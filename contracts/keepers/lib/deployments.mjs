// Every live and retired deployment the keepers cover, read from contracts/deployments/*.json (the records are
// the source of truth; nothing is hard-coded here). Retired deployments stay covered: their graduations, sweeps
// and buybacks are permissionless and holders there are just as exposed.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const DEPLOYMENTS = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "deployments");

const MOMENTS_FILES = [
  ["moments-143.json", "cohort3 (live)"],
  ["moments-143-cohort2.json", "cohort2 (retired)"],
  ["moments-143-cohort1.json", "cohort1 (retired)"],
  ["moments-143-v1.1-preview.json", "v1.1-preview (= cohort1)"],
  ["moments-143-v1.json", "v1 (retired)"],
];

const LAUNCHPAD_FILES = [
  ["143.json", "launchpad (live)"],
  ["143-retired-0x10F3.json", "launchpad 0x10F3 (retired)"],
];

function read(dir, file) {
  return JSON.parse(readFileSync(join(dir, file), "utf8"));
}

/** Moments cohorts, de-duplicated by collect address (v1.1-preview is the cohort-1 record). */
export function momentsCohorts(dir = DEPLOYMENTS) {
  const seen = new Set();
  const out = [];
  for (const [file, label] of MOMENTS_FILES) {
    let d;
    try {
      d = read(dir, file);
    } catch {
      continue;
    }
    const k = d.collect.toLowerCase();
    if (seen.has(k)) continue;
    seen.add(k);
    out.push({ label, file, ...d });
  }
  return out;
}

export function launchpads(dir = DEPLOYMENTS) {
  const out = [];
  for (const [file, label] of LAUNCHPAD_FILES) {
    try {
      out.push({ label, file, ...read(dir, file) });
    } catch {
      /* optional */
    }
  }
  return out;
}
