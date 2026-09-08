"use client";

import { useMemo, useSyncExternalStore } from "react";
import { createWalletClient, custom, getAddress, type Account, type Address, type Chain, type EIP1193Provider, type Transport, type WalletClient } from "viem";
import { CHAIN_HEX, CHAIN_ID, EXPLORER, RPC_URL, chain } from "./chain";

/* Wallet connection without a framework: EIP-6963 discovery for injected wallets, an EIP-1193 session, and a viem
   wallet client. State lives in a module store read through useSyncExternalStore so any component can use it. */

export type WalletInfo = { uuid: string; name: string; icon: string; rdns: string };
export type DiscoveredWallet = { info: WalletInfo; provider: EIP1193Provider };
export type Wallet = WalletClient<Transport, Chain, Account>;
type Snapshot = { wallets: DiscoveredWallet[]; account: Address | null; chainId: number | null; rdns: string | null; connecting: boolean; error: string | null; ready: boolean };

const STORAGE_KEY = "dyorhq-wallet";
const initial: Snapshot = { wallets: [], account: null, chainId: null, rdns: null, connecting: false, error: null, ready: false };
let snap: Snapshot = initial;
const listeners = new Set<() => void>();
let discovering = false;
let attached: DiscoveredWallet | null = null;

function update(patch: Partial<Snapshot>) {
  snap = { ...snap, ...patch };
  for (const listener of listeners) listener();
}
const getSnapshot = () => snap;
const getServerSnapshot = () => initial;
function subscribe(listener: () => void) {
  listeners.add(listener);
  startDiscovery();
  return () => {
    listeners.delete(listener);
  };
}

const onAccountsChanged = (accounts: readonly string[]) => {
  if (!accounts.length) disconnect();
  else update({ account: getAddress(accounts[0]) });
};
const onChainChanged = (id: string) => update({ chainId: Number(id) });
const onDisconnect = () => disconnect();

function attach(wallet: DiscoveredWallet) {
  detach();
  wallet.provider.on("accountsChanged", onAccountsChanged);
  wallet.provider.on("chainChanged", onChainChanged);
  wallet.provider.on("disconnect", onDisconnect);
  attached = wallet;
}
function detach() {
  if (!attached) return;
  attached.provider.removeListener("accountsChanged", onAccountsChanged);
  attached.provider.removeListener("chainChanged", onChainChanged);
  attached.provider.removeListener("disconnect", onDisconnect);
  attached = null;
}

function remember(rdns: string | null) {
  try {
    if (rdns) localStorage.setItem(STORAGE_KEY, rdns);
    else localStorage.removeItem(STORAGE_KEY);
  } catch {
    /* Private mode or blocked storage: the session simply is not remembered. */
  }
}
function remembered(): string | null {
  try {
    return localStorage.getItem(STORAGE_KEY);
  } catch {
    return null;
  }
}

async function session(wallet: DiscoveredWallet, method: "eth_accounts" | "eth_requestAccounts") {
  const accounts = await wallet.provider.request({ method });
  if (!accounts.length) return false;
  const chainId = await wallet.provider.request({ method: "eth_chainId" });
  attach(wallet);
  update({ account: getAddress(accounts[0]), chainId: Number(chainId), rdns: wallet.info.rdns, connecting: false, error: null });
  remember(wallet.info.rdns);
  return true;
}

async function maybeReconnect(wallet: DiscoveredWallet) {
  if (snap.account || remembered() !== wallet.info.rdns) return;
  try {
    await session(wallet, "eth_accounts");
  } catch {
    /* The wallet is locked or refused a silent reconnect; the user can connect manually. */
  }
}

function announce(wallet: DiscoveredWallet) {
  if (snap.wallets.some((w) => w.info.rdns === wallet.info.rdns)) return;
  update({ wallets: [...snap.wallets, wallet] });
  void maybeReconnect(wallet);
}

function startDiscovery() {
  if (discovering || typeof window === "undefined") return;
  discovering = true;
  window.addEventListener("eip6963:announceProvider", (event) => {
    const detail = (event as CustomEvent<{ info?: WalletInfo; provider?: EIP1193Provider }>).detail;
    if (!detail?.info?.rdns || !detail.provider) return;
    announce({ info: detail.info, provider: detail.provider });
  });
  window.dispatchEvent(new Event("eip6963:requestProvider"));
  setTimeout(() => {
    const legacy = (window as Window & { ethereum?: EIP1193Provider }).ethereum;
    if (snap.wallets.length === 0 && legacy) announce({ info: { uuid: "legacy", name: "Browser wallet", icon: "", rdns: "injected" }, provider: legacy });
    update({ ready: true });
  }, 300);
}

export async function connect(rdns: string) {
  const wallet = snap.wallets.find((w) => w.info.rdns === rdns);
  if (!wallet) return;
  update({ connecting: true, error: null });
  try {
    if (!(await session(wallet, "eth_requestAccounts"))) update({ connecting: false, error: "The wallet returned no account." });
  } catch (error) {
    update({ connecting: false, error: errorText(error) });
  }
}

export function disconnect() {
  detach();
  remember(null);
  update({ account: null, chainId: null, rdns: null, connecting: false, error: null });
}

/** Switches the wallet to Monad mainnet, adding the network first when the wallet does not know it. */
export async function switchToMonad() {
  const wallet = attached;
  if (!wallet) return;
  try {
    await wallet.provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: CHAIN_HEX }] });
  } catch (error) {
    const code = (error as { code?: number }).code;
    if (code === 4902 || /unrecognized|not added|does not exist|unknown chain/i.test(errorText(error))) {
      await wallet.provider.request({
        method: "wallet_addEthereumChain",
        params: [{ chainId: CHAIN_HEX, chainName: "Monad", nativeCurrency: chain.nativeCurrency, rpcUrls: [RPC_URL], blockExplorerUrls: [EXPLORER] }],
      });
    } else throw error;
  }
  const chainId = await wallet.provider.request({ method: "eth_chainId" });
  update({ chainId: Number(chainId) });
}

function errorText(error: unknown) {
  if (error && typeof error === "object" && "message" in error && typeof (error as { message: unknown }).message === "string") return (error as { message: string }).message;
  return String(error);
}

export function useWallet() {
  const state = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
  const active = state.wallets.find((w) => w.info.rdns === state.rdns) ?? null;
  const client = useMemo<Wallet | null>(
    () => (state.account && active ? createWalletClient({ account: state.account, chain, transport: custom(active.provider) }) : null),
    [state.account, active],
  );
  return { ...state, active, client, onMonad: state.chainId === CHAIN_ID, connect, disconnect, switchToMonad };
}
