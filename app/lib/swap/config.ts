import type { Address } from "viem";

/* Spot venues on Monad mainnet (chain id 143). Every address below was checked for bytecode on 2026-09-08 and
   comes from the venue's own documentation:
   - Uniswap: https://developers.uniswap.org/docs/protocols/v4/deployments and .../v3/deployments/v3-monad-deployments
   - Monday Trade: https://docs.monday.trade/spot-trading/spot-contract-pair-specifications
   - Kuru: https://docs.kuru.io/contracts/Contract-addresses and https://docs.kuru.io/kuru-flow/flow-overview */

export const WMON: Address = "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A";
export const NATIVE: Address = "0x0000000000000000000000000000000000000000";

export const UNISWAP = {
  v3Factory: "0x204faca1764b154221e35c0d20abb3c525710498" as Address,
  quoterV2: "0x661e93cca42afacb172121ef892830ca3b70f08d" as Address,
  swapRouter02: "0xfe31f71c1b106eac32f1a19239c9a9a72ddfb900" as Address,
  poolManager: "0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e" as Address,
  v4Quoter: "0xa222dd357a9076d1091ed6aa2e16c9742dd26891" as Address,
  stateView: "0x77395f3b2e73ae90843717371294fa97cc419d64" as Address,
  universalRouter: "0x0d97dc33264bfc1c226207428a79b26757fb9dc3" as Address,
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3" as Address,
  v3FeeTiers: [100, 500, 3000, 10000] as const,
  /** Hookless v4 pools use the canonical fee/tick-spacing pairs. */
  v4Tiers: [
    { fee: 100, tickSpacing: 1 },
    { fee: 500, tickSpacing: 10 },
    { fee: 3000, tickSpacing: 60 },
    { fee: 10000, tickSpacing: 200 },
  ] as const,
} as const;

export const MONDAY = {
  factory: "0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21" as Address,
  quoterV2: "0xB97eCD41Aef0F842E773C8F9905919cDE49880C9" as Address,
  swapRouter: "0xFE951b693A2FE54BE5148614B109E316B567632F" as Address,
  /** feeAmountTickSpacing is enabled for exactly these tiers (read from the factory). */
  feeTiers: [100, 300, 500, 3000, 10000] as const,
} as const;

export const KURU = {
  api: "https://ws.kuru.io",
  entrypoint: "0xb3e6778480b2E488385E8205eA05E20060B813cb" as Address,
  flowRouter: "0x0d3a1BE29E9dEd63c7a5678b31e847D68F71FFa2" as Address,
} as const;

/** Intermediate tokens tried for two-hop routes on the concentrated-liquidity venues. */
export const HOP_TOKENS: Address[] = [
  WMON,
  "0x754704Bc059F8C67012fEd69BC8A327a5aafb603", // USDC
  "0xe7cd86e13AC4309349F30B3435a9d337750fC82D", // USDT0
  "0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242", // WETH
];

export const SWAP_DEADLINE_SECONDS = 10 * 60;
