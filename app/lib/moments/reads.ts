import { encodeAbiParameters, erc20Abi, keccak256, type Address, type Hex } from "viem";
import { MomentBuybackAbi, MomentCoinAbi, MomentCollectAbi, MomentFeeHookAbi, MomentGraduationAbi, MomentLockerAbi, MomentNFTAbi, MomentVestingAbi, MomentsFactoryAbi } from "../moments-abi";
import { publicClient } from "../chain";
import { BPS, COIN_DECIMALS, MOMENTS, MOMENTS_DEPLOYED, SUPPLY, USDC } from "./config";

/* Read side of Moments: everything the pages show comes straight from the contracts through multicall. */

export const STATES = ["Collecting", "Graduation pending", "Graduated", "Expired"] as const;
export type MomentState = 0 | 1 | 2 | 3;

export type Provenance = { mediaURI: string; mediaHash: Hex; place: string; date: number; animationURI: string };
export type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };
export type Policy = {
  threshold: bigint;
  minPrice: bigint;
  creatorBps: number;
  platformBps: number;
  reserveBps: number;
  maxCreatorAllocBps: number;
  expiryCreatorBps: number;
  royaltyBps: number;
  platform: Address;
  treasury: Address;
  momentCount: number;
  publishingPaused: boolean;
  externalBaseURI: string;
};
export type Moment = {
  id: bigint;
  creator: Address;
  platform: Address;
  treasury: Address;
  coin: Address;
  nft: Address;
  price: bigint;
  threshold: bigint;
  rateNum: bigint;
  rateDen: bigint;
  creatorBps: number;
  platformBps: number;
  reserveBps: number;
  creatorAllocBps: number;
  expiryCreatorBps: number;
  royaltyBps: number;
  publishedAt: number;
  deadline: number;
};
export type Ledger = {
  state: MomentState;
  completedAt: number;
  stuckSince: number;
  endedAt: number;
  reserve: bigint;
  creatorClaimable: bigint;
  platformClaimable: bigint;
  treasuryClaimable: bigint;
  totalGross: bigint;
  collects: number;
};
export type PoolInfo = {
  key: PoolKey;
  poolId: Hex;
  usdcIs0: boolean;
  sqrtPriceX96: bigint;
  openingSqrtPriceX96: bigint;
  liquidity: bigint;
  seedLiquidity: bigint;
  reserveSeed: bigint;
  poolCoins: bigint;
  graduatedAt: number;
  usdcPerCoin: number; // whole USDC per whole coin, live
  fees: { creator: bigint; platform: bigint; buyback: bigint };
  buybackCarry: bigint;
  lastBuyback: number;
  buybackInterval: number;
  buybackMin: bigint;
};
export type MomentInfo = Moment & {
  name: string;
  symbol: string;
  provenance: Provenance;
  ledger: Ledger;
  editions: number;
  closed: boolean;
  entitlements: bigint;
  graduated: boolean;
  progressBps: number;
  pool: PoolInfo | null;
};
export type MomentDetail = MomentInfo & {
  supply: { entitlements: bigint; creatorAlloc: bigint; remainderPool: bigint; impliedPool: bigint; collects: number };
  coinTotalSupply: bigint;
  externalUrl: string;
};
export type CollectQuote = { gross: bigint; editions: bigint; entitlement: bigint; reserveIn: bigint; creatorIn: bigint; platformIn: bigint; excess: bigint; terminal: boolean };
export type AccountView = {
  usdcBalance: bigint;
  monBalance: bigint; // gas
  permit2Allowance: bigint; // USDC -> Permit2
  collectAllowance: bigint; // USDC -> collect (approve path)
  entitlement: bigint;
  claimed: bigint;
  claimableCollector: bigint;
  claimableCreator: bigint;
  coinBalance: bigint;
  nftBalance: number;
  nftIds: bigint[];
  creatorProceeds: bigint; // collect-time creator share still to pull (only for the creator)
  creatorFees: bigint; // hook fees still to pull (only for the creator)
  platformProceeds: bigint;
  platformFees: bigint;
  treasuryProceeds: bigint;
};
export type PortfolioRow = { moment: MomentInfo; entitlement: bigint; claimed: bigint; claimableCollector: bigint; claimableCreator: bigint; nftBalance: number; coinBalance: bigint };
export type Portfolio = { rows: PortfolioRow[]; pending: bigint; claimable: bigint; vesting: bigint; claimed: bigint };

