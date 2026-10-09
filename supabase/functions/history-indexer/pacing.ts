// Per-endpoint pacing and the state that outlives a run (§10.3): each endpoint's AIMD request rate, its rests after
// throttling, failures or refusals, the span and batch it taught us, its 429 ratio, its requests this UTC day, whether
// its straddle self-test failed, and whether it is sidelined (it refused everything: a revoked key, a spent quota, a
// firewall). history_release stores it (`history_indexer_state.endpoints`, by label — never a URL) and history_lease
// hands it to the next run.
import type { Endpoint, Straddle } from "./endpoints.ts";

export type Priority = 0 | 1 | 2 | 3; // follow, global gaps, wallet window, wallet deep

export type EndpointMemory = {
  restUntil?: number; span?: number; spanUntil?: number; batch?: number; batchUntil?: number; rps?: number; r429?: number;
  day?: string; used?: number; clampsUntil?: number; sidelinedUntil?: number; refusals?: number; strikes?: number;
};

export type Outcome =
  | { kind: "answered"; anyOk?: boolean } // anyOk false: every call of it was an error (the refusal streak goes on)
  | { kind: "throttled"; retryAfterMs?: number }
  | { kind: "batchRefused" }
  | { kind: "span"; span?: number; tried: number }
  | { kind: "unanswered" }   // network, 5xx, malformed, a batch of "Internal error"
  | { kind: "timeout" }
  | { kind: "pastHead" }
  | { kind: "invalid" }      // an answer checkAnswer rejected
  | { kind: "refused" };     // the endpoint refused the whole request: an HTTP 4xx, or a run of failed calls (strike)

const DAY_MS = 86_400_000;
const MINUTE = 60_000;
const MIN_RPS = 0.25;
const MIN_SPAN = 100;
const THROTTLE_RESTS = [2_000, 4_000, 8_000, 16_000];
const FAIL_RESTS = [1_000, 2_000, 4_000, 8_000];
const REFUSAL_RESTS = [2_000, 8_000, 30_000];   // the 4th refusal in a row sidelines the endpoint
export const SIDELINE_AFTER = 4;
export const SIDELINE_MS = 15 * MINUTE;
export const STRIKES_TO_REFUSAL = 3;            // exchanges in a row whose every call failed
const VERIFY_RECHECK_MS = 1_000;
const utcDay = (now: number) => new Date(now).toISOString().slice(0, 10);
const finite = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

export class EndpointState {
  readonly endpoint: Endpoint;
  inFlight = 0;
  restUntil = 0;
  private span: number;
  private spanUntil = 0;
  private batch: number;
  private batchUntil = 0;
  private liveBatch: number;          // halved after an unanswered request, restored by an answer (this run only)
  private rps: number;
  private lastRaise: number;
  private lastStart = Number.NEGATIVE_INFINITY;
  private r429: number;
  private day: string;
  private used: number;
  private clampsUntil = 0;
  private sidelinedUntil = 0;
  private throttles = 0;
  private failures = 0;
  private refusals = 0;               // endpoint-wide refusals in a row (no call answered in between)
  private strikes = 0;                // exchanges in a row whose every call failed

