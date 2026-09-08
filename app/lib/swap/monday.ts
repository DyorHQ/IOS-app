import { encodeFunctionData, type Address, type Hex } from "viem";
import { swapRouterV1Abi } from "./abis";
import { MONDAY, SWAP_DEADLINE_SECONDS } from "./config";
import { isNative, sameToken, wrapped } from "./tokens";
import { minAfterSlippage, nowSeconds, type PlanStep, type SwapRequest, type VenueQuote } from "./types";
import { bestV3Route, describeV3, encodeV3Path, hopSymbol, v3PriceImpact, type V3Venue } from "./uniswap";

/* Monday Trade spot: concentrated-liquidity pools with an embedded order book, exposed through a Uniswap-v3-style
   QuoterV2 and a SwapRouter with the v1 layout (deadline inside the params, multicall(bytes[])). Verified against
   the router's bytecode selectors on Monad mainnet. */

const ZERO = "0x0000000000000000000000000000000000000000" as const;
const venue: V3Venue = { factory: MONDAY.factory, quoter: MONDAY.quoterV2, tiers: MONDAY.feeTiers };

function buildTx(route: { path: Address[]; fees: number[] }, amountIn: bigint, minOut: bigint, account: Address, nativeIn: boolean, nativeOut: boolean, deadline: bigint) {
  // The v1 router treats recipient address(0) as itself, which is what unwrapWETH9 needs afterwards.
  const recipient = nativeOut ? ZERO : account;
  const swap = route.fees.length === 1
    ? encodeFunctionData({ abi: swapRouterV1Abi, functionName: "exactInputSingle", args: [{ tokenIn: route.path[0], tokenOut: route.path[1], fee: route.fees[0], recipient, deadline, amountIn, amountOutMinimum: minOut, sqrtPriceLimitX96: 0n }] })
    : encodeFunctionData({ abi: swapRouterV1Abi, functionName: "exactInput", args: [{ path: encodeV3Path(route), recipient, deadline, amountIn, amountOutMinimum: minOut }] });
  const calls: Hex[] = [swap];
  if (nativeOut) calls.push(encodeFunctionData({ abi: swapRouterV1Abi, functionName: "unwrapWETH9", args: [minOut, account] }));
  if (nativeIn) calls.push(encodeFunctionData({ abi: swapRouterV1Abi, functionName: "refundETH" }));
  return { to: MONDAY.swapRouter, data: encodeFunctionData({ abi: swapRouterV1Abi, functionName: "multicall", args: [calls] }), value: nativeIn ? amountIn : 0n };
}

export async function quoteMonday(req: SwapRequest): Promise<VenueQuote | null> {
  const tokenIn = wrapped(req.tokenIn.address);
  const tokenOut = wrapped(req.tokenOut.address);
  if (sameToken(tokenIn, tokenOut)) return null;
  const best = await bestV3Route(venue, tokenIn, tokenOut, req.amountIn);
  if (!best) return null;
  const minOut = minAfterSlippage(best.amountOut, req.slippageBps);
  const nativeIn = isNative(req.tokenIn.address);
  const nativeOut = isNative(req.tokenOut.address);
  const symbols = [req.tokenIn.symbol, ...(best.route.path.length === 3 ? [hopSymbol(best.route.path[1])] : []), req.tokenOut.symbol];
  return {
    venue: "monday",
    amountOut: best.amountOut,
    minOut,
    route: describeV3(best.route, symbols),
    gasEstimate: best.gas,
    priceImpactBps: await v3PriceImpact(venue, best.route, req.amountIn, best.amountOut),
    at: nowSeconds(),
    build: async (account) => {
      const steps: PlanStep[] = [];
      if (!nativeIn) steps.push({ kind: "approve", token: req.tokenIn.address, spender: MONDAY.swapRouter, amount: req.amountIn, label: `Approve ${req.tokenIn.symbol} for Monday Trade` });
      steps.push({ kind: "tx", request: buildTx(best.route, req.amountIn, minOut, account, nativeIn, nativeOut, BigInt(nowSeconds() + SWAP_DEADLINE_SECONDS)), label: "Swap on Monday Trade" });
      return steps;
    },
  };
}