export const factoryContract = { address: MOMENTS.factory, abi: MomentsFactoryAbi } as const;
export const collectContract = { address: MOMENTS.collect, abi: MomentCollectAbi } as const;
export const vestingContract = { address: MOMENTS.vesting, abi: MomentVestingAbi } as const;
export const graduationContract = { address: MOMENTS.graduation, abi: MomentGraduationAbi } as const;
export const lockerContract = { address: MOMENTS.locker, abi: MomentLockerAbi } as const;
export const hookContract = { address: MOMENTS.hook, abi: MomentFeeHookAbi } as const;
export const buybackContract = { address: MOMENTS.buyback, abi: MomentBuybackAbi } as const;
export const coinContract = (address: Address) => ({ address, abi: MomentCoinAbi }) as const;
export const nftContract = (address: Address) => ({ address, abi: MomentNFTAbi }) as const;

export const poolIdOf = (key: PoolKey): Hex =>
  keccak256(encodeAbiParameters([{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }], [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]));

/** Whole USDC per whole coin from a v4 sqrt price (USDC 6 dp, coin 18 dp). */
export function usdcPerCoin(sqrtPriceX96: bigint, usdcIs0: boolean): number {
  const sp = Number(sqrtPriceX96) / 2 ** 96;
  const ratio = sp * sp; // currency1 units per currency0 unit
  if (ratio === 0) return 0;
  return usdcIs0 ? 1e12 / ratio : ratio * 1e12;
}

export async function fetchPolicy(): Promise<Policy | null> {
  if (!MOMENTS_DEPLOYED) return null;
  const [policy, momentCount, publishingPaused, externalBaseURI] = await publicClient.multicall({
    contracts: [
      { ...factoryContract, functionName: "policy" },
      { ...factoryContract, functionName: "momentCount" },
      { ...factoryContract, functionName: "publishingPaused" },
      { ...factoryContract, functionName: "externalBaseURI" },
    ],
    allowFailure: false,
  });
  const [threshold, minPrice, creatorBps, platformBps, reserveBps, maxCreatorAllocBps, expiryCreatorBps, royaltyBps, platform, treasury] = policy;
  return { threshold, minPrice, creatorBps, platformBps, reserveBps, maxCreatorAllocBps, expiryCreatorBps, royaltyBps, platform, treasury, momentCount: Number(momentCount), publishingPaused, externalBaseURI };
}

type RawMoment = { creator: Address; platform: Address; treasury: Address; coin: Address; nft: Address; price: bigint; threshold: bigint; rateNum: bigint; rateDen: bigint; creatorBps: number; platformBps: number; reserveBps: number; creatorAllocBps: number; expiryCreatorBps: number; royaltyBps: number; publishedAt: bigint; deadline: bigint };
const toMoment = (id: bigint, m: RawMoment): Moment => ({ id, ...m, publishedAt: Number(m.publishedAt), deadline: Number(m.deadline) });
type RawLedger = { state: number; completedAt: bigint; stuckSince: bigint; endedAt: bigint; reserve: bigint; creatorClaimable: bigint; platformClaimable: bigint; treasuryClaimable: bigint; totalGross: bigint; collects: bigint };
const toLedger = (l: RawLedger): Ledger => ({ state: l.state as MomentState, completedAt: Number(l.completedAt), stuckSince: Number(l.stuckSince), endedAt: Number(l.endedAt), reserve: l.reserve, creatorClaimable: l.creatorClaimable, platformClaimable: l.platformClaimable, treasuryClaimable: l.treasuryClaimable, totalGross: l.totalGross, collects: Number(l.collects) });

/* Uniswap v4 keeps pool state in PoolManager storage: `pools` is slot 6 and slot0 (sqrtPriceX96 in the low
   160 bits) sits at keccak(poolId, 6). */
const POOLS_SLOT = 6n;
const extsloadAbi = [{ type: "function", name: "extsload", stateMutability: "view", inputs: [{ name: "slot", type: "bytes32" }], outputs: [{ name: "value", type: "bytes32" }] }] as const;
async function poolSqrtPrice(poolId: Hex): Promise<bigint> {
  const slot = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId, POOLS_SLOT]));
  const value = await publicClient.readContract({ address: MOMENTS.poolManager, abi: extsloadAbi, functionName: "extsload", args: [slot] });
  return BigInt(value) & ((1n << 160n) - 1n);
}

