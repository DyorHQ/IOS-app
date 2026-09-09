import { encodeFunctionData, erc20Abi, type Address, type Hex } from "viem";
import { publicClient } from "../chain";
import { describeError } from "../errors";
import { waitFor } from "../use-tx";
import type { Wallet } from "../wallet";
import { permit2Abi, wmonAbi } from "./abis";
import { UNISWAP, WMON } from "./config";
import { quoteKuru } from "./kuru";
import { quoteMonday } from "./monday";
import { isNative, sameToken } from "./tokens";
import { nowSeconds, type PlanStep, type QuoteResult, type SwapRequest, type Venue, type VenueQuote } from "./types";
import { quoteUniswap } from "./uniswap";

/* Asks every venue at once and ranks by output. MON ↔ WMON is a 1:1 wrap and never needs a venue. */

function wrapQuote(req: SwapRequest): VenueQuote {
  const wrapping = isNative(req.tokenIn.address);
  return {
    venue: "wmon",
    amountOut: req.amountIn,
    minOut: req.amountIn,
    route: wrapping ? "Wrap MON → WMON, 1:1" : "Unwrap WMON → MON, 1:1",
    gasEstimate: 50_000n,
    priceImpactBps: 0,
    at: nowSeconds(),
    build: async () => [
      {
        kind: "tx",
        request: wrapping
          ? { to: WMON, data: encodeFunctionData({ abi: wmonAbi, functionName: "deposit" }), value: req.amountIn }
          : { to: WMON, data: encodeFunctionData({ abi: wmonAbi, functionName: "withdraw", args: [req.amountIn] }), value: 0n },
        label: wrapping ? "Wrap MON" : "Unwrap WMON",
      },
    ],
  };
}

export const QUOTE_VENUES: Venue[] = ["kuru", "uniswap", "monday"];
const QUOTE_TIMEOUT_MS = 20_000;

export const isWrap = (req: Pick<SwapRequest, "tokenIn" | "tokenOut">) =>
  (isNative(req.tokenIn.address) && sameToken(req.tokenOut.address, WMON)) || (sameToken(req.tokenIn.address, WMON) && isNative(req.tokenOut.address));

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise((resolve, reject) => {
    const id = setTimeout(() => reject(new Error(`${label} did not answer within ${Math.round(ms / 1000)}s.`)), ms);
    promise.then((v) => { clearTimeout(id); resolve(v); }, (e) => { clearTimeout(id); reject(e); });
  });
}

/** One venue's quote, or null when it has no route. Throws with a readable message on failure or timeout. */
export async function fetchVenueQuote(venue: Venue, req: SwapRequest): Promise<VenueQuote | null> {
  if (sameToken(req.tokenIn.address, req.tokenOut.address) || req.amountIn <= 0n) return null;
  if (isWrap(req)) return venue === "wmon" ? wrapQuote(req) : null;
  if (venue === "wmon") return null;
  const label = { kuru: "Kuru Flow", uniswap: "Uniswap", monday: "Monday Trade" }[venue];
  const quote = venue === "kuru" ? quoteKuru(req) : venue === "uniswap" ? quoteUniswap(req) : quoteMonday(req);
  return withTimeout(quote, QUOTE_TIMEOUT_MS, label);
}

export function rankQuotes(quotes: (VenueQuote | null | undefined)[]): VenueQuote[] {
  return quotes.filter((q): q is VenueQuote => !!q).sort((a, b) => (b.amountOut > a.amountOut ? 1 : b.amountOut < a.amountOut ? -1 : 0));
}

export async function fetchQuotes(req: SwapRequest): Promise<QuoteResult> {
  if (sameToken(req.tokenIn.address, req.tokenOut.address) || req.amountIn <= 0n) return { quotes: [], errors: {} };
  if (isWrap(req)) return { quotes: [wrapQuote(req)], errors: {} };
  const settled = await Promise.allSettled(QUOTE_VENUES.map((v) => fetchVenueQuote(v, req)));
  const quotes: VenueQuote[] = [];
  const errors: QuoteResult["errors"] = {};
  settled.forEach((s, i) => {
    if (s.status === "fulfilled") {
      if (s.value) quotes.push(s.value);
      else errors[QUOTE_VENUES[i]] = "No route for this pair.";
    } else errors[QUOTE_VENUES[i]] = describeError(s.reason);
  });
  return { quotes: rankQuotes(quotes), errors };
}

/** Executes a plan step by step: approvals are skipped when the allowance already covers the amount, every
    transaction is simulated before the wallet opens, and each hash is reported as it is sent. */
export async function runPlan(wallet: Wallet, steps: PlanStep[], onStep: (label: string, hash?: Hex) => void): Promise<Hex> {
  const owner = wallet.account.address;
  let last: Hex | null = null;
  for (const step of steps) {
    onStep(step.label);
    if (step.kind === "approve") {
      const allowance = await publicClient.readContract({ address: step.token, abi: erc20Abi, functionName: "allowance", args: [owner, step.spender] });
      if (allowance >= step.amount) continue;
      const { request } = await publicClient.simulateContract({ address: step.token, abi: erc20Abi, functionName: "approve", args: [step.spender, step.amount], account: wallet.account });
      const hash = await wallet.writeContract(request);
      onStep(step.label, hash);
      await waitFor(hash);
      last = hash;
    } else if (step.kind === "permit2") {
      const [amount, expiration] = await publicClient.readContract({ address: UNISWAP.permit2, abi: permit2Abi, functionName: "allowance", args: [owner, step.token, step.spender] });
      if (amount >= step.amount && expiration > nowSeconds() + 120) continue;
      const { request } = await publicClient.simulateContract({ address: UNISWAP.permit2, abi: permit2Abi, functionName: "approve", args: [step.token, step.spender, step.amount, nowSeconds() + 30 * 24 * 3600], account: wallet.account });
      const hash = await wallet.writeContract(request);
      onStep(step.label, hash);
      await waitFor(hash);
      last = hash;
    } else {
      await publicClient.call({ account: owner, to: step.request.to, data: step.request.data, value: step.request.value });
      const hash = await wallet.sendTransaction({ account: wallet.account, chain: wallet.chain, to: step.request.to, data: step.request.data, value: step.request.value });
      onStep(step.label, hash);
      await waitFor(hash);
      last = hash;
    }
  }
  if (!last) throw new Error("Nothing to send.");
  return last;
}

export const quoteAgeSeconds = (quote: VenueQuote) => nowSeconds() - quote.at;
export const isAddressLike = (s: string) => /^0x[0-9a-fA-F]{40}$/.test(s);
export type { Address };
