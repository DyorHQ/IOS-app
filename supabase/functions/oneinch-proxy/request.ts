// What oneinch-proxy accepts, forwards and answers. Everything here is pure; index.ts does the I/O.
//
// The proxy quotes ONE kind of trade: a curated xStock (tokenized stock, ../_shared/xstocks.json) against USDC on
// Monad, either way. It never forwards what the caller sends: it validates the caller's pair, amount and slippage, then
// builds the 1inch query itself, with the session's wallet as from, origin and receiver and the other parameters
// forced. Fee, referrer, permit and protocols are never sent, whatever the caller asks: DyorHQ takes no fee on these
// trades, and no unreviewed protocol may be pinned. Every answer is rebuilt from the few fields the app needs and
// checked first, so nothing else 1inch says (time fields, gas, protocol names) ever reaches the app.

// The 1inch Swap API (classic, v6) for Monad. UNVERIFIED (research R1): the paths, the parameters and the answer's
// shape below are 1inch's documented v6 API; they have not been tried against chain 143 yet.
export const ONEINCH_API = "https://api.1inch.dev/swap/v6.0/143";
// AggregationRouterV6 on Monad, lowercase. UNVERIFIED (research R3a): from Monad's protocol directory
// (github.com/monad-crypto/protocols, mainnet/1inch.jsonc), the same constant as OneInch.router in the app.
export const ROUTER = "0x111111125421ca6dc452d289314280a0f8842a65";
// swap(address,(address,address,address,address,uint256,uint256,uint256),bytes). UNVERIFIED (research R3): computed
// locally; the only router function a swap answer may call.
export const SWAP_SELECTOR = "0x07ed2379";
// The most slippage a stock trade may take, in basis points (1%); the app's OneInch.stockSlippageCapBps.
export const STOCK_SLIPPAGE_CAP_BPS = 100;
// The per-trade cap, in USDC base units (6 decimals): $250. Checked on the amount paid for a buy and on the amount
// received for a sell.
export const TRADE_CAP_USDC = 250_000_000n;
// The disclosure version the app must have acknowledged before a buy (status answers it).
export const TERMS_VERSION = 1;
// Request and answer bounds.
export const MAX_BODY = 4_096;
export const MAX_UPSTREAM_BODY = 256 * 1024;
export const MAX_TX_DATA_BYTES = 64 * 1024;
// How long an indicative quote may be served again from the isolate's cache. Firm (swap) answers are never cached.
export const QUOTE_CACHE_MS = 5_000;
// How long the app_config flag is trusted before it is read again.
export const FLAG_TTL_MS = 30_000;

const MAX_UINT256 = (1n << 256n) - 1n;
const ADDRESS = /^0x[0-9a-f]{40}$/;

export type Route = "status" | "quote" | "swap";
export const ROUTES: ReadonlySet<string> = new Set<Route>(["status", "quote", "swap"]);
export type Mode = "off" | "sell-only" | "on";

// A refusal or failure as the app sees it: a status and a machine code (plus a few documented fields). The app maps
// codes to its own sentences; no upstream text ever reaches it.
export type Refusal = { status: number; body: { code: string; [field: string]: unknown } };
const refuse = (status: number, code: string, extra: Record<string, unknown> = {}): Refusal => ({
  status,
  body: { code, ...extra },
});

// ── The curated list ──────────────────────────────────────────────────────────────────────────────────────────────

export type Stock = { symbol: string; address: string };
export type Registry = { usdc: string; stocks: ReadonlyMap<string, Stock> };

