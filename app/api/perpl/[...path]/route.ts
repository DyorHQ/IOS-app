import { isCandlesRoute } from "../../../lib/perps/candles";

/* Read-only proxy for the public Perpl REST endpoints the web app reads: the market context (24h reference price and
   volume per market, app/lib/perps/perpl.ts) and a market's candles (app/lib/perps/candles.ts; the charts). Perpl's API
   does not send CORS headers for them, so the browser reaches them through this Worker route instead. Nothing else is
   relayed: no other upstream path (candle paths must name a listed market and resolution over an aligned window), no
   query string, and no request from another site (Origin / Sec-Fetch-Site), so the route cannot be used as a general
   Perpl proxy. Scripted clients can fake those headers; the Cloudflare rate-limit rule on /api/perpl/* caps them. */
const UPSTREAM = "https://app.perpl.xyz/api";
const CONTEXT_ROUTE = "v1/pub/context";

function fromThisSite(request: Request): boolean {
  const origin = request.headers.get("origin");
  if (origin !== null && origin !== new URL(request.url).origin) return false;
  const site = request.headers.get("sec-fetch-site");
  return site === null || site === "same-origin" || site === "none";
}

export async function GET(request: Request, context: { params: Promise<{ path: string[] }> }) {
  const { path } = await context.params;
  const route = path.join("/");
  const candles = isCandlesRoute(route);
  if (route !== CONTEXT_ROUTE && !candles) return Response.json({ error: "Only the Perpl market context and candles are proxied." }, { status: 404 });
  if (!fromThisSite(request)) return Response.json({ error: "Cross-site requests are not proxied." }, { status: 403 });
  let upstream: Response;
  try {
    upstream = await fetch(`${UPSTREAM}/${route}`, { headers: { accept: "application/json" } });
  } catch {
    return Response.json({ error: "Perpl is unreachable." }, { status: 502 });
  }
  const body = await upstream.text();
  // Always served as JSON (never Perpl's own content type), so an upstream error page cannot render on this origin.
  return new Response(body, {
    status: upstream.status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": candles ? "public, max-age=15" : "public, max-age=3" },
  });
}
