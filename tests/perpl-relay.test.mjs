import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* worker/perpl-relay.ts: the per-socket gate of the Perpl market-data relay. It forwards what the app's own socket
   sends and closes a socket that keeps too many streams open, churns through subscriptions, or floods frames. */

const relay = await tsImport("../worker/perpl-relay.ts", import.meta.url);
const sub = (streams, subscribe = true) => JSON.stringify({ mt: 5, subs: streams.map((stream) => ({ stream, subscribe })) });
const APP = sub(["order-book@10", "trades@10", "market-state@143"]);

test("the app's own subscription and pings pass, re-serialized", () => {
  const gate = relay.createRelayGate();
  assert.equal(gate(APP, 0), APP);
  assert.equal(gate(JSON.stringify({ mt: 1, extra: "dropped" }), 1), '{"mt":1}');
});

test("anything else closes the socket", () => {
  for (const frame of ["not json", "null", "[]", '{"mt":22}', sub(["candles@10*60"]), sub(["order-book@10"]).replace("true", '"yes"'), "x".repeat(3000)]) {
    assert.equal(relay.createRelayGate()(frame, 0), null, frame.slice(0, 40));
  }
});

test("more than eight streams open at once is refused", () => {
  const gate = relay.createRelayGate();
  assert.notEqual(gate(sub(["order-book@1", "order-book@2", "order-book@3", "order-book@4"]), 0), null);
  assert.notEqual(gate(sub(["trades@1", "trades@2", "trades@3", "trades@4"]), 1), null);
  assert.equal(gate(sub(["trades@5"]), 2), null);
});

test("subscribe/unsubscribe churn runs out of the lifetime budget", () => {
  const gate = relay.createRelayGate();
  let t = 0;
  let forwarded = 0;
  // Two streams at a time, never more than eight open, but a new pair every 10 s.
  for (let market = 1; market <= 40; market++) {
    const streams = [`order-book@${market}`, `trades@${market}`];
    const out = gate(sub(streams), (t += 10_000));
    if (out === null) break;
    forwarded++;
    assert.notEqual(gate(sub(streams, false), (t += 10_000)), null);
  }
  assert.equal(forwarded, relay.MAX_SUBSCRIBES_PER_SOCKET / 2, "stops once the subscribe budget is spent");
});

test("a frame flood is refused; the app's rate is far below the limit", () => {
  const flood = relay.createRelayGate();
  let refusedAt = null;
  for (let i = 0; i < 100 && refusedAt === null; i++) if (flood('{"mt":1}', 1_000 + i) === null) refusedAt = i;
  assert.equal(refusedAt, relay.MAX_MESSAGES_PER_MINUTE);

  const app = relay.createRelayGate();
  assert.notEqual(app(APP, 0), null);
  for (let minute = 0; minute < 120; minute++) {
    assert.notEqual(app('{"mt":1}', minute * 30_000 + 1), null, `ping at ${minute * 30} s`);
  }
});
