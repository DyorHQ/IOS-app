import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* app/lib/perps/candles.ts: the charts read Perpl's candles through the app's proxy, and the proxy relays only the
   candle paths the app itself builds at the current time. */

const candles = await tsImport("../app/lib/perps/candles.ts", import.meta.url);
const HOUR = 3_600_000;
const NOW = Date.UTC(2026, 8, 26, 12, 34, 56);

test("the window ends at the next candle boundary and spans 150 candles", () => {
  const path = candles.candlesPath(10, 3600, NOW);
  const to = Date.UTC(2026, 8, 26, 13);
  assert.equal(path, `v1/market-data/10/candles/3600/${to - 150 * HOUR}-${to}`);
  assert.equal(candles.candlesPath(10, 3600, NOW + 60_000), path, "the same URL for everyone within the hour");
  assert.equal(candles.isCandlesRoute(path, NOW), true);
  for (const res of candles.CANDLE_RESOLUTIONS) assert.equal(candles.isCandlesRoute(candles.candlesPath(1, res, NOW), NOW), true, String(res));
});

test("a visitor's clock may be a few minutes off", () => {
  for (const res of candles.CANDLE_RESOLUTIONS) {
    for (const skew of [-4 * 60_000, 4 * 60_000]) assert.equal(candles.isCandlesRoute(candles.candlesPath(10, res, NOW + skew), NOW), true, `${res} s, ${skew} ms`);
  }
  assert.equal(candles.isCandlesRoute(candles.candlesPath(10, 60, NOW + 7 * 60_000), NOW), false, "minute candles, seven minutes ahead");
  assert.equal(candles.isCandlesRoute(candles.candlesPath(10, 86400, NOW - 36 * HOUR), NOW), true, "daily candles: one candle back is within a step");
  assert.equal(candles.isCandlesRoute(candles.candlesPath(10, 86400, NOW - 60 * HOUR), NOW), false, "daily candles, two candles back");
});

test("the proxy refuses every other candle path", () => {
  const to = Date.UTC(2026, 8, 26, 13);
  const from = to - 150 * HOUR;
  const refused = [
    `v1/market-data/11/candles/3600/${from}-${to}`, // not a listed market
    `v1/market-data/10/candles/7200/${from}-${to}`, // not a listed resolution
    `v1/market-data/10/candles/3600/${from + 1}-${to}`, // unaligned (cache busting)
    `v1/market-data/10/candles/3600/${to - 1025 * HOUR}-${to}`, // more than 1024 candles
    `v1/market-data/10/candles/3600/${from + HOUR}-${to}`, // another window size (149 candles)
    `v1/market-data/10/candles/3600/${from - HOUR}-${to}`, // another window size (151 candles)
    `v1/market-data/10/candles/3600/${from - 240 * HOUR}-${to - 240 * HOUR}`, // a historical window
    `v1/market-data/10/candles/3600/${from + 240 * HOUR}-${to + 240 * HOUR}`, // a future window
    `v1/market-data/10/candles/3600/${to}-${from}`, // backwards
    `v1/market-data/10/candles/3600/${from}-${to}/x`,
    `v1/market-data/10/candles/3600/${from}`,
    `v1/market-data/10/trades/3600/${from}-${to}`,
    `v1/pub/context`,
    `v1/market-data/10/candles/3600/${from}-${to}?x=1`,
    `../v1/market-data/10/candles/3600/${from}-${to}`,
  ];
  for (const route of refused) assert.equal(candles.isCandlesRoute(route, NOW), false, route);
});

test("Perpl's series becomes ascending, unscaled chart candles, one per time", () => {
  const json = {
    mt: 12,
    r: 3600,
    d: [
      { t: 1789905600000, o: 23534, c: 23448, h: 23698, l: 23294, v: "5825731476", n: 127 },
      { t: 1789902000000, o: 23426, c: 23534, h: 23678, l: 23252, v: "19381864627", n: 232 },
      { t: 1789905600000, o: 23534, c: 23450, h: 23698, l: 23294, v: "5825731999", n: 128 },
      { t: "bad", o: 1, c: 1, h: 1, l: 1 },
      { t: 1789909200000, o: 0, c: 1, h: 1, l: 1 },
    ],
  };
  const out = candles.toCandles(json, 6);
  assert.deepEqual(out.map((c) => c.time), [1789902000, 1789905600]);
  assert.deepEqual(out[0], { time: 1789902000, open: 0.023426, high: 0.023678, low: 0.023252, close: 0.023534, volume: 19381864627 });
  assert.equal(out[1].close, 0.02345, "the later row for a time wins");
  assert.throws(() => candles.toCandles({ error: "x" }, 6), /no candle series/);
});
