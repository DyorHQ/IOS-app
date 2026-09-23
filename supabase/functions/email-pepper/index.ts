// email-pepper: the server half of the v2 email+password wallet, which makes it impossible to guess passwords offline.
//
// The app derives S = PBKDF2(password, email) as before, then sends only two hashes here:
//   e = SHA256("dyorhq/email-pepper/v1/email:" + normalized email)
//   t = SHA256("dyorhq/email-pepper/v1/t:" || S)
// and receives p = HMAC-SHA256(K, "dyorhq/email-pepper/v1" || 0x00 || e || t). The wallet key is HKDF(S || p), so a
// password guess can only be tested by asking this endpoint — which is rate limited per email hash (10 / 15 min,
// 50 / 24 h) and per client network (60 / 15 min; an IPv4 address or an IPv6 /64). K is 32 random bytes generated
// inside Postgres and kept in Supabase Vault ('email_pepper_key'); it never leaves the database: the HMAC and the rate
// limit both run in the SECURITY DEFINER function public.email_pepper_hmac (migration 20), executable only by the
// service role. The server only ever sees t — a hash of S — never the password or S itself.
//
// Nothing about the request or the answer is logged: e, t and p are sensitive (p together with S is the wallet key).
//
// Known limitation (owner decision, see migration 20): e needs no secret, so anyone who knows an email can spend its
// per-email budget and keep that user from deriving the v2 key on a device that does not already hold it, for as long
// as they keep it up. Funds are never at risk; lifting it needs an out-of-band proof such as a Privy email OTP.
//
// Deploy:  supabase functions deploy email-pepper --no-verify-jwt   (called before sign-in, so there is no session)
// Secrets: none of its own. SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected.
//
//   POST { e: <64 lowercase hex>, t: <64 lowercase hex> }
//     200 { p: <64 lowercase hex> }
//     400 malformed input
//     429 { error: "too many attempts", retryAfter: <seconds> }
import { createClient } from "npm:@supabase/supabase-js@2";

const HEX64 = /^[0-9a-f]{64}$/;
const MAX_BODY = 1024;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store", ...extra },
  });
}

// The caller's network for the per-IP limit, from Cloudflare's cf-connecting-ip (set at the edge; a client cannot
// forge it through Cloudflare). IPv4 counts per address, IPv6 per /64 — one subscriber's allocation — so rotating
// addresses inside a /64 buys no fresh bucket. X-Forwarded-For is deliberately NOT used: its first entry is whatever
// the client sent, so it would let a caller pick a fresh bucket per request, or fill someone else's. null when absent
// or unparseable — the per-email limits still apply, and unknown callers don't share (and exhaust) one bucket.
function clientNet(req: Request): string | null {
  const raw = (req.headers.get("cf-connecting-ip") ?? "").trim();
  const v4 = raw.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (v4) {
    const octets = v4.slice(1).map(Number);
    return octets.every((o) => o <= 255) ? octets.join(".") : null;
  }
  if (!raw.includes(":") || !/^[0-9a-fA-F:.]+$/.test(raw)) return null;
  let host: string;
  try { host = new URL(`http://[${raw}]/`).hostname; } catch { return null; }
  if (!host.startsWith("[") || !host.endsWith("]")) return null;
  // The URL parser validates and serialises IPv6 as lowercase hex groups with at most one "::" (never dotted).
  const [head, tail = ""] = host.slice(1, -1).split("::");
  const h = head ? head.split(":") : [], t = tail ? tail.split(":") : [];
  const groups = host.includes("::") ? [...h, ...Array(8 - h.length - t.length).fill("0"), ...t] : h;
  if (groups.length !== 8) return null;
  const g = groups.map((x) => parseInt(x, 16));
  if (g.slice(0, 5).every((x) => x === 0) && g[5] === 0xffff) { // IPv4-mapped: count as that IPv4 address
    return [g[6] >> 8, g[6] & 255, g[7] >> 8, g[7] & 255].join(".");
  }
  return `${g.slice(0, 4).map((x) => x.toString(16)).join(":")}::/64`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "server not configured" }, 500);

  let e: unknown, t: unknown;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY) throw new Error("too large");
    ({ e, t } = JSON.parse(text) ?? {});
  } catch {
    return json({ error: "expected { e, t }" }, 400);
  }
  if (typeof e !== "string" || typeof t !== "string" || !HEX64.test(e) || !HEX64.test(t)) {
    return json({ error: "e and t must each be 64 lowercase hex characters" }, 400);
  }

  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await db.rpc("email_pepper_hmac", { p_e: e, p_t: t, p_ip: clientNet(req) });
  if (error || !data || typeof data !== "object") return json({ error: "pepper unavailable" }, 503);

  const result = data as { p?: unknown; retryAfter?: unknown };
  if (typeof result.retryAfter === "number") {
    const retryAfter = Math.max(1, Math.ceil(result.retryAfter));
    return json({ error: "too many attempts", retryAfter }, 429, { "Retry-After": String(retryAfter) });
  }
  if (typeof result.p !== "string" || !HEX64.test(result.p)) return json({ error: "pepper unavailable" }, 503);
  return json({ p: result.p });
});
