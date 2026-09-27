import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* app/lib/use-async.ts: the refresh loop behind useAsync. A slow load must never overlap the next one (so an older
   response can't land after a newer one), a stopped loop aborts its load, and failures back off. setTimeout is mocked;
   `settle` lets pending promise callbacks run. */

const { loadTimeout, refreshDelay, startRefreshLoop, withTimeout } = await tsImport("../app/lib/use-async.ts", import.meta.url);
const settle = () => new Promise((resolve) => setImmediate(resolve));

function deferred() {
  let resolve;
  const promise = new Promise((r) => { resolve = r; });
  return { promise, resolve };
}

test("the delay doubles per consecutive failure, capped at a minute and never below the interval", () => {
  assert.equal(refreshDelay(8_000, 0), 8_000);
  assert.equal(refreshDelay(8_000, 1), 16_000);
  assert.equal(refreshDelay(8_000, 2), 32_000);
  assert.equal(refreshDelay(8_000, 3), 60_000);
  assert.equal(refreshDelay(8_000, 30), 60_000);
  assert.equal(refreshDelay(120_000, 3), 120_000, "an interval above the cap is kept");
});

test("a load slower than the interval never overlaps the next one", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const loads = [];
  const stop = startRefreshLoop(() => {
    const d = deferred();
    loads.push(d);
    return d.promise;
  }, 1_000);
  await settle();
  assert.equal(loads.length, 1);
  t.mock.timers.tick(10_000);
  await settle();
  assert.equal(loads.length, 1, "no second load while the first is in flight, however long it takes");
  loads[0].resolve(true);
  await settle();
  t.mock.timers.tick(999);
  await settle();
  assert.equal(loads.length, 1, "the interval counts from when the load settled");
  t.mock.timers.tick(1);
  await settle();
  assert.equal(loads.length, 2);
  stop();
});

test("stopping aborts the load in flight and schedules nothing more", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const signals = [];
  const pending = deferred();
  const stop = startRefreshLoop((signal) => {
    signals.push(signal);
    return pending.promise;
  }, 1_000);
  await settle();
  stop();
  assert.equal(signals[0].aborted, true);
  pending.resolve(true);
  await settle();
  t.mock.timers.tick(60_000);
  await settle();
  assert.equal(signals.length, 1, "no run after stop");
});

test("without an interval the load runs once", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let runs = 0;
  const stop = startRefreshLoop(async () => { runs++; return true; }, 0);
  await settle();
  t.mock.timers.tick(60_000);
  await settle();
  stop();
  assert.equal(runs, 1);
});

test("failures back off, a thrown load counts as one, and a success resets the interval", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const outcomes = [new Error("rpc down"), false, true, true];
  let runs = 0;
  const stop = startRefreshLoop(async () => {
    const next = outcomes[runs++];
    if (next instanceof Error) throw next;
    return next;
  }, 1_000);
  const advance = async (ms) => { t.mock.timers.tick(ms); await settle(); };
  await settle();
  assert.equal(runs, 1);
  await advance(1_999);
  assert.equal(runs, 1, "one failure: 2 s");
  await advance(1);
  assert.equal(runs, 2);
  await advance(3_999);
  assert.equal(runs, 2, "two failures: 4 s");
  await advance(1);
  assert.equal(runs, 3);
  await advance(1_000);
  assert.equal(runs, 4, "after a success the plain interval again");
  stop();
});

/* withTimeout: a load that never settles fails after its timeout and is aborted, so the refresh loop moves on. */

test("a load that answers in time is returned as is", async () => {
  assert.equal(await withTimeout(async () => "data", new AbortController().signal, 50), "data");
  await assert.rejects(withTimeout(async () => { throw new Error("rpc down"); }, new AbortController().signal, 50), /rpc down/);
});

test("a hung load fails as a timeout, even when it ignores its signal, and its signal is aborted", async () => {
  let seen;
  const hung = (signal) => { seen = signal; return new Promise(() => {}); };
  await assert.rejects(withTimeout(hung, new AbortController().signal, 20), (e) => e.name === "TimeoutError" && /No answer after/.test(e.message));
  assert.equal(seen.aborted, true, "the fetch behind it is cancelled");
  assert.equal(loadTimeout(10_000), 60_000, "never under a minute");
  assert.equal(loadTimeout(60_000), 120_000, "twice a long interval");
});

test("stopping the loop aborts the load's signal too", async () => {
  const outer = new AbortController();
  let seen;
  const pending = withTimeout((signal) => { seen = signal; return new Promise((_, reject) => signal.addEventListener("abort", () => reject(signal.reason))); }, outer.signal, 10_000);
  outer.abort(new Error("superseded"));
  await assert.rejects(pending, /superseded/);
  assert.equal(seen.aborted, true);
  const already = new AbortController();
  already.abort();
  let aborted;
  await withTimeout(async (signal) => { aborted = signal.aborted; }, already.signal, 10_000);
  assert.equal(aborted, true, "a signal already aborted passes through");
});
