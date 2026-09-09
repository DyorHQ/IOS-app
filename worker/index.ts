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

async function proxyPerplSocket(): Promise<Response> {
  const upstream = await fetch(PERPL_WS, { headers: { Upgrade: "websocket" } });
  const remote = (upstream as Response & { webSocket?: WebSocket | null }).webSocket;
  if (!remote) return new Response(`Perpl refused the socket (${upstream.status})`, { status: 502 });
  const pair = new WebSocketPair();
  const [client, server] = [pair[0], pair[1]];
  const accept = (socket: WebSocket) => (socket as WebSocket & { accept?: () => void }).accept?.();
  accept(server);
  accept(remote);
  server.addEventListener("message", (e) => { try { remote.send(e.data); } catch { /* remote closed */ } });
  remote.addEventListener("message", (e) => { try { server.send(e.data); } catch { /* client closed */ } });
  server.addEventListener("close", () => remote.close());
  remote.addEventListener("close", () => server.close());
  server.addEventListener("error", () => remote.close());
  remote.addEventListener("error", () => server.close());
  return new Response(null, { status: 101, webSocket: client } as ResponseInit & { webSocket: WebSocket });
}

const worker = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    // Perpl's market-data WebSocket only accepts its own origin, so browsers connect here and the Worker
    // bridges the socket to Perpl without an Origin header (Cloudflare Workers can dial WebSockets with fetch).
    if (url.pathname === "/api/perpl/ws" && request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
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

export default worker;