async function fetchPool(id: bigint, coin: Address): Promise<PoolInfo> {
  const [record, liquidity, creator, platform, buyback, carry, lastRun, interval, minAmount] = await publicClient.multicall({
    contracts: [
      { ...graduationContract, functionName: "record", args: [id] },
      { ...lockerContract, functionName: "liquidityOf", args: [id] },
      { ...hookContract, functionName: "creatorAccrued", args: [id] },
      { ...hookContract, functionName: "platformAccrued", args: [id] },
      { ...hookContract, functionName: "buybackAccrued", args: [id] },
      { ...buybackContract, functionName: "carry", args: [id] },
      { ...buybackContract, functionName: "lastRun", args: [id] },
      { ...buybackContract, functionName: "MIN_INTERVAL" },
      { ...buybackContract, functionName: "MIN_AMOUNT" },
    ],
    allowFailure: false,
  });
  const key: PoolKey = { ...record.key };
  const poolId = poolIdOf(key);
  const usdcIs0 = key.currency0.toLowerCase() === USDC.address.toLowerCase();
  let sqrtPriceX96 = record.sqrtPriceX96;
  try {
    const live = await poolSqrtPrice(poolId);
    if (live > 0n) sqrtPriceX96 = live;
  } catch {
    /* fall back to the opening price */
  }
  void coin;
  return {
    key,
    poolId,
    usdcIs0,
    sqrtPriceX96,
    openingSqrtPriceX96: record.sqrtPriceX96,
    liquidity,
    seedLiquidity: record.liquidity,
    reserveSeed: record.reserve,
    poolCoins: record.poolCoins,
    graduatedAt: Number(record.at),
    usdcPerCoin: usdcPerCoin(sqrtPriceX96, usdcIs0),
    fees: { creator, platform, buyback },
    buybackCarry: carry,
    lastBuyback: Number(lastRun),
    buybackInterval: Number(interval),
    buybackMin: minAmount,
  };
}

async function hydrate(id: bigint, raw: RawMoment): Promise<MomentInfo> {
  const m = toMoment(id, raw);
  const nft = nftContract(m.nft);
  const coin = coinContract(m.coin);
  const [ledgerRaw, editions, closed, provenance, name, symbol, entitlements, graduated] = await publicClient.multicall({
    contracts: [
      { ...collectContract, functionName: "ledger", args: [id] },
      { ...nft, functionName: "totalMinted" },
      { ...nft, functionName: "closed" },
      { ...nft, functionName: "provenance" },
      { ...coin, functionName: "name" },
      { ...coin, functionName: "symbol" },
      { ...vestingContract, functionName: "totalEntitlement", args: [id] },
      { ...graduationContract, functionName: "isGraduated", args: [id] },
    ],
    allowFailure: false,
  });
  const ledger = toLedger(ledgerRaw);
  const pool = graduated ? await fetchPool(id, m.coin) : null;
  const progressBps = graduated || ledger.state === 1 ? 10_000 : m.threshold === 0n ? 0 : Number((ledger.reserve * BPS) / m.threshold);
  return {
    ...m,
    name,
    symbol,
    provenance: { ...provenance, date: Number(provenance.date) },
    ledger,
    editions: Number(editions),
    closed,
    entitlements,
    graduated,
    progressBps,
    pool,
  };
}

/** The newest Moments first. */
export async function fetchMoments(limit = 48): Promise<MomentInfo[]> {
  if (!MOMENTS_DEPLOYED) return [];
  const total = Number(await publicClient.readContract({ ...factoryContract, functionName: "momentCount" }));
  if (total === 0) return [];
  const first = Math.max(1, total - limit + 1);
  const ids: bigint[] = [];
  for (let i = total; i >= first; i--) ids.push(BigInt(i));
  const raws = await publicClient.multicall({ contracts: ids.map((id) => ({ ...factoryContract, functionName: "getMoment", args: [id] }) as const), allowFailure: false });
  return Promise.all(ids.map((id, i) => hydrate(id, { ...raws[i] })));
}