// The registry from xstocks.json's value. Throws when it is not exactly the documented shape (supabase/README.md):
// {"version": 1, "chainId": 143, "usdc": "<lowercase address>", "curated": [{"symbol": "...", "address": "..."}]},
// with lowercase, unique addresses that are not USDC's and unique symbols.
export function parseRegistry(value: unknown): Registry {
  const fail = (why: string): never => {
    throw new Error(`xstocks.json: ${why}`);
  };
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("not an object");
  const v = value as Record<string, unknown>;
  const keys = Object.keys(v).sort().join(",");
  if (keys !== "chainId,curated,usdc,version") fail(`unexpected keys ${keys}`);
  if (v.version !== 1 || v.chainId !== 143) fail("version must be 1 and chainId 143");
  if (typeof v.usdc !== "string" || !ADDRESS.test(v.usdc)) fail("usdc must be a lowercase address");
  if (!Array.isArray(v.curated)) fail("curated must be an array");
  const stocks = new Map<string, Stock>();
  const symbols = new Set<string>();
  for (const entry of v.curated as unknown[]) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) fail("a curated entry is not an object");
    const e = entry as Record<string, unknown>;
    if (Object.keys(e).sort().join(",") !== "address,symbol") fail("a curated entry must hold symbol and address only");
    if (typeof e.symbol !== "string" || !/^[A-Za-z0-9.]{1,16}$/.test(e.symbol)) fail("a symbol is malformed");
    if (typeof e.address !== "string" || !ADDRESS.test(e.address)) fail("an address is not lowercase hex");
    const symbol = e.symbol as string, address = e.address as string;
    if (address === v.usdc || stocks.has(address)) fail(`${symbol}: address repeated or USDC's`);
    if (symbols.has(symbol.toLowerCase())) fail(`${symbol}: symbol repeated`);
    symbols.add(symbol.toLowerCase());
    stocks.set(address, { symbol, address });
  }
  return { usdc: v.usdc as string, stocks };
}

// ── The switches (Supabase secrets, read on every request) ──────────────────────────────────────────────────────

// ONEINCH_MODE: "on" serves buys and sells, "sell-only" sells only, and anything else — unset, "off", or a typo — is
// off. `valid` is false for a value that is set but not one of the three, so the caller can log it.
export function parseMode(raw: string | undefined): { mode: Mode; valid: boolean } {
  const value = (raw ?? "").trim().toLowerCase();
  if (value === "on" || value === "sell-only" || value === "off") return { mode: value, valid: true };
  return { mode: "off", valid: value === "" };
}

// A comma- or space-separated list (ONEINCH_WALLETS, ONEINCH_DENY, ONEINCH_DENY_ALL), lowercased; unset is empty.
export function parseList(raw: string | undefined): Set<string> {
  return new Set((raw ?? "").split(/[\s,]+/).map((s) => s.trim().toLowerCase()).filter((s) => s.length > 0));
}

// Whether a deny list (tickers or addresses, any case) names `stock`.
export const denies = (list: Set<string>, stock: Stock) =>
  list.has(stock.address) || list.has(stock.symbol.toLowerCase());

// ── The caller's request ────────────────────────────────────────────────────────────────────────────────────────

export type Side = "buy" | "sell";
export type Trade = {
  route: "quote" | "swap";
  side: Side; // buy: USDC in, the stock out; sell: the stock in, USDC out
  stock: Stock;
  src: string;
  dst: string;
  amount: bigint;
  slippageBps: number; // swap only; 0 for a quote
};

