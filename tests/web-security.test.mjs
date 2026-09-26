import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import test from "node:test";

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
  ]) assert.equal((await call(bad)).status, 404, bad);
  assert.equal((await call(path, { headers: { Origin: "https://evil.example" } })).status, 403);
  assert.deepEqual(upstreamCalls, [], "a refused path must not reach Perpl");
});

test("no third-party script is loaded into the wallet origin", () => {
  const assets = new URL("../dist/client/assets/", import.meta.url);
  const bundle = readdirSync(assets).filter((f) => f.endsWith(".js")).map((f) => readFileSync(new URL(f, assets), "utf8")).join("\n");
  assert.doesNotMatch(bundle, /tradingview\.com\/tv\.js|s3\.tradingview\.com/);
});
