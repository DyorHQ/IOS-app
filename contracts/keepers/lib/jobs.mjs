// The four keeper jobs. Each takes a viem-like `client` (readContract / simulateContract / getBlock / getLogs /
// getBlockNumber), the deployment records, a `sender` (dry-run by default, see send.mjs), a `reporter` and a
// mutable `state` object, so every job runs unchanged against Monad, a local anvil, or a mock in the tests.
import {
  momentsFactoryAbi,
  momentsFactoryV1Abi,
  momentCollectAbi,
  momentGraduationAbi,
  momentFeeHookAbi,
  momentBuybackAbi,
  launchpadFactoryAbi,
  bondingCurveAbi,
  mondayExecutorAbi,
  mondayFactoryAbi,
  mondayPoolAbi,
  memeHookAbi,
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
  decideStuckLaunch,
  mondayTargetSqrtPriceX96,
  tickAtSqrtPrice,
  bitmapWordsBetween,
  countInitializedTicksBetween,
  assessMondaySquat,
} from "./decide.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
const DEFAULT_SIM_ACCOUNT = "0x000000000000000000000000000000000000dEaD";

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

// ------------------------------------------------------------------------------------------------ MO-1

/** Retries graduation of every GraduationPending Moment in every cohort; alerts on each (and on GraduationFailed logs). */
export async function momentsGraduationJob({ client, cohorts, sender, reporter, state, simAccount = DEFAULT_SIM_ACCOUNT, logsLookback = 0n, logsChunk = 500n, gasLimit = 5_000_000n }) {
  const t = await now(client);
  for (const c of cohorts) {
    let count;
    try {
      count = await client.readContract({ address: c.factory, abi: momentsFactoryAbi, functionName: "momentCount" });
    } catch (e) {
      reporter.alert({ job: "moments-graduation", target: c.label, severity: "critical", reason: `cannot read momentCount: ${errText(e)}` });
      continue;
    }
    reporter.info(`${c.label}: ${count} moments`);
    for (let id = 1n; id <= count; id++) {
      const s = Number(await client.readContract({ address: c.collect, abi: momentCollectAbi, functionName: "state", args: [id] }));
      if (s !== MOMENT_STATE.GraduationPending) continue;
      const ledger = await client.readContract({ address: c.collect, abi: momentCollectAbi, functionName: "ledger", args: [id] });
      let m;
      try {
        m = await client.readContract({ address: c.factory, abi: momentsFactoryAbi, functionName: "getMoment", args: [id] });
      } catch {
        m = await client.readContract({ address: c.factory, abi: momentsFactoryV1Abi, functionName: "getMoment", args: [id] });
      }
      const sim = await simulate(client, { address: c.graduation, abi: momentGraduationAbi, functionName: "graduate", args: [id], account: simAccount, gas: gasLimit });
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
        await safeSend(sender, reporter, "moments-graduation", target, { to: c.graduation, signature: "graduate(uint256)", args: [id], gasLimit, label: `graduate ${target}` });
      }
    }
    if (logsLookback > 0n) {
      const head = await client.getBlockNumber();
      const from = head > logsLookback ? head - logsLookback : 0n;
      for (let start = from; start <= head; start += logsChunk) {
        const end = start + logsChunk - 1n < head ? start + logsChunk - 1n : head;
        const logs = await client.getLogs({ address: c.collect, event: momentCollectAbi.find((x) => x.name === "GraduationFailed"), fromBlock: start, toBlock: end });
        for (const l of logs) {
          reporter.alert({ job: "moments-graduation", target: `${c.label} moment #${l.args.momentId}`, severity: "warning", reason: `GraduationFailed emitted in block ${l.blockNumber} (tx ${l.transactionHash})` });
        }
      }
    }
  }
}

// ------------------------------------------------------------------------------------------------ MO-2

