/* What the Perpl market-data relay (worker/index.ts) lets a browser socket send upstream. The relay forwards only what
   the app's own socket sends (app/lib/perps/ws.ts): a ping (mt 1) and a subscription (mt 5) to one market's order book
   and trades plus Monad's market state. Each allowed message is re-serialized from its checked fields; anything else
   closes the socket, so the Worker is not a general-purpose Perpl relay. */

const PERPL_STREAM = /^(?:order-book@\d{1,6}|trades@\d{1,6}|market-state@143)$/;

/** Checks one client frame; returns the re-serialized message to forward, or null for anything the app never sends. */
export function perplClientMessage(data: unknown): string | null {
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

/* The app's socket carries one market (three streams), subscribes once, pings every 30 s, and opens a new socket to
   switch market. A socket beyond these limits is not the app: it is using the Worker as a market-data firehose. */
/** Distinct streams open at once. */
export const MAX_STREAMS_PER_SOCKET = 8;
/** Stream subscriptions over the socket's whole life, so subscribe/unsubscribe churn can't walk every market. */
export const MAX_SUBSCRIBES_PER_SOCKET = 24;
/** Frames per minute (the app sends about two). */
export const MAX_MESSAGES_PER_MINUTE = 30;

/** One socket's gate: returns the frame to forward upstream, or null when the socket must be closed. */
export function createRelayGate() {
  const streams = new Set<string>();
  let subscribes = 0;
  let windowStart = -Infinity;
  let inWindow = 0;
  return (data: unknown, now = Date.now()): string | null => {
    if (now - windowStart >= 60_000) {
      windowStart = now;
      inWindow = 0;
    }
    if (++inWindow > MAX_MESSAGES_PER_MINUTE) return null;
    const allowed = perplClientMessage(data);
    if (allowed === null) return null;
    const { subs } = JSON.parse(allowed) as { subs?: { stream: string; subscribe: boolean }[] };
    for (const sub of subs ?? []) {
      if (sub.subscribe) {
        subscribes++;
        streams.add(sub.stream);
      } else streams.delete(sub.stream);
    }
    if (streams.size > MAX_STREAMS_PER_SOCKET || subscribes > MAX_SUBSCRIBES_PER_SOCKET) return null;
    return allowed;
  };
}
