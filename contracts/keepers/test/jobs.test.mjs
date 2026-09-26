// Job-level tests: each job runs against a mocked chain (a table of view results + simulation outcomes) and a
// dry-run sender; we assert exactly which calls it would send and which alerts it raises.
import { test } from "node:test";
import assert from "node:assert/strict";
import { momentsGraduationJob, buybacksJob, sweepsJob, launchpadGraduationJob } from "../lib/jobs.mjs";
import { makeSender } from "../lib/send.mjs";
import { makeReporter } from "../lib/report.mjs";
import { mondayTargetSqrtPriceX96, tickAtSqrtPrice } from "../lib/decide.mjs";

const NOW = 1_790_000_000n;
const DAY = 86_400n;
const a = (n) => `0x${n.toString(16).padStart(40, "0")}`;
const ZERO = a(0);

function mockClient({ reads, sims = {} }) {
  const k = (addr, fn, args = []) => `${addr}:${fn}:${args.map(String).join(",")}`.toLowerCase();
  return {
    reads: new Map(Object.entries(reads).map(([key, v]) => [key.toLowerCase(), v])),
    async getBlock() {
      return { timestamp: NOW };
    },
    async getBlockNumber() {
      return 1000n;
    },
    async getLogs() {
      return [];
    },
    async readContract({ address, functionName, args }) {
      const key = k(address, functionName, args);
      if (!this.reads.has(key)) throw new Error(`unmocked read ${key}`);
      const v = this.reads.get(key);
      if (v instanceof Error) throw v;
      return v;
    },
    async simulateContract({ address, functionName, args }) {
      const s = sims[k(address, functionName, args)];
      if (s === undefined || s instanceof Error) throw s ?? new Error("execution reverted");
      return { result: s };
    },
  };
}

function harness() {
  const logs = [];
  const sender = makeSender({ rpcUrl: "http://x", log: (l) => logs.push(l) });
  const reporter = makeReporter({ log: () => {} });
  return { sender, reporter, logs, state: {} };
}

// ---------------------------------------------------------------- MO-1

const cohort = { label: "cohort3 (live)", factory: a(0xf1), collect: a(0xc1), graduation: a(0x91), hook: a(0x41), buyback: a(0xb1), locker: a(0x11), usdc: a(0x05) };
const moment = (deadline) => ({ deadline, creator: a(1), platform: a(2), treasury: a(3), coin: a(4), nft: a(5) });
const ledger = (stuckSince) => ({ state: 1, completedAt: stuckSince, stuckSince, endedAt: 0n, reserve: 1n });

