import { createPublicClient, http, parseAbiItem, type Address } from "viem";
import { monad } from "viem/chains";
import { publicClient } from "../chain";
import { LOGS_RPC, MOMENTS, MOMENTS_DEPLOY_BLOCK } from "./config";

/* Holder statistics for a Moment coin, rebuilt from Transfer logs (there is no indexer yet). The pool and the
   locker are protocol addresses and are reported separately from wallets. Results are cached per coin and scans
   resume from the last block seen. Containment UI (spec §12): holder count + top-holder share on every coin. */

/** Plain numbers only (display precision is enough here), so this state serializes anywhere. */
export type HolderStats = {
  holders: number; // wallets with a non-zero balance (pool, locker and vesting excluded)
  topHolder: Address | null;
  topHolderBps: number; // share of the circulating supply held by the largest wallet
  circulatingCoins: number; // whole coins outside the pool and the locker
  poolBps: number; // share of minted supply sitting in the pool
  mintedCoins: number;
  scannedTo: number;
};

const transferEvent = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 value)");
const logsClient = createPublicClient({ chain: monad, transport: http(LOGS_RPC) });
const CHUNK = 200_000n; // rpc1.monad.xyz answers a full day (~216k blocks) per call
const MIN_CHUNK = 100n;
const ZERO = "0x0000000000000000000000000000000000000000";

type Cache = { balances: Map<string, bigint>; scannedTo: bigint };
const cache = new Map<string, Cache>();

/** Estimates the block a timestamp falls in from the chain's recent block time (never before the factory's deployment). */
async function blockAt(timestamp: number): Promise<bigint> {
  const latest = await publicClient.getBlock();
  const back = latest.number > 20_000n ? latest.number - 20_000n : 0n;
  const older = await publicClient.getBlock({ blockNumber: back });
  const secondsPerBlock = Math.max(0.1, Number(latest.timestamp - older.timestamp) / Number(latest.number - older.number || 1n));
  const age = Math.max(0, Number(latest.timestamp) - timestamp);
  const estimate = latest.number - BigInt(Math.ceil((age / secondsPerBlock) * 1.25));
  return estimate > MOMENTS_DEPLOY_BLOCK ? estimate : MOMENTS_DEPLOY_BLOCK;
}

export async function fetchHolderStats(coin: Address, publishedAt: number): Promise<HolderStats> {
  const key = coin.toLowerCase();
  const latest = await publicClient.getBlockNumber();
  let entry = cache.get(key);
  if (!entry) entry = { balances: new Map(), scannedTo: (await blockAt(publishedAt)) - 1n };
  // Adaptive ranges: start wide (rpc1 answers a day per call) and halve on failure down to 100 blocks, the cap of
  // the default Monad RPC and of a local fork forwarding pre-fork ranges upstream.
  let chunk = CHUNK;
  let from = entry.scannedTo + 1n;
  while (from <= latest) {
    const to = from + chunk - 1n > latest ? latest : from + chunk - 1n;
    let logs;
    try {
      logs = await logsClient.getLogs({ address: coin, event: transferEvent, fromBlock: from, toBlock: to });
    } catch (error) {
      if (chunk > MIN_CHUNK) {
        chunk = chunk / 2n < MIN_CHUNK ? MIN_CHUNK : chunk / 2n;
        continue;
      }
      throw new Error(`The log RPC refused a ${MIN_CHUNK}-block range; holder statistics are unavailable (${(error as Error).message.slice(0, 80)}).`);
    }
    for (const log of logs) {
      const { from: f, to: t, value } = log.args;
      if (!f || !t || value === undefined) continue;
      if (f !== ZERO) entry.balances.set(f.toLowerCase(), (entry.balances.get(f.toLowerCase()) ?? 0n) - value);
      entry.balances.set(t.toLowerCase(), (entry.balances.get(t.toLowerCase()) ?? 0n) + value);
    }
    entry.scannedTo = to;
    from = to + 1n;
    if (chunk < CHUNK) chunk = chunk * 2n > CHUNK ? CHUNK : chunk * 2n; // grow back once a range succeeds
  }
  cache.set(key, entry);
  const protocol = new Set([MOMENTS.poolManager, MOMENTS.locker, MOMENTS.vesting, MOMENTS.buyback, MOMENTS.hook, MOMENTS.graduation].map((a) => a.toLowerCase()));
  let minted = 0n;
  let pool = 0n;
  let circulating = 0n;
  let holders = 0;
  let top: [string, bigint] = ["", 0n];
  for (const [who, bal] of entry.balances) {
    if (bal <= 0n) continue;
    minted += bal;
    if (who === MOMENTS.poolManager.toLowerCase()) pool += bal;
    if (protocol.has(who)) continue;
    circulating += bal;
    holders++;
    if (bal > top[1]) top = [who, bal];
  }
  return {
    holders,
    topHolder: top[0] ? (top[0] as Address) : null,
    topHolderBps: circulating === 0n ? 0 : Number((top[1] * 10_000n) / circulating),
    circulatingCoins: Number(circulating / 10n ** 18n),
    poolBps: minted === 0n ? 0 : Number((pool * 10_000n) / minted),
    mintedCoins: Number(minted / 10n ** 18n),
    scannedTo: Number(entry.scannedTo),
  };
}
