// The keeper jobs. Each takes a viem-like `client` (readContract / simulateContract / estimateContractGas / getBlock /
// getLogs / getBlockNumber / getGasPrice), the deployment records, a `sender` (dry-run by default, see send.mjs), a
// `reporter` and a mutable `state` object, so every job runs unchanged against Monad, a local anvil, or a mock in the
// tests.
//
// Robustness rules (2026-09-26 ops audit): one failing read never ends a run. Every cohort, launchpad and item is
// isolated (`guard`): a failure becomes a critical alert and the job moves on, so a rate limit on one read cannot
// starve the items after it. Log scans run after every retry and adapt their range to the RPC's cap.
import {
  momentsFactoryAbi,
  momentsFactoryV1Abi,
  momentCollectAbi,
  momentGraduationAbi,
  momentFeeHookAbi,
  momentBuybackAbi,
  launchpadFactoryAbi,
  launchpadFactoryLegacyAbi,
  launchpadFactoryV2Abi,
  bondingCurveAbi,
  mondayExecutorAbi,
  mondayFactoryAbi,
  mondayPoolAbi,
  mondayFeeVaultAbi,
  memeHookAbi,
  memeHookV2Abi,
  erc20Abi,
} from "./abis.mjs";
import {
  MOMENT_STATE,
  LAUNCH_PHASE,
  VENUE,
  decideMomentGraduation,
  decideBuyback,
  decideLockerIdle,
  minOutWithSlippage,
  decideSweep,
  minHolderSweep,
  gasWithMargin,
  decideStuckLaunch,
  mondayTargetSqrtPriceX96,
  tickAtSqrtPrice,
  bitmapWordsBetween,
  countInitializedTicksBetween,
  assessMondaySquat,
  squatSeverity,
} from "./decide.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
const DEFAULT_SIM_ACCOUNT = "0x000000000000000000000000000000000000dEaD";
const DAY = 86_400n;

function errText(e) {
  return (e?.shortMessage || e?.message || String(e)).split("\n")[0];
}

async function simulate(client, req) {
  try {
    const r = await client.simulateContract(req);
    return { ok: true, result: r.result };
  } catch (e) {
    return { ok: false, error: errText(e) };
  }
}

/** A read whose failure is expected on some deployments (a function the live or legacy bytecode lacks). */
async function readOr(client, req, fallback) {
  try {
    return await client.readContract(req);
  } catch {
    return fallback;
  }
}

/** Runs one unit of work (a cohort, a launchpad, a Moment, a launch); a failure is a critical alert, not the end. */
async function guard(reporter, job, target, fn) {
  try {
    await fn();
  } catch (e) {
    reporter.alert({ job, target, severity: "critical", reason: `could not be checked (read failed): ${errText(e)}` });
  }
}

/** Gas limit for one send: estimateGas x 1.2, capped at the job's fixed limit (Monad bills the limit, not the use). */
async function gasFor(client, req, cap) {
  try {
    return gasWithMargin(await client.estimateContractGas(req), cap);
  } catch {
    return cap;
  }
}

async function gasPriceOf(client) {
  try {
    return typeof client.getGasPrice === "function" ? await client.getGasPrice() : 0n;
  } catch {
    return 0n;
  }
}

/** Sends one transaction; a failed send becomes an alert instead of aborting the rest of the run (other targets and
    other jobs still get their turn). */
async function safeSend(sender, reporter, job, target, tx) {
  try {
    return await sender.call(tx);
  } catch (e) {
    reporter.alert({ job, target, severity: "critical", reason: `send failed: ${errText(e)}` });
    return null;
  }
}

async function now(client) {
  return (await client.getBlock()).timestamp;
}

/**
 * eth_getLogs over [from, to] in chunks of at most `chunk` blocks. An RPC that caps the range (rpc.monad.xyz answers
 * more than 100 blocks with -32614 "eth_getLogs is limited to a 100 range") makes the chunk halve and retry, down to
 * one block; any other error is thrown.
 */
