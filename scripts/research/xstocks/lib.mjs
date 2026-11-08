// The pure parts of the xStocks research tool (`research.mjs`): the 1inch router's addresses and generic swap as the
// app reads them, a strict decoder that accepts exactly what the app's own decoder accepts
// (ios/DyorKit/Sources/DyorKit/Services/Swap/OneInchCalldata.swift), the checks the app applies to a decoded swap, and
// the redaction every printed line goes through. No network here: the tests run offline.
import { decodeFunctionData, encodeFunctionData, getAddress, isAddress, keccak256, parseAbi } from "viem";

/** AggregationRouterV6 and the two 1inch contracts the app refuses, as Monad's protocol directory lists them
    (github.com/monad-crypto/protocols, mainnet/1inch.jsonc). The same constants as `OneInch` in Chain/Monad.swift. */
export const ONEINCH = Object.freeze({
  router: "0x111111125421cA6dc452d289314280a0f8842A65",
  aqua: "0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a",
  swapVMRouter: "0x111111338c5091E8440b67B168bAe16a668AC0De",
});

/** Monad's USDC, the one asset an xStock trades against in the app (`Monad.usdc`). */
export const MONAD_USDC = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603";
export const MONAD_CHAIN_ID = 143;

/** The generic swap, the one router entry point the app reads (`OneInchSwap.signature`). */
export const SWAP_SIGNATURE = "swap(address,(address,address,address,address,uint256,uint256,uint256),bytes)";
export const SWAP_SELECTOR = "0x07ed2379";
export const SWAP_ABI = parseAbi([
  "function swap(address executor, (address srcToken, address dstToken, address srcReceiver, address dstReceiver, uint256 amount, uint256 minReturnAmount, uint256 flags) desc, bytes data) payable returns (uint256 returnAmount, uint256 spentAmount)",
]);
/** The most calldata the app reads (`OneInchSwap.maxCalldataBytes`). */
export const MAX_CALLDATA_BYTES = 24 * 1024;
/** 1inch's marker for the native coin, which the app never swaps through 1inch. */
export const NATIVE_MARKER = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
const ZERO = "0x0000000000000000000000000000000000000000";

/** EIP-1967's implementation and admin slots, for telling how an xStock token is deployed (research R15). */
export const EIP1967 = Object.freeze({
  implementation: "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc",
  admin: "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103",
});

const same = (a, b) => a.toLowerCase() === b.toLowerCase();

/**
 * `data` (0x-hex calldata) read as the generic swap, or null unless it is exactly one in canonical form, as the app's
 * `OneInchSwap(calldata:)` reads it:
 * - the selector, at most MAX_CALLDATA_BYTES;
 * - the canonical encoding with nothing after it (re-encoding the decoded values must give back the same bytes, which
 *   also refuses dirty address words and stray offsets);
 * - two real ERC-20s (neither zero nor the native marker) that differ;
 * - a non-zero amount and minimum.
 */
export function decodeSwap(input) {
  if (typeof input !== "string" || !/^0x([0-9a-fA-F]{2})*$/.test(input)) return null;
  // The app reads hex digits of either case (`Data(hex:)`); viem matches the selector case-sensitively.
  const data = input.toLowerCase();
  const bytes = (data.length - 2) / 2;
  if (bytes > MAX_CALLDATA_BYTES || !data.startsWith(SWAP_SELECTOR)) return null;
  let decoded;
  try {
    decoded = decodeFunctionData({ abi: SWAP_ABI, data });
  } catch {
    return null;
  }
  const [executor, desc, executorData] = decoded.args;
  if (encodeFunctionData({ abi: SWAP_ABI, functionName: "swap", args: decoded.args }).toLowerCase() !== data) return null;
  const swap = {
    executor: getAddress(executor),
    srcToken: getAddress(desc.srcToken),
    dstToken: getAddress(desc.dstToken),
    srcReceiver: getAddress(desc.srcReceiver),
    dstReceiver: getAddress(desc.dstReceiver),
    amount: desc.amount,
    minReturn: desc.minReturnAmount,
    flags: desc.flags,
    executorData,
  };
  const markers = [ZERO, NATIVE_MARKER];
  if (markers.some((m) => same(m, swap.srcToken) || same(m, swap.dstToken))) return null;
  if (same(swap.srcToken, swap.dstToken) || swap.amount === 0n || swap.minReturn === 0n) return null;
  return swap;
}

/**
 * Why the app would refuse to sign `swap` sent with `value` from `account` (`OneInchSwap.problem`), or null. The output
 * must go to the account itself (1inch's "zero means the caller" is refused too), with no flags and no value.
 */
export function swapProblem(swap, { account, value = 0n }) {
  if (!same(swap.dstReceiver, account)) return "recipient";
  if (swap.flags !== 0n) return "flags";
  if (value !== 0n) return "value";
  return null;
}

/** Whether `swap` trades exactly `expected` ({tokenIn, tokenOut, amountIn, minReturnFloor}) for `account`
    (`OneInchSwap.matches`). */
