import { formatUnits } from "viem";

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
/** The exact decimal of `value`, cut (never rounded up) to at most `dp` fraction digits, with no grouping or compact
    notation — for filling an amount field: a Max or 100% preset must never exceed the balance it came from. */
export function exactDown(value: bigint, decimals: number, dp: number): string {
  const [whole, fraction = ""] = formatUnits(value, decimals).split(".");
  const cut = fraction.slice(0, dp).replace(/0+$/, "");
  return cut ? `${whole}.${cut}` : whole;
}

export const fmtAmount = (value: bigint, decimals: number, symbol: string, opts?: { compact?: boolean; dp?: number }) => `${fmtUnits(value, decimals, opts)} ${symbol}`;

/** The input (ASCII digits, "." and "," only) with one "." as its decimal point and no grouping, or null when it is
    ambiguous. A phone's decimal keypad types the region's separator ("," across much of Europe and Latin America), so:
    - one separator of either kind is the decimal point ("0,5" and "0.5" are both one half — never 5);
    - both kinds ("1,234.5", "1.234,5"): the last is the decimal point and the other must group thousands exactly;
    - one kind more than once ("1,234,567"): thousands grouping only, else null. Same rules as the iOS Amount.parse. */
function decimalPoint(s: string): string | null {
  const dots = (s.match(/\./g) ?? []).length;
  const commas = (s.match(/,/g) ?? []).length;
  const grouped = (part: string, sep: string): string | null => {
    const groups = part.split(sep);
    // More than one group: the first can't start with 0 ("0.001,5" is not 1.5, "0,500" alone is one half).
    const first = groups.length > 1 ? /^[1-9]\d{0,2}$/ : /^\d{1,3}$/;
    return first.test(groups[0]) && groups.slice(1).every((g) => /^\d{3}$/.test(g)) ? groups.join("") : null;
  };
  if (dots + commas === 0) return s;
  if (dots + commas === 1) return s.replace(",", ".");
  if (dots > 0 && commas > 0) {
    const decimalSep = s.lastIndexOf(".") > s.lastIndexOf(",") ? "." : ",";
    const at = s.lastIndexOf(decimalSep);
    if (s.indexOf(decimalSep) !== at) return null;
    const whole = grouped(s.slice(0, at), decimalSep === "." ? "," : ".");
    const fraction = s.slice(at + 1);
    return whole === null || /[.,]/.test(fraction) ? null : `${whole}.${fraction}`;
  }
  return grouped(s, dots > 0 ? "." : ",");
}

/** Parses a user-typed decimal amount; returns null for anything that is not a plain positive decimal. A decimal
    comma is read as a decimal point (see decimalPoint), and digits beyond `decimals` are truncated, never rounded up. */
export function parseAmount(input: string, decimals: number): bigint | null {
  const s = input.trim();
  if (!Number.isInteger(decimals) || decimals < 0 || !/^[0-9.,]+$/.test(s)) return null;
  const normalized = decimalPoint(s);
  if (normalized === null) return null;
  const [whole, fraction = ""] = normalized.split(".");
  if (whole === "" && fraction === "") return null;
  return BigInt((whole || "0") + fraction.slice(0, decimals).padEnd(decimals, "0"));
}

/** "Sep 26, 04:05 PM"; "—" for a time that isn't one (a half-typed date or window), never "Invalid Date". */
export const fmtDate = (ts: number) => (Number.isFinite(ts) ? new Date(ts * 1000).toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "—");
export function timeAgo(ts: number, now: number) {
  const d = Math.max(0, now - ts);
  if (d < 60) return `${d}s ago`;
  if (d < 3600) return `${Math.floor(d / 60)}m ago`;
  if (d < 86400) return `${Math.floor(d / 3600)}h ago`;
  return `${Math.floor(d / 86400)}d ago`;
}
export const seconds = (n: number) => (n === 1 ? "1 second" : `${n} seconds`);