export async function getLogsChunked(client, { from, to, chunk = 100n, ...filter }) {
  const out = [];
  let size = chunk > 0n ? chunk : 1n;
  for (let start = from; start <= to; ) {
    const end = start + size - 1n < to ? start + size - 1n : to;
    try {
      out.push(...(await client.getLogs({ ...filter, fromBlock: start, toBlock: end })));
      start = end + 1n;
    } catch (e) {
      const text = `${e?.shortMessage ?? ""} ${e?.details ?? ""} ${e?.message ?? ""}`;
      if (size > 1n && /range|limit|too many|exceed/i.test(text)) {
        size /= 2n;
        continue;
      }
      throw e;
    }
  }
  return out;
}

async function lookbackRange(client, lookback) {
  const head = await client.getBlockNumber();
  return { from: head > lookback ? head - lookback : 0n, to: head };
}

// ------------------------------------------------------------------------------------------------ MO-1

async function retryMoment({ client, c, id, t, sender, reporter, state, simAccount, gasLimit }) {
  const s = Number(await client.readContract({ address: c.collect, abi: momentCollectAbi, functionName: "state", args: [id] }));
  if (s !== MOMENT_STATE.GraduationPending) return;
  const ledger = await client.readContract({ address: c.collect, abi: momentCollectAbi, functionName: "ledger", args: [id] });
  let m;
  try {
    m = await client.readContract({ address: c.factory, abi: momentsFactoryAbi, functionName: "getMoment", args: [id] });
  } catch {
    m = await client.readContract({ address: c.factory, abi: momentsFactoryV1Abi, functionName: "getMoment", args: [id] });
  }
  const req = { address: c.graduation, abi: momentGraduationAbi, functionName: "graduate", args: [id], account: simAccount };
  const sim = await simulate(client, { ...req, gas: gasLimit });
  const key = `moment:${c.collect.toLowerCase()}:${id}`;
  const d = decideMomentGraduation({
    state: s,
    deadline: BigInt(m.deadline),
    stuckSince: BigInt(ledger.stuckSince),
    now: t,
    simulateOk: sim.ok,
    simulateError: sim.error,
    previousFailures: state[key]?.failures ?? 0,
  });
  state[key] = { failures: d.failures, lastSeen: Number(t) };
  const target = `${c.label} moment #${id}`;
  reporter.alert({ job: "moments-graduation", target, severity: d.severity, reason: `${d.reason}; expirable at ${d.expirableAt} (${d.secondsLeft}s left)` });
  if (d.action === "graduate") {
    reporter.action({ job: "moments-graduation", target, what: "graduate(id)" });
    const gas = await gasFor(client, req, gasLimit);
    await safeSend(sender, reporter, "moments-graduation", target, { to: c.graduation, signature: "graduate(uint256)", args: [id], gasLimit: gas, label: `graduate ${target}` });
  }
}

/**
 * Retries graduation of every GraduationPending Moment in every cohort; alerts on each. With `logsLookback` it then
 * reports GraduationFailed events. The retries of ALL cohorts run before any log scan: the scan is only an alerting
 * aid, and an RPC that refuses a log range must never keep a later cohort's retry from being sent.
 */
export async function momentsGraduationJob({ client, cohorts, sender, reporter, state, simAccount = DEFAULT_SIM_ACCOUNT, logsLookback = 0n, logsChunk = 100n, gasLimit = 5_000_000n }) {
  const t = await now(client);
  for (const c of cohorts) {
    await guard(reporter, "moments-graduation", c.label, async () => {
      const count = await client.readContract({ address: c.factory, abi: momentsFactoryAbi, functionName: "momentCount" });
      reporter.info(`${c.label}: ${count} moments`);
      for (let id = 1n; id <= count; id++) {
        await guard(reporter, "moments-graduation", `${c.label} moment #${id}`, () => retryMoment({ client, c, id, t, sender, reporter, state, simAccount, gasLimit }));
      }
    });
  }
  if (logsLookback <= 0n) return;
  for (const c of cohorts) {
    await guard(reporter, "moments-graduation", `${c.label} (GraduationFailed log scan)`, async () => {
      const range = await lookbackRange(client, logsLookback);
      const logs = await getLogsChunked(client, { address: c.collect, event: momentCollectAbi.find((x) => x.name === "GraduationFailed"), ...range, chunk: logsChunk });
      for (const l of logs) {
        reporter.alert({ job: "moments-graduation", target: `${c.label} moment #${l.args.momentId}`, severity: "warning", reason: `GraduationFailed emitted in block ${l.blockNumber} (tx ${l.transactionHash})` });
      }
    });
  }
}

