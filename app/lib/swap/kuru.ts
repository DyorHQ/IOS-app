import { getAddress, isAddress, type Address, type Hex } from "viem";
import { KURU, NATIVE } from "./config";
import { isNative } from "./tokens";
import { minAfterSlippage, nowSeconds, type PlanStep, type SwapRequest, type VenueQuote } from "./types";

/* Kuru Flow: Kuru's smart aggregator over Monad's order books and pools. The API (https://docs.kuru.io/kuru-flow)
   returns the expected output, a minimum after slippage, and a ready transaction against the KuruFlowEntrypoint.
   Auth is a per-address JWT (1 request/second), so quotes are debounced and cached per wallet. */

type KuruQuoteResponse = {
  type?: string;
  status?: string;
  message?: string;
  error?: string;
  output?: string;
  minOut?: string;
  transaction?: { calldata: string; value: string; to: string };
};

const jwtCache = new Map<string, { token: string; expiresAt: number }>();

async function jwtFor(address: Address): Promise<string> {
  const key = address.toLowerCase();
  const cached = jwtCache.get(key);
  if (cached && cached.expiresAt - 60 > nowSeconds()) return cached.token;
  const res = await fetch(`${KURU.api}/api/generate-token`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user_address: address }) });
  if (!res.ok) throw new Error(`Kuru Flow token request failed (${res.status}).`);
  const json = (await res.json()) as { token?: string; expires_at?: number };
  if (!json.token) throw new Error("Kuru Flow did not return an access token.");
  jwtCache.set(key, { token: json.token, expiresAt: json.expires_at ?? nowSeconds() + 3600 });
  return json.token;
}

export async function quoteKuru(req: SwapRequest): Promise<VenueQuote | null> {
  const user = req.account;
  const body = JSON.stringify({
    userAddress: user,
    tokenIn: isNative(req.tokenIn.address) ? NATIVE : req.tokenIn.address,
    tokenOut: isNative(req.tokenOut.address) ? NATIVE : req.tokenOut.address,
    amount: req.amountIn.toString(),
    slippageTolerance: Math.min(10_000, Math.max(1, req.slippageBps)),
  });
  const request = async (retry: boolean): Promise<Response> => {
    const token = await jwtFor(user);
    const res = await fetch(`${KURU.api}/api/quote`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body });
    if (res.status === 401 && retry) {
      jwtCache.delete(user.toLowerCase());
      return request(false);
    }
    return res;
  };
  const res = await request(true);
  if (res.status === 429) throw new Error("Kuru Flow rate limit reached. Retrying on the next refresh.");
  const json = (await res.json().catch(() => ({}))) as KuruQuoteResponse;
  if (!res.ok) throw new Error(json.message || json.error || `Kuru Flow returned ${res.status}.`);
  if (json.status !== "success" || !json.transaction || !json.output) throw new Error(json.message || "Kuru Flow could not route this trade.");
  const amountOut = BigInt(json.output);
  if (amountOut === 0n) return null;
  const calldata = json.transaction.calldata.startsWith("0x") ? json.transaction.calldata : `0x${json.transaction.calldata}`;
  // Never approve or call a contract the API chose, and never trust what it says the calldata does (as the iOS client,
  // KuruFlowClient.swift): the target must be Kuru Flow's entrypoint, the value exactly the input for a native swap and
  // zero otherwise, and the decoded swap must pay this account, trade exactly the requested amount of the requested
  // tokens, and enforce at least the minimum the requested slippage allows on the quoted output. A spoofed API that
  // inflated `output` to win the best-price race then only builds a swap that reverts.
  const blocked = () => new Error("Kuru Flow returned an unexpected transaction, so it was blocked for your safety.");
  const to = json.transaction.to;
  if (typeof to !== "string" || !isAddress(to) || getAddress(to) !== getAddress(KURU.entrypoint)) throw blocked();
  const value = BigInt(json.transaction.value || "0");
  if (value !== (isNative(req.tokenIn.address) ? req.amountIn : 0n)) throw blocked();
  const swap = decodeKuruFlowSwap(calldata);
  const slippage = Math.min(10_000, Math.max(1, req.slippageBps)); // as sent
  const expectedIn = isNative(req.tokenIn.address) ? NATIVE : getAddress(req.tokenIn.address);
  const expectedOut = isNative(req.tokenOut.address) ? NATIVE : getAddress(req.tokenOut.address);
  if (!swap || getAddress(swap.recipient ?? user) !== getAddress(user) || swap.tokenIn !== expectedIn || swap.tokenOut !== expectedOut ||
      swap.amountIn !== req.amountIn || swap.minAmountOut < minAfterSlippage(amountOut, slippage)) throw blocked();
  const minOut = swap.minAmountOut;
  const tx = { to: KURU.entrypoint, data: calldata as Hex, value };
  return {
    venue: "kuru",
    amountOut,
    minOut,
    route: "Aggregated across Kuru order books and Monad pools",
    gasEstimate: null,
    priceImpactBps: null,
    at: nowSeconds(),
    build: async (account) => {
      if (account.toLowerCase() !== user.toLowerCase()) throw new Error("This quote was made for a different wallet. Refresh the quote.");
      const steps: PlanStep[] = [];
      if (!isNative(req.tokenIn.address)) steps.push({ kind: "approve", token: req.tokenIn.address, spender: KURU.entrypoint, amount: req.amountIn, label: `Approve ${req.tokenIn.symbol} for Kuru Flow` });
      steps.push({ kind: "tx", request: tx, label: "Swap on Kuru Flow" });
      return steps;
    },
  };
}

