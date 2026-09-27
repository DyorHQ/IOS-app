"use client";

import { useState, useSyncExternalStore, type SetStateAction } from "react";
import type { Hex } from "viem";
import { publicClient } from "./chain";
import { describeError } from "./errors";
import { useWallet } from "./wallet";

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

/* ------------------------------------------------------------------------------------ unconfirmed transactions */

/** An account's transaction whose outcome was unknown when its run ended: "unconfirmed" while it is still unknown (and
    the account may send nothing else from this page), then "success" or "error" once its receipt has been read. */
export type HeldTx = TxState & { hash: Hex };
type ReceiptLookup = Pick<typeof publicClient, "getTransactionReceipt">;
type SessionStore = Pick<Storage, "getItem" | "setItem">;

const STORAGE_KEY = "dyorhq-unconfirmed-tx";
const HASH = /^0x[0-9a-fA-F]{64}$/;

/** The unconfirmed transactions of every account, outside any component: closing a sheet, leaving a screen or a panel
    that changes phase must not forget one, or the same trade can be sent again. Mirrored to sessionStorage (when there
    is one), so a reload of the tab keeps them too. While one is unconfirmed its receipt is read again every `pollMs`, up
    to `maxPolls` times; `check` reads it once, now. */
export function createUnconfirmedStore(reader: ReceiptLookup, { pollMs = 15_000, maxPolls = 40, storage = null }: { pollMs?: number; maxPolls?: number; storage?: SessionStore | null } = {}) {
  const held = new Map<string, HeldTx>();
  const listeners = new Set<() => void>();
  const polling = new Set<Hex>();
  const keyOf = (account: string) => account.toLowerCase();
  const outstanding = (hash: Hex) => [...held.values()].some((t) => t.hash === hash && t.status === "unconfirmed");
  const changed = () => {
    if (storage) {
      try {
        storage.setItem(STORAGE_KEY, JSON.stringify([...held].filter(([, t]) => t.status === "unconfirmed")));
      } catch {
        /* Blocked storage: this tab still holds them in memory. */
      }
    }
    for (const listener of listeners) listener();
  };
  const settle = (hash: Hex, next: Partial<TxState>) => {
    for (const [key, t] of held) if (t.hash === hash && t.status === "unconfirmed") held.set(key, { ...t, ...next });
    changed();
  };

  /** Reads the receipt once. A receipt settles the transaction; none yet (or a failed read) leaves it unconfirmed, and
      a `manual` check says so with the time, so the person who asked hears an answer. */
  const check = async (hash: Hex, manual = false): Promise<void> => {
    try {
      const receipt = await reader.getTransactionReceipt({ hash });
      settle(hash, receipt.status === "success" ? { status: "success", message: undefined } : { status: "error", message: "The transaction reverted on-chain." });
    } catch (error) {
      if (!manual || !outstanding(hash)) return;
      const notMined = (error as { name?: unknown } | null)?.name === "TransactionReceiptNotFoundError";
      const at = new Date().toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", second: "2-digit" });
      settle(hash, { message: `${notMined ? "No receipt yet" : "Its receipt still could not be read"} (checked ${at}). It may still go through: check it on the explorer before trying again.` });
    }
  };

  const poll = (hash: Hex) => {
    if (pollMs <= 0 || polling.has(hash)) return;
    polling.add(hash);
    const next = (left: number) => setTimeout(() => {
      void check(hash).finally(() => {
        if (left > 1 && outstanding(hash)) next(left - 1);
        else polling.delete(hash);
      });
    }, pollMs);
    next(maxPolls);
  };

  if (storage) {
    try {
      const saved: unknown = JSON.parse(storage.getItem(STORAGE_KEY) ?? "[]");
      for (const item of Array.isArray(saved) ? saved : []) {
        const [key, t] = Array.isArray(item) ? item : [];
        if (typeof key !== "string" || typeof t?.label !== "string" || typeof t?.hash !== "string" || !HASH.test(t.hash)) continue;
        held.set(key, { status: "unconfirmed", label: t.label, hash: t.hash as Hex, message: typeof t.message === "string" ? t.message : undefined });
        poll(t.hash as Hex);
      }
    } catch {
      /* Nothing usable saved. */
    }
  }

  const get = (account: string | null) => (account === null ? null : held.get(keyOf(account)) ?? null);
  return {
    get,
    locked: (account: string) => get(account)?.status === "unconfirmed",
    hold(account: string, t: HeldTx) {
      held.set(keyOf(account), t);
      changed();
      poll(t.hash);
    },
    /** Drops the account's transaction once it has settled (a new run or a form change moves on from it); an
        unconfirmed one stays. */
    release(account: string) {
      const t = get(account);
      if (t && t.status !== "unconfirmed" && held.delete(keyOf(account))) changed();
    },
    /** Drops the account's transaction whatever its state: the user has dismissed it, having checked it. */
    clear(account: string) {
      if (held.delete(keyOf(account))) changed();
    },
    check,
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
  };
}
export type UnconfirmedStore = ReturnType<typeof createUnconfirmedStore>;