  constructor(endpoint: Endpoint, memory: EndpointMemory | undefined, now: number) {
    this.endpoint = endpoint;
    const m = memory ?? {};
    this.restUntil = finite(m.restUntil) && m.restUntil > now ? Math.min(m.restUntil, now + MINUTE) : 0;
    this.span = endpoint.span;
    if (finite(m.span) && finite(m.spanUntil) && m.spanUntil > now && m.span >= MIN_SPAN && m.span < endpoint.span) {
      this.span = Math.floor(m.span);
      this.spanUntil = m.spanUntil;
    }
    this.batch = endpoint.batch;
    if (finite(m.batch) && finite(m.batchUntil) && m.batchUntil > now && m.batch >= 1 && m.batch < endpoint.batch) {
      this.batch = Math.floor(m.batch);
      this.batchUntil = m.batchUntil;
    }
    this.liveBatch = this.batch;
    this.rps = finite(m.rps) ? Math.min(endpoint.rps, Math.max(MIN_RPS, m.rps)) : endpoint.rps;
    this.lastRaise = now;
    this.r429 = finite(m.r429) ? Math.min(1, Math.max(0, m.r429)) : 0;
    this.day = typeof m.day === "string" ? m.day : utcDay(now);
    this.used = finite(m.used) && m.used >= 0 ? Math.floor(m.used) : 0;
    if (finite(m.clampsUntil) && m.clampsUntil > now) this.clampsUntil = m.clampsUntil;
    if (finite(m.sidelinedUntil) && m.sidelinedUntil > now) this.sidelinedUntil = Math.min(m.sidelinedUntil, now + SIDELINE_MS);
    // The refusal and strike streaks go on across runs (a run may end before an endpoint refuses four times in a row);
    // an endpoint back from a sideline is sidelined again by its next refusal.
    if (finite(m.refusals) && m.refusals >= 0) this.refusals = Math.min(SIDELINE_AFTER - 1, Math.floor(m.refusals));
    if (finite(m.strikes) && m.strikes >= 0) this.strikes = Math.min(STRIKES_TO_REFUSAL - 1, Math.floor(m.strikes));
    this.rollDay(now);
  }

  get label(): string { return this.endpoint.label; }
  straddle(now: number): Straddle {
    return this.endpoint.straddle === "clamps" || this.clampsUntil > now || this.unverified || this.verifying ? "clamps" : "refuses";
  }
  // Sidelined: it refused SIDELINE_AFTER requests in a row; no work, head or nonce read goes to it until then.
  sidelined(now: number): boolean { return this.sidelinedUntil > now; }
  currentSpan(): number { return this.span; }
  currentBatch(): number { return Math.max(1, Math.min(this.liveBatch, this.batch)); }
  bare(): boolean { return this.batch === 1; }
  currentRps(now: number): number { this.raise(now); return this.rps; }
  usedToday(now: number): number { this.rollDay(now); return this.used; }
  ratio429(): number { return this.r429; }

  // The straddle self-test found this `refuses` endpoint answering past its head: treat it as clamping for 24 hours.
  markClamps(now: number): void { this.clampsUntil = now + DAY_MS; }
  // The self-test got no verdict this run (throttled, no answer): clamping until the next run tests it again.
  private unverified = false;
  markUnverified(): void { this.unverified = true; this.verifying = false; }
  // The self-test is still to come (the endpoint was resting when the run started; the read loop probes it once it is
  // ready): used as clamping until then, and a piece that needs a refusing endpoint waits for it (pickEndpoint).
  verifying = false;
  deferProbe(): void { this.verifying = true; }
  markVerified(): void { this.verifying = false; }

  private rollDay(now: number) {
    const today = utcDay(now);
    if (today !== this.day) { this.day = today; this.used = 0; }
  }

  // +0.5 requests/s per whole minute without a 429, up to the configured rate.
  private raise(now: number) {
    const minutes = Math.floor((now - this.lastRaise) / MINUTE);
    if (minutes >= 1) {
      this.rps = Math.min(this.endpoint.rps, this.rps + 0.5 * minutes);
      this.lastRaise += minutes * MINUTE;
    }
  }

  // Whether the daily budget lets a piece of this priority through: below 80 % anything; 80–100 % only follow (P0) and
  // wallet windows (P2); at 100 % nothing until UTC midnight.
  budgetAllows(now: number, priority: Priority): boolean {
    const max = this.endpoint.maxPerDay;
    if (!max) return true;
    this.rollDay(now);
    if (this.used >= max) return false;
    if (this.used >= 0.8 * max) return priority === 0 || priority === 2;
    return true;
  }

  // The straddle rule (D4): a clamping endpoint only reads pieces ending at or below head − lag. The highest block it may
  // be given for a piece, or null when it may take none of [from, …].
  highestAllowed(now: number, from: number, head: number): number | null {
    if (this.straddle(now) === "refuses") return head;
    const top = head - this.endpoint.lag;
    return from <= top ? top : null;
  }

  // When this endpoint may start its next request (its rest and its pace), or +Infinity while its in-flight cap is
  // full (it frees when a request finishes).
  nextStartAt(now: number): number {
    if (this.inFlight >= this.endpoint.inFlight) return Number.POSITIVE_INFINITY;
    return Math.max(this.restUntil, this.lastStart + 1_000 / this.currentRps(now));
  }

