#!/usr/bin/env node
// DyorHQ keepers for the LIVE (immutable, v1) Launchpad and Moments contracts on Monad. Dry run by default: reads
// chain state, simulates each permissionless call and prints the exact `cast send` it would run. `--send` executes
// them through Foundry `cast` with a keystore / Foundry account / Ledger — never a raw private key.
//
//   node contracts/keepers/keeper.mjs <job...> [options]
//   jobs: moments-graduation (MO-1) | buybacks (MO-2) | sweeps (LP-2) | launchpad-graduation (LP-1) | governance | all
//
// Exit codes: 0 = nothing needs a human, 2 = alert(s) raised, 1 = the keeper failed. See keepers/README.md.
import { parseArgs } from "node:util";
import { createPublicClient, http, formatEther, parseEther } from "viem";
import { momentsCohorts, launchpads, pinMismatches } from "./lib/deployments.mjs";
import { makeSender, assertNoKeyEnv } from "./lib/send.mjs";
import { makeReporter, postWebhook, loadState, saveState, EXIT } from "./lib/report.mjs";
import { redact, rpcLabel } from "./lib/redact.mjs";
import { momentsGraduationJob, buybacksJob, sweepsJob, launchpadGraduationJob, governanceJob } from "./lib/jobs.mjs";

const JOBS = ["moments-graduation", "buybacks", "sweeps", "launchpad-graduation", "governance"];
// The metadata base the live Moments cohort was set to at the 2026-09-23 relaunch.
const LIVE_EXTERNAL_BASE_URI = "https://dyorhq.fun/moments/";

const { values: o, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    // rpc3 served every read of a full run on 2026-09-27; rpc1 rate-limited a single run after ~20 reads, and
    // rpc.monad.xyz caps eth_getLogs at 100 blocks (the scans adapt to that).
    "rpc-url": { type: "string", default: process.env.MONAD_RPC_URL || "https://rpc3.monad.xyz" },
    send: { type: "boolean", default: false },
    keystore: { type: "string" },
    "password-file": { type: "string" },
    account: { type: "string" },
    ledger: { type: "boolean", default: false },
    "hd-path": { type: "string" },
    unlocked: { type: "string" },
    "allow-unlocked": { type: "boolean", default: false },
    "sim-from": { type: "string", default: process.env.KEEPER_ADDRESS },
    "state-file": { type: "string", default: process.env.KEEPER_STATE_FILE },
    webhook: { type: "string", default: process.env.KEEPER_WEBHOOK_URL },
    deployments: { type: "string" },
    "slippage-bps": { type: "string", default: "50" },
    "locker-idle-alert": { type: "string", default: "50000000" },
    "min-sweep-other": { type: "string" },
    "logs-lookback": { type: "string", default: "0" },
    "logs-chunk": { type: "string", default: "100" },
    "watch-progress-bps": { type: "string", default: "0" },
    "min-balance": { type: "string", default: "2" },
    "only-live": { type: "boolean", default: false },
    help: { type: "boolean", short: "h", default: false },
  },
});

if (o.help || positionals.length === 0) {
  console.log(`usage: node contracts/keepers/keeper.mjs <${JOBS.join("|")}|all>... [--send --keystore FILE|--account NAME|--ledger] [--rpc-url URL]\nsee contracts/keepers/README.md`);
  process.exit(o.help ? 0 : 1);
}

// Nothing printed, logged or posted may carry the RPC or webhook URL (either can embed an API key).
const scrub = (s) => redact(s, [o["rpc-url"], o.webhook]);
const log = (s) => console.log(scrub(s));

