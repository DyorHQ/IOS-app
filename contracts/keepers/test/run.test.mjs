// Build 17, K1 through a whole run (lib/run.mjs) against a mocked chain, sender and webhook:
//  - E7: the sending address comes from the signer; a different --sim-from refuses the run; the balance check always
//    runs for the wallet that pays.
//  - E9: --max-runtime stops a hung run (critical alert, state saved, exit 1, nothing sent afterwards); a watchdog
//    never sends and marks its posts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseKeeperArgs } from "../lib/options.mjs";
import { runKeeper } from "../lib/run.mjs";
import { signerAddress } from "../lib/send.mjs";
import { EXIT } from "../lib/report.mjs";
import { momentsCohorts } from "../lib/deployments.mjs";

const NOW = 1_790_000_000n;
const SIGNER = "0x1111111111111111111111111111111111111111";
const OTHER = "0x2222222222222222222222222222222222222222";
const MON = 10n ** 18n;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const opts = (argv, over = {}) => ({ ...parseKeeperArgs(argv, {}), ...over });

/** A chain with one live Moment stuck in GraduationPending whose retry simulates OK. */
function chain({ balance = 50n * MON, blockDelay = 0, hang = false } = {}) {
  const reads = {
    momentCount: 1n,
    state: 1,
    ledger: { state: 1, completedAt: NOW, stuckSince: NOW, endedAt: 0n, reserve: 1n },
    getMoment: { deadline: NOW + 20n * 86_400n, creator: SIGNER, platform: SIGNER, treasury: SIGNER, coin: SIGNER, nft: SIGNER },
  };
  return {
    balances: [],
    sims: [],
    async getCode() {
      return "0x6000";
    },
    async getBalance({ address }) {
      this.balances.push(address);
      return balance;
    },
    async getBlock() {
      if (hang) await new Promise(() => {});
      if (blockDelay) await sleep(blockDelay);
      return { timestamp: NOW };
    },
    async getBlockNumber() {
      return 1000n;
    },
    async getGasPrice() {
      return 100n;
    },
    async readContract({ functionName }) {
      if (functionName in reads) return reads[functionName];
      throw new Error("execution reverted");
    },
    async simulateContract(req) {
      this.sims.push(req);
      return { result: null };
    },
  };
}

function fakeSender(calls) {
  return () => ({
    sent: [],
    live: true,
    async call(tx) {
      calls.push(tx);
      return { dryRun: false, receipt: { status: 1, transactionHash: `0x${"cd".repeat(32)}` }, spentWei: 1n };
    },
  });
}

function world({ client = chain(), signer = SIGNER, sends = [], posts = [], lines = [] } = {}) {
  return {
    client,
    sends,
    posts,
    lines,
    deps: {
      log: (l) => lines.push(l),
      env: {},
      makeClient: () => client,
      makeSenderFn: fakeSender(sends),
      signerAddressFn: () => signer,
      pickRpc: async (urls) => ({ url: urls[0], healthy: true }),
      fetchImpl: async (url, init) => (posts.push({ url, body: JSON.parse(init.body) }), { ok: true, status: 204 }),
    },
  };
}

// ---------------------------------------------------------------- E7

test("E7: signerAddress derives the sender with `cast wallet address` and the same keystore options as the sends", () => {
  const calls = [];
  const spawn = (bin, argv, o) => (calls.push({ bin, argv, o }), { status: 0, stdout: `${SIGNER}\n` });
  assert.equal(signerAddress({ keystore: "/ks/dyor-keeper-grad", passwordFile: "/run/creds/pw" }, { spawn, castBin: "cast" }), SIGNER);
  assert.deepEqual(calls[0].argv, ["wallet", "address", "--keystore", "/ks/dyor-keeper-grad", "--password-file", "/run/creds/pw"]);
  assert.equal(calls[0].o.killSignal, "SIGKILL");
  assert.ok(calls[0].o.timeout > 0, "a password prompt with no terminal cannot hang the run");
  signerAddress({ account: "dyor-keeper-grad" }, { spawn });
  assert.deepEqual(calls[1].argv, ["wallet", "address", "--account", "dyor-keeper-grad"]);
  assert.equal(signerAddress({ unlocked: OTHER }, { allowUnlocked: true, spawn }), OTHER, "anvil only: the address is given");
  assert.equal(calls.length, 2);
});

test("E7: a signer whose address cannot be derived stops the run", () => {
  const fail = (r) => () => signerAddress({ keystore: "/k" }, { spawn: () => r });
  assert.throws(fail({ status: 1, stdout: "", stderr: "Error: Failed to decrypt keystore: Mac Mismatch" }), /Mac Mismatch/);
  assert.throws(fail({ status: 0, stdout: "not an address" }), /could not derive/);
  assert.throws(fail({ status: null, signal: "SIGKILL", error: Object.assign(new Error("x"), { code: "ETIMEDOUT" }) }), /timed out/);
  assert.throws(() => signerAddress({}, { spawn: () => ({}) }), /needs a signer/);
});