/** Executes every due buyback round (bounded by its own simulation) and watches each cohort's idle locker USDC. */
export async function buybacksJob({ client, cohorts, sender, reporter, simAccount = DEFAULT_SIM_ACCOUNT, slippageBps = 50n, lockerIdleAlert = 50_000_000n, gasLimit = 3_000_000n }) {
  const t = await now(client);
  for (const c of cohorts) {
    const count = await client.readContract({ address: c.factory, abi: momentsFactoryAbi, functionName: "momentCount" });
    const [minAmount, minInterval] = await Promise.all([
      client.readContract({ address: c.buyback, abi: momentBuybackAbi, functionName: "MIN_AMOUNT" }),
      client.readContract({ address: c.buyback, abi: momentBuybackAbi, functionName: "MIN_INTERVAL" }),
    ]);
    for (let id = 1n; id <= count; id++) {
      const s = Number(await client.readContract({ address: c.collect, abi: momentCollectAbi, functionName: "state", args: [id] }));
      if (s !== MOMENT_STATE.Graduated) continue;
      const [accrued, carry, lastRun] = await Promise.all([
        client.readContract({ address: c.hook, abi: momentFeeHookAbi, functionName: "buybackAccrued", args: [id] }),
        client.readContract({ address: c.buyback, abi: momentBuybackAbi, functionName: "carry", args: [id] }),
        client.readContract({ address: c.buyback, abi: momentBuybackAbi, functionName: "lastRun", args: [id] }),
      ]);
      const d = decideBuyback({ state: s, accrued, carry, lastRun: BigInt(lastRun), now: t, minAmount, minInterval });
      if (d.action !== "execute") continue;
      const target = `${c.label} moment #${id}`;
      const sim = await simulate(client, { address: c.buyback, abi: momentBuybackAbi, functionName: "execute", args: [id, 0n], account: simAccount, gas: gasLimit });
      if (!sim.ok) {
        reporter.alert({ job: "buybacks", target, severity: "warning", reason: `execute() due (budget ${d.budget}) but simulation reverts: ${sim.error}` });
        continue;
      }
      const minCoinOut = minOutWithSlippage(sim.result.coinBought, slippageBps);
      reporter.action({ job: "buybacks", target, what: `execute(id, ${minCoinOut}) budget ${d.budget}` });
      await safeSend(sender, reporter, "buybacks", target, { to: c.buyback, signature: "execute(uint256,uint256)", args: [id, minCoinOut], gasLimit, label: `buyback ${target}` });
    }
    const idle = await client.readContract({ address: c.usdc, abi: erc20Abi, functionName: "balanceOf", args: [c.locker] });
    const li = decideLockerIdle({ lockerUsdc: idle, alertAbove: lockerIdleAlert });
    if (li.action === "alert") reporter.alert({ job: "buybacks", target: `${c.label} locker`, severity: li.severity, reason: li.reason });
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

// ------------------------------------------------------------------------------------------------ LP-2

/** Sweeps hook fees of every graduated Uniswap v4 pool: always for holder-sharing quote fees, others above a floor. */
export async function sweepsJob({ client, launchpads, sender, reporter, minOther, simAccount = DEFAULT_SIM_ACCOUNT, gasLimit = 1_500_000n }) {
  for (const lp of launchpads) {
    const tokens = await allLaunches(client, lp.factory);
    reporter.info(`${lp.label}: ${tokens.length} launches`);
    for (const token of tokens) {
      const l = await client.readContract({ address: lp.factory, abi: launchpadFactoryAbi, functionName: "getLaunchedToken", args: [token] });
      if (Number(l.phase) !== LAUNCH_PHASE.PoolCreated || Number(l.graduationVenue) !== VENUE.UniswapV4) continue;
      for (const currency of [l.pairToken, token]) {
        const [fee, tax] = await Promise.all([
          client.readContract({ address: lp.hook, abi: memeHookAbi, functionName: "pendingFees", args: [l.poolId, currency] }),
          client.readContract({ address: lp.hook, abi: memeHookAbi, functionName: "pendingCreatorTax", args: [l.poolId, currency] }),
        ]);
        const isQuote = currency.toLowerCase() === l.pairToken.toLowerCase();
        const d = decideSweep({ holderFeeSharing: l.holderFeeSharing, isQuote, pending: fee + tax, minOther });
        if (d.action !== "sweep") continue;
        const target = `${lp.label} ${token} (${isQuote ? "quote" : "token"} fees)`;
        // Simulate first, as the other jobs do: with a fixed gas limit cast skips estimation, so a reverting sweep would
        // otherwise be broadcast and pay gas.
        const sim = await simulate(client, { address: lp.hook, abi: memeHookAbi, functionName: "sweepPoolFees", args: [l.poolId, currency], account: simAccount, gas: gasLimit });
        if (!sim.ok) {
          reporter.alert({ job: "sweeps", target, severity: "warning", reason: `sweepPoolFees would revert: ${sim.error}` });
          continue;
        }
        reporter.action({ job: "sweeps", target, what: `sweepPoolFees ${fee + tax} (${d.reason})` });
        await safeSend(sender, reporter, "sweeps", target, { to: lp.hook, signature: "sweepPoolFees(bytes32,address)", args: [l.poolId, currency], gasLimit, label: `sweep ${target}` });
      }
    }
  }
}

// ------------------------------------------------------------------------------------------------ LP-1

async function assessSquat(client, { mondayFactory, fee, wmon, token, pairToken, curve }) {
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
  return { pool, target, sqrtP, ticksToCross, ...assessMondaySquat({ poolExists: true, sqrtPriceX96: sqrtP, targetSqrtPriceX96: target, ticksToCross }) };
}

/**
 * Watches Monday-venue launches for squatted Monday pools BEFORE they complete (alert: pre-align or steer the
 * creator), and retries graduation of completed-but-stuck launches (plain graduate first, then the v4 fallback).
 */
export async function launchpadGraduationJob({ client, launchpads, sender, reporter, simAccount = DEFAULT_SIM_ACCOUNT, mondayGas = 25_000_000n, v4Gas = 3_000_000n, watchProgressBps = 0n }) {
  const t = await now(client);
  for (const lp of launchpads) {
    const mondayExec = await client.readContract({ address: lp.factory, abi: launchpadFactoryAbi, functionName: "mondayExecutor" });
    let monday;
    if (mondayExec !== ZERO) {
      const [mf, wmon, fee] = await Promise.all([
        client.readContract({ address: mondayExec, abi: mondayExecutorAbi, functionName: "factory" }),
        client.readContract({ address: mondayExec, abi: mondayExecutorAbi, functionName: "wmon" }),
        client.readContract({ address: mondayExec, abi: mondayExecutorAbi, functionName: "FEE" }),
      ]);
      monday = { mondayFactory: mf, wmon, fee };
    }
    const tokens = await allLaunches(client, lp.factory);
    for (const token of tokens) {
      const l = await client.readContract({ address: lp.factory, abi: launchpadFactoryAbi, functionName: "getLaunchedToken", args: [token] });
      if (Number(l.phase) !== LAUNCH_PHASE.NotGraduated) continue;
      const [completed, rescued, stuckSince] = await Promise.all([
        client.readContract({ address: l.curve, abi: bondingCurveAbi, functionName: "completed" }),
        client.readContract({ address: l.curve, abi: bondingCurveAbi, functionName: "rescued" }),
        client.readContract({ address: lp.factory, abi: launchpadFactoryAbi, functionName: "stuckSince", args: [token] }),
      ]);
      const venue = Number(l.graduationVenue);
      const target = `${lp.label} ${token}`;
      let squat;
      if (venue === VENUE.Monday && monday) {
        let watch = true;
        if (!completed && watchProgressBps > 0n) {
          const raised = await client.readContract({ address: l.curve, abi: bondingCurveAbi, functionName: "realQuoteReserve" });
          watch = raised * 10_000n >= l.graduationThreshold * watchProgressBps;
        }
        if (watch) {
          squat = await assessSquat(client, { ...monday, token, pairToken: l.pairToken, curve: l.curve });
          if (!completed && squat.level !== "none") {
            const severity = squat.level === "blocking" ? "critical" : squat.level === "heavy" ? "warning" : "info";
            reporter.alert({ job: "launchpad-graduation", target, severity, reason: `Monday pool ${squat.pool} squatted (${squat.level}): ${squat.reason}; pool sqrtPriceX96 ${squat.sqrtP}, graduation target ${squat.target}` });
          }
        }
      }
      if (!completed || rescued) continue;
      const simG = await simulate(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "graduate", args: [token], account: simAccount, gas: venue === VENUE.Monday ? mondayGas : v4Gas });
      const simF = venue === VENUE.Monday && !simG.ok
        ? await simulate(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "graduateFallback", args: [token], account: simAccount, gas: mondayGas })
        : { ok: false };
      const d = decideStuckLaunch({ phase: Number(l.phase), venue, completed, rescued, stuckSince, now: t, simGraduate: simG.ok, simFallback: simF.ok });
      if (d.action === "none") continue;
      const extra = squat && squat.level !== "none" ? ` [Monday pool: ${squat.reason}]` : "";
      reporter.alert({ job: "launchpad-graduation", target, severity: d.severity, reason: `${d.reason}${d.rescueAt ? `; owner rescue possible from ${d.rescueAt}` : ""}${extra}` });
      if (d.action === "graduate") {
        reporter.action({ job: "launchpad-graduation", target, what: "graduate(token)" });
        await safeSend(sender, reporter, "launchpad-graduation", target, { to: lp.factory, signature: "graduate(address)", args: [token], gasLimit: venue === VENUE.Monday ? mondayGas : v4Gas, label: `graduate ${target}` });
      } else if (d.action === "graduateFallback") {
        reporter.action({ job: "launchpad-graduation", target, what: "graduateFallback(token)" });
        await safeSend(sender, reporter, "launchpad-graduation", target, { to: lp.factory, signature: "graduateFallback(address)", args: [token], gasLimit: mondayGas, label: `fallback ${target}` });
      }
    }
  }
}
