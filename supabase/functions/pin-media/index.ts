// pin-media: pins an already-uploaded Moment media object from the public launch-media bucket to IPFS via Pinata, so
// the NFT's on-chain mediaURI can be a permanent ipfs:// CID instead of a mutable Supabase URL. The Pinata JWT lives
// only in this function's environment (Supabase secret PINATA_JWT). verify_jwt=true gates to a valid Supabase JWT; we
// additionally require role 'authenticated' so the public anon/publishable key (which passes verify_jwt but carries
// role 'anon') cannot be used to drain the Pinata quota. Only a signed-in DyorHQ wallet session qualifies.
//
// CRITICAL — return a FILE uri, never a DIRECTORY. Pinata's pinFileToIPFS wraps the uploaded file in a UnixFS
// directory and returns the DIRECTORY CID (and if the file name contains a "/", it builds nested directories). A
// directory CID written on-chain as an NFT "image" resolves to an HTML listing, not the image — OpenSea and the app
// then show a broken/placeholder image (this is exactly what broke Moment #3 "0N1 Force NFT"). So: pin with
// wrapWithDirectory:false and a bare basename, then VERIFY the returned CID actually serves the file bytes; if it
// resolves to a directory, point the uri at the file inside it; if neither works, fail (the app falls back to the
// working https URL). The on-chain URI is immutable, so it MUST be a resolvable file the first time.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "https://fmnjqrguvopusfufmirs.supabase.co";
const PINATA = "https://api.pinata.cloud/pinning/pinFileToIPFS";
const GATEWAY = "https://gateway.pinata.cloud/ipfs"; // Pinata serves its own pins immediately

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

// True if the URL serves actual file bytes (not a UnixFS directory index, which Pinata's gateway renders as HTML).
async function servesFile(url: string): Promise<boolean> {
  try {
    const r = await fetch(url, { method: "GET", headers: { Range: "bytes=0-0" } });
    if (!r.ok && r.status !== 206) { await r.body?.cancel(); return false; }
    const ct = (r.headers.get("content-type") || "").toLowerCase();
    await r.body?.cancel();
    return !ct.includes("text/html") && !ct.includes("application/x-directory");
  } catch { return false; }
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
  const obj = await fetch(src);
  if (!obj.ok) return json({ error: `object not found (${obj.status})`, src }, 404);
  const bytes = new Uint8Array(await obj.arrayBuffer());
  const contentType = obj.headers.get("content-type") ?? "application/octet-stream";
  // Bare basename with NO slash — a "/" would make Pinata build nested wrapper directories.
  const name = (path.split("/").pop() || "media").replace(/[^A-Za-z0-9._-]/g, "_");

  const form = new FormData();
  form.append("file", new Blob([bytes], { type: contentType }), name);
  // wrapWithDirectory:false asks Pinata for the FILE's CID, not a wrapping directory.
  form.append("pinataOptions", JSON.stringify({ cidVersion: 1, wrapWithDirectory: false }));
  form.append("pinataMetadata", JSON.stringify({ name: `dyorhq/${path}` }));

  const res = await fetch(PINATA, { method: "POST", headers: { Authorization: `Bearer ${jwt}` }, body: form });
  const text = await res.text();
  if (!res.ok) return json({ error: `pinata responded ${res.status}`, detail: text.slice(0, 300) }, 502);
  let cid = "";
  try { cid = JSON.parse(text).IpfsHash ?? ""; } catch { /* fall through */ }
  if (!cid) return json({ error: "pinata returned no CID", detail: text.slice(0, 300) }, 502);

  // Guarantee the on-chain URI resolves to the image itself, not a directory listing.
  let uri = `ipfs://${cid}`;
  if (!(await servesFile(`${GATEWAY}/${cid}`))) {
    if (await servesFile(`${GATEWAY}/${cid}/${name}`)) {
      uri = `ipfs://${cid}/${name}`;
    } else {
      // The pin didn't yield a resolvable file — refuse it so the app falls back to the (working) https URL rather
      // than writing a broken directory URI on-chain, which is immutable.
      return json({ error: "pinned content did not resolve to a file", cid }, 502);
    }
  }

  return json({ cid, uri, contentType });
});
