import type { Address, Hex } from "viem";
import type { TokenInfo } from "./tokens";

export type Venue = "kuru" | "uniswap" | "monday" | "wmon";
export const VENUE_LABEL: Record<Venue, string> = { kuru: "Kuru Flow", uniswap: "Uniswap", monday: "Monday Trade", wmon: "Wrap" };

export type SwapRequest = {
  tokenIn: TokenInfo;
  tokenOut: TokenInfo;
  amountIn: bigint;
  slippageBps: number;
  /** Wallet that receives the output; a placeholder when nothing is connected. */
  account: Address;
};

export type TxRequest = { to: Address; data: Hex; value: bigint };

export type PlanStep =
  | { kind: "approve"; token: Address; spender: Address; amount: bigint; label: string }
  | { kind: "permit2"; token: Address; spender: Address; amount: bigint; label: string }
  | { kind: "tx"; request: TxRequest; label: string };

export type VenueQuote = {
  venue: Venue;
  amountOut: bigint;
  minOut: bigint;
  /** Short human route, e.g. "v4 · MON → USDC · 0.05%". */
  route: string;
  gasEstimate: bigint | null;
  /** Negative-for-worse price impact in basis points versus the venue's own marginal price; null when unknown. */
  priceImpactBps: number | null;
  /** Unix seconds when the quote was produced. */
  at: number;
  /** Builds the transaction plan for the connected account (approvals first, then the swap). */
  build: (account: Address) => Promise<PlanStep[]>;
};

export type QuoteResult = { quotes: VenueQuote[]; errors: Partial<Record<Venue, string>> };

export const minAfterSlippage = (amount: bigint, slippageBps: number) => (amount * BigInt(10_000 - slippageBps)) / 10_000n;
export const nowSeconds = () => Math.floor(Date.now() / 1000);