// ------------------------------------------------------------------------------------------------ MO-2

/** Executes every due buyback round (bounded by its own simulation) and watches each cohort's idle locker USDC. */
export async function buybacksJob({ client, cohorts, sender, reporter, simAccount = DEFAULT_SIM_ACCOUNT, slippageBps = 50n, lockerIdleAlert = 50_000_000n, gasLimit = 3_000_000n }) {
  const t = await now(client);
  for (const c of cohorts) {
    await guard(reporter, "buybacks", c.label, async () => {
      const count = await client.readContract({ address: c.factory, abi: momentsFactoryAbi, functionName: "momentCount" });
      const [minAmount, minInterval] = await Promise.all([
        client.readContract({ address: c.buyback, abi: momentBuybackAbi, functionName: "MIN_AMOUNT" }),
        client.readContract({ address: c.buyback, abi: momentBuybackAbi, functionName: "MIN_INTERVAL" }),
      ]);
      for (let id = 1n; id <= count; id++) {
        const target = `${c.label} moment #${id}`;
        await guard(reporter, "buybacks", target, async () => {
          const s = Number(await client.readContract({ address: c.collect, abi: momentCollectAbi, functionName: "state", args: [id] }));
          if (s !== MOMENT_STATE.Graduated) return;
          const [accrued, carry, lastRun] = await Promise.all([
            client.readContract({ address: c.hook, abi: momentFeeHookAbi, functionName: "buybackAccrued", args: [id] }),
            client.readContract({ address: c.buyback, abi: momentBuybackAbi, functionName: "carry", args: [id] }),
            client.readContract({ address: c.buyback, abi: momentBuybackAbi, functionName: "lastRun", args: [id] }),
          ]);
          const d = decideBuyback({ state: s, accrued, carry, lastRun: BigInt(lastRun), now: t, minAmount, minInterval });
          if (d.action !== "execute") return;
          const sim = await simulate(client, { address: c.buyback, abi: momentBuybackAbi, functionName: "execute", args: [id, 0n], account: simAccount, gas: gasLimit });
          if (!sim.ok) {
            reporter.alert({ job: "buybacks", target, severity: "warning", reason: `execute() due (budget ${d.budget}) but simulation reverts: ${sim.error}` });
            return;
          }
          const minCoinOut = minOutWithSlippage(sim.result.coinBought, slippageBps);
          reporter.action({ job: "buybacks", target, what: `execute(id, ${minCoinOut}) budget ${d.budget}` });
          const gas = await gasFor(client, { address: c.buyback, abi: momentBuybackAbi, functionName: "execute", args: [id, minCoinOut], account: simAccount }, gasLimit);
          await safeSend(sender, reporter, "buybacks", target, { to: c.buyback, signature: "execute(uint256,uint256)", args: [id, minCoinOut], gasLimit: gas, label: `buyback ${target}` });
        });
      }
      const idle = await client.readContract({ address: c.usdc, abi: erc20Abi, functionName: "balanceOf", args: [c.locker] });
      const li = decideLockerIdle({ lockerUsdc: idle, alertAbove: lockerIdleAlert });
      if (li.action === "alert") reporter.alert({ job: "buybacks", target: `${c.label} locker`, severity: li.severity, reason: li.reason });
    });
  }
}

