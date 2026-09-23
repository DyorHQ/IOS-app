import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

/* The web app's live launchpad must be the one contracts/deployments/143.json records, never a retired factory. */

const record = JSON.parse(readFileSync("contracts/deployments/143.json", "utf8"));
const web = JSON.parse(readFileSync("app/lib/deployment.json", "utf8"));
const RETIRED_FACTORIES = [
  "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7",
  "0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4",
  "0xad3d3Cb821279E52cFD499D15b26f77976eBA1Ea",
];
const lower = (value) => String(value ?? "").toLowerCase();

test("app/lib/deployment.json matches contracts/deployments/143.json", () => {
  assert.equal(web.chainId, 143);
  for (const key of ["factory", "launchAndBuyRouter", "escrow", "holderFeeSharing", "hook"]) {
    assert.match(web[key] ?? "", /^0x[0-9a-fA-F]{40}$/, `app/lib/deployment.json ${key}`);
    assert.equal(lower(web[key]), lower(record[key]), `${key} drifted from the deployment record`);
  }
});

test("the live factory is not a retired one", () => {
  for (const retired of RETIRED_FACTORIES) {
    assert.notEqual(lower(web.factory), lower(retired), "app/lib/deployment.json points at a retired factory");
    assert.notEqual(lower(record.factory), lower(retired), "contracts/deployments/143.json points at a retired factory");
  }
});

test("app/lib/chain.ts still serves every retired factory's launches", () => {
  const chain = readFileSync("app/lib/chain.ts", "utf8");
  const retiredBlock = chain.slice(chain.indexOf("export const RETIRED_STACKS"), chain.indexOf("export const LIVE_STACK"));
  for (const retired of RETIRED_FACTORIES) assert.match(retiredBlock, new RegExp(`factory: "${retired}"`, "i"), retired);
  assert.doesNotMatch(retiredBlock, new RegExp(web.factory, "i"), "the live factory is listed as retired");
});
