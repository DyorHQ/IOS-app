// One keeper run, from parsed options (lib/options.mjs) to an exit code. keeper.mjs is only the command-line wrapper,
// so every rule here is tested with a mocked chain, sender and webhook (test/run.test.mjs).
//
// Build 17, K1 ("sends are honest"):
//  - E7: in send mode the sending address is derived from the signer itself; a different --sim-from refuses the run,
//    and the balance check always runs for the address that pays.
//  - E6: the state file is loaded and written atomically; a corrupt one is a warning, moved aside.
//  - E9: the run has a deadline (--max-runtime): past it the run stops sending, saves its state, raises a critical
//    alert and exits 1. A watchdog (--role watchdog) never sends and marks every post.
import { createPublicClient, http, formatEther, parseEther } from "viem";
import { momentsCohorts, launchpads, pinMismatches } from "./deployments.mjs";
import { makeSender, assertNoKeyEnv, signerAddress } from "./send.mjs";
import { makeReporter, postWebhook, loadState, saveState, EXIT } from "./report.mjs";
import { redact, rpcLabel } from "./redact.mjs";
import { momentsGraduationJob, buybacksJob, sweepsJob, launchpadGraduationJob, governanceJob } from "./jobs.mjs";

// The metadata base the live Moments cohort (v2, cohort 4) was deployed with: part of its terms hash, and what the app
// reads as cohort c4 in a Moment's link.
export const LIVE_EXTERNAL_BASE_URI = "https://dyorhq.fun/moments/c4/";

function defaultClient(o) {
  return createPublicClient({ transport: http(o.rpcUrl, { retryCount: 3, retryDelay: 500 }) });
}

const errText = (e) => (e?.shortMessage || e?.message || String(e)).split("\n")[0];
const eqAddr = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();

/**
 * Runs the keeper. `deps` replaces the outside world in tests: `log`, `env`, `makeClient(o)`, `makeSenderFn`,
 * `signerAddressFn`, `fetchImpl` and `now` (ms). Resolves to an exit code (EXIT); throws when the keeper itself
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
  // Nothing printed, logged or posted may carry the RPC or webhook URL (either can embed an API key).
  const scrub = (s) => redact(s, [o.rpcUrl, o.webhook]);
  const say = (s) => log(scrub(s));
  if (o.role === "watchdog" && o.send) throw new Error("--role watchdog never sends: drop --send");
  assertNoKeyEnv(env); // even in dry-run: a key in the environment is a mistake worth stopping on
  const prefix = o.role === "watchdog" ? "[watchdog] " : "";
  const reporter = makeReporter({ log, scrub });
  const run = { state: undefined, stopped: false, current: "setup" };

  const work = async () => {
    run.state = loadState(o.stateFile, {
      now,
      onProblem: (why) => reporter.alert({ job: "keeper", target: "state file", severity: "warning", reason: why }),
    });
    const state = run.state;
    const client = makeClient(o);
    const inner = makeSenderFn({ send: o.send, rpcUrl: o.rpcUrl, signer: o.signer, allowUnlocked: o.allowUnlocked, log: say });
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
    const common = { client, sender, reporter, state, simAccount: simFrom };

    log(`keeper: ${o.jobs.join(", ")} · ${o.send ? "SEND" : "dry-run"}${o.role === "watchdog" ? " · watchdog" : ""} · rpc ${rpcLabel(o.rpcUrl)}${simFrom ? ` · from ${simFrom}` : ""}`);
    run.current = "records";
    for (const m of pinMismatches({ cohorts: [liveCohort], pads: [liveLaunchpad] })) {
      reporter.alert({ job: "records", target: m.file, severity: "critical", reason: `live record names factory ${m.recorded} but the keeper pins ${m.pinned}: a deploy script or a hand edit replaced the record` });
    }
    for (const r of [liveLaunchpad, liveCohort]) {
      // An RPC error here is left to the jobs (they alert on every failed read); only a definite "no code" alerts.
      const code = await client.getCode({ address: r.factory }).catch(() => null);
      if (code !== null && (!code || code === "0x")) reporter.alert({ job: "records", target: r.file, severity: "critical", reason: `no contract code at the recorded factory ${r.factory} on this RPC` });
    }
    if (simFrom) {
      run.current = "balance";
      let bal;
      try {
        bal = await client.getBalance({ address: simFrom });
      } catch (e) {
        reporter.alert({ job: "keeper", target: simFrom, severity: "warning", reason: `the keeper balance could not be read: ${errText(e)}` });
      }
      if (bal !== undefined) {
        reporter.info(`keeper ${simFrom}: ${formatEther(bal)} MON`);
        if (bal < parseEther(o.minBalance)) {
          reporter.alert({ job: "keeper", target: simFrom, severity: "warning", reason: `keeper balance ${formatEther(bal)} MON is below --min-balance ${o.minBalance} MON: graduation retries may stop` });
        }
      }
    }
    for (const job of o.jobs) {
      if (run.stopped) break;
      run.current = job;
      log(`== ${job}`);
      try {
        if (job === "moments-graduation") await momentsGraduationJob({ ...common, cohorts, logsLookback: o.logsLookback, logsChunk: o.logsChunk });
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
          await governanceJob({ ...common, launchpads: pads, cohorts, expected, logsLookback: o.logsLookback, logsChunk: o.logsChunk });
        }
      } catch (e) {
        // A job-level failure (e.g. the RPC is down) is reported and the next job still runs.
        reporter.alert({ job, target: "job", severity: "critical", reason: `job failed: ${e?.shortMessage || e?.message || e}` });
      }
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
    reporter.alert({ job: "keeper", target: "run", severity: "critical", reason: `the run exceeded --max-runtime ${o.maxRuntime}s during ${run.current} and was stopped before it finished: check the RPC and the host` });
  }
  if (run.state) saveState(o.stateFile, run.state);
  const serious = reporter.alerts.filter((a) => a.severity !== "info");
  await postWebhook(o.webhook, serious, { fetchImpl, prefix });
  log(`done: ${reporter.actions.length} action(s), ${reporter.alerts.length} alert(s) (${serious.length} warning/critical)`);
  if (outcome === "overrun") return EXIT.ERROR;
  return serious.length ? EXIT.ALERT : EXIT.OK;
}
