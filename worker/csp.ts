/* The Content-Security-Policy for the app's pages, shipped as Content-Security-Policy-Report-Only first: browsers
   block nothing and report every violation to CSP_REPORT_PATH (report-to for Chromium, report-uri for Safari and
   Firefox), where the Worker logs a sample of what was blocked (cspViolations), so it can be switched to enforcing once
   a release shows no reports from the app itself. Wallet extensions inject their providers from the extension's own
   world, which a page policy does not govern.

   - Scripts: this origin's bundles, plus inline scripts carrying the response's nonce (vinext writes its bootstrap
     and RSC payload inline and stamps them with the nonce it reads from the request's CSP header, as Next.js does).
     No third-party script origin at all.
   - Connections: this origin (the Perpl proxy and its WebSocket relay), the Monad RPCs and Kuru Flow's API.
   - Images and media: any https source, data: and blob: (token logos and Moment media are arbitrary on-chain links,
     wallet icons are data: URIs, a picked file previews as blob:).
   - Styles: 'unsafe-inline', because React renders style attributes, which cannot carry a nonce. */

export type CspSources = { nonce?: string; host?: string; connect: readonly string[] };

/** Where browsers send violation reports (worker/index.ts), and the Reporting-Endpoints name the policy uses for it. */
export const CSP_REPORT_PATH = "/api/csp-report";
export const CSP_REPORT_GROUP = "csp";

export function contentSecurityPolicy({ nonce, host, connect }: CspSources): string {
  const scripts = ["'self'", ...(nonce ? [`'nonce-${nonce}'`] : [])];
  // 'self' covers wss: on the same host in current browsers; the explicit origin is for older Safari.
  const connects = [...new Set(["'self'", ...(host ? [`wss://${host}`] : []), ...connect])];
  return [
    "default-src 'self'",
    `script-src ${scripts.join(" ")}`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob: https:",
    "media-src 'self' blob: https:",
    "font-src 'self'",
    `connect-src ${connects.join(" ")}`,
    "frame-src 'none'",
    "worker-src 'self'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    `report-uri ${CSP_REPORT_PATH}`,
    `report-to ${CSP_REPORT_GROUP}`,
  ].join("; ");
}

export type CspViolation = { directive: string; blocked: string };

const KEYWORDS = new Set(["inline", "eval", "wasm-eval", "self", "data", "blob", "trusted-types-policy", "trusted-types-sink"]);
const MAX_REPORTS = 20;

/** What is safe and useful to log of a blocked resource: its origin, or the keyword the browser reports ("inline",
    "eval", "data"…). Never its path or query string, which can carry user data. */
export function blockedSource(value: unknown): string {
  if (typeof value !== "string" || value === "") return "unknown";
  if (KEYWORDS.has(value)) return value;
  try {
    const url = new URL(value);
    return /^(https?|wss?):$/.test(url.protocol) ? url.origin : url.protocol.slice(0, -1).slice(0, 20);
  } catch {
    return "other";
  }
}

const directiveOf = (value: unknown) => {
  const name = typeof value === "string" ? value.split(" ")[0] : "";
  return /^[a-z-]{1,40}$/.test(name) ? name : "unknown";
};

/** The violations in one report request, as directive and blocked source only: the legacy report-uri format
    (application/csp-report) and the Reporting API's (application/reports+json, possibly batched). Anything else, or
    anything malformed, yields nothing. */
export function cspViolations(contentType: string | null, body: string): CspViolation[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return [];
  }
  const type = (contentType ?? "").split(";")[0].trim().toLowerCase();
  const bodies: unknown[] = type === "application/reports+json" && Array.isArray(parsed)
    ? parsed.filter((r) => (r as { type?: unknown } | null)?.type === "csp-violation").map((r) => (r as { body?: unknown }).body)
    : type === "application/csp-report" && parsed !== null && typeof parsed === "object"
      ? [(parsed as { "csp-report"?: unknown })["csp-report"]]
      : [];
  return bodies.slice(0, MAX_REPORTS).filter((b): b is Record<string, unknown> => b !== null && typeof b === "object").map((b) => ({
    directive: directiveOf(b.effectiveDirective ?? b["effective-directive"] ?? b["violated-directive"]),
    blocked: blockedSource(b.blockedURL ?? b["blocked-uri"]),
  }));
}

/** The origin of a configured URL, or null when it is not a usable http(s)/ws(s) URL. */
export function sourceOrigin(url: string | undefined): string | null {
  if (!url) return null;
  try {
    const parsed = new URL(url);
    return /^(https?|wss?):$/.test(parsed.protocol) ? parsed.origin : null;
  } catch {
    return null;
  }
}

/** A fresh nonce for one response: 128 random bits, base64. */
export function newNonce(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return btoa(String.fromCharCode(...bytes));
}
