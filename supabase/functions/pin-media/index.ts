// pin-media: pins an already-uploaded Moment media object from the public launch-media bucket to IPFS via Pinata, so
// the NFT's on-chain mediaURI can be a permanent ipfs:// CID instead of a mutable Supabase URL. The Pinata JWT lives
// only in this function's environment (Supabase secret PINATA_JWT). verify_jwt=true gates to a valid Supabase JWT; we
// additionally require role 'authenticated' so the public anon/publishable key (which passes verify_jwt but carries
// role 'anon') cannot be used to drain the Pinata quota. Only a signed-in DyorHQ wallet session qualifies.
//
// CRITICAL — return a FILE cid, never a DIRECTORY. Pinata's pinFileToIPFS treats a "/" in `pinataMetadata.name` (and
// in the multipart filename) as a FOLDER PATH: it builds those directories around the file and returns the ROOT
// directory's CID. That is exactly what broke Moment #3 "0N1 Force NFT" — the old code named the pin
// `dyorhq/<wallet>/<file>`, so the on-chain image was a directory listing (HTML), which OpenSea and the app cannot
// render, and the on-chain URI is immutable. Verified directly against the API (2026-09-22): a slash-free metadata
// name + a bare basename + wrapWithDirectory:false returns the bare file CID with MimeType image/jpeg; a name with a
// slash returns a directory CID even with wrapWithDirectory:false. Belt and braces, the returned CID is then checked
// to actually serve file bytes on the account's dedicated gateway before it is handed to the app; a CID that only
// resolves as a directory is pointed at the file inside it, and one that resolves as neither is refused (502) so the
// app falls back to the working https URL rather than writing a broken URI on-chain.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "https://fmnjqrguvopusfufmirs.supabase.co";
const PINATA = "https://api.pinata.cloud/pinning/pinFileToIPFS";
// The account's dedicated gateway (restricted to this account's pins) serves a fresh pin within a second; the public
// gateway is the fallback when the dedicated one is unavailable. PINATA_GATEWAY overrides the dedicated hostname.
const DEDICATED_GATEWAY = Deno.env.get("PINATA_GATEWAY") ?? "scarlet-secure-kangaroo-820.mypinata.cloud";
const PUBLIC_GATEWAY = "gateway.pinata.cloud";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
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

// True if the URL serves actual file bytes (not a UnixFS directory index, which gateways render as HTML). Bounded so
// a slow gateway can never stall the app's publish flow (the app gives the whole call 30 s).
async function servesFile(url: string, timeoutMs = 8_000): Promise<boolean> {
  try {
    const r = await fetch(url, { method: "GET", headers: { Range: "bytes=0-0" }, signal: AbortSignal.timeout(timeoutMs) });
    const ct = (r.headers.get("content-type") || "").toLowerCase();
    await r.body?.cancel();
    if (!r.ok && r.status !== 206) return false;
    return !ct.includes("text/html") && !ct.includes("application/x-directory");
  } catch { return false; }
}

// The first of `paths` (relative to a CID) that serves file bytes on the dedicated gateway, else on the public one.
async function resolvableFilePath(cid: string, paths: string[]): Promise<string | null> {
  for (const host of [DEDICATED_GATEWAY, PUBLIC_GATEWAY]) {
    for (const p of paths) {
      if (await servesFile(`https://${host}/ipfs/${cid}${p}`)) return p;
    }
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const role = claims(req.headers.get("authorization") ?? "").role;
  if (role !== "authenticated") return json({ error: "a signed-in wallet session is required" }, 403);

  const jwt = Deno.env.get("PINATA_JWT");
  if (!jwt) return json({ error: "PINATA_JWT is not configured" }, 500);

  let payload: { bucket?: string; path?: string };
  try { payload = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  const bucket = payload.bucket ?? "launch-media";
  const path = (payload.path ?? "").replace(/^\/+/, "");
  if (!path || path.includes("..")) return json({ error: "a bucket-relative object path is required" }, 400);

  // Pull the bytes from the public bucket (the app already uploaded them there).
  const src = `${SUPABASE_URL}/storage/v1/object/public/${bucket}/${path}`;
  let obj: Response;
  try { obj = await fetch(src, { signal: AbortSignal.timeout(20_000) }); } catch { return json({ error: "could not read the object", src }, 502); }
  if (!obj.ok) return json({ error: `object not found (${obj.status})`, src }, 404);
  const bytes = new Uint8Array(await obj.arrayBuffer());
  const contentType = obj.headers.get("content-type") ?? "application/octet-stream";
  // Bare basename with NO slash, used for both the multipart filename and the pin's metadata name — a "/" in either
  // makes Pinata build wrapper directories and return the directory's CID instead of the file's.
  const name = (path.split("/").pop() || "media").replace(/[^A-Za-z0-9._-]/g, "_");

  const form = new FormData();
  form.append("file", new Blob([bytes], { type: contentType }), name);
  form.append("pinataOptions", JSON.stringify({ cidVersion: 1, wrapWithDirectory: false }));
  // The bucket path goes in keyvalues (free-form tags), never in `name`.
  form.append("pinataMetadata", JSON.stringify({ name, keyvalues: { app: "dyorhq", bucket, path } }));

  let res: Response;
  let text: string;
  try {
    res = await fetch(PINATA, { method: "POST", headers: { Authorization: `Bearer ${jwt}` }, body: form, signal: AbortSignal.timeout(60_000) });
    text = await res.text();
  } catch (e) {
    return json({ error: "pinata did not answer", detail: String(e).slice(0, 200) }, 502);
  }
  if (!res.ok) return json({ error: `pinata responded ${res.status}`, detail: text.slice(0, 300) }, 502);
  let cid = "";
  let mime = "";
  try { const parsed = JSON.parse(text); cid = parsed.IpfsHash ?? ""; mime = parsed.MimeType ?? ""; } catch { /* fall through */ }
  if (!cid) return json({ error: "pinata returned no CID", detail: text.slice(0, 300) }, 502);

  // Guarantee the on-chain URI resolves to the media itself. Pinata reports MimeType "directory" when it wrapped the
  // file; either way the gateway is the arbiter.
  const filePath = await resolvableFilePath(cid, mime === "directory" ? [`/${name}`, ""] : ["", `/${name}`]);
  if (filePath === null) {
    // Nothing resolvable — refuse, so the app writes the (working) https URL on-chain instead of a broken URI.
    return json({ error: "pinned content did not resolve to a file", cid, mime }, 502);
  }
  const uri = `ipfs://${cid}${filePath}`;
  return json({ cid, uri, contentType, wrapped: filePath !== "" });
});
