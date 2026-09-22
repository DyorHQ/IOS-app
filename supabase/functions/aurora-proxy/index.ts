// aurora-proxy: the Bridge's only route to the Aurora Intents Swap API. It holds the Aurora API key server-side
// (Supabase secret AURORA_API_KEY) so the key never ships inside the app, and forwards ONLY the four endpoints the
// bridge uses. verify_jwt=true gates to a valid Supabase JWT; we additionally require role 'authenticated' so the
// public anon/publishable key (role 'anon') cannot use it — only a signed-in DyorHQ wallet session qualifies (the same
// rule as pin-media). The key is appended as Aurora's path segment here, and scrubbed from every response body, since
// Aurora's error bodies can echo the request path.
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

  const role = claims(req.headers.get("authorization") ?? "").role;
  if (role !== "authenticated") return json({ error: "a signed-in wallet session is required" }, 403);

  const key = Deno.env.get("AURORA_API_KEY");
  if (!key) return json({ error: "bridge not configured" }, 503);

  // The runtime path is /aurora-proxy/<route> (or /functions/v1/aurora-proxy/<route> behind the gateway).
  const url = new URL(req.url);
  const route = url.pathname.replace(/^.*\/aurora-proxy\/?/, "").replace(/\/+$/, "");
  const method = ROUTES[route];
  if (!method) return json({ error: "unknown route" }, 404);
  if (req.method !== method) return json({ error: "method not allowed" }, 405);

  const target = new URL(`${AURORA}/${route}/${encodeURIComponent(key)}`);
  if (route === "status") {
    for (const [name, value] of url.searchParams) if (STATUS_QUERY.has(name)) target.searchParams.set(name, value);
    if (!target.searchParams.get("depositAddress")) return json({ error: "depositAddress is required" }, 400);
  }

  let body: string | undefined;
  if (method === "POST") {
    body = await req.text();
    if (body.length > MAX_BODY) return json({ error: "request too large" }, 413);
    try { JSON.parse(body); } catch { return json({ error: "invalid json" }, 400); }
  }

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
  const text = (await upstream.text()).split(key).join("[redacted]");
  return new Response(text, { status: upstream.status, headers: { ...cors, "Content-Type": "application/json" } });
});
