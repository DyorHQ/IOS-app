import { createPublicClient, getAddress, http, isAddress, type Address } from "viem";
import { monad } from "viem/chains";
import deployment from "./deployment.json";

/* Public, build-time configuration. vinext inlines `process.env.NEXT_PUBLIC_*` when the variable is set at build
   time; when it is not, the expression survives into the browser bundle where `process` does not exist, so every
   read goes through a guard and falls back to the checked-in deployment file. */
function publicEnv(read: () => string | undefined): string | undefined {
  try {
    const value = read();
    return typeof value === "string" && value.trim() ? value.trim() : undefined;
  } catch {
    return undefined;
  }
}

/* Inspectors, loggers and devtools serialize component props with JSON.stringify, which throws on bigint and can
   take a React commit down with it. viem has its own serializer, so this only makes plain JSON.stringify safe. */
const bigintProto = BigInt.prototype as unknown as { toJSON?: () => string };
if (typeof bigintProto.toJSON !== "function") bigintProto.toJSON = function toJSON(this: bigint) { return this.toString(); };

export const chain = monad;
export const CHAIN_ID: number = monad.id;
export const CHAIN_HEX = `0x${monad.id.toString(16)}`;
export const RPC_URL = publicEnv(() => process.env.NEXT_PUBLIC_MONAD_RPC) ?? monad.rpcUrls.default.http[0];
export const EXPLORER = monad.blockExplorers?.default.url ?? "https://monadscan.com";
export const ZERO_ADDRESS: Address = "0x0000000000000000000000000000000000000000";

const addr = (value: string | undefined, fallback?: string): Address => {
  const candidate = value ?? fallback;
  return candidate && isAddress(candidate) ? getAddress(candidate) : ZERO_ADDRESS;
};

/* Launchpad contracts on Monad mainnet: app/lib/deployment.json (written by `npm run sync:deployment` from
   contracts/deployments/143.json) is the source of truth. NEXT_PUBLIC_LAUNCHPAD_* variables only apply when
   NEXT_PUBLIC_LAUNCHPAD_OVERRIDE=1 is also set — the fork-rehearsal switch — so a stale variable in a hosting
   dashboard or an old env file can never point production at a retired deployment again. */
const overrideLaunchpad = publicEnv(() => process.env.NEXT_PUBLIC_LAUNCHPAD_OVERRIDE) === "1";
const launchpadEnv = (read: () => string | undefined): string | undefined => (overrideLaunchpad ? publicEnv(read) : undefined);

export const ADDRESSES = {
  factory: addr(launchpadEnv(() => process.env.NEXT_PUBLIC_LAUNCHPAD_FACTORY), deployment.factory),
  router: addr(launchpadEnv(() => process.env.NEXT_PUBLIC_LAUNCH_ROUTER), deployment.launchAndBuyRouter),
  escrow: addr(launchpadEnv(() => process.env.NEXT_PUBLIC_FEE_ESCROW), deployment.escrow),
  holderFeeSharing: addr(launchpadEnv(() => process.env.NEXT_PUBLIC_HOLDER_FEE_SHARING), deployment.holderFeeSharing),
  hook: addr(launchpadEnv(() => process.env.NEXT_PUBLIC_MEME_HOOK), deployment.hook),
  poolManager: addr(launchpadEnv(() => process.env.NEXT_PUBLIC_POOL_MANAGER), deployment.poolManager),
} as const;

/** One launchpad deployment: the factory and the modules its launches settle through. */
export type LaunchpadStack = {
  factory: Address;
  router: Address;
  escrow: Address;
  holderFeeSharing: Address;
  hook: Address;
  retired: boolean;
  /** `getLaunchedToken` returns the 16-field record with no `graduationVenue` (every launch on it graduates on Monday Trade). */
  legacyRecord: boolean;
};

/* Retired launchpads, newest first. The owner closed them to new launches (whitelist on, config 0 off), but their
   curves keep trading and their escrow, holder sharing and hook keep paying out, so every per-launch read and write
   goes to the stack that launched the token. Module addresses were read from each factory on Monad mainnet. */
export const RETIRED_STACKS: readonly LaunchpadStack[] = [
  {
    factory: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7",
    router: "0x3eE688C3b3aCd652914aD49d8Ee5ae1004bF3690",
    escrow: "0xbc70ba9D66F761FFb7647D6B52C8Cf65a49E47fc",
    holderFeeSharing: "0x70F8f64c6A4A76A507e322BCef19E6E37abe4eF6",
    hook: "0x51A240c13164BcDF3FC11053FddEaC626A4160cc",
    retired: true,
    legacyRecord: false,
  },
  {
    factory: "0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4",
    router: "0xbaEa633e9Ba5d927bfD6a0f5b3FB3982784DA30D",
    escrow: "0xeDC73b06BE454714b6Bd0C1c742e51e605664B2A",
    holderFeeSharing: "0x1413CB051f78a4605cD150d4E97B1B06f81e2Bdf",
    hook: "0x22957b1d794A7Ca37D054acB5e993e026826E0Cc",
    retired: true,
    legacyRecord: false,
  },
  {
    factory: "0xad3d3Cb821279E52cFD499D15b26f77976eBA1Ea",
    router: "0xd5862DfB44831868CF8f459aA270d05d32031CE1",
    escrow: "0x1253b18077E8b52FC2522F5B62Ebd2B176383231",
    holderFeeSharing: "0x0C7a1F7625696bAbF9a7309ed3c4A9086eFEE8dd",
    hook: "0xB0c2Fa59aA9f30BC0907bcD785bFf068fEb0E0Cc",
    retired: true,
    legacyRecord: true,
  },
];

export const LIVE_STACK: LaunchpadStack = {
  factory: ADDRESSES.factory,
  router: ADDRESSES.router,
  escrow: ADDRESSES.escrow,
  holderFeeSharing: ADDRESSES.holderFeeSharing,
  hook: ADDRESSES.hook,
  retired: false,
  legacyRecord: false,
};

/** Every factory launches are read from: the live one first (new launches only ever go there), then the retired ones. */
export const FACTORIES: readonly LaunchpadStack[] = [
  ...(LIVE_STACK.factory !== ZERO_ADDRESS ? [LIVE_STACK] : []),
  ...RETIRED_STACKS.filter((s) => s.factory.toLowerCase() !== LIVE_STACK.factory.toLowerCase()),
];

/** Extra ERC-20 pair tokens the owner approved with `setPairEconomics` (comma separated). Native MON is always offered. */
export const EXTRA_PAIR_TOKENS: Address[] = (publicEnv(() => process.env.NEXT_PUBLIC_PAIR_TOKENS) ?? "")
  .split(",")
  .map((s) => s.trim())
  .filter((s) => isAddress(s))
  .map((s) => getAddress(s));

export const DEPLOYED = ADDRESSES.factory !== ZERO_ADDRESS;

export const publicClient = createPublicClient({
  chain: monad,
  transport: http(RPC_URL, { batch: true }),
  batch: { multicall: { wait: 16 } },
  pollingInterval: 1_000, // Monad blocks every ~0.4 s; viem's 4 s default makes confirmations feel slow.
});

export const explorerTx = (hash: string) => `${EXPLORER}/tx/${hash}`;
export const explorerAddress = (address: string) => `${EXPLORER}/address/${address}`;
export const explorerToken = (address: string) => `${EXPLORER}/token/${address}`;