// ------------------------------------------------------------------------------------------------ Launchpad helpers

async function allLaunches(client, factory, page = 100n) {
  const n = await client.readContract({ address: factory, abi: launchpadFactoryAbi, functionName: "launchCount" });
  const out = [];
  for (let off = 0n; off < n; off += page) {
    const tokens = await client.readContract({ address: factory, abi: launchpadFactoryAbi, functionName: "getLaunches", args: [off, page] });
    out.push(...tokens);
  }
  return out;
}

/** A launch record in the current shape; the legacy (0xad3d) record has no venue: every launch graduates on Monday. */
async function launchRecord(client, lp, token) {
  if (lp.legacyRecord) {
    const l = await client.readContract({ address: lp.factory, abi: launchpadFactoryLegacyAbi, functionName: "getLaunchedToken", args: [token] });
    return { ...l, graduationVenue: VENUE.Monday };
  }
  return client.readContract({ address: lp.factory, abi: launchpadFactoryAbi, functionName: "getLaunchedToken", args: [token] });
}

// ------------------------------------------------------------------------------------------------ LP-2

/**
 * Sweeps hook fees of every graduated Uniswap v4 pool: holder-sharing quote fees once they are worth the sweep's gas
 * (see decide.mjs `minHolderSweep`), other fees above `minOther`. On a v2 hook the protocol's cut of holder-sharing
 * pools sits in `pendingProtocolFees` (LP-2), which is counted too; on the live (v1) hooks that read reverts and is 0.
 */
export async function sweepsJob({ client, launchpads, sender, reporter, minOther, simAccount = DEFAULT_SIM_ACCOUNT, gasLimit = 1_500_000n }) {
  for (const lp of launchpads) {
    await guard(reporter, "sweeps", lp.label, async () => {
      if (lp.legacyRecord) return; // every launch on it graduates on Monday Trade: no hook fees
      const tokens = await allLaunches(client, lp.factory);
      reporter.info(`${lp.label}: ${tokens.length} launches`);
      const gasPrice = await gasPriceOf(client);
      for (const token of tokens) {
        await guard(reporter, "sweeps", `${lp.label} ${token}`, async () => {
          const l = await launchRecord(client, lp, token);
          if (Number(l.phase) !== LAUNCH_PHASE.PoolCreated || Number(l.graduationVenue) !== VENUE.UniswapV4) return;
          for (const currency of [l.pairToken, token]) {
            const [fee, tax, protocolOnly] = await Promise.all([
              client.readContract({ address: lp.hook, abi: memeHookAbi, functionName: "pendingFees", args: [l.poolId, currency] }),
              client.readContract({ address: lp.hook, abi: memeHookAbi, functionName: "pendingCreatorTax", args: [l.poolId, currency] }),
              readOr(client, { address: lp.hook, abi: memeHookV2Abi, functionName: "pendingProtocolFees", args: [l.poolId, currency] }, 0n),
            ]);
            const pending = fee + tax + protocolOnly;
            const isQuote = currency.toLowerCase() === l.pairToken.toLowerCase();
            const req = { address: lp.hook, abi: memeHookAbi, functionName: "sweepPoolFees", args: [l.poolId, currency], account: simAccount };
            let minHolders = 1n;
            if (l.holderFeeSharing && isQuote && pending > 0n) {
              const isNative = currency === ZERO;
              const decimals = isNative ? 18 : await readOr(client, { address: currency, abi: erc20Abi, functionName: "decimals" }, 18);
              minHolders = minHolderSweep({ isNative, gasLimit: await gasFor(client, req, gasLimit), gasPrice, decimals });
            }
            const d = decideSweep({ holderFeeSharing: l.holderFeeSharing, isQuote, pending, minHolders, minOther });
            if (d.action !== "sweep") continue;
            const target = `${lp.label} ${token} (${isQuote ? "quote" : "token"} fees)`;
            // Simulate first, as the other jobs do: with a gas limit cast skips estimation, so a reverting sweep would
            // otherwise be broadcast and pay gas.
            const sim = await simulate(client, { ...req, gas: gasLimit });
            if (!sim.ok) {
              reporter.alert({ job: "sweeps", target, severity: "warning", reason: `sweepPoolFees would revert: ${sim.error}` });
              continue;
            }
            reporter.action({ job: "sweeps", target, what: `sweepPoolFees ${pending} (${d.reason})` });
            const gas = await gasFor(client, req, gasLimit);
            await safeSend(sender, reporter, "sweeps", target, { to: lp.hook, signature: "sweepPoolFees(bytes32,address)", args: [l.poolId, currency], gasLimit: gas, label: `sweep ${target}` });
          }
        });
      }
    });
  }
}