test("E7: in send mode a --sim-from that is not the signer refuses the run before anything is read or sent", async () => {
  const w = world();
  await assert.rejects(runKeeper(opts(["moments-graduation", "--only-live"], { send: true, signer: { account: "k" }, simFrom: OTHER }), w.deps), /--sim-from 0x2+ is not the signer's address 0x1+: refusing to run/);
  assert.deepEqual(w.sends, []);
  assert.deepEqual(w.client.balances, []);
  assert.deepEqual(w.client.sims, []);
});

test("E7: in send mode the signer's address is used for the simulations and the balance check, which always runs", async () => {
  const w = world({ client: chain({ balance: 5n * MON }) });
  const code = await runKeeper(opts(["moments-graduation", "--only-live", "--min-balance", "10", "--webhook", "https://hooks.example/x"], { send: true, signer: { account: "k" } }), w.deps);
  assert.equal(code, EXIT.ALERT);
  assert.deepEqual(w.client.balances, [SIGNER]);
  assert.ok(w.client.sims.length > 0 && w.client.sims.every((s) => s.account === SIGNER), "simulated as the sender");
  assert.equal(w.sends.length, 1, "the retry is sent");
  const low = w.posts[0].body.alerts.find((x) => /below --min-balance 10/.test(x.reason));
  assert.equal(low.severity, "warning");
  assert.equal(low.target, SIGNER);
  // The same address given explicitly (any case) is fine.
  const same = world();
  await runKeeper(opts(["moments-graduation", "--only-live"], { send: true, signer: { account: "k" }, simFrom: SIGNER.toUpperCase().replace("0X", "0x") }), same.deps);
  assert.equal(same.sends.length, 1);
});

test("E7: a dry run checks the balance of --sim-from when given, and reads none without it", async () => {
  const w = world({ client: chain({ balance: 1n }) });
  await runKeeper(opts(["moments-graduation", "--only-live"], { simFrom: OTHER }), w.deps);
  assert.deepEqual(w.client.balances, [OTHER]);
  const none = world();
  await runKeeper(opts(["moments-graduation", "--only-live"]), none.deps);
  assert.deepEqual(none.client.balances, []);
});

test("the run header names the RPC by its origin only, and the sending address", async () => {
  const w = world();
  const keyed = "https://monad.example/v2/FAKE_KEY_123";
  await runKeeper(opts(["moments-graduation", "--only-live", "--rpc-url", keyed, "--rpc-url", "https://rpc4.monad.xyz"], { send: true, signer: { account: "k" } }), w.deps);
  const header = w.lines.find((l) => l.startsWith("keeper:"));
  assert.equal(header, `keeper: moments-graduation · SEND · rpc https://monad.example/… → https://rpc4.monad.xyz · cast via https://monad.example/… · from ${SIGNER}`);
  assert.ok(!w.lines.join("\n").includes("FAKE_KEY_123"));
});

// ---------------------------------------------------------------- E9

test("E9: --role watchdog refuses --send; unknown roles and a bad --max-runtime are usage errors", () => {
  assert.throws(() => parseKeeperArgs(["all", "--role", "watchdog", "--send"], {}), /watchdog never sends/);
  assert.throws(() => parseKeeperArgs(["all", "--role", "boss"], {}), /--role must be one of keeper, watchdog/);
  assert.throws(() => parseKeeperArgs(["all", "--max-runtime", "0"], {}), /--max-runtime must be a positive/);
  assert.equal(parseKeeperArgs(["all"], {}).maxRuntime, 240);
  assert.equal(parseKeeperArgs(["all"], {}).role, "keeper");
});

test("E9: runKeeper itself refuses a watchdog that would send", async () => {
  const w = world();
  await assert.rejects(runKeeper(opts(["governance"], { role: "watchdog", send: true, signer: { account: "k" } }), w.deps), /watchdog never sends/);
  assert.deepEqual(w.sends, []);
});

test("E9: every watchdog post is marked [watchdog]", async () => {
  const w = world({ client: chain({ balance: 0n }) });
  const code = await runKeeper(opts(["moments-graduation", "--only-live", "--role", "watchdog", "--webhook", "https://hooks.example/x"], { simFrom: OTHER }), w.deps);
  assert.equal(code, EXIT.ALERT);
  assert.equal(w.posts.length, 1);
  assert.match(w.posts[0].body.text, /^\[watchdog\] DyorHQ keeper/);
  assert.ok(w.lines.some((l) => /· watchdog ·/.test(l)));
});

test("E9: a run past --max-runtime raises a critical alert, saves its state, posts, and exits 1", async () => {
  const stateFile = join(mkdtempSync(join(tmpdir(), "keeper-run-")), "state.json");
  const w = world({ client: chain({ hang: true }) });
  const t0 = Date.now();
  const code = await runKeeper(opts(["moments-graduation", "--only-live", "--webhook", "https://hooks.example/x", "--state-file", stateFile], { maxRuntime: 0.2 }), w.deps);
  assert.equal(code, EXIT.ERROR);
  assert.ok(Date.now() - t0 < 2000, "stopped at the deadline, not when the read returned");
  const overrun = w.posts[0].body.alerts.find((x) => x.target === "run");
  assert.equal(overrun.severity, "critical");
  assert.match(overrun.reason, /exceeded --max-runtime 0\.2s during moments-graduation/);
  assert.equal(JSON.parse(readFileSync(stateFile, "utf8")).version, 1, "the state was saved");
});

test("E9: once the deadline has passed nothing more is sent, even when a late read lets the job go on", async () => {
  const w = world({ client: chain({ blockDelay: 300 }) });
  const code = await runKeeper(opts(["moments-graduation", "--only-live"], { send: true, signer: { account: "k" }, maxRuntime: 0.1 }), w.deps);
  assert.equal(code, EXIT.ERROR);
  await sleep(600); // the job wakes up, finds the pending Moment and tries to send its retry
  assert.ok(w.client.sims.length > 0, "the job did go on after the deadline");
  assert.deepEqual(w.sends, [], "but its send was refused");
});

test("E9: a normal run finishes well inside the deadline and exits by its alerts", async () => {
  const w = world();
  const code = await runKeeper(opts(["moments-graduation", "--only-live"]), w.deps);
  assert.equal(code, EXIT.ALERT, "the pending Moment is a warning");
  assert.equal(momentsCohorts().filter((c) => c.live).length, 1);
});
