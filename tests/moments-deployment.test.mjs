import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

/* The web app's live Moments stack must be the one contracts/deployments/moments-143.json records (cohort 3), never a
   retired cohort: every Moment on those snapshotted the retired platform wallet and the treasury whose key leaked, so
   a Collect there pays them. */

const record = JSON.parse(readFileSync("contracts/deployments/moments-143.json", "utf8"));
const web = JSON.parse(readFileSync("app/lib/moments-deployment.json", "utf8"));
const RETIRED_FACTORIES = [
  "0x64698c7702d85F87f43a6dFF7D495CDD2327C020", // cohort 1
  "0xc12B6b6948185cef75F861c5327702c30CB8a581", // cohort 2
];
const LEAKED_TREASURY = "0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045";
const lower = (value) => String(value ?? "").toLowerCase();

test("app/lib/moments-deployment.json matches contracts/deployments/moments-143.json", () => {
  assert.equal(web.chainId, 143);
  for (const key of ["factory", "collect", "vesting", "graduation", "locker", "hook", "buyback", "usdc", "permit2", "poolManager", "platform", "treasury"]) {
    assert.match(web[key] ?? "", /^0x[0-9a-fA-F]{40}$/, `app/lib/moments-deployment.json ${key}`);
    assert.equal(lower(web[key]), lower(record[key]), `${key} drifted from the deployment record`);
  }
});

test("the live Moments stack is not a retired cohort and never pays the leaked treasury", () => {
  for (const retired of RETIRED_FACTORIES) {
    assert.notEqual(lower(web.factory), lower(retired), "app/lib/moments-deployment.json points at a retired cohort");
    assert.notEqual(lower(record.factory), lower(retired), "contracts/deployments/moments-143.json points at a retired cohort");
  }
  assert.notEqual(lower(web.treasury), lower(LEAKED_TREASURY));
  assert.notEqual(lower(record.treasury), lower(LEAKED_TREASURY));
});

test("the web app uses the canonical Permit2", () => {
  assert.equal(lower(web.permit2), lower("0x000000000022D473030F116dDEE9F6B43aC78BA3"));
});