// ------------------------------------------------------------------------------------------------ LP-1

async function assessSquat(client, { mondayFactory, fee, wmon, token, pairToken, curve, mondayOnly }) {
  const quote = pairToken === ZERO ? wmon : pairToken;
  const pool = await client.readContract({ address: mondayFactory, abi: mondayFactoryAbi, functionName: "getPool", args: [token, quote, fee] });
  if (pool === ZERO) return { pool, ...assessMondaySquat({ poolExists: false }) };
  const slot0 = await client.readContract({ address: pool, abi: mondayPoolAbi, functionName: "slot0" });
  const [reserved, phantom, threshold] = await Promise.all([
    client.readContract({ address: curve, abi: bondingCurveAbi, functionName: "reservedTokens" }),
    client.readContract({ address: curve, abi: bondingCurveAbi, functionName: "phantomQuote" }),
    client.readContract({ address: curve, abi: bondingCurveAbi, functionName: "graduationThreshold" }),
  ]);
  const target = mondayTargetSqrtPriceX96({ token, quote, quoteAmount: threshold, tokenAmount: reserved, phantomQuote: phantom });
  const sqrtP = BigInt(slot0[0]);
  let ticksToCross;
  if (sqrtP !== 0n && sqrtP !== target) {
    try {
      const spacing = Number(await client.readContract({ address: mondayFactory, abi: mondayFactoryAbi, functionName: "feeAmountTickSpacing", args: [fee] }));
      const tickFrom = Number(slot0[1]);
      const tickTo = tickAtSqrtPrice(target);
      const words = new Map();
      for (const w of bitmapWordsBetween({ tickSpacing: spacing, tickFrom, tickTo })) {
        if (w < -32768 || w > 32767) continue;
        words.set(w, await client.readContract({ address: pool, abi: mondayPoolAbi, functionName: "tickBitmap", args: [w] }));
      }
      ticksToCross = countInitializedTicksBetween({ words, tickSpacing: spacing, tickFrom, tickTo });
    } catch {
      ticksToCross = undefined; // unreadable -> treated as blocking
    }
  }
  return { pool, target, sqrtP, ticksToCross, ...assessMondaySquat({ poolExists: true, sqrtPriceX96: sqrtP, targetSqrtPriceX96: target, ticksToCross, mondayOnly }) };
}

