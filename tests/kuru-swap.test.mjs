import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";
import { encodeAbiParameters, parseAbiParameters, zeroAddress } from "viem";

/* The web Kuru Flow path (app/lib/swap/kuru.ts): the calldata the API returns is decoded, not trusted. The fee tuple
   must carry no fee, and no route may touch a retired Moments cohort's coin or hook. Calldata is real ABI encoding
   (viem) in the layout read from the KuruFlowEntrypoint's bytecode, as the iOS tests build it. The API is stubbed. */

const kuru = await tsImport("../app/lib/swap/kuru.ts", import.meta.url);
const retired = await tsImport("../app/lib/moments/retired.ts", import.meta.url);
const { KURU } = await tsImport("../app/lib/swap/config.ts", import.meta.url);

const ACCOUNT = "0x1111111111111111111111111111111111111111";
const STRANGER = "0x2222222222222222222222222222222222222222";
const USDC = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603";
const WMON = "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A";
const MON_IN = 10n ** 18n;
const OUT = 1_000_000n;
const HEAD = "address,uint256,address,uint256,(address,uint256,address,uint256,bool),bytes";

function kuruCalldata({ tokenIn = zeroAddress, amountIn = MON_IN, tokenOut = USDC, minOut = 995_000n, fee = {}, route = "0x0201ff", recipient } = {}) {
  const tuple = [fee.recipient ?? STRANGER, fee.bps ?? 0n, fee.referrer ?? zeroAddress, fee.referrerBps ?? 0n, fee.onOutput ?? true];
  const args = [tokenOut, minOut, tokenIn, amountIn, tuple, route];
  if (recipient) return "0x31343b21" + encodeAbiParameters(parseAbiParameters(`${HEAD},address`), [...args, recipient]).slice(2);
  return "0xce1e7030" + encodeAbiParameters(parseAbiParameters(HEAD), args).slice(2);
}

test("decodes both selectors and the fee tuple", () => {
  const plain = kuru.decodeKuruFlowSwap(kuruCalldata({ fee: { bps: 7n, referrer: STRANGER, referrerBps: 3n, onOutput: false } }));
  assert.equal(plain.tokenOut, USDC);
  assert.equal(plain.tokenIn, zeroAddress);
  assert.equal(plain.amountIn, MON_IN);
  assert.equal(plain.minAmountOut, 995_000n);
  assert.equal(plain.recipient, null);
  assert.deepEqual(plain.fee, { recipient: STRANGER, bps: 7n, referrer: STRANGER, referrerBps: 3n, onOutput: false });
  const paid = kuru.decodeKuruFlowSwap(kuruCalldata({ recipient: ACCOUNT }));
  assert.equal(paid.recipient, ACCOUNT);
  assert.equal(paid.fee.onOutput, true);
});

test("rejects malformed calldata", () => {
  const good = kuruCalldata();
  assert.equal(kuru.decodeKuruFlowSwap("0xdeadbeef" + good.slice(10)), null, "unknown selector");
  assert.equal(kuru.decodeKuruFlowSwap(good.slice(0, 10 + 64 * 9)), null, "short head");
  // Word 4 (fee recipient) with dirty high bytes; word 8 (feeOnOutput) that isn't 0 or 1.
  const words = (hex) => hex.slice(10).match(/.{64}/g);
  const w = words(good);
  const dirty = [...w];
  dirty[4] = "ff" + dirty[4].slice(2);
  assert.equal(kuru.decodeKuruFlowSwap(good.slice(0, 10) + dirty.join("")), null, "dirty fee recipient");
  const badBool = [...w];
  badBool[8] = "0".repeat(63) + "2";
  assert.equal(kuru.decodeKuruFlowSwap(good.slice(0, 10) + badBool.join("")), null, "non-bool feeOnOutput");
});

test("only a zero-fee tuple is allowed", () => {
  const fee = (f) => kuru.decodeKuruFlowSwap(kuruCalldata({ fee: f })).fee;
  assert.equal(kuru.kuruFeeAllowed(fee({})), true, "fee recipient set, 0 bps (the shape the iOS fixtures use)");
  assert.equal(kuru.kuruFeeAllowed(fee({ recipient: zeroAddress })), true);
  assert.equal(kuru.kuruFeeAllowed(fee({ bps: 1n })), false);
  assert.equal(kuru.kuruFeeAllowed(fee({ referrer: STRANGER, referrerBps: 1n })), false);
  assert.equal(kuru.kuruFeeAllowed(fee({ bps: 2n ** 255n })), false);
});

