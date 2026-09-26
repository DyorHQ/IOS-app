// aurora-proxy: the Bridge's only route to the Aurora Intents Swap API. It holds the Aurora API key server-side
// (Supabase secret AURORA_API_KEY) so the key never ships inside the app, and forwards ONLY the four endpoints the
// bridge uses. verify_jwt=true (pinned in supabase/config.toml) gates to a valid Supabase JWT; we additionally require
// role 'authenticated' and a wallet_address claim so the public anon/publishable key (role 'anon') cannot use it —
// only a signed-in DyorHQ wallet session qualifies (the same rule as pin-media). The key is appended as Aurora's path
// segment here, and scrubbed from every response body (raw and percent-encoded), since Aurora's error bodies can echo
// the request path.
//
// Security audit 2026-09-26 (SB-2, SB-11):
//   * every call passes edge_rate_gate (migration 27): tokens/quote/deposit-submit 120 per wallet and 360 per client
//     network per 15 minutes; status polls (every 4 s during a bridge) 300 and 900;
//   * a quote must deliver to, and refund to, the session's own wallet, with the origin-chain deposit and refund and
//     destination-chain recipient the app uses; appFees is dropped and referral is always "dyorhq"; only the fields
//     the app sends are forwarded (request.ts);
//   * upstream errors reach the client as Aurora's short message only, never the raw body.
import { createClient } from "npm:@supabase/supabase-js@2";
import { clientNet } from "../_shared/net.ts";
import { rateGate } from "../_shared/rate.ts";
import { quoteBody, submitBody, upstreamError } from "./request.ts";

const AURORA = "https://intents-api.aurora.dev/api";
const ROUTES: Record<string, "GET" | "POST"> = {
  "tokens": "GET",
  "quote": "POST",
  "deposit/submit": "POST",
  "status": "GET",
};
const STATUS_QUERY = new Set(["depositAddress", "depositMemo"]);
const MAX_BODY = 16_384;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

// Reads a claim from an already-gateway-verified JWT (verify_jwt=true has validated the signature; we only inspect).
function claims(auth: string): Record<string, unknown> {
  const token = auth.replace(/^Bearer\s+/i, "").trim();
  const part = token.split(".")[1];
  if (!part) return {};
  try {
    const b64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(part.length + (4 - part.length % 4) % 4, "=");
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))));
  } catch { return {}; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const session = claims(req.headers.get("authorization") ?? "");
  if (session.role !== "authenticated") return json({ error: "a signed-in wallet session is required" }, 403);
  const wallet = typeof session.wallet_address === "string" ? session.wallet_address.toLowerCase() : "";
  if (!/^0x[0-9a-f]{40}$/.test(wallet)) return json({ error: "a signed-in wallet session is required" }, 403);

  const key = Deno.env.get("AURORA_API_KEY");
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!key || !url || !serviceKey) return json({ error: "bridge not configured" }, 503);

  // The runtime path is /aurora-proxy/<route> (or /functions/v1/aurora-proxy/<route> behind the gateway).
  const requestURL = new URL(req.url);
  const route = requestURL.pathname.replace(/^.*\/aurora-proxy\/?/, "").replace(/\/+$/, "");
  const method = ROUTES[route];
  if (!method) return json({ error: "unknown route" }, 404);
  if (req.method !== method) return json({ error: "method not allowed" }, 405);

  const target = new URL(`${AURORA}/${route}/${encodeURIComponent(key)}`);
  if (route === "status") {
    for (const [name, value] of requestURL.searchParams) if (STATUS_QUERY.has(name)) target.searchParams.set(name, value);
    if (!target.searchParams.get("depositAddress")) return json({ error: "depositAddress is required" }, 400);
  }

  let body: string | undefined;
  if (method === "POST") {
    const raw = await req.text();
    if (raw.length > MAX_BODY) return json({ error: "request too large" }, 413);
    const forward = route === "quote" ? quoteBody(raw, wallet) : submitBody(raw);
    if ("error" in forward) return json({ error: forward.error }, forward.status);
    body = forward.body;
  }

  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const refused = await rateGate(db, route === "status" ? "aurora-status" : "aurora", wallet, clientNet(req), cors);
  if (refused) return refused;

  let upstream: Response;
  try {
    upstream = await fetch(target, {
      method,
      headers: { "Content-Type": "application/json" },
      body,
      signal: AbortSignal.timeout(20_000),
    });
  } catch {
    return json({ error: "Aurora did not answer" }, 502);
  }
  // Scrub the key both as-is and in the percent-encoded form it had in the request path.
  const scrub = (s: string) => s.split(key).join("[redacted]").split(encodeURIComponent(key)).join("[redacted]");
  const text = scrub(await upstream.text());
  if (!upstream.ok) {
    console.error("aurora-proxy: upstream", upstream.status, route, text.slice(0, 200)); // logs only (SB-11)
    const failure = upstreamError(text, upstream.status, scrub);
    return json(failure.body, failure.status);
  }
  return new Response(text, { status: upstream.status, headers: { ...cors, "Content-Type": "application/json" } });
});
