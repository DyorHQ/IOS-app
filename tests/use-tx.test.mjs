import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";
import { WaitForTransactionReceiptTimeoutError } from "viem";

/* app/lib/use-tx.ts: once a transaction is out, a failed receipt read is "unconfirmed" (it may still land), never an
   ordinary failure the user is invited to retry. The receipt client is stubbed; nothing reaches an RPC. */

const tx = await tsImport("../app/lib/use-tx.ts", import.meta.url);
const HASH = `0x${"ab".repeat(32)}`;
const OTHER = `0x${"cd".repeat(32)}`;

const reader = (...outcomes) => {
  const calls = [];
  return {
    calls,
    async waitForTransactionReceipt({ hash }) {
      calls.push(hash);
      const next = outcomes.shift();
      if (next instanceof Error) throw next;
      return next;
    },
  };
};

test("a confirmed receipt is returned; a reverted one is a plain failure", async () => {
  const ok = { status: "success", logs: [] };
  assert.equal(await tx.waitFor(HASH, reader(ok), 0), ok);
  await assert.rejects(tx.waitFor(HASH, reader({ status: "reverted" }), 0), (e) => !(e instanceof tx.TxUnconfirmedError) && /reverted/.test(e.message));
});

test("a receipt read that fails is retried, and still counts once it lands", async () => {
  const client = reader(new Error("HTTP request failed"), { status: "success", logs: [] });
  const receipt = await tx.waitFor(HASH, client, 0);
  assert.equal(receipt.status, "success");
  assert.deepEqual(client.calls, [HASH, HASH]);
});

test("a receipt that stays unreadable is unconfirmed, with the hash", async () => {
  const client = reader(new Error("rpc down"), new Error("rpc down"), new Error("rpc down"), { status: "success" });
  await assert.rejects(tx.waitFor(HASH, client, 0), (e) => e instanceof tx.TxUnconfirmedError && e.hash === HASH);
  assert.equal(client.calls.length, 3, "three reads, then give up");
});

test("a confirmation timeout is unconfirmed at once (no further three-minute waits)", async () => {
  const client = reader(new WaitForTransactionReceiptTimeoutError({ hash: HASH }), { status: "success" });
  await assert.rejects(tx.waitFor(HASH, client, 0), (e) => e instanceof tx.TxUnconfirmedError);
  assert.equal(client.calls.length, 1);
});

test("the failed state keeps a sent transaction out of the retryable error state", () => {
  const unconfirmed = tx.failedState("Swap", new tx.TxUnconfirmedError(HASH), OTHER);
  assert.equal(unconfirmed.status, "unconfirmed");
  assert.equal(unconfirmed.hash, HASH, "the unconfirmed transaction's own hash, not an earlier step's");
  assert.match(unconfirmed.message, /explorer/);
  const failed = tx.failedState("Swap", new Error("Nothing to send."), OTHER);
  assert.deepEqual(failed, { status: "error", label: "Swap", hash: OTHER, message: "Nothing to send." });
});