test("the retired list matches iOS SwapEngine.retiredAddresses: five coins and two hooks", () => {
  assert.equal(retired.RETIRED_MOMENT_COINS.length, 5);
  assert.equal(retired.RETIRED_MOMENT_HOOKS.length, 2);
  assert.equal(retired.RETIRED_MOMENT_ADDRESSES.length, 7);
  assert.equal(retired.findRetiredAddress(kuruCalldata()), null);
  for (const hit of retired.RETIRED_MOMENT_ADDRESSES) {
    // As an ABI word, and raw in a packed path (an odd-length prefix puts it at a byte, not word, boundary).
    const word = "0x5f3bd1c8" + encodeAbiParameters(parseAbiParameters("address,uint256"), [hit, 0n]).slice(2);
    const packed = "0xdeadbeef" + WMON.slice(2) + "000bb8" + hit.slice(2) + "0001f4" + USDC.slice(2);
    assert.equal(retired.findRetiredAddress(word), hit);
    assert.equal(retired.findRetiredAddress(packed.toUpperCase().replace("0X", "0x")), hit);
    assert.equal(retired.findRetiredAddress(kuruCalldata({ route: `0x01${hit.slice(2)}` })), hit, "inside the route bytes");
  }
  // Half a byte off is not an address the calldata touches.
  const hit = retired.RETIRED_MOMENT_ADDRESSES[0];
  assert.equal(retired.findRetiredAddress("0x0" + hit.slice(2) + "0"), null);
});

// quoteKuru end to end, against a stubbed Kuru API.
const realFetch = globalThis.fetch;
let reply;
let calls = [];
globalThis.fetch = async (input) => {
  const url = String(input);
  calls.push(url);
  if (url.endsWith("/api/generate-token")) return Response.json({ token: "t", expires_at: Math.floor(Date.now() / 1000) + 3600 });
  return Response.json(reply);
};
test.after(() => { globalThis.fetch = realFetch; });

const MON = { address: zeroAddress, symbol: "MON", name: "Monad", decimals: 18, logo: "", native: true };
const USDC_TOKEN = { address: USDC, symbol: "USDC", name: "USDC", decimals: 6, logo: "" };
const req = (tokenOut = USDC_TOKEN) => ({ tokenIn: MON, tokenOut, amountIn: MON_IN, slippageBps: 50, account: ACCOUNT });
const quoteWith = (calldata, r = req()) => {
  reply = { status: "success", output: OUT.toString(), transaction: { to: KURU.entrypoint, value: MON_IN.toString(), calldata } };
  return kuru.quoteKuru(r);
};
const BLOCKED = /blocked for your safety/;
const RETIRED = /retired Moments coin or pool/;

test("quoteKuru accepts a clean zero-fee quote", async () => {
  const quote = await quoteWith(kuruCalldata());
  assert.equal(quote.amountOut, OUT);
  assert.equal(quote.minOut, 995_000n);
  const steps = await quote.build(ACCOUNT);
  assert.equal(steps.length, 1);
  assert.equal(steps[0].request.to, KURU.entrypoint);
  assert.ok(await quoteWith(kuruCalldata({ recipient: ACCOUNT })));
});

test("quoteKuru blocks a quote that takes a fee", async () => {
  await assert.rejects(quoteWith(kuruCalldata({ fee: { bps: 30n } })), BLOCKED);
  await assert.rejects(quoteWith(kuruCalldata({ fee: { referrer: STRANGER, referrerBps: 30n } })), BLOCKED);
  await assert.rejects(quoteWith(kuruCalldata({ fee: { recipient: STRANGER, bps: 1n, onOutput: false } })), BLOCKED);
});

test("quoteKuru blocks a route through a retired cohort, and never asks for a retired coin", async () => {
  for (const hit of retired.RETIRED_MOMENT_ADDRESSES) {
    await assert.rejects(quoteWith(kuruCalldata({ route: `0x01${hit.slice(2)}02` })), RETIRED, hit);
  }
  calls = [];
  for (const coin of retired.RETIRED_MOMENT_COINS) {
    const token = { address: coin, symbol: "PAST", name: "Past cohort coin", decimals: 18, logo: "" };
    await assert.rejects(quoteWith(kuruCalldata({ tokenOut: coin }), req(token)), RETIRED, coin);
    await assert.rejects(kuru.quoteKuru({ ...req(), tokenIn: token, tokenOut: USDC_TOKEN }), RETIRED, coin);
  }
  assert.deepEqual(calls, [], "a retired coin must be refused before the API is asked");
});
