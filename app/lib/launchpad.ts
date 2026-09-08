import { encodeAbiParameters, erc20Abi, keccak256, type Address, type Hex } from "viem";
import { BondingCurveAbi, FeeEscrowAbi, HolderFeeSharingAbi, LaunchTokenAbi, LaunchpadFactoryAbi, MemeHookAbi } from "./abi";
import { ADDRESSES, DEPLOYED, EXTRA_PAIR_TOKENS, ZERO_ADDRESS, publicClient } from "./chain";

/* Read side of the launchpad: everything the pages show comes straight from the contracts through multicall. */

export const PHASES = ["Bonding", "Migrating", "Graduated", "Refund mode"] as const;
export type Socials = { twitter: string; telegram: string; discord: string; website: string; farcaster: string };
export type PairInfo = { address: Address; symbol: string; decimals: number; native: boolean };
export type PairEconomics = PairInfo & { phantomQuote: bigint; graduationThreshold: bigint; approved: boolean };
export type ProtocolInfo = {
  launchFee: bigint;
  configId: bigint;
  supply: bigint;
  curveFeeBps: number;
  poolFeeBps: number;
  snipeSchedule: number[];
  configEnabled: boolean;
  maxCreatorTaxBps: number;
  whitelistEnabled: boolean;
  protocolFeeShareBps: number;
  launchCount: number;
  pairs: PairEconomics[];
};
export type LaunchRecord = {
  token: Address;
  curve: Address;
  deployer: Address;
  creatorFeeRecipient: Address;
  pairToken: Address;
  graduationThreshold: bigint;
  creatorTaxBps: number;
  poolFeeBps: number;
  tickSpacing: number;
  holderFeeSharing: boolean;
  phase: number;
  sweptQuote: bigint;
  sweptTokens: bigint;
  sweptAt: bigint;
  poolId: Hex;
  exists: boolean;
};
export type LaunchInfo = LaunchRecord & {
  name: string;
  symbol: string;
  logo: string;
  description: string;
  socials: Socials;
  pair: PairInfo;
  price: bigint;
  realQuoteReserve: bigint;
  completed: boolean;
  rescued: boolean;
  launchedAt: number;
  supply: bigint;
  marketCap: bigint;
  progressBps: number;
};
export type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };
export type LaunchDetail = LaunchInfo & {
  feeBps: number;
  snipeSchedule: number[];
  quoteReserve: bigint;
  tokenReserve: bigint;
  sellableTokens: bigint;
  phantomQuote: bigint;
  reservedTokens: bigint;
  swept: boolean;
  stuckSince: number;
  poolKey: PoolKey | null;
  hookPendingFees: bigint;
  hookPendingTax: bigint;
};
export type AccountView = {
  tokenBalance: bigint;
  pairBalance: bigint;
  allowance: bigint;
  snipeTaxBps: number;
  pendingRewards: bigint;
  escrowBalance: bigint;
};
export type BuyQuote = { tokensOut: bigint; used: bigint; fee: bigint; tax: bigint; snipe: bigint; refund: bigint };
export type SellQuote = { quoteOut: bigint; fee: bigint; tax: bigint };

export const factoryContract = { address: ADDRESSES.factory, abi: LaunchpadFactoryAbi } as const;
export const curveContract = (address: Address) => ({ address, abi: BondingCurveAbi }) as const;
export const tokenContract = (address: Address) => ({ address, abi: LaunchTokenAbi }) as const;

const pairCache = new Map<string, Promise<PairInfo>>();
export function pairInfo(address: Address): Promise<PairInfo> {
  if (address === ZERO_ADDRESS) return Promise.resolve({ address, symbol: "MON", decimals: 18, native: true });
  let pending = pairCache.get(address);
  if (!pending) {
    pending = publicClient
      .multicall({
        contracts: [
          { address, abi: erc20Abi, functionName: "symbol" },
          { address, abi: erc20Abi, functionName: "decimals" },
        ],
        allowFailure: false,
      })
      .then(([symbol, decimals]) => ({ address, symbol, decimals, native: false }));
    pairCache.set(address, pending);
  }
  return pending;
}

