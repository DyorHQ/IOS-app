"use client";

import { useEffect, useRef, useState } from "react";
import { CandlestickSeries, ColorType, createChart, type IChartApi, type ISeriesApi, type UTCTimestamp } from "lightweight-charts";
import { fetchPerplCandles } from "../lib/perps/candles";
import { fetchPerplContext } from "../lib/perps/perpl";
import { useAsync } from "../lib/use-async";

/* Charts are drawn in the bundle with TradingView's Lightweight Charts, from data the app reads itself: Perpl's candles
   for anything with a Perpl market, candles built from curve trades for launchpad tokens. No third-party script runs
   on this origin (the wallet's origin); other assets link out to TradingView's own site instead. */

/** Assets whose chart is their Perpl perpetual (the market id). Wrapped forms follow their underlying one to one. */
export const PERPL_CHARTS: Record<string, { id: number; symbol: string }> = {
  MON: { id: 10, symbol: "MON" }, WMON: { id: 10, symbol: "MON" },
  WBTC: { id: 1, symbol: "BTC" }, cbBTC: { id: 1, symbol: "BTC" },
  WETH: { id: 20, symbol: "ETH" },
};

/** TradingView symbols for assets the app has no candles for; they open on tradingview.com, never inside the app. */
export const TV_SYMBOLS: Record<string, string> = {
  LBTC: "BINANCE:BTCUSDT", ezETH: "BINANCE:ETHUSDT", rETH: "BINANCE:ETHUSDT", USDe: "BINANCE:USDEUSDT",
  NVDA: "NASDAQ:NVDA", TSLA: "NASDAQ:TSLA", AAPL: "NASDAQ:AAPL", MSFT: "NASDAQ:MSFT", SPY: "AMEX:SPY", GOOGL: "NASDAQ:GOOGL", AMZN: "NASDAQ:AMZN",
};
/** The symbol's page on tradingview.com ("NASDAQ:NVDA" → …/symbols/NASDAQ-NVDA/). */
export const tradingViewUrl = (symbol: string) => `https://www.tradingview.com/symbols/${encodeURIComponent(symbol.replace(":", "-"))}/`;

function currentTheme(): "light" | "dark" {
  if (typeof document === "undefined") return "light";
  const forced = document.documentElement.getAttribute("data-theme");
  if (forced === "dark" || forced === "light") return forced;
  return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}
function useTheme() {
  const [theme, setTheme] = useState<"light" | "dark">("light");
  useEffect(() => {
    const update = () => setTheme(currentTheme());
    update();
    const mq = matchMedia("(prefers-color-scheme: dark)");
    mq.addEventListener("change", update);
    const obs = new MutationObserver(update);
    obs.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => { mq.removeEventListener("change", update); obs.disconnect(); };
  }, []);
  return theme;
}

/** The chart's colours and font from the design tokens (a canvas can't read CSS variables), for the current theme. */
function chartTokens() {
  const css = getComputedStyle(document.documentElement);
  const token = (name: string) => css.getPropertyValue(name).trim();
  return { text: token("--muted"), grid: token("--inner"), label: token("--inner2"), up: token("--up"), down: token("--down"), font: token("--mono") };
}

export type Candle = { time: number; open: number; high: number; low: number; close: number; volume?: number };

/** A candlestick chart. New candles replace the data in place, so a refresh keeps the viewer's zoom and scroll. */
export function LightweightChart({ candles, height = 260, precision = 6 }: { candles: Candle[]; height?: number; precision?: number }) {
  const ref = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const seriesRef = useRef<ISeriesApi<"Candlestick"> | null>(null);
  const fitted = useRef(false);
  const theme = useTheme();
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    // Re-created on a theme change (the effect depends on `theme`), so the tokens are read for the theme now showing.
    const c = chartTokens();
    const chart = createChart(el, {
      height,
      autoSize: true,
      layout: { background: { type: ColorType.Solid, color: "transparent" }, textColor: c.text, fontFamily: c.font, attributionLogo: true },
      grid: { vertLines: { color: c.grid }, horzLines: { color: c.grid } },
      rightPriceScale: { borderVisible: false },
      timeScale: { borderVisible: false, timeVisible: true, secondsVisible: false },
      crosshair: { horzLine: { labelBackgroundColor: c.label }, vertLine: { labelBackgroundColor: c.label } },
    });
    seriesRef.current = chart.addSeries(CandlestickSeries, {
      upColor: c.up, downColor: c.down, borderVisible: false, wickUpColor: c.up, wickDownColor: c.down,
      priceFormat: { type: "price", precision, minMove: 10 ** -precision },
    });
    chartRef.current = chart;
    fitted.current = false;
    return () => { chart.remove(); chartRef.current = null; seriesRef.current = null; };
  }, [height, theme, precision]);
  useEffect(() => {
    const series = seriesRef.current;
    if (!series) return;
    series.setData(candles.map((c) => ({ time: c.time as UTCTimestamp, open: c.open, high: c.high, low: c.low, close: c.close })));
    if (!fitted.current && candles.length > 0) {
      chartRef.current?.timeScale().fitContent();
      fitted.current = true;
    }
  }, [candles, height, theme, precision]);
  return <div ref={ref} className="lw-chart" style={{ height, width: "100%" }} />;
}

/** A Perpl market's candles at `resolution` seconds, read through the app's proxy and refreshed as candles form. */
export function PerplChart({ marketId, resolution = 3600, height = 300 }: { marketId: number; resolution?: number; height?: number }) {
  const ctx = useAsync((signal) => fetchPerplContext(signal), "perpl-context", 60_000);
  const priceDecimals = ctx.data?.find((m) => m.id === marketId)?.priceDecimals ?? null;
  const candles = useAsync(
    async (signal) => (priceDecimals === null ? null : fetchPerplCandles(marketId, resolution, priceDecimals, signal)),
    `perpl-candles:${marketId}:${resolution}:${priceDecimals ?? ""}`,
    30_000,
  );
  const error = candles.error ?? (priceDecimals === null ? ctx.error : null);
  if (candles.data && candles.data.length > 1) return <LightweightChart candles={candles.data} height={height} precision={Math.min(8, Math.max(2, priceDecimals ?? 2))} />;
  return (
    <div className="card" style={{ height, display: "grid", placeItems: "center" }}>
      <p className={`hint ${error ? "err" : ""}`}>{error ? `Couldn't read Perpl's candles: ${error}` : candles.data ? "Perpl has no candles for this market yet." : "Reading Perpl's candles…"}</p>
    </div>
  );
}
