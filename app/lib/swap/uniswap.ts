import { encodeAbiParameters, encodeFunctionData, encodePacked, keccak256, type Address, type Hex } from "viem";
import { ADDRESSES, DEPLOYED, publicClient } from "../chain";
import { LaunchpadFactoryAbi } from "../abi";
import { bpsToPct } from "../format";
import { quoterV2Abi, stateViewAbi, swapRouter02Abi, universalRouterAbi, v3FactoryAbi, v3PoolAbi, v4QuoterAbi } from "./abis";
import { HOP_TOKENS, NATIVE, SWAP_DEADLINE_SECONDS, UNISWAP, WMON } from "./config";
import { isNative, sameToken, wrapped } from "./tokens";
import { minAfterSlippage, nowSeconds, type PlanStep, type SwapRequest, type VenueQuote } from "./types";

/* Uniswap on Monad: v3 pools through SwapRouter02 and v4 pools (hookless canonical pools plus the launchpad's
   hooked pools) through the Universal Router. Quotes come from QuoterV2 and V4Quoter; the best of both is offered. */

const ZERO = "0x0000000000000000000000000000000000000000" as const;
const ROUTER_THIS = "0x0000000000000000000000000000000000000002" as const; // SwapRouter02 ADDRESS_THIS
const V4_SWAP = "0x10";
const ACTION = { SWAP_EXACT_IN_SINGLE: 0x06, SWAP_EXACT_IN: 0x07, SETTLE_ALL: 0x0c, TAKE_ALL: 0x0f } as const;
const MAX_UINT160 = (1n << 160n) - 1n;

type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };
type V3Route = { path: Address[]; fees: number[] };
type V3Candidate = { route: V3Route; amountOut: bigint; gas: bigint };
type V4Hop = { key: PoolKey; zeroForOne: boolean };
type V4Candidate = { hops: V4Hop[]; amountOut: bigint; gas: bigint };

const feeLabel = (fee: number) => bpsToPct(fee / 100, 2);
const poolId = (key: PoolKey) => keccak256(encodeAbiParameters([{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }], [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]));
const sortCurrencies = (a: Address, b: Address): [Address, Address] => (BigInt(a) < BigInt(b) ? [a, b] : [b, a]);

/* ----------------------------------------------------------------------------------------------- v3 quoting */

export type V3Venue = { factory: Address; quoter: Address; tiers: readonly number[] };

/** Finds the best single- or two-hop route on a Uniswap-v3-style venue. Shared with Monday Trade. */
export async function bestV3Route(venue: V3Venue, tokenIn: Address, tokenOut: Address, amountIn: bigint): Promise<V3Candidate | null> {
  const hops = HOP_TOKENS.filter((h) => !sameToken(h, tokenIn) && !sameToken(h, tokenOut));
  const pairs: [Address, Address][] = [[tokenIn, tokenOut], ...hops.flatMap((h): [Address, Address][] => [[tokenIn, h], [h, tokenOut]])];
  const poolCalls = pairs.flatMap(([a, b]) => venue.tiers.map((fee) => ({ address: venue.factory, abi: v3FactoryAbi, functionName: "getPool", args: [a, b, fee] }) as const));
  const pools = await publicClient.multicall({ contracts: poolCalls, allowFailure: false });
  const live = pools.map((pool, i) => ({ pool, i })).filter((x) => x.pool !== ZERO);
  if (live.length === 0) return null;
  const liquidity = await publicClient.multicall({ contracts: live.map((x) => ({ address: x.pool, abi: v3PoolAbi, functionName: "liquidity" }) as const), allowFailure: true });
  const liq = new Map<number, bigint>();
  live.forEach((x, k) => {
    const r = liquidity[k];
    if (r.status === "success" && r.result > 0n) liq.set(x.i, r.result);
  });
  // Quoter simulations are the expensive part, so only the deepest tiers are quoted: three direct tiers and the
  // deepest tier per leg of each two-hop route.
  const tiersFor = (pairIndex: number, take: number) =>
    venue.tiers
      .map((fee, t) => ({ fee, liq: liq.get(pairIndex * venue.tiers.length + t) ?? 0n }))
      .filter((x) => x.liq > 0n)
      .sort((a, b) => (b.liq > a.liq ? 1 : b.liq < a.liq ? -1 : 0))
      .slice(0, take);

  const routes: V3Route[] = tiersFor(0, 3).map((x) => ({ path: [tokenIn, tokenOut], fees: [x.fee] }));
  hops.forEach((hop, h) => {
    for (const a of tiersFor(1 + h * 2, 1)) for (const b of tiersFor(2 + h * 2, 1)) routes.push({ path: [tokenIn, hop, tokenOut], fees: [a.fee, b.fee] });
  });
  if (routes.length === 0) return null;
  const quotes = await publicClient.multicall({
    contracts: routes.map((r) =>
      r.fees.length === 1
        ? ({ address: venue.quoter, abi: quoterV2Abi, functionName: "quoteExactInputSingle", args: [{ tokenIn, tokenOut, amountIn, fee: r.fees[0], sqrtPriceLimitX96: 0n }] } as const)
        : ({ address: venue.quoter, abi: quoterV2Abi, functionName: "quoteExactInput", args: [encodeV3Path(r), amountIn] } as const),
    ),
    allowFailure: true,
  });
  let best: V3Candidate | null = null;
  quotes.forEach((q, i) => {
    if (q.status !== "success") return;
    const amountOut = q.result[0] as bigint;
    const gas = q.result[3] as bigint;
    if (!best || amountOut > best.amountOut) best = { route: routes[i], amountOut, gas };
  });
  return best;
}