test("MO-1: retries every GraduationPending Moment and alerts; skips the rest", async () => {
  const client = mockClient({
    reads: {
      [`${cohort.factory}:momentCount:`]: 3n,
      [`${cohort.collect}:state:1`]: 2, // graduated
      [`${cohort.collect}:state:2`]: 1, // pending: griefed
      [`${cohort.collect}:state:3`]: 1, // pending: genuinely failing
      [`${cohort.collect}:ledger:2`]: ledger(NOW - DAY),
      [`${cohort.collect}:ledger:3`]: ledger(NOW - 6n * DAY - 23n * 3600n),
      [`${cohort.factory}:getMoment:2`]: moment(NOW + 20n * DAY),
      [`${cohort.factory}:getMoment:3`]: moment(NOW - DAY),
    },
    sims: { [`${cohort.graduation}:graduate:2`.toLowerCase()]: null },
  });
  const h = harness();
  await momentsGraduationJob({ client, cohorts: [cohort], ...h });
  assert.equal(h.sender.sent.length, 1, "one retry sent");
  assert.deepEqual(h.sender.sent[0].argv.slice(0, 4), ["send", cohort.graduation, "graduate(uint256)", "2"]);
  assert.equal(h.reporter.alerts.length, 2);
  const [g, f] = h.reporter.alerts;
  assert.equal(g.severity, "warning");
  assert.match(g.target, /#2/);
  assert.equal(f.severity, "critical", "retry reverts and expiry is < 1h away");
  assert.match(f.reason, /REVERTS/);
  assert.equal(h.state[`moment:${cohort.collect}:3`].failures, 1, "failure remembered for the next run");
});

test("MO-1: a failure seen on an earlier run escalates even when the retry now simulates", async () => {
  const client = mockClient({
    reads: {
      [`${cohort.factory}:momentCount:`]: 1n,
      [`${cohort.collect}:state:1`]: 1,
      [`${cohort.collect}:ledger:1`]: ledger(NOW),
      [`${cohort.factory}:getMoment:1`]: moment(NOW + 20n * DAY),
    },
    sims: { [`${cohort.graduation}:graduate:1`.toLowerCase()]: null },
  });
  const h = harness();
  h.state[`moment:${cohort.collect}:1`] = { failures: 2 };
  await momentsGraduationJob({ client, cohorts: [cohort], ...h });
  assert.equal(h.reporter.alerts[0].severity, "critical");
  assert.equal(h.sender.sent.length, 1);
});

// ---------------------------------------------------------------- MO-2

test("MO-2: executes due buybacks with a simulated minCoinOut and flags idle locker USDC", async () => {
  const client = mockClient({
    reads: {
      [`${cohort.factory}:momentCount:`]: 2n,
      [`${cohort.buyback}:MIN_AMOUNT:`]: 1_000_000n,
      [`${cohort.buyback}:MIN_INTERVAL:`]: 3600n,
      [`${cohort.collect}:state:1`]: 2,
      [`${cohort.collect}:state:2`]: 2,
      [`${cohort.hook}:buybackAccrued:1`]: 5_000_000n,
      [`${cohort.buyback}:carry:1`]: 0n,
      [`${cohort.buyback}:lastRun:1`]: 0n,
      [`${cohort.hook}:buybackAccrued:2`]: 10n, // not worth a round
      [`${cohort.buyback}:carry:2`]: 0n,
      [`${cohort.buyback}:lastRun:2`]: 0n,
      [`${cohort.usdc}:balanceOf:${cohort.locker}`]: 75_000_000n,
    },
    sims: { [`${cohort.buyback}:execute:1,0`.toLowerCase()]: { coinBought: 1_000_000n } },
  });
  const h = harness();
  await buybacksJob({ client, cohorts: [cohort], ...h, slippageBps: 100n, lockerIdleAlert: 50_000_000n });
  assert.equal(h.sender.sent.length, 1);
  assert.deepEqual(h.sender.sent[0].argv.slice(0, 5), ["send", cohort.buyback, "execute(uint256,uint256)", "1", "990000"]);
  assert.equal(h.reporter.alerts.length, 1);
  assert.match(h.reporter.alerts[0].reason, /idle USDC/);
});

// ---------------------------------------------------------------- Launchpad fixtures

const lp = { label: "launchpad (live)", factory: a(0xfa), hook: a(0x4a) };
const WMON = a(0x3b);
const mondayExec = a(0xe0);
const mondayFactory = a(0xe1);
const launch = (over) => ({
  token: a(0x7001),
  curve: a(0xc001),
  pairToken: ZERO,
  graduationThreshold: 16_000n * 10n ** 18n,
  holderFeeSharing: true,
  graduationVenue: 0,
  phase: 2,
  poolId: `0x${"ab".repeat(32)}`,
  exists: true,
  ...over,
});

test("LP-2: sweeps holder-sharing quote fees; leaves creator-only token fees below the floor", async () => {
  const tok = a(0x7001);
  const l = launch({});
  const client = mockClient({
    reads: {
      [`${lp.factory}:launchCount:`]: 1n,
      [`${lp.factory}:getLaunches:0,100`]: [tok],
      [`${lp.factory}:getLaunchedToken:${tok}`]: l,
      [`${lp.hook}:pendingFees:${l.poolId},${ZERO}`]: 3n,
      [`${lp.hook}:pendingCreatorTax:${l.poolId},${ZERO}`]: 0n,
      [`${lp.hook}:pendingFees:${l.poolId},${tok}`]: 9n,
      [`${lp.hook}:pendingCreatorTax:${l.poolId},${tok}`]: 0n,
    },
    sims: { [`${lp.hook}:sweepPoolFees:${l.poolId},${ZERO}`.toLowerCase()]: null },
  });
  const h = harness();
  await sweepsJob({ client, launchpads: [lp], ...h, minOther: 10n });
  assert.equal(h.sender.sent.length, 1);
  assert.deepEqual(h.sender.sent[0].argv.slice(0, 5), ["send", lp.hook, "sweepPoolFees(bytes32,address)", l.poolId, ZERO]);
});

test("LP-2: a sweep that would revert is not sent (it would still pay gas) and raises an alert", async () => {
  const tok = a(0x7001);
  const l = launch({});
  const client = mockClient({
    reads: {
      [`${lp.factory}:launchCount:`]: 1n,
      [`${lp.factory}:getLaunches:0,100`]: [tok],
      [`${lp.factory}:getLaunchedToken:${tok}`]: l,
      [`${lp.hook}:pendingFees:${l.poolId},${ZERO}`]: 3n,
      [`${lp.hook}:pendingCreatorTax:${l.poolId},${ZERO}`]: 0n,
      [`${lp.hook}:pendingFees:${l.poolId},${tok}`]: 0n,
      [`${lp.hook}:pendingCreatorTax:${l.poolId},${tok}`]: 0n,
    },
  });
  const h = harness();
  await sweepsJob({ client, launchpads: [lp], ...h, minOther: 10n });
  assert.equal(h.sender.sent.length, 0);
  assert.equal(h.reporter.alerts.length, 1);
});

test("LP-2: Monday-venue and not-yet-graduated launches are not swept", async () => {
  const t1 = a(0x7001);
  const t2 = a(0x7002);
  const client = mockClient({
    reads: {
      [`${lp.factory}:launchCount:`]: 2n,
      [`${lp.factory}:getLaunches:0,100`]: [t1, t2],
      [`${lp.factory}:getLaunchedToken:${t1}`]: launch({ graduationVenue: 1 }),
      [`${lp.factory}:getLaunchedToken:${t2}`]: launch({ token: t2, phase: 0 }),
    },
  });
  const h = harness();
  await sweepsJob({ client, launchpads: [lp], ...h });
  assert.equal(h.sender.sent.length, 0);
});

// ---------------------------------------------------------------- LP-1

function lp1Reads({ tok, l, completed, stuckSince, pool, slot0, bitmap = {} }) {
  const reads = {
    [`${lp.factory}:mondayExecutor:`]: mondayExec,
    [`${mondayExec}:factory:`]: mondayFactory,
    [`${mondayExec}:wmon:`]: WMON,
    [`${mondayExec}:FEE:`]: 10_000,
    [`${lp.factory}:launchCount:`]: 1n,
    [`${lp.factory}:getLaunches:0,100`]: [tok],
    [`${lp.factory}:getLaunchedToken:${tok}`]: l,
    [`${l.curve}:completed:`]: completed,
    [`${l.curve}:rescued:`]: false,
    [`${lp.factory}:stuckSince:${tok}`]: stuckSince,
    [`${mondayFactory}:getPool:${tok},${WMON},10000`]: pool,
    [`${l.curve}:reservedTokens:`]: 200_000_000n * 10n ** 18n,
    [`${l.curve}:phantomQuote:`]: 4_000n * 10n ** 18n,
    [`${l.curve}:graduationThreshold:`]: 16_000n * 10n ** 18n,
    [`${mondayFactory}:feeAmountTickSpacing:10000`]: 200,
  };
  if (pool !== ZERO) reads[`${pool}:slot0:`] = slot0;
  for (const [w, v] of Object.entries(bitmap)) reads[`${pool}:tickBitmap:${w}`] = v;
  return reads;
}

test("LP-1: a dense squat on a not-yet-complete Monday launch raises a critical pre-completion alert", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const pool = a(0x9001);
  const target = mondayTargetSqrtPriceX96({ token: tok, quote: WMON, quoteAmount: 16_000n * 10n ** 18n, tokenAmount: 200_000_000n * 10n ** 18n, phantomQuote: 4_000n * 10n ** 18n });
  const tickTo = tickAtSqrtPrice(target);
  const squatTick = 600_000;
  const full = (1n << 256n) - 1n; // every tick in every word initialized
  const bitmap = {};
  for (let w = Math.floor(Math.min(tickTo, squatTick) / 200) >> 8; w <= Math.ceil(Math.max(tickTo, squatTick) / 200) >> 8; w++) bitmap[w] = full;
  const reads = lp1Reads({ tok, l, completed: false, stuckSince: 0n, pool, slot0: [1n << 150n, squatTick, 0, 1, 1, 0, true], bitmap });
  const h = harness();
  await launchpadGraduationJob({ client: mockClient({ reads }), launchpads: [lp], ...h });
  assert.equal(h.sender.sent.length, 0, "nothing to send before completion");
  assert.equal(h.reporter.alerts.length, 1);
  assert.equal(h.reporter.alerts[0].severity, "critical");
  assert.match(h.reporter.alerts[0].reason, /blocking/);
});

