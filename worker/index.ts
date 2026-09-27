/** Cloudflare Worker entry point for the vinext-starter template. */
import { handleImageOptimization, DEFAULT_DEVICE_SIZES, DEFAULT_IMAGE_SIZES } from "vinext/server/image-optimization";
import handler from "vinext/server/app-router-entry";
import { RPC_URL } from "../app/lib/chain";
import { LOGS_RPC } from "../app/lib/moments/config";
import { KURU } from "../app/lib/swap/config";
import { contentSecurityPolicy, newNonce, sourceOrigin } from "./csp";
import { createRelayGate } from "./perpl-relay";
import { PERPL_REQUESTS_PER_MINUTE, PERPL_SOCKETS_PER_CLIENT, PERPL_SOCKET_OPENS_PER_MINUTE, clientKey, createSlotLimiter, createWindowLimiter } from "./rate-limit";

interface Env {
  ASSETS: Fetcher;
  DB: D1Database;
  IMAGES: {
    input(stream: ReadableStream): {
      transform(options: Record<string, unknown>): {
        output(options: { format: string; quality: number }): Promise<{ response(): Response }>;
      };
    };
  };
}

interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
}

// Image security config. SVG sources with .svg extension auto-skip the
// optimization endpoint on the client side (served directly, no proxy).
// To route SVGs through the optimizer (with security headers), set
// dangerouslyAllowSVG: true in next.config.js and uncomment below:
// const imageConfig: ImageConfig = { dangerouslyAllowSVG: true };


const PERPL_WS = "https://app.perpl.xyz/ws/v1/market-data";

// Per-client caps on the Perpl relays, in this isolate's memory (worker/rate-limit.ts).
const perplRequests = createWindowLimiter(PERPL_REQUESTS_PER_MINUTE, 60_000);
const perplSocketOpens = createWindowLimiter(PERPL_SOCKET_OPENS_PER_MINUTE, 60_000);
const perplSockets = createSlotLimiter(PERPL_SOCKETS_PER_CLIENT);
const tooMany = (what: string) =>
  Response.json({ error: `Too many ${what} from this address. Try again in a minute.` }, { status: 429, headers: { "retry-after": "60" } });

/** Bridges one socket to Perpl; `release` frees the client's socket slot once either side closes. */
async function proxyPerplSocket(release: () => void): Promise<Response> {
  let upstream: Response;
  try {
    upstream = await fetch(PERPL_WS, { headers: { Upgrade: "websocket" } });
  } catch {
    release();
    return new Response("Perpl did not answer", { status: 502 });
  }
  const remote = (upstream as Response & { webSocket?: WebSocket | null }).webSocket;
  if (!remote) {
    release();
    return new Response(`Perpl refused the socket (${upstream.status})`, { status: 502 });
  }
  const gate = createRelayGate();
  const pair = new WebSocketPair();
  const [client, server] = [pair[0], pair[1]];
  const accept = (socket: WebSocket) => (socket as WebSocket & { accept?: () => void }).accept?.();
  accept(server);
  accept(remote);
  server.addEventListener("message", (e) => {
    const allowed = gate(e.data);
    if (allowed === null) {
      try { server.close(1008, "Message not allowed"); } catch { /* already closing */ }
      try { remote.close(); } catch { /* already closing */ }
      return;
    }
    try { remote.send(allowed); } catch { /* remote closed */ }
  });
  remote.addEventListener("message", (e) => { try { server.send(e.data); } catch { /* client closed */ } });
  server.addEventListener("close", () => { release(); remote.close(); });
  remote.addEventListener("close", () => { release(); server.close(); });
  server.addEventListener("error", () => { release(); remote.close(); });
  remote.addEventListener("error", () => { release(); server.close(); });
  return new Response(null, { status: 101, webSocket: client } as ResponseInit & { webSocket: WebSocket });
}