function sessionStore(): SessionStore | null {
  try {
    return typeof window === "undefined" ? null : window.sessionStorage;
  } catch {
    return null;
  }
}

const unconfirmedTxs = createUnconfirmedStore(publicClient, { storage: sessionStore() });

/** Reads an unconfirmed transaction's receipt again now (the status's "Check again"). */
export const checkTx = (hash: Hex) => unconfirmedTxs.check(hash, true);

/* ----------------------------------------------------------------------------------------------------- runs */

/** The run rules behind useTx, without React. One run at a time: a second `run` while one is in flight is refused
    (returns null) synchronously, so a double click can never start a second transaction, even before React has
    re-rendered the button as busy. Each run has an identity and only the run that owns the status writes it, so an
    older run can never overwrite a newer state. A sent transaction whose receipt could not be read is handed to the
    store as the account's unconfirmed transaction, and every run for that account is refused until it settles or the
    user dismisses it. `reset` (a form change) and `dismiss` (the status's close button) never touch a run in flight;
    `dismiss` also drops the account's held transaction. */
export function createTxRunner(setTx: (next: SetStateAction<TxState>) => void, store: Pick<UnconfirmedStore, "locked" | "hold" | "release" | "clear">) {
  let inFlight = false;
  let owner = 0;
  const clearLocal = () => {
    owner++;
    setTx(IDLE);
  };
  return {
    async run<T>(account: string | null, label: string, action: (onSent: (hash: Hex) => void) => Promise<T>, onDone?: (result: T) => void): Promise<T | null> {
      const key = account ?? "";
      if (inFlight || store.locked(key)) return null;
      inFlight = true;
      const id = ++owner;
      const show = (next: TxState) => { if (owner === id) setTx(next); };
      let sent: Hex | undefined;
      store.release(key);
      show({ status: "signing", label });
      try {
        const result = await action((hash) => { sent = hash; show({ status: "pending", label, hash }); });
        show({ status: "success", label, hash: sent });
        onDone?.(result);
        return result;
      } catch (error) {
        const failed = failedState(label, error, sent);
        if (failed.status === "unconfirmed" && failed.hash) {
          store.hold(key, { ...failed, hash: failed.hash });
          show(IDLE);
        } else show(failed);
        return null;
      } finally {
        inFlight = false;
      }
    },
    reset(account: string | null) {
      if (inFlight) return;
      clearLocal();
      store.release(account ?? "");
    },
    dismiss(account: string | null) {
      if (inFlight) return;
      clearLocal();
      store.clear(account ?? "");
    },
  };
}

/** Drives one transaction at a time for a form or panel: wallet signature, confirmation, then success or a readable
    error (createTxRunner). The action receives an `onSent` callback so the pending state shows the hash before the
    receipt lands. The status shown is this form's own run while it is in flight, else the account's unconfirmed (or
    since settled) transaction, else this form's last outcome. `busy`: a run is in flight (a spinner). `locked`: no new
    transaction may start, because one is in flight or the account's last one is still unconfirmed. */
export function useTx() {
  const { account } = useWallet();
  const [local, setLocal] = useState<TxState>(IDLE);
  const [runner] = useState(() => createTxRunner(setLocal, unconfirmedTxs));
  const heldTx = useSyncExternalStore(unconfirmedTxs.subscribe, () => unconfirmedTxs.get(account), () => null);
  const busy = local.status === "signing" || local.status === "pending";
  return {
    tx: busy ? local : heldTx ?? local,
    run: <T,>(label: string, action: (onSent: (hash: Hex) => void) => Promise<T>, onDone?: (result: T) => void) => runner.run(account, label, action, onDone),
    reset: () => runner.reset(account),
    dismiss: () => runner.dismiss(account),
    busy,
    locked: busy || heldTx?.status === "unconfirmed",
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
