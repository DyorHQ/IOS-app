// The JSON-RPC endpoints the indexer reads logs, heads and nonces from, and how it reads their errors.
//
// Defaults: Monad's public endpoints, as measured on 2026-10-08 (eth_getLogs span per request, JSON-RPC batch size,
// ≤ 4 requests/s each). The optional Edge secret MONAD_LOGS_ENDPOINTS adds or replaces endpoints (a keyed provider
// later, with no code change); its URLs may hold a key, so no URL is ever logged, stored or put in an error.
//
// Straddle classes (D4): `refuses` — a range crossing the endpoint's head is an error (rpc2: -32014 "block not
// available … requested toBlock N is not yet available on the node"); `clamps` — the endpoint may answer such a range
// up to its own head with no error (rpc3 and rpc1 always, rpc4 for some of its nodes). A clamped answer looks like
// "no logs in the missing blocks", so a clamping endpoint only gets pieces ending at or below head − lag (pacing.ts).
export type Straddle = "refuses" | "clamps";
export type Endpoint = {
  label: string;          // ^[a-z0-9-]{1,20}$ — what logs, summaries and the endpoint memory name it by
  url: string;            // never logged
  span: number;           // blocks per eth_getLogs request
  batch: number;          // JSON-RPC calls per HTTP request (1 = a bare object: rpc1 refuses any array with HTTP 403)
  rps: number;            // HTTP requests per second, at most
  inFlight: number;       // HTTP requests at once, at most
  archive: boolean;       // answers eth_getTransactionCount at old blocks (first-transaction bisection)
  straddle: Straddle;
  lag: number;            // a clamping endpoint only reads pieces ending at or below head − lag
  priority: number;       // lower first
  maxPerDay?: number;     // a paid quota: requests per UTC day
};

export const DEFAULT_ENDPOINTS: readonly Endpoint[] = Object.freeze([
  { label: "rpc2", url: "https://rpc2.monad.xyz", span: 10_000, batch: 6, rps: 4, inFlight: 8, archive: true, straddle: "refuses", lag: 600, priority: 10 },
  { label: "rpc4", url: "https://rpc4.monad.xyz", span: 1_000, batch: 1, rps: 4, inFlight: 2, archive: true, straddle: "clamps", lag: 600, priority: 20 },
  { label: "rpc3", url: "https://rpc3.monad.xyz", span: 1_000, batch: 1, rps: 4, inFlight: 2, archive: false, straddle: "clamps", lag: 600, priority: 30 },
  { label: "rpc1", url: "https://rpc1.monad.xyz", span: 100, batch: 1, rps: 4, inFlight: 2, archive: true, straddle: "clamps", lag: 600, priority: 40 },
].map((e) => Object.freeze(e as Endpoint)));

// Defaults for a custom entry's fields (a custom entry must name its url; everything else is optional). Conservative:
// the owner raises span, batch and rps to what the provider allows.
const CUSTOM_DEFAULTS = { span: 1_000, batch: 1, rps: 4, inFlight: 2, archive: false, straddle: "clamps" as Straddle, lag: 600, priority: 0 };
const MAX_CUSTOM = 8;
const LABEL = /^[a-z0-9-]{1,20}$/;
const FIELDS = new Set(["label", "url", "span", "batch", "rps", "inFlight", "archive", "straddle", "lag", "priority", "maxPerDay"]);

class Invalid extends Error {}

function numberField(v: unknown, field: string, min: number, max: number, integer: boolean): number {
  if (typeof v !== "number" || !Number.isFinite(v) || v < min || v > max || (integer && !Number.isInteger(v))) {
    throw new Invalid(`${field} must be ${integer ? "an integer" : "a number"} from ${min} to ${max}`);
  }
  return v;
}