async function checkLaunch({ client, lp, token, monday, t, sender, reporter, simAccount, mondayGas, v4Gas, watchProgressBps }) {
  const l = await launchRecord(client, lp, token);
  if (Number(l.phase) !== LAUNCH_PHASE.NotGraduated) return;
  const [completed, rescued, stuckSince] = await Promise.all([
    client.readContract({ address: l.curve, abi: bondingCurveAbi, functionName: "completed" }),
    client.readContract({ address: l.curve, abi: bondingCurveAbi, functionName: "rescued" }),
    client.readContract({ address: lp.factory, abi: launchpadFactoryAbi, functionName: "stuckSince", args: [token] }),
  ]);
  const venue = Number(l.graduationVenue);
  const target = `${lp.label} ${token}`;
  // A Monday-only quote asset (aBIL) has no permissionless v4 fallback on the live factories: say so, loudly.
  const mondayOnly = venue === VENUE.Monday && !lp.legacyRecord && (await readOr(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "pairMondayOnly", args: [l.pairToken] }, false));
  const fallbackAllowed = mondayOnly && (await readOr(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "v4FallbackAllowed", args: [token] }, false));
  let squat;
  if (venue === VENUE.Monday && monday) {
    let watch = true;
    if (!completed && watchProgressBps > 0n) {
      const raised = await client.readContract({ address: l.curve, abi: bondingCurveAbi, functionName: "realQuoteReserve" });
      watch = raised * 10_000n >= l.graduationThreshold * watchProgressBps;
    }
    if (watch) {
      squat = await assessSquat(client, { ...monday, token, pairToken: l.pairToken, curve: l.curve, mondayOnly: mondayOnly && !fallbackAllowed });
      if (!completed && squat.level !== "none") {
        reporter.alert({ job: "launchpad-graduation", target, severity: squatSeverity(squat), reason: `Monday pool ${squat.pool} squatted (${squat.level}): ${squat.reason}; pool sqrtPriceX96 ${squat.sqrtP}, graduation target ${squat.target}` });
      }
    }
  }
  if (!completed || rescued) return;
  const simG = await simulate(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "graduate", args: [token], account: simAccount, gas: venue === VENUE.Monday ? mondayGas : v4Gas });
  const simF = venue === VENUE.Monday && !simG.ok
    ? await simulate(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "graduateFallback", args: [token], account: simAccount, gas: mondayGas })
    : { ok: false };
  const d = decideStuckLaunch({ phase: Number(l.phase), venue, completed, rescued, stuckSince, now: t, simGraduate: simG.ok, simFallback: simF.ok, mondayOnly, v4FallbackAllowed: fallbackAllowed });
  if (d.action === "none") return;
  const extra = squat && squat.level !== "none" ? ` [Monday pool: ${squat.reason}]` : "";
  reporter.alert({ job: "launchpad-graduation", target, severity: d.severity, reason: `${d.reason}${d.rescueAt ? `; owner rescue possible from ${d.rescueAt}` : ""}${extra}` });
  // Monday graduation and the fallback keep a fixed, high gas limit on purpose: the realign swap must get as much gas
  // as one transaction allows (and the v2 graduateFallback refuses less than ~22.1M).
  if (d.action === "graduate") {
    reporter.action({ job: "launchpad-graduation", target, what: "graduate(token)" });
    const gas = venue === VENUE.Monday ? mondayGas : await gasFor(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "graduate", args: [token], account: simAccount }, v4Gas);
    await safeSend(sender, reporter, "launchpad-graduation", target, { to: lp.factory, signature: "graduate(address)", args: [token], gasLimit: gas, label: `graduate ${target}` });
  } else if (d.action === "graduateFallback") {
    reporter.action({ job: "launchpad-graduation", target, what: "graduateFallback(token)" });
    await safeSend(sender, reporter, "launchpad-graduation", target, { to: lp.factory, signature: "graduateFallback(address)", args: [token], gasLimit: mondayGas, label: `fallback ${target}` });
  }
}

/**
 * Watches Monday-venue launches for squatted Monday pools BEFORE they complete (alert: pre-align or steer the
 * creator), and retries graduation of completed-but-stuck launches (plain graduate first, then the v4 fallback).
 */
