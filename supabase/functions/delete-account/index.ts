// delete-account: deletes the caller's Privy user — and with it the embedded wallet — so that in-app account
// deletion is complete (App Store guideline 5.1.1(v)). The caller proves ownership with the Privy access token the
// SDK issues to the signed-in user: it is verified against the app's public verification key (fetched from Privy
// and cached per isolate), then the user is deleted with the app secret, which lives only in this function's
// environment. The app deletes its own Supabase rows separately, under the wallet's row-level security.
//
// Deploy:  supabase functions deploy delete-account --no-verify-jwt   (the bearer is a Privy token, not a Supabase JWT)
// Secrets: supabase secrets set PRIVY_APP_SECRET=...   (PRIVY_APP_ID defaults to the DyorHQ app below)
//          SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected (the rate-limit gate; needs migration 20 applied).
import { importSPKI, jwtVerify } from "npm:jose@5";
import { createClient } from "npm:@supabase/supabase-js@2";

const APP_ID = Deno.env.get("PRIVY_APP_ID") ?? "cmttp2squ00lk0djrso3z0yvm";
const PRIVY = "https://auth.privy.io/api/v1";
// The Privy-lookup budget's subject: the same hash email-pepper and email-rebind use (one budget per Privy user).
const PRIVY_USER_LABEL = "dyorhq/email-pepper/v1/privy-user:";

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

let verificationKey: CryptoKey | null = null;
async function appVerificationKey(): Promise<CryptoKey> {
  if (verificationKey) return verificationKey;
  const res = await fetch(`${PRIVY}/apps/${APP_ID}`, { headers: { "privy-app-id": APP_ID } });
  if (!res.ok) throw new Error(`privy app config ${res.status}`);
  const app = await res.json();
  verificationKey = await importSPKI(String(app.verification_key), "ES256");
  return verificationKey;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "missing Privy access token" }, 401);

  let userId: string;
  try {
    const { payload } = await jwtVerify(token, await appVerificationKey(), { issuer: "privy.io", audience: APP_ID });
    if (!payload.sub) throw new Error("no subject");
    userId = payload.sub;
  } catch {
    return json({ error: "invalid Privy access token" }, 401);
  }

  const secret = Deno.env.get("PRIVY_APP_SECRET");
  if (!secret) return json({ error: "PRIVY_APP_SECRET is not configured" }, 500);

  // Every Privy admin call first passes email_pepper_lookup_gate (migration 20): at most 10 per Privy user per 15
  // minutes, so one valid token cannot turn into a stream of calls under Privy's app-wide rate limit (security audit
  // 2026-09-26, SB-3). A refusal leaves everything as it was; the app stops before erasing the device and can retry.
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "server not configured" }, 500);
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const gate = await db.rpc("email_pepper_lookup_gate", { p_subject: await sha256Hex(PRIVY_USER_LABEL + userId), p_ip: null });
  if (gate.error || !gate.data || typeof gate.data !== "object") return json({ error: "account deletion is unavailable right now — try again in a minute" }, 503);
  if (typeof (gate.data as { retryAfter?: unknown }).retryAfter === "number") {
    return json({ error: "too many attempts — try again in a few minutes" }, 429);
  }
  if ((gate.data as { ok?: unknown }).ok !== true) return json({ error: "account deletion is unavailable right now — try again in a minute" }, 503);

  const res = await fetch(`${PRIVY}/users/${encodeURIComponent(userId)}`, {
    method: "DELETE",
    headers: { Authorization: "Basic " + btoa(`${APP_ID}:${secret}`), "privy-app-id": APP_ID },
  });
  if (res.status === 404) return json({ deleted: true, alreadyGone: true });
  if (!res.ok) return json({ error: `privy responded ${res.status}` }, 502);
  return json({ deleted: true });
});
