// deno test --no-config --node-modules-dir=none -A supabase/functions/oneinch-proxy/
// Every address below except USDC's and the router's is a TEST-ONLY fixture: no xStock is listed yet (xstocks.json).
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { mintSession, sessionSigner } from "../wallet-auth/session.ts";
import { type SessionKeys } from "../_shared/wallet_session.ts";
import { XSTOCKS } from "../_shared/xstocks.ts";
import { type Deps, handler } from "./index.ts";
import {
  admit,
  FlagCache,
  flagFromConfig,
  gateCodes,
  logExcerpt,
  MAX_TX_DATA_BYTES,
  parseList,
  parseMode,
  parseRegistry,
  parseTrade,
  QuoteCache,
  rebuildQuote,
  rebuildSwap,
  ROUTER,
  slippagePercent,
  type Switches,
  TERMS_VERSION,
  type Trade,
  upstreamError,
  upstreamURL,
} from "./request.ts";

const WALLET = "0x" + "ab".repeat(20);
const OTHER = "0x" + "cd".repeat(20);
const USDC = "0x754704bc059f8c67012fed69bc8a327a5aafb603";
const TSLA = "0x" + "5a".repeat(20); // TEST-ONLY
const NVDA = "0x" + "5b".repeat(20); // TEST-ONLY
const STRANGER = "0x" + "5c".repeat(20); // TEST-ONLY: not listed
const KEY = "test-1inch-key-" + "k".repeat(24);
const SECRET = "test-secret-" + "x".repeat(32);
const DATA = "0x07ed2379" + "00".repeat(196);

const REGISTRY = parseRegistry({
  version: 1,
  chainId: 143,
  usdc: USDC,
  curated: [{ symbol: "TSLAx", address: TSLA }, { symbol: "NVDAx", address: NVDA }],
});
const nowS = () => Math.floor(Date.now() / 1000);
const keys: SessionKeys = { secret: new TextEncoder().encode(SECRET), jwks: null };
const session = async (wallet = WALLET) => mintSession(wallet, (await sessionSigner({ secret: SECRET }))!, nowS());

// ── Pure rules ──────────────────────────────────────────────────────────────────────────────────────────────────

Deno.test("registry: the shipped xstocks.json parses and lists nothing yet; anything off-shape is refused", () => {
  const shipped = parseRegistry(XSTOCKS);
  assertEquals(shipped.usdc, USDC);
  assertEquals(shipped.stocks.size, 0);
  assertEquals(REGISTRY.stocks.get(TSLA), { symbol: "TSLAx", address: TSLA });
  const base = { version: 1, chainId: 143, usdc: USDC, curated: [] as unknown[] };
  for (
    const bad of [
      null,
      [],
      "x",
      { ...base, version: 2 },
      { ...base, chainId: 1 },
      { ...base, usdc: USDC.toUpperCase().replace("0X", "0x") },
      { ...base, curated: {} },
      { ...base, extra: 1 },
      { ...base, curated: [{ symbol: "A", address: TSLA, decimals: 18 }] },
      { ...base, curated: [{ symbol: "A", address: TSLA.toUpperCase().replace("0X", "0x") }] },
      { ...base, curated: [{ symbol: "A", address: USDC }] },
      { ...base, curated: [{ symbol: "A", address: TSLA }, { symbol: "B", address: TSLA }] },
      { ...base, curated: [{ symbol: "A", address: TSLA }, { symbol: "a", address: NVDA }] },
      { ...base, curated: [{ symbol: "", address: TSLA }] },
      { ...base, curated: [{ symbol: "A B", address: TSLA }] },
    ]
  ) {
    assertThrows(() => parseRegistry(bad), Error, "xstocks.json", JSON.stringify(bad));
  }
});

Deno.test("switches: ONEINCH_MODE unset or unknown is off; lists are lowercase sets", () => {
  assertEquals(parseMode(undefined), { mode: "off", valid: true });
  assertEquals(parseMode(" "), { mode: "off", valid: true });
  assertEquals(parseMode("on"), { mode: "on", valid: true });
  assertEquals(parseMode(" Sell-Only "), { mode: "sell-only", valid: true });
  assertEquals(parseMode("off"), { mode: "off", valid: true });
  for (const typo of ["yes", "true", "1", "sell", "sellonly", "buy-only"]) {
    assertEquals(parseMode(typo), { mode: "off", valid: false });
  }
  assertEquals(parseList(undefined), new Set());
  assertEquals(
    parseList(` ${WALLET.toUpperCase().replace("0X", "0x")}, ${OTHER}\nTSLAx `),
    new Set([WALLET, OTHER, "tslax"]),
  );
});

