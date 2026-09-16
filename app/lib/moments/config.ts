import { getAddress, isAddress, type Address } from "viem";
import deployment from "../moments-deployment.json";

/* Moments contracts on Monad mainnet (clean-room set, separate from the launchpad). Environment variables win
   over app/lib/moments-deployment.json, which `npm run sync:moments` writes from contracts/deployments. */

const ZERO: Address = "0x0000000000000000000000000000000000000000";

function publicEnv(read: () => string | undefined): string | undefined {
  try {
    const value = read();
    return typeof value === "string" && value.trim() ? value.trim() : undefined;
  } catch {
    return undefined;
  }
}
const addr = (value: string | undefined, fallback?: string): Address => {
  const candidate = value ?? fallback;
  return candidate && isAddress(candidate) ? getAddress(candidate) : ZERO;
};

export const MOMENTS = {
  factory: addr(publicEnv(() => process.env.NEXT_PUBLIC_MOMENTS_FACTORY), deployment.factory),
  collect: addr(publicEnv(() => process.env.NEXT_PUBLIC_MOMENTS_COLLECT), deployment.collect),
  vesting: addr(publicEnv(() => process.env.NEXT_PUBLIC_MOMENTS_VESTING), deployment.vesting),
  graduation: addr(publicEnv(() => process.env.NEXT_PUBLIC_MOMENTS_GRADUATION), deployment.graduation),
  locker: addr(publicEnv(() => process.env.NEXT_PUBLIC_MOMENTS_LOCKER), deployment.locker),
  hook: addr(publicEnv(() => process.env.NEXT_PUBLIC_MOMENTS_HOOK), deployment.hook),
  buyback: addr(publicEnv(() => process.env.NEXT_PUBLIC_MOMENTS_BUYBACK), deployment.buyback),
  usdc: addr(publicEnv(() => process.env.NEXT_PUBLIC_USDC), deployment.usdc),
  permit2: addr(publicEnv(() => process.env.NEXT_PUBLIC_PERMIT2), deployment.permit2),
  poolManager: addr(publicEnv(() => process.env.NEXT_PUBLIC_POOL_MANAGER), deployment.poolManager),
  platform: addr(undefined, deployment.platform),
  treasury: addr(undefined, deployment.treasury),
  governance: addr(undefined, deployment.governance),
} as const;

export const MOMENTS_DEPLOYED = MOMENTS.factory !== ZERO;
/** Block the factory was deployed in: no Moment coin has a Transfer before it. */
export const MOMENTS_DEPLOY_BLOCK = BigInt((deployment as { deployBlock?: number }).deployBlock ?? 0);
/** Log scans need an RPC that answers wide eth_getLogs ranges (rpc.monad.xyz caps them at 100 blocks). */
export const LOGS_RPC = publicEnv(() => process.env.NEXT_PUBLIC_MONAD_LOGS_RPC) ?? "https://rpc1.monad.xyz";

export const USDC = { address: MOMENTS.usdc, symbol: "USDC", decimals: 6 } as const;
/** Optional link to a place to get USDC (any venue); shown when a wallet holds no USDC. */
export const ONRAMP_URL = publicEnv(() => process.env.NEXT_PUBLIC_ONRAMP_URL) ?? "";
export const COIN_DECIMALS = 18;
export const BPS = 10_000n;
export const SUPPLY = 100_000_000n * 10n ** 18n;
export const MONTH_SECONDS = 30 * 24 * 3600;
export const STUCK_GRACE_SECONDS = 7 * 24 * 3600;
export const MAX_BATCH = 20;
export const MAX_COLLECT_WINDOW_SECONDS = 30 * 24 * 3600;
export const MIN_COLLECT_WINDOW_SECONDS = 3600;
export const HOOK_FEE_BPS = 100;
export const HOOK_SPLIT = { creator: 2_000, platform: 3_000, buyback: 5_000 } as const;