// Applies `fields` (validated) onto `base`; `where` names the entry in an error, never its url.
function applyFields(base: Endpoint, fields: Record<string, unknown>, where: string, allowUrl: boolean): Endpoint {
  const e = { ...base };
  for (const [key, value] of Object.entries(fields)) {
    if (!FIELDS.has(key)) throw new Invalid(`${where}: unknown field ${key.slice(0, 20)}`);
    switch (key) {
      case "url": {
        if (!allowUrl) throw new Invalid(`${where}: url cannot be overridden`);
        let parsed: URL | null = null;
        try { parsed = typeof value === "string" ? new URL(value) : null; } catch { parsed = null; }
        if (!parsed || parsed.protocol !== "https:" || !parsed.hostname) throw new Invalid(`${where}: url must be https with a host`);
        e.url = value as string;
        break;
      }
      case "label":
        if (typeof value !== "string" || !LABEL.test(value)) throw new Invalid(`${where}: label must match ^[a-z0-9-]{1,20}$`);
        e.label = value;
        break;
      case "span": e.span = numberField(value, `${where}: span`, 100, 1_000_000, true); break;
      case "batch": e.batch = numberField(value, `${where}: batch`, 1, 20, true); break;
      case "rps": e.rps = numberField(value, `${where}: rps`, 0.25, 50, false); break;
      case "inFlight": e.inFlight = numberField(value, `${where}: inFlight`, 1, 16, true); break;
      case "lag": e.lag = numberField(value, `${where}: lag`, 100, 10_000, true); break;
      case "priority": e.priority = numberField(value, `${where}: priority`, -1_000_000, 1_000_000, true); break;
      case "maxPerDay": e.maxPerDay = numberField(value, `${where}: maxPerDay`, 1, 10_000_000, true); break;
      case "archive":
        if (typeof value !== "boolean") throw new Invalid(`${where}: archive must be true or false`);
        e.archive = value;
        break;
      case "straddle":
        if (value !== "refuses" && value !== "clamps") throw new Invalid(`${where}: straddle must be "refuses" or "clamps"`);
        e.straddle = value;
        break;
    }
  }
  return e;
}

function customEntries(list: unknown): Endpoint[] {
  if (!Array.isArray(list)) throw new Invalid("endpoints must be a list");
  if (list.length > MAX_CUSTOM) throw new Invalid(`at most ${MAX_CUSTOM} custom endpoints`);
  return list.map((entry, i) => {
    const where = `endpoints[${i}]`;
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) throw new Invalid(`${where} must be an object`);
    if (!("url" in entry)) throw new Invalid(`${where}: url is required`);
    const base = { label: `custom-${i + 1}`, url: "", ...CUSTOM_DEFAULTS } as Endpoint;
    return applyFields(base, entry as Record<string, unknown>, where, true);
  });
}

// The endpoints MONAD_LOGS_ENDPOINTS configures: unset → the defaults; a JSON array → replaces the defaults; an object
// {"mode": "append" (the default) | "replace", "endpoints": [...], "overrides": {"<default label>": {fields but url}}}.
// Anything invalid → the defaults, and `error` names the field (never a URL or a value).
export function endpointsFromEnv(raw: string | undefined): { endpoints: Endpoint[]; error?: string } {
  const defaults = () => DEFAULT_ENDPOINTS.map((e) => ({ ...e }));
  if (raw === undefined || raw.trim() === "") return { endpoints: defaults() };
  let parsed: unknown;
  try { parsed = JSON.parse(raw); } catch { return { endpoints: defaults(), error: "MONAD_LOGS_ENDPOINTS is not JSON" }; }
  try {
    let list: Endpoint[];
    if (Array.isArray(parsed)) {
      list = customEntries(parsed);
      if (list.length === 0) throw new Invalid("the endpoint list is empty");
    } else if (parsed && typeof parsed === "object") {
      const o = parsed as Record<string, unknown>;
      for (const key of Object.keys(o)) if (!["mode", "endpoints", "overrides"].includes(key)) throw new Invalid(`unknown key ${key.slice(0, 20)}`);
      const mode = o.mode ?? "append";
      if (mode !== "append" && mode !== "replace") throw new Invalid(`mode must be "append" or "replace"`);
      const custom = customEntries(o.endpoints ?? []);
      if (mode === "replace") {
        if (o.overrides !== undefined) throw new Invalid("overrides apply to the defaults: use mode append");
        if (custom.length === 0) throw new Invalid("mode replace needs at least one endpoint");
        list = custom;
      } else {
        const base = defaults();
        const overrides = o.overrides ?? {};
        if (!overrides || typeof overrides !== "object" || Array.isArray(overrides)) throw new Invalid("overrides must be an object");
        for (const [label, fields] of Object.entries(overrides as Record<string, unknown>)) {
          const at = base.findIndex((e) => e.label === label);
          if (at < 0) throw new Invalid(`overrides: no default endpoint ${label.slice(0, 20)}`);
          if (!fields || typeof fields !== "object" || Array.isArray(fields)) throw new Invalid(`overrides.${label} must be an object`);
          base[at] = applyFields(base[at], fields as Record<string, unknown>, `overrides.${label}`, false);
        }
        list = [...base, ...custom];
      }
    } else {
      throw new Invalid("MONAD_LOGS_ENDPOINTS must be a list or an object");
    }
    const labels = list.map((e) => e.label);
    if (new Set(labels).size !== labels.length) throw new Invalid("endpoint labels must be unique");
    return { endpoints: list.sort((a, b) => a.priority - b.priority) };
  } catch (err) {
    if (err instanceof Invalid) return { endpoints: defaults(), error: `MONAD_LOGS_ENDPOINTS: ${err.message}` };
    throw err;
  }
}

