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
console.log(`factory ${ordered.factory}`);
