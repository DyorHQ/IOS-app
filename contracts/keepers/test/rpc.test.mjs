// Build 17, K2 / E5: RPC resilience. Reads fall back across the --rpc-url list (rpc3 -> rpc4); cast sends through the
// first endpoint that answers as chain 143; an RPC failure is never read as a chain answer, and a run's RPC failures
// are posted as one "RPC degraded" warning (critical after 3 runs in a row), not one critical per item. The research
// run on rpc1 raised 11 criticals for one rate limit.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HttpRequestError, TimeoutError } from "viem";
import { isTransportError, makeRpcClient, firstHealthy, rpcDegradedAlert, DEFAULT_RPC_URLS } from "../lib/rpc.mjs";
import { getLogsChunked, momentsGraduationJob } from "../lib/jobs.mjs";
import { makeReporter, EXIT } from "../lib/report.mjs";
import { makeSender } from "../lib/send.mjs";
import { parseKeeperArgs } from "../lib/options.mjs";
import { runKeeper } from "../lib/run.mjs";
import { redact } from "../lib/redact.mjs";

const http429 = () => new HttpRequestError({ url: "https://rpc1.monad.xyz/?key=FAKE_KEY_123", status: 429, body: {} });

test("E5: RPC failures are told apart from chain answers", () => {
  assert.equal(isTransportError(http429()), true);
  assert.equal(isTransportError(new TimeoutError({ body: {}, url: "https://rpc3.monad.xyz" })), true);
  assert.equal(isTransportError(Object.assign(new Error("ContractFunctionExecutionError"), { cause: Object.assign(new Error("CallExecutionError"), { cause: http429() }) })), true, "wrapped by readContract");
  assert.equal(isTransportError(Object.assign(new Error("fetch failed"), { cause: { code: "ECONNRESET" } })), true);
  assert.equal(isTransportError(new Error("429 Too Many Requests")), true);
  assert.equal(isTransportError(new Error("execution reverted: PriceMoved")), false);
  assert.equal(isTransportError(Object.assign(new Error("RPC Request failed."), { details: "eth_getLogs is limited to a 100 range" })), false);
  assert.equal(isTransportError(Object.assign(new Error("RPC Request failed."), { code: -32062, details: "Block range is too large" })), false);
  assert.equal(isTransportError(new Error('The contract function "state" returned no data ("0x"). args: (503)')), false, "a Moment id is not a status code");
  assert.equal(isTransportError(new Error("unmocked read 0xabc:launchMondayOnly:0x1")), false);
});

test("E5: a configured RPC URL is shown by its origin in logs and alerts (a key in it never is)", () => {
  const urls = ["https://rpc3.monad.xyz", "https://monad.example/v2/FAKE_KEY_123"];
  assert.equal(redact("rpc https://rpc3.monad.xyz failed 3", urls), "rpc https://rpc3.monad.xyz failed 3");
  assert.equal(redact("POST https://monad.example/v2/FAKE_KEY_123 failed", urls), "POST https://monad.example/… failed");
  assert.equal(redact("token FAKE_KEY_123", ["FAKE_KEY_123"]), "token [redacted]");
});

test("E5: --rpc-url repeats; the default is rpc3 then rpc4, or MONAD_RPC_URL alone", () => {
  assert.deepEqual(parseKeeperArgs(["governance"], {}).rpcUrls, [...DEFAULT_RPC_URLS]);
  assert.deepEqual(DEFAULT_RPC_URLS, ["https://rpc3.monad.xyz", "https://rpc4.monad.xyz"]);
  assert.deepEqual(parseKeeperArgs(["governance"], { MONAD_RPC_URL: "https://a.example" }).rpcUrls, ["https://a.example"]);
  const o = parseKeeperArgs(["governance", "--rpc-url", "https://a.example", "--rpc-url", "https://b.example"], {});
  assert.deepEqual(o.rpcUrls, ["https://a.example", "https://b.example"]);
  assert.equal(o.rpcUrl, "https://a.example");
});

