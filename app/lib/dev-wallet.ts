"use client";

import { createWalletClient, http, type EIP1193Provider, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { CHAIN_HEX, RPC_URL, chain } from "./chain";

/* DEVELOPMENT ONLY. When NEXT_PUBLIC_DEV_WALLET_KEY is set at build/dev time (an anvil throwaway key against a
   local fork), this announces an EIP-6963 wallet backed by that key so the UI can be exercised end to end in a
   browser without an extension. It is never configured for production builds; without the variable the module
   does nothing. */

function devKey(): Hex | undefined {
  try {
    const v = process.env.NEXT_PUBLIC_DEV_WALLET_KEY;
    return typeof v === "string" && /^0x[0-9a-fA-F]{64}$/.test(v) ? (v as Hex) : undefined;
  } catch {
    return undefined;
  }
}

function announce(key: Hex) {
  if (typeof window === "undefined") return;
  const account = privateKeyToAccount(key);
  const client = createWalletClient({ account, chain, transport: http(RPC_URL) });
  const listeners = new Map<string, Set<(...args: unknown[]) => void>>();
  const provider = {
    request: async ({ method, params }: { method: string; params?: unknown[] }) => {
      switch (method) {
        case "eth_requestAccounts":
        case "eth_accounts":
          return [account.address];
        case "eth_chainId":
          return CHAIN_HEX;
        case "wallet_switchEthereumChain":
        case "wallet_addEthereumChain":
          return null;
        case "eth_sendTransaction": {
          const tx = (params?.[0] ?? {}) as { to?: Hex; data?: Hex; value?: Hex; gas?: Hex };
          return client.sendTransaction({ to: tx.to, data: tx.data, value: tx.value ? BigInt(tx.value) : undefined, gas: tx.gas ? BigInt(tx.gas) : undefined });
        }
        case "eth_signTypedData_v4": {
          const typed = JSON.parse(String(params?.[1]));
          return account.signTypedData({ domain: typed.domain, types: typed.types, primaryType: typed.primaryType, message: typed.message });
        }
        case "personal_sign":
          return account.signMessage({ message: { raw: params?.[0] as Hex } });
        default:
          return client.request({ method, params } as never);
      }
    },
    on: (event: string, listener: (...args: unknown[]) => void) => {
      if (!listeners.has(event)) listeners.set(event, new Set());
      listeners.get(event)!.add(listener);
    },
    removeListener: (event: string, listener: (...args: unknown[]) => void) => {
      listeners.get(event)?.delete(listener);
    },
  } as unknown as EIP1193Provider;
  const info = { uuid: "dev-wallet-anvil", name: "Anvil dev wallet (local fork)", icon: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%23ffaa00'/%3E%3C/svg%3E", rdns: "dev.anvil.local" };
  const detail = Object.freeze({ info, provider });
  const respond = () => window.dispatchEvent(new CustomEvent("eip6963:announceProvider", { detail }));
  window.addEventListener("eip6963:requestProvider", respond);
  respond();
}

const key = devKey();
if (key) announce(key);