export async function fetchProtocol(): Promise<ProtocolInfo | null> {
  if (!DEPLOYED) return null;
  const [launchFee, configCount, maxCreatorTaxBps, whitelistEnabled, policy, launchCount] = await publicClient.multicall({
    contracts: [
      { ...factoryContract, functionName: "launchFee" },
      { ...factoryContract, functionName: "launchConfigCount" },
      { ...factoryContract, functionName: "maxCreatorTaxBps" },
      { ...factoryContract, functionName: "whitelistEnabled" },
      { ...factoryContract, functionName: "getLaunchFeePolicy" },
      { ...factoryContract, functionName: "launchCount" },
    ],
    allowFailure: false,
  });
  const configId = 0n;
  const config = configCount > 0n ? await publicClient.readContract({ ...factoryContract, functionName: "getLaunchConfig", args: [configId] }) : null;
  const pairAddresses: Address[] = [ZERO_ADDRESS, ...EXTRA_PAIR_TOKENS];
  const economics = await publicClient.multicall({
    contracts: pairAddresses.map((pairToken) => ({ ...factoryContract, functionName: "pairTokenEconomics", args: [pairToken] }) as const),
    allowFailure: false,
  });
  const infos = await Promise.all(pairAddresses.map(pairInfo));
  const pairs = infos.map((info, i) => {
    const [phantomQuote, graduationThreshold, , approved] = economics[i];
    return { ...info, phantomQuote, graduationThreshold, approved };
  });
  return {
    launchFee,
    configId,
    supply: config?.supply ?? 0n,
    curveFeeBps: config?.curveFeeBps ?? 0,
    poolFeeBps: config?.poolFeeBps ?? 0,
    snipeSchedule: config ? [...config.snipeTaxSchedule] : [],
    configEnabled: config?.enabled ?? false,
    maxCreatorTaxBps,
    whitelistEnabled,
    protocolFeeShareBps: policy.protocolFeeShareBps,
    launchCount: Number(launchCount),
    pairs,
  };
}

async function hydrate(record: LaunchRecord): Promise<LaunchInfo> {
  const token = tokenContract(record.token);
  const curve = curveContract(record.curve);
  const [pair, [name, symbol, info, price, realQuoteReserve, completed, rescued, launchedAt, supply]] = await Promise.all([
    pairInfo(record.pairToken),
    publicClient.multicall({
      contracts: [
        { ...token, functionName: "name" },
        { ...token, functionName: "symbol" },
        { ...token, functionName: "getTokenInfo" },
        { ...curve, functionName: "price" },
        { ...curve, functionName: "realQuoteReserve" },
        { ...curve, functionName: "completed" },
        { ...curve, functionName: "rescued" },
        { ...curve, functionName: "launchedAt" },
        { ...token, functionName: "totalSupply" },
      ],
      allowFailure: false,
    }),
  ]);
  const [, logo, description, socials] = info;
  const threshold = record.graduationThreshold;
  const graduated = record.phase === 2;
  const raised = graduated ? record.sweptQuote : realQuoteReserve > threshold ? threshold : realQuoteReserve;
  const livePrice = graduated ? await poolPrice(record.poolId, record.token, record.pairToken) : null;
  return {
    ...record,
    name,
    symbol,
    logo,
    description,
    socials: { ...socials },
    pair,
    price: livePrice ?? price,
    realQuoteReserve: graduated ? record.sweptQuote : realQuoteReserve,
    completed,
    rescued,
    launchedAt: Number(launchedAt),
    supply,
    marketCap: ((livePrice ?? price) * supply) / 10n ** 18n,
    progressBps: graduated ? 10000 : threshold === 0n ? 0 : Number((raised * 10000n) / threshold),
  };
}

/** The newest launches first. */
export async function fetchLaunches(limit = 48): Promise<LaunchInfo[]> {
  if (!DEPLOYED) return [];
  const total = Number(await publicClient.readContract({ ...factoryContract, functionName: "launchCount" }));
  if (total === 0) return [];
  const offset = Math.max(0, total - limit);
  const tokens = await publicClient.readContract({ ...factoryContract, functionName: "getLaunches", args: [BigInt(offset), BigInt(total - offset)] });
  const records = await publicClient.multicall({
    contracts: tokens.map((token) => ({ ...factoryContract, functionName: "getLaunchedToken", args: [token] }) as const),
    allowFailure: false,
  });
  const launches = await Promise.all(records.map((r) => hydrate({ ...r })));
  return launches.reverse();
}

export async function fetchLaunch(tokenAddress: Address): Promise<LaunchDetail | null> {
  if (!DEPLOYED) return null;
  const record = await publicClient.readContract({ ...factoryContract, functionName: "getLaunchedToken", args: [tokenAddress] });
  if (!record.exists) return null;
  const info = await hydrate({ ...record });
  const curve = curveContract(record.curve);
  const graduated = record.phase >= 2;
  const [feeBps, snipeSchedule, reserves, sellableTokens, phantomQuote, reservedTokens, swept, stuckSince, poolKey] = await publicClient.multicall({
    contracts: [
      { ...curve, functionName: "feeBps" },
      { ...curve, functionName: "snipeTaxSchedule" },
      { ...curve, functionName: "getReserves" },
      { ...curve, functionName: "sellableTokens" },
      { ...curve, functionName: "phantomQuote" },
      { ...curve, functionName: "reservedTokens" },
      { ...curve, functionName: "swept" },
      { ...factoryContract, functionName: "stuckSince", args: [tokenAddress] },
      { ...factoryContract, functionName: "poolKeyOf", args: [tokenAddress] },
    ],
    allowFailure: false,
  });
  let hookPendingFees = 0n;
  let hookPendingTax = 0n;
  if (graduated && ADDRESSES.hook !== ZERO_ADDRESS) {
    const hook = { address: ADDRESSES.hook, abi: MemeHookAbi } as const;
    [hookPendingFees, hookPendingTax] = await publicClient.multicall({
      contracts: [
        { ...hook, functionName: "pendingFees", args: [record.poolId, record.pairToken] },
        { ...hook, functionName: "pendingCreatorTax", args: [record.poolId, record.pairToken] },
      ],
      allowFailure: false,
    });
  }
  return {
    ...info,
    feeBps,
    snipeSchedule: [...snipeSchedule],
    quoteReserve: reserves[0],
    tokenReserve: reserves[1],
    sellableTokens,
    phantomQuote,
    reservedTokens,
    swept,
    stuckSince: Number(stuckSince),
    poolKey: graduated ? { ...poolKey } : null,
    hookPendingFees,
    hookPendingTax,
  };
}

