import { createPublicClient, http, parseAbiItem, type Address, type Hex } from "viem";
import { monad } from "viem/chains";
import { ADDRESSES, DEPLOYED, RPC_URL, publicClient } from "../chain";
import type { Candle } from "../../ui/tradingview";

/* On-chain history without an indexer: `eth_getLogs` over recent blocks in chunks. Monad's public endpoints cap
   the range per call (rpc.monad.xyz 100 blocks, rpc1.monad.xyz 1000 blocks), so the client picks a chunk size for
   the endpoint it talks to and fans requests out in parallel. Windows are deliberately recent (hours, not months). */

const LOGS_RPC = /127\.0\.0\.1|localhost/.test(RPC_URL) ? RPC_URL : "https://rpc1.monad.xyz";
const CHUNK = /127\.0\.0\.1|localhost/.test(LOGS_RPC) ? 50_000n : /rpc1|rpc3/.test(LOGS_RPC) ? 1_000n : 100n;
const BLOCK_SECONDS = 0.4;
export const logsClient = createPublicClient({ chain: monad, transport: http(LOGS_RPC, { batch: true }) });

export const EVENTS = {
  buy: parseAbiItem("event CurveBuy(address indexed buyer, address indexed recipient, uint256 quoteIn, uint256 tokensOut, uint256 fee, uint256 tax)"),
  sell: parseAbiItem("event CurveSell(address indexed seller, address indexed recipient, uint256 tokensIn, uint256 quoteOut, uint256 fee, uint256 tax)"),
  launched: parseAbiItem("event TokenLaunched(address indexed token, address indexed curve, address indexed deployer, address pairToken, uint256 launchConfigId, uint256 graduationThreshold)"),
  graduated: parseAbiItem("event PoolGraduated(address indexed token, bytes32 indexed poolId, uint128 liquidity)"),
};

export type CurveTrade = { block: number; time: number; tx: Hex; curve: Address; trader: Address; side: "buy" | "sell"; quote: bigint; tokens: bigint; price: number };
export type ActivityItem =
  | { kind: "launch"; block: number; time: number; tx: Hex; token: Address; curve: Address; deployer: Address }
  | { kind: "trade"; block: number; time: number; tx: Hex; token: Address | null; curve: Address; trader: Address; side: "buy" | "sell"; quote: bigint; tokens: bigint }
  | { kind: "graduated"; block: number; time: number; tx: Hex; token: Address; poolId: Hex };

type Anchor = { block: bigint; time: number };
async function anchor(): Promise<Anchor> {
  const b = await publicClient.getBlock({ blockTag: "latest" });
  return { block: b.number, time: Number(b.timestamp) };
}
const timeOf = (a: Anchor, block: bigint) => Math.round(a.time - Number(a.block - block) * BLOCK_SECONDS);

/** Splits [from, to] into chunks the endpoint accepts and runs them with bounded concurrency. */
async function chunkedLogs<T>(from: bigint, to: bigint, fetchRange: (a: bigint, b: bigint) => Promise<T[]>, concurrency = 6): Promise<T[]> {
  const ranges: [bigint, bigint][] = [];
  for (let start = from; start <= to; start += CHUNK) ranges.push([start, start + CHUNK - 1n > to ? to : start + CHUNK - 1n]);
  const out: T[] = [];
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(concurrency, ranges.length) }, async () => {
    while (next < ranges.length) {
      const [a, b] = ranges[next++];
      try { out.push(...(await fetchRange(a, b))); } catch { /* a failed chunk leaves a gap rather than failing the whole window */ }
    }
  }));
  return out;
}

/** Curve trades for one launch over the last `blocks` blocks (default ≈ 2 hours), newest last. */
export async function fetchCurveTrades(curve: Address, blocks = 18_000n): Promise<CurveTrade[]> {
  const a = await anchor();
  const from = a.block > blocks ? a.block - blocks : 0n;
  const [buys, sells] = await Promise.all([
    chunkedLogs(from, a.block, (x, y) => logsClient.getLogs({ address: curve, event: EVENTS.buy, fromBlock: x, toBlock: y })),
    chunkedLogs(from, a.block, (x, y) => logsClient.getLogs({ address: curve, event: EVENTS.sell, fromBlock: x, toBlock: y })),
  ]);
  const trades: CurveTrade[] = [
    ...buys.map((l) => ({ block: Number(l.blockNumber), time: timeOf(a, l.blockNumber), tx: l.transactionHash, curve, trader: l.args.buyer!, side: "buy" as const, quote: l.args.quoteIn! - l.args.fee! - l.args.tax!, tokens: l.args.tokensOut! })),
    ...sells.map((l) => ({ block: Number(l.blockNumber), time: timeOf(a, l.blockNumber), tx: l.transactionHash, curve, trader: l.args.seller!, side: "sell" as const, quote: l.args.quoteOut! + l.args.fee! + l.args.tax!, tokens: l.args.tokensIn! })),
  ].map((t) => ({ ...t, price: t.tokens === 0n ? 0 : Number(t.quote) / Number(t.tokens) }));
  return trades.sort((x, y) => x.block - y.block);
}

