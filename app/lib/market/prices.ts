import { keccak256, encodeAbiParameters, parseAbi, type Address } from "viem";
import { publicClient } from "../chain";
import { stateViewAbi, v3FactoryAbi, v3PoolAbi } from "../swap/abis";
import { NATIVE, UNISWAP, WMON } from "../swap/config";
import { isNative, sameToken, type TokenInfo } from "../swap/tokens";

/* Spot prices straight from the deepest on-chain pool for each token, quoted in USDC, plus the same read 24 hours
   earlier (Monad's public RPCs serve historical state) for the 24h change. Nothing here depends on an indexer. */

export type PriceInfo = { usd: number; change24h: number | null; source: string };
export type PriceMap = Record<string, PriceInfo>;

const USDC: Address = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603";
const BLOCKS_PER_DAY = 216_000n; // ~0.4 s blocks
const ZERO = "0x0000000000000000000000000000000000000000" as const;
const poolSlot0Abi = parseAbi(["function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)"]);

type Source = { kind: "v4"; poolId: `0x${string}`; token: Address; quote: Address } | { kind: "v3"; pool: Address; token: Address; quote: Address; token0: Address };
const discovered = new Map<string, Source | null>();

const poolId = (c0: Address, c1: Address, fee: number, tickSpacing: number) => keccak256(encodeAbiParameters([{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }], [c0, c1, fee, tickSpacing, ZERO]));

/** price of `token` in `quote` units per whole token, from a sqrtPriceX96 of a pool whose token0/token1 are known. */
function priceFromSqrt(sqrtPriceX96: bigint, token: Address, token0: Address, decToken: number, decQuote: number): number {
  const ratio = Number(sqrtPriceX96) / 2 ** 96; // sqrt(token1 per token0 in raw units)
  const price1per0 = ratio * ratio;
  const tokenIs0 = sameToken(token, token0);
  const raw = tokenIs0 ? price1per0 : 1 / price1per0; // quote-raw per token-raw
  return raw * 10 ** (decToken - decQuote);
}

async function discover(tokens: TokenInfo[]): Promise<void> {
  const todo = tokens.filter((t) => !discovered.has(t.address.toLowerCase()) && !isUsd(t));
  if (todo.length === 0) return;
  // v4 candidates: native MON vs USDC at the canonical tiers. v3 candidates: token vs USDC and token vs WMON.
  const v4Ids = UNISWAP.v4Tiers.map((t) => poolId(NATIVE, USDC, t.fee, t.tickSpacing));
  const v3Pairs: { token: Address; quote: Address; fee: number }[] = [];
  for (const t of todo) {
    const base = isNative(t.address) ? WMON : t.address;
    for (const quote of [USDC, WMON]) if (!sameToken(base, quote)) for (const fee of UNISWAP.v3FeeTiers) v3Pairs.push({ token: base, quote, fee });
  }
  const [v4Liq, v3Pools] = await Promise.all([
    publicClient.multicall({ contracts: v4Ids.map((id) => ({ address: UNISWAP.stateView, abi: stateViewAbi, functionName: "getLiquidity", args: [id] }) as const), allowFailure: true }),
    publicClient.multicall({ contracts: v3Pairs.map((p) => ({ address: UNISWAP.v3Factory, abi: v3FactoryAbi, functionName: "getPool", args: [p.token, p.quote, p.fee] }) as const), allowFailure: false }),
  ]);
  const existing = v3Pools.map((pool, i) => ({ pool, i })).filter((x) => x.pool !== ZERO);
  const [liqs, token0s] = await Promise.all([
    publicClient.multicall({ contracts: existing.map((x) => ({ address: x.pool, abi: v3PoolAbi, functionName: "liquidity" }) as const), allowFailure: true }),
    publicClient.multicall({ contracts: existing.map((x) => ({ address: x.pool, abi: parseAbi(["function token0() view returns (address)"]), functionName: "token0" }) as const), allowFailure: true }),
  ]);
  const bestV3 = new Map<string, { liq: bigint; src: Source }>();
  existing.forEach((x, k) => {
    const liq = liqs[k].status === "success" ? (liqs[k].result as bigint) : 0n;
    const token0 = token0s[k].status === "success" ? (token0s[k].result as Address) : null;
    if (liq === 0n || !token0) return;
    const p = v3Pairs[x.i];
    // Prefer USDC-quoted pools; a WMON-quoted pool only wins when no USDC pool has liquidity.
    const key = p.token.toLowerCase();
    const weight = sameToken(p.quote, USDC) ? liq * 1_000_000n : liq;
    const prev = bestV3.get(key);
    if (!prev || weight > prev.liq) bestV3.set(key, { liq: weight, src: { kind: "v3", pool: x.pool, token: p.token, quote: p.quote, token0 } });
  });
  let v4Best: { liq: bigint; id: `0x${string}` } | null = null;
  for (let i = 0; i < v4Liq.length; i++) {
    const r = v4Liq[i];
    if (r.status !== "success") continue;
    const liq = r.result as bigint;
    if (liq > 0n && (v4Best === null || liq > v4Best.liq)) v4Best = { liq, id: v4Ids[i] };
  }
  for (const t of todo) {
    const key = t.address.toLowerCase();
    if (isNative(t.address) || sameToken(t.address, WMON)) {
      discovered.set(key, v4Best ? { kind: "v4", poolId: v4Best.id, token: NATIVE, quote: USDC } : (bestV3.get(WMON.toLowerCase())?.src ?? null));
    } else discovered.set(key, bestV3.get(key)?.src ?? null);
  }
}

