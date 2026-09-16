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

/** Launchpad contracts on Monad mainnet. Environment variables win over app/lib/deployment.json. */
export const ADDRESSES = {
  factory: addr(publicEnv(() => process.env.NEXT_PUBLIC_LAUNCHPAD_FACTORY), deployment.factory),
  router: addr(publicEnv(() => process.env.NEXT_PUBLIC_LAUNCH_ROUTER), deployment.launchAndBuyRouter),
  escrow: addr(publicEnv(() => process.env.NEXT_PUBLIC_FEE_ESCROW), deployment.escrow),
  holderFeeSharing: addr(publicEnv(() => process.env.NEXT_PUBLIC_HOLDER_FEE_SHARING), deployment.holderFeeSharing),
  hook: addr(publicEnv(() => process.env.NEXT_PUBLIC_MEME_HOOK), deployment.hook),
  poolManager: addr(publicEnv(() => process.env.NEXT_PUBLIC_POOL_MANAGER), deployment.poolManager),
} as const;

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
