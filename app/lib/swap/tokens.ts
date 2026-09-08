import { erc20Abi, getAddress, isAddress, type Address } from "viem";
import { publicClient } from "../chain";
import { NATIVE, WMON } from "./config";

export type TokenInfo = { address: Address; symbol: string; name: string; decimals: number; logo: string; native?: boolean; launchpad?: boolean };

const LOGO = (symbol: string, ext = "svg") => `https://raw.githubusercontent.com/monad-crypto/token-list/refs/heads/main/mainnet/${symbol}/logo.${ext}`;

/** Curated spot assets from Monad's official token list (monad-crypto/token-list, mainnet v2.48). */
export const CORE_TOKENS: TokenInfo[] = [
  { address: NATIVE, symbol: "MON", name: "Monad", decimals: 18, logo: LOGO("MON"), native: true },
  { address: WMON, symbol: "WMON", name: "Wrapped MON", decimals: 18, logo: LOGO("WMON") },
  { address: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603", symbol: "USDC", name: "USDC", decimals: 6, logo: LOGO("USDC") },
  { address: "0xe7cd86e13AC4309349F30B3435a9d337750fC82D", symbol: "USDT0", name: "USDT0", decimals: 6, logo: LOGO("USDT0") },
  { address: "0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242", symbol: "WETH", name: "Wrapped Ether", decimals: 18, logo: LOGO("WETH") },
  { address: "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c", symbol: "WBTC", name: "Wrapped BTC", decimals: 8, logo: LOGO("WBTC") },
  { address: "0xd18B7EC58Cdf4876f6AFebd3Ed1730e4Ce10414b", symbol: "cbBTC", name: "Coinbase Wrapped BTC", decimals: 8, logo: LOGO("cbBTC") },
  { address: "0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081", symbol: "gMON", name: "gMON", decimals: 18, logo: LOGO("gMON") },
  { address: "0xA3227C5969757783154C60bF0bC1944180ed81B9", symbol: "sMON", name: "Kintsu Staked Monad", decimals: 18, logo: LOGO("sMON") },
  { address: "0x0c65A0BC65a5D819235B71F554D210D3F80E0852", symbol: "aprMON", name: "aPriori Monad LST", decimals: 18, logo: LOGO("aprMON") },
  { address: "0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c", symbol: "shMON", name: "ShMonad", decimals: 18, logo: LOGO("shMON", "png") },
  { address: "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a", symbol: "AUSD", name: "AUSD", decimals: 6, logo: LOGO("AUSD") },
  { address: "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34", symbol: "USDe", name: "USDe", decimals: 18, logo: LOGO("USDe") },
  { address: "0x111111d2bf19e43C34263401e0CAd979eD1cdb61", symbol: "USD1", name: "World Liberty Financial USD", decimals: 6, logo: LOGO("USD1") },
  { address: "0xacA92E438df0B2401fF60dA7E4337B687a2435DA", symbol: "mUSD", name: "MetaMask USD", decimals: 6, logo: LOGO("mUSD") },
  { address: "0xecAc9C5F704e954931349Da37F60E39f515c11c1", symbol: "LBTC", name: "Lombard Staked Bitcoin", decimals: 8, logo: LOGO("LBTC") },
  { address: "0x2416092f143378750bb29b79eD961ab195CcEea5", symbol: "ezETH", name: "Renzo Restaked ETH", decimals: 18, logo: LOGO("ezETH") },
  { address: "0xC50f2e735eDd9dCD8Ccd41EcFE9894E679e3195f", symbol: "rETH", name: "Rocket Pool ETH", decimals: 18, logo: LOGO("rETH") },
];

export const isNative = (address: Address) => address.toLowerCase() === NATIVE;
export const sameToken = (a: Address, b: Address) => a.toLowerCase() === b.toLowerCase();
/** Native MON trades as WMON on the concentrated-liquidity venues. */
export const wrapped = (address: Address): Address => (isNative(address) ? WMON : address);

export function findToken(list: TokenInfo[], address: string): TokenInfo | undefined {
  return list.find((t) => t.address.toLowerCase() === address.toLowerCase());
}

/** Reads symbol, name and decimals for an arbitrary ERC-20 so any Monad token can be swapped by address. */
export async function loadToken(address: string): Promise<TokenInfo | null> {
  if (!isAddress(address)) return null;
  const checksummed = getAddress(address);
  try {
    const erc20 = { address: checksummed, abi: erc20Abi } as const;
    const [symbol, name, decimals] = await publicClient.multicall({
      contracts: [
        { ...erc20, functionName: "symbol" },
        { ...erc20, functionName: "name" },
        { ...erc20, functionName: "decimals" },
      ],
      allowFailure: false,
    });
    return { address: checksummed, symbol, name, decimals, logo: "" };
  } catch {
    return null;
  }
}

export async function loadBalances(tokens: TokenInfo[], account: Address): Promise<Record<string, bigint>> {
  const erc20s = tokens.filter((t) => !t.native);
  const [native, balances] = await Promise.all([
    tokens.some((t) => t.native) ? publicClient.getBalance({ address: account }) : Promise.resolve(0n),
    erc20s.length
      ? publicClient.multicall({ contracts: erc20s.map((t) => ({ address: t.address, abi: erc20Abi, functionName: "balanceOf", args: [account] }) as const), allowFailure: true })
      : Promise.resolve([]),
  ]);
  const out: Record<string, bigint> = {};
  for (const t of tokens) if (t.native) out[t.address.toLowerCase()] = native;
  erc20s.forEach((t, i) => {
    const r = balances[i];
    out[t.address.toLowerCase()] = r && r.status === "success" ? (r.result as bigint) : 0n;
  });
  return out;
}