/* Security headers on every response the Worker generates (static files get the same set from public/_headers).
   The enforced CSP restricts framing only; the full policy (worker/csp.ts) ships report-only until a release shows
   the app itself raises no reports. */
const SECURITY_HEADERS: Record<string, string> = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Frame-Options": "DENY",
  "Content-Security-Policy": "frame-ancestors 'none'",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
};

/** Every origin the browser code connects to besides this one: the configured and log-scan Monad RPCs, Kuru Flow. */
const CONNECT_SOURCES = [RPC_URL, "https://rpc1.monad.xyz", LOGS_RPC, KURU.api].map(sourceOrigin).filter((s): s is string => s !== null);

function withSecurityHeaders(response: Response, policy: string): Response {
  // A WebSocket handshake (101) cannot be rebuilt and serves no document.
  if (response.status === 101) return response;
  const secured = new Response(response.body, response);
  for (const [name, value] of Object.entries({ ...SECURITY_HEADERS, "Content-Security-Policy-Report-Only": policy })) {
    if (!secured.headers.has(name)) secured.headers.set(name, value);
  }
  return secured;
}

/** Page requests reach vinext with headers only the Worker sets, replacing any the client sent: the CSP carrying this
    response's nonce (vinext stamps its inline scripts with the nonce it finds there, the Next.js convention), and the
    host and scheme the request really came in on (app/layout.tsx builds share links from them). */
function forRender(request: Request, policy: string): Request {
  if (request.method !== "GET" && request.method !== "HEAD") return request;
  const url = new URL(request.url);
  const headers = new Headers(request.headers);
  headers.delete("content-security-policy");
  headers.set("content-security-policy-report-only", policy);
  headers.set("x-forwarded-host", url.host);
  headers.set("x-forwarded-proto", url.protocol.slice(0, -1));
  return new Request(request, { headers });
}

const app = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext, policy: string): Promise<Response> {
    const url = new URL(request.url);

    // Perpl's market-data WebSocket only accepts its own origin, so browsers connect here and the Worker
    // bridges the socket to Perpl without an Origin header (Cloudflare Workers can dial WebSockets with fetch).
    // Only this app's pages may open it: browsers always send Origin on a WebSocket handshake. A script can forge
    // Origin, so each client also has a cap on sockets held and opened, and on REST reads through /api/perpl/*.
    if (url.pathname === "/api/perpl/ws" && request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      if (request.method !== "GET") return new Response("Method not allowed", { status: 405, headers: { allow: "GET" } });
      if (request.headers.get("Origin") !== url.origin) return new Response("Forbidden", { status: 403 });
      const client = clientKey(request);
      if (client === null) return proxyPerplSocket(() => undefined);
      if (!perplSocketOpens(client)) return tooMany("Perpl sockets opened");
      const release = perplSockets.acquire(client);
      if (!release) return tooMany("open Perpl sockets");
      return proxyPerplSocket(release);
    }
    if (url.pathname.startsWith("/api/perpl/")) {
      const client = clientKey(request);
      if (client !== null && !perplRequests(client)) return tooMany("Perpl requests");
    }
    if (url.pathname === "/_vinext/image") {
      const allowedWidths = [...DEFAULT_DEVICE_SIZES, ...DEFAULT_IMAGE_SIZES];
      return handleImageOptimization(request, {
        fetchAsset: (path) => env.ASSETS.fetch(new Request(new URL(path, request.url))),
        transformImage: async (body, { width, format, quality }) => {
          const result = await env.IMAGES.input(body).transform(width > 0 ? { width } : {}).output({ format, quality });
          return result.response();
        },
      }, allowedWidths);
    }

    return handler.fetch(forRender(request, policy), env, ctx);
  },
};

const worker = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const policy = contentSecurityPolicy({ nonce: newNonce(), host: new URL(request.url).host, connect: CONNECT_SOURCES });
    return withSecurityHeaders(await app.fetch(request, env, ctx, policy), policy);
  },
};

export default worker;
