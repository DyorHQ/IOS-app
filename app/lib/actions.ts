import { erc20Abi, parseEventLogs, toHex, type Address, type Hex } from "viem";
import { BondingCurveAbi, FeeEscrowAbi, HolderFeeSharingAbi, LaunchAndBuyRouterAbi, LaunchpadFactoryAbi, MemeHookAbi } from "./abi";
import { ADDRESSES, publicClient } from "./chain";
import { factoryContract, type Socials } from "./launchpad";
import { waitFor } from "./use-tx";
import type { Wallet } from "./wallet";

/* Write side: every call is simulated first so reverts surface as readable errors before the wallet opens. */

type OnSent = (hash: Hex) => void;

export type LaunchInput = {
  name: string;
  symbol: string;
  logo: string;
  description: string;
  socials: Socials;
  creatorFeeRecipient: Address;
  creatorTaxBps: number;
  holderFeeSharing: boolean;
  /** 0 = Uniswap v4 (default), 1 = Monday Trade. Forced to 1 for Monday-only (aBIL) pairs. */
  graduationVenue: number;
  pairToken: Address;
  pairNative: boolean;
  configId: bigint;
  exemptions: Address[];
  launchFee: bigint;
  devBuy: bigint;
  minTokensOut: bigint;
};

const randomSalt = (): Hex => toHex(crypto.getRandomValues(new Uint8Array(32)));

async function ensureAllowance(wallet: Wallet, token: Address, spender: Address, amount: bigint, onSent: OnSent) {
  const owner = wallet.account.address;
  const allowance = await publicClient.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [owner, spender] });
  if (allowance >= amount) return;
  const { request } = await publicClient.simulateContract({ address: token, abi: erc20Abi, functionName: "approve", args: [spender, amount], account: wallet.account });
  const hash = await wallet.writeContract(request);
  onSent(hash);
  await waitFor(hash);
}

export async function launch(wallet: Wallet, input: LaunchInput, onSent: OnSent) {
  const account = wallet.account;
  const expectedEconomics = await publicClient.readContract({ ...factoryContract, functionName: "previewLaunchEconomics", args: [input.configId, input.pairToken] });
  const params = {
    name: input.name,
    symbol: input.symbol,
    logo: input.logo,
    description: input.description,
    socials: input.socials,
    creatorFeeRecipient: input.creatorFeeRecipient,
    creatorTaxBps: input.creatorTaxBps,
    holderFeeSharing: input.holderFeeSharing,
    graduationVenue: input.graduationVenue,
    expectedEconomics,
    salt: randomSalt(),
  };
  let hash: Hex;
  if (input.devBuy > 0n) {
    if (!input.pairNative) await ensureAllowance(wallet, input.pairToken, ADDRESSES.router, input.devBuy, onSent);
    const { request } = await publicClient.simulateContract({
      address: ADDRESSES.router,
      abi: LaunchAndBuyRouterAbi,
      functionName: "launchAndBuy",
      args: [params, input.configId, input.pairToken, input.devBuy, input.minTokensOut, account.address, input.exemptions],
      value: input.pairNative ? input.launchFee + input.devBuy : input.launchFee,
      account,
    });
    hash = await wallet.writeContract(request);
  } else {
    const { request } = await publicClient.simulateContract({
      ...factoryContract,
      functionName: "launchToken",
      args: [params, input.configId, input.pairToken, input.exemptions],
      value: input.launchFee,
      account,
    });
    hash = await wallet.writeContract(request);
  }
  onSent(hash);
  const receipt = await waitFor(hash);
  const [event] = parseEventLogs({ abi: LaunchpadFactoryAbi, eventName: "TokenLaunched", logs: receipt.logs });
  return { hash, token: event?.args.token ?? null, curve: event?.args.curve ?? null };
}

export async function buy(wallet: Wallet, curve: Address, pairToken: Address, pairNative: boolean, quoteIn: bigint, minTokensOut: bigint, onSent: OnSent) {
  if (!pairNative) await ensureAllowance(wallet, pairToken, curve, quoteIn, onSent);
  const { request } = await publicClient.simulateContract({
    address: curve,
    abi: BondingCurveAbi,
    functionName: "buy",
    args: [quoteIn, minTokensOut, wallet.account.address],
    value: pairNative ? quoteIn : 0n,
    account: wallet.account,
  });
  const hash = await wallet.writeContract(request);
  onSent(hash);
  await waitFor(hash);
  return hash;
}

export async function sell(wallet: Wallet, token: Address, curve: Address, tokensIn: bigint, minQuoteOut: bigint, onSent: OnSent) {
  await ensureAllowance(wallet, token, curve, tokensIn, onSent);
  const { request } = await publicClient.simulateContract({
    address: curve,
    abi: BondingCurveAbi,
    functionName: "sell",
    args: [tokensIn, minQuoteOut, wallet.account.address],
    account: wallet.account,
  });
  const hash = await wallet.writeContract(request);
  onSent(hash);
  await waitFor(hash);
  return hash;
}

export async function claimHolderRewards(wallet: Wallet, token: Address, onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ address: ADDRESSES.holderFeeSharing, abi: HolderFeeSharingAbi, functionName: "claim", args: [token], account: wallet.account });
  const hash = await wallet.writeContract(request);
  onSent(hash);
  await waitFor(hash);
  return hash;
}

export async function claimEscrow(wallet: Wallet, pairToken: Address, pairNative: boolean, onSent: OnSent) {
  const escrow = { address: ADDRESSES.escrow, abi: FeeEscrowAbi } as const;
  let hash: Hex;
  if (pairNative) {
    const { request } = await publicClient.simulateContract({ ...escrow, functionName: "claim", account: wallet.account });
    hash = await wallet.writeContract(request);
  } else {
    const { request } = await publicClient.simulateContract({ ...escrow, functionName: "claimToken", args: [pairToken], account: wallet.account });
    hash = await wallet.writeContract(request);
  }
  onSent(hash);
  await waitFor(hash);
  return hash;
}

export async function retryGraduation(wallet: Wallet, token: Address, onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ ...factoryContract, functionName: "graduate", args: [token], account: wallet.account });
  const hash = await wallet.writeContract(request);
  onSent(hash);
  await waitFor(hash);
  return hash;
}

export async function sweepPoolFees(wallet: Wallet, poolId: Hex, currency: Address, onSent: OnSent) {
  const { request } = await publicClient.simulateContract({ address: ADDRESSES.hook, abi: MemeHookAbi, functionName: "sweepPoolFees", args: [poolId, currency], account: wallet.account });
  const hash = await wallet.writeContract(request);
  onSent(hash);
  await waitFor(hash);
  return hash;
}
