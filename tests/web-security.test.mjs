import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* Security headers and the Perpl relay's limits, exercised on the production Worker in dist/. */
const ORIGIN = "https://mainstreet-ui.bushy-petal-0744.chatgpt.site";
const env = { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } };
const ctx = { waitUntil() {}, passThroughOnException() {} };
// Upstream calls are captured instead of reaching Perpl. Installed before the Worker loads: vinext keeps the fetch it
// finds at import time.
const realFetch = globalThis.fetch;
let upstreamCalls = [];
globalThis.fetch = async (input) => {
  upstreamCalls.push(String(input instanceof Request ? input.url : input));
  return new Response(JSON.stringify({ markets: [] }), { status: 200, headers: { "content-type": "text/html" } });
};
test.after(() => { globalThis.fetch = realFetch; });

const { default: worker } = await import("../dist/server/index.js");
const call = (pathname, init) => worker.fetch(new Request(`${ORIGIN}${pathname}`, init), env, ctx);

const SECURITY_HEADERS = {
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "x-frame-options": "DENY",
  "content-security-policy": "frame-ancestors 'none'",
  "permissions-policy": "camera=(), microphone=(), geolocation=()",
  "strict-transport-security": "max-age=63072000; includeSubDomains",
};
const assertSecured = (response) => {
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) assert.equal(response.headers.get(name), value, `${name} on ${response.url || "response"}`);
  assert.match(response.headers.get("content-security-policy-report-only") ?? "", /script-src 'self' 'nonce-[A-Za-z0-9+/]{22}=='/);
};

test("every Worker response carries the security headers", async () => {
  assertSecured(await call("/"));
  assertSecured(await call("/api/perpl/v1/pub/context"));
  assertSecured(await call("/api/perpl/v2/anything"));
  assertSecured(await call("/api/perpl/ws", { headers: { Upgrade: "websocket", Origin: "https://evil.example" } }));
});

test("static files get the same headers and keep the immutable asset cache rule", () => {
  const headers = readFileSync(new URL("../dist/client/_headers", import.meta.url), "utf8");
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) assert.ok(headers.toLowerCase().includes(`${name}: ${value.toLowerCase()}`), `_headers is missing ${name}`);
  assert.match(headers, /\/assets\/\*\n\s+Cache-Control: public, max-age=31536000, immutable/);
  const policy = headers.match(/Content-Security-Policy-Report-Only: (.*)/)?.[1] ?? "";
  for (const directive of ["script-src 'self';", "object-src 'none'", "base-uri 'none'", "frame-ancestors 'none'"]) assert.ok(policy.includes(directive), `static CSP is missing ${directive}`);
});

test("pages carry a report-only CSP: no third-party script, and a fresh nonce on every inline script", async () => {
  const first = await call("/");
  const policy = first.headers.get("content-security-policy-report-only");
  const nonce = policy.match(/'nonce-([^']+)'/)[1];
  const scriptSrc = policy.split("; ").find((d) => d.startsWith("script-src "));
  assert.equal(scriptSrc, `script-src 'self' 'nonce-${nonce}'`, "no host allowlist, no unsafe-inline, no unsafe-eval");
  for (const directive of ["object-src 'none'", "base-uri 'none'", "frame-ancestors 'none'", "frame-src 'none'", "form-action 'self'"]) assert.ok(policy.includes(directive), directive);
  const connect = policy.split("; ").find((d) => d.startsWith("connect-src ")).split(" ");
  for (const source of ["'self'", "wss://mainstreet-ui.bushy-petal-0744.chatgpt.site", "https://rpc.monad.xyz", "https://rpc1.monad.xyz", "https://ws.kuru.io"]) assert.ok(connect.includes(source), `connect-src ${source}`);

  const html = await first.text();
  const scripts = [...html.matchAll(/<script\b([^>]*)>/g)].map((m) => m[1]);
  assert.ok(scripts.length > 0);
  for (const attrs of scripts) assert.match(attrs, new RegExp(`nonce="${nonce.replace(/[+/=]/g, "\\$&")}"`), `script without the nonce: <script${attrs}>`);

  const again = (await call("/")).headers.get("content-security-policy-report-only");
  assert.notEqual(again.match(/'nonce-([^']+)'/)[1], nonce, "a new nonce per response");
  const forged = await call("/", { headers: { "content-security-policy": "script-src 'nonce-chosenbyclient'" } });
  assert.doesNotMatch(await forged.text(), /chosenbyclient/, "a client can't choose the nonce");
});

