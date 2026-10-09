// One indexer run (§10): lease → state → head → straddle self-test → plan and read, newest first → commit → release.
// Every dependency is injected (database, endpoints, fetch, clocks, randomness), so the whole loop runs in tests on a
// virtual clock against fake endpoints and a real PGlite database (supabase/tests/history_indexer_run_test.ts).
//
// THE INVARIANT this loop serves (HistoryStore's, enforced again by history_commit): a block range is committed as
// covered only from a complete, checked answer for exactly that range, in the same transaction as its logs. Anything
// not answered — throttled, timed out, too dense, refused past the head — is re-queued, split, recorded as a hole, or
// left as a gap for the next run; it is never claimed.
import { type CommitArgs, CommitSlow, DbDown, DefsChanged, type HistoryDb, LeaseLost, Refused, Retryable, type RunSummary } from "./db.ts";
import { classifyCallError, classifyHttp, type Endpoint } from "./endpoints.ts";
import { locateFirstTx, type NonceSource, reverifyFirstTx } from "./firsttx.ts";
import { checkAnswer, type CompactLog, compactBytes, fillTimestamps, splitForCommit } from "./logs.ts";
import { ByteBudget, EndpointState, minSpanFor, type Outcome, pickEndpoint, type Priority } from "./pacing.ts";
import { DEFAULT_PLAN, type IndexerState, type PlanOptions, Planner, type WalletState, type WorkItem } from "./planner.ts";
import { type Call, type CallResult, exchange, type Exchange } from "./rpc.ts";
import { bundledDefs, defsDrift, defsFromState, filterFor, GLOBAL_SCANS, type ScanDef, type ScanId } from "./scans.ts";

const MiB = 1_048_576;

export type RunOptions = {
  workMs: number; isolateMaxMs: number; minRunMs: number; readMarginMs: number; slowReadMarginMs: number;
  leaseSeconds: number; renewMs: number; maxWallets: number; stateRefreshMs: number; jitterMs: number;
  requestTimeoutMs: number; responseCap: number; singleBlockCap: number; maxInFlightTotal: number; inFlightReserve: number;
  maxParsedBytes: number; maxLogs: number; syncBudgetMs: number; denseLogs: number; singleBlockLogs: number;
  commitLogs: number; minCommitLogs: number; commitConcurrency: number; backpressureLogs: number; backpressureCommits: number;
  coalesceItems: number; coalesceMs: number; firstTxPerRun: number; firstTxConcurrency: number; firstTxPauseMs: number;
  maxAttempts: number; maxPastHead: number; parkItems: number; headReadyMs: number; probeAttempts: number; plan: PlanOptions;
};

// The starting budgets (D21): `maxInFlightTotal`, `maxParsedBytes`, `maxLogs` and `syncBudgetMs` start low until deployed
// runs show the platform's cpu_time_used below half of the 2,000 ms limit.
export const DEFAULT_RUN_OPTIONS: RunOptions = {
  workMs: 240_000, isolateMaxMs: 340_000, minRunMs: 40_000, readMarginMs: 30_000, slowReadMarginMs: 45_000,
  leaseSeconds: 300, renewMs: 60_000, maxWallets: 2_000, stateRefreshMs: 30_000, jitterMs: 5_000,
  requestTimeoutMs: 15_000, responseCap: 3 * MiB, singleBlockCap: 8 * MiB, maxInFlightTotal: 6, inFlightReserve: 12 * MiB,
  maxParsedBytes: 8 * MiB, maxLogs: 20_000, syncBudgetMs: 1_000, denseLogs: 10_000, singleBlockLogs: 5_000,
  commitLogs: 2_000, minCommitLogs: 500, commitConcurrency: 2, backpressureLogs: 8_000, backpressureCommits: 4,
  coalesceItems: 10, coalesceMs: 15_000, firstTxPerRun: 20, firstTxConcurrency: 2, firstTxPauseMs: 2_000,
  maxAttempts: 3, maxPastHead: 3, parkItems: 32, headReadyMs: 2_000, probeAttempts: 3, plan: DEFAULT_PLAN,
};

export type Deps = {
  db: HistoryDb; endpoints: Endpoint[]; fetch: typeof fetch; now: () => number; cpuNow: () => number;
  sleep: (ms: number) => Promise<void>; random: () => number; log: (line: string) => void;
  isolateStartedAt: number; version: string;
  onLease?: (owner: string) => void; onRelease?: (stop: string) => void;
  setTimer?: (ms: number, fn: () => void) => () => void;    // a cancellable timer (default: from `sleep`)
  options?: Partial<Omit<RunOptions, "plan">> & { plan?: Partial<PlanOptions> };
};

type ItemCounts = { follow: number; global: number; window: number; deep: number; holes: number };

// The run's counters, turned into the summary at release (§10): counts only, no wallet address, no URL.
class Counters {
  requests: Record<string, number> = {};
  throttled: Record<string, number> = {};
  refused: Record<string, number> = {};
  sidelined: string[] = [];
  failed = 0; invalid = 0; dense = 0; timeouts = 0; pastHead = 0; straddleWaits = 0; dropped = 0;
  commits = 0; commitSlow = 0; commitRetries = 0; logs = 0; inserted: Record<string, number> = {}; trimmed = 0;
  holesMarked = 0; holesCleared = 0; capped = 0;
  firstTx = { found: 0, none: 0, same: 0, failed: 0, unconfirmed: 0, movedEarlier: 0 };
  straddle: Record<string, string> = {};
  globalHoles: { scan: string; from: number; to: number }[] = [];
  errors: string[] = [];
  error(line: string) { if (this.errors.length < 5) this.errors.push(line.replace(/0x[0-9a-fA-F]{40,}/g, "0x…").slice(0, 120)); }
}

type Pending = { scan: ScanId; defVersion: number; wallets: string[] | null; from: number; to: number; logs: CompactLog[];
                 pieces: number; firstAt: number; items: WorkItem[] };
type Job = { scan: ScanId; defVersion: number; wallets: string[] | null; from: number; to: number; logs: CompactLog[];
             slowRetried: boolean; retries: number; group: { remaining: number; items: WorkItem[] } };

class Stop extends Error { constructor(readonly reason: string) { super(reason); } }

const hex = (n: number) => "0x" + n.toString(16);
const quantity = (v: unknown): number | null => typeof v === "string" && /^0x[0-9a-fA-F]{1,16}$/.test(v) ? parseInt(v, 16) : null;
const NOTHING_TOPIC = "0x" + "f".repeat(64); // matches no event: the straddle self-test's filter
const throttleError = (e: { code?: number; message: string }) =>
  e.code === 429 || e.code === -32005 || /rate limit|too many requests|request limit|per second|throughput/i.test(e.message);

export async function runIndexer(deps: Deps, signal: { shutdown?: string }): Promise<RunSummary> {
  const run = new Run(deps, signal);
  return await run.go();
}

