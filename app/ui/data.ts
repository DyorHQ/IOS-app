// Sample data and formatting helpers shared by the DyorHQ screens. Illustrative only, no real quotes.
import type { IconName } from "./icons";

export const TONES = { violet: "var(--asset-violet)", blue: "var(--asset-blue)", orange: "var(--asset-orange)", eth: "var(--asset-eth)", pink: "var(--asset-pink)", teal: "var(--asset-teal)", nvidia: "var(--asset-nvidia)", tesla: "var(--asset-tesla)", avax: "var(--asset-avax)", sui: "var(--asset-sui)", arb: "var(--asset-arb)", doge: "var(--asset-doge)", usdc: "var(--asset-usdc)" } as const;
export type Tone = keyof typeof TONES;

export type Token = { sym: string; name: string; price: number; chg: number; tone: Tone; perp: boolean; vol: number; hot?: boolean; launch?: boolean; rwa?: boolean };
export const TOKENS: Token[] = [
  { sym: "MON", name: "Monad", price: 1.284, chg: 12.8, tone: "violet", perp: true, vol: 184e6, hot: true },
  { sym: "JENSEN", name: "paired with aNVDA", price: 0.0842, chg: 48.2, tone: "blue", perp: false, vol: 92.8e3, hot: true, launch: true },
  { sym: "BTC", name: "Bitcoin", price: 78391.5, chg: -1.27, tone: "orange", perp: true, vol: 1.24e9 },
  { sym: "ETH", name: "Ethereum", price: 2493.35, chg: -0.58, tone: "eth", perp: true, vol: 640e6 },
  { sym: "PURPLE", name: "paired with aTSLA", price: 0.0198, chg: 31.4, tone: "pink", perp: false, vol: 41e3, hot: true, launch: true },
  { sym: "SOL", name: "Solana", price: 102.725, chg: -2.06, tone: "teal", perp: true, vol: 310e6 },
  { sym: "aNVDA", name: "Tokenized NVIDIA", price: 182.14, chg: 1.72, tone: "nvidia", perp: true, vol: 22e6, rwa: true },
  { sym: "aTSLA", name: "Tokenized Tesla", price: 246.9, chg: -0.91, tone: "tesla", perp: true, vol: 15e6, rwa: true },
  { sym: "AVAX", name: "Avalanche", price: 8.0505, chg: 3.26, tone: "avax", perp: true, vol: 88e6 },
  { sym: "SUI", name: "Sui", price: 0.81145, chg: 1.37, tone: "sui", perp: true, vol: 74e6 },
  { sym: "ARB", name: "Arbitrum", price: 0.17044, chg: 0.2, tone: "arb", perp: true, vol: 51e6 },
  { sym: "DOGE", name: "Dogecoin", price: 0.08924, chg: -0.31, tone: "doge", perp: true, vol: 120e6 },
];
export const byId: Record<string, Token> = Object.fromEntries(TOKENS.map((t) => [t.sym, t]));

export type FeedItem = { user: string; initials: string; time: string; verb: string; token: string; amount: string; thesis: string; ret: number; copies: number; tone: Tone; badge: string; likes: number; replies: number; seed: number };
export const FEED: FeedItem[] = [
  { user: "0xKofi", initials: "KO", time: "2m", verb: "Bought", token: "$JENSEN", amount: "$2,480", thesis: "Blackwell demand keeps surprising. I'm early to the meme, long the underlying story.", ret: 38.4, copies: 42, tone: "blue", badge: "Top 10", likes: 12, replies: 4, seed: 11 },
  { user: "monadmaxi", initials: "MM", time: "8m", verb: "Launched", token: "$PURPLE", amount: "aTSLA pair", thesis: "The fastest chain deserves the fastest car. Fair launch, no team allocation.", ret: 21.7, copies: 19, tone: "pink", badge: "Creator", likes: 19, replies: 5, seed: 23 },
  { user: "ana.chain", initials: "AC", time: "14m", verb: "Bought", token: "$CHOG", amount: "$840", thesis: "Volume is rotating back into Monad natives. Watching graduation liquidity closely.", ret: 9.2, copies: 11, tone: "teal", badge: "Verified", likes: 26, replies: 6, seed: 37 },
];

export type Launch = { name: string; pair: string; progress: number; cap: number; holders: number; tone: Tone; chg: number };
export const LAUNCHES: Launch[] = [
  { name: "JENSEN", pair: "aNVDA", progress: 78, cap: 184200, holders: 1842, tone: "blue", chg: 48.2 },
  { name: "PURPLE", pair: "aTSLA", progress: 51, cap: 96000, holders: 824, tone: "pink", chg: 21.7 },
  { name: "APESTREET", pair: "aAAPL", progress: 34, cap: 42000, holders: 519, tone: "teal", chg: 12.4 },
];

export const HOLDINGS = [{ sym: "MON", qty: 4280 }, { sym: "JENSEN", qty: 28400.18 }, { sym: "BTC", qty: 0.0361 }, { sym: "ETH", qty: 0.8595 }];
export const CASH = 1840;
export const holdingsValue = () => HOLDINGS.reduce((s, h) => s + h.qty * byId[h.sym].price, 0);
export const totalBalance = () => CASH + holdingsValue();