Deno.test("slippage: basis points to 1inch's percent by integer arithmetic, capped at 100 bps", () => {
  const table: [number, string][] = [[0, "0"], [1, "0.01"], [5, "0.05"], [10, "0.1"], [25, "0.25"], [50, "0.5"], [
    99,
    "0.99",
  ], [100, "1"]];
  for (const [bps, percent] of table) assertEquals(slippagePercent(bps), percent, String(bps));
  for (const bad of [-1, 101, 1.5, NaN]) assertThrows(() => slippagePercent(bad), RangeError);
});

const quoteBody = (over: Record<string, unknown> = {}) =>
  JSON.stringify({ src: USDC, dst: TSLA, amount: "100000000", ...over });
const swapBody = (over: Record<string, unknown> = {}) =>
  JSON.stringify({ src: USDC, dst: TSLA, amount: "100000000", from: WALLET, slippageBps: 50, ...over });

Deno.test("trade: only a curated xStock against USDC, either way", () => {
  const buy = parseTrade(quoteBody(), "quote", WALLET, REGISTRY) as Trade;
  assertEquals([buy.side, buy.stock.symbol, buy.amount], ["buy", "TSLAx", 100_000_000n]);
  const sell = parseTrade(quoteBody({ src: NVDA, dst: USDC, amount: "5" }), "quote", WALLET, REGISTRY) as Trade;
  assertEquals([sell.side, sell.stock.symbol], ["sell", "NVDAx"]);
  for (
    const [src, dst] of [
      [TSLA, NVDA],
      [USDC, USDC],
      [TSLA, TSLA],
      [USDC, STRANGER],
      [STRANGER, USDC],
      [USDC, "0x" + "ee".repeat(20)],
      [USDC, "0x" + "00".repeat(20)],
      [USDC.toUpperCase(), TSLA],
      [USDC, TSLA.toUpperCase().replace("0X", "0x")],
      [USDC, 5],
      [undefined, TSLA],
    ]
  ) {
    assertEquals(parseTrade(quoteBody({ src, dst }), "quote", WALLET, REGISTRY), {
      status: 422,
      body: { code: "pair_not_offered" },
    }, `${src} ${dst}`);
  }
});

Deno.test("trade: amount is a positive integer string up to 2^256 − 1; slippage an integer up to the cap", () => {
  const max = ((1n << 256n) - 1n).toString();
  assertEquals((parseTrade(quoteBody({ amount: max }), "quote", WALLET, REGISTRY) as Trade).amount, (1n << 256n) - 1n);
  for (const amount of ["0", "01", "1.5", "-1", "1e6", "", " 1", (1n << 256n).toString(), "9".repeat(79), 5, null]) {
    assertEquals(parseTrade(quoteBody({ amount }), "quote", WALLET, REGISTRY), {
      status: 400,
      body: { code: "bad_request" },
    }, String(amount));
  }
  for (const slippageBps of [-1, 101, 1.5, "50", null, undefined]) {
    assertEquals(parseTrade(swapBody({ slippageBps }), "swap", WALLET, REGISTRY), {
      status: 400,
      body: { code: "bad_request" },
    }, String(slippageBps));
  }
  assertEquals((parseTrade(swapBody({ slippageBps: 100 }), "swap", WALLET, REGISTRY) as Trade).slippageBps, 100);
  assertEquals((parseTrade(swapBody({ slippageBps: 0 }), "swap", WALLET, REGISTRY) as Trade).slippageBps, 0);
  // A quote takes no slippage, whatever is sent.
  assertEquals((parseTrade(quoteBody({ slippageBps: 9_999 }), "quote", WALLET, REGISTRY) as Trade).slippageBps, 0);
  for (const raw of ["", "[]", "nope", "null"]) {
    assertEquals(parseTrade(raw, "quote", WALLET, REGISTRY), { status: 400, body: { code: "bad_request" } }, raw);
  }
});

Deno.test("trade: a swap's from must be the session's wallet (any case)", () => {
  assertEquals(
    (parseTrade(swapBody({ from: WALLET.toUpperCase().replace("0X", "0x") }), "swap", WALLET, REGISTRY) as Trade).side,
    "buy",
  );
  for (const from of [OTHER, undefined, "", 7]) {
    assertEquals(parseTrade(swapBody({ from }), "swap", WALLET, REGISTRY), {
      status: 409,
      body: { code: "wallet_mismatch" },
    }, String(from));
  }
});