export async function fetchAccountView(launch: LaunchInfo, account: Address): Promise<AccountView> {
  const token = tokenContract(launch.token);
  const curve = curveContract(launch.curve);
  const escrow = { address: ADDRESSES.escrow, abi: FeeEscrowAbi } as const;
  const sharing = { address: ADDRESSES.holderFeeSharing, abi: HolderFeeSharingAbi } as const;
  const pairErc20 = { address: launch.pairToken, abi: erc20Abi } as const;
  const [tokenBalance, snipeTaxBps, pendingRewards, escrowBalance, pairBalance, allowance] = await Promise.all([
    publicClient.readContract({ ...token, functionName: "balanceOf", args: [account] }),
    publicClient.readContract({ ...curve, functionName: "currentSnipeTaxBps", args: [account] }),
    launch.holderFeeSharing ? publicClient.readContract({ ...sharing, functionName: "pendingRewards", args: [launch.token, account] }) : Promise.resolve(0n),
    launch.pair.native
      ? publicClient.readContract({ ...escrow, functionName: "balanceOf", args: [account] })
      : publicClient.readContract({ ...escrow, functionName: "balanceOfToken", args: [account, launch.pairToken] }),
    launch.pair.native ? publicClient.getBalance({ address: account }) : publicClient.readContract({ ...pairErc20, functionName: "balanceOf", args: [account] }),
    launch.pair.native ? Promise.resolve(0n) : publicClient.readContract({ ...pairErc20, functionName: "allowance", args: [account, launch.curve] }),
  ]);
  return { tokenBalance, snipeTaxBps: Number(snipeTaxBps), pendingRewards, escrowBalance, pairBalance, allowance };
}

export async function quoteBuy(curve: Address, quoteIn: bigint, recipient: Address): Promise<BuyQuote> {
  const [tokensOut, used, fee, tax, snipe, refund] = await publicClient.readContract({ ...curveContract(curve), functionName: "quoteBuy", args: [quoteIn, recipient] });
  return { tokensOut, used, fee, tax, snipe, refund };
}
export async function quoteSell(curve: Address, tokensIn: bigint): Promise<SellQuote> {
  const [quoteOut, fee, tax] = await publicClient.readContract({ ...curveContract(curve), functionName: "quoteSell", args: [tokensIn] });
  return { quoteOut, fee, tax };
}

/* Uniswap v4 keeps pool state in PoolManager storage: `pools` is slot 6 and slot0 (sqrtPriceX96 in the low
   160 bits) sits at keccak(poolId, 6). Reading it through `extsload` gives the live price after graduation. */
const POOLS_SLOT = 6n;
const extsloadAbi = [{ type: "function", name: "extsload", stateMutability: "view", inputs: [{ name: "slot", type: "bytes32" }], outputs: [{ name: "value", type: "bytes32" }] }] as const;
async function poolPrice(poolId: Hex, token: Address, pairToken: Address): Promise<bigint | null> {
  if (ADDRESSES.poolManager === ZERO_ADDRESS) return null;
  try {
    const slot = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId, POOLS_SLOT]));
    const value = await publicClient.readContract({ address: ADDRESSES.poolManager, abi: extsloadAbi, functionName: "extsload", args: [slot] });
    const sqrtPriceX96 = BigInt(value) & ((1n << 160n) - 1n);
    if (sqrtPriceX96 === 0n) return null;
    // price1Per0 = (sqrtPriceX96 / 2^96)^2, scaled by 1e36 for precision.
    const price1Per0E36 = (sqrtPriceX96 * sqrtPriceX96 * 10n ** 36n) >> 192n;
    const tokenIsCurrency0 = BigInt(token) < BigInt(pairToken);
    const tokenDecimals = 18n;
    // Quote units per whole token, expressed in quote wei per 1e18 token wei (same scale as BondingCurve.price).
    if (tokenIsCurrency0) return (price1Per0E36 * 10n ** tokenDecimals) / 10n ** 36n; // quote per token = price1Per0 (currency1 = quote)
    if (price1Per0E36 === 0n) return null;
    return (10n ** 36n * 10n ** tokenDecimals) / price1Per0E36; // currency1 = token, so quote per token = 1 / price
  } catch {
    return null;
  }
}

/** Bonding-curve price in pair units per token, as a JS number for display. */
export const priceNumber = (launch: { price: bigint; pair: PairInfo }) => Number(launch.price) / 10 ** launch.pair.decimals;
export const snipeWindowSeconds = (schedule: number[]) => schedule.length;