// ── Reading errors (§10.1; the strings are the ones measured on 2026-10-08) ───────────────────────────────────────

export type CallVerdict =
  | { kind: "throttled"; retryAfterMs?: number }
  | { kind: "span"; span?: number }
  | { kind: "dense"; cut?: number }
  | { kind: "pastHead" }
  | { kind: "failed" };

const THROTTLED = /rate limit|too many requests|request limit|per second|throughput/i;
const DENSE = /returned more than|too many logs|too many results|response size|log response size exceeded/i;
const PAST_HEAD = /errupstreamblockunavailable|not yet available on the node|beyond current head/i;
const SPAN_N = /(?:limited to a|up to a)\s+([0-9][0-9,_]*)\s+(?:block\s+)?range/i;
const SPAN = /block range|range is too large|range too large/i;
const SUGGESTED = /\[\s*(0x[0-9a-f]+|[0-9]+)\s*,\s*(0x[0-9a-f]+|[0-9]+)\s*\]/i;

// One JSON-RPC error for an eth_getLogs piece [from, to], read against the run's head.
export function classifyCallError(error: { code?: number; message?: string }, piece: { from: number; to: number },
                                  head: number): CallVerdict {
  const message = String(error.message ?? "");
  if (error.code === 429 || THROTTLED.test(message)) return { kind: "throttled" };
  if (PAST_HEAD.test(message) || (error.code === -32014 && /block not available/i.test(message))) return { kind: "pastHead" };
  if (/block requested not found/i.test(message) && piece.to > head - 1_000) return { kind: "pastHead" };
  // Before -32005: some providers answer "query returned more than 10000 results" with that code, which retrying
  // unchanged would never get past.
  if (DENSE.test(message)) {
    const suggested = SUGGESTED.exec(message);
    const cut = suggested ? Number(suggested[2]) : NaN;
    return Number.isSafeInteger(cut) && cut >= piece.from && cut < piece.to ? { kind: "dense", cut } : { kind: "dense" };
  }
  if (error.code === -32005) return { kind: "throttled" };
  const n = SPAN_N.exec(message);
  if (n) {
    const span = Number(n[1].replace(/[,_]/g, ""));
    return Number.isSafeInteger(span) && span >= 1 ? { kind: "span", span } : { kind: "span" };
  }
  if (SPAN.test(message)) return { kind: "span" };
  return { kind: "failed" };
}

// Retry-After as milliseconds: delta-seconds or an HTTP date; undefined when absent or unreadable.
export function retryAfterMs(value: string | null, now: number = Date.now()): number | undefined {
  if (!value) return undefined;
  const trimmed = value.trim();
  if (/^[0-9]+$/.test(trimmed)) return Number(trimmed) * 1_000;
  const at = Date.parse(trimmed);
  return Number.isFinite(at) ? Math.max(0, at - now) : undefined;
}

// A non-2xx answer whose body is not JSON-RPC.
export function classifyHttp(status: number, headers: Headers, body: string, now: number = Date.now())
  : { kind: "throttled"; retryAfterMs?: number } | { kind: "batchRefused" } | { kind: "unanswered" } | { kind: "callErrors" } {
  if (status === 429 || status === 503) return { kind: "throttled", retryAfterMs: retryAfterMs(headers.get("retry-after"), now) };
  if (status === 403 && /restricted json rpc method/i.test(body)) return { kind: "batchRefused" };
  if (status >= 500) return { kind: "unanswered" };
  return { kind: "callErrors" };
}