class Run {
  private readonly o: RunOptions;
  private readonly owner = crypto.randomUUID();
  private readonly started: number;
  private readonly c = new Counters();
  private stop: string | null = null;
  private states: EndpointState[] = [];
  private planner: Planner | null = null;
  private defs = new Map<ScanId, ScanDef>();
  private drift: ScanId[] = [];
  private head: number | null = null;
  private headTimestamp: number | null = null;
  private deadline = 0;           // D: the end of the work
  private readDeadline = 0;       // R: no new reads after it
  private leaseUntil = 0;
  private lastRenew = 0;
  private lastRefresh = 0;
  private stateCursor: string | null = null;
  private wallets = { active: 0, skipped: 0, refreshed: 0 };
  private syncMs = 0;
  private parsedBytes = 0;
  private logsSeen = 0;
  private requestsInFlight = 0;
  private readonly bytes: ByteBudget;
  // The look-ahead (§10): items taken from the planner that wait for an endpoint, offered again most urgent first on
  // every step, so one busy or resting endpoint never holds back work another endpoint could do now (§14). At most
  // `parkItems` of P1–P3 (the follow is never limited; it is bounded by the wallets).
  private parked: WorkItem[] = [];
  private readonly probing = new Set<EndpointState>();
  private readonly probes = new Map<EndpointState, number>();
  private readonly pending = new Map<string, Pending>();
  private readonly jobs: Job[] = [];
  private commitsInFlight = 0;
  private readonly globalCommitting = new Set<ScanId>();
  private commitLogs: number;
  private commitTimes: number[] = [];
  private uncommitted = 0;
  private waiters: (() => void)[] = [];
  private firstTxWorker: Promise<void> | null = null;

  constructor(private readonly deps: Deps, private readonly signal: { shutdown?: string }) {
    const { plan, ...rest } = deps.options ?? {};
    this.o = { ...DEFAULT_RUN_OPTIONS, ...rest, plan: { ...DEFAULT_PLAN, ...(plan ?? {}) } };
    this.started = deps.now();
    this.bytes = new ByteBudget(this.o.inFlightReserve, this.o.responseCap, this.o.singleBlockCap);
    this.commitLogs = this.o.commitLogs;
  }

  private now() { return this.deps.now(); }

  // ── Waiting ─────────────────────────────────────────────────────────────────────────────────────────────────────

  private timer(ms: number, fn: () => void): () => void {
    if (this.deps.setTimer) return this.deps.setTimer(ms, fn);
    let live = true;
    this.deps.sleep(ms).then(() => { if (live) fn(); });
    return () => { live = false; };
  }

  // Until something finishes (a request, a commit) or `ms` pass, whichever is first.
  private wait(ms = 1_000): Promise<void> {
    return new Promise((resolve) => {
      let done = false;
      const finish = () => { if (!done) { done = true; cancel(); resolve(); } };
      const cancel = this.timer(Math.max(0, Math.min(ms, 60_000)), finish);
      this.waiters.push(finish);
    });
  }

  private wake() {
    const w = this.waiters;
    this.waiters = [];
    for (const f of w) f();
  }

  private sync<T>(fn: () => T): T {
    const t = this.deps.cpuNow();
    try { return fn(); } finally { this.syncMs += Math.max(0, this.deps.cpuNow() - t); }
  }

  private setStop(reason: string) { if (!this.stop) this.stop = reason; }

  // ── The run ─────────────────────────────────────────────────────────────────────────────────────────────────────

  async go(): Promise<RunSummary> {
    const { deps, o } = this;
    let lease;
    try {
      lease = await deps.db.lease(this.owner, o.leaseSeconds, deps.version);
    } catch (err) {
      this.setStop("db");
      this.c.error(`lease: ${(err as Error).message}`);
      const summary = this.summary();
      deps.log(`history-indexer: ${JSON.stringify(summary)}`);
      return summary;
    }
    if (!lease.ok) return { v: 2, stop: lease.paused ? "paused" : "busy" }; // silent: another run holds it, or paused
    this.leaseUntil = this.now() + o.leaseSeconds * 1_000;
    this.lastRenew = this.now();
    deps.onLease?.(this.owner);
    this.states = deps.endpoints.map((e) => new EndpointState(e, lease.endpoints[e.label], this.now()));
    try {
      await this.execute();
    } catch (err) {
      this.fail(err);
    } finally {
      await this.finish();
    }
    return this.summary();
  }

  private fail(err: unknown) {
    if (err instanceof Stop) this.setStop(err.reason);
    else if (err instanceof LeaseLost) this.setStop(err.paused ? "paused" : "lease");
    else if (err instanceof DefsChanged) this.setStop("defs");
    else if (err instanceof DbDown) { this.setStop("db"); this.c.error(`db: ${err.message}`); }
    else { this.setStop("error"); this.c.error(`error: ${String((err as Error)?.message ?? err)}`); }
  }

  private async execute() {
    const { deps, o } = this;
    const now = this.now();
    this.deadline = Math.min(now + o.workMs, deps.isolateStartedAt + o.isolateMaxMs);
    if (this.deadline - now < o.minRunMs) throw new Stop("isolate");
    this.readDeadline = this.deadline - o.readMarginMs;
    await deps.sleep(Math.floor(deps.random() * o.jitterMs));

    const state = await deps.db.state(this.owner, o.maxWallets);
    this.lastRefresh = this.now();
    this.stateCursor = new Date(state.now).toISOString();
    this.wallets.active = state.active;
    this.wallets.skipped = state.skipped;
    const defs = defsFromState(state.defs);
    for (const d of defs) this.defs.set(d.id, d);
    this.drift = defsDrift(defs, bundledDefs());

    const head = await this.readHead(state.head);
    if (!head) throw new Stop("head");
    [this.head, this.headTimestamp] = head;
    await this.selfTest();

    this.planner = this.sync(() => new Planner(state, this.head!, defs, o.plan, state.now));
    this.firstTxWorker = this.firstTransactions(state.wallets);
    await this.loop();
  }

  // ── Head (finalized), with a second opinion when it jumped implausibly far ──────────────────────────────────────

  // Endpoints in priority order, ≤ 2 tries each; one resting (a Retry-After the last run remembered) is passed over
  // for the next one ready within `headReadyMs`, and waited for only when none is (a lower finalized head from a
  // clamping endpoint is safe: the follow simply starts lower).
  private async readHead(stored: number | null): Promise<[number, number] | null> {
    const tries = new Map<EndpointState, number>();
    let first: [number, number] | null = null;
    for (;;) {
      const now = this.now();
      const left = this.states.filter((s) => !s.sidelined(now) && (tries.get(s) ?? 0) < 2);
      if (left.length === 0) return first;
      const soon = left.filter((s) => s.nextStartAt(now) <= now + this.o.headReadyMs).sort((a, b) => a.endpoint.priority - b.endpoint.priority);
      const s = soon[0] ?? [...left].sort((a, b) => a.nextStartAt(now) - b.nextStartAt(now) || a.endpoint.priority - b.endpoint.priority)[0];
      tries.set(s, (tries.get(s) ?? 0) + 1);
      const got = await this.headFrom(s);
      if (!got) continue;
      tries.set(s, 2); // answered: never asked again
      if (first) return got[0] < first[0] ? got : first;
      // Plausible: no more than ~5 blocks/s over the last 10 minutes beyond the stored head. Else ask the next endpoint
      // too and take the lower (after downtime this costs one extra request).
      if (stored === null || got[0] <= stored + 5 * 600 + 1_000) return got;
      first = got;
    }
  }

