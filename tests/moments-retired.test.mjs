import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

/* app/lib/moments-retired.json is the web app's list of retired Moments cohorts (their coins and pool hooks, which the
   swap never trades or routes through). It must agree with the deployment records and with the iOS app's table. */

const web = JSON.parse(readFileSync("app/lib/moments-retired.json", "utf8"));
const lower = (value) => String(value ?? "").toLowerCase();

test("each retired cohort's factory and hook match contracts/deployments", () => {
  assert.equal(web.chainId, 143);
  const byName = Object.fromEntries(web.cohorts.map((c) => [c.name, c]));
  for (const name of ["cohort1", "cohort2"]) {
    const record = JSON.parse(readFileSync(`contracts/deployments/moments-143-${name}.json`, "utf8"));
    assert.ok(byName[name], `${name} is missing`);
    assert.equal(lower(byName[name].factory), lower(record.factory), `${name} factory`);
    assert.equal(lower(byName[name].hook), lower(record.hook), `${name} hook`);
  }
  const live = JSON.parse(readFileSync("app/lib/moments-deployment.json", "utf8"));
  for (const c of web.cohorts) {
    assert.notEqual(lower(c.factory), lower(live.factory), "the live cohort must not be listed as retired");
    assert.notEqual(lower(c.hook), lower(live.hook), "the live hook must not be listed as retired");
  }
});

test("the retired coins match the iOS app's MomentsAddresses.retiredMainnetCoins", () => {
  const swift = readFileSync("ios/DyorKit/Sources/DyorKit/Services/Moments/MomentsModels.swift", "utf8");
  const table = swift.slice(swift.indexOf("retiredMainnetCoins: [Address: MomentKey] = ["), swift.indexOf("public static func isRetiredCoin"));
  const ios = [...table.matchAll(/Address\(literal: "(0x[0-9a-fA-F]{40})"\): MomentKey\(factory: Address\(literal: "(0x[0-9a-fA-F]{40})"\)/g)]
    .map(([, coin, factory]) => `${lower(coin)}@${lower(factory)}`).sort();
  const ours = web.cohorts.flatMap((c) => c.coins.map((coin) => `${lower(coin)}@${lower(c.factory)}`)).sort();
  assert.equal(ios.length, 5);
  assert.deepEqual(ours, ios);
});
