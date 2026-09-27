import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* app/lib/swap/tokens.ts tokenNamed: what a swap link (?in= / ?out=) or an in-app preset selects. A symbol names only a
   core token; launchpad tickers are not unique, so launches are named by address. */

const { CORE_TOKENS, tokenNamed } = await tsImport("../app/lib/swap/tokens.ts", import.meta.url);
const launch = (address, symbol) => ({ address, symbol, name: symbol, decimals: 18, logo: "", launchpad: true });
const ORIGINAL = launch("0x1000000000000000000000000000000000000001", "PEPE");
const IMPOSTOR = launch("0x1000000000000000000000000000000000000002", "PEPE"); // newer, so listed first
const FAKE_USDC = launch("0x1000000000000000000000000000000000000003", "USDC");
const LIST = [...CORE_TOKENS, IMPOSTOR, ORIGINAL, FAKE_USDC];
const USDC = CORE_TOKENS.find((t) => t.symbol === "USDC");

test("core tokens by symbol, in any case", () => {
  assert.equal(tokenNamed(LIST, "usdc"), USDC);
  assert.equal(tokenNamed(LIST, "MON"), CORE_TOKENS[0]);
  assert.equal(tokenNamed(LIST, "USDC"), USDC, "a launch that took a core ticker never wins");
});

test("a launch's ticker picks nothing; its address picks exactly it", () => {
  assert.equal(tokenNamed(LIST, "PEPE"), undefined, "two launches share the ticker");
  assert.equal(tokenNamed(LIST, ORIGINAL.address), ORIGINAL);
  assert.equal(tokenNamed(LIST, ORIGINAL.address.toUpperCase().replace("0X", "0x")), ORIGINAL);
  assert.equal(tokenNamed(LIST, IMPOSTOR.address), IMPOSTOR);
});

test("nothing named, nothing picked", () => {
  for (const raw of [null, undefined, "", "NOPE", "0x1000000000000000000000000000000000000009"]) assert.equal(tokenNamed(LIST, raw), undefined, String(raw));
});