  // An endpoint that answers but cannot name its latest block (an error for both tags) is broken — a key, a quota: a
  // strike (pacing.ts), so it is sidelined even when no log piece ever reaches it.
  private async headFrom(s: EndpointState): Promise<[number, number] | null> {
    let errors = false;
    const block = async (tag: string): Promise<{ number: number; timestamp: number } | "unsupported" | null> => {
      const ex = await this.call(s, [{ method: "eth_getBlockByNumber", params: [tag, false] }], 65_536);
      if (ex.kind !== "answered") return null;
      const r = ex.results[0];
      if (!r.ok) { if (!throttleError(r)) errors = true; return /finalized|tag|invalid/i.test(r.message) ? "unsupported" : null; }
      const b = r.result as Record<string, unknown> | null;
      const number = quantity(b?.number), timestamp = quantity(b?.timestamp);
      return number !== null && timestamp !== null ? { number, timestamp } : null;
    };
    const read = async (): Promise<[number, number] | null> => {
      const fin = await block("finalized");
      if (fin && fin !== "unsupported") return [fin.number, fin.timestamp];
      if (fin === null) return null;
      errors = false; // the tag refused: the question is whether `latest` answers
      const latest = await block("latest");
      if (!latest || latest === "unsupported") return null;
      const settled = await block(hex(Math.max(0, latest.number - 10)));
      return settled && settled !== "unsupported" ? [settled.number, settled.timestamp] : null;
    };
    const head = await read();
    if (!head && errors) { s.strike(this.now()); this.noteSidelined(s); }
    return head;
  }

  // One request through an endpoint's pace (waiting for it), with the outcome noted for pacing. A sidelined endpoint
  // sends nothing: the answer is "unanswered" and nothing is noted. `bypassCap`: past the run's in-flight cap (the
  // block-timestamp reads of a request that already holds a slot, which must never wait on the slots of others).
  private async call(s: EndpointState, calls: Call[], maxBytes: number, bypassCap = false): Promise<Exchange> {
    if (!(await this.paced(s, bypassCap))) return { kind: "unanswered", reason: "network", bytes: 0 };
    this.c.requests[s.label] = (this.c.requests[s.label] ?? 0) + 1;
    let ex: Exchange = { kind: "unanswered", reason: "network", bytes: 0 };
    try {
      ex = await this.send(s, calls, maxBytes);
    } finally {
      this.requestsInFlight--;
      s.finished(this.now(), this.outcomeOf(s, ex));
      this.noteSidelined(s);
      this.wake();
    }
    return ex;
  }

  // Waits for the endpoint's pace and a slot, then takes both (started, counted in flight); false: it is sidelined.
  private async paced(s: EndpointState, bypassCap = false): Promise<boolean> {
    for (;;) {
      if (this.stop) throw new Stop(this.stop);
      const now = this.now();
      if (s.sidelined(now)) return false;
      const at = s.nextStartAt(now);
      const full = !bypassCap && this.requestsInFlight >= this.o.maxInFlightTotal;
      if (at <= now && !full) {
        // Taken in the same synchronous step as the check: several waiters woken together must not all pass it.
        s.started(now);
        this.requestsInFlight++;
        return true;
      }
      if (now >= this.deadline) throw new Stop("deadline");
      // A full in-flight cap frees when a request finishes (which wakes every waiter); a pace or a rest has a time.
      await this.wait(full || at === Number.POSITIVE_INFINITY ? 1_000 : Math.max(1, at - now));
    }
  }

  // Reports an endpoint the moment it is sidelined (once per run): it refused SIDELINE_AFTER requests in a row.
  private noteSidelined(s: EndpointState) {
    if (!s.sidelined(this.now()) || this.c.sidelined.includes(s.label)) return;
    this.c.sidelined.push(s.label);
    this.c.error(`sidelined ${s.label}: it refused every request (a key, a quota or a firewall?)`);
  }

  private async send(s: EndpointState, calls: Call[], maxBytes: number): Promise<Exchange> {
    const ex = await exchange(this.deps.fetch, s.endpoint.url, calls, {
      timeoutMs: this.o.requestTimeoutMs, maxBytes, bare: s.bare() && calls.length === 1, cpuNow: this.deps.cpuNow,
      setTimer: (ms, fn) => this.timer(ms, fn),
    });
    if (ex.kind === "answered") { this.syncMs += ex.parseMs; this.parsedBytes += ex.bytes; }
    return ex;
  }

  // What a request's answer says about the endpoint. An HTTP 4xx (not 429, not the batch refusal) without a JSON-RPC
  // body, or a non-2xx JSON-RPC body refusing every call, is a refusal of the endpoint (a revoked key, a spent quota, a
  // firewall): it rests 2 → 8 → 30 s and the fourth in a row sidelines it (pacing.ts).
  private outcomeOf(s: EndpointState, ex: Exchange): Outcome {
    if (ex.kind === "unanswered") return ex.reason === "timeout" ? { kind: "timeout" } : ex.reason === "tooLarge" ? { kind: "answered" } : { kind: "unanswered" };
    if (ex.kind === "http") {
      const v = classifyHttp(ex.status, ex.headers, ex.body, Date.now());
      if (v.kind === "throttled") { this.c.throttled[s.label] = (this.c.throttled[s.label] ?? 0) + 1; return v; }
      if (v.kind === "batchRefused") return s.bare() ? { kind: "unanswered" } : { kind: "batchRefused" };
      if (v.kind === "unanswered") return { kind: "unanswered" };
      this.c.refused[s.label] = (this.c.refused[s.label] ?? 0) + 1;
      return { kind: "refused" };
    }
    const errors = ex.results.filter((r) => !r.ok) as Extract<CallResult, { ok: false }>[];
    if (errors.some(throttleError)) {
      this.c.throttled[s.label] = (this.c.throttled[s.label] ?? 0) + 1;
      return { kind: "throttled" };
    }
    if (errors.length === ex.results.length && ex.results.length > 1 && errors.every((e) => /internal error/i.test(e.message))) {
      return { kind: "unanswered" };
    }
    if (errors.length === ex.results.length && ex.status >= 400) {
      this.c.refused[s.label] = (this.c.refused[s.label] ?? 0) + 1;
      return { kind: "refused" };
    }
    return { kind: "answered", anyOk: errors.length < ex.results.length };
  }

  // ── Straddle self-test (D4): each `refuses` endpoint must refuse a range past its head ──────────────────────────
  // The probe starts well below the head (up to the endpoint's span, ≤ 10,000 blocks), not 10 blocks below it: a
  // clamping node more than 10 blocks behind refuses a range that lies entirely past ITS head ("Block requested not
  // found") and would pass a narrow probe, then silently answer real pieces short (the run-loop test's lagging
  // clamping endpoint found exactly that). A refusing endpoint refuses either way. No verdict (throttled, no answer)
  // → treated as clamping for this run.