async function server(handler) {
  const s = createServer((req, res) => {
    let body = "";
    req.on("data", (d) => (body += d)).on("end", () => handler(JSON.parse(body || "{}"), res));
  });
  await new Promise((r) => s.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${s.address().port}`, close: () => s.close() };
}
const answer = (result) => (req, res) => {
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({ jsonrpc: "2.0", id: req.id, result }));
};

test("E5: reads fall back to the next endpoint when the first fails, and each endpoint's failures are counted", async () => {
  const down = await server((req, res) => (res.writeHead(503), res.end("down")));
  const up = await server(answer("0x10"));
  try {
    const { client, stats } = makeRpcClient([`${down.url}/v2/FAKE_KEY_123`, up.url]);
    assert.equal(await client.getBlockNumber({ cacheTime: 0 }), 16n);
    const labels = Object.keys(stats);
    assert.deepEqual(labels, [`${down.url}/…`, up.url], "stats are keyed by label, never the keyed URL");
    assert.ok(stats[labels[0]].failed >= 1);
    assert.ok(stats[labels[1]].served >= 1);
  } finally {
    down.close();
    up.close();
  }
});

test("E5: cast sends through the first endpoint that answers as chain 143", async () => {
  const replies = {
    "https://a.example": () => Promise.reject(new Error("fetch failed")),
    "https://b.example": async () => ({ ok: true, json: async () => ({ result: "0x1" }) }), // another chain
    "https://c.example": async () => ({ ok: true, json: async () => ({ result: "0x8f" }) }),
  };
  const fetchImpl = (url) => replies[url]();
  assert.deepEqual(await firstHealthy(Object.keys(replies), { fetchImpl }), { url: "https://c.example", healthy: true });
  assert.deepEqual(await firstHealthy(["https://a.example", "https://b.example"], { fetchImpl }), { url: "https://a.example", healthy: false }, "none: the first, and the sends alert on their own");
});

test("E5: RPC failures collapse into one alert per run: a warning, critical after 3 runs in a row, reset by a clean run", () => {
  const state = {};
  const one = rpcDegradedAlert(state, { failures: 11, skipped: ["cohort4 (live)", "launchpad (live)"], stats: { "https://rpc1.monad.xyz": { failed: 33, served: 20 } } });
  assert.equal(one.severity, "warning");
  assert.equal(one.key, "rpc:degraded");
  assert.match(one.reason, /RPC degraded: 11 read\(s\) failed after retries and fallback \(https:\/\/rpc1\.monad\.xyz failed 33, served 20\); skipped this run: cohort4 \(live\), launchpad \(live\)\. 1 run\(s\) in a row/);
  assert.equal(rpcDegradedAlert(state, { failures: 1 }).severity, "warning");
  assert.equal(rpcDegradedAlert(state, { failures: 1 }).severity, "critical");
  assert.equal(rpcDegradedAlert(state, { failures: 0 }), null);
  assert.equal(state.rpc.degradedRuns, 0);
  assert.equal(rpcDegradedAlert(state, { failures: 2 }).severity, "warning");
});

test("E5: a simulation that fails at the RPC is not read as a revert (no REVERTS page, no failure counted)", async () => {
  const cohort = { label: "cohort4 (live)", factory: "0x00000000000000000000000000000000000000f1", collect: "0x00000000000000000000000000000000000000c1", graduation: "0x0000000000000000000000000000000000000091" };
  const reads = { momentCount: 1n, state: 1, ledger: { stuckSince: 1n }, getMoment: { deadline: 2_000_000_000n } };
  const client = {
    getBlock: async () => ({ timestamp: 1_790_000_000n }),
    readContract: async ({ functionName }) => reads[functionName],
    simulateContract: async () => {
      throw http429();
    },
  };
  const reporter = makeReporter({ log: () => {} });
  const state = {};
  const sender = makeSender({ rpcUrl: "http://x", log: () => {} });
  await momentsGraduationJob({ client, cohorts: [cohort], sender, reporter, state });
  assert.equal(reporter.alerts.length, 1);
  assert.equal(reporter.alerts[0].rpc, true);
  assert.doesNotMatch(reporter.alerts[0].reason, /REVERTS/);
  assert.equal(state[`moment:${cohort.collect}:1`], undefined, "no failure recorded against the Moment");
  assert.equal(sender.sent.length, 0);
});

test("E5: a rate limit on eth_getLogs is not a range cap: the scan does not shrink its chunk, it fails the read", async () => {
  const calls = [];
  const client = {
    async getLogs(req) {
      calls.push(req);
      throw new Error("429 Too Many Requests");
    },
  };
  await assert.rejects(getLogsChunked(client, { from: 0n, to: 999n, chunk: 1000n }), /429/);
  assert.equal(calls.length, 1);
});

test("E5 through a run: every read failing at the RPC posts ONE 'RPC degraded' alert, with each skipped item on stdout", async () => {
  const lines = [];
  const posts = [];
  const client = {
    getCode: async () => {
      throw http429();
    },
    getBlock: async () => {
      throw http429();
    },
    getBlockNumber: async () => {
      throw http429();
    },
    readContract: async () => {
      throw http429();
    },
  };
  const stateFile = join(mkdtempSync(join(tmpdir(), "keeper-rpc-")), "state.json");
  const deps = {
    log: (l) => lines.push(l),
    env: {},
    makeClient: () => ({ client, stats: { "https://rpc3.monad.xyz": { failed: 12, served: 0 }, "https://rpc4.monad.xyz": { failed: 12, served: 0 } } }),
    fetchImpl: async (url, init) => (posts.push(JSON.parse(init.body)), { ok: true, status: 204 }),
  };
  const o = parseKeeperArgs(["moments-graduation", "buybacks", "--webhook", "https://hooks.example/x", "--state-file", stateFile], {});
  const severities = [];
  for (let run = 1; run <= 3; run++) {
    posts.length = 0;
    assert.equal(await runKeeper(o, deps), EXIT.ALERT);
    assert.equal(posts.length, 1);
    assert.deepEqual(posts[0].alerts.map((x) => x.target), ["rpc"], JSON.stringify(posts[0].alerts));
    severities.push(posts[0].alerts[0].severity);
  }
  assert.deepEqual(severities, ["warning", "warning", "critical"], "critical after 3 runs in a row (state file counter)");
  assert.match(posts[0].alerts[0].reason, /RPC degraded: \d+ read\(s\) failed after retries and fallback \(https:\/\/rpc3\.monad\.xyz failed 12, served 0; https:\/\/rpc4\.monad\.xyz failed 12, served 0\); skipped this run: 143\.json, moments-143\.json, moments-graduation \(the whole job\), buybacks \(the whole job\)/);
  assert.equal(lines.filter((l) => /^ALERT \[critical\] .*HTTP request failed/.test(l)).length, 12, "each skipped item is still in the log (4 per run)");
  assert.ok(!lines.join("\n").includes("FAKE_KEY_123") && !JSON.stringify(posts).includes("FAKE_KEY_123"), "the keyed URL in viem's error never leaks");
});