test("the Perpl REST relay serves only the market context, without the query string", async () => {
  upstreamCalls = [];
  const ok = await call("/api/perpl/v1/pub/context?target=https://evil.example", { headers: { "sec-fetch-site": "same-origin" } });
  assert.equal(ok.status, 200);
  assert.equal(ok.headers.get("content-type"), "application/json; charset=utf-8");
  assert.deepEqual(upstreamCalls, ["https://app.perpl.xyz/api/v1/pub/context"]);

  upstreamCalls = [];
  for (const pathname of ["/api/perpl/v1/pub/other", "/api/perpl/v1/market-data/candles", "/api/perpl/v1/pub", "/api/perpl/v1/pub/context/x", "/api/perpl/ws"]) {
    assert.equal((await call(pathname)).status, 404, pathname);
  }
  assert.deepEqual(upstreamCalls, [], "a refused path must not reach Perpl");
});

test("the Perpl REST relay refuses other sites and other methods", async () => {
  upstreamCalls = [];
  assert.equal((await call("/api/perpl/v1/pub/context", { headers: { Origin: "https://evil.example" } })).status, 403);
  assert.equal((await call("/api/perpl/v1/pub/context", { headers: { "sec-fetch-site": "cross-site" } })).status, 403);
  assert.equal((await call("/api/perpl/v1/pub/context", { headers: { "sec-fetch-site": "same-site" } })).status, 403);
  assert.equal((await call("/api/perpl/v1/pub/context", { method: "POST", body: "{}", headers: { Origin: ORIGIN } })).status, 405);
  assert.deepEqual(upstreamCalls, []);
  assert.equal((await call("/api/perpl/v1/pub/context", { headers: { Origin: ORIGIN } })).status, 200);
});

test("the Perpl WebSocket relay only opens for this app's own pages", async () => {
  upstreamCalls = [];
  assert.equal((await call("/api/perpl/ws", { headers: { Upgrade: "websocket" } })).status, 403, "no Origin");
  assert.equal((await call("/api/perpl/ws", { headers: { Upgrade: "websocket", Origin: "https://evil.example" } })).status, 403, "foreign Origin");
  assert.equal((await call("/api/perpl/ws", { method: "POST", body: "x", headers: { Upgrade: "websocket", Origin: ORIGIN } })).status, 405, "POST");
  assert.deepEqual(upstreamCalls, [], "a refused handshake must not dial Perpl");
});

test("the Perpl REST relay serves the charts' candle windows and nothing near them", async () => {
  const hour = 3_600_000;
  const to = Math.ceil(Date.now() / hour) * hour;
  const path = `/api/perpl/v1/market-data/10/candles/3600/${to - 150 * hour}-${to}`;
  upstreamCalls = [];
  const ok = await call(path, { headers: { "sec-fetch-site": "same-origin" } });
  assert.equal(ok.status, 200);
  assert.equal(ok.headers.get("content-type"), "application/json; charset=utf-8");
  assert.equal(ok.headers.get("cache-control"), "public, max-age=15");
  assert.deepEqual(upstreamCalls, [`https://app.perpl.xyz/api${path.slice("/api/perpl".length)}`]);

  upstreamCalls = [];
  for (const bad of [
    `/api/perpl/v1/market-data/99/candles/3600/${to - 150 * hour}-${to}`,
    `/api/perpl/v1/market-data/10/candles/3600/${to - 150 * hour + 1}-${to}`,
    `/api/perpl/v1/market-data/10/candles/3600/${to - 2000 * hour}-${to}`,
    `/api/perpl/v1/market-data/10/orders/3600/${to - 150 * hour}-${to}`,
    `/api/perpl/v1/market-data/10/candles/3600/${to - 149 * hour}-${to}`, // another window size
    `/api/perpl/v1/market-data/10/candles/3600/${to - 390 * hour}-${to - 240 * hour}`, // a historical window
    `/api/perpl/v1/market-data/10/candles/3600/${to + 90 * hour}-${to + 240 * hour}`, // a future window
  ]) assert.equal((await call(bad)).status, 404, bad);
  assert.equal((await call(path, { headers: { Origin: "https://evil.example" } })).status, 403);
  assert.deepEqual(upstreamCalls, [], "a refused path must not reach Perpl");
});

