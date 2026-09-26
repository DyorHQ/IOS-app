import { test } from "node:test";
import assert from "node:assert/strict";
import { signerArgs, castSendArgv, makeSender, assertNoKeyEnv } from "../lib/send.mjs";

const RPC = "http://127.0.0.1:8545";
const TO = "0x0000000000000000000000000000000000000abc";

test("signers: keystore, named account, ledger", () => {
  assert.deepEqual(signerArgs({ keystore: "/k.json", passwordFile: "/pw" }), ["--keystore", "/k.json", "--password-file", "/pw"]);
  assert.deepEqual(signerArgs({ account: "keeper" }), ["--account", "keeper"]);
  assert.deepEqual(signerArgs({ ledger: true, hdPath: "m/44'/60'/1'/0/0" }), ["--ledger", "--mnemonic-derivation-path", "m/44'/60'/1'/0/0"]);
});

test("signers: raw keys and mnemonics are refused; a signer is required", () => {
  assert.throws(() => signerArgs({ privateKey: "0x01" }), /raw keys/);
  assert.throws(() => signerArgs({ mnemonic: "test test" }), /raw keys/);
  assert.throws(() => signerArgs({}), /needs a signer/);
});

test("signers: --unlocked only with an explicit local-anvil opt-in", () => {
  assert.throws(() => signerArgs({ unlocked: TO }), /anvil/);
  assert.deepEqual(signerArgs({ unlocked: TO }, { allowUnlocked: true }), ["--unlocked", "--from", TO]);
});

test("private keys in the environment stop the keeper", () => {
  assert.throws(() => assertNoKeyEnv({ PRIVATE_KEY: "0x01" }), /PRIVATE_KEY/);
  assert.doesNotThrow(() => assertNoKeyEnv({}));
});

test("castSendArgv builds the exact cast command", () => {
  assert.deepEqual(castSendArgv({ to: TO, signature: "graduate(uint256)", args: [7n], rpcUrl: RPC, gasLimit: 5_000_000n, signer: { account: "keeper" } }), [
    "send", TO, "graduate(uint256)", "7", "--rpc-url", RPC, "--gas-limit", "5000000", "--account", "keeper",
  ]);
});

test("dry-run (default) never spawns cast and needs no signer", async () => {
  let spawned = 0;
  const logs = [];
  const s = makeSender({ rpcUrl: RPC, log: (l) => logs.push(l), spawn: () => spawned++ });
  const r = await s.call({ to: TO, signature: "graduate(uint256)", args: [1n] });
  assert.equal(r.dryRun, true);
  assert.equal(spawned, 0);
  assert.match(logs[0], /^\[dry-run\] graduate\(uint256\): cast send 0x0+abc 'graduate\(uint256\)' 1 --rpc-url http:\/\/127\.0\.0\.1:8545 '<signer>'$/);
});

test("send mode spawns cast with the signer and surfaces failures", async () => {
  const calls = [];
  const s = makeSender({ send: true, rpcUrl: RPC, signer: { keystore: "/k.json" }, log: () => {}, spawn: (bin, argv) => (calls.push([bin, argv]), { status: 0, stdout: "ok" }) });
  await s.call({ to: TO, signature: "graduate(uint256)", args: [1n] });
  assert.equal(calls[0][0], "cast");
  assert.deepEqual(calls[0][1].slice(-2), ["--keystore", "/k.json"]);
  const bad = makeSender({ send: true, rpcUrl: RPC, signer: { keystore: "/k.json" }, log: () => {}, spawn: () => ({ status: 1, stderr: "execution reverted" }) });
  await assert.rejects(bad.call({ to: TO, signature: "graduate(uint256)", args: [1n] }), /execution reverted/);
});

test("send mode without a signer refuses to start", () => {
  assert.throws(() => makeSender({ send: true, rpcUrl: RPC, signer: {} }), /needs a signer/);
});