export async function fetchMoment(id: bigint): Promise<MomentDetail | null> {
  if (!MOMENTS_DEPLOYED || id <= 0n) return null;
  const count = await publicClient.readContract({ ...factoryContract, functionName: "momentCount" });
  if (id > count) return null;
  const raw = await publicClient.readContract({ ...factoryContract, functionName: "getMoment", args: [id] });
  const info = await hydrate(id, { ...raw });
  const [supply, coinTotalSupply, base] = await publicClient.multicall({
    contracts: [
      { ...collectContract, functionName: "supplyCheck", args: [id] },
      { ...coinContract(info.coin), functionName: "totalSupply" },
      { ...factoryContract, functionName: "externalBaseURI" },
    ],
    allowFailure: false,
  });
  const [entitlements, creatorAlloc, remainderPool, impliedPool, collects] = supply;
  return { ...info, supply: { entitlements, creatorAlloc, remainderPool, impliedPool, collects: Number(collects) }, coinTotalSupply, externalUrl: base ? `${base}${id}` : "" };
}

export async function fetchByCoin(coin: Address): Promise<MomentDetail | null> {
  if (!MOMENTS_DEPLOYED) return null;
  const id = await publicClient.readContract({ ...factoryContract, functionName: "momentIdByCoin", args: [coin] });
  return id === 0n ? null : fetchMoment(id);
}

/** Previews a collect exactly as the contract would settle it; null when collecting is closed. */
export async function quoteCollect(id: bigint, quantity: number): Promise<{ quote: CollectQuote | null; reason: string | null }> {
  try {
    const q = await publicClient.readContract({ ...collectContract, functionName: "quote", args: [id, BigInt(quantity)] });
    return { quote: { ...q }, reason: null };
  } catch (error) {
    const text = String((error as { shortMessage?: string }).shortMessage ?? error);
    if (/CollectWindowClosed/.test(text)) return { quote: null, reason: "The collect window has closed." };
    if (/NotCollecting/.test(text)) return { quote: null, reason: "This Moment is no longer collecting." };
    if (/BadQuantity/.test(text)) return { quote: null, reason: "Choose between 1 and 20 editions." };
    return { quote: null, reason: text };
  }
}

export async function fetchAccountView(m: MomentInfo, account: Address): Promise<AccountView> {
  const usdc = { address: USDC.address, abi: erc20Abi } as const;
  const nft = nftContract(m.nft);
  const coin = coinContract(m.coin);
  const isCreator = m.creator.toLowerCase() === account.toLowerCase();
  const isPlatform = m.platform.toLowerCase() === account.toLowerCase();
  const isTreasury = m.treasury.toLowerCase() === account.toLowerCase();
  const [usdcBalance, permit2Allowance, collectAllowance, entitlement, claimed, claimable, coinBalance, nftBalance, ledgerRaw, creatorFees, platformFees] = await publicClient.multicall({
    contracts: [
      { ...usdc, functionName: "balanceOf", args: [account] },
      { ...usdc, functionName: "allowance", args: [account, MOMENTS.permit2] },
      { ...usdc, functionName: "allowance", args: [account, MOMENTS.collect] },
      { ...vestingContract, functionName: "entitlement", args: [m.id, account] },
      { ...vestingContract, functionName: "claimed", args: [m.id, account] },
      { ...vestingContract, functionName: "claimable", args: [m.id, account] },
      { ...coin, functionName: "balanceOf", args: [account] },
      { ...nft, functionName: "balanceOf", args: [account] },
      { ...collectContract, functionName: "ledger", args: [m.id] },
      { ...hookContract, functionName: "creatorAccrued", args: [m.id] },
      { ...hookContract, functionName: "platformAccrued", args: [m.id] },
    ],
    allowFailure: false,
  });
  const [nftIds, monBalance] = await Promise.all([
    nftBalance > 0n ? publicClient.readContract({ ...nft, functionName: "tokensOfOwner", args: [account, 0n, 50n] }).then((ids) => [...ids]) : Promise.resolve([] as bigint[]),
    publicClient.getBalance({ address: account }),
  ]);
  const ledger = toLedger(ledgerRaw);
  return {
    usdcBalance,
    monBalance,
    permit2Allowance,
    collectAllowance,
    entitlement,
    claimed,
    claimableCollector: claimable[0],
    claimableCreator: claimable[1],
    coinBalance,
    nftBalance: Number(nftBalance),
    nftIds,
    creatorProceeds: isCreator ? ledger.creatorClaimable : 0n,
    creatorFees: isCreator ? creatorFees : 0n,
    platformProceeds: isPlatform ? ledger.platformClaimable : 0n,
    platformFees: isPlatform ? platformFees : 0n,
    treasuryProceeds: isTreasury ? ledger.treasuryClaimable : 0n,
  };
}

