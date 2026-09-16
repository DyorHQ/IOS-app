// Copies the Moments addresses written by `forge script script/moments/Deploy.s.sol --broadcast` into the web app.
// Usage: node scripts/sync-moments-deployment.mjs [chainId]   (default 143 = Monad mainnet)
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const chainId = process.argv[2] ?? "143";
const source = join(root, "contracts", "deployments", `moments-${chainId}.json`);
const target = join(root, "app", "lib", "moments-deployment.json");
const required = ["chainId", "governance", "platform", "treasury", "poolManager", "usdc", "permit2", "factory", "vesting", "collect", "locker", "graduation", "buyback", "hook", "hookSalt", "thresholdUsdc", "minPriceUsdc", "lpFee", "expiryCreatorBps", "royaltyBps"];
const optional = ["deployBlock"];

const deployment = JSON.parse(readFileSync(source, "utf8"));
const missing = required.filter((key) => deployment[key] === undefined);
if (missing.length) throw new Error(`${source} is missing ${missing.join(", ")}`);
const ordered = Object.fromEntries([...required, ...optional.filter((k) => deployment[k] !== undefined)].map((key) => [key, deployment[key]]));
writeFileSync(target, JSON.stringify(ordered, null, 2) + "\n");
console.log(`wrote app/lib/moments-deployment.json from ${source}`);
console.log(`factory ${ordered.factory}`);
