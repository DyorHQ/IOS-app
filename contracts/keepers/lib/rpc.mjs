// RPC resilience (build 17, K2 / E5). One public RPC is not enough for an unattended keeper: rpc1 rate-limits a full
// run (11 false criticals in the research run), and any endpoint blips. So:
//  - `--rpc-url` can be repeated: reads go through viem's fallback transport (rpc3, then rpc4 by default), and cast
//    sends through the first endpoint that answers as chain 143.
//  - A read that still fails is told apart from a contract answer: an HTTP error, a timeout, a rate limit or a dropped
//    connection is an RPC failure, which skips that item for this run and is collapsed into one "RPC degraded"
//    warning per run (critical after 3 runs in a row), instead of paging once per item. A revert or a malformed answer
//    is not an RPC failure and still alerts on its own.
import { createPublicClient, fallback, http } from "viem";
import { rpcLabel } from "./redact.mjs";

export const DEFAULT_RPC_URLS = Object.freeze(["https://rpc3.monad.xyz", "https://rpc4.monad.xyz"]);
export const MONAD_CHAIN_ID = 143;
/** Consecutive degraded runs after which the RPC warning becomes critical. */
export const DEGRADED_CRITICAL_RUNS = 3;

const TRANSPORT_NAMES = new Set(["HttpRequestError", "TimeoutError", "WebSocketRequestError", "SocketClosedError"]);
// Phrases only: a bare number such as 429 or 503 could be a Moment id in a call's arguments.
const TRANSPORT_TEXT = /HTTP request failed|timed out|took too long to respond|fetch failed|socket hang up|ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|EPIPE|network error|rate.?limit|request limit reached|too many requests|status:? ?(408|429|5\d\d)\b/i;

/** Is `e` (or anything in its cause chain) a failure of the RPC transport rather than an answer from the chain? */
export function isTransportError(e) {
  for (let x = e, depth = 0; x && depth < 8; x = x.cause, depth++) {
    if (TRANSPORT_NAMES.has(x.name)) return true;
    if (typeof x.status === "number" && (x.status === 408 || x.status === 429 || x.status >= 500)) return true;
    if (typeof x.code === "string" && /^(ECONN|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|EPIPE|UND_ERR)/.test(x.code)) return true;
    const text = `${x.shortMessage ?? ""} ${x.details ?? ""} ${x.message ?? ""}`;
    // A revert is the chain answering, even when a node words it oddly.
    if (/execution reverted|revert/i.test(text)) return false;
    if (TRANSPORT_TEXT.test(text)) return true;
  }
  return false;
}

/**
 * A viem public client over `urls` (in order). `stats` counts, per endpoint label, the requests that failed on it
 * (whether or not the next endpoint then answered), for the run summary.
 */
export function makeRpcClient(urls, { timeoutMs = 15_000 } = {}) {
  if (!urls?.length) throw new Error("no --rpc-url");
  const stats = Object.fromEntries(urls.map((u) => [rpcLabel(u), { failed: 0, served: 0 }]));
  const byUrl = new Map(urls.map((u) => [u, rpcLabel(u)]));
  const client = createPublicClient({
    transport: fallback(
      urls.map((u) => http(u, { timeout: timeoutMs })),
      { retryCount: 2, retryDelay: 400 },
    ),
  });
  client.transport.onResponse?.(({ status, transport, error }) => {
    const label = byUrl.get(transport?.value?.url);
    if (!label) return;
    // A revert (an optional read the bytecode lacks) is the endpoint answering, not failing.
    if (status === "success" || !isTransportError(error)) stats[label].served++;
    else stats[label].failed++;
  });
  return { client, stats };
}

/**
 * The first endpoint that answers eth_chainId with Monad's chain id, for cast (which takes one URL). Falls back to the
 * first URL when none does: the sends then fail on their own and alert.
 */
export async function firstHealthy(urls, { fetchImpl = globalThis.fetch, timeoutMs = 5_000, chainId = MONAD_CHAIN_ID } = {}) {
  for (const url of urls) {
    try {
      const res = await fetchImpl(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
        signal: AbortSignal.timeout(timeoutMs),
      });
      if (!res.ok) continue;
      const j = await res.json();
      if (typeof j?.result === "string" && BigInt(j.result) === BigInt(chainId)) return { url, healthy: true };
    } catch {
      // next endpoint
    }
  }
  return { url: urls[0], healthy: false };
}

/**
 * Collapses this run's RPC read failures into one alert and keeps the consecutive-run counter in `state.rpc`.
 * Returns the alert to raise, or null for a clean run (which resets the counter).
 */
export function rpcDegradedAlert(state, { failures, skipped = [], stats = {} }) {
  state.rpc ??= {};
  if (failures <= 0) {
    state.rpc.degradedRuns = 0;
    return null;
  }
  const runs = (state.rpc.degradedRuns ?? 0) + 1;
  state.rpc.degradedRuns = runs;
  const endpoints = Object.entries(stats)
    .map(([label, s]) => `${label} failed ${s.failed}, served ${s.served}`) // no ":" right after a URL: redact would eat it
    .join("; ");
  const list = skipped.length ? `; skipped this run: ${skipped.slice(0, 5).join(", ")}${skipped.length > 5 ? ` and ${skipped.length - 5} more` : ""}` : "";
  return {
    job: "keeper",
    target: "rpc",
    key: "rpc:degraded",
    severity: runs >= DEGRADED_CRITICAL_RUNS ? "critical" : "warning",
    reason: `RPC degraded: ${failures} read(s) failed after retries and fallback${endpoints ? ` (${endpoints})` : ""}${list}. ${runs} run(s) in a row${runs >= DEGRADED_CRITICAL_RUNS ? ": the keeper is effectively blind" : ""}`,
  };
}
