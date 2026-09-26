"use client";

import { useRef, useState, type SetStateAction } from "react";
import type { Hex } from "viem";
import { publicClient } from "./chain";
import { describeError } from "./errors";

export type TxState = { status: "idle" | "signing" | "pending" | "unconfirmed" | "success" | "error"; label: string; hash?: Hex; message?: string };

const IDLE: TxState = { status: "idle", label: "" };

/** A transaction that was sent but whose receipt could not be read (the RPC kept failing, or confirmation timed out).
    It may still go through, so it must never be reported as failed and offered again: that is how a trade doubles. */
export class TxUnconfirmedError extends Error {
  constructor(readonly hash: Hex, cause?: unknown) {
    super("Sent, but its confirmation could not be read. It may still go through: check it on the explorer before trying again.", { cause });
    this.name = "TxUnconfirmedError";
  }
}

/** The status a run ends in when its action throws: "unconfirmed" once a transaction is out, "error" otherwise. */
export function failedState(label: string, error: unknown, hash: Hex | undefined): TxState {
  if (error instanceof TxUnconfirmedError) return { status: "unconfirmed", label, hash: error.hash, message: error.message };
  return { status: "error", label, hash, message: describeError(error) };
}

/** Drives one transaction at a time: wallet signature, confirmation, then success or a readable error. The action
    receives an `onSent` callback so the pending state shows the hash before the receipt lands. A second `run` while one
    is in flight is refused (returns null) synchronously — a double click must never start a second transaction, even
    before React has re-rendered the button as busy. Each run has an identity and only the run that owns the status
    writes it, so an older run can never overwrite a newer state. A sent transaction whose receipt could not be read
    ends "unconfirmed": `busy` stays set and `run` stays refused until the user dismisses it. `reset` (a form change)
    leaves an in-flight or unconfirmed status alone; `dismiss` (the status's close button) clears anything settled. */
export function useTx() {
  const [tx, setTx] = useState<TxState>(IDLE);
  const inFlight = useRef(false);
  const unconfirmed = useRef(false);
  const owner = useRef(0);
  const run = async <T,>(label: string, action: (onSent: (hash: Hex) => void) => Promise<T>, onDone?: (result: T) => void) => {
    if (inFlight.current || unconfirmed.current) return null;
    inFlight.current = true;
    const id = ++owner.current;
    const show = (next: SetStateAction<TxState>) => { if (owner.current === id) setTx(next); };
    show({ status: "signing", label });
    try {
      const result = await action((hash) => show({ status: "pending", label, hash }));
      show((s) => ({ status: "success", label, hash: s.hash }));
      onDone?.(result);
      return result;
    } catch (error) {
      if (error instanceof TxUnconfirmedError) unconfirmed.current = true;
      show((s) => failedState(label, error, s.hash));
      return null;
    } finally {
      inFlight.current = false;
    }
  };
  const clear = () => {
    owner.current++;
    unconfirmed.current = false;
    setTx(IDLE);
  };
  return {
    tx,
    run,
    reset: () => { if (!inFlight.current && !unconfirmed.current) clear(); },
    dismiss: () => { if (!inFlight.current) clear(); },
    busy: tx.status === "signing" || tx.status === "pending" || tx.status === "unconfirmed",
  };
}

const RECEIPT_READS = 3;
type ReceiptReader = Pick<typeof publicClient, "waitForTransactionReceipt">;

/** Waits for the receipt and throws if the transaction reverted. viem already retries each failed poll; a read that
    still fails is tried again twice, and if the receipt stays unreadable (or confirmation times out) the outcome is
    unknown, so TxUnconfirmedError is thrown instead of an ordinary, retryable failure. */
export async function waitFor(hash: Hex, client: ReceiptReader = publicClient, pauseMs = 2_000) {
  let receipt: Awaited<ReturnType<ReceiptReader["waitForTransactionReceipt"]>> | null = null;
  let lastError: unknown;
  for (let attempt = 0; attempt < RECEIPT_READS && !receipt; attempt++) {
    if (attempt > 0) await new Promise((resolve) => setTimeout(resolve, pauseMs * attempt));
    try {
      receipt = await client.waitForTransactionReceipt({ hash });
    } catch (error) {
      lastError = error;
      // viem's WaitForTransactionReceiptTimeoutError, matched by name: three minutes without a receipt won't settle by waiting.
      if ((error as { name?: unknown } | null)?.name === "WaitForTransactionReceiptTimeoutError") break;
    }
  }
  if (!receipt) throw new TxUnconfirmedError(hash, lastError);
  if (receipt.status !== "success") throw new Error("The transaction reverted on-chain.");
  return receipt;
}