export function encodeV3Path(route: V3Route): Hex {
  const types: string[] = [];
  const values: (Address | number)[] = [];
  route.path.forEach((token, i) => {
    types.push("address");
    values.push(token);
    if (i < route.fees.length) {
      types.push("uint24");
      values.push(route.fees[i]);
    }
  });
  return encodePacked(types, values);
}

export const describeV3 = (route: V3Route, symbols: string[]) => `${symbols.join(" → ")} · ${route.fees.map(feeLabel).join(" + ")}`;

/** Marginal price check: quotes a 1/1000 slice of the trade and compares the rates. */
export async function v3PriceImpact(venue: V3Venue, route: V3Route, amountIn: bigint, amountOut: bigint): Promise<number | null> {
  const slice = amountIn / 1000n;
  if (slice === 0n || amountOut === 0n) return null;
  try {
    const small = route.fees.length === 1
      ? await publicClient.readContract({ address: venue.quoter, abi: quoterV2Abi, functionName: "quoteExactInputSingle", args: [{ tokenIn: route.path[0], tokenOut: route.path[1], amountIn: slice, fee: route.fees[0], sqrtPriceLimitX96: 0n }] })
      : await publicClient.readContract({ address: venue.quoter, abi: quoterV2Abi, functionName: "quoteExactInput", args: [encodeV3Path(route), slice] });
    return impactBps(amountIn, amountOut, slice, small[0]);
  } catch {
    return null;
  }
}

export function impactBps(amountIn: bigint, amountOut: bigint, sliceIn: bigint, sliceOut: bigint): number | null {
  if (sliceOut === 0n) return null;
  // rate = out/in; impact = 1 - rate / spotRate, in bps
  const ratio = (amountOut * sliceIn * 10_000n) / (amountIn * sliceOut);
  return Number(10_000n - ratio);
}

/* ------------------------------------------------------------------------------------------------ v4 quoting */

async function launchpadKeys(tokens: Address[]): Promise<Map<string, { token: Address; key: PoolKey }>> {
  const keys = new Map<string, { token: Address; key: PoolKey }>();
  if (!DEPLOYED) return keys;
  const candidates = tokens.filter((t) => !isNative(t) && !sameToken(t, WMON));
  if (candidates.length === 0) return keys;
  const factory = { address: ADDRESSES.factory, abi: LaunchpadFactoryAbi } as const;
  const records = await publicClient.multicall({ contracts: candidates.map((t) => ({ ...factory, functionName: "getLaunchedToken", args: [t] }) as const), allowFailure: true });
  const graduated = candidates.filter((_, i) => records[i].status === "success" && (records[i].result as { exists: boolean; phase: number }).exists && (records[i].result as { phase: number }).phase === 2);
  if (graduated.length === 0) return keys;
  const poolKeys = await publicClient.multicall({ contracts: graduated.map((t) => ({ ...factory, functionName: "poolKeyOf", args: [t] }) as const), allowFailure: false });
  graduated.forEach((t, i) => keys.set(t.toLowerCase(), { token: t, key: { ...poolKeys[i] } }));
  return keys;
}

function hopFor(key: PoolKey, from: Address): V4Hop | null {
  if (sameToken(key.currency0, from)) return { key, zeroForOne: true };
  if (sameToken(key.currency1, from)) return { key, zeroForOne: false };
  return null;
}
const otherSide = (hop: V4Hop) => (hop.zeroForOne ? hop.key.currency1 : hop.key.currency0);

