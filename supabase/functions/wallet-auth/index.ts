// wallet-auth: bridges a Privy wallet login to a Supabase session.
// The app has the user's Privy wallet personal_sign a short, freshly-timestamped message; this function recovers
// the signer, checks it matches the claimed address and the message is fresh, then mints a Supabase-compatible
// HS256 JWT carrying a `wallet_address` claim that every RLS policy keys off. No private key ever touches this
// service; only a signature over a nonce.
//
// Deploy: supabase functions deploy wallet-auth --no-verify-jwt
// Secret:  APP_JWT_SECRET must equal the project's JWT Secret (Dashboard -> Settings -> API -> JWT Secret) so the
//          minted tokens are accepted by PostgREST.
import { recoverMessageAddress, isAddress } from "npm:viem@2";
import { SignJWT } from "npm:jose@5";
import { v5 as uuidv5 } from "npm:uuid@9";

const NAMESPACE = "6f9b1c2e-1c2a-4b6e-9c3d-0a1b2c3d4e5f"; // stable namespace for wallet->uuid mapping
const MAX_AGE_MS = 10 * 60 * 1000; // the signed message must be < 10 minutes old

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const secret = Deno.env.get("APP_JWT_SECRET");
  if (!secret) return json({ error: "server not configured: APP_JWT_SECRET missing" }, 500);

  let payload: { address?: string; message?: string; signature?: string };
  try { payload = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  const { address, message, signature } = payload;
  if (!address || !isAddress(address) || !message || !signature) return json({ error: "address, message and signature are required" }, 400);

  if (!message.includes(address)) return json({ error: "message does not match address" }, 400);
  const issuedMatch = message.match(/Issued At:\s*(\d{10,})/);
  if (!issuedMatch) return json({ error: "message missing Issued At timestamp" }, 400);
  const issued = Number(issuedMatch[1]);
  if (!Number.isFinite(issued) || Math.abs(Date.now() - issued) > MAX_AGE_MS) return json({ error: "message expired" }, 401);

  let recovered: string;
  try { recovered = await recoverMessageAddress({ message, signature: signature as `0x${string}` }); }
  catch { return json({ error: "unreadable signature" }, 401); }
  if (recovered.toLowerCase() !== address.toLowerCase()) return json({ error: "signature does not match address" }, 401);

  const wallet = address.toLowerCase();
  const now = Math.floor(Date.now() / 1000);
  const token = await new SignJWT({ role: "authenticated", wallet_address: wallet })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setSubject(uuidv5(wallet, NAMESPACE))
    .setAudience("authenticated")
    .setIssuedAt(now)
    .setExpirationTime(now + 12 * 60 * 60)
    .sign(new TextEncoder().encode(secret));

  return json({ access_token: token, token_type: "bearer", expires_in: 12 * 60 * 60, wallet });
});
