import { formatUnits, parseUnits } from "viem";

export const shortAddress = (address: string, chars = 4) => `${address.slice(0, 2 + chars)}…${address.slice(-chars)}`;
const trimZeros = (s: string) => (s.includes(".") ? s.replace(/\.?0+$/, "") : s);
export const bpsToPct = (bps: number, dp = 2) => `${trimZeros((bps / 100).toFixed(dp))}%`;

const SUBSCRIPT = "₀₁₂₃₄₅₆₇₈₉";
const subscript = (n: number) => String(n).split("").map((d) => SUBSCRIPT[Number(d)]).join("");

/** Human number formatting for balances and prices: compact suffixes for large values, trading-style
    leading-zero notation (0.0₆42) for dust prices. */
export function fmtNumber(n: number, opts: { compact?: boolean; dp?: number } = {}): string {
  if (!Number.isFinite(n)) return "—";
  const abs = Math.abs(n);
  const sign = n < 0 ? "−" : "";
  if (abs === 0) return "0";
  if (opts.compact && abs >= 1e3) {
    const units: [number, string][] = [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "K"]];
    for (const [v, s] of units) if (abs >= v) return sign + trimZeros((abs / v).toFixed(2)) + s;
  }
  if (abs >= 1000) return sign + abs.toLocaleString("en-US", { maximumFractionDigits: opts.dp ?? 2 });
  if (abs >= 1) return sign + trimZeros(abs.toFixed(opts.dp ?? 4));
  if (abs >= 1e-4) return sign + trimZeros(abs.toFixed(6));
  const m = abs.toFixed(20).match(/^0\.(0*)(\d{1,4})/);
  if (!m) return sign + abs.toPrecision(3);
  return `${sign}0.0${subscript(m[1].length)}${trimZeros(m[2])}`;
}

export const fmtUnits = (value: bigint, decimals: number, opts?: { compact?: boolean; dp?: number }) => fmtNumber(Number(formatUnits(value, decimals)), opts);
export const fmtAmount = (value: bigint, decimals: number, symbol: string, opts?: { compact?: boolean; dp?: number }) => `${fmtUnits(value, decimals, opts)} ${symbol}`;

/** Parses a user-typed decimal amount; returns null for anything that is not a plain positive decimal. */
export function parseAmount(input: string, decimals: number): bigint | null {
  const s = input.trim().replace(/,/g, "");
  if (!/^\d*\.?\d*$/.test(s) || s === "" || s === ".") return null;
  try {
    return parseUnits(s, decimals);
  } catch {
    return null;
  }
}

export const fmtDate = (ts: number) => new Date(ts * 1000).toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
export function timeAgo(ts: number, now: number) {
  const d = Math.max(0, now - ts);
  if (d < 60) return `${d}s ago`;
  if (d < 3600) return `${Math.floor(d / 60)}m ago`;
  if (d < 86400) return `${Math.floor(d / 3600)}h ago`;
  return `${Math.floor(d / 86400)}d ago`;
}
export const seconds = (n: number) => (n === 1 ? "1 second" : `${n} seconds`);
