// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assert, assertEquals } from "jsr:@std/assert@1";
import { classifyCallError, classifyHttp, DEFAULT_ENDPOINTS, endpointsFromEnv, retryAfterMs } from "./endpoints.ts";

const KEYED = "https://monad.example-provider.test/v1/k3y-material-that-must-never-be-logged";

Deno.test("defaults: the four public endpoints as measured (rpc2 refuses straddles, the others clamp)", () => {
  assertEquals(DEFAULT_ENDPOINTS.map((e) => [e.label, e.span, e.batch, e.rps, e.inFlight, e.archive, e.straddle, e.lag, e.priority]), [
    ["rpc2", 10_000, 6, 4, 8, true, "refuses", 600, 10],
    ["rpc4", 1_000, 1, 4, 2, true, "clamps", 600, 20],
    ["rpc3", 1_000, 1, 4, 2, false, "clamps", 600, 30],
    ["rpc1", 100, 1, 4, 2, true, "clamps", 600, 40],
  ]);
  for (const e of DEFAULT_ENDPOINTS) assert(/^https:\/\/rpc[1-4]\.monad\.xyz$/.test(e.url));
  assertEquals(endpointsFromEnv(undefined), { endpoints: DEFAULT_ENDPOINTS.map((e) => ({ ...e })) });
  assertEquals(endpointsFromEnv("  ").endpoints.length, 4);
});

Deno.test("MONAD_LOGS_ENDPOINTS: an array replaces the defaults", () => {
  const { endpoints, error } = endpointsFromEnv(JSON.stringify([{ url: KEYED, span: 10_000, batch: 10, rps: 20, inFlight: 8, archive: true, straddle: "refuses" }]));
  assertEquals(error, undefined);
  assertEquals(endpoints, [{ label: "custom-1", url: KEYED, span: 10_000, batch: 10, rps: 20, inFlight: 8, archive: true, straddle: "refuses", lag: 600, priority: 0 }]);
});

Deno.test("MONAD_LOGS_ENDPOINTS: append keeps the defaults as a fallback, custom entries first by priority", () => {
  const { endpoints, error } = endpointsFromEnv(JSON.stringify({ mode: "append", endpoints: [{ label: "paid", url: KEYED, maxPerDay: 100_000 }] }));
  assertEquals(error, undefined);
  assertEquals(endpoints.map((e) => e.label), ["paid", "rpc2", "rpc4", "rpc3", "rpc1"]);
  assertEquals(endpoints[0].straddle, "clamps"); // the safe class unless declared
  assertEquals(endpoints[0].maxPerDay, 100_000);
  // The launch setting: only an override of a default, no custom entry.
  const launch = endpointsFromEnv(JSON.stringify({ mode: "append", overrides: { rpc2: { rps: 2, inFlight: 4 } } }));
  assertEquals(launch.error, undefined);
  assertEquals(launch.endpoints.map((e) => [e.label, e.rps, e.inFlight]), [["rpc2", 2, 4], ["rpc4", 4, 2], ["rpc3", 4, 2], ["rpc1", 4, 2]]);
  assertEquals(launch.endpoints[0].url, "https://rpc2.monad.xyz");
  // mode defaults to append.
  assertEquals(endpointsFromEnv(JSON.stringify({ overrides: { rpc1: { lag: 1200 } } })).endpoints.find((e) => e.label === "rpc1")!.lag, 1200);
  // replace with an object.
  assertEquals(endpointsFromEnv(JSON.stringify({ mode: "replace", endpoints: [{ url: KEYED }] })).endpoints.map((e) => e.label), ["custom-1"]);
});

Deno.test("MONAD_LOGS_ENDPOINTS: anything invalid → the defaults and an error naming the field, never the URL", () => {
  const cases: [unknown, string][] = [
    [[{ url: "http://insecure.example/" + "k".repeat(20) }], "url must be https"],
    [[{ url: KEYED, span: 50 }], "span"],
    [[{ url: KEYED, span: 2_000_000 }], "span"],
    [[{ url: KEYED, batch: 0 }], "batch"],
    [[{ url: KEYED, rps: 0.1 }], "rps"],
    [[{ url: KEYED, inFlight: 17 }], "inFlight"],
    [[{ url: KEYED, lag: 50 }], "lag"],
    [[{ url: KEYED, maxPerDay: 0 }], "maxPerDay"],
    [[{ url: KEYED, archive: "yes" }], "archive"],
    [[{ url: KEYED, straddle: "maybe" }], "straddle"],
    [[{ url: KEYED, label: "Bad Label" }], "label"],
    [[{ url: KEYED, secret: "x" }], "unknown field"],
    [[{ span: 1000 }], "url is required"],
    [[{ url: KEYED, label: "a" }, { url: KEYED, label: "a" }], "unique"],
    [{ mode: "append", endpoints: [{ url: KEYED, label: "rpc2" }] }, "unique"],
    [Array.from({ length: 9 }, () => ({ url: KEYED })), "at most 8"],
    [[], "empty"],
    [{ mode: "merge" }, "mode"],
    [{ mode: "replace" }, "at least one"],
    [{ mode: "replace", endpoints: [{ url: KEYED }], overrides: {} }, "overrides"],
    [{ overrides: { rpc9: { rps: 1 } } }, "no default endpoint"],
    [{ overrides: { rpc2: { url: KEYED } } }, "url cannot be overridden"],
    [{ overrides: { rpc2: { rps: 100 } } }, "rps"],
    [{ extra: 1 }, "unknown key"],
    [42, "must be a list or an object"],
  ];
  for (const [value, field] of cases) {
    const { endpoints, error } = endpointsFromEnv(JSON.stringify(value));
    assertEquals(endpoints, DEFAULT_ENDPOINTS.map((e) => ({ ...e })), JSON.stringify(value).slice(0, 80));
    assert(error && error.includes(field), `${error} should name ${field}`);
    assert(!error.includes("k3y") && !error.includes("example"), "the error must not contain the URL");
  }
  assertEquals(endpointsFromEnv("{not json").error, "MONAD_LOGS_ENDPOINTS is not JSON");
});

