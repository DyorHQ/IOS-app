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
  assert.match(html, /Sample data, no real transactions/);
  assert.doesNotMatch(html, /Your site is taking shape|codex-preview/);
});