export type Activity = { icon: IconName; title: string; sub: string; amt: string; usd: string };
export const ACTIVITY: Activity[] = [
  { icon: "trade", title: "Bought $JENSEN", sub: "Copied 0xKofi · 2h ago", amt: "+2,969.12 JENSEN", usd: "$250.00" },
  { icon: "rocket", title: "Launched $PURPLE", sub: "Paired with aTSLA · Yesterday", amt: "Graduation 51%", usd: "$96.0K cap" },
  { icon: "deposit", title: "Deposit", sub: "USDC via Monad · Yesterday", amt: "+$1,000.00", usd: "Completed" },
  { icon: "copy", title: "Copy earnings", sub: "127 copiers · Sep 5", amt: "+$284.90", usd: "Paid out" },
];

export const PERP = { sym: "ETH", mid: 2493.35, mark: 2493.1, high: 2531.2, low: 2447.8, volBase: 27400, volQuote: 67.8e6, funding: 0.00036 };
export const JENSEN_PRICE = 0.0842;
export const SWAP_BALANCE = 1840;

/* ---------- formatting ---------- */
export const fmtNum = (n: number, d = 2) => n.toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
export const fmtPrice = (p: number) => (p >= 1000 ? fmtNum(p, 2) : p >= 100 ? fmtNum(p, 3) : p >= 1 ? fmtNum(p, 4) : String(+p.toPrecision(5)));
export const fmtUSD = (p: number) => "$" + fmtPrice(p);
export const fmtPct = (c: number) => (c > 0 ? "+" : c < 0 ? "−" : "") + Math.abs(c).toFixed(2) + "%";
const trim = (s: string) => s.replace(/\.0+$|(\.\d*?)0+$/, "$1");
export const compact = (n: number) => (n >= 1e9 ? trim((n / 1e9).toFixed(2)) + "B" : n >= 1e6 ? trim((n / 1e6).toFixed(1)) + "M" : n >= 1e3 ? trim((n / 1e3).toFixed(1)) + "K" : String(n));
export const capitalize = (s: string) => s[0].toUpperCase() + s.slice(1);

/* ---------- deterministic sample series ---------- */
export function rng(seed: number) {
  let s = (seed * 2654435761) >>> 0 || 7;
  return () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff; };
}
export function walk(seed: number, n: number, drift: number) {
  const r = rng(seed); let v = 50; const out: number[] = [];
  for (let i = 0; i < n; i++) { v += (r() - 0.5 + drift) * 9; out.push(v); }
  return out;
}

/* ---------- filters ---------- */
export type Filter = "Popular" | "Hot" | "Gainers" | "Losers";
export const FILTERS: { v: Filter; l: string; i: IconName }[] = [
  { v: "Popular", l: "Popular", i: "star" }, { v: "Hot", l: "Hot", i: "flame" }, { v: "Gainers", l: "Gainers", i: "trend-up" }, { v: "Losers", l: "Losers", i: "trend-down" },
];
export function filterTokens(list: Token[], filter: Filter) {
  const a = list.slice();
  if (filter === "Hot") return a.filter((t) => t.hot).concat(a.filter((t) => !t.hot).sort((x, y) => Math.abs(y.chg) - Math.abs(x.chg))).slice(0, 7);
  if (filter === "Gainers") return a.sort((x, y) => y.chg - x.chg);
  if (filter === "Losers") return a.sort((x, y) => x.chg - y.chg);
  return a.sort((x, y) => y.vol - x.vol);
}

/* ---------- perps: candles, book, trades ---------- */
export type Candle = { o: number; h: number; l: number; c: number; v: number };
let CANDLES: Candle[] | null = null;
export function candles(): Candle[] {
  if (CANDLES) return CANDLES;
  const r = rng(1337); const out: Candle[] = []; let price = 2372;
  for (let i = 0; i < 40; i++) {
    const o = price; const c = o + (r() - 0.46) * 26 + 0.9; const h = Math.max(o, c) + r() * 11 + 1.5; const l = Math.min(o, c) - r() * 11 - 1.5; const v = 20 + r() * 60;
    out.push({ o, h, l, c, v }); price = c;
  }
  const last = out[out.length - 1]; last.c = PERP.mid; last.h = Math.max(last.h, PERP.mid + 4); last.l = Math.min(last.l, PERP.mid - 4);
  return (CANDLES = out);
}
export const ma = (arr: Candle[], n: number) => arr.map((_, i) => (i < n - 1 ? null : arr.slice(i - n + 1, i + 1).reduce((s, d) => s + d.c, 0) / n));

export type Level = { px: number; sz: number; cum: number };
export function bookLevels() {
  const r = rng(99); const asks: Level[] = []; const bids: Level[] = []; let ca = 0, cb = 0;
  for (let i = 0; i < 8; i++) {
    const sa = +(0.25 + r() * 4.5).toFixed(4), sb = +(0.25 + r() * 4.5).toFixed(4); ca += sa; cb += sb;
    asks.push({ px: PERP.mid + 0.5 * (i + 1) + 0.15, sz: sa, cum: ca }); bids.push({ px: PERP.mid - 0.5 * (i + 1) + 0.15, sz: sb, cum: cb });
  }
  return { asks, bids, max: Math.max(ca, cb), buyPct: Math.round((cb / (ca + cb)) * 100) };
}
export function recentTrades() {
  const r = rng(5); const out: { px: number; sz: number; up: boolean; t: string }[] = [];
  for (let i = 0; i < 10; i++) {
    const up = r() > 0.45;
    out.push({ px: PERP.mid + (r() - 0.5) * 3, sz: +(0.05 + r() * 1.8).toFixed(3), up, t: `07:${String(30 - Math.floor(i / 2)).padStart(2, "0")}:${String(Math.floor(r() * 60)).padStart(2, "0")}` });
  }
  return out;
}