/** A swap call on the KuruFlowEntrypoint, decoded from the calldata the Flow API returns (layout read from the
    contract's bytecode; mirrors `KuruFlowSwap` in the iOS app):
      0xce1e7030  (address tokenOut, uint256 minAmountOut, address tokenIn, uint256 amountIn,
                   (address feeRecipient, uint256 feeBps, address referrer, uint256 referrerFeeBps, bool feeOnOutput),
                   bytes route)                                      → output paid to msg.sender
      0x31343b21  the same arguments, then (address recipient)       → output paid to `recipient`
    Native MON is the zero address on either side. Null for any other selector, a short payload, or an address word
    with dirty high bytes. */
export type KuruFlowSwap = { tokenOut: Address; minAmountOut: bigint; tokenIn: Address; amountIn: bigint; recipient: Address | null };

const PAY_CALLER = "0xce1e7030";
const PAY_RECIPIENT = "0x31343b21";

export function decodeKuruFlowSwap(calldata: string): KuruFlowSwap | null {
  if (!/^0x[0-9a-fA-F]*$/.test(calldata) || (calldata.length - 2) % 2 !== 0 || calldata.length < 10) return null;
  const selector = calldata.slice(0, 10).toLowerCase();
  const explicitRecipient = selector === PAY_RECIPIENT;
  if (!explicitRecipient && selector !== PAY_CALLER) return null;
  const args = calldata.slice(10);
  const words = Math.floor(args.length / 64);
  // Ten head words (four scalars, the five-word fee tuple, the route's offset), plus the recipient.
  if (words < (explicitRecipient ? 11 : 10)) return null;
  const word = (i: number) => args.slice(i * 64, (i + 1) * 64);
  const uint = (i: number) => BigInt(`0x${word(i)}`);
  const address = (i: number): Address | null => {
    const w = word(i);
    return /^0{24}/.test(w) ? getAddress(`0x${w.slice(24)}`) : null;
  };
  const tokenOut = address(0);
  const tokenIn = address(2);
  const recipient = explicitRecipient ? address(10) : null;
  if (!tokenOut || !tokenIn || (explicitRecipient && !recipient)) return null;
  return { tokenOut, minAmountOut: uint(1), tokenIn, amountIn: uint(3), recipient };
}
