// Seeds a LOCAL anvil fork of Monad mainnet (anvil --fork-url https://rpc.monad.xyz --chain-id 143) with Moments so
// the UI can be exercised: the v1.1 contracts already exist in the forked state. Anvil throwaway keys only.
// Usage: node scripts/dev/seed-moments-fork.mjs   (local RPC only)
import { createPublicClient, createWalletClient, encodeAbiParameters, http, keccak256, parseEventLogs, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const RPC = "http://127.0.0.1:8545";
if (!RPC.includes("127.0.0.1")) throw new Error("seed script is for the local fork only");
const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const abi = (name) => JSON.parse(readFileSync(`${root}/contracts/out/${name}.sol/${name}.json`, "utf8")).abi;
const dep = JSON.parse(readFileSync(`${root}/contracts/deployments/moments-143.json`, "utf8"));
const chain = { id: 143, name: "Monad fork", nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC) });
// Anvil's default accounts carry EIP-7702 delegation code on Monad mainnet (their keys are public), which makes
// ERC-721 safeMint revert for them on a fork. These are fresh throwaway keys: keccak256("dyorhq-moments-fork-wallet-N").
const keys = [
  "0x57bcbb515c0a9835560414863de2a2903e4f195eb93fa071b8d0557608ee952a", // wallet 1 (dev wallet in the preview) 0x1C4d85cF39eD9343F1cdc34ea890394Aa63D7Bd8
  "0x3470e801c46dde26c5827e7caa3e523b54f026eec2b2d0bbbae6ad2e98179270", // wallet 2 0x5829268041d941e4E5594590B8133AC0319773A5
  "0x130eadc747f9b9e2c55ec6772c90b96a89e3b2890fa0f66ebd35aba462e32dd5", // wallet 3 0x70d54A7e83E6f09312e4cc2eAc87440A109dc082
];
const wallets = keys.map((k) => createWalletClient({ account: privateKeyToAccount(k), chain, transport: http(RPC) }));
const factory = { address: dep.factory, abi: abi("MomentsFactory") };
const collect = { address: dep.collect, abi: abi("MomentCollect") };
const erc20 = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
];
const usdc = { address: dep.usdc, abi: erc20 };

async function send(wallet, req) {
  const { request } = await pub.simulateContract({ ...req, account: wallet.account });
  const hash = await wallet.writeContract(request);
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("reverted " + hash);
  return receipt;
}

/** Gives `who` USDC on the fork by finding the balances mapping slot (Circle's FiatToken keeps it at slot 9) and writing it. */
async function dealUsdc(who, amount) {
  for (let slot = 0n; slot < 40n; slot++) {
    const key = keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [who, slot]));
    const before = await pub.getStorageAt({ address: dep.usdc, slot: key });
    await pub.request({ method: "anvil_setStorageAt", params: [dep.usdc, key, toHex(amount, { size: 32 })] });
    const bal = await pub.readContract({ ...usdc, functionName: "balanceOf", args: [who] });
    if (bal === amount) return slot;
    await pub.request({ method: "anvil_setStorageAt", params: [dep.usdc, key, before ?? toHex(0n, { size: 32 })] });
  }
  throw new Error("USDC balance slot not found");
}

const rnd = () => toHex(crypto.getRandomValues(new Uint8Array(32)));
async function publish(wallet, o) {
  const params = {
    name: o.name,
    symbol: o.symbol,
    provenance: { mediaURI: o.media, mediaHash: keccak256(toHex(o.media)), place: o.place, date: BigInt(o.date), animationURI: o.animation ?? "" },
    price: o.price,
    creatorAllocBps: o.alloc ?? 1000,
    collectWindow: o.window ?? 30 * 86400,
    salt: rnd(),
  };
  const receipt = await send(wallet, { ...factory, functionName: "publish", args: [params] });
  const [ev] = parseEventLogs({ abi: factory.abi, eventName: "Published", logs: receipt.logs });
  console.log(`published #${ev.args.momentId} ${o.symbol} coin=${ev.args.coin} nft=${ev.args.nft}`);
  return ev.args;
}
async function collectN(wallet, id, n, price) {
  await send(wallet, { ...usdc, functionName: "approve", args: [dep.collect, price * BigInt(n) * 2n] });
  for (let i = 0; i < n; i++) {
    const state = await pub.readContract({ ...collect, functionName: "state", args: [id] });
    if (state !== 0) break;
    await send(wallet, { ...collect, functionName: "collect", args: [id, 1n] });
  }
}

for (const w of wallets) {
  await pub.request({ method: "anvil_setBalance", params: [w.account.address, toHex(10n ** 21n)] });
  const slot = await dealUsdc(w.account.address, 1_000_000_000n); // $1,000
  console.log(`${w.account.address} funded (USDC slot ${slot})`);
}

// 1. A Moment that graduates: 14 x $1 across two collectors (the 14th is the clamped terminal collect).
const a = await publish(wallets[0], { name: "Sunrise over Labadi", symbol: "LABADI", place: "Labadi Beach, Accra", date: 1_779_900_000, media: "https://picsum.photos/seed/labadi/960/720", price: 1_000_000n });
await collectN(wallets[1], a.momentId, 7, 1_000_000n);
await collectN(wallets[2], a.momentId, 7, 1_000_000n);
console.log(`#${a.momentId} state=${await pub.readContract({ ...collect, functionName: "state", args: [a.momentId] })} (2 = graduated)`);
// 2. A Moment still collecting at $0.50 with a 4% creator allocation.
const b = await publish(wallets[1], { name: "Osu night market", symbol: "OSU", place: "Oxford Street, Osu", date: 1_780_100_000, media: "https://picsum.photos/seed/osu/960/720", price: 500_000n, alloc: 400 });
await collectN(wallets[2], b.momentId, 3, 500_000n);
await collectN(wallets[0], b.momentId, 2, 500_000n);
// 3. A $10 Moment: one collect is 75% of the way; a single holder can graduate it (the containment case).
const c = await publish(wallets[2], { name: "Kakum canopy walk", symbol: "KAKUM", place: "Kakum National Park", date: 1_780_200_000, media: "https://picsum.photos/seed/kakum/960/720", price: 10_000_000n, alloc: 0, window: 7 * 86400 });
await collectN(wallets[0], c.momentId, 1, 10_000_000n);
console.log(JSON.stringify({ LABADI: a.momentId.toString(), OSU: b.momentId.toString(), KAKUM: c.momentId.toString(), devWallet: wallets[0].account.address }));
