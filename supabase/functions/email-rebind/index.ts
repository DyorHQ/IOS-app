// email-rebind: moves an OTP-verified email to a NEW deterministic wallet — the "forgot password" / re-verify path.
//
// Normal sign-up writes the email → address binding directly (owner row-level security), so it can only ever CLAIM a
// free email, never overwrite one that already belongs to a different wallet. Re-binding needs to overwrite, so it
// cannot go through that RLS path; it goes through this function, which requires TWO independent proofs and then
// writes with the service role:
//
//   1. Ownership of the EMAIL — the caller passes the Privy access token issued after a fresh email one-time-code
//      login (same OTP as sign-up). The token is verified against the app's public key, and the email is read back
//      from Privy with the app secret, so the client can never assert an email it did not just verify.
//   2. Control of the NEW WALLET — the caller signs a challenge (EIP-191 personal_sign) that names the email and the
//      new address. The signer is recovered from the signature; only the holder of the new private key can produce it.
//
// The two proofs are bound together by the challenge (it carries the same email Privy attests), so this can only ever
// bind an email you verified to a wallet you hold — it cannot hijack someone else's email or point at a wallet you
// don't control. Then the binding is upserted with the service role, which is the only path allowed to overwrite a
// row owned by another wallet.
//
// Deploy:  supabase functions deploy email-rebind --no-verify-jwt   (the bearer is a Privy token, not a Supabase JWT)
// Secrets: PRIVY_APP_SECRET (shared with delete-account). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected.
import { importSPKI, jwtVerify } from "npm:jose@5";
import { recoverMessageAddress } from "npm:viem@2";
import { createClient } from "npm:@supabase/supabase-js@2";

const APP_ID = Deno.env.get("PRIVY_APP_ID") ?? "cmttp2squ00lk0djrso3z0yvm";
const PRIVY = "https://auth.privy.io/api/v1";
const REBIND_WINDOW_MS = 15 * 60 * 1000; // the signed challenge is only good for 15 minutes

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

// Reads the verified email Privy holds for this user (never trusts an email supplied by the client).
async function privyEmail(userId: string, secret: string): Promise<string | null> {
  const res = await fetch(`${PRIVY}/users/${encodeURIComponent(userId)}`, {
    headers: { Authorization: "Basic " + btoa(`${APP_ID}:${secret}`), "privy-app-id": APP_ID },
  });
  if (!res.ok) return null;
  const user = await res.json();
  const accounts: Array<Record<string, unknown>> = user?.linked_accounts ?? [];
  const email = accounts.find((a) => a?.type === "email");
  const address = email?.address;
  return typeof address === "string" ? address.trim().toLowerCase() : null;
}

// Pulls `Field: value` lines out of the challenge the wallet signed.
function field(message: string, key: string): string | null {
  const line = message.split("\n").find((l) => l.toLowerCase().startsWith(`${key.toLowerCase()}:`));
  return line ? line.slice(line.indexOf(":") + 1).trim() : null;
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

  let message: string, signature: string;
  try {
    const body = await req.json();
    message = String(body.message ?? "");
    signature = String(body.signature ?? "");
    if (!message || !signature.startsWith("0x")) throw new Error("bad body");
  } catch {
    return json({ error: "expected { message, signature }" }, 400);
  }

  // Proof #1 — the email Privy attests for this token.
  const verifiedEmail = await privyEmail(userId, secret);
  if (!verifiedEmail) return json({ error: "no verified email on this Privy account" }, 400);

  // The challenge must name that exact email, be recent, and carry the address it claims to bind.
  const claimedEmail = (field(message, "Email") ?? "").toLowerCase();
  const claimedAddress = (field(message, "Address") ?? "").toLowerCase();
  const issuedAt = Date.parse(field(message, "Issued At") ?? "");
  if (claimedEmail !== verifiedEmail) return json({ error: "the code you entered was for a different email" }, 400);
  if (!Number.isFinite(issuedAt) || Math.abs(Date.now() - issuedAt) > REBIND_WINDOW_MS) {
    return json({ error: "this reset expired — start again" }, 400);
  }

  // Proof #2 — recover the signer of the challenge; it must be the address the challenge binds.
  let recovered: string;
  try {
    recovered = (await recoverMessageAddress({ message, signature: signature as `0x${string}` })).toLowerCase();
  } catch {
    return json({ error: "invalid wallet signature" }, 401);
  }
  if (!/^0x[0-9a-f]{40}$/.test(claimedAddress) || recovered !== claimedAddress) {
    return json({ error: "wallet signature did not match" }, 401);
  }

  // Both proofs hold — overwrite the binding with the service role (the only path allowed past the owner RLS).
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { error } = await admin
    .from("email_accounts")
    .upsert({ email: verifiedEmail, wallet: recovered, verified_at: new Date().toISOString() }, { onConflict: "email" });
  if (error) return json({ error: `could not save the binding: ${error.message}` }, 502);

  return json({ rebound: true, address: recovered });
});