/** Candidate v4 routes: hookless canonical pools (direct and through native MON) and graduated launchpad pools. */
async function v4Routes(cIn: Address, cOut: Address): Promise<V4Hop[][]> {
  const canonical = (a: Address, b: Address): PoolKey[] => {
    const [c0, c1] = sortCurrencies(a, b);
    return UNISWAP.v4Tiers.map((t) => ({ currency0: c0, currency1: c1, fee: t.fee, tickSpacing: t.tickSpacing, hooks: ZERO }));
  };
  const viaNative = !isNative(cIn) && !isNative(cOut);
  const probe: PoolKey[] = [...canonical(cIn, cOut), ...(viaNative ? [...canonical(cIn, NATIVE), ...canonical(NATIVE, cOut)] : [])];
  const [liquidity, launchKeys] = await Promise.all([
    publicClient.multicall({ contracts: probe.map((key) => ({ address: UNISWAP.stateView, abi: stateViewAbi, functionName: "getLiquidity", args: [poolId(key)] }) as const), allowFailure: true }),
    launchpadKeys([cIn, cOut]),
  ]);
  const alive = (key: PoolKey, i: number) => liquidity[i].status === "success" && (liquidity[i].result as bigint) > 0n;
  const direct = probe.slice(0, 4).filter(alive);
  const routes: V4Hop[][] = direct.map((key) => [hopFor(key, cIn)!]);
  if (viaNative) {
    const leg1 = probe.slice(4, 8).filter((k, i) => alive(k, i + 4));
    const leg2 = probe.slice(8, 12).filter((k, i) => alive(k, i + 8));
    for (const a of leg1) for (const b of leg2) routes.push([hopFor(a, cIn)!, hopFor(b, NATIVE)!]);
  }
  // Launchpad pools pair a token with its quote asset; reach them directly or through native MON.
  for (const { token, key } of launchKeys.values()) {
    const quote = sameToken(key.currency0, token) ? key.currency1 : key.currency0;
    if (sameToken(cOut, token)) {
      if (sameToken(cIn, quote)) routes.push([hopFor(key, cIn)!]);
      else if (isNative(quote)) for (const a of probe.slice(4, 8).filter((k, i) => alive(k, i + 4))) routes.push([hopFor(a, cIn)!, hopFor(key, NATIVE)!]);
    } else if (sameToken(cIn, token)) {
      if (sameToken(cOut, quote)) routes.push([hopFor(key, cIn)!]);
      else if (isNative(quote)) for (const b of probe.slice(8, 12).filter((k, i) => alive(k, i + 8))) routes.push([hopFor(key, cIn)!, hopFor(b, NATIVE)!]);
    }
  }
  return routes.filter((r) => r.every(Boolean));
}

const pathKeys = (hops: V4Hop[]) => hops.map((h) => ({ intermediateCurrency: otherSide(h), fee: h.key.fee, tickSpacing: h.key.tickSpacing, hooks: h.key.hooks, hookData: "0x" as Hex }));
function v4QuoteCall(cIn: Address, hops: V4Hop[], amountIn: bigint) {
  if (hops.length === 1) {
    return { address: UNISWAP.v4Quoter, abi: v4QuoterAbi, functionName: "quoteExactInputSingle", args: [{ poolKey: hops[0].key, zeroForOne: hops[0].zeroForOne, exactAmount: amountIn, hookData: "0x" }] } as const;
  }
  return { address: UNISWAP.v4Quoter, abi: v4QuoterAbi, functionName: "quoteExactInput", args: [{ exactCurrency: cIn, path: pathKeys(hops), exactAmount: amountIn }] } as const;
}
async function quoteV4Once(cIn: Address, hops: V4Hop[], amountIn: bigint): Promise<bigint> {
  const result = hops.length === 1
    ? await publicClient.readContract({ address: UNISWAP.v4Quoter, abi: v4QuoterAbi, functionName: "quoteExactInputSingle", args: [{ poolKey: hops[0].key, zeroForOne: hops[0].zeroForOne, exactAmount: amountIn, hookData: "0x" }] })
    : await publicClient.readContract({ address: UNISWAP.v4Quoter, abi: v4QuoterAbi, functionName: "quoteExactInput", args: [{ exactCurrency: cIn, path: pathKeys(hops), exactAmount: amountIn }] });
  return result[0];
}

