import { isCandlesRoute } from "../../../lib/perps/candles";

/* Read-only proxy for the public Perpl REST endpoints the web app reads: the market context (24h reference price and
   volume per market, app/lib/perps/perpl.ts) and a market's candles (app/lib/perps/candles.ts; the charts). Perpl's API
   does not send CORS headers for them, so the browser reaches them through this Worker route instead. Nothing else is
   relayed: no other upstream path (candle paths must name a listed market and resolution over the current window), no
   query string, and no request from another site (Origin / Sec-Fetch-Site), so the route cannot be used as a general
   Perpl proxy. Scripted clients can fake those headers, so every valid URL is the same for all viewers and is answered
   from the edge cache while it is fresh: many clients, one upstream read. */
const UPSTREAM = "https://app.perpl.xyz/api";
const CONTEXT_ROUTE = "v1/pub/context";

function fromThisSite(request: Request): boolean {
  const origin = request.headers.get("origin");
  if (origin !== null && origin !== new URL(request.url).origin) return false;
  const site = request.headers.get("sec-fetch-site");
  return site === null || site === "same-origin" || site === "none";
}

/** Cloudflare's edge cache (the Workers Cache API), when the runtime provides one; elsewhere every read goes upstream. */
function edgeCache(): Cache | null {
  return (globalThis as { caches?: { default?: Cache } }).caches?.default ?? null;
}

async function cached(key: Request): Promise<Response | null> {
  try {
    return (await edgeCache()?.match(key)) ?? null;
  } catch {
    return null;
  }
}

async function keep(key: Request, response: Response): Promise<void> {
  try {
    await edgeCache()?.put(key, response);
  } catch {
    /* No usable edge cache here: the next read goes upstream. */
  }
}

export async function GET(request: Request, context: { params: Promise<{ path: string[] }> }) {
  const { path } = await context.params;
  const route = path.join("/");
  const candles = isCandlesRoute(route);
  if (route !== CONTEXT_ROUTE && !candles) return Response.json({ error: "Only the Perpl market context and candles are proxied." }, { status: 404 });
  if (!fromThisSite(request)) return Response.json({ error: "Cross-site requests are not proxied." }, { status: 403 });
  // Keyed on the validated route alone (never the client's query string or headers), and kept for its max-age.
  const key = new Request(`${new URL(request.url).origin}/api/perpl/${route}`);
  const hit = await cached(key);
  if (hit) return new Response(hit.body, hit);
  let upstream: Response;
  try {
    upstream = await fetch(`${UPSTREAM}/${route}`, { headers: { accept: "application/json" } });
  } catch {
    return Response.json({ error: "Perpl is unreachable." }, { status: 502 });
  }
  const body = await upstream.text();
  // Always served as JSON (never Perpl's own content type), so an upstream error page cannot render on this origin.
  const response = new Response(body, {
    status: upstream.status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": candles ? "public, max-age=15" : "public, max-age=3" },
  });
  if (upstream.ok) await keep(key, response.clone());
  return response;
}
