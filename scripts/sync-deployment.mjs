// Copies the addresses written by `forge script script/Deploy.s.sol --broadcast` into the web app.
// Usage: node scripts/sync-deployment.mjs [chainId]   (default 143 = Monad mainnet)
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const chainId = process.argv[2] ?? "143";
const source = join(root, "contracts", "deployments", `${chainId}.json`);
const target = join(root, "app", "lib", "deployment.json");
const required = ["chainId", "owner", "poolManager", "factory", "escrow", "holderFeeSharing", "locker", "hook", "hookSalt", "graduationExecutor", "launchAndBuyRouter", "launchDeployer"];

const deployment = JSON.parse(readFileSync(source, "utf8"));
const missing = required.filter((key) => deployment[key] === undefined);
if (missing.length) throw new Error(`${source} is missing ${missing.join(", ")}`);
const ordered = Object.fromEntries(required.map((key) => [key, deployment[key]]));
writeFileSync(target, JSON.stringify(ordered, null, 2) + "\n");
console.log(`wrote app/lib/deployment.json from ${source}`);

// The iOS app ships the same deployment baked into DyorKit (LaunchpadAddresses.monadMainnet); rewrite that block so
// one command re-wires both apps. DyorKit's LaunchpadDeploymentTests fails if the two ever drift.
if (chainId === "143") {
  const swiftPath = join(root, "ios", "DyorKit", "Sources", "DyorKit", "Services", "Launchpad", "LaunchpadModels.swift");
  const swift = readFileSync(swiftPath, "utf8");
  const fields = { factory: "factory", router: "launchAndBuyRouter", escrow: "escrow", holderFeeSharing: "holderFeeSharing", hook: "hook" };
  const start = swift.indexOf("static let monadMainnet");
  const end = swift.indexOf("\n    )", start);
  if (start < 0 || end < 0) throw new Error("LaunchpadAddresses.monadMainnet block not found in LaunchpadModels.swift");
  let block = swift.slice(start, end);
  for (const [field, key] of Object.entries(fields)) {
    const re = new RegExp(`${field}: Address\\(literal: "0x[0-9a-fA-F]{40}"\\)`);
    if (!re.test(block)) throw new Error(`${field} not found in the monadMainnet block`);
    block = block.replace(re, `${field}: Address(literal: "${deployment[key]}")`);
  }
  writeFileSync(swiftPath, swift.slice(0, start) + block + swift.slice(end));
  console.log("wrote LaunchpadAddresses.monadMainnet in ios/DyorKit (LaunchpadModels.swift)");
}
console.log(`factory ${ordered.factory}`);
