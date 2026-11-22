// Writes the 1inch swap decoding parity fixture: calldata for AggregationRouterV6's generic swap encoded by viem (the
// reference ABI implementation), and mutations of it, each with what a strict reader must make of it. The app's
// decoder (OneInchCalldataParityTests in DyorKit) and this tool's (tests/xstocks-research.test.mjs) both read the
// same file, so the two can't drift apart. Test-only addresses: none is a real token or wallet.
//
//   node scripts/research/xstocks/make-parity-fixture.mjs [--check]
import { readFileSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { encodeFunctionData } from "viem";
import { NATIVE_MARKER, SWAP_ABI, decodeSwap, swapProblem, toJSON } from "./lib.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
export const FIXTURE = join(root, "ios/DyorKit/Tests/DyorKitTests/Fixtures/oneinch-swap-parity.json");

const T = Object.freeze({
  executor: "0x00000000000000000000000000000000000e0001",
  stock: "0x00000000000000000000000000000000000a0001",
  usdc: "0x00000000000000000000000000000000000a0002",
  receiver: "0x00000000000000000000000000000000000b0001",
  account: "0x00000000000000000000000000000000000c0001",
  other: "0x00000000000000000000000000000000000c0002",
});

const encode = (overrides = {}) => {
  const desc = { srcToken: T.usdc, dstToken: T.stock, srcReceiver: T.receiver, dstReceiver: T.account, amount: 50_000_000n, minReturnAmount: 165_000_000_000_000_000n, flags: 0n, ...overrides.desc };
  return encodeFunctionData({ abi: SWAP_ABI, functionName: "swap", args: [overrides.executor ?? T.executor, desc, overrides.data ?? "0x1234abcd"] });
};

/** The fixture's cases: a name, the calldata, and whether a strict reader accepts it. */
export function cases() {
  const canonical = encode();
  const body = canonical.slice(10);
  // The `bytes` argument's offset is the head word after the executor and the seven-word tuple (word 8). Pointing it
  // one word further, with a zero word slipped in before the bytes, still decodes to the same values: only the
  // canonical re-encoding refuses it. Pointing it one word further with nothing slipped in reads a garbage length.
  const offset = BigInt(`0x${body.slice(64 * 8, 64 * 9)}`);
  const word = (n) => n.toString(16).padStart(64, "0");
  const slipped = `${canonical.slice(0, 10)}${body.slice(0, 64 * 8)}${word(offset + 32n)}${"00".repeat(32)}${body.slice(64 * 9)}`;
  const garbage = `${canonical.slice(0, 10)}${body.slice(0, 64 * 8)}${word(offset + 32n)}${body.slice(64 * 9)}${"00".repeat(32)}`;
  // The largest executor data that fits 24 KiB of calldata beside the rest of a canonical swap, in whole words.
  const fits = 757 * 32;
  return [
    { name: "canonical buy", calldata: canonical },
    { name: "canonical sell", calldata: encode({ desc: { srcToken: T.stock, dstToken: T.usdc, amount: 165_000_000_000_000_000n, minReturnAmount: 49_000_000n } }) },
    { name: "flags set (decodes, refused as flags)", calldata: encode({ desc: { flags: 1n } }) },
    { name: "another receiver (decodes, refused as recipient)", calldata: encode({ desc: { dstReceiver: T.other } }) },
    { name: "zero receiver (decodes, refused as recipient)", calldata: encode({ desc: { dstReceiver: "0x0000000000000000000000000000000000000000" } }) },
    { name: "one trailing byte", calldata: `${canonical}00` },
    { name: "a trailing word", calldata: `${canonical}${"00".repeat(32)}` },
    { name: "v5 selector", calldata: `0x12aa3caf${body}` },
    { name: "dirty executor word", calldata: `${canonical.slice(0, 10)}ff${body.slice(2)}` },
    { name: "same token both sides", calldata: encode({ desc: { dstToken: T.usdc } }) },
    { name: "native marker out", calldata: encode({ desc: { dstToken: NATIVE_MARKER } }) },
    { name: "zero amount", calldata: encode({ desc: { amount: 0n } }) },
    { name: "zero minimum", calldata: encode({ desc: { minReturnAmount: 0n } }) },
    { name: "oversized executor data", calldata: encode({ data: `0x${"ab".repeat(24 * 1024)}` }) },
    { name: "slipped bytes offset (readable, not canonical)", calldata: slipped },
    { name: "bytes offset past a garbage length", calldata: garbage },
    { name: "uppercase hex digits", calldata: `0x${canonical.slice(2).toUpperCase()}` },
    { name: "empty executor data", calldata: encode({ data: "0x" }) },
    { name: "largest executor data that fits", calldata: encode({ data: `0x${"ab".repeat(fits)}` }) },
    { name: "one byte over the size limit", calldata: encode({ data: `0x${"ab".repeat(fits + 1)}` }) },
    { name: "truncated", calldata: canonical.slice(0, canonical.length - 64) },
  ].map((c) => {
    const swap = decodeSwap(c.calldata);
    return { ...c, decodes: swap !== null, problem: swap ? swapProblem(swap, { account: T.account }) : null,
      ...(swap ? { executor: swap.executor, srcToken: swap.srcToken, dstToken: swap.dstToken, srcReceiver: swap.srcReceiver, dstReceiver: swap.dstReceiver,
        amount: swap.amount, minReturn: swap.minReturn, flags: swap.flags, executorData: swap.executorData } : {}) };
  });
}

export function fixture() {
  return `${toJSON({ note: "Generated by scripts/research/xstocks/make-parity-fixture.mjs; do not edit.", account: T.account, cases: cases() })}\n`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  if (process.argv.includes("--check")) {
    const ok = readFileSync(FIXTURE, "utf8") === fixture();
    console.log(ok ? "fixture up to date" : "fixture is stale: run make-parity-fixture.mjs");
    process.exit(ok ? 0 : 1);
  }
  writeFileSync(FIXTURE, fixture());
  console.log(`wrote ${FIXTURE}`);
}
