/* Minimal ambient types for the Cloudflare runtime used by worker/index.ts and db/index.ts.
   Replace with @cloudflare/workers-types if the app grows more bindings. */
interface Fetcher {
  fetch(input: Request | string, init?: RequestInit): Promise<Response>;
}
interface D1PreparedStatement {
  bind(...values: unknown[]): D1PreparedStatement;
  all<T = unknown>(): Promise<{ results: T[] }>;
  run(): Promise<unknown>;
  first<T = unknown>(): Promise<T | null>;
}
interface D1Database {
  prepare(query: string): D1PreparedStatement;
  batch(statements: D1PreparedStatement[]): Promise<unknown[]>;
  exec(query: string): Promise<unknown>;
}
declare module "cloudflare:workers" {
  export const env: { DB?: D1Database; ASSETS?: Fetcher } & Record<string, unknown>;
}

declare class WebSocketPair {
  0: WebSocket;
  1: WebSocket;
}
