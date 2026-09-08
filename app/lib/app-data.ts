"use client";

import type { Address } from "viem";
import { DEPLOYED } from "./chain";
import { fetchLaunches, priceNumber, type LaunchInfo } from "./launchpad";
import { loadPrices, type PriceMap } from "./market/prices";
import { CORE_TOKENS, findToken, loadBalances, type TokenInfo } from "./swap/tokens";
import { useAsync } from "./use-async";
import { fetchAccount, fetchPerps, fetchPositions, type PerpAccount, type PerpInfo, type PerpPosition } from "./perps/perpl";

/* Shared, real data for the in-app screens: market prices, wallet balances, launchpad holdings, perps account. */

export type MarketRow = TokenInfo & { usd: number | null; change24h: number | null; balance: bigint; value: number | null; launch?: LaunchInfo };

export function useMarkets(account: Address | null) {
  const launches = useAsync(async () => (DEPLOYED ? fetchLaunches(60) : []), "launches", 20_000);
  const graduated = launches.data ?? [];
  const tokens: TokenInfo[] = [
    ...CORE_TOKENS.filter((t) => t.symbol !== "WMON"),
    ...graduated.filter((l) => !findToken(CORE_TOKENS, l.token)).map((l) => ({ address: l.token, symbol: l.symbol, name: l.name, decimals: 18, logo: l.logo, launchpad: true })),
  ];
  const key = tokens.map((t) => t.address).join(",");
  const prices = useAsync(async () => loadPrices(tokens), `prices:${key}`, 30_000);
  const balances = useAsync(async (): Promise<Record<string, bigint>> => (account ? loadBalances(tokens, account) : {}), `bal:${account ?? ""}:${key}`, 15_000);
  const rows: MarketRow[] = tokens.map((t) => {
    const launch = graduated.find((l) => l.token.toLowerCase() === t.address.toLowerCase());
    const p = prices.data?.[t.address.toLowerCase()];
    // A launchpad token still on its curve is priced by the curve; graduated ones by their pool.
    const monUsd = prices.data?.["0x0000000000000000000000000000000000000000"]?.usd;
    const curveUsd = launch && !p && monUsd !== undefined && launch.pair.native ? priceNumber(launch) * monUsd : undefined;
    const usd = p?.usd ?? curveUsd ?? null;
    const balance = balances.data?.[t.address.toLowerCase()] ?? 0n;
    return { ...t, usd, change24h: p?.change24h ?? null, balance, value: usd === null ? null : (Number(balance) / 10 ** t.decimals) * usd, launch };
  });
  return { rows, loading: prices.loading && !prices.data, error: prices.error, refresh: () => { prices.refresh(); balances.refresh(); launches.refresh(); }, priceMap: prices.data ?? ({} as PriceMap), launches: launches.data ?? [] };
}

export type Portfolio = { total: number | null; holdings: MarketRow[]; perps: { account: PerpAccount | null; positions: PerpPosition[]; perpsInfo: PerpInfo[]; equity: number } | null; loading: boolean };

export function usePerpsAccount(account: Address | null) {
  const perps = useAsync(fetchPerps, "perps", 10_000);
  const acct = useAsync(async () => (account ? fetchAccount(account) : null), `perp-account:${account ?? ""}`, 8_000);
  const positions = useAsync(async () => (acct.data && perps.data ? fetchPositions(acct.data, perps.data) : []), `perp-positions:${account ?? ""}:${acct.data?.accountId ?? 0}:${acct.data?.positionPerps.join("/") ?? ""}:${perps.data ? "p" : ""}`, 8_000);
  return { perps: perps.data ?? [], account: acct.data ?? null, positions: positions.data ?? [], loading: perps.loading || acct.loading, refresh: () => { perps.refresh(); acct.refresh(); positions.refresh(); } };
}