export function swapMatches(swap, expected, { account, value = 0n }) {
  return swapProblem(swap, { account, value }) === null && same(swap.srcToken, expected.tokenIn) && same(swap.dstToken, expected.tokenOut)
    && swap.amount === expected.amountIn && swap.minReturn >= expected.minReturnFloor;
}

/** The most slippage a stock trade may take, in basis points (`OneInch.stockSlippageCapBps`, the proxy's cap). */
export const STOCK_SLIPPAGE_CAP_BPS = 100;
const MAX_UINT256 = (1n << 256n) - 1n;

/** An amount as the app and the proxy accept one from 1inch: a positive decimal string, no leading zero, at most
    2^256 − 1 (`OneInchVenue.amount`, the proxy's `amountField`). Null for anything else. */
export function amountField(value) {
  if (typeof value !== "string" || !/^[1-9][0-9]{0,77}$/.test(value)) return null;
  const amount = BigInt(value);
  return amount <= MAX_UINT256 ? amount : null;
}

/** Slippage in basis points as the proxy sends it to 1inch, a percent string ("1", "0.5", "0.25"), the proxy's
    `slippagePercent`. Throws outside 0…STOCK_SLIPPAGE_CAP_BPS. */
export function slippagePercent(bps) {
  if (!Number.isInteger(bps) || bps < 0 || bps > STOCK_SLIPPAGE_CAP_BPS) throw new RangeError("slippage out of range");
  const whole = Math.floor(bps / 100);
  const cents = bps % 100;
  return cents === 0 ? String(whole) : `${whole}.${String(cents).padStart(2, "0").replace(/0$/, "")}`;
}

/**
 * A 1inch /swap answer (`{status, body}`) checked as the app checks a firm quote (`OneInchVenue.firmAnswer` and
 * `firmQuote`), for `trade` ({tokenIn, tokenOut, amountIn}) from `account` at `bps` slippage:
 * - a 2xx answer whose `dstAmount` is an amount (`amountField`);
 * - `tx.to` the router and `tx.from` the account, both real addresses;
 * - `tx.value` exactly "0";
 * - calldata that decodes strictly and matches the trade, with a minimum between the slippage floor and `dstAmount`.
 * The band against the reference price is checked separately, by hand, from the printed amounts.
 */
export function checkFirmAnswer(answer, trade, account, bps) {
  const body = answer?.body;
  const tx = body && typeof body === "object" ? body.tx : undefined;
  if (!(answer?.status >= 200 && answer.status <= 299) || !tx || typeof tx !== "object") return { ok: false, why: `HTTP ${answer?.status}` };
  const dstAmount = amountField(body.dstAmount);
  if (dstAmount === null) return { ok: false, why: "dstAmount is not a positive decimal" };
  const is = (a, b) => typeof a === "string" && isAddress(a, { strict: false }) && a.toLowerCase() === b.toLowerCase();
  const floor = minAfterSlippage(dstAmount, bps);
  const swap = decodeSwap(tx.data);
  const ok = swap !== null && is(tx.to, ONEINCH.router) && is(tx.from, account) && tx.value === "0"
    && swapMatches(swap, { ...trade, minReturnFloor: floor }, { account, value: 0n }) && swap.minReturn <= dstAmount;
  return {
    ok, to: tx.to, from: tx.from, value: tx.value, selector: typeof tx.data === "string" ? tx.data.slice(0, 10) : null, decodes: swap !== null,
    problem: swap ? swapProblem(swap, { account, value: 0n }) : "undecodable", dstAmount, minReturn: swap?.minReturn ?? null, floor,
    protocols: body.protocols ?? null,
  };
}

/** `text` with control characters (C0 but newline and tab, DEL, C1) replaced, so a token's on-chain name or an API
    body can't drive the terminal. */
export function printable(text) {
  return String(text).replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g, "?");
}

/** `amount × (10_000 − bps) / 10_000`, the app's slippage minimum (`SwapMath.minAfterSlippage`). */
export function minAfterSlippage(amount, bps) {
  return (amount * BigInt(10_000 - bps)) / 10_000n;
}

/** keccak-256 of deployed runtime code (`eth_getCode`), the value compared across chains (research R3a). Null for an
    address with no code. */
export function codeHash(code) {
  if (!code || code === "0x") return null;
  return keccak256(code);
}

/** The address in a 32-byte storage word (an EIP-1967 slot), or null when the word is zero. */
export function addressFromSlot(word) {
  if (!word || /^0x0*$/.test(word)) return null;
  return getAddress(`0x${word.slice(-40)}`);
}

/**
 * `text` with every occurrence of each secret removed, as-is and URL-encoded. Every line the tool prints and every
 * file it writes goes through this, so the 1inch key can't reach a terminal, a CI log or a fixture.
 */
export function redact(text, secrets) {
  let out = String(text);
  for (const secret of secrets) {
    if (!secret || secret.length < 8) continue;
    for (const form of new Set([secret, encodeURIComponent(secret)])) out = out.split(form).join("[redacted]");
  }
  return out;
}

/** JSON with bigints as decimal strings, for printing and fixtures. */
export function toJSON(value) {
  return JSON.stringify(value, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2);
}
