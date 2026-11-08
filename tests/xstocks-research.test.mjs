// The xStocks research tool's pure parts (scripts/research/xstocks/lib.mjs), offline: the strict 1inch swap decoder
// against the shared parity fixture (also read by DyorKit's OneInchCalldataParityTests), the checks applied to a
// decoded swap, and redaction of the 1inch key.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { FIXTURE, cases, fixture } from "../scripts/research/xstocks/make-parity-fixture.mjs";
import { decodeFunctionData } from "viem";
import {
  ONEINCH, SWAP_ABI, addressFromSlot, amountField, checkFirmAnswer, codeHash, decodeSwap, maskAddress, minAfterSlippage, printable, redact,
  slippagePercent, swapMatches, swapProblem,
} from "../scripts/research/xstocks/lib.mjs";

test("the slipped offset really is readable, so only the canonical re-encoding refuses it", () => {
  const slipped = cases().find((c) => c.name === "slipped bytes offset (readable, not canonical)");
  assert.doesNotThrow(() => decodeFunctionData({ abi: SWAP_ABI, data: slipped.calldata }));
  assert.equal(decodeSwap(slipped.calldata), null);
});

test("a firm answer passes only as the app's firmAnswer and firmQuote would pass it", () => {
  const swap = decodeSwap(cases()[0].calldata);
  const account = swap.dstReceiver;
  const trade = { tokenIn: swap.srcToken, tokenOut: swap.dstToken, amountIn: swap.amount };
  // The canonical buy's minimum is 1% under this quoted amount, rounded down: exactly the 100 bps floor.
  const dstAmount = (swap.minReturn * 10_000n + 9_899n) / 9_900n;
  const good = { status: 200, body: { dstAmount: dstAmount.toString(), tx: { to: ONEINCH.router, from: account, value: "0", data: cases()[0].calldata } } };
  assert.equal(checkFirmAnswer(good, trade, account, 100).ok, true);
  const bad = (change, why) => {
    const answer = structuredClone(good);
    change(answer);
    assert.equal(checkFirmAnswer(answer, trade, account, 100).ok, false, why);
  };
  bad((a) => { a.status = 199; }, "a status just under 2xx");
  bad((a) => { a.status = 300; }, "a status just over 2xx");
  bad((a) => { a.status = 400; }, "an error status");
  bad((a) => { delete a.body.dstAmount; }, "no dstAmount");
  bad((a) => { a.body.dstAmount = "0"; }, "a zero dstAmount");
  bad((a) => { a.body.dstAmount = `0x${dstAmount.toString(16)}`; }, "a hex dstAmount");
  bad((a) => { a.body.dstAmount = ` ${dstAmount}`; }, "a padded dstAmount");
  bad((a) => { a.body.dstAmount = (swap.minReturn - 1n).toString(); }, "a minimum above the quoted amount");
  bad((a) => { a.body.dstAmount = (dstAmount * 2n).toString(); }, "a minimum below the slippage floor");
  bad((a) => { a.body.tx.to = ONEINCH.aqua; }, "another target");
  bad((a) => { a.body.tx.to = "not an address"; }, "an unreadable target");
  bad((a) => { a.body.tx.from = "0x00000000000000000000000000000000000c0002"; }, "another sender");
  bad((a) => { a.body.tx.value = "0x0"; }, "a value that isn't exactly \"0\"");
  bad((a) => { delete a.body.tx.value; }, "no value");
  bad((a) => { a.body.tx.data = `${a.body.tx.data}00`; }, "calldata with a suffix");
  bad((a) => { delete a.body.tx; }, "no tx");
  assert.equal(checkFirmAnswer(good, { ...trade, amountIn: trade.amountIn + 1n }, account, 100).ok, false, "another amount");
  assert.equal(checkFirmAnswer(good, trade, account, 50).ok, false, "a tighter slippage raises the floor above the minimum");
});

test("amounts, slippage and printing as the proxy and the app take them", () => {
  assert.equal(amountField("12"), 12n);
  for (const bad of ["", "0", "012", "-1", "1.5", "0x10", " 1", 1, null, "1".repeat(79)]) assert.equal(amountField(bad), null, String(bad));
  assert.equal(amountField(((1n << 256n) - 1n).toString()), (1n << 256n) - 1n);
  assert.equal(amountField((1n << 256n).toString()), null);
  assert.deepEqual([100, 50, 25, 5, 0].map(slippagePercent), ["1", "0.5", "0.25", "0.05", "0"]);
  for (const bad of [101, -1, 1.5, Number.NaN]) assert.throws(() => slippagePercent(bad));
  assert.equal(printable("a\u0007b\u001b[2Jc\u009bd\ne\tf"), "a?b?[2Jc?d\ne\tf");
});

test("the committed parity fixture is what the generator writes", () => {
  assert.equal(readFileSync(FIXTURE, "utf8"), fixture());
});

