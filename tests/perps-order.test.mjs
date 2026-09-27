import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* app/lib/perps/perpl.ts: the order the form shows is the order that is sent (exact lots and price units). The form
   parses with parseAmount (app/lib/format.ts), which cuts to the market's decimals and never rounds up. */

const perpl = await tsImport("../app/lib/perps/perpl.ts", import.meta.url);
const { parseAmount } = await tsImport("../app/lib/format.ts", import.meta.url);
const BTC = { id: 1, symbol: "BTC", priceDecimals: 1, lotDecimals: 5, mark: 65_000, maintMarginFrac: 0.05 };

test("a parsed size and limit price go out exactly as shown", () => {
  const lots = parseAmount("0.1234567", BTC.lotDecimals);
  const pricePNS = parseAmount("64999.99", BTC.priceDecimals);
  assert.equal(lots, 12345n, "the size is cut to the lot, never rounded up");
  assert.equal(pricePNS, 649999n);
  const desc = perpl.buildOrderDesc({ perp: BTC, side: "long", kind: "limit", size: 0.1234567, lotLNS: lots, price: 64999.99, pricePNS, leverage: 5 });
  assert.equal(desc.lotLNS, 12345n);
  assert.equal(desc.pricePNS, 649999n);
  assert.equal(desc.immediateOrCancel, false);
});

test("without parsed values the size is rounded to the lot (closing a position read from the chain)", () => {
  const desc = perpl.buildOrderDesc({ perp: BTC, side: "short", kind: "market", size: 0.12345, leverage: 2, reduceOnly: true, slippageBps: 100 });
  assert.equal(desc.lotLNS, 12345n);
  assert.equal(desc.pricePNS, BigInt(Math.round(65_000 * 0.99 * 10)));
  assert.equal(desc.orderType, perpl.ORDER_TYPE.CloseLong);
  assert.equal(desc.immediateOrCancel, true);
});

test("a market order ignores a stray limit price", () => {
  const desc = perpl.buildOrderDesc({ perp: BTC, side: "long", kind: "market", size: 1, lotLNS: 100000n, pricePNS: 1n, leverage: 1, slippageBps: 100 });
  assert.equal(desc.pricePNS, BigInt(Math.round(65_000 * 1.01 * 10)));
});

/* fetchPositions: a market whose position (or market info) can't be read is named, never allowed to hide the others.
   The chain reads are a stub; nothing reaches an RPC. */

const INFO = (symbol) => ({ symbol, priceDecimals: 6n, lotDecimals: 3n, basePricePNS: 0n, markPNS: 2_000_000n, lastPNS: 2_000_000n, oraclePNS: 2_000_000n, markTimestamp: 0n, longOpenInterestLNS: 0n, shortOpenInterestLNS: 0n, fundingRatePct100k: 0n, status: 0n, numOrders: 0n });
const POSITION = (lots) => [{ lotLNS: lots, pricePNS: 1_000_000n, positionType: 0n, depositCNS: 5_000_000n, premiumPnlCNS: 0n }, 2_000_000n];
/** A multicall stub: `fail` lists "function:perpId" reads that revert; `down` makes the whole call throw. */
const chain = ({ fail = [], down = false, lots = {} } = {}) => ({
  async multicall({ contracts }) {
    if (down) throw new Error("HTTP request failed");
    return contracts.map(({ functionName, args }) => {
      const id = Number(args[0]);
      if (fail.includes(`${functionName}:${id}`)) return { status: "failure", error: new Error("execution reverted") };
      if (functionName === "getPerpetualInfo") return { status: "success", result: INFO(`M${id}`) };
      if (functionName === "getMarginFractions") return { status: "success", result: [1000n, 2000n] };
      if (functionName === "getPosition") return { status: "success", result: POSITION(lots[id] ?? 1_500n) };
      throw new Error(`unexpected ${functionName}`);
    });
  },
});
const account = (positionPerps) => ({ accountId: 7, balance: 0n, locked: 0n, frozen: false, positionPerps });

test("positions that read are returned with a market that doesn't, which is named", async () => {
  const listed = await perpl.fetchPerps([1, 10], chain());
  const read = await perpl.fetchPositions(account([1, 10]), listed, chain({ fail: ["getPosition:10"] }));
  assert.deepEqual(read.positions.map((p) => [p.perpId, p.size]), [[1, 1.5]], "BTC keeps its position (and its Close button)");
  assert.deepEqual(read.unreadable, [10]);
  assert.equal(perpl.unreadablePositionsText(read.unreadable), "Couldn't read your position in MON-PERP.");
});

test("a market the app doesn't list is read; if its info reverts, only that position is unreadable", async () => {
  const listed = await perpl.fetchPerps([1], chain());
  const ok = await perpl.fetchPositions(account([1, 77]), listed, chain());
  assert.deepEqual(ok.positions.map((p) => p.perpId), [1, 77]);
  const bad = await perpl.fetchPositions(account([1, 77, 20]), [...listed, ...(await perpl.fetchPerps([20], chain()))], chain({ fail: ["getPerpetualInfo:77"] }));
  assert.deepEqual(bad.positions.map((p) => p.perpId), [1, 20]);
  assert.deepEqual(bad.unreadable, [77]);
  assert.equal(perpl.unreadablePositionsText([77, 20, 1]), "Couldn't read your positions in Perpl market 77, ETH-PERP and BTC-PERP.");
});

test("a closed position is skipped, not unreadable; a failed read of the whole set still fails", async () => {
  const listed = await perpl.fetchPerps([1, 10], chain());
  const read = await perpl.fetchPositions(account([1, 10]), listed, chain({ lots: { 10: 0n } }));
  assert.deepEqual([read.positions.map((p) => p.perpId), read.unreadable], [[1], []]);
  await assert.rejects(perpl.fetchPositions(account([1]), listed, chain({ down: true })), /HTTP request failed/);
  assert.deepEqual(await perpl.fetchPositions(account([]), listed, chain({ down: true })), { positions: [], unreadable: [] });
});