async function bestV4(cIn: Address, cOut: Address, amountIn: bigint): Promise<V4Candidate | null> {
  const routes = await v4Routes(cIn, cOut);
  if (routes.length === 0) return null;
  const results = await publicClient.multicall({ contracts: routes.map((hops) => v4QuoteCall(cIn, hops, amountIn)), allowFailure: true });
  let best: V4Candidate | null = null;
  results.forEach((r, i) => {
    if (r.status !== "success") return;
    const [amountOut, gas] = r.result as readonly [bigint, bigint];
    if (!best || amountOut > best.amountOut) best = { hops: routes[i], amountOut, gas };
  });
  return best;
}

function describeV4(hops: V4Hop[], cIn: Address, symbols: { in: string; out: string }) {
  const names = [symbols.in];
  hops.forEach((h, i) => names.push(i === hops.length - 1 ? symbols.out : isNative(otherSide(h)) ? "MON" : "…"));
  const fees = hops.map((h) => (h.key.hooks === ZERO ? feeLabel(h.key.fee) : "launchpad")).join(" + ");
  return `v4 · ${names.join(" → ")} · ${fees}`;
}

/* --------------------------------------------------------------------------------------------- transactions */

export function buildSwapRouter02Tx(route: V3Route, amountIn: bigint, minOut: bigint, account: Address, nativeIn: boolean, nativeOut: boolean, deadline: bigint) {
  const recipient = nativeOut ? ROUTER_THIS : account;
  const swap = route.fees.length === 1
    ? encodeFunctionData({ abi: swapRouter02Abi, functionName: "exactInputSingle", args: [{ tokenIn: route.path[0], tokenOut: route.path[1], fee: route.fees[0], recipient, amountIn, amountOutMinimum: minOut, sqrtPriceLimitX96: 0n }] })
    : encodeFunctionData({ abi: swapRouter02Abi, functionName: "exactInput", args: [{ path: encodeV3Path(route), recipient, amountIn, amountOutMinimum: minOut }] });
  const calls: Hex[] = [swap];
  if (nativeOut) calls.push(encodeFunctionData({ abi: swapRouter02Abi, functionName: "unwrapWETH9", args: [minOut, account] }));
  if (nativeIn) calls.push(encodeFunctionData({ abi: swapRouter02Abi, functionName: "refundETH" }));
  return { to: UNISWAP.swapRouter02, data: encodeFunctionData({ abi: swapRouter02Abi, functionName: "multicall", args: [deadline, calls] }), value: nativeIn ? amountIn : 0n };
}

function buildUniversalRouterV4Tx(cIn: Address, cOut: Address, hops: V4Hop[], amountIn: bigint, minOut: bigint, deadline: bigint) {
  const swap = hops.length === 1
    ? encodeAbiParameters(
        [{ type: "tuple", components: [{ type: "tuple", name: "poolKey", components: [{ type: "address", name: "currency0" }, { type: "address", name: "currency1" }, { type: "uint24", name: "fee" }, { type: "int24", name: "tickSpacing" }, { type: "address", name: "hooks" }] }, { type: "bool", name: "zeroForOne" }, { type: "uint128", name: "amountIn" }, { type: "uint128", name: "amountOutMinimum" }, { type: "bytes", name: "hookData" }] }],
        [{ poolKey: hops[0].key, zeroForOne: hops[0].zeroForOne, amountIn, amountOutMinimum: minOut, hookData: "0x" }],
      )
    : encodeAbiParameters(
        [{ type: "tuple", components: [{ type: "address", name: "currencyIn" }, { type: "tuple[]", name: "path", components: [{ type: "address", name: "intermediateCurrency" }, { type: "uint24", name: "fee" }, { type: "int24", name: "tickSpacing" }, { type: "address", name: "hooks" }, { type: "bytes", name: "hookData" }] }, { type: "uint128", name: "amountIn" }, { type: "uint128", name: "amountOutMinimum" }] }],
        [{ currencyIn: cIn, path: pathKeys(hops), amountIn, amountOutMinimum: minOut }],
      );
  const actions = encodePacked(["uint8", "uint8", "uint8"], [hops.length === 1 ? ACTION.SWAP_EXACT_IN_SINGLE : ACTION.SWAP_EXACT_IN, ACTION.SETTLE_ALL, ACTION.TAKE_ALL]);
  const params: Hex[] = [
    swap,
    encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [cIn, amountIn]),
    encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [cOut, minOut]),
  ];
  const input = encodeAbiParameters([{ type: "bytes" }, { type: "bytes[]" }], [actions, params]);
  return { to: UNISWAP.universalRouter, data: encodeFunctionData({ abi: universalRouterAbi, functionName: "execute", args: [V4_SWAP, [input], deadline] }), value: isNative(cIn) ? amountIn : 0n };
}

