// deno test --no-config --node-modules-dir=none -A supabase/functions/_shared/
import { assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { gateRefusal, rateGate } from "./rate.ts";

const cors = { "Access-Control-Allow-Origin": "*" };

Deno.test("gateRefusal: proceeds only on {ok: true}", () => {
  assertEquals(gateRefusal({ ok: true }, false, cors), null);
});

Deno.test("gateRefusal: a refusal is a 429 with Retry-After and the limit that fired", async () => {
  const res = gateRefusal({ retryAfter: 12.2, limit: "network" }, false, cors)!;
  assertEquals(res.status, 429);
  assertEquals(res.headers.get("Retry-After"), "13");
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*");
  assertEquals(await res.json(), { error: "too many requests — try again later", retryAfter: 13, limit: "network" });
  const odd = gateRefusal({ retryAfter: 0, limit: "something" }, false, cors)!;
  assertEquals(await odd.json(), { error: "too many requests — try again later", retryAfter: 1 });
  const overall = gateRefusal({ retryAfter: 600, limit: "global" }, false, cors)!;
  assertEquals((await overall.json()).limit, "global");
});

Deno.test("gateRefusal: an RPC error or an unexpected answer fails closed as a retryable 503", async () => {
  for (const [data, failed] of [[null, true], [{ ok: true }, true], [null, false], ["ok", false], [{ ok: "yes" }, false], [{ retryAfter: "9" }, false]] as const) {
    const res = gateRefusal(data, failed, cors)!;
    assertEquals(res.status, 503, JSON.stringify(data));
    assertEquals((await res.json()).retryable, true);
  }
});

Deno.test("rateGate: passes the scope, subject and network to edge_rate_gate, oneinch-proxy's scopes included", async () => {
  const calls: unknown[] = [];
  const db = { rpc: (name: string, args: unknown) => { calls.push([name, args]); return Promise.resolve({ data: { ok: true }, error: null }); } };
  for (const scope of ["oneinch", "oneinch-firm"] as const) {
    assertEquals(await rateGate(db as unknown as SupabaseClient, scope, "0xabc", "203.0.113.9", cors), null);
  }
  assertEquals(calls, [
    ["edge_rate_gate", { p_scope: "oneinch", p_subject: "0xabc", p_ip: "203.0.113.9" }],
    ["edge_rate_gate", { p_scope: "oneinch-firm", p_subject: "0xabc", p_ip: "203.0.113.9" }],
  ]);
  const throwing = { rpc: () => { throw new Error("down"); } };
  assertEquals((await rateGate(throwing as unknown as SupabaseClient, "oneinch-firm", "0xabc", null, cors))!.status, 503);
});
