import { getAddress, type Address } from "viem";
import retired from "../moments-retired.json";

/* Retired Moments cohorts on Monad mainnet (publishing paused, so the lists are final). Every Moment on them
   snapshotted the retired platform wallet and the treasury whose key leaked, so the app never trades their coins or
   routes through their pools. app/lib/moments-retired.json is the web app's one source of truth;
   tests/moments-retired.test.mjs pins it to contracts/deployments/moments-143-cohort{1,2}.json and to the iOS app's
   `MomentsAddresses.retiredMainnetCoins`. */

export const RETIRED_MOMENT_COINS: readonly Address[] = retired.cohorts.flatMap((c) => c.coins.map((a) => getAddress(a)));
export const RETIRED_MOMENT_HOOKS: readonly Address[] = retired.cohorts.map((c) => getAddress(c.hook));
/** Every retired cohort's coin and pool hook: the same set as iOS `SwapEngine.retiredAddresses`. */
export const RETIRED_MOMENT_ADDRESSES: readonly Address[] = [...RETIRED_MOMENT_COINS, ...RETIRED_MOMENT_HOOKS];

export const isRetiredMomentCoin = (token: string) => RETIRED_MOMENT_COINS.some((a) => a.toLowerCase() === token.toLowerCase());

/** For calldata the app did not encode (Kuru Flow's is ready-made, so its route cannot be read): the first retired
    coin or hook that appears anywhere in it, or null. An address the calldata touches sits in it as 20 contiguous
    bytes (an ABI word's low 20 bytes, or a raw address in a packed path), so a route that hops through a retired pool
    is caught even for an ordinary pair. Best effort, as iOS `SwapEngine.ensureNoRetired(in:)`: a route that names a
    pool only by its id (a v4 PoolId hash) would not show the hook, which is why the sides are also checked first. */
export function findRetiredAddress(calldata: string): Address | null {
  const hex = calldata.toLowerCase().replace(/^0x/, "");
  for (const address of RETIRED_MOMENT_ADDRESSES) {
    const needle = address.slice(2).toLowerCase();
    // Byte-aligned matches only (an even hex offset), as a byte search would find.
    for (let i = hex.indexOf(needle); i !== -1; i = hex.indexOf(needle, i + 1)) {
      if (i % 2 === 0) return address;
    }
  }
  return null;
}

export class RetiredMomentError extends Error {
  constructor(readonly address: Address) {
    super("This trade touches a retired Moments coin or pool, so it was blocked. Past-cohort coins can't be traded in the app.");
    this.name = "RetiredMomentError";
  }
}
