// oneinch-proxy: the app's only route to the 1inch Swap API, for one kind of trade — a curated xStock (tokenized
// stock) against USDC on Monad. It holds DyorHQ's 1inch key server-side (Supabase secret ONEINCH_API_KEY) so the key
// never ships inside the app, and answers three POST routes:
//   status  {mode, beta, termsVersion} for the session's wallet; never calls 1inch;
//   quote   an indicative price, {dstAmount}: what the Swap screen shows; it cannot be built into a transaction;
//   swap    a firm, issuer-signed RFQ, {dstAmount, tx: {to, from, data, value}}: fetched once, at Review.
// Only a signed-in DyorHQ wallet session qualifies, verified here (../_shared/wallet_session.ts) and not only by the
// gateway's verify_jwt (pinned in supabase/config.toml), as aurora-proxy does.
//
// Checks, in order (request.ts holds each rule):
//   1. POST, a known route, a body of at most 4 KiB;
//   2. the wallet session (401 without one, 403 for anything that is not one: code "session");
//   3. the body: a curated xStock against USDC, either way (422 pair_not_offered); an integer amount up to 2^256 − 1,
//      and for a swap an integer slippage up to 100 bps (400 bad_request) and `from` = the session's wallet (409
//      wallet_mismatch);
//   4. ONEINCH_MODE: "on" serves buys and sells, "sell-only" sells only, and unset or anything else is off (503
//      disabled). Sells never need the flag below: holders can always sell while the mode is on or sell-only;
//   5. ONEINCH_WALLETS, when set: only those wallets are served (503 disabled), and they hold the beta bit;
//   6. a buy by a wallet without the beta bit needs app_config's flags.xStocks to be JSON true (503 disabled);
//   7. ONEINCH_DENY (no buys) and ONEINCH_DENY_ALL (no trades) of a ticker or address (422 pair_not_offered);
//   8. the per-trade cap, $250: on what a buy pays, and on what a sell receives once 1inch answers (422 over_cap);
//   9. edge_rate_gate (migrations 27 and 34): scope "oneinch" for status and quote, "oneinch-firm" for swap (10 per
//      wallet per day); 429 rate_limited with retryAfter, or 503 busy when the gate fails or takes over 3 s;
//  10. 1inch, within 15 s, redirects refused, the answer capped at 256 KiB; an error becomes a code (request.ts
//      upstreamError), never 1inch's text; an answer that does not check out is 502 unexpected_answer.
// Only the quote route may answer from the isolate's 5-second cache; swap and status never do. No answer carries a
// time field: the app measures a firm quote's deadline on the device, from before it sends the request. Logs name
// routes, tickers and codes, never a wallet or an address of any kind.
//
// Deploy:  supabase functions deploy oneinch-proxy   (verify_jwt = true, supabase/config.toml)
//          Only after migration 34 is applied (after 27): without the oneinch scopes every call fails closed (503
//          busy). With ONEINCH_MODE unset the function serves nothing (disabled). Needs APP_JWT_SECRET (project-wide,
//          set for wallet-auth) to verify HS256 sessions.
import { createClient } from "npm:@supabase/supabase-js@2";
import { clientNet } from "../_shared/net.ts";
import { rateGate, type RateScope } from "../_shared/rate.ts";
import { type SessionKeys, sessionKeys, SessionKeysUnavailable, sessionWallet } from "../_shared/wallet_session.ts";
import { XSTOCKS } from "../_shared/xstocks.ts";
import {
  admit,
  FlagCache,
  flagFromConfig,
  gateCodes,
  isAnomaly,
  isRefusal,
  logExcerpt,
  MAX_BODY,
  MAX_UPSTREAM_BODY,
  parseList,
  parseMode,
  parseRegistry,
  parseTrade,
  QuoteCache,
  rebuildQuote,
  rebuildSwap,
  type Refusal,
  type Registry,
  ROUTES,
  sellCap,
  type Switches,
  TERMS_VERSION,
  upstreamError,
  upstreamURL,
  walletMode,
} from "./request.ts";

export const UPSTREAM_TIMEOUT_MS = 15_000;
export const GATE_TIMEOUT_MS = 3_000;
export const FLAG_TIMEOUT_MS = 3_000;