export async function launchpadGraduationJob({ client, launchpads, sender, reporter, simAccount = DEFAULT_SIM_ACCOUNT, mondayGas = 25_000_000n, v4Gas = 3_000_000n, watchProgressBps = 0n }) {
  const t = await now(client);
  for (const lp of launchpads) {
    await guard(reporter, "launchpad-graduation", lp.label, async () => {
      // The legacy factory keeps its Monday executor in the graduationExecutor slot and has no mondayExecutor().
      const mondayExec = lp.legacyRecord
        ? lp.graduationExecutor
        : await readOr(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "mondayExecutor" }, ZERO);
      let monday;
      if (mondayExec && mondayExec !== ZERO) {
        const [mf, wmon, fee] = await Promise.all([
          client.readContract({ address: mondayExec, abi: mondayExecutorAbi, functionName: "factory" }),
          client.readContract({ address: mondayExec, abi: mondayExecutorAbi, functionName: "wmon" }),
          client.readContract({ address: mondayExec, abi: mondayExecutorAbi, functionName: "FEE" }),
        ]);
        monday = { mondayFactory: mf, wmon, fee };
      }
      const tokens = await allLaunches(client, lp.factory);
      for (const token of tokens) {
        await guard(reporter, "launchpad-graduation", `${lp.label} ${token}`, () =>
          checkLaunch({ client, lp, token, monday, t, sender, reporter, simAccount, mondayGas, v4Gas, watchProgressBps }),
        );
      }
    });
  }
}

// ------------------------------------------------------------------------------------------------ governance watch

// Every owner/governance action that could redirect money or swap code, per contract kind.
const LAUNCHPAD_GOV_EVENTS = ["ModulesSet", "MondayExecutorSet", "OwnershipTransferStarted", "FeePolicySet", "LaunchFeeSet", "PairEconomicsSet", "PairMondayOnlySet", "WhitelistSet", "LaunchConfigEnabled"];
const VAULT_GOV_EVENTS = ["LpFeeRecipientSet", "OwnershipTransferStarted"];
const MOMENTS_GOV_EVENTS = ["GovernanceTransferStarted", "PolicyProposed", "PublishingPaused", "ExternalBaseURISet"];

function events(abi, names) {
  return abi.filter((x) => x.type === "event" && names.includes(x.name));
}

const eqAddr = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();

/** At most one alert per `key` per day (the state file remembers when), for standing conditions that would otherwise
    page on every run. */
function throttled(state, key, t, fn) {
  const last = BigInt(state[key]?.lastAlert ?? 0);
  if (t - last < DAY) return;
  state[key] = { lastAlert: Number(t) };
  fn();
}

/**
 * Governance watch (2026-09-26 ops audit): the governance key (a plain EOA, SEC-1) can still swap modules on a factory
 * with no launch, repoint fees, and propose Moments policies. This job compares every factory's and vault's roles and
 * modules with the deployment records (critical on any drift), flags a launchpad whose modules are not frozen yet,
 * pending ownership/governance transfers and policy proposals, and, with `logsLookback`, every governance event.
 * `expected` = { owner, treasury, feesRecipient, momentsGovernance, externalBaseURI } from the live records.
 */