test("LP-1: no Monday pool yet -> silent", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = lp1Reads({ tok, l, completed: false, stuckSince: 0n, pool: ZERO });
  const h = harness();
  await launchpadGraduationJob({ client: mockClient({ reads }), launchpads: [lp], ...h });
  assert.equal(h.reporter.alerts.length, 0);
});

test("LP-1: stuck Monday launch whose high-gas Monday retry works -> graduate(token) with the big gas limit", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = lp1Reads({ tok, l, completed: true, stuckSince: NOW - 3600n, pool: ZERO });
  const client = mockClient({ reads, sims: { [`${lp.factory}:graduate:${tok}`.toLowerCase()]: null } });
  const h = harness();
  await launchpadGraduationJob({ client, launchpads: [lp], ...h, mondayGas: 25_000_000n });
  assert.equal(h.sender.sent.length, 1);
  assert.deepEqual(h.sender.sent[0].argv.slice(0, 4), ["send", lp.factory, "graduate(address)", tok]);
  assert.ok(h.sender.sent[0].argv.includes("25000000"));
});

test("LP-1: stuck Monday launch where both paths fail -> critical alert with the rescue time, nothing sent", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = lp1Reads({ tok, l, completed: true, stuckSince: NOW - 3600n, pool: ZERO });
  const h = harness();
  await launchpadGraduationJob({ client: mockClient({ reads }), launchpads: [lp], ...h });
  assert.equal(h.sender.sent.length, 0);
  assert.equal(h.reporter.alerts[0].severity, "critical");
  assert.match(h.reporter.alerts[0].reason, /rescue possible from/);
});

test("LP-1: stuck Monday launch where only the v4 fallback works -> graduateFallback", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = lp1Reads({ tok, l, completed: true, stuckSince: NOW - 3600n, pool: ZERO });
  const client = mockClient({ reads, sims: { [`${lp.factory}:graduateFallback:${tok}`.toLowerCase()]: null } });
  const h = harness();
  await launchpadGraduationJob({ client, launchpads: [lp], ...h });
  assert.deepEqual(h.sender.sent[0].argv.slice(0, 4), ["send", lp.factory, "graduateFallback(address)", tok]);
});