export type Deps = {
  env: { get(name: string): string | undefined };
  keys: SessionKeys;
  registry: Registry;
  // 1inch. Called only with a URL built by request.ts, the key in the Authorization header.
  fetch: (url: URL, init: RequestInit) => Promise<Response>;
  // edge_rate_gate: null to proceed, else its refusal (../_shared/rate.ts).
  gate: (scope: RateScope, wallet: string, net: string | null) => Promise<Response | null>;
  // app_config's 'ios' value; throws when it cannot be read.
  readConfig: () => Promise<unknown>;
  flags: FlagCache;
  quotes: QuoteCache;
  now: () => number;
  log: (...parts: unknown[]) => void;
  // Tests shorten the gate's and the flag read's deadlines; the deployed function uses the constants above.
  timeoutsMs?: { gate: number; flag: number };
};

const headers = (extra: Record<string, string> = {}) => ({
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
  ...extra,
});

function json(body: unknown, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), { status, headers: headers(extra) });
}

const reply = (refusal: Refusal, extra: Record<string, string> = {}) => json(refusal.body, refusal.status, extra);

// Settles with `promise`'s value, or with `fallback` once `ms` have passed (the promise is then left to settle alone).
async function within<T, F>(promise: Promise<T>, ms: number, fallback: F): Promise<T | F> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<F>((resolve) => {
        timer = setTimeout(() => resolve(fallback), ms);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

// The body as text, or null when it is longer than `max` bytes (read no further than that).
async function readCapped(body: ReadableStream<Uint8Array> | null, max: number): Promise<string | null> {
  if (!body) return "";
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > max) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const chunk of chunks) {
    all.set(chunk, at);
    at += chunk.byteLength;
  }
  return new TextDecoder().decode(all);
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== "POST") return json({ code: "method" }, 405, { Allow: "POST" });
  // The runtime path is /oneinch-proxy/<route> (or /functions/v1/oneinch-proxy/<route> behind the gateway).
  const route = new URL(req.url).pathname.replace(/^.*\/oneinch-proxy\/?/, "").replace(/\/+$/, "");
  if (!ROUTES.has(route)) return json({ code: "route" }, 404);

  const authorization = req.headers.get("authorization");
  let wallet: string | null;
  try {
    wallet = await sessionWallet(authorization, deps.keys);
  } catch (err) {
    if (!(err instanceof SessionKeysUnavailable)) throw err;
    deps.log("oneinch-proxy: session keys unavailable");
    return json({ code: "unavailable" }, 503);
  }
  if (!wallet) return json({ code: "session" }, (authorization ?? "").trim() === "" ? 401 : 403);

  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY) return json({ code: "too_large" }, 413);
  const raw = await readCapped(req.body, MAX_BODY);
  if (raw === null) return json({ code: "too_large" }, 413);

  const parsedMode = parseMode(deps.env.get("ONEINCH_MODE"));
  if (!parsedMode.valid) deps.log("oneinch-proxy: ONEINCH_MODE is not on, sell-only or off; serving nothing");
  const switches: Switches = {
    mode: parsedMode.mode,
    wallets: parseList(deps.env.get("ONEINCH_WALLETS")),
    deny: parseList(deps.env.get("ONEINCH_DENY")),
    denyAll: parseList(deps.env.get("ONEINCH_DENY_ALL")),
  };

  const passGate = async (scope: RateScope): Promise<Response | null> => {
    const refused = await within(
      deps.gate(scope, wallet!, clientNet(req, 48)).catch(() => "failed" as const),
      deps.timeoutsMs?.gate ?? GATE_TIMEOUT_MS,
      "timeout" as const,
    );
    if (refused === null) return null;
    if (refused === "failed" || refused === "timeout") {
      deps.log("oneinch-proxy: rate gate", refused, scope);
      return reply({ status: 503, body: { code: "busy", retryable: true } });
    }
    const coded = await gateCodes(refused);
    return reply(coded, coded.retryAfter ? { "Retry-After": String(coded.retryAfter) } : {});
  };

  if (route === "status") {
    const refused = await passGate("oneinch");
    if (refused) return refused;
    const { mode, beta } = walletMode(switches, wallet);
    return json({ mode, beta, termsVersion: TERMS_VERSION });
  }

  const trade = parseTrade(raw, route as "quote" | "swap", wallet, deps.registry);
  if (isRefusal(trade)) return reply(trade);

  const flagOn = () =>
    deps.flags.current(async () => {
      const value = await within(
        deps.readConfig().then((v) => ({ v })),
        deps.timeoutsMs?.flag ?? FLAG_TIMEOUT_MS,
        null,
      );
      if (!value) throw new Error("app_config read timed out");
      return flagFromConfig(value.v);
    }, deps.now()).catch(() => null);
  const refusal = await admit(trade, switches, wallet, flagOn);
  if (refusal) return reply(refusal);

  const key = deps.env.get("ONEINCH_API_KEY");
  if (!key) {
    deps.log("oneinch-proxy: ONEINCH_API_KEY is not set");
    return json({ code: "unavailable" }, 503);
  }

  const refused = await passGate(trade.route === "swap" ? "oneinch-firm" : "oneinch");
  if (refused) return refused;

  const cacheKey = QuoteCache.key(trade);
  if (trade.route === "quote") {
    const cached = deps.quotes.get(cacheKey, deps.now());
    if (cached) {
      const capped = sellCap(trade, cached);
      return capped ? reply(capped) : json({ dstAmount: cached });
    }
  }

  let upstream: Response;
  let text: string | null;
  try {
    upstream = await deps.fetch(upstreamURL(trade, wallet), {
      method: "GET",
      headers: { Authorization: `Bearer ${key}`, Accept: "application/json" },
      redirect: "error",
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    text = await readCapped(upstream.body, MAX_UPSTREAM_BODY);
  } catch {
    deps.log("oneinch-proxy: 1inch did not answer", trade.route, trade.stock.symbol);
    return json({ code: "upstream", retryable: true }, 502);
  }
  if (text === null) {
    deps.log("oneinch-proxy: anomaly oversize -", trade.route, trade.stock.symbol);
    return json({ code: "unexpected_answer" }, 502);
  }
  if (!upstream.ok) {
    const failure = upstreamError(upstream.status, text);
    deps.log(
      "oneinch-proxy: upstream",
      upstream.status,
      trade.route,
      trade.stock.symbol,
      failure.body.code,
      logExcerpt(text, key),
    );
    return reply(failure);
  }

  const answer = trade.route === "swap" ? rebuildSwap(text, wallet) : rebuildQuote(text);
  if (isAnomaly(answer)) {
    deps.log("oneinch-proxy: anomaly", answer.anomaly, answer.selector, trade.route, trade.stock.symbol);
    return json({ code: "unexpected_answer" }, 502);
  }
  const capped = sellCap(trade, answer.dstAmount);
  if (capped) return reply(capped);
  if (trade.route === "quote") deps.quotes.set(cacheKey, answer.dstAmount, deps.now());
  return json(answer);
}

// The deployed function's dependencies. Secrets are read on every request (deps.env), so a change of mode, list or
// key takes effect without a redeploy; the session keys, the curated list and the caches live for the isolate.
export function liveDeps(): Deps {
  const env = Deno.env;
  const db = () => {
    const url = env.get("SUPABASE_URL"), serviceKey = env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) throw new Error("SUPABASE_URL or the service-role key is not set");
    return createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  };
  let registry: Registry;
  try {
    registry = parseRegistry(XSTOCKS);
  } catch (err) {
    console.error("oneinch-proxy:", (err as Error).message, "— serving no pair");
    registry = { usdc: "", stocks: new Map() };
  }
  return {
    env,
    keys: sessionKeys(env),
    registry,
    fetch: (url, init) => fetch(url, init),
    gate: async (scope, wallet, net) => {
      let client;
      try {
        client = db();
      } catch {
        return new Response(null, { status: 503 });
      }
      return await rateGate(client, scope, wallet, net, {});
    },
    readConfig: async () => {
      const { data, error } = await db().from("app_config").select("value").eq("key", "ios").maybeSingle();
      if (error) throw new Error("app_config could not be read");
      return (data as { value?: unknown } | null)?.value ?? null;
    },
    flags: new FlagCache(),
    quotes: new QuoteCache(),
    now: () => Date.now(),
    log: (...parts) => console.error(...parts),
  };
}

if (import.meta.main) {
  const deps = liveDeps();
  Deno.serve((req) => handler(req, deps));
}