  // Ready now for a piece of `priority` covering [from, to] against `head`: not resting, paced, below its in-flight cap,
  // inside its daily budget, and the straddle rule allows the piece's top.
  ready(now: number, piece: { from?: number; to: number; priority: Priority }, head: number): boolean {
    if (this.nextStartAt(now) > now) return false;
    if (!this.budgetAllows(now, piece.priority)) return false;
    const top = this.highestAllowed(now, piece.from ?? piece.to, head);
    return top !== null && piece.to <= top;
  }

  started(now: number): void {
    this.rollDay(now);
    this.inFlight++;
    this.lastStart = Math.max(now, this.lastStart + 1_000 / this.currentRps(now));
    this.used++;
  }

  finished(now: number, outcome: Outcome): void {
    this.inFlight = Math.max(0, this.inFlight - 1);
    this.note(now, outcome);
  }

  // What one call of a finished request taught us (a request can carry several: a batch).
  note(now: number, outcome: Outcome): void {
    this.raise(now);
    const throttled = outcome.kind === "throttled";
    this.r429 = this.r429 * 0.95 + (throttled ? 0.05 : 0);
    switch (outcome.kind) {
      case "answered":
        this.throttles = 0;
        this.failures = 0;
        this.liveBatch = this.batch;
        if (outcome.anyOk !== false) { this.refusals = 0; this.strikes = 0; }
        break;
      case "throttled": {
        this.throttles++;
        this.rps = Math.max(MIN_RPS, this.rps / 2);
        this.lastRaise = now;
        const backoff = THROTTLE_RESTS[Math.min(this.throttles, THROTTLE_RESTS.length) - 1];
        const told = outcome.retryAfterMs !== undefined ? Math.min(60_000, Math.max(0, outcome.retryAfterMs)) : 0;
        this.rest(now, Math.max(told, backoff));
        break;
      }
      case "batchRefused":
        this.batch = 1;
        this.liveBatch = 1;
        this.batchUntil = now + DAY_MS;
        break;
      case "span": {
        const learned = outcome.span !== undefined ? Math.min(outcome.span, outcome.tried - 1) : Math.floor(outcome.tried / 2);
        this.span = Math.max(MIN_SPAN, Math.min(this.span, learned));
        this.spanUntil = now + DAY_MS;
        break;
      }
      case "unanswered":
      case "timeout":
        this.failures++;
        this.liveBatch = Math.max(1, Math.floor(this.liveBatch / 2));
        this.rest(now, FAIL_RESTS[Math.min(this.failures, FAIL_RESTS.length) - 1]);
        break;
      case "invalid":
        this.rest(now, 8_000);
        break;
      case "pastHead":
        this.rest(now, 1_000);
        break;
      case "refused":
        this.refusals++;
        if (this.refusals >= SIDELINE_AFTER) this.sidelinedUntil = Math.max(this.sidelinedUntil, now + SIDELINE_MS);
        else this.rest(now, REFUSAL_RESTS[this.refusals - 1]);
        break;
    }
  }

  // An exchange whose every call failed with an error the run cannot classify (not a throttle, span, density or head
  // answer): a strike. STRIKES_TO_REFUSAL in a row, with no call answered in between, are a refusal (and so is each
  // further one). True when this is not the first strike in a row: the endpoint, more likely than the piece, is at
  // fault, so the piece is re-queued without counting an attempt (it can never become a hole that way).
  strike(now: number): boolean {
    this.strikes++;
    if (this.strikes >= STRIKES_TO_REFUSAL) this.note(now, { kind: "refused" });
    return this.strikes > 1;
  }

  private rest(now: number, ms: number) { this.restUntil = Math.max(this.restUntil, now + ms); }