Deno.test("upstream query: every parameter forced; from, origin and receiver are the wallet; fee, referrer, permit and protocols never sent", () => {
  const hostile = {
    fee: "3",
    referrer: OTHER,
    permit: "0xdead",
    protocols: "EVIL",
    receiver: OTHER,
    origin: OTHER,
    disableEstimate: false,
    allowPartialFill: true,
    usePermit2: true,
    slippage: "50",
  };
  const quote = parseTrade(quoteBody(hostile), "quote", WALLET, REGISTRY) as Trade;
  const q = upstreamURL(quote, WALLET);
  assertEquals(`${q.origin}${q.pathname}`, "https://api.1inch.dev/swap/v6.0/143/quote");
  assertEquals(Object.fromEntries(q.searchParams), {
    src: USDC,
    dst: TSLA,
    amount: "100000000",
    includeProtocols: "true",
  });
  const swap = parseTrade(swapBody(hostile), "swap", WALLET, REGISTRY) as Trade;
  const s = upstreamURL(swap, WALLET);
  assertEquals(`${s.origin}${s.pathname}`, "https://api.1inch.dev/swap/v6.0/143/swap");
  assertEquals(Object.fromEntries(s.searchParams), {
    src: USDC,
    dst: TSLA,
    amount: "100000000",
    from: WALLET,
    origin: WALLET,
    receiver: WALLET,
    slippage: "0.5",
    disableEstimate: "true",
    allowPartialFill: "false",
    usePermit2: "false",
    includeProtocols: "true",
  });
  for (const url of [q, s]) {
    for (const name of ["fee", "referrer", "permit", "protocols", "excludedProtocols", "gasPrice", "complexityLevel"]) {
      assertEquals(url.searchParams.has(name), false, name);
    }
  }
});

Deno.test("answers: a quote is {dstAmount}; a swap only the router's swap() from the wallet, rebuilt; no time field", () => {
  assertEquals(
    rebuildQuote(JSON.stringify({ dstAmount: "123", srcToken: {}, protocols: [], expiresAt: 9, serverTime: 1 })),
    { dstAmount: "123" },
  );
  for (
    const bad of [
      "{}",
      "nope",
      JSON.stringify({ dstAmount: 123 }),
      JSON.stringify({ dstAmount: "0" }),
      JSON.stringify({ dstAmount: "01" }),
      JSON.stringify({ dstAmount: (1n << 256n).toString() }),
    ]
  ) {
    assertEquals(rebuildQuote(bad), { anomaly: "dstAmount", selector: "-" }, bad);
  }
  const good = {
    to: ROUTER.toUpperCase().replace("0X", "0x"),
    from: WALLET.toUpperCase().replace("0X", "0x"),
    data: DATA.toUpperCase().replace("0X", "0x"),
    value: "0",
    gas: 0,
    gasPrice: "1",
  };
  const answer = (tx: Record<string, unknown> | null, extra: Record<string, unknown> = {}) =>
    JSON.stringify({ dstAmount: "456", tx, protocols: [["x"]], deadline: 1_900_000_000, expiry: 5, ...extra });
  assertEquals(rebuildSwap(answer(good), WALLET), {
    dstAmount: "456",
    tx: { to: ROUTER, from: WALLET, data: DATA, value: "0" },
  });
  const cases: [Record<string, unknown> | null, string, string][] = [
    [null, "tx", "-"],
    [{ ...good, to: OTHER }, "to", "0x07ed2379"],
    [{ ...good, to: undefined }, "to", "0x07ed2379"],
    [{ ...good, from: OTHER }, "from", "0x07ed2379"],
    [{ ...good, value: "1" }, "value", "0x07ed2379"],
    [{ ...good, value: 0 }, "value", "0x07ed2379"],
    [{ ...good, value: "0x0" }, "value", "0x07ed2379"],
    [{ ...good, data: "0x12345678" + "00".repeat(32) }, "selector", "0x12345678"],
    [{ ...good, data: DATA + "0" }, "data", "0x07ed2379"],
    [{ ...good, data: DATA + "zz" }, "data", "0x07ed2379"],
    [{ ...good, data: "0x07ed23" }, "selector", "-"],
    [{ ...good, data: 5 }, "data", "-"],
    [{ ...good, data: "0x07ed2379" + "00".repeat(MAX_TX_DATA_BYTES - 3) }, "size", "0x07ed2379"],
  ];
  for (const [tx, anomaly, selector] of cases) {
    assertEquals(rebuildSwap(answer(tx), WALLET), { anomaly, selector }, JSON.stringify(tx)?.slice(0, 80));
  }
  // Exactly 64 KiB of calldata is accepted.
  const full = "0x07ed2379" + "00".repeat(MAX_TX_DATA_BYTES - 4);
  assertEquals((rebuildSwap(answer({ ...good, data: full }), WALLET) as { tx: { data: string } }).tx.data, full);
  assertEquals(rebuildSwap(answer(good, { dstAmount: "0" }), WALLET), { anomaly: "dstAmount", selector: "0x07ed2379" });
});

