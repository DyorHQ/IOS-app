// Seeds a LOCAL anvil fork (anvil --fork-url https://rpc.monad.xyz) with launches so the UI can be exercised.
// Usage: node scripts/dev/seed-fork.mjs contracts/deployments/143.json   (after deploying to the fork; local RPC only)
import { createPublicClient, createWalletClient, http, parseEther, parseEventLogs, formatEther, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";

const RPC = "http://127.0.0.1:8545";
if (!RPC.includes("127.0.0.1")) throw new Error("seed script is for the local fork only");
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const abi = (name) => JSON.parse(readFileSync(`${root}/contracts/out/${name}.sol/${name}.json`, "utf8")).abi;
const dep = JSON.parse(readFileSync(process.argv[2], "utf8"));
const chain = { id: 143, name: "Monad fork", nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC) });
const keys = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", // anvil #0 (owner)
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // anvil #1
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", // anvil #2
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", // anvil #3
];
const wallets = keys.map((k) => createWalletClient({ account: privateKeyToAccount(k), chain, transport: http(RPC) }));
const factory = { address: dep.factory, abi: abi("LaunchpadFactory") };
const router = { address: dep.launchAndBuyRouter, abi: abi("LaunchAndBuyRouter") };
const curveAbi = abi("BondingCurve");
const fee = await pub.readContract({ ...factory, functionName: "launchFee" });
const economics = await pub.readContract({ ...factory, functionName: "previewLaunchEconomics", args: [0n, "0x0000000000000000000000000000000000000000"] });
const rnd = () => toHex(crypto.getRandomValues(new Uint8Array(32)));
const params = (o) => ({ name: o.name, symbol: o.symbol, logo: o.logo ?? "", description: o.description ?? "", socials: { twitter: o.twitter ?? "", telegram: "", discord: "", website: "", farcaster: "" }, creatorFeeRecipient: o.creator, creatorTaxBps: o.tax ?? 0, holderFeeSharing: o.sharing ?? true, expectedEconomics: economics, salt: rnd() });
async function send(wallet, req) {
  const { request } = await pub.simulateContract({ ...req, account: wallet.account });
  const hash = await wallet.writeContract(request);
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("reverted " + hash);
  return receipt;
}
async function launch(wallet, o, devBuy = 0n) {
  const receipt = devBuy > 0n
    ? await send(wallet, { ...router, functionName: "launchAndBuy", args: [params(o), 0n, "0x0000000000000000000000000000000000000000", devBuy, 0n, wallet.account.address, []], value: fee + devBuy })
    : await send(wallet, { ...factory, functionName: "launchToken", args: [params(o), 0n, "0x0000000000000000000000000000000000000000", []], value: fee });
  const [ev] = parseEventLogs({ abi: factory.abi, eventName: "TokenLaunched", logs: receipt.logs });
  console.log(`launched ${o.symbol} token=${ev.args.token} curve=${ev.args.curve}`);
  return ev.args;
}
const buy = (wallet, curve, amount) => send(wallet, { address: curve, abi: curveAbi, functionName: "buy", args: [amount, 0n, wallet.account.address], value: amount });

// 1. A launch with a developer buy and holder fee sharing.
const a = await launch(wallets[1], { name: "Jensen's Jacket", symbol: "JENSEN", description: "Blackwell demand keeps surprising. A meme for everyone betting on the AI supercycle.", logo: "https://upload.wikimedia.org/wikipedia/commons/thumb/2/21/Nvidia_logo.svg/512px-Nvidia_logo.svg.png", twitter: "https://x.com/nvidia", creator: wallets[1].account.address }, parseEther("25"));
await pub.request({ method: "evm_increaseTime", params: [10] }); await pub.request({ method: "evm_mine", params: [] });
await buy(wallets[2], a.curve, parseEther("1500"));
await buy(wallets[3], a.curve, parseEther("2200"));
// 2. A creator-tax launch without sharing and without a dev buy.
const b = await launch(wallets[2], { name: "Purple Lambo", symbol: "PURPLE", description: "The fastest chain deserves the fastest car. Fair launch, no team allocation.", creator: wallets[2].account.address, tax: 200, sharing: false });
await pub.request({ method: "evm_increaseTime", params: [10] }); await pub.request({ method: "evm_mine", params: [] });
await buy(wallets[3], b.curve, parseEther("400"));
// 3. A launch that graduates into the real (forked) Uniswap v4 PoolManager.
const c = await launch(wallets[3], { name: "Monad Maxi", symbol: "MAXI", description: "Graduated on day one. Liquidity locked in Uniswap v4 forever.", creator: wallets[3].account.address });
await pub.request({ method: "evm_increaseTime", params: [10] }); await pub.request({ method: "evm_mine", params: [] });
await pub.request({ method: "anvil_setBalance", params: [wallets[1].account.address, toHex(parseEther("50000"))] });
await buy(wallets[1], c.curve, parseEther("9000"));
await buy(wallets[2], c.curve, parseEther("8000"));
const rec = await pub.readContract({ ...factory, functionName: "getLaunchedToken", args: [c.token] });
console.log(`MAXI phase=${rec.phase} poolId=${rec.poolId} sweptQuote=${formatEther(rec.sweptQuote)} MON`);
console.log(JSON.stringify({ JENSEN: a.token, PURPLE: b.token, MAXI: c.token }));
