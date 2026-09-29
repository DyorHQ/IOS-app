// One keeper run, from parsed options (lib/options.mjs) to an exit code. keeper.mjs is only the command-line wrapper,
// so every rule here is tested with a mocked chain, sender and webhook (test/run.test.mjs).
//
// Build 17, K3 ("alerts people can live with"): alerts are posted through notify.mjs (stable keys, dedup, escalation,
// repeat cadence, "resolved" after a completed job; the channel's own payload and size limit; retries; what was not
// delivered is posted by the next run and this one exits 1), the webhook URL can come from --webhook-file, and live
// sends pass the spend guard (--max-spend-per-day, per-target backoff).
//
// Build 17, K2 ("scans see every block"): reads fall back across the --rpc-url list, cast sends through the first one
// that answers as chain 143, and the run's RPC read failures become one "RPC degraded" alert (critical after 3 runs in
// a row) instead of one critical per item. The log scans take their cursor options from here, and may use half of
// --max-runtime.
//
// Build 17, K1 ("sends are honest"):
//  - E7: in send mode the sending address is derived from the signer itself; a different --sim-from refuses the run,
//    and the balance check always runs for the address that pays.
//  - E6: the state file is loaded and written atomically; a corrupt one is a warning, moved aside.
//  - E9: the run has a deadline (--max-runtime): past it the run stops sending, saves its state, raises a critical
//    alert and exits 1. A watchdog (--role watchdog) never sends and marks every post.
import { formatEther, parseEther } from "viem";
import { momentsCohorts, launchpads, pinMismatches } from "./deployments.mjs";
import { makeSender, assertNoKeyEnv, signerAddress } from "./send.mjs";
import { makeReporter, loadState, saveState, EXIT } from "./report.mjs";
import { redact, rpcLabel } from "./redact.mjs";
import { momentsGraduationJob, buybacksJob, sweepsJob, launchpadGraduationJob, governanceJob } from "./jobs.mjs";
import { makeRpcClient, firstHealthy, isTransportError, rpcDegradedAlert } from "./rpc.mjs";
import { planPosts, commitPosts, buildPayloads, deliver, webhookKind, readWebhookFile } from "./notify.mjs";

// The metadata base the live Moments cohort (v2, cohort 4) was deployed with: part of its terms hash, and what the app
// reads as cohort c4 in a Moment's link.
export const LIVE_EXTERNAL_BASE_URI = "https://dyorhq.fun/moments/c4/";

function defaultClient(o) {
  return makeRpcClient(o.rpcUrls);
}

const errText = (e) => (e?.shortMessage || e?.message || String(e)).split("\n")[0];
const eqAddr = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();

/**
 * Runs the keeper. `deps` replaces the outside world in tests: `log`, `env`, `makeClient(o)` (a viem-like client, or
 * `{ client, stats }`), `makeSenderFn`, `signerAddressFn`, `pickRpc(urls)` (the URL cast sends through), `fetchImpl`
 * and `now` (ms). Resolves to an exit code (EXIT); throws when the keeper itself
 * cannot run (the caller exits 1).
 */
