// history-indexer: fills the wallet-history cache (migration 32) that history_read serves to the app, so a history
// screen reads one PostgREST call instead of minutes of capped public eth_getLogs.
//
// Called every 30 s by pg_cron → pg_net (migrations-deferred/33_history_indexer_schedule.sql) with the x-history-cron
// header, which must equal the Edge secret HISTORY_CRON_SECRET (≥ 32 characters; compared in constant time,
// auth.ts). verify_jwt = false (supabase/config.toml): the tick carries no Supabase session. The function answers 202
// at once and works in EdgeRuntime.waitUntil for at most 240 s under a database lease (history_lease), so runs never
// overlap: follow the head, backfill newest first, commit each fully answered range with its logs (history_commit),
// release (history_release). run.ts is the loop; every other file is a pure module with a test beside it.
//
// Secrets (names only): HISTORY_CRON_SECRET (required); MONAD_LOGS_ENDPOINTS (optional JSON, endpoints.ts: add a keyed
// provider later without a code change — its URL is never logged). SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are
// injected by the platform. Errors to the caller carry no detail (SB-11); the log gets one summary line per run
// (counts only, never a wallet address or a URL) and at most five short error lines.
//
// This is the only file touching Deno.env, Deno.serve, EdgeRuntime and addEventListener.
import { createClient } from "npm:@supabase/supabase-js@2";
import { cronAuthorized, MIN_SECRET_LENGTH } from "./auth.ts";
import { type HistoryDb, postgrestDb, type RunSummary } from "./db.ts";
import { endpointsFromEnv } from "./endpoints.ts";
import { runIndexer } from "./run.ts";
import { VERSION } from "./version.ts";

const ISOLATE_STARTED = Date.now();
declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

// The run this isolate is doing, so the shutdown handler can release it (best effort) and a second tick reaching the
// same isolate does not start another.
let current: { owner: string; released: boolean; db: HistoryDb } | null = null;
const signal: { shutdown?: string } = {};

addEventListener("beforeunload", (ev) => {  // CPUTime, Memory, WallClockTime, EarlyDrop, TerminationRequested, …
  const reason = String((ev as CustomEvent).detail?.reason ?? "unknown").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 30) || "unknown";
  console.log(`history-indexer: shutdown ${reason}`);
  signal.shutdown = reason;
  if (current && !current.released) {
    current.released = true;
    const stop = `shutdown:${reason}`;
    current.db.release(current.owner, null, null, { v: 2, stop } as RunSummary, null, stop).catch(() => {});
  }
});

const reply = (status: number, body?: unknown) =>
  new Response(body === undefined ? null : JSON.stringify(body), {
    status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const setTimer = (ms: number, fn: () => void) => { const t = setTimeout(fn, ms); return () => clearTimeout(t); };

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405);
  const secret = Deno.env.get("HISTORY_CRON_SECRET");
  if (!secret || secret.length < MIN_SECRET_LENGTH) {
    console.error("history-indexer: HISTORY_CRON_SECRET missing or too short");
    return reply(503);
  }
  if (!(await cronAuthorized(req.headers.get("x-history-cron"), secret))) return reply(403);
  await req.body?.cancel();
  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key || typeof EdgeRuntime === "undefined") return reply(503);
  if (current && !current.released) return reply(202, { accepted: false });
  const { endpoints, error } = endpointsFromEnv(Deno.env.get("MONAD_LOGS_ENDPOINTS"));
  if (error) console.error("history-indexer:", error, "— using the public defaults"); // names the field, never a value
  const db = postgrestDb(createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } }));
  signal.shutdown = undefined;
  EdgeRuntime.waitUntil(
    runIndexer({
      db, endpoints, fetch, now: Date.now, cpuNow: () => performance.now(), sleep, setTimer, random: Math.random,
      log: (line) => console.log(line), isolateStartedAt: ISOLATE_STARTED, version: VERSION,
      onLease: (owner) => { current = { owner, released: false, db }; },
      onRelease: () => { if (current) current.released = true; },
    }, signal).catch((err) => console.error("history-indexer: run failed", String(err).slice(0, 200))),
  );
  return reply(202, { accepted: true });
});
