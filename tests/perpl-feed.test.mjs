import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* app/lib/perps/ws.ts: the market-data socket reconnects with exponential backoff and jitter, not every 3 s forever. */

const { reconnectDelay } = await tsImport("../app/lib/perps/ws.ts", import.meta.url);

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
