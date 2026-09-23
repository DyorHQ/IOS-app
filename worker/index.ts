/** Cloudflare Worker entry point for the vinext-starter template. */
import { handleImageOptimization, DEFAULT_DEVICE_SIZES, DEFAULT_IMAGE_SIZES } from "vinext/server/image-optimization";
import handler from "vinext/server/app-router-entry";

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

/* The relay forwards only what the app's own socket sends (app/lib/perps/ws.ts): a ping (mt 1) and a subscription
   (mt 5) to one market's order book and trades plus Monad's market state. Each allowed message is re-serialized from
   its checked fields; anything else closes the socket, so the Worker is not a general-purpose Perpl relay. */
const PERPL_STREAM = /^(?:order-book@\d{1,6}|trades@\d{1,6}|market-state@143)$/;

function perplClientMessage(data: unknown): string | null {
  if (typeof data !== "string" || data.length > 2048) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(data);
  } catch {
    return null;
  }
  // null, numbers, strings and arrays are not messages (reading .mt of null would throw inside the listener).
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const msg = parsed as { mt?: unknown; subs?: unknown };
  if (msg.mt === 1) return JSON.stringify({ mt: 1 });
  if (msg.mt !== 5 || !Array.isArray(msg.subs) || msg.subs.length === 0 || msg.subs.length > 8) return null;
  const subs: { stream: string; subscribe: boolean }[] = [];
  for (const sub of msg.subs as { stream?: unknown; subscribe?: unknown }[]) {
    if (typeof sub?.stream !== "string" || !PERPL_STREAM.test(sub.stream) || typeof sub.subscribe !== "boolean") return null;
    subs.push({ stream: sub.stream, subscribe: sub.subscribe });
  }
  return JSON.stringify({ mt: 5, subs });
}

async function proxyPerplSocket(): Promise<Response> {
  const upstream = await fetch(PERPL_WS, { headers: { Upgrade: "websocket" } });
  const remote = (upstream as Response & { webSocket?: WebSocket | null }).webSocket;
  if (!remote) return new Response(`Perpl refused the socket (${upstream.status})`, { status: 502 });
  const pair = new WebSocketPair();
  const [client, server] = [pair[0], pair[1]];
  const accept = (socket: WebSocket) => (socket as WebSocket & { accept?: () => void }).accept?.();
  accept(server);
  accept(remote);
  server.addEventListener("message", (e) => {
    const allowed = perplClientMessage(e.data);
    if (allowed === null) {
      try { server.close(1008, "Message not allowed"); } catch { /* already closing */ }
      try { remote.close(); } catch { /* already closing */ }
      return;
    }
    try { remote.send(allowed); } catch { /* remote closed */ }
  });
  remote.addEventListener("message", (e) => { try { server.send(e.data); } catch { /* client closed */ } });
  server.addEventListener("close", () => remote.close());
  remote.addEventListener("close", () => server.close());
  server.addEventListener("error", () => remote.close());
  remote.addEventListener("error", () => server.close());
  return new Response(null, { status: 101, webSocket: client } as ResponseInit & { webSocket: WebSocket });
}

/* Security headers on every response the Worker generates (static files get the same set from public/_headers).
   Framing is the only thing the CSP restricts: a script policy would fight the wallet extensions that inject
   providers and open popups, so none is set. */
const SECURITY_HEADERS: Record<string, string> = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Frame-Options": "DENY",
  "Content-Security-Policy": "frame-ancestors 'none'",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
};

function withSecurityHeaders(response: Response): Response {
  // A WebSocket handshake (101) cannot be rebuilt and serves no document.
  if (response.status === 101) return response;
  const secured = new Response(response.body, response);
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
    if (!secured.headers.has(name)) secured.headers.set(name, value);
  }
  return secured;
}

const app = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    // Perpl's market-data WebSocket only accepts its own origin, so browsers connect here and the Worker
    // bridges the socket to Perpl without an Origin header (Cloudflare Workers can dial WebSockets with fetch).
    // Only this app's pages may open it: browsers always send Origin on a WebSocket handshake.
    if (url.pathname === "/api/perpl/ws" && request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      if (request.method !== "GET") return new Response("Method not allowed", { status: 405, headers: { allow: "GET" } });
      if (request.headers.get("Origin") !== url.origin) return new Response("Forbidden", { status: 403 });
      return proxyPerplSocket();
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

    return handler.fetch(request, env, ctx);
  },
};

const worker = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return withSecurityHeaders(await app.fetch(request, env, ctx));
  },
};

export default worker;
