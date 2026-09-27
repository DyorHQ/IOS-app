import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* app/lib/perps/ws.ts: the market-data socket reconnects with exponential backoff and jitter, not every 3 s forever;
   the backoff restarts only once data flows; and a stopped feed's socket is detached before it closes, so its late
   events can't reach the next market's feed. Sockets and timers are fakes; nothing leaves the process. */

const { reconnectDelay, connectPerplFeed } = await tsImport("../app/lib/perps/ws.ts", import.meta.url);

test("reconnects back off from 1 s to a 30 s ceiling", () => {
  const none = () => 0;
  assert.deepEqual([0, 1, 2, 3, 4, 5, 6, 12].map((n) => reconnectDelay(n, none)), [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000]);
});

test("jitter adds at most 20%", () => {
  assert.equal(reconnectDelay(0, () => 1), 1_200);
  assert.equal(reconnectDelay(10, () => 1), 36_000);
  for (let i = 0; i < 50; i++) {
    const d = reconnectDelay(3);
    assert.ok(d >= 8_000 && d <= 9_600, String(d));
  }
});

class FakeSocket {
  constructor(url) { this.url = url; this.readyState = 0; this.sent = []; this.closed = false; this.onopen = this.onmessage = this.onerror = this.onclose = null; }
  send(frame) { this.sent.push(JSON.parse(frame)); }
  close() { this.closed = true; this.readyState = 3; }
  // What the network does to the socket:
  opened() { this.readyState = 1; this.onopen?.(); }
  receive(msg) { this.onmessage?.({ data: JSON.stringify(msg) }); }
  dropped() { this.readyState = 3; this.onclose?.(); }
}

const runtime = () => {
  const sockets = [];
  const timers = [];
  return {
    sockets,
    timers,
    open: (url) => { const s = new FakeSocket(url); sockets.push(s); return s; },
    later: (fn, ms) => { const t = { fn, ms, cancelled: false, kind: "later" }; timers.push(t); return () => { t.cancelled = true; }; },
    every: (fn, ms) => { const t = { fn, ms, cancelled: false, kind: "every" }; timers.push(t); return () => { t.cancelled = true; }; },
    random: () => 0,
    retries: () => timers.filter((t) => t.kind === "later" && !t.cancelled),
    fire: (t) => { t.cancelled = true; t.fn(); },
  };
};
const EMPTY = { book: { bids: [], asks: [] }, trades: [], state: null, connected: false, error: null };
const feedOf = () => {
  let feed = EMPTY;
  return { update: (change) => { feed = change(feed); }, now: () => feed };
};

test("the feed subscribes to one market on open and pings on the socket's own timer", () => {
  const rt = runtime();
  const feed = feedOf();
  connectPerplFeed(20, "wss://app.example/api/perpl/ws", feed.update, rt);
  const [socket] = rt.sockets;
  socket.opened();
  assert.deepEqual(socket.sent[0], { mt: 5, subs: [{ stream: "order-book@20", subscribe: true }, { stream: "trades@20", subscribe: true }, { stream: "market-state@143", subscribe: true }] });
  const ping = rt.timers.find((t) => t.kind === "every");
  assert.equal(ping.ms, 30_000);
  ping.fn();
  assert.deepEqual(socket.sent[1], { mt: 1 });
  assert.equal(feed.now().connected, true);
});

test("the backoff grows while sockets open and drop without data, and restarts only once data flows", () => {
  const rt = runtime();
  const feed = feedOf();
  connectPerplFeed(10, "wss://x/ws", feed.update, rt);
  const delays = [];
  for (let i = 0; i < 3; i++) {
    const socket = rt.sockets.at(-1);
    socket.opened(); // accepted by the relay…
    socket.dropped(); // …then dropped, with no data
    const [retry] = rt.retries();
    delays.push(retry.ms);
    rt.fire(retry);
  }
  assert.deepEqual(delays, [1_000, 2_000, 4_000], "an open alone does not reset it");
  const live = rt.sockets.at(-1);
  live.opened();
  live.receive({ mt: 9, d: { 10: { mrk: 42 } } });
  assert.equal(feed.now().state.mrk, 42);
  live.dropped();
  assert.equal(rt.retries()[0].ms, 1_000, "data flowed: the next reconnect starts over");
  assert.equal(rt.timers.filter((t) => t.kind === "every" && !t.cancelled).length, 0, "no ping timer outlives its socket");
});

test("stopping detaches the socket before closing it: its late events reach nothing, and nothing reconnects", () => {
  const rt = runtime();
  const feed = feedOf();
  const stop = connectPerplFeed(10, "wss://x/ws", feed.update, rt);
  const socket = rt.sockets[0];
  socket.opened();
  stop();
  assert.equal(socket.closed, true);
  for (const handler of ["onopen", "onmessage", "onerror", "onclose"]) assert.equal(socket[handler], null, handler);
  assert.equal(rt.retries().length, 0);
  assert.ok(rt.timers.every((t) => t.cancelled), "the ping timer is cancelled");
  const before = feed.now();
  socket.receive({ mt: 9, d: { 10: { mrk: 99 } } }); // a late message from the old market's socket
  assert.equal(feed.now(), before);
});

test("stopping while a reconnect is pending cancels it", () => {
  const rt = runtime();
  const stop = connectPerplFeed(10, "wss://x/ws", feedOf().update, rt);
  rt.sockets[0].dropped();
  const [retry] = rt.retries();
  stop();
  assert.equal(retry.cancelled, true);
  assert.equal(rt.sockets.length, 1, "no new socket");
});