  // An endpoint resting at the start (a Retry-After the last run remembered) is not waited for: its probe is deferred
  // until it is first ready (the read loop sends it), and until then it is used as clamping — a piece that needs a
  // refusing endpoint waits for it (pickEndpoint). A probe without a verdict is tried again when the endpoint is next
  // ready, `probeAttempts` in all; then the endpoint is clamping for the rest of the run.
  private async selfTest() {
    for (const s of this.states) {
      const now = this.now();
      if (s.sidelined(now)) { this.c.straddle[s.label] = "sidelined"; continue; }
      if (s.straddle(now) !== "refuses") { this.c.straddle[s.label] = "clamps"; continue; }
      if (s.nextStartAt(now) > now + this.o.headReadyMs) {
        s.deferProbe();
        this.c.straddle[s.label] = "deferred";
        continue;
      }
      this.settleProbe(s, await this.probe(s));
    }
  }

  private async probe(s: EndpointState): Promise<"refuses" | "clamps" | null> {
    const H = this.head!;
    this.probes.set(s, (this.probes.get(s) ?? 0) + 1);
    const from = Math.max(0, H + 200 - Math.min(10_000, s.currentSpan()) + 1);
    try {
      const ex = await this.call(s, [{ method: "eth_getLogs", params: [{ fromBlock: hex(from), toBlock: hex(H + 200), topics: [NOTHING_TOPIC] }] }], 65_536);
      const r = ex.kind === "answered" ? ex.results[0] : null;
      if (r?.ok && Array.isArray(r.result)) return "clamps";
      if (r && !r.ok && classifyCallError(r, { from, to: H + 200 }, H).kind === "pastHead") return "refuses";
    } catch (err) {
      if (!(err instanceof Stop)) throw err;
    }
    return null;
  }

  private settleProbe(s: EndpointState, verdict: "refuses" | "clamps" | null) {
    if (verdict === "refuses") {
      s.markVerified();
    } else if (verdict === "clamps") {
      s.markVerified();
      s.markClamps(this.now());
      this.c.error(`straddle: ${s.label} answered past its head; treated as clamping for 24 h`);
    } else if ((this.probes.get(s) ?? 0) < this.o.probeAttempts && !s.sidelined(this.now()) && !this.stop) {
      s.deferProbe();
      this.c.straddle[s.label] = "deferred";
      return;
    } else {
      s.markUnverified();
    }
    this.c.straddle[s.label] = verdict ?? "unverified";
  }

  // Sends the deferred probes of endpoints that are ready now (one at a time each; the answer wakes the loop).
  private startProbes() {
    const now = this.now();
    for (const s of this.states) {
      if (!s.verifying || this.probing.has(s) || s.sidelined(now) || s.nextStartAt(now) > now) continue;
      if (this.requestsInFlight >= this.o.maxInFlightTotal) return;
      this.probing.add(s);
      this.probe(s)
        .then((verdict) => this.settleProbe(s, verdict))
        .catch((err) => this.fail(err))
        .finally(() => { this.probing.delete(s); this.wake(); });
    }
  }

  // ── The read loop ───────────────────────────────────────────────────────────────────────────────────────────────

  private async loop() {
    try {
      await this.reads();
    } finally {
      this.loopDone = true;
      this.wake();
    }
  }

  private async reads() {
    const { o } = this;
    for (;;) {
      if (this.stop) return;
      if (this.signal.shutdown) throw new Stop(`shutdown:${this.signal.shutdown}`.slice(0, 40));
      const now = this.now();
      if (now >= this.readDeadline) { this.setStop("deadline"); return; }
      if (this.syncMs >= o.syncBudgetMs) { this.setStop("cpu"); return; }
      if (this.parsedBytes >= o.maxParsedBytes || this.logsSeen >= o.maxLogs) { this.setStop("budget"); return; }
      await this.renewIfDue(false);
      await this.refreshIfDue();
      this.flushDue(now);
      this.pumpCommits();
      if (this.uncommitted > o.backpressureLogs || this.jobs.length + this.commitsInFlight > o.backpressureCommits) {
        await this.wait(1_000);
        continue;
      }
      this.startProbes();
      if (this.requestsInFlight >= o.maxInFlightTotal) { await this.wait(1_000); continue; }
      const step = this.step();
      if (step === "sent") continue;
      if (step === "idle") {
        if (this.requestsInFlight === 0 && !this.firstTxBusy && this.probing.size === 0) { this.setStop("done"); return; }
        await this.wait(1_000);
        continue;
      }
      // Everything at hand waits: for the earliest endpoint to be ready, for bytes, or for something to finish.
      await this.wait(step === "bytes" || step.waitUntil === Number.POSITIVE_INFINITY ? 1_000 : Math.max(1, step.waitUntil - this.now()));
    }
  }

  // One step of the read loop: top up the look-ahead from the planner, then send its most urgent item that an endpoint
  // can take now (items of a priority in the order the planner gave them: newest first). An item whose endpoints are
  // all busy or resting stays parked and the next one is tried — never a stall behind one endpoint (§14).
  private step(): "sent" | "idle" | "bytes" | { waitUntil: number } {
    for (;;) {
      this.topUp();
      if (this.parked.length === 0) return "idle";
      const now = this.now();
      let wait = Number.POSITIVE_INFINITY;
      let unreadable = false, bytes = false;
      for (const item of this.byUrgency(this.parked)) {
        const pick = pickEndpoint(this.states, item, now, this.head!, this.readDeadline);
        if (pick === null) { this.unpark(item); this.unreadable(item); unreadable = true; continue; }
        if ("waitUntil" in pick) { wait = Math.min(wait, pick.waitUntil); continue; }
        const at = this.unpark(item);
        if (this.dispatch(item, pick.state, pick.upTo)) return "sent";
        this.parked.splice(at, 0, item); // no bytes for it now: it keeps its place
        bytes = true;
      }
      if (unreadable) continue; // room again: top up and try once more
      return bytes && wait === Number.POSITIVE_INFINITY ? "bytes" : { waitUntil: wait };
    }
  }

  // Fills the look-ahead from the planner: up to `parkItems` P1–P3 items (and every follow item); once full, only items
  // more urgent than its least urgent one, which then goes back to the planner.
  private topUp() {
    const planner = this.planner!;
    for (;;) {
      const counted = this.parked.filter((i) => i.priority > 0);
      const max = counted.length < this.o.parkItems ? 3 : Math.max(...counted.map((i) => i.priority)) - 1;
      const item = this.sync(() => planner.next(planner.pendingNewWindows() === 0, max as Priority));
      if (!item) return;
      this.park(item);
    }
  }

  private park(item: WorkItem) {
    this.parked.push(item);
    const counted = this.parked.filter((i) => i.priority > 0);
    if (counted.length <= this.o.parkItems) return;
    let worst: WorkItem | null = null;
    for (const i of counted) if (!worst || i.priority >= worst.priority) worst = i; // the least urgent, the last given
    this.unpark(worst!);
    this.planner!.giveBack(worst!);
  }

