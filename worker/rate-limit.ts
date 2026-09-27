/* Per-client limits for the Perpl relays (worker/index.ts), keyed on the client IP that Cloudflare's edge sets in
   CF-Connecting-IP (a client can't choose it). They are counted in this isolate's memory, so they bound one client's
   burst on the isolates it reaches rather than being a global quota; an edge rate-limit rule on /api/perpl/* is the
   global cap (docs/security-audit-2026-09-26/RUNBOOKS.md). A request without the header is not counted: it can't be
   told apart from other clients, and one shared key would throttle everyone. The limits sit far above what the app
   sends (one viewer reads a few REST URLs a minute and holds one socket), so a household or office behind one address
   is not affected. */

/** REST reads through /api/perpl/* per client per minute. */
export const PERPL_REQUESTS_PER_MINUTE = 120;
/** Relay sockets one client may hold open at once. */
export const PERPL_SOCKETS_PER_CLIENT = 8;
/** Relay sockets one client may open per minute (a reconnect loop backs off far below this). */
export const PERPL_SOCKET_OPENS_PER_MINUTE = 20;

const MAX_CLIENTS = 10_000;

/** A fixed-window counter per key: true while `key` is within `limit` calls in the current window. Memory stays bounded:
    once `maxKeys` clients are tracked, expired windows are dropped, and if all are live the table starts over. */
export function createWindowLimiter(limit: number, windowMs: number, maxKeys = MAX_CLIENTS) {
  const windows = new Map<string, { start: number; count: number }>();
  return (key: string, now = Date.now()): boolean => {
    let window = windows.get(key);
    if (!window || now - window.start >= windowMs) {
      if (!window && windows.size >= maxKeys) {
        for (const [k, w] of windows) if (now - w.start >= windowMs) windows.delete(k);
        if (windows.size >= maxKeys) windows.clear();
      }
      window = { start: now, count: 0 };
      windows.set(key, window);
    }
    return ++window.count <= limit;
  };
}

/** Open slots per key: `acquire` returns the slot's release (safe to call more than once), or null when `key` already
    holds `limit` slots. */
export function createSlotLimiter(limit: number) {
  const open = new Map<string, number>();
  return {
    acquire(key: string): (() => void) | null {
      const held = open.get(key) ?? 0;
      if (held >= limit) return null;
      open.set(key, held + 1);
      let released = false;
      return () => {
        if (released) return;
        released = true;
        const left = (open.get(key) ?? 1) - 1;
        if (left > 0) open.set(key, left);
        else open.delete(key);
      };
    },
    held: (key: string) => open.get(key) ?? 0,
  };
}

/** The client key for a request: Cloudflare's CF-Connecting-IP, or null when the request did not come through the edge. */
export const clientKey = (request: Request): string | null => request.headers.get("cf-connecting-ip")?.trim() || null;
