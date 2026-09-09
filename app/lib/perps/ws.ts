"use client";

import { useEffect, useState } from "react";
import { PERPL } from "./perpl";

/* Perpl public market data over WebSocket: L2 book, trades and per-market state. One socket per hook instance,
   pings every 30 s, resubscribes on reconnect. Values arrive scaled by the market's price/size decimals. */

export type Level = { p: number; s: number; o: number };
export type Trade = { t: number; p: number; s: number; side: "buy" | "sell"; tx?: string };
export type MarketState = { orl: number; mrk: number; lst: number; mid: number; bid: number; ask: number; prv: number; dv: number; oi: number };
export type Book = { bids: Level[]; asks: Level[] };
export type Feed = { book: Book; trades: Trade[]; state: MarketState | null; connected: boolean; error: string | null };

type RawLevel = { p: number; s: number; o: number };
type Msg = { mt: number; sid?: number; bid?: RawLevel[]; ask?: RawLevel[]; d?: unknown; subs?: unknown[] };

function applyLevels(current: Level[], updates: RawLevel[], descending: boolean): Level[] {
  const map = new Map(current.map((l) => [l.p, l]));
  for (const u of updates) {
    if (u.o === 0 || u.s === 0) map.delete(u.p);
    else map.set(u.p, { p: u.p, s: u.s, o: u.o });
  }
  return [...map.values()].sort((a, b) => (descending ? b.p - a.p : a.p - b.p)).slice(0, 40);
}

const empty: Feed = { book: { bids: [], asks: [] }, trades: [], state: null, connected: false, error: null };

export function usePerplFeed(marketId: number | null): Feed {
  const [feed, setFeed] = useState<Feed>(empty);
  useEffect(() => {
    if (marketId === null || typeof window === "undefined") return;
    let ws: WebSocket | null = null;
    let closed = false;
    let ping: ReturnType<typeof setInterval> | null = null;
    let retry: ReturnType<typeof setTimeout> | null = null;
    const connect = () => {
      const url = PERPL.ws.startsWith("/") ? `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}${PERPL.ws}` : PERPL.ws;
      ws = new WebSocket(url);
      ws.onopen = () => {
        ws?.send(JSON.stringify({ mt: 5, subs: [{ stream: `order-book@${marketId}`, subscribe: true }, { stream: `trades@${marketId}`, subscribe: true }, { stream: "market-state@143", subscribe: true }] }));
        ping = setInterval(() => ws?.send(JSON.stringify({ mt: 1 })), 30_000);
        setFeed((f) => ({ ...f, connected: true, error: null }));
      };
      ws.onmessage = (e) => {
        const m = JSON.parse(e.data) as Msg;
        if (m.mt === 15) setFeed((f) => ({ ...f, book: { bids: applyLevels([], m.bid ?? [], true), asks: applyLevels([], m.ask ?? [], false) } }));
        else if (m.mt === 16) setFeed((f) => ({ ...f, book: { bids: applyLevels(f.book.bids, m.bid ?? [], true), asks: applyLevels(f.book.asks, m.ask ?? [], false) } }));
        else if (m.mt === 17 || m.mt === 18) {
          const d = (m.d ?? []) as { at: { t: number; txid?: string }; p: number; s: number; sd: number }[];
          const incoming: Trade[] = d.map((t) => ({ t: t.at.t, p: t.p, s: t.s, side: t.sd === 1 ? "buy" : "sell", tx: t.at.txid }));
          setFeed((f) => ({ ...f, trades: (m.mt === 17 ? incoming : [...incoming, ...f.trades]).slice(0, 60) }));
        } else if (m.mt === 9) {
          const d = m.d as Record<string, MarketState> | undefined;
          const s = d?.[String(marketId)];
          if (s) setFeed((f) => ({ ...f, state: s }));
        }
      };
      ws.onerror = () => setFeed((f) => ({ ...f, error: "Perpl market data unavailable" }));
      ws.onclose = () => {
        if (ping) clearInterval(ping);
        setFeed((f) => ({ ...f, connected: false }));
        if (!closed) retry = setTimeout(connect, 3000);
      };
    };
    connect();
    return () => {
      closed = true;
      if (ping) clearInterval(ping);
      if (retry) clearTimeout(retry);
      ws?.close();
      setFeed(empty);
    };
  }, [marketId]);
  return feed;
}