test("each fixture case reads as a strict reader must read it", () => {
  // Written out by hand, so a decoder change can't move the fixture and its expectation together.
  const expected = {
    "canonical buy": [true, null],
    "canonical sell": [true, null],
    "flags set (decodes, refused as flags)": [true, "flags"],
    "another receiver (decodes, refused as recipient)": [true, "recipient"],
    "zero receiver (decodes, refused as recipient)": [true, "recipient"],
    "one trailing byte": [false, null],
    "a trailing word": [false, null],
    "v5 selector": [false, null],
    "dirty executor word": [false, null],
    "same token both sides": [false, null],
    "native marker out": [false, null],
    "zero amount": [false, null],
    "zero minimum": [false, null],
    "oversized executor data": [false, null],
    "slipped bytes offset (readable, not canonical)": [false, null],
    "bytes offset past a garbage length": [false, null],
    "uppercase hex digits": [true, null],
    "empty executor data": [true, null],
    "largest executor data that fits": [true, null],
    "one byte over the size limit": [false, null],
    "truncated": [false, null],
  };
  const all = cases();
  assert.deepEqual(all.map((c) => c.name).sort(), Object.keys(expected).sort());
  for (const c of all) assert.deepEqual([c.decodes, c.problem], expected[c.name], c.name);
});

test("anything that isn't hex calldata is refused", () => {
  for (const bad of [undefined, null, 42, "", "0x", "0x0", "07ed2379", "0x07ed237", "0xzz"]) assert.equal(decodeSwap(bad), null, String(bad));
});

test("a swap matches only the exact reviewed terms, for the account, with no value", () => {
  const swap = decodeSwap(cases()[0].calldata);
  const account = swap.dstReceiver;
  const terms = { tokenIn: swap.srcToken, tokenOut: swap.dstToken, amountIn: swap.amount, minReturnFloor: swap.minReturn };
  assert.equal(swapMatches(swap, terms, { account }), true);
  assert.equal(swapMatches(swap, { ...terms, tokenIn: terms.tokenOut }, { account }), false);
  assert.equal(swapMatches(swap, { ...terms, amountIn: terms.amountIn + 1n }, { account }), false);
  assert.equal(swapMatches(swap, { ...terms, minReturnFloor: terms.minReturnFloor + 1n }, { account }), false);
  assert.equal(swapMatches(swap, terms, { account, value: 1n }), false);
  assert.equal(swapProblem(swap, { account, value: 1n }), "value");
  assert.equal(swapMatches(swap, terms, { account: "0x00000000000000000000000000000000000c0002" }), false);
});

test("the slippage minimum is the app's", () => {
  // SwapMath.minAfterSlippage: amount × (10_000 − bps) / 10_000, rounded down.
  assert.equal(minAfterSlippage(165_000_000_000_000_000n, 100), 163_350_000_000_000_000n);
  assert.equal(minAfterSlippage(999n, 100), 989n);
  assert.equal(minAfterSlippage(1n, 0), 1n);
});

test("the 1inch key never survives redaction, plain or URL-encoded", () => {
  const key = "abcDEF123/+=key-value";
  const text = `GET https://api.1inch.dev/x?k=${encodeURIComponent(key)} Authorization: Bearer ${key}`;
  const out = redact(text, [key]);
  assert.equal(out.includes(key), false);
  assert.equal(out.includes(encodeURIComponent(key)), false);
  assert.equal(redact("short ab", ["ab"]), "short ab", "a secret too short to be a key is not a redaction target");
  assert.equal(redact("nothing", [undefined, ""]), "nothing");
});

test("masking an immutable address compares two deployments of the same code", () => {
  const weth = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
  const wmon = "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A";
  const body = (address) => `0x6080604052${address.slice(2).toLowerCase()}5b${address.slice(2)}00`;
  const eth = maskAddress(body(weth), weth);
  const mon = maskAddress(body(wmon), wmon);
  assert.equal(eth.count, 2);
  assert.equal(mon.count, 2);
  assert.equal(eth.code, mon.code);
  // An occurrence that doesn't start on a byte boundary isn't the address.
  assert.equal(maskAddress(`0x0${weth.slice(2)}0`, weth).count, 0);
  assert.notEqual(maskAddress(body(weth), wmon).code, mon.code);
});

test("code hashes and EIP-1967 slots", () => {
  assert.equal(codeHash("0x"), null);
  assert.equal(codeHash(undefined), null);
  assert.match(codeHash("0x6000"), /^0x[0-9a-f]{64}$/);
  assert.equal(addressFromSlot(`0x${"0".repeat(64)}`), null);
  assert.equal(addressFromSlot(`0x${"0".repeat(24)}111111125421ca6dc452d289314280a0f8842a65`), "0x111111125421cA6dc452d289314280a0f8842A65");
});
