// Alerts and run state. Alerts always go to stdout; with KEEPER_WEBHOOK_URL set they are also POSTed as JSON
// (Slack/Discord-compatible `text` field plus structured `alerts`). The process exit code tells a scheduler what
// happened: 0 = nothing needs a human, 2 = at least one alert, 1 = the keeper itself failed.
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeSync } from "node:fs";
import { basename, dirname } from "node:path";

export const EXIT = Object.freeze({ OK: 0, ERROR: 1, ALERT: 2 });

/** `scrub` is applied to every alert reason before it is stored, printed or posted (see redact.mjs): an RPC error can
    quote the endpoint URL, and with it an API key. */
export function makeReporter({ log = console.log, scrub = (s) => s } = {}) {
  const alerts = [];
  const actions = [];
  return {
    alerts,
    actions,
    info: (msg) => log(scrub(`  ${msg}`)),
    action: (a) => {
      actions.push(a);
      log(scrub(`ACTION ${a.job} ${a.target}: ${a.what}`));
    },
    alert: (a) => {
      const clean = { ...a, reason: scrub(a.reason) };
      alerts.push(clean);
      log(`ALERT [${clean.severity}] ${clean.job} ${clean.target}: ${clean.reason}`);
    },
  };
}

export async function postWebhook(url, alerts, { fetchImpl = globalThis.fetch, prefix = "" } = {}) {
  if (!url || alerts.length === 0) return;
  const text = alerts.map((a) => `[${a.severity}] ${a.job} ${a.target}: ${a.reason}`).join("\n");
  const body = JSON.stringify({ text: `${prefix}DyorHQ keeper: ${alerts.length} alert(s)\n${text}`, alerts }, (_, v) => (typeof v === "bigint" ? v.toString() : v));
  const res = await fetchImpl(url, { method: "POST", headers: { "content-type": "application/json" }, body, signal: AbortSignal.timeout(15_000) });
  if (!res.ok) throw new Error(`webhook POST failed: ${res.status}`); // never echoes the webhook URL
}

// ------------------------------------------------------------------------------------------------ run state
//
// A small JSON file per scheduled unit: per-target failure counters, alert throttles, and (build 17) the spend ledger,
// log-scan cursors and alert history. Losing it silently would reset the daily spend cap and re-scan or skip blocks,
// so it is written atomically (temp file, fsync, rename) and a file that cannot be parsed is moved aside and reported,
// never silently replaced.

export const STATE_VERSION = 1;

function stamp(ms) {
  return new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
}

/**
 * Reads the state file. A missing file is a first run. A file that does not parse, is not a JSON object, or was
 * written by a newer keeper (`version` above STATE_VERSION) is renamed to `<file>.corrupt-<time>` and `onProblem`
 * gets a sentence for a warning alert; the run then starts from an empty state. A file that cannot be read at all
 * (permissions) throws: the run fails instead of forgetting.
 */
export function loadState(file, { onProblem = () => {}, now = Date.now } = {}) {
  if (!file) return { version: STATE_VERSION };
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch (e) {
    if (e.code === "ENOENT") return { version: STATE_VERSION };
    throw new Error(`state file ${basename(file)} cannot be read (${e.code ?? e.message})`);
  }
  let why;
  let state;
  try {
    state = JSON.parse(text);
    if (!state || typeof state !== "object" || Array.isArray(state)) why = "not a JSON object";
    else if (state.version !== undefined && !(Number.isInteger(state.version) && state.version >= 1 && state.version <= STATE_VERSION)) {
      why = `version ${JSON.stringify(state.version)}, this keeper reads up to ${STATE_VERSION}`;
    }
  } catch (e) {
    why = `invalid JSON: ${e.message.split("\n")[0]}`;
  }
  if (!why) return { ...state, version: STATE_VERSION }; // a file from before build 17 has no version: it is version 1
  const aside = `${file}.corrupt-${stamp(now())}`;
  let moved = true;
  try {
    renameSync(file, aside);
  } catch {
    moved = false;
  }
  onProblem(`state file ${basename(file)} was unreadable (${why}); ${moved ? `moved aside to ${basename(aside)}` : "could not be moved aside"}. Failure counters, the spend ledger, alert history and log cursors start over from this run`);
  return { version: STATE_VERSION };
}

/** Writes the state atomically: a crash or a full disk leaves the previous file whole. */
export function saveState(file, state) {
  if (!file) return;
  const dir = dirname(file);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = `${file}.tmp-${process.pid}`;
  const body = `${JSON.stringify({ ...state, version: STATE_VERSION }, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2)}\n`;
  let fd;
  try {
    fd = openSync(tmp, "w", 0o600);
    writeSync(fd, body);
    fsyncSync(fd);
    closeSync(fd);
    fd = undefined;
    renameSync(tmp, file);
  } catch (e) {
    if (fd !== undefined) {
      try {
        closeSync(fd);
      } catch {}
    }
    rmSync(tmp, { force: true });
    throw new Error(`state file ${basename(file)} could not be written (${e.code ?? e.message})`);
  }
  try {
    // Make the rename itself durable. Not every platform can fsync a directory; the file is complete either way.
    const dfd = openSync(dir, "r");
    try {
      fsyncSync(dfd);
    } finally {
      closeSync(dfd);
    }
  } catch {}
}