const isUsd = (t: TokenInfo) => sameToken(t.address, USDC);

async function readPrices(tokens: TokenInfo[], blockNumber?: bigint): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  const calls: { key: string; src: Source }[] = [];
  for (const t of tokens) {
    const src = discovered.get(t.address.toLowerCase());
    if (src) calls.push({ key: t.address.toLowerCase(), src });
  }
  if (calls.length === 0) return out;
  const results = await publicClient.multicall({
    contracts: calls.map(({ src }) => src.kind === "v4"
      ? ({ address: UNISWAP.stateView, abi: stateViewAbi, functionName: "getSlot0", args: [src.poolId] } as const)
      : ({ address: src.pool, abi: poolSlot0Abi, functionName: "slot0" } as const)),
    allowFailure: true,
    blockNumber,
  });
  const byAddress = new Map(tokens.map((t) => [t.address.toLowerCase(), t]));
  results.forEach((r, i) => {
    if (r.status !== "success") return;
    const { key, src } = calls[i];
    const sqrt = (r.result as readonly unknown[])[0] as bigint;
    const token = byAddress.get(key)!;
    const quoteDecimals = sameToken(src.quote, USDC) ? 6 : 18;
    const price = src.kind === "v4" ? priceFromSqrt(sqrt, NATIVE, NATIVE, 18, 6) : priceFromSqrt(sqrt, src.token, src.token0, token.decimals, quoteDecimals);
    out.set(key, price);
  });
  // WMON-quoted prices become USD through MON's own price.
  for (const { key, src } of calls) {
    if (src.kind === "v3" && sameToken(src.quote, WMON)) {
      const mon = out.get(NATIVE) ?? out.get(WMON.toLowerCase());
      const v = out.get(key);
      if (mon !== undefined && v !== undefined) out.set(key, v * mon);
      else out.delete(key);
    }
  }
  return out;
}

/** USD price and 24h change for every token that has a discoverable pool. USDC is 1 by definition. */
export async function loadPrices(tokens: TokenInfo[]): Promise<PriceMap> {
  await discover(tokens);
  const latest = await publicClient.getBlockNumber();
  const dayAgo = latest > BLOCKS_PER_DAY ? latest - BLOCKS_PER_DAY : undefined;
  const [now, before] = await Promise.all([readPrices(tokens), dayAgo ? readPrices(tokens, dayAgo).catch(() => new Map<string, number>()) : Promise.resolve(new Map<string, number>())]);
  const map: PriceMap = {};
  for (const t of tokens) {
    const key = t.address.toLowerCase();
    if (isUsd(t)) { map[key] = { usd: 1, change24h: 0, source: "USDC" }; continue; }
    const usd = now.get(key);
    if (usd === undefined) continue;
    const prev = before.get(key);
    const src = discovered.get(key);
    map[key] = { usd, change24h: prev ? ((usd - prev) / prev) * 100 : null, source: src?.kind === "v4" ? "Uniswap v4" : "Uniswap v3" };
  }
  return map;
}

export const usdValue = (amount: bigint, decimals: number, price: number | undefined) => (price === undefined ? null : (Number(amount) / 10 ** decimals) * price);