Deno.test("upstream errors: codes only, never 1inch's text; the log excerpt drops the key and every address", () => {
  const said = (description: string) => JSON.stringify({ error: "Bad Request", description, statusCode: 400 });
  assertEquals(upstreamError(401, "{}"), { status: 503, body: { code: "unavailable" } });
  assertEquals(upstreamError(429, "{}"), { status: 503, body: { code: "busy", retryable: true } });
  assertEquals(upstreamError(403, "{}"), { status: 403, body: { code: "refused" } });
  assertEquals(upstreamError(400, said("insufficient liquidity")), { status: 422, body: { code: "no_route" } });
  assertEquals(upstreamError(400, said("Market is closed")), { status: 422, body: { code: "market_closed" } });
  assertEquals(upstreamError(404, said("something else")), { status: 422, body: { code: "refused" } });
  assertEquals(upstreamError(400, "<html>"), { status: 422, body: { code: "refused" } });
  assertEquals(upstreamError(500, said("x")), { status: 502, body: { code: "upstream", retryable: true } });
  assertEquals(upstreamError(503, ""), { status: 502, body: { code: "upstream", retryable: true } });
  const excerpt = logExcerpt(
    `bad key ${KEY} for ${WALLET} and ${OTHER.toUpperCase().replace("0X", "0x")}\n` + "y".repeat(500),
    KEY,
  );
  assertEquals(excerpt.includes(KEY) || excerpt.includes(WALLET.slice(2)) || excerpt.includes("\n"), false);
  assertEquals(excerpt.startsWith("bad key [redacted] for [address] and [address] y"), true);
  assertEquals(excerpt.length, 160);
});

Deno.test("gate codes: 429 becomes rate_limited with retryAfter and the limit; anything else busy", async () => {
  const limited = new Response(JSON.stringify({ error: "too many", retryAfter: 86_000, limit: "subject" }), {
    status: 429,
  });
  assertEquals(await gateCodes(limited), {
    status: 429,
    body: { code: "rate_limited", retryAfter: 86_000, limit: "subject" },
    retryAfter: 86_000,
  });
  assertEquals(await gateCodes(new Response("{}", { status: 503 })), {
    status: 503,
    body: { code: "busy", retryable: true },
  });
});

Deno.test("flag: only JSON true; read at most every 30 s; a failed read keeps the last value; never read is off", async () => {
  assertEquals(flagFromConfig({ min_build: 0, flags: { xStocks: true } }), true);
  for (
    const value of [
      null,
      {},
      { flags: null },
      { flags: [] },
      { flags: {} },
      { flags: { xStocks: "true" } },
      { flags: { xStocks: 1 } },
      { flags: { xStocks: false } },
      [{ flags: { xStocks: true } }],
    ]
  ) {
    assertEquals(flagFromConfig(value), false, JSON.stringify(value));
  }
  const cache = new FlagCache(30_000, 5_000);
  let reads = 0;
  const fail = () => {
    reads++;
    return Promise.reject(new Error("down"));
  };
  const ok = (v: boolean) => () => {
    reads++;
    return Promise.resolve(v);
  };
  assertEquals(await cache.current(fail, 0), null, "never read");
  assertEquals(await cache.current(ok(true), 1_000), null, "a failed read is retried after 5 s, not before");
  assertEquals(await cache.current(ok(true), 5_000), true);
  assertEquals(await cache.current(ok(false), 34_999), true, "cached for 30 s");
  assertEquals(await cache.current(fail, 35_000), true, "a failed read keeps the last value");
  assertEquals(await cache.current(ok(false), 40_000), false);
  assertEquals(reads, 4);
});

Deno.test("quote cache: 5 s, by pair and amount, bounded", () => {
  const cache = new QuoteCache(5_000, 2);
  cache.set("a", "1", 0);
  assertEquals(cache.get("a", 4_999), "1");
  assertEquals(cache.get("a", 5_000), null);
  cache.set("a", "1", 0);
  cache.set("b", "2", 0);
  cache.set("c", "3", 0);
  assertEquals([cache.size, cache.get("a", 1), cache.get("c", 1)], [2, null, "3"]);
});

const SWITCHES = (over: Partial<Switches> = {}): Switches => ({
  mode: "on",
  wallets: new Set(),
  deny: new Set(),
  denyAll: new Set(),
  ...over,
});

