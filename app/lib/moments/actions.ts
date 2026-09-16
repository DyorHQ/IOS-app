import { erc20Abi, parseEventLogs, toHex, type Address, type Hex } from "viem";
import { MomentsFactoryAbi } from "../moments-abi";
import { publicClient } from "../chain";
import { waitFor } from "../use-tx";
import type { Wallet } from "../wallet";
import { MOMENTS, USDC } from "./config";
import { buybackContract, collectContract, factoryContract, graduationContract, hookContract, vestingContract } from "./reads";

/* Write side: every call is simulated first so reverts surface as readable errors before the wallet opens.
   Collects pay USDC either through a Permit2 signature (one approval of Permit2 ever, then a signature per
   collect) or through a plain exact-amount approval of the collect contract. */

type OnSent = (hash: Hex) => void;
const MAX_UINT256 = (1n << 256n) - 1n;

export type PublishInput = {
  name: string;
  symbol: string;
  mediaURI: string;
  mediaHash: Hex;
  animationURI: string;
  place: string;
  date: number;
  price: bigint; // USDC units
  creatorAllocBps: number;
  collectWindow: number; // seconds
};

const randomSalt = (): Hex => toHex(crypto.getRandomValues(new Uint8Array(32)));
const randomNonce = (): bigint => BigInt(toHex(crypto.getRandomValues(new Uint8Array(32))));

async function ensureAllowance(wallet: Wallet, spender: Address, amount: bigint, onSent: OnSent) {
  const owner = wallet.account.address;
  const allowance = await publicClient.readContract({ address: USDC.address, abi: erc20Abi, functionName: "allowance", args: [owner, spender] });
  if (allowance >= amount) return;
  const { request } = await publicClient.simulateContract({ address: USDC.address, abi: erc20Abi, functionName: "approve", args: [spender, amount], account: wallet.account });
  const hash = await wallet.writeContract(request);
  onSent(hash);
  await waitFor(hash);
}

export async function publish(wallet: Wallet, input: PublishInput, onSent: OnSent) {
  const params = {
    name: input.name,
    symbol: input.symbol,
    provenance: { mediaURI: input.mediaURI, mediaHash: input.mediaHash, place: input.place, date: BigInt(input.date), animationURI: input.animationURI },
    price: input.price,
    creatorAllocBps: input.creatorAllocBps,
    collectWindow: input.collectWindow,
    salt: randomSalt(),
  };
  const { request } = await publicClient.simulateContract({ ...factoryContract, functionName: "publish", args: [params], account: wallet.account });
  const hash = await wallet.writeContract(request);
  onSent(hash);
  const receipt = await waitFor(hash);
  const [event] = parseEventLogs({ abi: MomentsFactoryAbi, eventName: "Published", logs: receipt.logs });
  return { hash, id: event?.args.momentId ?? null, coin: event?.args.coin ?? null, nft: event?.args.nft ?? null };
}

export type CollectMode = "permit2" | "approve";

/** Collects `quantity` editions paying `gross` USDC. Permit2 mode: Permit2 is approved once (unlimited, the
    canonical pattern) and each collect is a signature; approve mode: an exact approval of the collect contract. */
export async function collect(wallet: Wallet, momentId: bigint, quantity: number, gross: bigint, mode: CollectMode, onSent: OnSent) {
  const account = wallet.account;
  let hash: Hex;
  if (mode === "permit2") {
    await ensureAllowance(wallet, MOMENTS.permit2, gross > MAX_UINT256 / 2n ? gross : MAX_UINT256, onSent);
    const nonce = randomNonce();
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 30 * 60);
    const permit = { permitted: { token: USDC.address, amount: gross }, nonce, deadline };
    const signature = await wallet.signTypedData({
      account,
      domain: { name: "Permit2", chainId: publicClient.chain!.id, verifyingContract: MOMENTS.permit2 },
      types: {
        PermitTransferFrom: [
          { name: "permitted", type: "TokenPermissions" },
          { name: "spender", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
        TokenPermissions: [
          { name: "token", type: "address" },
          { name: "amount", type: "uint256" },
        ],
      },
      primaryType: "PermitTransferFrom",
      message: { permitted: permit.permitted, spender: MOMENTS.collect, nonce, deadline },
    });
    const { request } = await publicClient.simulateContract({ ...collectContract, functionName: "collectWithPermit2", args: [momentId, BigInt(quantity), permit, signature], account });
    hash = await wallet.writeContract(request);
  } else {
    await ensureAllowance(wallet, MOMENTS.collect, gross, onSent);
    const { request } = await publicClient.simulateContract({ ...collectContract, functionName: "collect", args: [momentId, BigInt(quantity)], account });
    hash = await wallet.writeContract(request);
  }
  onSent(hash);
  await waitFor(hash);
  return hash;
}

async function write(wallet: Wallet, request: Parameters<Wallet["writeContract"]>[0], onSent: OnSent) {
  const hash = await wallet.writeContract(request);
  onSent(hash);
  await waitFor(hash);
  return hash;
}

export async function claim(wallet: Wallet, momentId: bigint, onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ ...vestingContract, functionName: "claim", args: [momentId], account: wallet.account });
  return write(wallet, request, onSent);
}
export async function claimAll(wallet: Wallet, momentIds: bigint[], onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ ...vestingContract, functionName: "claimAll", args: [momentIds], account: wallet.account });
  return write(wallet, request, onSent);
}
export async function withdrawCreatorProceeds(wallet: Wallet, momentId: bigint, onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ ...collectContract, functionName: "withdrawCreator", args: [momentId], account: wallet.account });
  return write(wallet, request, onSent);
}
export async function withdrawPlatformProceeds(wallet: Wallet, momentId: bigint, onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ ...collectContract, functionName: "withdrawPlatform", args: [momentId], account: wallet.account });
  return write(wallet, request, onSent);
}
export async function withdrawTreasuryProceeds(wallet: Wallet, momentId: bigint, onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ ...collectContract, functionName: "withdrawTreasury", args: [momentId], account: wallet.account });
  return write(wallet, request, onSent);
}
export async function withdrawCreatorFees(wallet: Wallet, momentId: bigint, onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ ...hookContract, functionName: "withdrawCreator", args: [momentId], account: wallet.account });
  return write(wallet, request, onSent);
}
export async function withdrawPlatformFees(wallet: Wallet, momentId: bigint, onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ ...hookContract, functionName: "withdrawPlatform", args: [momentId], account: wallet.account });
  return write(wallet, request, onSent);
}
export async function retryGraduation(wallet: Wallet, momentId: bigint, onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ ...graduationContract, functionName: "graduate", args: [momentId], account: wallet.account });
  return write(wallet, request, onSent);
}
export async function expire(wallet: Wallet, momentId: bigint, onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ ...collectContract, functionName: "expire", args: [momentId], account: wallet.account });
  return write(wallet, request, onSent);
}
export async function runBuyback(wallet: Wallet, momentId: bigint, minCoinOut: bigint, onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ ...buybackContract, functionName: "execute", args: [momentId, minCoinOut], account: wallet.account });
  return write(wallet, request, onSent);
}