  private unpark(item: WorkItem): number {
    const at = this.parked.indexOf(item);
    if (at >= 0) this.parked.splice(at, 1);
    return at < 0 ? this.parked.length : at;
  }

  // Most urgent first; within a priority, in the order they were parked (a stable sort).
  private byUrgency(items: readonly WorkItem[]): WorkItem[] {
    return [...items].sort((a, b) => a.priority - b.priority);
  }

  // No endpoint can take the item this run: past the head on clamping endpoints only (the next run), or dropped.
  private unreadable(item: WorkItem) {
    if (item.to > this.head! - this.maxLag()) this.c.straddleWaits++;
    else this.c.dropped++;
    this.planner!.settle(item);
  }

  private maxLag() { return Math.max(0, ...this.states.map((s) => s.endpoint.lag)); }

  private kindOf(item: WorkItem): string { return item.single ? "single" : item.kind; }

  // Cuts `item` to what `s` may read, fills a batch from the look-ahead, reserves bytes, and sends it (asynchronously).
  // False (and nothing changed) when the bytes cannot be reserved now.
  private dispatch(first: WorkItem, s: EndpointState, upTo: number): boolean {
    const planner = this.planner!;
    const reserved = this.bytes.tryReserve(this.kindOf(first), !!first.single);
    if (reserved === null) return false;
    const pieces: WorkItem[] = [];
    const take = (item: WorkItem, top: number) => {
      let it = item;
      const parts: WorkItem[] = [];
      if (top < it.to) {                        // the part above head − lag waits for a refusing endpoint
        const upper = { ...it, from: top + 1 };
        it = { ...it, to: top };
        parts.push(upper);
        planner.requeue(upper, true);
      }
      const span = it.single ? 1 : s.currentSpan();
      const piece = { ...it, from: Math.max(it.from, it.to - span + 1) };
      parts.push(piece);
      if (piece.from > it.from) {
        const rest = { ...it, to: piece.from - 1 };
        parts.push(rest);
        planner.requeue(rest, true);
      }
      if (parts.length > 1) planner.derive(item, parts);
      pieces.push(piece);
    };
    take(first, upTo);
    const batch = first.alone || first.single ? 1 : s.currentBatch();
    if (batch > 1) {
      this.topUp();
      const now = this.now();
      for (const next of this.byUrgency(this.parked)) {
        if (pieces.length >= batch) break;
        const top = s.highestAllowed(now, next.from, this.head!);
        if (next.alone || next.single || top === null || (next.refusingOnly && s.straddle(now) !== "refuses") ||
            !s.budgetAllows(now, next.priority) || s.currentSpan() < minSpanFor(next.priority)) continue;
        this.unpark(next);
        take(next, Math.min(next.to, top));
      }
    }
    const maxBytes = first.single ? this.o.singleBlockCap : this.o.responseCap;
    const calls = this.sync(() => pieces.map((p) => ({ method: "eth_getLogs", params: [filterFor(this.defs.get(p.scan)!, p.from, p.to, p.wallets)] })));
    s.started(this.now());
    this.c.requests[s.label] = (this.c.requests[s.label] ?? 0) + 1;
    this.requestsInFlight++;
    let noted = false;
    this.send(s, calls, maxBytes)
      .then((ex) => { noted = true; return this.answered(s, pieces, ex); })
      .catch((err) => { if (!noted) s.finished(this.now(), { kind: "unanswered" }); this.fail(err); })
      .finally(() => {
        this.requestsInFlight--;
        this.bytes.release(reserved, !!first.single);
        this.wake();
      });
    return true;
  }

  // §10.1: one request's outcome, piece by piece.
  private async answered(s: EndpointState, pieces: WorkItem[], ex: Exchange) {
    const planner = this.planner!;
    const now = this.now();
    const H = this.head!;
    const outcome = this.outcomeOf(s, ex);
    s.finished(now, outcome);
    this.noteSidelined(s);
    const again = (p: WorkItem, front = true) => planner.requeue(p, front);
    const batch = pieces.length > 1;
    // The endpoint refused the whole request: its pieces go back unchanged and uncounted (a refusing endpoint never
    // turns a piece into a hole); the endpoint rests, and is sidelined after four refusals in a row.
    if (outcome.kind === "refused") { for (const p of pieces) again(p); return; }
    if (ex.kind === "http") {
      // Throttled or a refused batch: re-queued as they are. A 5xx without JSON-RPC: a batch's pieces each alone; a
      // piece already alone counts an attempt (3, then dropped, or a hole at its minimum size).
      for (const p of pieces) {
        if (outcome.kind !== "unanswered") again(p);
        else if (batch) again({ ...p, alone: true });
        else this.failedPiece(p, `${s.label}: HTTP ${ex.status}`);
      }
      return;
    }
    if (ex.kind === "unanswered") {
      if (ex.reason === "timeout") this.c.timeouts++;
      if (ex.reason === "timeout" || ex.reason === "tooLarge") {
        if (ex.reason === "tooLarge") this.c.dense++;
        // A batch: every piece alone at once; a piece already alone is too dense (split, never capped: D10).
        for (const p of pieces) if (batch) again({ ...p, alone: true }); else await this.split(p);
        return;
      }
      for (const p of pieces) {
        if (batch) again({ ...p, alone: true });
        else this.failedPiece(p, `${s.label}: ${ex.reason}`);
      }
      return;
    }
    // Every call failed with an error that says nothing about the piece: a strike against the endpoint (pacing.ts). Only
    // the first strike in a row counts an attempt for its pieces.
    const verdicts = pieces.map((p, k) => { const r = ex.results[k]; return r.ok ? null : classifyCallError(r, p, H); });
    const endpointAtFault = verdicts.every((v) => v?.kind === "failed") && s.strike(now);
    this.noteSidelined(s);
    for (let k = 0; k < pieces.length; k++) {
      const p = pieces[k];
      const r = ex.results[k];
      if (!r.ok) {
        const v = verdicts[k]!;
        switch (v.kind) {
          case "throttled": again(p); break;
          case "span":
            s.note(now, { kind: "span", span: v.span, tried: p.to - p.from + 1 });
            again(p);
            break;
          case "dense":
            this.c.dense++;
            await this.split(p, v.cut);
            break;
          case "pastHead": {
            this.c.pastHead++;
            s.note(now, { kind: "pastHead" });
            const times = (p.pastHead ?? 0) + 1;
            if (times >= this.o.maxPastHead) { planner.settle(p); this.c.straddleWaits++; break; } // the next run
            again({ ...p, pastHead: times, refusingOnly: true }, false);
            break;
          }
          case "failed":
            if (endpointAtFault) again(p);
            else this.failedPiece(p, `${s.label}: ${r.message.slice(0, 60)}`);
            break;
        }
        continue;
      }
      const checked = this.sync(() => checkAnswer(this.defs.get(p.scan)!, p, r.result));
      if (!checked.ok) {
        this.c.invalid++;
        this.c.error(`invalid answer from ${s.label}: ${checked.reason}`);
        s.note(now, { kind: "invalid" });
        this.failedPiece(p, null);
        continue;
      }
      // Too dense to trust whole: ≥ 10,000 logs, or a block with more than one commit can hold.
      const single = p.from === p.to && p.wallets.length <= 1;
      let perBlock = 0, run = 0, last = -1;
      for (const l of checked.logs) { run = l.b === last ? run + 1 : 1; last = l.b; perBlock = Math.max(perBlock, run); }
      if (single ? checked.logs.length > this.o.singleBlockLogs : (checked.logs.length >= this.o.denseLogs || perBlock > this.o.singleBlockLogs)) {
        this.c.dense++;
        await this.split(p);
        continue;
      }
      if (checked.missingTimestamps.length > 0 && !(await this.fillTimestamps(s, checked.logs, checked.missingTimestamps))) {
        if (s.sidelined(this.now())) again(p);
        else this.failedPiece(p, `${s.label}: block timestamps unavailable`);
        continue;
      }
      this.logsSeen += checked.logs.length;
      this.c.logs += checked.logs.length;
      this.bytes.observe(this.kindOf(p), ex.bytes / pieces.length);
      this.coalesce(p, checked.logs);
    }
  }