async function main() {
  assertNoKeyEnv(); // even in dry-run: a key in the environment is a mistake worth stopping on
  const jobs = positionals.includes("all") ? JOBS : positionals;
  for (const j of jobs) if (!JOBS.includes(j)) throw new Error(`unknown job ${j}`);

  const client = createPublicClient({ transport: http(o["rpc-url"], { retryCount: 3, retryDelay: 500 }) });
  const signer = o.keystore
    ? { keystore: o.keystore, passwordFile: o["password-file"] }
    : o.account
      ? { account: o.account, passwordFile: o["password-file"] }
      : o.ledger
        ? { ledger: true, hdPath: o["hd-path"] }
        : o.unlocked
          ? { unlocked: o.unlocked }
          : {};
  const sender = makeSender({ send: o.send, rpcUrl: o["rpc-url"], signer, allowUnlocked: o["allow-unlocked"], log });
  const reporter = makeReporter({ log: console.log, scrub });
  const state = loadState(o["state-file"]);
  // Missing, unreadable or wrong-chain LIVE records throw here: the run fails loudly instead of skipping them.
  let cohorts = momentsCohorts(o.deployments);
  let pads = launchpads(o.deployments);
  const liveLaunchpad = pads.find((p) => p.live);
  const liveCohort = cohorts.find((c) => c.live);
  if (o["only-live"]) {
    cohorts = cohorts.filter((c) => c.live);
    pads = pads.filter((p) => p.live);
  }
  const common = { client, sender, reporter, state, simAccount: o["sim-from"] || undefined };
  const logsLookback = BigInt(o["logs-lookback"]);
  const logsChunk = BigInt(o["logs-chunk"]);

  console.log(`keeper: ${jobs.join(", ")} · ${o.send ? "SEND" : "dry-run"} · rpc ${rpcLabel(o["rpc-url"])}`);
  for (const m of pinMismatches({ cohorts: [liveCohort], pads: [liveLaunchpad] })) {
    reporter.alert({ job: "records", target: m.file, severity: "critical", reason: `live record names factory ${m.recorded} but the keeper pins ${m.pinned}: a deploy script or a hand edit replaced the record` });
  }
  for (const r of [liveLaunchpad, liveCohort]) {
    // An RPC error here is left to the jobs (they alert on every failed read); only a definite "no code" alerts.
    const code = await client.getCode({ address: r.factory }).catch(() => null);
    if (code !== null && (!code || code === "0x")) reporter.alert({ job: "records", target: r.file, severity: "critical", reason: `no contract code at the recorded factory ${r.factory} on this RPC` });
  }
  if (o["sim-from"]) {
    const bal = await client.getBalance({ address: o["sim-from"] }).catch(() => undefined);
    if (bal !== undefined && bal < parseEther(o["min-balance"])) {
      reporter.alert({ job: "keeper", target: o["sim-from"], severity: "warning", reason: `keeper balance ${formatEther(bal)} MON is below --min-balance ${o["min-balance"]} MON: graduation retries may stop` });
    }
  }
  for (const job of jobs) {
    console.log(`== ${job}`);
    try {
      if (job === "moments-graduation") await momentsGraduationJob({ ...common, cohorts, logsLookback, logsChunk });
      if (job === "buybacks") await buybacksJob({ ...common, cohorts, slippageBps: BigInt(o["slippage-bps"]), lockerIdleAlert: BigInt(o["locker-idle-alert"]) });
      if (job === "sweeps") await sweepsJob({ ...common, launchpads: pads, minOther: o["min-sweep-other"] ? BigInt(o["min-sweep-other"]) : undefined });
      if (job === "launchpad-graduation") await launchpadGraduationJob({ ...common, launchpads: pads, watchProgressBps: BigInt(o["watch-progress-bps"]) });
      if (job === "governance") {
        const expected = {
          owner: liveLaunchpad.owner,
          treasury: liveLaunchpad.treasury,
          feesRecipient: liveLaunchpad.feesRecipient,
          momentsGovernance: liveCohort.governance,
          externalBaseURI: LIVE_EXTERNAL_BASE_URI,
        };
        await governanceJob({ ...common, launchpads: pads, cohorts, expected, logsLookback, logsChunk });
      }
    } catch (e) {
      // A job-level failure (e.g. the RPC is down) is reported and the next job still runs.
      reporter.alert({ job, target: "job", severity: "critical", reason: `job failed: ${e?.shortMessage || e?.message || e}` });
    }
  }
  saveState(o["state-file"], state);
  const serious = reporter.alerts.filter((a) => a.severity !== "info");
  await postWebhook(o.webhook, serious);
  console.log(`done: ${reporter.actions.length} action(s), ${reporter.alerts.length} alert(s) (${serious.length} warning/critical)`);
  return serious.length ? EXIT.ALERT : EXIT.OK;
}

main().then(
  (code) => process.exit(code),
  (e) => {
    console.error(`keeper failed: ${scrub(e?.stack || e)}`);
    process.exit(EXIT.ERROR);
  },
);