Deno.test("admit: mode, beta list, flag (buys only), deny lists, buy cap — in that order", async () => {
  const buy = parseTrade(quoteBody(), "quote", WALLET, REGISTRY) as Trade;
  const sell = parseTrade(quoteBody({ src: TSLA, dst: USDC }), "quote", WALLET, REGISTRY) as Trade;
  const on = () => Promise.resolve(true), off = () => Promise.resolve(false), unread = () => Promise.resolve(null);
  const disabled = { status: 503, body: { code: "disabled" } };
  assertEquals(await admit(buy, SWITCHES(), WALLET, on), null);
  assertEquals(await admit(sell, SWITCHES(), WALLET, off), null, "a sell never needs the flag");
  assertEquals(await admit(buy, SWITCHES(), WALLET, off), disabled);
  assertEquals(await admit(buy, SWITCHES(), WALLET, unread), disabled);
  assertEquals(await admit(buy, SWITCHES({ mode: "off" }), WALLET, on), disabled);
  assertEquals(await admit(sell, SWITCHES({ mode: "off" }), WALLET, on), disabled);
  assertEquals(await admit(buy, SWITCHES({ mode: "sell-only" }), WALLET, on), disabled);
  assertEquals(await admit(sell, SWITCHES({ mode: "sell-only" }), WALLET, off), null);
  // The beta list: only its wallets are served, and they skip the flag.
  assertEquals(await admit(buy, SWITCHES({ wallets: new Set([WALLET]) }), WALLET, off), null);
  assertEquals(await admit(buy, SWITCHES({ wallets: new Set([OTHER]) }), WALLET, on), disabled);
  assertEquals(await admit(sell, SWITCHES({ wallets: new Set([OTHER]) }), WALLET, on), disabled);
  // Deny lists, by ticker or address.
  const notOffered = { status: 422, body: { code: "pair_not_offered" } };
  assertEquals(await admit(buy, SWITCHES({ deny: new Set(["tslax"]) }), WALLET, on), notOffered);
  assertEquals(await admit(sell, SWITCHES({ deny: new Set(["tslax"]) }), WALLET, on), null, "DENY blocks buys only");
  assertEquals(await admit(sell, SWITCHES({ denyAll: new Set([TSLA]) }), WALLET, on), notOffered);
  assertEquals(await admit(buy, SWITCHES({ denyAll: new Set(["tslax"]) }), WALLET, on), notOffered);
  assertEquals(await admit(buy, SWITCHES({ deny: new Set(["nvdax"]) }), WALLET, on), null);
  // $250 per buy, on what it pays.
  const at = (amount: string) => parseTrade(quoteBody({ amount }), "quote", WALLET, REGISTRY) as Trade;
  assertEquals(await admit(at("250000000"), SWITCHES(), WALLET, on), null);
  assertEquals(await admit(at("250000001"), SWITCHES(), WALLET, on), {
    status: 422,
    body: { code: "over_cap", max: "250000000" },
  });
  // The flag is not read when it cannot matter.
  let asked = 0;
  const counting = () => {
    asked++;
    return Promise.resolve(true);
  };
  await admit(sell, SWITCHES(), WALLET, counting);
  await admit(buy, SWITCHES({ wallets: new Set([WALLET]) }), WALLET, counting);
  await admit(buy, SWITCHES({ mode: "sell-only" }), WALLET, counting);
  assertEquals(asked, 0);
});

// ── The handler, end to end with fake dependencies ─────────────────────────────────────────────────────────────

type Fake = {
  deps: Deps;
  fetched: { url: URL; init: RequestInit }[];
  gated: { scope: string; wallet: string; net: string | null }[];
  logs: string[];
  configReads: number;
  clock: { now: number };
};

function fake(options: {
  env?: Record<string, string>;
  upstream?: (url: URL) => Response | Promise<Response>;
  gate?: (scope: string) => Response | null | Promise<Response | null>;
  config?: () => Promise<unknown>;
} = {}): Fake {
  const env = { ONEINCH_API_KEY: KEY, ONEINCH_MODE: "on", ...options.env };
  const f: Fake = { fetched: [], gated: [], logs: [], configReads: 0, clock: { now: 1_000_000 } } as unknown as Fake;
  const swapAnswer = {
    dstAmount: "456",
    tx: { to: ROUTER, from: WALLET, data: DATA, value: "0", gas: 0 },
    protocols: [],
  };
  f.deps = {
    env: { get: (name) => env[name as keyof typeof env] },
    keys,
    registry: REGISTRY,
    fetch: (url, init) => {
      f.fetched.push({ url, init });
      if (options.upstream) return Promise.resolve(options.upstream(url));
      const body = url.pathname.endsWith("/swap") ? swapAnswer : { dstAmount: "123" };
      return Promise.resolve(new Response(JSON.stringify(body), { status: 200 }));
    },
    gate: (scope, wallet, net) => {
      f.gated.push({ scope, wallet, net });
      return Promise.resolve(options.gate ? options.gate(scope) : null);
    },
    readConfig: () => {
      f.configReads++;
      return options.config ? options.config() : Promise.resolve({ min_build: 0, flags: { xStocks: true } });
    },
    flags: new FlagCache(),
    quotes: new QuoteCache(),
    now: () => f.clock.now,
    log: (...parts) => f.logs.push(parts.map(String).join(" ")),
    timeoutsMs: { gate: 50, flag: 50 },
  };
  return f;
}

