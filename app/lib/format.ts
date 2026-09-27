import { formatUnits } from "viem";

export const shortAddress = (address: string, chars = 4) => `${address.slice(0, 2 + chars)}…${address.slice(-chars)}`;
const trimZeros = (s: string) => (s.includes(".") ? s.replace(/\.?0+$/, "") : s);
export const bpsToPct = (bps: number, dp = 2) => `${trimZeros((bps / 100).toFixed(dp))}%`;

const SUBSCRIPT = "₀₁₂₃₄₅₆₇₈₉";
const subscript = (n: number) => String(n).split("").map((d) => SUBSCRIPT[Number(d)]).join("");
/** The one minus sign every formatter here uses (U+2212, the width of "+"), never a hyphen. */
const MINUS = "−";
const COMPACT: [number, string][] = [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "K"]];

/** Human number formatting for balances and prices: compact suffixes for large values, trading-style
    leading-zero notation (0.0₆42) for dust prices. */
export function fmtNumber(n: number, opts: { compact?: boolean; dp?: number } = {}): string {
  if (!Number.isFinite(n)) return "—";
  const abs = Math.abs(n);
  const sign = n < 0 ? MINUS : "";
  if (abs === 0) return "0";
  if (opts.compact && abs >= 1e3) {
    for (let i = 0; i < COMPACT.length; i++) {
      const [v, s] = COMPACT[i];
      if (abs < v) continue;
      // 999,999 rounds to "1000K": it is shown in the next unit up ("1M").
      if (i > 0 && Number((abs / v).toFixed(2)) >= 1000) return sign + trimZeros((abs / COMPACT[i - 1][0]).toFixed(2)) + COMPACT[i - 1][1];
      return sign + trimZeros((abs / v).toFixed(2)) + s;
    }
  }
  if (abs >= 1000) return sign + abs.toLocaleString("en-US", { maximumFractionDigits: opts.dp ?? 2 });
  if (abs >= 1) return sign + trimZeros(abs.toFixed(opts.dp ?? 4));
  if (abs >= 1e-4) return sign + trimZeros(abs.toFixed(6));
  const m = abs.toFixed(20).match(/^0\.(0*)(\d{1,4})/);
  if (!m) return sign + abs.toPrecision(3);
  // The significant digits have no decimal point, so their trailing zeros are cut directly ("0.0₆95", not "0.0₆9500").
  return `${sign}0.0${subscript(m[1].length)}${m[2].replace(/0+$/, "") || "0"}`;
}

/** Grouped with exactly `dp` decimals ("1,234.50"), for dollar values and sizes that keep their width. A value that
    rounds to zero carries no sign ("0.00", never "−0.00"). */
export function fmtFixed(n: number, dp = 2): string {
  if (!Number.isFinite(n)) return "—";
  const digits = Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
  return (n < 0 && /[1-9]/.test(digits) ? MINUS : "") + digits;
}

/** US dollars, the same everywhere: cents from $1 up ("$1.50", "$2,493.35", "$102.725"), up to six decimals below $1
    ("$0.50", "$0.0321") and fmtNumber's leading-zero notation for dust ("$0.0₆95"), never exponent notation. */
export function fmtUsd(n: number): string {
  if (!Number.isFinite(n)) return "—";
  const abs = Math.abs(n);
  const body = abs >= 1 ? abs.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: abs >= 1000 ? 2 : 4 })
    : abs >= 1e-4 || abs === 0 ? abs.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 })
    : fmtNumber(abs);
  return (n < 0 && /[1-9]/.test(body) ? MINUS : "") + "$" + body;
}

/** A signed percentage change: "+12.80%", "−2.06%", and "0.00%" for anything that rounds to zero. */
export function fmtPct(n: number, dp = 2): string {
  if (!Number.isFinite(n)) return "—";
  const digits = Math.abs(n).toFixed(dp);
  const sign = !/[1-9]/.test(digits) ? "" : n > 0 ? "+" : MINUS;
  return `${sign}${digits}%`;
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

/** "Sep 26, 04:05 PM"; "—" for a time that isn't one (a half-typed date, or a window too long for a date), never
    "Invalid Date". */
export const fmtDate = (ts: number) => {
  const date = new Date(ts * 1000);
  return Number.isNaN(date.getTime()) ? "—" : date.toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
};
export function timeAgo(ts: number, now: number) {
  const d = Math.max(0, now - ts);
  if (d < 60) return `${d}s ago`;
  if (d < 3600) return `${Math.floor(d / 60)}m ago`;
  if (d < 86400) return `${Math.floor(d / 3600)}h ago`;
  return `${Math.floor(d / 86400)}d ago`;
}
export const seconds = (n: number) => (n === 1 ? "1 second" : `${n} seconds`);
