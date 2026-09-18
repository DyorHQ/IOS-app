// delete-account: deletes the caller's Privy user — and with it the embedded wallet — so that in-app account
// deletion is complete (App Store guideline 5.1.1(v)). The caller proves ownership with the Privy access token the
// SDK issues to the signed-in user: it is verified against the app's public verification key (fetched from Privy
// and cached per isolate), then the user is deleted with the app secret, which lives only in this function's
// environment. The app deletes its own Supabase rows separately, under the wallet's row-level security.
//
// Deploy:  supabase functions deploy delete-account --no-verify-jwt   (the bearer is a Privy token, not a Supabase JWT)
// Secrets: supabase secrets set PRIVY_APP_SECRET=...   (PRIVY_APP_ID defaults to the DyorHQ app below)
import { importSPKI, jwtVerify } from "npm:jose@5";

const APP_ID = Deno.env.get("PRIVY_APP_ID") ?? "cmttp2squ00lk0djrso3z0yvm";
const PRIVY = "https://auth.privy.io/api/v1";

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

  const res = await fetch(`${PRIVY}/users/${encodeURIComponent(userId)}`, {
    method: "DELETE",
    headers: { Authorization: "Basic " + btoa(`${APP_ID}:${secret}`), "privy-app-id": APP_ID },
  });
  if (res.status === 404) return json({ deleted: true, alreadyGone: true });
  if (!res.ok) return json({ error: `privy responded ${res.status}` }, 502);
  return json({ deleted: true });
});
