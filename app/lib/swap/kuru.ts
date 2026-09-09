import type { Address, Hex } from "viem";
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
  const minOut = json.minOut ? BigInt(json.minOut) : minAfterSlippage(amountOut, req.slippageBps);
  const calldata = json.transaction.calldata.startsWith("0x") ? json.transaction.calldata : `0x${json.transaction.calldata}`;
  const tx = { to: json.transaction.to as Address, data: calldata as Hex, value: BigInt(json.transaction.value || "0") };
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
      if (!isNative(req.tokenIn.address)) steps.push({ kind: "approve", token: req.tokenIn.address, spender: tx.to, amount: req.amountIn, label: `Approve ${req.tokenIn.symbol} for Kuru Flow` });
      steps.push({ kind: "tx", request: tx, label: "Swap on Kuru Flow" });
      return steps;
    },
  };
}