  // A piece that failed: retried up to 3 times this run; then a piece at its minimum size becomes a hole, any other
  // stays a gap for the next run. A hole's retry that failed is recorded again whatever its size (it is already a hole):
  // that restarts its 6-hour clock (history_mark_hole), instead of retrying it on every run.
  private failedPiece(p: WorkItem, reason: string | null) {
    const planner = this.planner!;
    if (reason) { this.c.failed++; }
    const attempts = p.attempts + 1;
    if (attempts < this.o.maxAttempts) { planner.requeue({ ...p, attempts }, false); return; }
    const global = GLOBAL_SCANS.includes(p.scan);
    const minimal = p.from === p.to || (global && p.to - p.from + 1 <= 100);
    if (reason) this.c.error(`gave up on a piece: ${reason}`);
    if (minimal || p.hole) { this.hole(p).catch((err) => this.fail(err)); return; }
    this.c.dropped++;
    planner.settle(p);
  }

  // D10: halve the range down to 100 blocks, then the wallet list, then down to single blocks; a single block for one
  // wallet (or a global single block) still too dense is a hole. Never a cap.
  private async split(p: WorkItem, cut?: number) {
    const planner = this.planner!;
    const blocks = p.to - p.from + 1;
    let parts: WorkItem[];
    const base = { ...p, attempts: 0, alone: true, single: false };
    if (blocks > 100 || (blocks > 1 && p.wallets.length <= 1)) {
      const mid = cut !== undefined && cut >= p.from && cut < p.to ? cut : p.from + Math.floor((blocks - 1) / 2);
      parts = [{ ...base, from: mid + 1 }, { ...base, to: mid }];
    } else if (p.wallets.length > 1) {
      const half = Math.ceil(p.wallets.length / 2);
      parts = [{ ...base, wallets: p.wallets.slice(0, half) }, { ...base, wallets: p.wallets.slice(half) }];
    } else {
      await this.hole(p);
      return;
    }
    parts = parts.map((x) => ({ ...x, single: x.from === x.to }));
    planner.derive(p, parts);
    for (const x of [...parts].reverse()) planner.requeue(x, true); // newest first
  }

  private async hole(p: WorkItem) {
    const planner = this.planner!;
    const global = GLOBAL_SCANS.includes(p.scan);
    try {
      if (global) {
        await this.deps.db.markHole(this.owner, p.scan, p.defVersion, null, p.from, p.to);
        planner.holed(p.scan, null, [p.from, p.to]);
        if (this.c.globalHoles.length < 20) this.c.globalHoles.push({ scan: p.scan, from: p.from, to: p.to });
        this.c.holesMarked++;
      } else {
        for (const w of p.wallets) {
          await this.deps.db.markHole(this.owner, p.scan, p.defVersion, w, p.from, p.to);
          planner.holed(p.scan, w, [p.from, p.to]);
          this.c.holesMarked++;
        }
      }
    } catch (err) {
      if (err instanceof Refused) this.c.error(`hole refused: ${p.scan}`);
      else if (err instanceof CommitSlow || err instanceof Retryable) this.c.error(`hole not recorded: ${p.scan}`);
      else throw err;
    } finally {
      planner.settle(p);
    }
  }

  // Blocks whose logs came without blockTimestamp (never on the public endpoints; a custom provider): read their
  // headers on the same endpoint. Past the run's in-flight cap: the request they complete still holds its slot, and
  // with every slot held by such requests they would wait on each other until the deadline.
  private async fillTimestamps(s: EndpointState, logs: CompactLog[], blocks: number[]): Promise<boolean> {
    const times = new Map<number, number>();
    for (let k = 0; k < blocks.length; k += Math.max(1, s.currentBatch())) {
      const chunk = blocks.slice(k, k + Math.max(1, s.currentBatch()));
      const ex = await this.call(s, chunk.map((b) => ({ method: "eth_getBlockByNumber", params: [hex(b), false] })), 4 * MiB, true);
      if (ex.kind !== "answered") return false;
      ex.results.forEach((r, i) => {
        const t = r.ok ? quantity((r.result as Record<string, unknown> | null)?.timestamp) : null;
        if (t !== null) times.set(chunk[i], t);
      });
    }
    return fillTimestamps(logs, times);
  }

  // ── Coalescing and committing (§12) ─────────────────────────────────────────────────────────────────────────────

  private key(p: { scan: ScanId; defVersion: number; wallets: readonly string[] }) {
    return `${p.scan}|${p.defVersion}|${[...p.wallets].sort().join(",")}`;
  }

  private coalesce(p: WorkItem, logs: CompactLog[]) {
    const k = this.key(p);
    const cur = this.pending.get(k);
    if (cur && (p.to + 1 === cur.from || cur.to + 1 === p.from)) {
      cur.from = Math.min(cur.from, p.from);
      cur.to = Math.max(cur.to, p.to);
      cur.logs = cur.logs.concat(logs);
      cur.pieces++;
      cur.items.push(p);
    } else {
      if (cur) this.flush(k);
      const wallets = GLOBAL_SCANS.includes(p.scan) ? null : [...p.wallets].sort();
      this.pending.set(k, { scan: p.scan, defVersion: p.defVersion, wallets, from: p.from, to: p.to, logs: [...logs], pieces: 1,
                            firstAt: this.now(), items: [p] });
    }
    this.uncommitted += logs.length;
    const now = this.pending.get(k)!;
    if (now.logs.length >= this.commitLogs || now.pieces >= this.o.coalesceItems) this.flush(k);
    this.pumpCommits();
  }

  private flushDue(now: number) {
    for (const [k, p] of this.pending) if (now - p.firstAt >= this.o.coalesceMs) this.flush(k);
  }

