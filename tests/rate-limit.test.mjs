import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* worker/rate-limit.ts: per-client caps on the Perpl relays, counted per window and per open socket, with bounded
   memory. */

const limits = await tsImport("../worker/rate-limit.ts", import.meta.url);

test("a client gets `limit` calls per window, then waits for the next window; other clients are separate", () => {
  const allow = limits.createWindowLimiter(3, 60_000);
  assert.deepEqual([0, 1, 2, 3, 4].map((t) => allow("a", t)), [true, true, true, false, false]);
  assert.equal(allow("b", 5), true, "another client");
  assert.equal(allow("a", 59_999), false, "same window");
  assert.equal(allow("a", 60_000), true, "a new window");
});

test("the table of clients stays bounded: expired windows go first, and a full table of live ones starts over", () => {
  const allow = limits.createWindowLimiter(1, 1_000, 2);
  assert.equal(allow("a", 0), true);
  assert.equal(allow("b", 500), true);
  assert.equal(allow("c", 1_200), true, "a's window expired and was dropped to make room");
  assert.equal(allow("b", 1_300), false, "b's live window was kept");
  assert.equal(allow("d", 1_400), true, "full of live windows: the table starts over");
  assert.equal(allow("b", 1_450), true, "b starts a fresh window after the reset");
});

test("slots: at most `limit` held per client, each released once, however often release is called", () => {
  const slots = limits.createSlotLimiter(2);
  const first = slots.acquire("a");
  const second = slots.acquire("a");
  assert.ok(first && second);
  assert.equal(slots.acquire("a"), null, "a third socket is refused");
  assert.ok(slots.acquire("b"), "another client");
  first();
  first();
  assert.equal(slots.held("a"), 1, "a double release frees one slot");
  const third = slots.acquire("a");
  assert.ok(third);
  assert.equal(slots.acquire("a"), null);
  second();
  third();
  assert.equal(slots.held("a"), 0);
});

test("the client key is Cloudflare's connecting IP, or none", () => {
  assert.equal(limits.clientKey(new Request("https://x.example/", { headers: { "cf-connecting-ip": " 203.0.113.9 " } })), "203.0.113.9");
  assert.equal(limits.clientKey(new Request("https://x.example/", { headers: { "x-forwarded-for": "203.0.113.9" } })), null, "a header the client chooses is not a key");
});

test("the limits sit well above the app's own use", () => {
  assert.ok(limits.PERPL_REQUESTS_PER_MINUTE >= 60);
  assert.ok(limits.PERPL_SOCKETS_PER_CLIENT >= 4);
  assert.ok(limits.PERPL_SOCKET_OPENS_PER_MINUTE >= 10);
});