export async function governanceJob({ client, launchpads, cohorts, reporter, state, expected, logsLookback = 0n, logsChunk = 100n }) {
  const t = await now(client);
  const job = "governance";
  const critical = (target, reason) => reporter.alert({ job, target, severity: "critical", reason });
  for (const lp of launchpads) {
    await guard(reporter, job, lp.label, async () => {
      const read = (functionName) => client.readContract({ address: lp.factory, abi: launchpadFactoryAbi, functionName });
      const modules = [
        ["hook", "hook"],
        ["graduationExecutor", "graduationExecutor"],
        ["locker", "locker"],
        ["escrow", "escrow"],
        ["holderFeeSharing", "holderFeeSharing"],
        ["router", "launchAndBuyRouter"],
        ["launchDeployer", "launchDeployer"],
        ...(lp.legacyRecord ? [] : [["mondayExecutor", "mondayExecutor"]]),
      ];
      for (const [fn, key] of modules) {
        const onChain = await read(fn);
        if (lp[key] && !eqAddr(onChain, lp[key])) critical(lp.label, `module ${fn}() is ${onChain}, the record says ${lp[key]}: a module was swapped`);
      }
      const [owner, pendingOwner, recipient, count] = await Promise.all([read("owner"), read("pendingOwner"), read("protocolFeeRecipient"), read("launchCount")]);
      if (!eqAddr(owner, expected.owner)) critical(lp.label, `owner() is ${owner}, expected ${expected.owner}`);
      if (!eqAddr(pendingOwner, ZERO)) critical(lp.label, `an ownership transfer to ${pendingOwner} is pending`);
      if (!eqAddr(recipient, expected.treasury)) critical(lp.label, `protocolFeeRecipient() is ${recipient}, expected ${expected.treasury}`);
      const sealed = await readOr(client, { address: lp.factory, abi: launchpadFactoryV2Abi, functionName: "modulesSealed" }, false);
      if (count === 0n && !sealed) {
        throttled(state, `gov:${lp.factory.toLowerCase()}:unfrozen`, t, () =>
          reporter.alert({ job, target: lp.label, severity: "warning", reason: "no launch yet and modules not sealed: the owner key can still replace any module, and the first launch freezes whatever is set. Close the factory or freeze it with a canary launch (owner runbook)" }),
        );
      }
      if (lp.feeVault && !eqAddr(lp.feeVault, ZERO)) {
        const v = (functionName) => client.readContract({ address: lp.feeVault, abi: mondayFeeVaultAbi, functionName });
        const [vOwner, vPending, vRecipient] = await Promise.all([v("owner"), v("pendingOwner"), v("lpFeeRecipient")]);
        const target = `${lp.label} fee vault`;
        if (!eqAddr(vOwner, expected.owner)) critical(target, `owner() is ${vOwner}, expected ${expected.owner}`);
        if (!eqAddr(vPending, ZERO)) critical(target, `an ownership transfer to ${vPending} is pending`);
        if (!eqAddr(vRecipient, expected.feesRecipient)) critical(target, `lpFeeRecipient() is ${vRecipient}, expected ${expected.feesRecipient}`);
      }
    });
  }
  for (const c of cohorts) {
    await guard(reporter, job, c.label, async () => {
      const read = (functionName) => client.readContract({ address: c.factory, abi: momentsFactoryAbi, functionName });
      const [gov, pendingGov, pendingAt, paused] = await Promise.all([read("governance"), read("pendingGovernance"), read("pendingPolicyAt"), read("publishingPaused")]);
      if (!eqAddr(gov, expected.momentsGovernance)) critical(c.label, `governance() is ${gov}, expected ${expected.momentsGovernance}`);
      if (!eqAddr(pendingGov, ZERO)) critical(c.label, `a governance transfer to ${pendingGov} is pending`);
      if (BigInt(pendingAt) !== 0n) {
        reporter.alert({ job, target: c.label, severity: BigInt(pendingAt) <= t ? "critical" : "warning", reason: `a policy proposal is pending, applicable from ${pendingAt}: check it is intended, or cancel it` });
      }
      if (!c.live && !paused) critical(c.label, "a retired cohort is publishing again (its policy pays retired wallets)");
      if (c.live && expected.externalBaseURI !== undefined) {
        const base = await read("externalBaseURI");
        if (base !== expected.externalBaseURI) critical(c.label, `externalBaseURI() is "${base}", expected "${expected.externalBaseURI}"`);
      }
    });
  }
  if (logsLookback <= 0n) return;
  await guard(reporter, job, "governance event scan", async () => {
    const range = await lookbackRange(client, logsLookback);
    const scans = [
      [launchpads.map((l) => l.factory), events(launchpadFactoryAbi, LAUNCHPAD_GOV_EVENTS)],
      [launchpads.map((l) => l.feeVault).filter((a) => a && !eqAddr(a, ZERO)), events(mondayFeeVaultAbi, VAULT_GOV_EVENTS)],
      [cohorts.map((c) => c.factory), events(momentsFactoryAbi, MOMENTS_GOV_EVENTS)],
    ];
    for (const [address, evs] of scans) {
      if (address.length === 0) continue;
      const logs = await getLogsChunked(client, { address, events: evs, ...range, chunk: logsChunk });
      for (const l of logs) critical(l.address, `governance event ${l.eventName} in block ${l.blockNumber} (tx ${l.transactionHash})`);
    }
  });
}