/** Every Moment the account has a stake in: pending (not graduated), claimable now, still vesting, claimed. */
export async function fetchPortfolio(account: Address, limit = 200): Promise<Portfolio> {
  const moments = await fetchMoments(limit);
  if (moments.length === 0) return { rows: [], pending: 0n, claimable: 0n, vesting: 0n, claimed: 0n };
  const calls = moments.flatMap((m) => [
    { ...vestingContract, functionName: "entitlement", args: [m.id, account] } as const,
    { ...vestingContract, functionName: "claimed", args: [m.id, account] } as const,
    { ...vestingContract, functionName: "claimable", args: [m.id, account] } as const,
    { ...nftContract(m.nft), functionName: "balanceOf", args: [account] } as const,
    { ...coinContract(m.coin), functionName: "balanceOf", args: [account] } as const,
    { ...vestingContract, functionName: "creatorClaimed", args: [m.id] } as const,
  ]);
  const results = await publicClient.multicall({ contracts: calls, allowFailure: false });
  const rows: PortfolioRow[] = [];
  let pending = 0n;
  let claimableTotal = 0n;
  let vesting = 0n;
  let claimed = 0n;
  const STRIDE = 6;
  moments.forEach((m, i) => {
    const entitlement = results[i * STRIDE] as bigint;
    const claimedAmt = results[i * STRIDE + 1] as bigint;
    const [claimableCollector, claimableCreator] = results[i * STRIDE + 2] as readonly [bigint, bigint];
    const nftBalance = Number(results[i * STRIDE + 3] as bigint);
    const coinBalance = results[i * STRIDE + 4] as bigint;
    const creatorClaimed = results[i * STRIDE + 5] as bigint;
    const isCreator = m.creator.toLowerCase() === account.toLowerCase();
    const alloc = isCreator ? (SUPPLY * BigInt(m.creatorAllocBps)) / BPS : 0n;
    if (entitlement === 0n && nftBalance === 0 && coinBalance === 0n && alloc === 0n) return;
    // `promised` is what this account will be able to claim in total: its collects plus, for the creator, the allocation.
    const promised = entitlement + alloc;
    const claimedTotal = claimedAmt + (isCreator ? creatorClaimed : 0n);
    rows.push({ moment: m, entitlement: promised, claimed: claimedTotal, claimableCollector, claimableCreator, nftBalance, coinBalance });
    if (!m.graduated) pending += promised;
    else {
      claimableTotal += claimableCollector + claimableCreator;
      vesting += promised - claimedTotal - claimableCollector - claimableCreator;
      claimed += claimedTotal;
    }
  });
  return { rows, pending, claimable: claimableTotal, vesting, claimed };
}

/** Coin amount as a display number. */
export const coins = (wei: bigint) => Number(wei) / 10 ** COIN_DECIMALS;
/** Fully diluted value in USDC for a live pool price. */
export const fdvUsd = (usdcPerCoinPrice: number) => usdcPerCoinPrice * 1e8;

/** Distinct NFT holders and the largest one, from ownerOf over every edition (editions are few and on-chain). */
export async function fetchNftHolders(nft: Address, editions: number): Promise<{ holders: number; topHolder: Address | null; topCount: number }> {
  if (editions === 0) return { holders: 0, topHolder: null, topCount: 0 };
  const ids = Array.from({ length: Math.min(editions, 400) }, (_, i) => BigInt(i + 1));
  const owners = await publicClient.multicall({ contracts: ids.map((id) => ({ ...nftContract(nft), functionName: "ownerOf", args: [id] }) as const), allowFailure: true });
  const counts = new Map<string, number>();
  for (const o of owners) if (o.status === "success") counts.set((o.result as string).toLowerCase(), (counts.get((o.result as string).toLowerCase()) ?? 0) + 1);
  let top: [string, number] = ["", 0];
  for (const [who, n] of counts) if (n > top[1]) top = [who, n];
  return { holders: counts.size, topHolder: top[0] ? (top[0] as Address) : null, topCount: top[1] };
}
