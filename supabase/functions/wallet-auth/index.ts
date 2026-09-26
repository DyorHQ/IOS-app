// wallet-auth: bridges a Privy wallet login to a Supabase session, with a server-issued single-use nonce.
//
//   1. POST { action: "nonce", address }            -> { nonce, expiresAt }
//      32 random bytes (64 lowercase hex), valid for 5 minutes, bound to lower(address). There is deliberately NO
//      per-wallet cap: wallet addresses are public, so either refusing new nonces (429) or evicting the oldest pending
//      ones would let anyone lock a chosen wallet out of sign-in by requesting nonces for it faster than its owner can
//      sign (security audit 2026-09-26, SB-1). A cap per wallet never bounded the table anyway (any number of wallets
//      can be named); expired rows are purged on every issue (an expired nonce can never be consumed), so the table only
//      ever holds about 5 minutes of issuance.
//   2. POST { address, message, signature }          -> { access_token, token_type, expires_in, wallet }
//      The wallet personal_signs EXACTLY
//        "DyorHQ Sign-In\n\nWallet: <address as sent>\nNonce: <nonce>\nIssued At: <unix ms>"
//      This function checks the template (anchored, no extra lines), the timestamp (< 10 minutes), recovers the signer
//      (EIP-191), and only THEN consumes the nonce atomically — a single UPDATE … WHERE used_at IS NULL AND
//      expires_at > now(), so a signature can be exchanged for a session at most once, and nobody without the wallet's
//      signature can burn a nonce. Legacy client-generated nonces are rejected (no grace period).
//
// On success it mints a Supabase-compatible HS256 JWT carrying the `wallet_address` claim every RLS policy keys off.
// No private key ever touches this service; only a signature over a server nonce.
//
// Deploy:  supabase functions deploy wallet-auth --no-verify-jwt   (called before the app has a session)
//          Apply migration 19 first, and ship together with the app build that requests nonces: this version rejects
//          the old client-built message, and the old version rejects { action: "nonce" }.
// Secret:  APP_JWT_SECRET must equal the project's JWT Secret (Dashboard -> Settings -> API -> JWT Secret) so the
//          minted tokens are accepted by PostgREST. SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected; the
//          nonces live in public.auth_nonces (migration 19: RLS on, no policies, service role only).
import { recoverMessageAddress, isAddress } from "npm:viem@2";
import { SignJWT } from "npm:jose@5";
import { v5 as uuidv5 } from "npm:uuid@9";
import { createClient } from "npm:@supabase/supabase-js@2";

const NAMESPACE = "6f9b1c2e-1c2a-4b6e-9c3d-0a1b2c3d4e5f"; // stable namespace for wallet->uuid mapping
const MAX_AGE_MS = 10 * 60 * 1000; // the signed message must be < 10 minutes old
const NONCE_TTL_MS = 5 * 60 * 1000; // a nonce must be used within 5 minutes of issue
const SESSION_S = 12 * 60 * 60;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

const hex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

function admin() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return null;
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

// The one message shape a sign-in may carry. `address` has already passed isAddress (0x + 40 hex, no regex
// metacharacters), and JS `$` without the m flag matches only at the very end, so nothing can be appended.
function signInTemplate(address: string) {
  return new RegExp(`^DyorHQ Sign-In\\n\\nWallet: ${address}\\nNonce: ([0-9a-f]{64})\\nIssued At: (\\d{13})$`);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const secret = Deno.env.get("APP_JWT_SECRET");
  if (!secret) return json({ error: "server not configured: APP_JWT_SECRET missing" }, 500);
  const db = admin();
  if (!db) return json({ error: "server not configured" }, 500);

  let payload: { action?: unknown; address?: unknown; message?: unknown; signature?: unknown };
  try { payload = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  if (!payload || typeof payload !== "object") return json({ error: "invalid json" }, 400);

  // ── 1. Issue a nonce ────────────────────────────────────────────────────────────────────────────────────────────
  if (payload.action === "nonce") {
    const address = payload.address;
    if (typeof address !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(address) || !isAddress(address)) {
      return json({ error: "a valid wallet address is required" }, 400);
    }
    const wallet = address.toLowerCase();
    const nonce = hex(crypto.getRandomValues(new Uint8Array(32)));
    const expiresAt = Date.now() + NONCE_TTL_MS;

    // Consumption requires expires_at > now(), so deleting every expired row (used or not) changes nothing observable.
    const now = new Date().toISOString();
    const [, inserted] = await Promise.all([
      db.from("auth_nonces").delete().lt("expires_at", now),
      db.from("auth_nonces").insert({ nonce, wallet, expires_at: new Date(expiresAt).toISOString() }),
    ]);
    if (inserted.error) return json({ error: "could not issue a sign-in nonce" }, 502);
    return json({ nonce, expiresAt });
  }
  if (payload.action !== undefined) return json({ error: "unknown action" }, 400);

  // ── 2. Exchange a signed nonce for a session ────────────────────────────────────────────────────────────────────
  const { address, message, signature } = payload;
  if (typeof address !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(address) || !isAddress(address) ||
      typeof message !== "string" || !message || typeof signature !== "string" || !/^0x[0-9a-fA-F]+$/.test(signature)) {
    return json({ error: "address, message and signature are required" }, 400);
  }

  const match = signInTemplate(address).exec(message);
  if (!match) return json({ error: "sign-in message not recognised — update DyorHQ and try again" }, 400);
  const nonce = match[1];
  const issued = Number(match[2]);
  if (!Number.isFinite(issued) || Math.abs(Date.now() - issued) > MAX_AGE_MS) return json({ error: "message expired" }, 401);

  let recovered: string;
  try { recovered = await recoverMessageAddress({ message, signature: signature as `0x${string}` }); }
  catch { return json({ error: "unreadable signature" }, 401); }
  if (recovered.toLowerCase() !== address.toLowerCase()) return json({ error: "signature does not match address" }, 401);

  const wallet = address.toLowerCase();
  const now = new Date().toISOString();
  const consumed = await db.from("auth_nonces").update({ used_at: now })
    .eq("nonce", nonce).eq("wallet", wallet).is("used_at", null).gt("expires_at", now)
    .select("nonce");
  if (consumed.error) return json({ error: "could not verify the sign-in nonce" }, 502);
  if (!consumed.data || consumed.data.length !== 1) {
    return json({ error: "sign-in nonce invalid, expired or already used" }, 401);
  }

  const iat = Math.floor(Date.now() / 1000);
  const token = await new SignJWT({ role: "authenticated", wallet_address: wallet })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setSubject(uuidv5(wallet, NAMESPACE))
    .setAudience("authenticated")
    .setIssuedAt(iat)
    .setExpirationTime(iat + SESSION_S)
    .sign(new TextEncoder().encode(secret));

  return json({ access_token: token, token_type: "bearer", expires_in: SESSION_S, wallet });
});
