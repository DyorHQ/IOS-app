/* Read-only proxy for Perpl's public REST endpoints (context, candles, funding). Perpl's API does not send CORS
   headers for these routes, so the browser reaches them through this Worker route instead. */
const UPSTREAM = "https://app.perpl.xyz/api";

export async function GET(request: Request, context: { params: Promise<{ path: string[] }> }) {
  const { path } = await context.params;
  const publicRoute = path[0] === "v1" && (path[1] === "pub" || path[1] === "market-data");
  if (!publicRoute) return Response.json({ error: "Only public Perpl routes are proxied." }, { status: 404 });
  const url = new URL(request.url);
  const upstream = await fetch(`${UPSTREAM}/${path.map(encodeURIComponent).join("/")}${url.search}`, { headers: { accept: "application/json" } });
  const body = await upstream.text();
  return new Response(body, {
    status: upstream.status,
    headers: { "content-type": upstream.headers.get("content-type") ?? "application/json", "cache-control": "public, max-age=3" },
  });
}
