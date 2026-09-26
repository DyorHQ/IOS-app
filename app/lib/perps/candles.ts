import type { Candle } from "../../ui/tradingview";
import { PERP_MARKETS } from "./markets";

/* Perpl's public candle series: GET https://app.perpl.xyz/api/v1/market-data/<market>/candles/<seconds>/<fromMs>-<toMs>
   (no auth, at most 1024 candles, prices scaled by the market's price decimals). Perpl sends no CORS headers, so the
   browser reads it through the app's own proxy (app/api/perpl/[...path]/route.ts), which accepts exactly the paths
   candlesPath builds: a listed market, a listed resolution, and a window aligned to that resolution. Aligned windows
   are the same URL for every viewer within a candle, so the proxy's response can be cached. */

export const CANDLE_RESOLUTIONS = [60, 300, 900, 3600, 14400, 86400] as const;
const MAX_CANDLES = 1024;
const DEFAULT_COUNT = 150;

/** The proxy path for the `count` candles up to now, window aligned to the resolution. */
export function candlesPath(marketId: number, resolution: number, now = Date.now(), count = DEFAULT_COUNT): string {
  const step = resolution * 1000;
  const to = Math.ceil(now / step) * step;
  return `v1/market-data/${marketId}/candles/${resolution}/${to - count * step}-${to}`;
}

/** True only for a path candlesPath can produce, so the proxy relays nothing else from Perpl's market-data API. */
export function isCandlesRoute(route: string): boolean {
  const m = /^v1\/market-data\/(\d{1,3})\/candles\/(\d{2,5})\/(\d{13})-(\d{13})$/.exec(route);
  if (!m) return false;
  const [market, resolution, from, to] = [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4])];
  if (!PERP_MARKETS.some((p) => p.id === market) || !(CANDLE_RESOLUTIONS as readonly number[]).includes(resolution)) return false;
  const step = resolution * 1000;
  return from < to && from % step === 0 && to % step === 0 && (to - from) / step <= MAX_CANDLES;
}

type RawCandle = { t?: unknown; o?: unknown; h?: unknown; l?: unknown; c?: unknown; v?: unknown };

/** Perpl's `{ d: [{ t, o, h, l, c, v }] }` as chart candles: prices unscaled, seconds, ascending, one per time. */
export function toCandles(json: unknown, priceDecimals: number): Candle[] {
  const rows = (json as { d?: unknown } | null)?.d;
  if (!Array.isArray(rows)) throw new Error("Perpl returned no candle series.");
  const scale = 10 ** priceDecimals;
  const byTime = new Map<number, Candle>();
  for (const row of rows as RawCandle[]) {
    const [t, o, h, l, c] = [row?.t, row?.o, row?.h, row?.l, row?.c].map(Number);
    if (![t, o, h, l, c].every(Number.isFinite) || o <= 0 || h <= 0 || l <= 0 || c <= 0) continue;
    const time = Math.floor(t / 1000);
    byTime.set(time, { time, open: o / scale, high: h / scale, low: l / scale, close: c / scale, volume: Number(row.v) || 0 });
  }
  return [...byTime.values()].sort((a, b) => a.time - b.time);
}

export async function fetchPerplCandles(marketId: number, resolution: number, priceDecimals: number, signal?: AbortSignal): Promise<Candle[]> {
  const res = await fetch(`/api/perpl/${candlesPath(marketId, resolution)}`, { signal });
  if (!res.ok) throw new Error(`Perpl candles unavailable (${res.status})`);
  return toCandles(await res.json(), priceDecimals);
}
