import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* app/lib/launchpad/events.ts: a log scan with a hole in it must fail, not pass for "nothing happened". The range reader
   is stubbed; nothing reaches an RPC. */

const { chunkedLogs } = await tsImport("../app/lib/launchpad/events.ts", import.meta.url);

test("every range is read once and the logs are all returned", async () => {
  const seen = [];
  const out = await chunkedLogs(0n, 2_499n, async (a, b) => { seen.push([a, b]); return [Number(a)]; }, 2, 1_000n);
  assert.deepEqual(seen.map(([a, b]) => `${a}-${b}`).sort(), ["0-999", "1000-1999", "2000-2499"]);
  assert.deepEqual(out.sort((x, y) => x - y), [0, 1000, 2000]);
});

test("a range that fails once is retried", async () => {
  let failures = 1;
  const out = await chunkedLogs(0n, 1_999n, async (a) => {
    if (a === 1000n && failures-- > 0) throw new Error("rate limited");
    return [Number(a)];
  }, 6, 1_000n);
  assert.deepEqual(out.sort((x, y) => x - y), [0, 1000]);
});

test("a range that keeps failing fails the whole read", async () => {
  await assert.rejects(chunkedLogs(0n, 4_999n, async (a) => {
    if (a === 3000n) throw new Error("rpc down");
    return [Number(a)];
  }, 6, 1_000n), /didn't return every block range/);
});