Deno.test("classifyCallError: every measured message (§2, §10.1)", () => {
  const H = 111_739_139;
  const deep = { from: 100_000_000, to: 100_009_999 };
  const top = { from: H - 10, to: H + 50 };
  const c = (code: number | undefined, message: string, piece = deep) => classifyCallError({ code, message }, piece, H);
  // Throttling.
  assertEquals(c(429, "Too Many Requests"), { kind: "throttled" });
  assertEquals(c(-32005, "limit exceeded"), { kind: "throttled" });
  assertEquals(c(-32000, "rate limit exceeded, retry later"), { kind: "throttled" });
  assertEquals(c(-32000, "You have exceeded your request limit"), { kind: "throttled" });
  assertEquals(c(-32000, "exceeded 25 requests per second"), { kind: "throttled" });
  assertEquals(c(-32000, "throughput exceeded"), { kind: "throttled" });
  // Past the head: rpc2's two codes, rpc4's two texts, and the clamping endpoints' "not found" near the head.
  assertEquals(c(-32014, "block not available: block not found for eth_getLogs, requested toBlock 111739189 is not yet available on the node", top), { kind: "pastHead" });
  assertEquals(c(-32603, "ErrUpstreamBlockUnavailable: upstream does not have the requested block yet", top), { kind: "pastHead" });
  assertEquals(c(-32602, "block range extends beyond current head block", top), { kind: "pastHead" });
  assertEquals(c(-32602, "Block requested not found. Request might be querying historical state that is not available", top), { kind: "pastHead" });
  // …but "not found" deep in history is a non-archive node, not the head.
  assertEquals(c(-32602, "Block requested not found. Request might be querying historical state that is not available"), { kind: "failed" });
  // Span limits.
  assertEquals(c(-32602, "eth_getLogs is limited to a 1,000 range"), { kind: "span", span: 1000 });
  assertEquals(c(-32602, "You can make eth_getLogs requests with up to a 10000 block range"), { kind: "span", span: 10_000 });
  assertEquals(c(-32602, "Block range is too large"), { kind: "span" });
  assertEquals(c(-32602, "invalid block range params"), { kind: "span" });
  // Too dense.
  assertEquals(c(-32005, "query returned more than 10000 results"), { kind: "dense" }); // not a rate limit, whatever the code
  assertEquals(c(-32602, "query returned more than 10000 results. Try with this block range [0x5F5E100, 0x5F5E1FF]"), { kind: "dense", cut: 0x5f5e1ff });
  assertEquals(c(-32000, "too many logs"), { kind: "dense" });
  assertEquals(c(-32000, "Log response size exceeded"), { kind: "dense" });
  assertEquals(c(-32000, "response size should not greater than 10000000 bytes"), { kind: "dense" });
  // Anything else.
  assertEquals(c(-32603, "Internal error"), { kind: "failed" });
  assertEquals(c(undefined, ""), { kind: "failed" });
});

Deno.test("classifyHttp and Retry-After (seconds and a date)", () => {
  const now = Date.parse("2026-10-08T12:00:00Z");
  assertEquals(classifyHttp(429, new Headers({ "Retry-After": "2" }), "", now), { kind: "throttled", retryAfterMs: 2000 });
  assertEquals(classifyHttp(503, new Headers({ "Retry-After": "Thu, 08 Oct 2026 12:00:05 GMT" }), "", now), { kind: "throttled", retryAfterMs: 5000 });
  assertEquals(classifyHttp(429, new Headers(), "", now), { kind: "throttled", retryAfterMs: undefined });
  assertEquals(classifyHttp(403, new Headers(), '{"error":"Restricted JSON RPC method"}', now), { kind: "batchRefused" });
  assertEquals(classifyHttp(403, new Headers(), "forbidden", now), { kind: "callErrors" });
  assertEquals(classifyHttp(502, new Headers(), "", now), { kind: "unanswered" });
  assertEquals(classifyHttp(400, new Headers(), "bad", now), { kind: "callErrors" });
  assertEquals(retryAfterMs("soon", now), undefined);
  assertEquals(retryAfterMs("Thu, 08 Oct 2026 11:00:00 GMT", now), 0);
});