test("the relay answers repeat reads from the edge cache: many viewers, one upstream read", async () => {
  const hour = 3_600_000;
  const to = Math.ceil(Date.now() / hour) * hour;
  const path = `/api/perpl/v1/market-data/20/candles/3600/${to - 150 * hour}-${to}`;
  const stored = new Map();
  globalThis.caches = { default: { async match(key) { return stored.get(key.url)?.clone(); }, async put(key, response) { stored.set(key.url, response); } } };
  try {
    upstreamCalls = [];
    for (const query of ["", "?v=1", "?v=2"]) assert.equal((await call(`${path}${query}`, { headers: { "sec-fetch-site": "same-origin" } })).status, 200, query);
    assert.equal(upstreamCalls.length, 1, "one upstream read");
    assert.deepEqual([...stored.keys()], [`${ORIGIN}${path}`], "keyed on the validated route, never the query string");
    const hit = await call(path);
    assertSecured(hit);
    assert.equal(hit.headers.get("content-type"), "application/json; charset=utf-8");
    assert.equal(hit.headers.get("cache-control"), "public, max-age=15");
    assert.equal((await call(path, { headers: { Origin: "https://evil.example" } })).status, 403, "the cache does not bypass the site check");
    assert.equal(upstreamCalls.length, 1);
  } finally {
    delete globalThis.caches;
  }
});

test("one client's Perpl reads and socket opens are capped; other clients are not affected", async () => {
  const { PERPL_REQUESTS_PER_MINUTE, PERPL_SOCKET_OPENS_PER_MINUTE } = await tsImport("../worker/rate-limit.ts", import.meta.url);
  const from = (n, extra = {}) => ({ headers: { "cf-connecting-ip": `203.0.113.${n}`, "sec-fetch-site": "same-origin", ...extra } });
  let limitedAt = null;
  for (let i = 0; i <= PERPL_REQUESTS_PER_MINUTE && limitedAt === null; i++) if ((await call("/api/perpl/v1/pub/context", from(7))).status === 429) limitedAt = i;
  assert.equal(limitedAt, PERPL_REQUESTS_PER_MINUTE);
  upstreamCalls = [];
  const refused = await call("/api/perpl/v1/pub/context", from(7));
  assert.equal(refused.status, 429);
  assert.equal(refused.headers.get("retry-after"), "60");
  assertSecured(refused);
  assert.deepEqual(upstreamCalls, [], "a refused read does not reach Perpl");
  assert.equal((await call("/api/perpl/v1/pub/context", from(8))).status, 200, "another client");
  assert.equal((await call("/api/perpl/v1/pub/context", { headers: { "sec-fetch-site": "same-origin" } })).status, 200, "no client IP: not counted");

  // Each dial here fails upstream (there is no Perpl in the test) and frees its slot, so the opens cap is what trips.
  const socket = (n) => call("/api/perpl/ws", from(n, { Upgrade: "websocket", Origin: ORIGIN }));
  let opensLimitedAt = null;
  for (let i = 0; i <= PERPL_SOCKET_OPENS_PER_MINUTE && opensLimitedAt === null; i++) if ((await socket(9)).status === 429) opensLimitedAt = i;
  assert.equal(opensLimitedAt, PERPL_SOCKET_OPENS_PER_MINUTE);
  assert.equal((await socket(10)).status, 502, "another client still reaches the dial");
});

test("no third-party script is loaded into the wallet origin", () => {
  const assets = new URL("../dist/client/assets/", import.meta.url);
  const bundle = readdirSync(assets).filter((f) => f.endsWith(".js")).map((f) => readFileSync(new URL(f, assets), "utf8")).join("\n");
  assert.doesNotMatch(bundle, /tradingview\.com\/tv\.js|s3\.tradingview\.com/);
});