export async function runKeeper(o, deps = {}) {
  const {
    log = console.log,
    env = process.env,
    makeClient = defaultClient,
    makeSenderFn = makeSender,
    signerAddressFn = signerAddress,
    fetchImpl = globalThis.fetch,
    now = Date.now,
  } = deps;
  const pickRpc = deps.pickRpc ?? ((urls) => firstHealthy(urls, { fetchImpl }));
  const rpcUrls = o.rpcUrls ?? [o.rpcUrl];
  const startedAt = now();
  if (o.role === "watchdog" && o.send) throw new Error("--role watchdog never sends: drop --send");
  assertNoKeyEnv(env); // even in dry-run: a key in the environment is a mistake worth stopping on
  // The webhook URL is a token: from --webhook-file it never sits in argv or the environment.
  const webhookUrl = o.webhook ?? (o.webhookFile ? readWebhookFile(o.webhookFile) : undefined);
  const channel = webhookUrl ? webhookKind(webhookUrl) : undefined;
  if (channel === "telegram" && !o.telegramChatId) throw new Error("a Telegram webhook needs KEEPER_TELEGRAM_CHAT_ID");
  // Nothing printed, logged or posted may carry the RPC or webhook URL (either can embed an API key).
  const scrub = (s) => redact(s, [...rpcUrls, webhookUrl]);
  const say = (s) => log(scrub(s));
  const prefix = o.role === "watchdog" ? "[watchdog] " : "";
  const reporter = makeReporter({ log, scrub });
  const run = { state: undefined, stopped: false, current: "setup", rpcStats: {}, completed: new Set() };
  // A read of the keeper's own (not a job's) that failed: an RPC failure is counted for the "RPC degraded" alert.
  const keeperReadFailed = (target, what, e) => {
    reporter.incomplete.add("keeper");
    reporter.alert({ job: "keeper", target, severity: "critical", key: `read:keeper:${target}`, reason: `${what}: ${errText(e)}`, ...(isTransportError(e) ? { rpc: true } : {}) });
  };

  const work = async () => {
    run.state = loadState(o.stateFile, {
      now,
      onProblem: (why) => reporter.alert({ job: "keeper", target: "state file", severity: "warning", key: `keeper:state:${now()}`, once: true, reason: why }),
    });
    const state = run.state;
    const made = makeClient({ ...o, rpcUrls });
    const client = made?.client ?? made;
    run.rpcStats = made?.stats ?? {};
    // cast takes one URL: the first endpoint that answers as Monad (reads fall back on their own).
    let castRpc = rpcUrls[0];
    if (o.send) {
      const pick = await pickRpc(rpcUrls);
      castRpc = pick.url;
      if (!pick.healthy) reporter.info(`no RPC answered as chain 143; cast sends through ${rpcLabel(castRpc)}`);
    }
    const inner = makeSenderFn({ send: o.send, rpcUrl: castRpc, signer: o.signer, allowUnlocked: o.allowUnlocked, log: say });
    // Once the deadline has passed nothing more is sent, even if a job is still awaiting a read.
    const sender = {
      ...inner,
      call: (tx) => {
        if (run.stopped) throw new Error("the run was stopped by --max-runtime: not sending");
        return inner.call(tx);
      },
    };
    let simFrom = o.simFrom;
    if (o.send) {
      const from = signerAddressFn(o.signer, { allowUnlocked: o.allowUnlocked });
      if (simFrom && !eqAddr(simFrom, from)) {
        throw new Error(`--sim-from ${simFrom} is not the signer's address ${from}: refusing to run (the simulations and the balance check would not be for the wallet that sends)`);
      }
      simFrom = from;
    }
    // Missing, unreadable or wrong-chain LIVE records throw here: the run fails loudly instead of skipping them.
    let cohorts = momentsCohorts(o.deployments);
    let pads = launchpads(o.deployments);
    const liveLaunchpad = pads.find((p) => p.live);
    const liveCohort = cohorts.find((c) => c.live);
    if (o.onlyLive) {
      cohorts = cohorts.filter((c) => c.live);
      pads = pads.filter((p) => p.live);
    }
    const common = { client, sender, reporter, state, simAccount: simFrom, budget: { capWei: o.maxSpendPerDay } };
    const logArgs = {
      logsLookback: o.logsLookback,
      logsChunk: o.logsChunk,
      logsCursor: o.logsCursor,
      logsFrom: o.logsFrom,
      logsMaxBlocks: o.logsMaxBlocks,
      // Scans stop starting new chunks at half the deadline, so a long catch-up never overruns the run.
      logsUntil: startedAt + (o.maxRuntime * 1000) / 2,
      logsNow: now,
    };

    log(`keeper: ${o.jobs.join(", ")} · ${o.send ? "SEND" : "dry-run"}${o.role === "watchdog" ? " · watchdog" : ""} · rpc ${rpcUrls.map(rpcLabel).join(" → ")}${o.send ? ` · cast via ${rpcLabel(castRpc)}` : ""}${simFrom ? ` · from ${simFrom}` : ""}${channel ? ` · alerts to ${channel}` : ""}`);
    if (webhookUrl && !o.stateFile) reporter.info("no --state-file: every run posts every standing alert again (no dedup)");
    run.current = "records";
    for (const m of pinMismatches({ cohorts: [liveCohort], pads: [liveLaunchpad] })) {
      reporter.alert({ job: "records", target: m.file, severity: "critical", key: `records:pin:${m.file}`, reason: `live record names factory ${m.recorded} but the keeper pins ${m.pinned}: a deploy script or a hand edit replaced the record` });
    }
    for (const r of [liveLaunchpad, liveCohort]) {
      // Only a definite "no code" alerts; an RPC failure counts toward "RPC degraded", any other error is left to the
      // jobs (they alert on every failed read).
      const code = await client.getCode({ address: r.factory }).catch((e) => {
        if (isTransportError(e)) keeperReadFailed(r.file, "the factory's code could not be read", e);
        return null;
      });
      if (code !== null && (!code || code === "0x")) reporter.alert({ job: "records", target: r.file, severity: "critical", key: `records:nocode:${r.file}`, reason: `no contract code at the recorded factory ${r.factory} on this RPC` });
    }
    if (simFrom) {
      run.current = "balance";
      let bal;
      try {
        bal = await client.getBalance({ address: simFrom });
      } catch (e) {
        if (isTransportError(e)) keeperReadFailed(simFrom, "the keeper balance could not be read", e);
        else {
          reporter.incomplete.add("keeper");
          reporter.alert({ job: "keeper", target: simFrom, severity: "warning", key: `read:keeper:${simFrom}`, reason: `the keeper balance could not be read: ${errText(e)}` });
        }
      }
      if (bal !== undefined) {
        reporter.info(`keeper ${simFrom}: ${formatEther(bal)} MON`);
        if (bal < parseEther(o.minBalance)) {
          reporter.alert({ job: "keeper", target: simFrom, severity: "warning", key: `keeper:balance:${simFrom.toLowerCase()}`, reason: `keeper balance ${formatEther(bal)} MON is below --min-balance ${o.minBalance} MON: graduation retries may stop` });
        }
      }
    }
    for (const job of o.jobs) {
      if (run.stopped) break;
      run.current = job;
      log(`== ${job}`);
      let ok = true;
      try {
        if (job === "moments-graduation") await momentsGraduationJob({ ...common, cohorts, ...logArgs });
        if (job === "buybacks") await buybacksJob({ ...common, cohorts, slippageBps: o.slippageBps, lockerIdleAlert: o.lockerIdleAlert });
        if (job === "sweeps") await sweepsJob({ ...common, launchpads: pads, minOther: o.minSweepOther });
        if (job === "launchpad-graduation") await launchpadGraduationJob({ ...common, launchpads: pads, watchProgressBps: o.watchProgressBps });
        if (job === "governance") {
          const expected = {
            owner: liveLaunchpad.owner,
            treasury: liveLaunchpad.treasury,
            feesRecipient: liveLaunchpad.feesRecipient,
            momentsGovernance: liveCohort.governance,
            externalBaseURI: LIVE_EXTERNAL_BASE_URI,
          };
          await governanceJob({ ...common, launchpads: pads, cohorts, expected, ...logArgs });
        }
      } catch (e) {
        // A job-level failure (e.g. the RPC is down) is reported and the next job still runs.
        ok = false;
        reporter.incomplete.add(job);
        reporter.alert({ job, target: "job", severity: "critical", key: `job:${job}`, reason: `job failed: ${e?.shortMessage || e?.message || e}`, ...(isTransportError(e) ? { rpc: true } : {}) });
      }
      // A job that ran to its end with every read answered: what it no longer raises has resolved.
      if (ok && !run.stopped && !reporter.incomplete.has(job)) run.completed.add(job);
    }
    return common.sender;
  };

  // E9: a hung RPC read (or anything else) must not hold the unit forever. The deadline cannot interrupt a running
  // `cast send` (it is synchronous and has its own kill timer), but it fires as soon as that returns.
  let timer;
  const deadline = new Promise((resolve) => {
    timer = setTimeout(() => resolve("overrun"), o.maxRuntime * 1000);
  });
  let outcome;
  try {
    outcome = await Promise.race([work().then(() => "done"), deadline]);
  } finally {
    clearTimeout(timer);
  }
  if (outcome === "overrun") {
    run.stopped = true;
    reporter.alert({ job: "keeper", target: "run", severity: "critical", key: "keeper:runtime", reason: `the run exceeded --max-runtime ${o.maxRuntime}s during ${run.current} and was stopped before it finished: check the RPC and the host` });
  }
  const state = run.state ?? {};
  // E5: the items an RPC failure skipped stay on stdout one by one, but are posted as a single alert.
  const rpcFailed = reporter.alerts.filter((a) => a.rpc);
  const skipped = rpcFailed.map((a) => (a.target === "job" ? `${a.job} (the whole job)` : a.target));
  const degraded = rpcDegradedAlert(state, { failures: rpcFailed.length, skipped, stats: run.rpcStats });
  if (degraded) reporter.alert(degraded);
  for (const [label, s] of Object.entries(run.rpcStats)) if (s.failed) reporter.info(`rpc ${label} failed ${s.failed}, served ${s.served}`);
  // Save before posting: the spend ledger and the cursors must survive a hung or killed post.
  if (run.state) saveState(o.stateFile, run.state);
  const serious = reporter.alerts.filter((a) => a.severity !== "info");
  let undelivered;
  if (webhookUrl) {
    // Keeper-level checks (records, balance, RPC health, the deadline) count as a completed "job" when the run ended
    // on its own and they read everything.
    const completed = new Set(run.completed);
    if (outcome === "done" && !reporter.incomplete.has("keeper")) completed.add("keeper").add("records");
    state.notify ??= {};
    state.notify.keys ??= {};
    const at = Math.floor(now() / 1000);
    const items = planPosts({ alerts: reporter.alerts, holds: reporter.holds, completed, history: state.notify.keys, now: at, repeat: o.repeat });
    if (items.length) {
      const payloads = buildPayloads({ kind: channel, items, title: `${prefix}DyorHQ keeper (${o.jobs.join(", ")})`, chatId: o.telegramChatId });
      const { delivered, error } = await deliver(webhookUrl, payloads, { kind: channel, fetchImpl });
      commitPosts(state.notify.keys, items, delivered, at);
      log(`posted ${delivered.size} of ${items.length} alert line(s) to the ${channel} webhook`);
      if (error) undelivered = scrub(error);
    } else {
      log("nothing new to post");
    }
    if (run.state) saveState(o.stateFile, run.state);
  }
  log(`done: ${reporter.actions.length} action(s), ${reporter.alerts.length} alert(s) (${serious.length} warning/critical)`);
  if (undelivered) {
    log(`keeper: alerts NOT delivered (${undelivered}); the next run posts them again`);
    return EXIT.ERROR;
  }
  if (outcome === "overrun") return EXIT.ERROR;
  return serious.length ? EXIT.ALERT : EXIT.OK;
}
