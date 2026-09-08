"use client";

import { useState } from "react";
import type { Hex } from "viem";
import { publicClient } from "./chain";
import { describeError } from "./errors";

export type TxState = { status: "idle" | "signing" | "pending" | "success" | "error"; label: string; hash?: Hex; message?: string };

/** Drives one transaction at a time: wallet signature, confirmation, then success or a readable error. The action
    receives an `onSent` callback so the pending state shows the hash before the receipt lands. */
export function useTx() {
  const [tx, setTx] = useState<TxState>({ status: "idle", label: "" });
  const run = async <T,>(label: string, action: (onSent: (hash: Hex) => void) => Promise<T>, onDone?: (result: T) => void) => {
    setTx({ status: "signing", label });
    try {
      const result = await action((hash) => setTx({ status: "pending", label, hash }));
      setTx((s) => ({ status: "success", label, hash: s.hash }));
      onDone?.(result);
      return result;
    } catch (error) {
      setTx((s) => ({ status: "error", label, hash: s.hash, message: describeError(error) }));
      return null;
    }
  };
  return { tx, run, reset: () => setTx({ status: "idle", label: "" }), busy: tx.status === "signing" || tx.status === "pending" };
}

export async function waitFor(hash: Hex) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("The transaction reverted on-chain.");
  return receipt;
}