async function call(
  f: Fake,
  route: string,
  body: string | null,
  init: { token?: string | null; method?: string; ip?: string } = {},
) {
  const headers: Record<string, string> = { "cf-connecting-ip": init.ip ?? "2001:db8:abcd:12ff::1" };
  const token = init.token === undefined ? await session() : init.token;
  if (token !== null) headers.authorization = `Bearer ${token}`;
  const res = await handler(
    new Request(`https://x.test/functions/v1/oneinch-proxy/${route}`, { method: init.method ?? "POST", headers, body }),
    f.deps,
  );
  const text = await res.text();
  return { status: res.status, headers: res.headers, body: text ? JSON.parse(text) : null };
}

Deno.test("handler: POST, a known route and a wallet session first; no CORS; never cached by clients", async () => {
  const f = fake();
  assertEquals((await call(f, "quote", null, { method: "GET" })).status, 405);
  assertEquals((await call(f, "quote", null, { method: "OPTIONS" })).status, 405);
  assertEquals((await call(f, "tokens", "{}")).body, { code: "route" });
  assertEquals((await call(f, "swap/extra", "{}")).status, 404);
  const none = await call(f, "quote", quoteBody(), { token: null });
  assertEquals([none.status, none.body], [401, { code: "session" }]);
  const anon = await call(f, "quote", quoteBody(), { token: "sb_publishable_xxxxxxxx" });
  assertEquals([anon.status, anon.body], [403, { code: "session" }]);
  const ok = await call(f, "quote", quoteBody());
  assertEquals([ok.status, ok.body], [200, { dstAmount: "123" }]);
  assertEquals(ok.headers.get("Cache-Control"), "no-store");
  assertEquals(ok.headers.get("Access-Control-Allow-Origin"), null);
  // The ES256 path without a JWKS is an outage, not "not signed in".
  const outage = fake();
  outage.deps.keys = { secret: null, jwks: () => Promise.reject(new TypeError("unreachable")) };
  const { privateKey } = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ]);
  const jwk = JSON.stringify({ ...(await crypto.subtle.exportKey("jwk", privateKey)), kid: "k" });
  const es = await mintSession(WALLET, (await sessionSigner({ jwk }))!, nowS());
  assertEquals((await call(outage, "quote", quoteBody(), { token: es })).body, { code: "unavailable" });
  assertEquals(f.fetched.length, 1);
});

Deno.test("handler: bodies over 4 KiB are refused unread", async () => {
  const f = fake();
  assertEquals((await call(f, "quote", quoteBody({ pad: "x".repeat(5_000) }))).status, 413);
  assertEquals(f.fetched.length + f.gated.length, 0);
});

Deno.test("handler: status answers mode, beta and termsVersion; never calls 1inch; never cached", async () => {
  const cases: [Record<string, string>, unknown][] = [
    [{}, { mode: "on", beta: false, termsVersion: TERMS_VERSION }],
    [{ ONEINCH_MODE: "" }, { mode: "off", beta: false, termsVersion: TERMS_VERSION }],
    [{ ONEINCH_MODE: "sell-only" }, { mode: "sell-only", beta: false, termsVersion: TERMS_VERSION }],
    [{ ONEINCH_WALLETS: `${OTHER},${WALLET}` }, { mode: "on", beta: true, termsVersion: TERMS_VERSION }],
    [{ ONEINCH_WALLETS: OTHER }, { mode: "off", beta: false, termsVersion: TERMS_VERSION }],
  ];
  for (const [env, expected] of cases) {
    const f = fake({ env });
    if (env.ONEINCH_MODE === "") f.deps.env = { get: (n) => n === "ONEINCH_API_KEY" ? KEY : undefined };
    for (let i = 0; i < 2; i++) assertEquals((await call(f, "status", "{}")).body, expected, JSON.stringify(env));
    assertEquals(f.fetched.length, 0);
    assertEquals(f.gated.map((g) => g.scope), ["oneinch", "oneinch"]);
  }
  // A typo in the mode is off, and logged (without any wallet).
  const typo = fake({ env: { ONEINCH_MODE: "yes" } });
  assertEquals((await call(typo, "status", "")).body.mode, "off");
  assert(typo.logs.some((l) => l.includes("ONEINCH_MODE")));
});

Deno.test("handler: modes — off refuses everything, sell-only serves sells only, on serves both", async () => {
  const sellBody = quoteBody({ src: TSLA, dst: USDC });
  for (
    const [mode, buy, sell] of [["off", 503, 503], ["", 503, 503], ["sell-only", 503, 200], ["on", 200, 200]] as const
  ) {
    const f = fake({ env: { ONEINCH_MODE: mode } });
    assertEquals((await call(f, "quote", quoteBody())).status, buy, `${mode} buy`);
    assertEquals((await call(f, "swap", swapBody({ src: TSLA, dst: USDC }))).status, sell, `${mode} sell`);
    if (buy === 503) assertEquals((await call(f, "swap", swapBody())).body, { code: "disabled" });
    assertEquals((await call(f, "quote", sellBody)).status, sell);
  }
});