/** OHLC candles from trades (price = quote per token, both in raw units, so scale by 10^(18 - quoteDecimals) for display). */
export function candlesFromTrades(trades: CurveTrade[], intervalSec: number, scale = 1): Candle[] {
  const buckets = new Map<number, Candle>();
  for (const t of trades) {
    if (t.price <= 0) continue;
    const bucket = Math.floor(t.time / intervalSec) * intervalSec;
    const price = t.price * scale;
    const c = buckets.get(bucket);
    if (!c) buckets.set(bucket, { time: bucket, open: price, high: price, low: price, close: price, volume: Number(t.quote) });
    else { c.high = Math.max(c.high, price); c.low = Math.min(c.low, price); c.close = price; c.volume = (c.volume ?? 0) + Number(t.quote); }
  }
  const out = [...buckets.values()].sort((a, b) => a.time - b.time);
  // Carry the close forward through empty buckets so the chart has no holes.
  const filled: Candle[] = [];
  for (let i = 0; i < out.length; i++) {
    filled.push(out[i]);
    const next = out[i + 1];
    if (next) for (let t = out[i].time + intervalSec; t < next.time && filled.length < 2000; t += intervalSec) filled.push({ time: t, open: out[i].close, high: out[i].close, low: out[i].close, close: out[i].close, volume: 0 });
  }
  return filled;
}

/** Everything that happened on the launchpad in the last `blocks` blocks: launches, curve trades, graduations. */
export async function fetchLaunchpadActivity(curves: Map<string, Address>, blocks = 9_000n): Promise<ActivityItem[]> {
  if (!DEPLOYED) return [];
  const a = await anchor();
  const from = a.block > blocks ? a.block - blocks : 0n;
  const factory = ADDRESSES.factory;
  const [launches, grads, buys, sells] = await Promise.all([
    chunkedLogs(from, a.block, (x, y) => logsClient.getLogs({ address: factory, event: EVENTS.launched, fromBlock: x, toBlock: y })),
    chunkedLogs(from, a.block, (x, y) => logsClient.getLogs({ address: factory, event: EVENTS.graduated, fromBlock: x, toBlock: y })),
    chunkedLogs(from, a.block, (x, y) => logsClient.getLogs({ event: EVENTS.buy, fromBlock: x, toBlock: y })),
    chunkedLogs(from, a.block, (x, y) => logsClient.getLogs({ event: EVENTS.sell, fromBlock: x, toBlock: y })),
  ]);
  const known = (addr: Address) => curves.get(addr.toLowerCase());
  const items: ActivityItem[] = [
    ...launches.map((l): ActivityItem => ({ kind: "launch", block: Number(l.blockNumber), time: timeOf(a, l.blockNumber), tx: l.transactionHash, token: l.args.token!, curve: l.args.curve!, deployer: l.args.deployer! })),
    ...grads.map((l): ActivityItem => ({ kind: "graduated", block: Number(l.blockNumber), time: timeOf(a, l.blockNumber), tx: l.transactionHash, token: l.args.token!, poolId: l.args.poolId! })),
    ...buys.filter((l) => known(l.address)).map((l): ActivityItem => ({ kind: "trade", block: Number(l.blockNumber), time: timeOf(a, l.blockNumber), tx: l.transactionHash, token: known(l.address) ?? null, curve: l.address, trader: l.args.buyer!, side: "buy", quote: l.args.quoteIn!, tokens: l.args.tokensOut! })),
    ...sells.filter((l) => known(l.address)).map((l): ActivityItem => ({ kind: "trade", block: Number(l.blockNumber), time: timeOf(a, l.blockNumber), tx: l.transactionHash, token: known(l.address) ?? null, curve: l.address, trader: l.args.seller!, side: "sell", quote: l.args.quoteOut!, tokens: l.args.tokensIn! })),
  ];
  return items.sort((x, y) => y.block - x.block);
}
