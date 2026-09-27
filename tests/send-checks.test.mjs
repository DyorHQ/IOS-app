import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* app/lib/send-checks.ts: the Send sheet refuses recipients that certainly lose the tokens and flags the risky ones. */

const { CODE_UNREADABLE, checkRecipient, isDelegatedAccount } = await tsImport("../app/lib/send-checks.ts", import.meta.url);
const USDC = { address: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603", symbol: "USDC" };
const MON = { address: "0x0000000000000000000000000000000000000000", symbol: "MON", native: true };
const ME = "0x1111111111111111111111111111111111111111";
const FRIEND = "0x2222222222222222222222222222222222222222";
const CONTRACT_CODE = "0x6080604052348015600f57600080fd5b50";
const DELEGATION = `0xef0100${"ab".repeat(20)}`;

test("an ordinary wallet passes", () => {
  assert.deepEqual(checkRecipient(FRIEND, USDC, ME, undefined), { block: null, warn: null, contract: false, wait: null });
  assert.deepEqual(checkRecipient(` ${FRIEND} `, MON, ME, "0x"), { block: null, warn: null, contract: false, wait: null });
});

test("malformed and mis-checksummed addresses are refused", () => {
  assert.match(checkRecipient("0x123", USDC, ME, undefined).block, /valid address/);
  assert.match(checkRecipient("0x754704bc059F8C67012fEd69BC8A327a5aafb603", USDC, ME, undefined).block, /valid address/, "a broken checksum");
});

test("the zero address and the token's own contract are refused", () => {
  assert.match(checkRecipient("0x0000000000000000000000000000000000000000", MON, ME, undefined).block, /burned/);
  assert.match(checkRecipient("0x0000000000000000000000000000000000000000", USDC, ME, undefined).block, /burned/);
  assert.match(checkRecipient(USDC.address.toLowerCase(), USDC, ME, CONTRACT_CODE).block, /USDC token contract itself/);
});

test("a contract recipient is flagged for confirmation; a 7702-delegated wallet is not", () => {
  const c = checkRecipient(FRIEND, USDC, ME, CONTRACT_CODE);
  assert.equal(c.block, null);
  assert.equal(c.contract, true);
  assert.match(c.warn, /contract/);
  assert.equal(isDelegatedAccount(DELEGATION), true);
  assert.equal(isDelegatedAccount(`${DELEGATION}00`), false);
  assert.deepEqual(checkRecipient(FRIEND, USDC, ME, DELEGATION), { block: null, warn: null, contract: false, wait: null });
});

test("sending to yourself is noted, not refused", () => {
  const self = checkRecipient(ME, USDC, ME, undefined);
  assert.equal(self.block, null);
  assert.match(self.warn, /your own wallet/);
});

test("a recipient whose bytecode is unknown is never cleared: Send waits while it is read and after a failed read", () => {
  const reading = checkRecipient(FRIEND, USDC, ME, null);
  assert.deepEqual([reading.block, reading.contract], [null, false]);
  assert.match(reading.wait, /Checking the address/);
  const failed = checkRecipient(FRIEND, USDC, ME, CODE_UNREADABLE);
  assert.equal(failed.block, null);
  assert.match(failed.wait, /Couldn't check whether this address is a contract/, "a failed read is not \"no code\"");
  assert.equal(checkRecipient(ME, USDC, ME, CODE_UNREADABLE).warn, null, "nothing is concluded about the recipient");
  // Refusals need no bytecode, so they still apply while it is unknown.
  assert.match(checkRecipient("0x0000000000000000000000000000000000000000", USDC, ME, CODE_UNREADABLE).block, /burned/);
  assert.match(checkRecipient(USDC.address, USDC, ME, null).block, /token contract itself/);
  assert.equal(checkRecipient(FRIEND, USDC, ME, CONTRACT_CODE).wait, null, "known bytecode: nothing to wait for");
});
