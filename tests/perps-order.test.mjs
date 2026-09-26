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