  private flush(k: string) {
    const p = this.pending.get(k);
    if (!p) return;
    this.pending.delete(k);
    const sorted = p.logs.sort((a, b) => a.b - b.b || a.i - b.i);
    const parts = splitForCommit(sorted, p.from, p.to, this.commitLogs);
    const group = { remaining: parts.length, items: p.items };
    for (const part of parts.reverse()) {  // newest first
      this.jobs.push({ scan: p.scan, defVersion: p.defVersion, wallets: p.wallets, from: part.from, to: part.to, logs: part.logs,
                       slowRetried: false, retries: 0, group });
    }
  }

  private pumpCommits() {
    while (this.commitsInFlight < this.o.commitConcurrency && !this.stopsCommits()) {
      const at = this.jobs.findIndex((j) => !GLOBAL_SCANS.includes(j.scan) || !this.globalCommitting.has(j.scan));
      if (at < 0) return;
      const job = this.jobs.splice(at, 1)[0];
      this.commitsInFlight++;
      if (GLOBAL_SCANS.includes(job.scan)) this.globalCommitting.add(job.scan);
      this.commit(job).catch((err) => this.fail(err)).finally(() => {
        this.commitsInFlight--;
        this.globalCommitting.delete(job.scan);
        this.wake();
        this.pumpCommits();
      });
    }
  }

  // Stops after which nothing more is committed: the lease or the definitions are gone, the database is down, or the
  // platform is shutting the isolate down (index.ts has already released the run).
  private stopsCommits() {
    return this.stop !== null && (["lease", "paused", "defs", "db", "error"].includes(this.stop) || this.stop.startsWith("shutdown:"));
  }

  private async commit(job: Job) {
    const planner = this.planner!;
    const args: CommitArgs = { owner: this.owner, scan: job.scan, defVersion: job.defVersion, from: job.from, to: job.to,
                               head: this.head!, headTimestamp: this.headTimestamp!, wallets: job.wallets, logs: job.logs };
    const started = this.now();
    let done = true;
    try {
      this.syncMs += compactBytes(job.logs) / 200_000; // the payload's JSON.stringify inside the client, at ~200 MB/s
      const answer = await this.deps.db.commit(args);
      this.commitTimes.push(this.now() - started);
      if (this.commitTimes.length > 50) this.commitTimes.shift();
      if (this.p95() > 2_000) this.readDeadline = Math.min(this.readDeadline, this.deadline - this.o.slowReadMarginMs);
      this.c.commits++;
      this.c.inserted[job.scan] = (this.c.inserted[job.scan] ?? 0) + answer.inserted;
      this.c.trimmed += answer.trimmed;
      this.c.holesCleared += planner.committed(job.scan, job.wallets, [job.from, job.to]);
      for (const [w, floor] of Object.entries(answer.capFloors)) { planner.capped(w, job.scan, floor); this.c.capped++; }
    } catch (err) {
      if (err instanceof LeaseLost) { this.setStop(err.paused ? "paused" : "lease"); return; }
      if (err instanceof DefsChanged) { this.setStop("defs"); return; }
      if (err instanceof CommitSlow) {
        this.c.commitSlow++;
        this.commitLogs = Math.max(this.o.minCommitLogs, Math.floor(this.commitLogs / 2));
        if (!job.slowRetried) {
          const parts = splitForCommit(job.logs, job.from, job.to, Math.max(1, Math.ceil(job.logs.length / 2)));
          const sub = parts.length > 1 ? parts : [{ from: job.from, to: job.to, logs: job.logs }];
          job.group.remaining += sub.length - 1;
          for (const part of sub.reverse()) this.jobs.unshift({ ...job, from: part.from, to: part.to, logs: part.logs, slowRetried: true });
          this.c.commitRetries++;
          done = false;
        } else {
          this.c.error(`commit slow twice: ${job.scan}; the range stays a gap`);
        }
        return;
      }
      if (err instanceof Retryable && job.retries < 2) {
        this.c.commitRetries++;
        await this.deps.sleep(100 + Math.floor(this.deps.random() * 400));
        this.jobs.unshift({ ...job, retries: job.retries + 1 });
        done = false;
        return;
      }
      if (err instanceof Refused || err instanceof Retryable) { this.c.error(`commit refused: ${job.scan} ${(err as Error).message.slice(0, 60)}`); return; }
      if (err instanceof DbDown) { this.setStop("db"); this.c.error(`db: ${err.message}`); return; }
      throw err;
    } finally {
      if (done) {
        this.uncommitted = Math.max(0, this.uncommitted - job.logs.length);
        if (--job.group.remaining === 0) for (const item of job.group.items) planner.settle(item);
      }
    }
  }

  private p95(): number {
    if (this.commitTimes.length < 5) return 0;
    const sorted = [...this.commitTimes].sort((a, b) => a - b);
    return sorted[Math.floor(sorted.length * 0.95)] ?? 0;
  }

  // ── Lease and mid-run refresh ───────────────────────────────────────────────────────────────────────────────────

  private async renewIfDue(final: boolean) {
    const now = this.now();
    if (!final && now - this.lastRenew < this.o.renewMs) return;
    if (final && this.leaseUntil - now > 30_000) return;
    const lease = await this.deps.db.lease(this.owner, this.o.leaseSeconds, this.deps.version);
    if (!lease.ok) throw new LeaseLost("the lease was taken", lease.paused);
    this.lastRenew = this.now();
    this.leaseUntil = this.lastRenew + this.o.leaseSeconds * 1_000;
  }

  private async refreshIfDue() {
    if (this.now() - this.lastRefresh < this.o.stateRefreshMs || !this.stateCursor) return;
    this.lastRefresh = this.now();
    const fresh: IndexerState = await this.deps.db.state(this.owner, this.o.maxWallets, this.stateCursor);
    this.stateCursor = new Date(fresh.now).toISOString();
    if (fresh.wallets.length === 0) return;
    this.wallets.refreshed += fresh.wallets.length;
    this.sync(() => this.planner!.addWallets(fresh.wallets));
    this.firstTxQueue.unshift(...fresh.wallets.filter((w) => this.needsFirstTx(w, fresh.now)));
  }

  // ── First transactions (§13), alongside the reads ──────────────────────────────────────────────────────────────

  private firstTxQueue: WalletState[] = [];
  private firstTxActive = 0;
  private firstTxStarted = 0;
  private loopDone = false;
  // Wallets waiting for, or in, a first-transaction lookup this run (the read loop is not done while there are any).
  private get firstTxBusy(): boolean {
    return this.firstTxActive > 0 || (this.firstTxQueue.length > 0 && this.firstTxStarted < this.o.firstTxPerRun);
  }

  private needsFirstTx(w: WalletState, now: number): boolean {
    const f = w.firstTx;
    if (f.state === "unknown") return true;
    if (f.state === "none") return f.checkedAt === null || now - f.checkedAt >= 6 * 3_600_000;
    return f.checkedAt === null || now - f.checkedAt >= 7 * 86_400_000;
  }

  private async firstTransactions(wallets: WalletState[]) {
    const now = this.now();
    const rank = (w: WalletState) => (w.firstTx.state === "unknown" ? 0 : w.firstTx.state === "none" ? 1 : 2);
    this.firstTxQueue = wallets.filter((w) => this.needsFirstTx(w, now)).sort((a, b) => rank(a) - rank(b));
    const workers: Promise<void>[] = [];
    for (let k = 0; k < this.o.firstTxConcurrency; k++) workers.push(this.firstTxLoop());
    await Promise.all(workers);
    this.wake();
  }

