// Alerts and run state. Alerts always go to stdout; with KEEPER_WEBHOOK_URL set they are also POSTed as JSON
// (Slack/Discord-compatible `text` field plus structured `alerts`). The process exit code tells a scheduler what
// happened: 0 = nothing needs a human, 2 = at least one alert, 1 = the keeper itself failed.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export const EXIT = Object.freeze({ OK: 0, ERROR: 1, ALERT: 2 });

export function makeReporter({ log = console.log } = {}) {
  const alerts = [];
  const actions = [];
  return {
    alerts,
    actions,
    info: (msg) => log(`  ${msg}`),
    action: (a) => {
      actions.push(a);
      log(`ACTION ${a.job} ${a.target}: ${a.what}`);
    },
    alert: (a) => {
      alerts.push(a);
      log(`ALERT [${a.severity}] ${a.job} ${a.target}: ${a.reason}`);
    },
  };
}

export async function postWebhook(url, alerts, { fetchImpl = globalThis.fetch } = {}) {
  if (!url || alerts.length === 0) return;
  const text = alerts.map((a) => `[${a.severity}] ${a.job} ${a.target}: ${a.reason}`).join("\n");
  const body = JSON.stringify({ text: `DyorHQ keeper: ${alerts.length} alert(s)\n${text}`, alerts }, (_, v) => (typeof v === "bigint" ? v.toString() : v));
  const res = await fetchImpl(url, { method: "POST", headers: { "content-type": "application/json" }, body });
  if (!res.ok) throw new Error(`webhook POST failed: ${res.status}`);
}

/** Tiny JSON state (per-target failure counters) so repeated failures escalate across runs. */
export function loadState(file) {
  if (!file) return {};
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return {};
  }
}

export function saveState(file, state) {
  if (!file) return;
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(state, null, 2));
}