Deno.test("handler: the beta list and the app_config flag (buys only)", async () => {
  // A beta wallet is served while flags.xStocks is false; a wallet not on the list is not served at all.
  const beta = fake({ env: { ONEINCH_WALLETS: WALLET }, config: () => Promise.resolve({ flags: { xStocks: false } }) });
  assertEquals((await call(beta, "quote", quoteBody())).status, 200);
  assertEquals(beta.configReads, 0);
  const outsider = fake({ env: { ONEINCH_WALLETS: OTHER } });
  assertEquals((await call(outsider, "quote", quoteBody())).body, { code: "disabled" });
  assertEquals((await call(outsider, "quote", quoteBody({ src: TSLA, dst: USDC }))).body, { code: "disabled" });
  // Without a list: buys need the flag; sells (the L1 exit) never do.
  for (const config of [{ flags: { xStocks: false } }, { min_build: 0 }, null, { flags: { xStocks: "true" } }]) {
    const f = fake({ config: () => Promise.resolve(config) });
    assertEquals((await call(f, "quote", quoteBody())).body, { code: "disabled" }, JSON.stringify(config));
    assertEquals((await call(f, "swap", swapBody({ src: TSLA, dst: USDC }))).status, 200);
    assertEquals(f.fetched.length, 1);
  }
  // A flag that cannot be read (an error, or no answer in time) refuses buys until it is read.
  const down = fake({ config: () => Promise.reject(new Error("db down")) });
  assertEquals((await call(down, "quote", quoteBody())).body, { code: "disabled" });
  const slow = fake({ config: () => new Promise(() => {}) });
  assertEquals((await call(slow, "quote", quoteBody())).body, { code: "disabled" });
  // Read once per 30 s; a failure afterwards keeps the last good value.
  let answer: () => Promise<unknown> = () => Promise.resolve({ flags: { xStocks: true } });
  const f = fake({ config: () => answer() });
  assertEquals((await call(f, "quote", quoteBody())).status, 200);
  assertEquals((await call(f, "quote", quoteBody({ amount: "2" }))).status, 200);
  assertEquals(f.configReads, 1);
  answer = () => Promise.reject(new Error("down"));
  f.clock.now += 31_000;
  assertEquals((await call(f, "quote", quoteBody({ amount: "3" }))).status, 200);
  answer = () => Promise.resolve({ flags: { xStocks: false } });
  f.clock.now += 6_000;
  assertEquals((await call(f, "quote", quoteBody({ amount: "4" }))).body, { code: "disabled" });
});

Deno.test("handler: deny lists and the $250 cap (a buy before 1inch, a sell on its answer)", async () => {
  const denied = fake({ env: { ONEINCH_DENY: "TSLAx", ONEINCH_DENY_ALL: NVDA } });
  assertEquals((await call(denied, "quote", quoteBody())).body, { code: "pair_not_offered" });
  assertEquals((await call(denied, "quote", quoteBody({ src: TSLA, dst: USDC }))).status, 200);
  assertEquals((await call(denied, "quote", quoteBody({ src: NVDA, dst: USDC }))).body, { code: "pair_not_offered" });
  const f = fake();
  assertEquals((await call(f, "swap", swapBody({ amount: "250000001" }))).body, { code: "over_cap", max: "250000000" });
  assertEquals(f.fetched.length + f.gated.length, 0, "refused before the gate and 1inch");
  const rich = fake({ upstream: () => new Response(JSON.stringify({ dstAmount: "250000001" })) });
  assertEquals((await call(rich, "quote", quoteBody({ src: TSLA, dst: USDC, amount: "10" }))).body, {
    code: "over_cap",
    max: "250000000",
  });
});

Deno.test("handler: rate gate — oneinch for quotes, oneinch-firm for swaps, per wallet and /48; refusals as codes", async () => {
  const f = fake();
  await call(f, "quote", quoteBody());
  await call(f, "swap", swapBody());
  assertEquals(f.gated, [
    { scope: "oneinch", wallet: WALLET, net: "2001:db8:abcd::/48" },
    { scope: "oneinch-firm", wallet: WALLET, net: "2001:db8:abcd::/48" },
  ]);
  const limited = fake({
    gate: () => new Response(JSON.stringify({ error: "x", retryAfter: 86_000, limit: "subject" }), { status: 429 }),
  });
  const res = await call(limited, "swap", swapBody());
  assertEquals([res.status, res.body], [429, { code: "rate_limited", retryAfter: 86_000, limit: "subject" }]);
  assertEquals(res.headers.get("Retry-After"), "86000");
  assertEquals(limited.fetched.length, 0);
  for (
    const gate of [
      () => new Response("{}", { status: 503 }),
      () => Promise.reject(new Error("rpc")),
      () => new Promise<null>(() => {}),
    ]
  ) {
    const g = fake({ gate });
    const busy = await call(g, "quote", quoteBody());
    assertEquals([busy.status, busy.body], [503, { code: "busy", retryable: true }]);
    assertEquals(g.fetched.length, 0);
  }
});