  private async firstTxLoop() {
    for (;;) {
      if (this.stop || this.now() >= this.readDeadline || this.firstTxStarted >= this.o.firstTxPerRun) return;
      const w = this.firstTxQueue.shift();
      if (!w) {
        if (this.loopDone) return;
        await this.wait(1_000);   // a mid-run refresh may bring new wallets
        continue;
      }
      this.firstTxStarted++;
      this.firstTxActive++;
      try {
        await this.firstTxOf(w);
      } catch (err) {
        if (err instanceof Stop) return;
        if (err instanceof LeaseLost || err instanceof DefsChanged || err instanceof DbDown) { this.fail(err); return; }
        this.c.firstTx.failed++;
      } finally {
        this.firstTxActive--;
        this.wake();
      }
    }
  }

  // The archive endpoints in the order nonce reads try them: the wide logs endpoints (span ≥ 10,000) last.
  private nonceSources(wallet: string): NonceSource[] {
    const archive = this.states.filter((s) => s.endpoint.archive && !s.sidelined(this.now()))
      .sort((a, b) => (a.endpoint.span >= 10_000 ? 1 : 0) - (b.endpoint.span >= 10_000 ? 1 : 0) || a.endpoint.priority - b.endpoint.priority);
    return archive.map((s) => ({
      label: s.label,
      nonceAt: async (block: number) => {
        const ex = await this.call(s, [{ method: "eth_getTransactionCount", params: [wallet, hex(block)] }], 65_536);
        if (ex.kind !== "answered" || !ex.results[0].ok) throw new Error("no nonce");
        const n = quantity(ex.results[0].result);
        if (n === null) throw new Error("malformed nonce");
        return BigInt(n);
      },
    }));
  }

  private async firstTxOf(w: WalletState) {
    const H = this.head!;
    const sources = this.nonceSources(w.wallet);
    if (sources.length === 0) return;
    const opts = { sleep: (ms: number) => this.deps.sleep(ms), pauseMs: this.o.firstTxPauseMs };
    const f = w.firstTx;
    const result = f.state === "found" && f.block !== null
      ? await reverifyFirstTx(sources, { block: f.block, source: f.source }, opts)
      : await locateFirstTx(sources, H, f.state === "none" && f.head !== null && f.head < H ? { ...opts, zeroAt: f.head } : opts);
    switch (result.state) {
      case "found":
        if (await this.deps.db.setFirstTx(this.owner, w.wallet, "found", result.block, H, result.source)) {
          this.c.firstTx.found++;
          if (result.movedEarlier) this.c.firstTx.movedEarlier++;
        }
        this.planner?.markDeep(w.wallet);
        break;
      case "same":
        await this.deps.db.setFirstTx(this.owner, w.wallet, "found", f.block!, H, f.source ?? sources[0].label);
        this.c.firstTx.same++;
        break;
      case "none":
        await this.deps.db.setFirstTx(this.owner, w.wallet, "none", null, H, sources[0].label);
        this.c.firstTx.none++;
        break;
      case "unconfirmed": this.c.firstTx.unconfirmed++; break;
      case "failed": this.c.firstTx.failed++; break;
    }
  }

  // ── The end of the run ──────────────────────────────────────────────────────────────────────────────────────────

  private async finish() {
    const { deps } = this;
    try {
      // No new reads: let the requests in flight answer (each has its own timeout), then commit what they brought.
      while (this.requestsInFlight > 0 && this.now() < this.deadline + this.o.requestTimeoutMs) await this.wait(1_000);
      // The first-transaction workers stop at their next read once a stop is set; wait for them (bounded), so nothing
      // of this run is written after its release.
      if (!this.stop) this.stop = "done";
      if (this.firstTxWorker) await Promise.race([this.firstTxWorker, this.deps.sleep(this.o.requestTimeoutMs)]);
      if (!this.stopsCommits() && this.planner) {
        for (const k of [...this.pending.keys()]) this.flush(k);
        if (this.jobs.length > 0) await this.renewIfDue(true);
        this.pumpCommits();
        while ((this.jobs.length > 0 || this.commitsInFlight > 0) && !this.stopsCommits() && this.now() < this.deadline + 30_000) {
          await this.wait(1_000);
          this.pumpCommits();
        }
      }
      while (this.commitsInFlight > 0 && this.now() < this.deadline + 30_000) await this.wait(1_000);
    } catch (err) {
      this.fail(err);
    }
    if (this.stop === "deadline" && this.planner && this.parked.length === 0 && this.planner.next(true) === null) this.stop = "done";
    const stop = this.stop ?? "done";
    deps.onRelease?.(stop);
    const summary = this.summary();
    try {
      await deps.db.release(this.owner, this.head, this.headTimestamp, summary,
                            Object.fromEntries(this.states.map((s) => [s.label, s.memory(this.now())])), stop);
    } catch (err) {
      this.c.error(`release: ${(err as Error).message}`);
    }
    deps.log(`history-indexer: ${JSON.stringify(summary)}`);
    for (const e of this.c.errors) deps.log(`history-indexer: ${e}`);
  }

  summary(): RunSummary {
    const now = this.now();
    const c = this.c;
    const stats = this.planner?.stats();
    const kinds = this.planner?.kindCounts() as ItemCounts | undefined;
    const r429: Record<string, number> = {}, usedToday: Record<string, number> = {};
    for (const s of this.states) { r429[s.label] = Math.round(s.ratio429() * 10_000) / 10_000; usedToday[s.label] = s.usedToday(now); }
    return {
      v: 2, version: this.deps.version, head: this.head, ms: now - this.started, syncMs: Math.round(this.syncMs),
      stop: this.stop ?? "done",
      counts: {
        requests: c.requests, throttled: c.throttled, refused: c.refused, sidelined: c.sidelined, r429, usedToday,
        failed: c.failed, invalid: c.invalid, dense: c.dense,
        timeouts: c.timeouts, pastHead: c.pastHead, straddleWaits: c.straddleWaits, dropped: c.dropped,
        items: kinds ?? { follow: 0, global: 0, window: 0, deep: 0, holes: 0 },
        commits: c.commits, commitSlow: c.commitSlow, commitRetries: c.commitRetries, logs: c.logs, inserted: c.inserted,
        trimmed: c.trimmed, holesMarked: c.holesMarked, holesCleared: c.holesCleared, capped: c.capped, firstTx: c.firstTx,
        wallets: { active: this.wallets.active, planned: stats?.planned ?? 0, skipped: this.wallets.skipped, new: stats?.new ?? 0,
                   refreshed: this.wallets.refreshed, windowComplete: stats?.windowComplete ?? 0, deepComplete: stats?.deepComplete ?? 0 },
      },
      straddle: c.straddle, defsDrift: this.drift, globalHoles: c.globalHoles.slice(0, 20), errors: c.errors.slice(0, 5),
    };
  }
}

export type { Priority };