  // What the next run starts from.
  memory(now: number): EndpointMemory {
    this.raise(now);
    this.rollDay(now);
    const m: EndpointMemory = { rps: Math.round(this.rps * 100) / 100, r429: Math.round(this.r429 * 10_000) / 10_000, day: this.day, used: this.used };
    if (this.restUntil > now) m.restUntil = this.restUntil;
    if (this.span < this.endpoint.span && this.spanUntil > now) { m.span = this.span; m.spanUntil = this.spanUntil; }
    if (this.batch < this.endpoint.batch && this.batchUntil > now) { m.batch = this.batch; m.batchUntil = this.batchUntil; }
    if (this.clampsUntil > now) m.clampsUntil = this.clampsUntil;
    if (this.sidelinedUntil > now) m.sidelinedUntil = this.sidelinedUntil;
    if (this.refusals > 0) m.refusals = Math.min(this.refusals, SIDELINE_AFTER - 1); // after a sideline: one more refusal
    if (this.strikes > 0) m.strikes = Math.min(this.strikes, STRIKES_TO_REFUSAL - 1);
    return m;
  }
}

// The smallest span an endpoint must have to take work of a priority: deep reads only on wide endpoints (10,000 blocks
// per request), window and global gaps on ≥ 1,000, the follow on any.
export function minSpanFor(priority: Priority): number {
  return priority === 3 ? 10_000 : priority === 0 ? 0 : 1_000;
}

// The endpoint to send `item` to now (in priority order), with the highest block it may read; or the time to wait
// for (before `deadline`); or null when no endpoint can ever take it this run (the straddle rule with no refusing
// endpoint, spans, daily budgets, sidelined endpoints). An endpoint whose straddle self-test is still to come counts
// as a refusing one to wait for.
export function pickEndpoint(states: readonly EndpointState[],
                             item: { from: number; to: number; priority: Priority; refusingOnly?: boolean },
                             now: number, head: number, deadline: number)
  : { state: EndpointState; upTo: number } | { waitUntil: number } | null {
  let wait = Number.POSITIVE_INFINITY;
  let eligible = false;
  for (const s of [...states].sort((a, b) => a.endpoint.priority - b.endpoint.priority)) {
    if (s.sidelined(now)) continue;
    if (s.currentSpan() < minSpanFor(item.priority)) continue;
    if (!s.budgetAllows(now, item.priority)) continue;
    const top = item.refusingOnly && s.straddle(now) !== "refuses" ? null : s.highestAllowed(now, item.from, head);
    if (top === null) {
      if (s.verifying) {
        eligible = true;
        wait = Math.min(wait, Math.max(s.nextStartAt(now), now + VERIFY_RECHECK_MS));
      }
      continue;
    }
    eligible = true;
    const at = s.nextStartAt(now);
    if (at <= now) return { state: s, upTo: Math.min(item.to, top) };
    wait = Math.min(wait, at);
  }
  if (!eligible) return null;
  if (wait === Number.POSITIVE_INFINITY) return { waitUntil: Number.POSITIVE_INFINITY }; // in-flight caps: wait for one
  return wait < deadline ? { waitUntil: wait } : null;
}

// In-flight response bytes (§10.3): each request reserves min(3 MiB, max(256 KiB, 2 × the running average answer of
// its kind)); everything in flight ≤ 12 MiB; a single-block piece reserves 8 MiB and runs with no other single block.
export class ByteBudget {
  private reserved = 0;
  private singles = 0;
  private averages = new Map<string, number>();
  constructor(readonly total = 12 * 1_048_576, readonly cap = 3 * 1_048_576, readonly single = 8 * 1_048_576) {}

  reservation(kind: string, single: boolean): number {
    if (single) return this.single;
    const avg = this.averages.get(kind) ?? 0;
    return Math.min(this.cap, Math.max(262_144, 2 * avg));
  }

  tryReserve(kind: string, single: boolean): number | null {
    const amount = this.reservation(kind, single);
    if (single && this.singles > 0) return null;
    if (this.reserved + amount > this.total) return null;
    this.reserved += amount;
    if (single) this.singles++;
    return amount;
  }

  release(amount: number, single: boolean): void {
    this.reserved = Math.max(0, this.reserved - amount);
    if (single) this.singles = Math.max(0, this.singles - 1);
  }

  observe(kind: string, bytes: number): void {
    const prev = this.averages.get(kind);
    this.averages.set(kind, prev === undefined ? bytes : prev * 0.8 + bytes * 0.2);
  }

  inUse(): number { return this.reserved; }
}
