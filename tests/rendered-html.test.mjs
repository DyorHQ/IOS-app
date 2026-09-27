import assert from "node:assert/strict";
import test from "node:test";

test("DyorHQ serves the screen playground from the production Worker", async () => {
  const { default: worker } = await import("../dist/server/index.js");
  const response = await worker.fetch(new Request("https://mainstreet-ui.bushy-petal-0744.chatgpt.site/"), {
    ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) },
  }, { waitUntil() {}, passThroughOnException() {} });
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /DyorHQ/);
  assert.match(html, /The RWA HQ for social trading/);
  assert.match(html, /Preview screens/);
  assert.match(html, /Live on Monad/);
  assert.doesNotMatch(html, /Your site is taking shape|codex-preview/);
});

test("share metadata points at the serving origin and describes what the app does", async () => {
  const { default: worker } = await import("../dist/server/index.js");
  // A client-sent forwarding header is replaced by the Worker with the host the request really came in on.
  const response = await worker.fetch(new Request("https://app.example.test/", { headers: { "x-forwarded-host": "evil.example" } }), {
    ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) },
  }, { waitUntil() {}, passThroughOnException() {} });
  const html = await response.text();
  assert.match(html, /<meta property="og:image" content="https:\/\/app\.example\.test\/brand\/dyorhq-monogram\.png"/);
  assert.match(html, /<meta property="og:url" content="https:\/\/app\.example\.test\/?"/);
  assert.doesNotMatch(html, /evil\.example/);
  assert.match(html, /<meta name="twitter:image" content="https:\/\/app\.example\.test\/brand\/dyorhq-monogram\.png"/);
  const description = html.match(/<meta name="description" content="([^"]*)"/)?.[1] ?? "";
  assert.match(description, /Moments/);
  assert.doesNotMatch(description, /copying|copy trad|stock-backed/i, "features the product does not have");
});