function object(raw: string): Record<string, unknown> | null {
  try {
    const value = JSON.parse(raw);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

// The trade a quote or swap body asks for, or the refusal. Body: {"src", "dst", "amount"} for a quote, plus
// {"from", "slippageBps"} for a swap; src and dst lowercase addresses, amount a positive integer string of at most
// 2^256 − 1, slippageBps an integer from 0 to the stock cap, from the session's wallet. Any other field is ignored —
// never forwarded.
export function parseTrade(raw: string, route: "quote" | "swap", wallet: string, registry: Registry): Trade | Refusal {
  const body = object(raw);
  if (!body) return refuse(400, "bad_request");
  const { src, dst } = body;
  if (typeof src !== "string" || typeof dst !== "string" || !ADDRESS.test(src) || !ADDRESS.test(dst) || src === dst) {
    return refuse(422, "pair_not_offered");
  }
  const side: Side | null = src === registry.usdc && registry.stocks.has(dst)
    ? "buy"
    : dst === registry.usdc && registry.stocks.has(src)
    ? "sell"
    : null;
  if (!side) return refuse(422, "pair_not_offered");
  if (typeof body.amount !== "string" || !/^[1-9][0-9]{0,77}$/.test(body.amount)) return refuse(400, "bad_request");
  const amount = BigInt(body.amount);
  if (amount > MAX_UINT256) return refuse(400, "bad_request");
  let slippageBps = 0;
  if (route === "swap") {
    const bps = body.slippageBps;
    if (typeof bps !== "number" || !Number.isInteger(bps) || bps < 0 || bps > STOCK_SLIPPAGE_CAP_BPS) {
      return refuse(400, "bad_request");
    }
    slippageBps = bps;
    if (typeof body.from !== "string" || body.from.toLowerCase() !== wallet) return refuse(409, "wallet_mismatch");
  }
  const stock = registry.stocks.get(side === "buy" ? dst : src)!;
  return { route, side, stock, src, dst, amount, slippageBps };
}

export const isRefusal = (value: unknown): value is Refusal =>
  !!value && typeof value === "object" && "status" in value && "body" in value;

// ── Who is served ───────────────────────────────────────────────────────────────────────────────────────────────

export type Switches = {
  mode: Mode;
  wallets: Set<string>; // ONEINCH_WALLETS: when not empty, only these are served, and they are the beta wallets
  deny: Set<string>; // ONEINCH_DENY: no buys of these
  denyAll: Set<string>; // ONEINCH_DENY_ALL: neither buys nor sells of these
};

// The mode this wallet is served in, and whether it holds the beta bit (status answers both).
export function walletMode(switches: Switches, wallet: string): { mode: Mode; beta: boolean } {
  if (switches.wallets.size === 0) return { mode: switches.mode, beta: false };
  return switches.wallets.has(wallet) ? { mode: switches.mode, beta: true } : { mode: "off", beta: false };
}

// The checks before the rate gate, in order: the mode, the beta list, the app_config flag for a buy by a wallet without
// the beta bit (`flagOn` is asked only then: null means it could not be read, which refuses), the deny lists, and a
// buy's cap on what it pays. null when the trade may go on.
export async function admit(
  trade: Trade,
  switches: Switches,
  wallet: string,
  flagOn: () => Promise<boolean | null>,
): Promise<Refusal | null> {
  const { mode, beta } = walletMode(switches, wallet);
  if (mode === "off" || (mode === "sell-only" && trade.side === "buy")) return refuse(503, "disabled");
  if (trade.side === "buy" && !beta && (await flagOn()) !== true) return refuse(503, "disabled");
  if (denies(switches.denyAll, trade.stock) || (trade.side === "buy" && denies(switches.deny, trade.stock))) {
    return refuse(422, "pair_not_offered");
  }
  if (trade.side === "buy" && trade.amount > TRADE_CAP_USDC) {
    return refuse(422, "over_cap", { max: TRADE_CAP_USDC.toString() });
  }
  return null;
}

// A sell's cap, on the USDC it would receive (dstAmount from 1inch).
export function sellCap(trade: Trade, dstAmount: string): Refusal | null {
  return trade.side === "sell" && BigInt(dstAmount) > TRADE_CAP_USDC
    ? refuse(422, "over_cap", { max: TRADE_CAP_USDC.toString() })
    : null;
}

// ── What 1inch is asked ─────────────────────────────────────────────────────────────────────────────────────────

// Basis points as the percent 1inch's `slippage` takes, by integer arithmetic: 50 → "0.5", 100 → "1", 5 → "0.05".
export function slippagePercent(bps: number): string {
  if (!Number.isInteger(bps) || bps < 0 || bps > STOCK_SLIPPAGE_CAP_BPS) throw new RangeError("slippage out of range");
  const whole = Math.floor(bps / 100), cents = bps % 100;
  return cents === 0 ? String(whole) : `${whole}.${String(cents).padStart(2, "0").replace(/0$/, "")}`;
}

// The upstream URL: every parameter set here, none taken from the caller. UNVERIFIED (research R1): whether 1inch
// serves these pairs through its classic API on chain 143, and the xChange protocol id (unknown, so `protocols` is
// never sent).
export function upstreamURL(trade: Trade, wallet: string): URL {
  const url = new URL(`${ONEINCH_API}/${trade.route}`);
  const p = url.searchParams;
  p.set("src", trade.src);
  p.set("dst", trade.dst);
  p.set("amount", trade.amount.toString());
  if (trade.route === "swap") {
    p.set("from", wallet);
    p.set("origin", wallet);
    p.set("receiver", wallet);
    p.set("slippage", slippagePercent(trade.slippageBps));
    p.set("disableEstimate", "true");
    p.set("allowPartialFill", "false");
    p.set("usePermit2", "false");
  }
  p.set("includeProtocols", "true");
  return url;
}

// ── What the app is answered ────────────────────────────────────────────────────────────────────────────────────

export type QuoteAnswer = { dstAmount: string };
export type SwapAnswer = { dstAmount: string; tx: { to: string; from: string; data: string; value: "0" } };
// An answer that does not check out: `reason` and the call's selector are all that is logged.
export type Anomaly = { anomaly: string; selector: string };

function amountField(v: unknown): string | null {
  if (typeof v !== "string" || !/^[1-9][0-9]{0,77}$/.test(v)) return null;
  return BigInt(v) <= MAX_UINT256 ? v : null;
}

// A quote answer as {dstAmount}, nothing else.
export function rebuildQuote(raw: string): QuoteAnswer | Anomaly {
  const answer = object(raw);
  const dstAmount = amountField(answer?.dstAmount);
  return dstAmount ? { dstAmount } : { anomaly: "dstAmount", selector: "-" };
}

// A swap answer as {dstAmount, tx: {to, from, data, value}}, only when the transaction calls the pinned router's
// swap() from the session's wallet, with no value and at most 64 KiB of calldata. The app decodes and checks the
// calldata itself before anything is signed (OneInchSwap); this is the server's first, structural line.
export function rebuildSwap(raw: string, wallet: string): SwapAnswer | Anomaly {
  const answer = object(raw);
  const tx = answer?.tx && typeof answer.tx === "object" && !Array.isArray(answer.tx)
    ? answer.tx as Record<string, unknown>
    : null;
  const data = typeof tx?.data === "string" ? tx.data.toLowerCase() : "";
  const selector = /^0x[0-9a-f]{8}/.test(data) ? data.slice(0, 10) : "-";
  const bad = (anomaly: string): Anomaly => ({ anomaly, selector });
  const dstAmount = amountField(answer?.dstAmount);
  if (!dstAmount) return bad("dstAmount");
  if (!tx) return bad("tx");
  if (typeof tx.to !== "string" || tx.to.toLowerCase() !== ROUTER) return bad("to");
  if (typeof tx.from !== "string" || tx.from.toLowerCase() !== wallet) return bad("from");
  if (tx.value !== "0") return bad("value");
  if (!/^0x(?:[0-9a-f]{2})+$/.test(data)) return bad("data");
  if (selector !== SWAP_SELECTOR) return bad("selector");
  if ((data.length - 2) / 2 > MAX_TX_DATA_BYTES) return bad("size");
  return { dstAmount, tx: { to: ROUTER, from: wallet, data, value: "0" } };
}

export const isAnomaly = (value: unknown): value is Anomaly =>
  !!value && typeof value === "object" && "anomaly" in value;

// An upstream error as the app sees it: a code, never 1inch's text. 401 means 1inch refused DyorHQ's key (the
// function is not usable: "unavailable"); 429 is 1inch's quota ("busy"); another 4xx is classified from 1inch's
// description; 5xx and anything else is "upstream". UNVERIFIED (research R1): how 1inch words a missing route on
// Monad, what a 403 means there (taken here as a refusal of the address), and whether xChange's market hours show up
// as an error at all (R5).
export function upstreamError(status: number, raw: string): Refusal {
  if (status === 401) return refuse(503, "unavailable");
  if (status === 429) return refuse(503, "busy", { retryable: true });
  if (status === 403) return refuse(403, "refused");
  if (status >= 400 && status < 500) {
    const answer = object(raw);
    const said = [answer?.description, answer?.error, answer?.message].filter((s) => typeof s === "string").join(" ");
    if (/market\s+(?:is\s+)?closed|trading\s+hours|market\s+hours/i.test(said)) return refuse(422, "market_closed");
    if (/liquidity|no\s+route|cannot\s+find|not\s+found\s+route|insufficient/i.test(said)) {
      return refuse(422, "no_route");
    }
    return refuse(422, "refused");
  }
  return refuse(502, "upstream", { retryable: true });
}

// What may be logged about an upstream body: at most 160 characters, with the key, every address (a wallet) and
// control characters removed.
export function logExcerpt(raw: string, key: string): string {
  let text = key ? raw.split(key).join("[redacted]") : raw;
  // deno-lint-ignore no-control-regex
  text = text.replace(/0x[0-9a-fA-F]{40}/g, "[address]").replace(/[\u0000-\u001f\u007f]/g, " ");
  return text.slice(0, 160);
}

// The rate gate's refusal (../_shared/rate.ts), rewritten as codes: its 429 becomes rate_limited with retryAfter and
// the limit that fired; anything else (its 503: the gate failed or timed out) becomes busy.
export async function gateCodes(refusal: Response): Promise<Refusal & { retryAfter?: number }> {
  if (refusal.status === 429) {
    let body: Record<string, unknown> = {};
    try {
      body = await refusal.json();
    } catch { /* the gate's own body; keep the code */ }
    const retryAfter = typeof body.retryAfter === "number" ? body.retryAfter : 60;
    const limit = typeof body.limit === "string" ? { limit: body.limit } : {};
    return { ...refuse(429, "rate_limited", { retryAfter, ...limit }), retryAfter };
  }
  return refuse(503, "busy", { retryable: true });
}

// ── Isolate caches ──────────────────────────────────────────────────────────────────────────────────────────────

// Indicative quotes by pair and amount, for QUOTE_CACHE_MS. Only the quote route uses it: a firm swap answer is an
// RFQ the issuer signed for one caller, and is never served twice.
export class QuoteCache {
  #entries = new Map<string, { dstAmount: string; until: number }>();
  constructor(readonly ttlMs = QUOTE_CACHE_MS, readonly maxEntries = 512) {}
  static key(trade: Trade) {
    return `${trade.src}|${trade.dst}|${trade.amount}`;
  }
  get(key: string, now: number): string | null {
    const hit = this.#entries.get(key);
    if (!hit) return null;
    if (hit.until > now) return hit.dstAmount;
    this.#entries.delete(key);
    return null;
  }
  set(key: string, dstAmount: string, now: number) {
    this.#entries.delete(key);
    this.#entries.set(key, { dstAmount, until: now + this.ttlMs });
    while (this.#entries.size > this.maxEntries) this.#entries.delete(this.#entries.keys().next().value!);
  }
  get size() {
    return this.#entries.size;
  }
}

// app_config's flags.xStocks for buys: true only when the row says JSON true. It is read at most every FLAG_TTL_MS;
// a failed read keeps the last value read (and is retried after 5 s), and a flag never read is not on.
export function flagFromConfig(value: unknown): boolean {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const flags = (value as Record<string, unknown>).flags;
  if (!flags || typeof flags !== "object" || Array.isArray(flags)) return false;
  return (flags as Record<string, unknown>).xStocks === true;
}

export class FlagCache {
  #value: boolean | null = null;
  #next = 0;
  constructor(readonly ttlMs = FLAG_TTL_MS, readonly retryMs = 5_000) {}
  async current(read: () => Promise<boolean>, now: number): Promise<boolean | null> {
    if (now < this.#next) return this.#value;
    try {
      this.#value = await read();
      this.#next = now + this.ttlMs;
    } catch {
      this.#next = now + this.retryMs;
    }
    return this.#value;
  }
}
