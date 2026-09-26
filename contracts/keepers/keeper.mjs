#!/usr/bin/env node
// DyorHQ keepers for the LIVE (immutable, v1) Launchpad and Moments contracts on Monad. Dry run by default: reads
// chain state, simulates each permissionless call and prints the exact `cast send` it would run. `--send` executes
// them through Foundry `cast` with a keystore / Foundry account / Ledger — never a raw private key.
//
//   node contracts/keepers/keeper.mjs <job...> [options]
//   jobs: moments-graduation (MO-1) | buybacks (MO-2) | sweeps (LP-2) | launchpad-graduation (LP-1) | all
//
// Exit codes: 0 = nothing needs a human, 2 = alert(s) raised, 1 = the keeper failed. See keepers/README.md.
import { parseArgs } from "node:util";
import { createPublicClient, http } from "viem";
import { momentsCohorts, launchpads } from "./lib/deployments.mjs";
import { makeSender, assertNoKeyEnv } from "./lib/send.mjs";
import { makeReporter, postWebhook, loadState, saveState, EXIT } from "./lib/report.mjs";
import { momentsGraduationJob, buybacksJob, sweepsJob, launchpadGraduationJob } from "./lib/jobs.mjs";

const JOBS = ["moments-graduation", "buybacks", "sweeps", "launchpad-graduation"];

const { values: o, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    "rpc-url": { type: "string", default: process.env.MONAD_RPC_URL || "https://rpc.monad.xyz" },
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
    "watch-progress-bps": { type: "string", default: "0" },
    "only-live": { type: "boolean", default: false },
    help: { type: "boolean", short: "h", default: false },
  },
});

if (o.help || positionals.length === 0) {
  console.log(`usage: node contracts/keepers/keeper.mjs <${JOBS.join("|")}|all>... [--send --keystore FILE|--account NAME|--ledger] [--rpc-url URL]\nsee contracts/keepers/README.md`);
  process.exit(o.help ? 0 : 1);
}

async function main() {
  assertNoKeyEnv(); // even in dry-run: a key in the environment is a mistake worth stopping on
  const jobs = positionals.includes("all") ? JOBS : positionals;
  for (const j of jobs) if (!JOBS.includes(j)) throw new Error(`unknown job ${j}`);

  const client = createPublicClient({ transport: http(o["rpc-url"]) });
  const signer = o.keystore
    ? { keystore: o.keystore, passwordFile: o["password-file"] }
    : o.account
      ? { account: o.account, passwordFile: o["password-file"] }
      : o.ledger
        ? { ledger: true, hdPath: o["hd-path"] }
        : o.unlocked
          ? { unlocked: o.unlocked }
          : {};
  const sender = makeSender({ send: o.send, rpcUrl: o["rpc-url"], signer, allowUnlocked: o["allow-unlocked"] });
  const reporter = makeReporter();
  const state = loadState(o["state-file"]);
  let cohorts = momentsCohorts(o.deployments);
  let pads = launchpads(o.deployments);
  if (o["only-live"]) {
    cohorts = cohorts.filter((c) => c.label.includes("live"));
    pads = pads.filter((p) => p.label.includes("live"));
  }
  const common = { client, sender, reporter, state, simAccount: o["sim-from"] || undefined };

  console.log(`keeper: ${jobs.join(", ")} · ${o.send ? "SEND" : "dry-run"} · rpc ${o["rpc-url"]}`);
  for (const job of jobs) {
    console.log(`== ${job}`);
    if (job === "moments-graduation") await momentsGraduationJob({ ...common, cohorts, logsLookback: BigInt(o["logs-lookback"]) });
    if (job === "buybacks") await buybacksJob({ ...common, cohorts, slippageBps: BigInt(o["slippage-bps"]), lockerIdleAlert: BigInt(o["locker-idle-alert"]) });
    if (job === "sweeps") await sweepsJob({ ...common, launchpads: pads, minOther: o["min-sweep-other"] ? BigInt(o["min-sweep-other"]) : undefined });
    if (job === "launchpad-graduation") await launchpadGraduationJob({ ...common, launchpads: pads, watchProgressBps: BigInt(o["watch-progress-bps"]) });
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
    console.error(`keeper failed: ${e?.stack || e}`);
    process.exit(EXIT.ERROR);
  },
);