/* ---------------------------------------------------------------------------------------------------- quote */

export async function quoteUniswap(req: SwapRequest): Promise<VenueQuote | null> {
  const tokenIn = wrapped(req.tokenIn.address);
  const tokenOut = wrapped(req.tokenOut.address);
  if (sameToken(tokenIn, tokenOut)) return null;
  const nativeIn = isNative(req.tokenIn.address);
  const nativeOut = isNative(req.tokenOut.address);
  // v4 pools hold native MON directly; WMON legs stay on v3.
  const v4Eligible = !sameToken(req.tokenIn.address, WMON) && !sameToken(req.tokenOut.address, WMON);
  const venue: V3Venue = { factory: UNISWAP.v3Factory, quoter: UNISWAP.quoterV2, tiers: UNISWAP.v3FeeTiers };
  const [v3, v4] = await Promise.all([
    bestV3Route(venue, tokenIn, tokenOut, req.amountIn).catch(() => null),
    v4Eligible ? bestV4(req.tokenIn.address, req.tokenOut.address, req.amountIn).catch(() => null) : Promise.resolve(null),
  ]);
  if (!v3 && !v4) return null;
  const useV4 = !!v4 && (!v3 || v4.amountOut >= v3.amountOut);
  const amountOut = useV4 ? v4!.amountOut : v3!.amountOut;
  const minOut = minAfterSlippage(amountOut, req.slippageBps);
  let priceImpactBps: number | null = null;
  if (useV4) {
    const slice = req.amountIn / 1000n;
    if (slice > 0n) {
      try {
        priceImpactBps = impactBps(req.amountIn, amountOut, slice, await quoteV4Once(req.tokenIn.address, v4!.hops, slice));
      } catch { /* impact stays unknown */ }
    }
  } else priceImpactBps = await v3PriceImpact(venue, v3!.route, req.amountIn, amountOut);
  const symbols = [req.tokenIn.symbol, ...(v3 && v3.route.path.length === 3 ? [hopSymbol(v3.route.path[1])] : []), req.tokenOut.symbol];
  return {
    venue: "uniswap",
    amountOut,
    minOut,
    route: useV4 ? describeV4(v4!.hops, req.tokenIn.address, { in: req.tokenIn.symbol, out: req.tokenOut.symbol }) : `v3 · ${describeV3(v3!.route, symbols)}`,
    gasEstimate: useV4 ? v4!.gas : v3!.gas,
    priceImpactBps,
    at: nowSeconds(),
    build: async (account) => {
      const deadline = BigInt(nowSeconds() + SWAP_DEADLINE_SECONDS);
      const steps: PlanStep[] = [];
      if (useV4) {
        if (!nativeIn) {
          steps.push({ kind: "approve", token: req.tokenIn.address, spender: UNISWAP.permit2, amount: MAX_UINT160, label: `Approve ${req.tokenIn.symbol} for Permit2` });
          steps.push({ kind: "permit2", token: req.tokenIn.address, spender: UNISWAP.universalRouter, amount: req.amountIn, label: `Allow the Universal Router to spend ${req.tokenIn.symbol}` });
        }
        steps.push({ kind: "tx", request: buildUniversalRouterV4Tx(req.tokenIn.address, req.tokenOut.address, v4!.hops, req.amountIn, minOut, deadline), label: `Swap on Uniswap v4` });
      } else {
        if (!nativeIn) steps.push({ kind: "approve", token: req.tokenIn.address, spender: UNISWAP.swapRouter02, amount: req.amountIn, label: `Approve ${req.tokenIn.symbol} for Uniswap` });
        steps.push({ kind: "tx", request: buildSwapRouter02Tx(v3!.route, req.amountIn, minOut, account, nativeIn, nativeOut, deadline), label: `Swap on Uniswap v3` });
      }
      return steps;
    },
  };
}

const HOP_SYMBOLS: Record<string, string> = { [WMON.toLowerCase()]: "WMON", "0x754704bc059f8c67012fed69bc8a327a5aafb603": "USDC", "0xe7cd86e13ac4309349f30b3435a9d337750fc82d": "USDT0", "0xee8c0e9f1bffb4eb878d8f15f368a02a35481242": "WETH" };
export const hopSymbol = (address: Address) => HOP_SYMBOLS[address.toLowerCase()] ?? "…";
