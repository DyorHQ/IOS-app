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

/* The run rules (createTxRunner) and the per-account store of unconfirmed transactions (createUnconfirmedStore). */

const ME = "0xaBcDeF1111111111111111111111111111111111";
const OTHER_ACCOUNT = "0x2222222222222222222222222222222222222222";

/** A settable state like React's: records every state written. */
const recorder = () => {
  const states = [];
  let current = { status: "idle", label: "" };
  const setTx = (next) => { current = typeof next === "function" ? next(current) : next; states.push(current); };
  return { setTx, states, now: () => current };
};
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
};
const store = (reader = { async getTransactionReceipt() { throw Object.assign(new Error("not found"), { name: "TransactionReceiptNotFoundError" }); } }, storage = null) =>
  tx.createUnconfirmedStore(reader, { pollMs: 0, storage });

test("a second run while one is in flight is refused at once, and a form change can't clear it", async () => {
  const ui = recorder();
  const runner = tx.createTxRunner(ui.setTx, store());
  const gate = deferred();
  const first = runner.run(ME, "Swap", async (onSent) => { onSent(HASH); await gate.promise; return "done"; });
  assert.equal(await runner.run(ME, "Swap", async () => "again"), null, "the double click");
  runner.reset(ME);
  runner.dismiss(ME);
  assert.deepEqual(ui.now(), { status: "pending", label: "Swap", hash: HASH });
  gate.resolve();
  assert.equal(await first, "done");
  assert.deepEqual(ui.now(), { status: "success", label: "Swap", hash: HASH });
  runner.reset(ME);
  assert.equal(ui.now().status, "idle", "a settled status is cleared by a form change");
});

test("an older run can't write the status once a newer run owns it", async () => {
  const ui = recorder();
  const runner = tx.createTxRunner(ui.setTx, store());
  let lateOnSent;
  await runner.run(ME, "First", async (onSent) => { lateOnSent = onSent; });
  await runner.run(ME, "Second", async () => {});
  lateOnSent(OTHER);
  assert.deepEqual(ui.now(), { status: "success", label: "Second", hash: undefined });
  assert.ok(!ui.states.some((s) => s.hash === OTHER), "the first run's late callback wrote nothing");
});

test("an unconfirmed run locks the account, in every form, until it is dismissed", async () => {
  const shared = store();
  const ui = recorder();
  const runner = tx.createTxRunner(ui.setTx, shared);
  const other = tx.createTxRunner(recorder().setTx, shared); // another form, or this one after a remount
  assert.equal(await runner.run(ME, "Swap", async (onSent) => { onSent(OTHER); throw new tx.TxUnconfirmedError(HASH); }), null);
  assert.equal(ui.now().status, "idle", "the status moves to the store");
  assert.deepEqual(shared.get(ME), { status: "unconfirmed", label: "Swap", hash: HASH, message: new tx.TxUnconfirmedError(HASH).message });
  assert.equal(shared.get(ME.toLowerCase()).hash, HASH, "keyed on the account, whatever its case");
  assert.equal(shared.locked(ME.toUpperCase().replace("0X", "0x")), true);
  let ran = false;
  assert.equal(await other.run(ME, "Swap", async () => { ran = true; }), null);
  assert.equal(await runner.run(ME, "Swap", async () => { ran = true; }), null);
  other.reset(ME);
  assert.equal(shared.locked(ME), true, "a form change leaves it alone");
  assert.equal(ran, false);
  assert.equal(await other.run(OTHER_ACCOUNT, "Send", async () => "ok"), "ok", "another account is not locked");
  other.dismiss(ME);
  assert.equal(shared.get(ME), null, "dismissed: the user has checked it");
  assert.equal(await runner.run(ME, "Swap", async () => "ok"), "ok");
});

test("an ordinary failure stays with the form and does not lock", async () => {
  const shared = store();
  const ui = recorder();
  const runner = tx.createTxRunner(ui.setTx, shared);
  await runner.run(ME, "Swap", async () => { throw new Error("User rejected the request."); });
  assert.equal(ui.now().status, "error");
  assert.equal(shared.get(ME), null);
});

test("an unconfirmed transaction settles when its receipt is read, and releases the lock", async () => {
  const receipts = [];
  const reader = { async getTransactionReceipt({ hash }) { const next = receipts.shift(); if (next instanceof Error) throw next; if (!next) throw Object.assign(new Error("not found"), { name: "TransactionReceiptNotFoundError" }); assert.equal(hash, HASH); return next; } };
  const shared = store(reader);
  let notified = 0;
  shared.subscribe(() => notified++);
  shared.hold(ME, { status: "unconfirmed", label: "Swap", hash: HASH, message: "Sent, but…" });

  await shared.check(HASH);
  assert.equal(shared.get(ME).message, "Sent, but…", "a background read with no receipt changes nothing on screen");
  await shared.check(HASH, true);
  assert.match(shared.get(ME).message, /^No receipt yet \(checked .+\)\. It may still go through/, "a manual check answers");
  receipts.push(new Error("HTTP request failed"));
  await shared.check(HASH, true);
  assert.match(shared.get(ME).message, /^Its receipt still could not be read/);
  assert.equal(shared.locked(ME), true);

  receipts.push({ status: "success" });
  await shared.check(HASH);
  assert.deepEqual(shared.get(ME), { status: "success", label: "Swap", hash: HASH, message: undefined });
  assert.equal(shared.locked(ME), false);
  assert.ok(notified >= 4);
  shared.release(ME);
  assert.equal(shared.get(ME), null, "a settled one is released by the next run or form change");

  shared.hold(ME, { status: "unconfirmed", label: "Buy", hash: HASH, message: "Sent, but…" });
  shared.release(ME);
  assert.equal(shared.locked(ME), true, "an unconfirmed one is not");
  receipts.push({ status: "reverted" });
  await shared.check(HASH);
  assert.deepEqual([shared.get(ME).status, shared.get(ME).message], ["error", "The transaction reverted on-chain."]);
});

test("unconfirmed transactions survive a reload of the tab through sessionStorage", () => {
  const saved = new Map();
  const storage = { getItem: (k) => saved.get(k) ?? null, setItem: (k, v) => saved.set(k, v) };
  const before = store(undefined, storage);
  before.hold(ME, { status: "unconfirmed", label: "Swap", hash: HASH, message: "Sent, but…" });
  before.hold(OTHER_ACCOUNT, { status: "unconfirmed", label: "Send", hash: OTHER, message: "Sent, but…" });
  before.clear(OTHER_ACCOUNT);
  const after = store(undefined, storage);
  assert.deepEqual(after.get(ME), { status: "unconfirmed", label: "Swap", hash: HASH, message: "Sent, but…" });
  assert.equal(after.get(OTHER_ACCOUNT), null, "a dismissed one is gone");

  saved.set("dyorhq-unconfirmed-tx", JSON.stringify([[ME.toLowerCase(), { label: "x", hash: "0x1234" }], "junk", [1, 2]]));
  assert.equal(store(undefined, storage).get(ME), null, "malformed entries are ignored");
  saved.set("dyorhq-unconfirmed-tx", "{not json");
  assert.equal(store(undefined, storage).get(ME), null);
  const blocked = { getItem() { throw new Error("SecurityError"); }, setItem() { throw new Error("SecurityError"); } };
  const inMemory = store(undefined, blocked);
  inMemory.hold(ME, { status: "unconfirmed", label: "Swap", hash: HASH });
  assert.equal(inMemory.locked(ME), true, "blocked storage: still held in memory");
});
