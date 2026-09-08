"use client";

import { useEffect, useRef, useState } from "react";
import { CandlestickSeries, ColorType, createChart, type IChartApi, type UTCTimestamp } from "lightweight-charts";

/* Two TradingView surfaces: the Advanced Chart widget for anything with an exchange symbol, and TradingView's
   Lightweight Charts for tokens that only exist on-chain (launchpad curves), fed with candles built from events. */

const TV_SCRIPT = "https://s3.tradingview.com/tv.js";
let tvLoading: Promise<void> | null = null;
function loadTradingView(): Promise<void> {
  if (typeof window === "undefined") return Promise.resolve();
  if ((window as Window & { TradingView?: unknown }).TradingView) return Promise.resolve();
  if (!tvLoading) {
    tvLoading = new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = TV_SCRIPT;
      s.async = true;
      s.onload = () => resolve();
      s.onerror = () => { tvLoading = null; reject(new Error("TradingView failed to load")); };
      document.head.appendChild(s);
    });
  }
  return tvLoading;
}

/** Exchange symbols for assets that trade on venues TradingView covers. Perps use Binance perpetual symbols. */
export const TV_SYMBOLS: Record<string, string> = {
  MON: "BYBIT:MONUSDT", WMON: "BYBIT:MONUSDT", BTC: "BINANCE:BTCUSDT", WBTC: "BINANCE:BTCUSDT", cbBTC: "BINANCE:BTCUSDT", LBTC: "BINANCE:BTCUSDT",
  ETH: "BINANCE:ETHUSDT", WETH: "BINANCE:ETHUSDT", ezETH: "BINANCE:ETHUSDT", rETH: "BINANCE:ETHUSDT", SOL: "BINANCE:SOLUSDT", HYPE: "BINANCE:HYPEUSDT.P", ZEC: "BINANCE:ZECUSDT",
  USDT0: "BINANCE:USDCUSDT", USDe: "BINANCE:USDEUSDT", NVDA: "NASDAQ:NVDA", TSLA: "NASDAQ:TSLA", AAPL: "NASDAQ:AAPL", MSFT: "NASDAQ:MSFT", SPY: "AMEX:SPY", GOOGL: "NASDAQ:GOOGL", AMZN: "NASDAQ:AMZN",
};
export const TV_PERP_SYMBOLS: Record<string, string> = { BTC: "BINANCE:BTCUSDT.P", MON: "BINANCE:MONUSDT.P", ETH: "BINANCE:ETHUSDT.P", SOL: "BINANCE:SOLUSDT.P", HYPE: "BINANCE:HYPEUSDT.P", ZEC: "BINANCE:ZECUSDT.P" };

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

type TVWidgetCtor = new (config: Record<string, unknown>) => unknown;

export function TradingViewChart({ symbol, interval = "60", height = 320, style = "1", compact = false }: { symbol: string; interval?: string; height?: number; style?: string; compact?: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const theme = useTheme();
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let cancelled = false;
    el.innerHTML = "";
    const id = `tv-${Math.random().toString(36).slice(2)}`;
    const holder = document.createElement("div");
    holder.id = id;
    holder.style.height = "100%";
    el.appendChild(holder);
    loadTradingView().then(() => {
      if (cancelled) return;
      const TradingView = (window as Window & { TradingView?: { widget: TVWidgetCtor } }).TradingView;
      if (!TradingView) { setFailed(true); return; }
      new TradingView.widget({
        container_id: id, symbol, interval, timezone: "Etc/UTC", theme, style, locale: "en", autosize: true,
        hide_top_toolbar: compact, hide_legend: compact, hide_side_toolbar: true, allow_symbol_change: false, save_image: false, withdateranges: !compact, calendar: false,
        backgroundColor: theme === "dark" ? "#1B211D" : "#FFFFFF", gridColor: theme === "dark" ? "rgba(255,255,255,0.06)" : "rgba(12,16,13,0.06)",
        toolbar_bg: theme === "dark" ? "#1B211D" : "#FFFFFF", enable_publishing: false, hide_volume: compact, details: false,
      });
    }).catch(() => setFailed(true));
    return () => { cancelled = true; el.innerHTML = ""; };
  }, [symbol, interval, theme, style, compact]);
  return (
    <div className="tv-wrap" style={{ height }}>
      <div ref={ref} style={{ height: "100%" }} />
      {failed && <p className="hint" style={{ padding: 12 }}>TradingView could not load in this browser. The chart needs access to tradingview.com.</p>}
    </div>
  );
}

export type Candle = { time: number; open: number; high: number; low: number; close: number; volume?: number };

export function LightweightChart({ candles, height = 260, precision = 6 }: { candles: Candle[]; height?: number; precision?: number }) {
  const ref = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const theme = useTheme();
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const dark = theme === "dark";
    const chart = createChart(el, {
      height,
      autoSize: true,
      layout: { background: { type: ColorType.Solid, color: "transparent" }, textColor: dark ? "#98A494" : "#5E6A5B", fontFamily: "inherit", attributionLogo: true },
      grid: { vertLines: { color: dark ? "rgba(255,255,255,0.05)" : "rgba(12,16,13,0.05)" }, horzLines: { color: dark ? "rgba(255,255,255,0.05)" : "rgba(12,16,13,0.05)" } },
      rightPriceScale: { borderVisible: false },
      timeScale: { borderVisible: false, timeVisible: true, secondsVisible: false },
      crosshair: { horzLine: { labelBackgroundColor: dark ? "#2E372F" : "#DDE3D6" }, vertLine: { labelBackgroundColor: dark ? "#2E372F" : "#DDE3D6" } },
    });
    const series = chart.addSeries(CandlestickSeries, {
      upColor: dark ? "#27DB91" : "#0E9F6E", downColor: dark ? "#FF507A" : "#E5484D", borderVisible: false, wickUpColor: dark ? "#27DB91" : "#0E9F6E", wickDownColor: dark ? "#FF507A" : "#E5484D",
      priceFormat: { type: "price", precision, minMove: 10 ** -precision },
    });
    series.setData(candles.map((c) => ({ time: c.time as UTCTimestamp, open: c.open, high: c.high, low: c.low, close: c.close })));
    chart.timeScale().fitContent();
    chartRef.current = chart;
    return () => { chart.remove(); chartRef.current = null; };
  }, [candles, height, theme, precision]);
  return <div ref={ref} className="lw-chart" style={{ height, width: "100%" }} />;
}