Deno.test("handler: only the quote route is cached (5 s); a firm swap is fetched every time", async () => {
  const f = fake();
  for (let i = 0; i < 3; i++) assertEquals((await call(f, "quote", quoteBody())).body, { dstAmount: "123" });
  assertEquals(f.fetched.length, 1);
  assertEquals(f.gated.length, 3, "a cached answer still passes the gate");
  await call(f, "quote", quoteBody({ amount: "99" }));
  assertEquals(f.fetched.length, 2, "another amount is another quote");
  f.clock.now += 5_000;
  await call(f, "quote", quoteBody());
  assertEquals(f.fetched.length, 3, "expired after 5 s");
  const s = fake();
  for (let i = 0; i < 3; i++) assertEquals((await call(s, "swap", swapBody())).status, 200);
  assertEquals(s.fetched.length, 3);
  assertEquals(s.deps.quotes.size, 0);
});

Deno.test("handler: 1inch is asked with the key in a header, redirects refused, a deadline; answers rebuilt", async () => {
  const f = fake();
  const res = await call(f, "swap", swapBody({ fee: 3, referrer: OTHER, protocols: "X" }));
  assertEquals(res.body, { dstAmount: "456", tx: { to: ROUTER, from: WALLET, data: DATA, value: "0" } });
  const { url, init } = f.fetched[0];
  assertEquals(init.method, "GET");
  assertEquals(init.redirect, "error");
  assert(init.signal instanceof AbortSignal);
  assertEquals((init.headers as Record<string, string>).Authorization, `Bearer ${KEY}`);
  assertEquals(url.href.includes(KEY), false);
  assertEquals(url.searchParams.get("from"), WALLET);
  for (const name of ["fee", "referrer", "protocols"]) assertEquals(url.searchParams.has(name), false);
  // Nothing but the rebuilt fields, whatever 1inch adds (time fields included).
  const chatty = fake({
    upstream: () => new Response(JSON.stringify({ dstAmount: "7", expiresAt: 1, serverTime: 2, quoteId: "q" })),
  });
  assertEquals((await call(chatty, "quote", quoteBody())).body, { dstAmount: "7" });
});

Deno.test("handler: 1inch failures become codes; anomalies are logged by reason and selector only", async () => {
  const noKey = fake({ env: { ONEINCH_API_KEY: "" } });
  assertEquals((await call(noKey, "quote", quoteBody())).body, { code: "unavailable" });
  assertEquals(noKey.gated.length, 0);
  const thrown = fake({
    upstream: () => {
      throw new TypeError("redirect");
    },
  });
  assertEquals((await call(thrown, "quote", quoteBody())).body, { code: "upstream", retryable: true });
  const huge = fake({ upstream: () => new Response("x".repeat(300 * 1024)) });
  assertEquals((await call(huge, "quote", quoteBody())).body, { code: "unexpected_answer" });
  const keyed = fake({
    upstream: () =>
      new Response(JSON.stringify({ description: `insufficient liquidity ${KEY} ${WALLET}` }), { status: 400 }),
  });
  const failed = await call(keyed, "quote", quoteBody());
  assertEquals([failed.status, failed.body], [422, { code: "no_route" }]);
  assertEquals(JSON.stringify(failed.body).includes(KEY), false);
  const hostile = fake({
    upstream: () =>
      new Response(JSON.stringify({ dstAmount: "9", tx: { to: OTHER, from: WALLET, data: DATA, value: "0" } })),
  });
  assertEquals((await call(hostile, "swap", swapBody())).body, { code: "unexpected_answer" });
  for (const f of [keyed, hostile, thrown, huge, noKey]) {
    for (const line of f.logs) {
      assertEquals(
        line.includes(KEY) || line.includes(WALLET.slice(2)) || line.includes("2001:db8") ||
          line.includes(OTHER.slice(2)),
        false,
        line,
      );
    }
  }
  assert(
    hostile.logs.some((l) => l.startsWith("oneinch-proxy: anomaly to 0x07ed2379 swap TSLAx")),
    hostile.logs.join("|"),
  );
});

Deno.test("handler: a swap's from must be the session's wallet; a pair outside the list never reaches the gate", async () => {
  const f = fake();
  assertEquals((await call(f, "swap", swapBody({ from: OTHER }))).body, { code: "wallet_mismatch" });
  assertEquals((await call(f, "quote", quoteBody({ dst: STRANGER }))).body, { code: "pair_not_offered" });
  assertEquals(f.gated.length + f.fetched.length, 0);
  // The shipped list is empty: nothing at all is offered yet.
  const shipped = fake();
  shipped.deps.registry = parseRegistry(XSTOCKS);
  assertEquals((await call(shipped, "quote", quoteBody())).body, { code: "pair_not_offered" });
});
