// The history-indexer's whole run loop (runIndexer) on a virtual clock, against fake endpoints over a seeded fake chain
// (history_fake_chain.ts) and a real PGlite database with migration 32 (history_pglite_db.ts). Checks the invariant
// after every commit (every log of a covered range is stored; nothing is covered that was not answered), the served
// history against the chain, holes instead of caps for spam and slow ranges, the straddle rule, pacing, the run's
// stops (defs, paused, two runs at once, slow commits), and broken endpoints (one resting at the start, one refusing
// everything, one failing every call, logs without blockTimestamp, a gateway error). Nothing here touches the network
// or a real project.
//
//   deno test -A --no-config --node-modules-dir=none supabase/tests/history_indexer_run_test.ts   (10–15 minutes)
import type { PGlite } from "npm:@electric-sql/pglite@0.5.8";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { alchemyEndpoint, type Endpoint } from "../functions/history-indexer/endpoints.ts";
import { redactor } from "../functions/history-indexer/redact.ts";
import { SIDELINE_AFTER, STRIKES_TO_REFUSAL } from "../functions/history-indexer/pacing.ts";
import { type Deps, runIndexer } from "../functions/history-indexer/run.ts";
import { merge, type Range, subtract } from "../functions/history-indexer/ranges.ts";
import { FakeChain, type FakeBehaviour, type FakeLog, FakeNetwork, pad } from "./history_fake_chain.ts";
import { as, historyDatabase, one, pgliteDb, type PgliteDbOptions, VirtualClock } from "./history_pglite_db.ts";

// deno-lint-ignore no-explicit-any
type Any = any;

const H = 3_000_000;
const WINDOW = 1_000_000;          // the test's "30 days": deep work below H − 1,000,000
const LAG = 600;
const TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const CURVEBUY = "0xec36bf571f136799e8dc0b0b8bea4b04d8bd3d43de838aab0d5fc21d4cbfc455";
const SHARING_CLAIMED = "0xf7a40077ff7a04c7e61f6f26fb13774259ddf1b6bce9ecf26a8276cdd3992683";
const COLLECTED = "0xc475c499a9357ec964b24130f5e1e4b21748160d33ce0df8721acb1e370b7c96";
const FEE_SHARING = "0x5358a136a50ee4f961b532064dc641e8f4fa5656";
const MOMENTS_FACTORY = "0x95eb7f5a88b10d9df32ac54f48c767927fa80840";
const FLOORS: Record<string, number> = { launchpad: 2_000_000, "fee-sharing": 2_000_000, moments: 2_500_000 };
const SCANS: Record<string, { topic0: string[]; walletTopic: number; addresses: string[] | null; global: boolean }> = {
  launchpad: { topic0: [CURVEBUY], walletTopic: 1, addresses: null, global: true },
  "fee-sharing": { topic0: [SHARING_CLAIMED], walletTopic: 2, addresses: [FEE_SHARING], global: true },
  moments: { topic0: [COLLECTED], walletTopic: 2, addresses: [MOMENTS_FACTORY], global: true },
  "transfers-in": { topic0: [TRANSFER], walletTopic: 2, addresses: null, global: false },
  "transfers-out": { topic0: [TRANSFER], walletTopic: 1, addresses: null, global: false },
};
const addr = (n: number) => "0x" + n.toString(16).padStart(40, "0");
const word = (n: number) => "0x" + n.toString(16).padStart(64, "0");
const hex = (n: number) => "0x" + n.toString(16);

// ── The world ─────────────────────────────────────────────────────────────────────────────────────────────────────

type World = { chain: FakeChain; enrolled: string[]; spam: string; busy: string; oversized: string; strangers: string[] };

export function buildWorld(): World {
  let seed = 7;
  const rand = () => ((seed = (seed * 1_103_515_245 + 12_345) % 2 ** 31) / 2 ** 31);
  const pick = <T>(list: T[]) => list[Math.floor(rand() * list.length)];
  const chain = new FakeChain(H);
  const enrolled = Array.from({ length: 150 }, (_, k) => addr(0x1000 + k));
  const strangers = Array.from({ length: 20 }, (_, k) => addr(0x9000 + k));
  const tokens = Array.from({ length: 5 }, (_, k) => addr(0x7000 + k));
  const active = enrolled.filter((_, k) => k % 3 !== 0);
  for (const w of active) {
    const first = Math.floor(rand() * (H - 1_000));
    chain.firstTx.set(w, first);
    for (let m = 0; m < 2 + Math.floor(rand() * 5); m++) {
      const out = rand() < 0.5;
      const other = rand() < 0.5 ? pick(strangers) : pick(active);
      const block = out ? first + Math.floor(rand() * (H - first)) : Math.floor(rand() * H); // transfers in may precede the first send
      chain.add({ address: pick(tokens), topics: out ? [TRANSFER, pad(w), pad(other)] : [TRANSFER, pad(other), pad(w)], data: word(m + 1), block });
    }
  }
  for (let m = 0; m < 60; m++) {
    chain.add({ address: pick(tokens), topics: [TRANSFER, pad(pick(strangers)), pad(pick(strangers))], data: word(m), block: Math.floor(rand() * H) });
  }
  const spam = active[0], busy = active[1], oversized = active[2];
  // A spam block: 6,000 Transfers to one enrolled wallet, 50 blocks below the head.
  for (let m = 0; m < 6_000; m++) chain.add({ address: tokens[0], topics: [TRANSFER, pad(strangers[0]), pad(spam)], data: word(m), block: H - 50, index: m });
  // A busy wallet: one Transfer in per block for 25,000 blocks (answers slow down with their size).
  for (let b = 2_500_000; b < 2_525_000; b++) chain.add({ address: tokens[1], topics: [TRANSFER, pad(strangers[1]), pad(busy)], data: word(b), block: b });
  // Global events, for enrolled wallets and strangers.
  for (let m = 0; m < 100; m++) {
    const w = rand() < 0.7 ? pick(enrolled) : pick(strangers);
    chain.add({ address: addr(0x5000 + (m % 7)), topics: [CURVEBUY, pad(w), pad(addr(0x6000 + m))], data: word(m), block: FLOORS.launchpad + Math.floor(rand() * (H - FLOORS.launchpad)) });
  }
  chain.add({ address: addr(0x5000), topics: [CURVEBUY, "0xff" + "00".repeat(31)], data: "0x", block: 2_100_000 }); // no wallet: never stored
  chain.add({ address: addr(0x5001), topics: [CURVEBUY, pad(oversized), pad(addr(0x6999))], data: "0x" + "ab".repeat(20_480), block: 2_200_000 });
  for (let m = 0; m < 10; m++) {
    chain.add({ address: FEE_SHARING, topics: [SHARING_CLAIMED, pad(tokens[2]), pad(pick(enrolled))], data: word(m), block: FLOORS["fee-sharing"] + Math.floor(rand() * 900_000) });
  }
  chain.add({ address: addr(0x4444), topics: [SHARING_CLAIMED, pad(tokens[2]), pad(enrolled[3])], data: word(1), block: 2_300_000 }); // not a listed contract
  for (let m = 0; m < 20; m++) {
    chain.add({ address: MOMENTS_FACTORY, topics: [COLLECTED, word(m), pad(pick(enrolled))], data: word(m), block: FLOORS.moments + Math.floor(rand() * 400_000) });
  }
  return { chain, enrolled, spam, busy, oversized, strangers };
}

// A small world for the broken-endpoint runs: 20 enrolled wallets (half with activity), a few transfers and global
// events, no spam. `denseLaunchpad`: also a launchpad event in each of the newest 40 aligned 10,000-block ranges.
function smallWorld(denseLaunchpad = false): World {
  let seed = 11;
  const rand = () => ((seed = (seed * 1_103_515_245 + 12_345) % 2 ** 31) / 2 ** 31);
  const chain = new FakeChain(H);
  const enrolled = Array.from({ length: 20 }, (_, k) => addr(0x2000 + k));
  const strangers = Array.from({ length: 5 }, (_, k) => addr(0x9100 + k));
  const tokens = [addr(0x7100), addr(0x7101)];
  for (const [k, w] of enrolled.entries()) {
    if (k % 2) continue;
    const first = Math.floor(rand() * (H - 1_000));
    chain.firstTx.set(w, first);
    chain.add({ address: tokens[0], topics: [TRANSFER, pad(w), pad(strangers[k % 5])], data: word(k), block: first + Math.floor(rand() * (H - first)) });
    chain.add({ address: tokens[1], topics: [TRANSFER, pad(strangers[(k + 1) % 5]), pad(w)], data: word(k + 1), block: Math.floor(rand() * H) });
  }
  for (let m = 0; m < 15; m++) {
    chain.add({ address: addr(0x5100 + (m % 3)), topics: [CURVEBUY, pad(enrolled[m % 20]), pad(addr(0x6100 + m))], data: word(m),
                block: FLOORS.launchpad + Math.floor(rand() * (H - FLOORS.launchpad)) });
  }
  if (denseLaunchpad) {
    for (let k = 0; k < 40; k++) {
      chain.add({ address: addr(0x5100), topics: [CURVEBUY, pad(enrolled[k % 20]), pad(addr(0x6200 + k))], data: word(k), block: H - 5_000 - k * 10_000 });
    }
  }
  for (let m = 0; m < 3; m++) {
    chain.add({ address: FEE_SHARING, topics: [SHARING_CLAIMED, pad(tokens[1]), pad(enrolled[m])], data: word(m), block: FLOORS["fee-sharing"] + 100_000 * (m + 1) });
  }
  for (let m = 0; m < 5; m++) {
    chain.add({ address: MOMENTS_FACTORY, topics: [COLLECTED, word(m), pad(enrolled[m + 3])], data: word(m), block: FLOORS.moments + 50_000 * (m + 1) });
  }
  return { chain, enrolled, spam: "", busy: "", oversized: "", strangers };
}

// The fake endpoints: "wide" (rpc2-like), "liar" (declares refuses, clamps 100 blocks behind, and lies once: a log
// outside the range asked), "narrow" (rpc4-like), "tiny" (rpc1-like, declared batch 2 but refuses arrays).
const latency = (base: number) => (logs: number) => base + 2 * logs;
export const BEHAVIOUR: Record<string, FakeBehaviour> = {
  wide: { url: "https://wide.test", span: 10_000, spanMessage: "eth_getLogs is limited to a 10,000 range", straddle: "refuses", archive: true,
          arrays: "ok", throttleEvery: 7, behindEvery: { n: 5, lag: 30, kind: "refuses" }, latency: latency(150) },
  liar: { url: "https://liar.test", span: 10_000, spanMessage: "Block range is too large", straddle: "clamps", headLag: 100, archive: false,
          arrays: "ok", lieOnce: 3, latency: latency(150) },
  narrow: { url: "https://narrow.test", span: 1_000, spanMessage: "eth_getLogs is limited to a 1,000 range", straddle: "clamps", archive: true,
            arrays: "internal", behindEvery: { n: 3, lag: 40, kind: "clamps" }, latency: latency(100) },
  tiny: { url: "https://tiny.test", span: 100, spanMessage: "Block range is too large", straddle: "clamps", archive: true, arrays: "403",
          latency: latency(80) },
};
const ENDPOINTS: Endpoint[] = [
  { label: "wide", url: BEHAVIOUR.wide.url, span: 10_000, batch: 6, rps: 4, inFlight: 8, archive: true, straddle: "refuses", lag: LAG, priority: 10 },
  { label: "liar", url: BEHAVIOUR.liar.url, span: 10_000, batch: 6, rps: 4, inFlight: 4, archive: false, straddle: "refuses", lag: LAG, priority: 15 },
  { label: "narrow", url: BEHAVIOUR.narrow.url, span: 1_000, batch: 1, rps: 4, inFlight: 2, archive: true, straddle: "clamps", lag: LAG, priority: 20 },
  { label: "tiny", url: BEHAVIOUR.tiny.url, span: 100, batch: 2, rps: 4, inFlight: 2, archive: true, straddle: "clamps", lag: LAG, priority: 40 },
];

export async function setUp(world: World): Promise<PGlite> {
  const db = await historyDatabase();
  for (const [scan, floor] of Object.entries(FLOORS)) await db.query("select public.history_redefine_scan($1, null, null, $2, $2)", [scan, floor]);
  await db.query(`insert into public.profiles (wallet) select unnest($1::text[])`, [world.enrolled]);
  return db;
}

// The invariant, after a commit: every chain log of the committed range that the scan matches (for the wallets the
// commit carried, from their cap floor; for a global scan, each subject from its cap floor) is stored, and nothing else.
async function checkCommit(db: PGlite, chain: FakeChain, args: { scan: string; from: number; to: number; wallets: string[] | null }) {
  const s = SCANS[args.scan];
  const filter = { fromBlock: "0x" + args.from.toString(16), toBlock: "0x" + args.to.toString(16), address: s.addresses ?? undefined,
                   topics: [s.topic0] as (string[] | null)[] };
  const expected = new Map<string, Set<string>>();
  for (const l of chain.query(filter, chain.head)) {
    const subject = l.topics[s.walletTopic];
    if (!subject || !/^0x0{24}/.test(subject)) continue;
    const w = "0x" + subject.slice(26);
    if (!s.global && !args.wallets!.includes(w)) continue;
    if (!expected.has(w)) expected.set(w, new Set());
    expected.get(w)!.add(`${l.block}:${l.index}`);
  }
  const subjects = s.global ? [...expected.keys()] : args.wallets!;
  if (subjects.length === 0) return;
  const enrolled = s.global ? new Set(subjects)
    : new Set((await db.query<Any>("select wallet from public.history_wallets where wallet = any($1)", [subjects])).rows.map((r: Any) => r.wallet));
  const caps = new Map<string, number>((s.global
    ? (await db.query<Any>("select '0x' || encode(subject, 'hex') w, cap_floor::bigint::text f from public.history_subject_caps where scan = $1", [args.scan])).rows
    : (await db.query<Any>("select wallet w, cap_floor::bigint::text f from public.history_wallet_scans where scan = $1 and wallet = any($2) and cap_floor is not null", [args.scan, subjects])).rows)
    .map((r: Any) => [r.w, Number(r.f)]));
  const rows = (await db.query<Any>(`select '0x' || encode(subject, 'hex') w, block_number::bigint::text b, log_index i from public.history_logs
      where scan = $1 and block_number between $2 and $3`, [args.scan, args.from, args.to])).rows;
  const stored = new Map<string, Set<string>>();
  for (const r of rows) {
    if (!stored.has(r.w)) stored.set(r.w, new Set());
    stored.get(r.w)!.add(`${r.b}:${r.i}`);
  }
  for (const w of subjects) {
    if (!enrolled.has(w)) continue;
    const cap = caps.get(w) ?? 0;
    const have = new Set([...(stored.get(w) ?? [])].filter((k) => Number(k.split(":")[0]) >= cap));
    const want = new Set([...(expected.get(w) ?? [])].filter((k) => Number(k.split(":")[0]) >= cap));
    assertEquals(have, want, `${args.scan} ${args.from}-${args.to} ${w}: the committed range holds exactly the chain's logs`);
  }
}

// Invariant violations seen by the commit hook (asserted after each run, with the full message), and every commit made
// (for the served-history check of the wallets a test touched). Each Deno.test starts them empty.
export const violations: string[] = [];
const committed: { scan: string; from: number; to: number; wallets: string[] | null }[] = [];

const TEST_OPTIONS = { maxParsedBytes: 256 * 1_048_576, maxLogs: 1_000_000, firstTxPerRun: 60, firstTxConcurrency: 4, plan: { window: WINDOW } };

export function deps(db: PGlite, clock: VirtualClock, net: FakeNetwork, chain: FakeChain, extra: Partial<Deps> = {},
              dbOptions: PgliteDbOptions = {}, check = true): Deps & { commits: number } {
  const counter = { commits: 0 };
  const historyDb = pgliteDb(db, {
    busy: clock, sleep: clock.sleep,
    onCommit: async (args) => {
      counter.commits++;
      committed.push({ scan: args.scan, from: args.from, to: args.to, wallets: args.wallets });
      if (!check) return;
      try { await checkCommit(db, chain, args); } catch (err) { violations.push(String((err as Error).message).slice(0, 2_000)); }
    },
    ...dbOptions,
  });
  const lines: string[] = [];
  return Object.assign(counter, {
    db: historyDb, endpoints: ENDPOINTS.map((e) => ({ ...e })), fetch: net.fetch, now: clock.now, cpuNow: () => 0, sleep: clock.sleep,
    random: () => 0.5, log: (line: string) => { lines.push(line); }, isolateStartedAt: clock.now(), version: "test",
    setTimer: clock.setTimer,
    options: TEST_OPTIONS,
    ...extra,
  }) as Deps & { commits: number };
}

// Every wallet a commit carried, and every subject of a global commit's range: the wallets whose served history a commit
// changed.
function touchedWallets(chain: FakeChain): Set<string> {
  const out = new Set<string>();
  for (const c of committed) {
    if (c.wallets) { for (const w of c.wallets) out.add(w); continue; }
    const s = SCANS[c.scan];
    for (const l of chain.query({ fromBlock: hex(c.from), toBlock: hex(c.to), address: s.addresses ?? undefined, topics: [s.topic0] }, chain.head)) {
      const t = l.topics[s.walletTopic];
      if (t && /^0x0{24}/.test(t)) out.add("0x" + t.slice(26));
    }
  }
  return out;
}

// What history_read serves each wallet, page by page, equals the chain's logs scan by scan within what the scan says it
// covers (logs listed as omitted aside). Returns each wallet's first page.
async function assertServedMatchesChain(db: PGlite, chain: FakeChain, wallets: Iterable<string>): Promise<Map<string, Any>> {
  const firsts = new Map<string, Any>();
  for (const w of wallets) {
    const pages: Any[] = [];
    let cursor: string | null = null;
    do {
      const page: Any = (await as<Any>(db, "anon", null, "select public.history_read($1, $2) r", [w, cursor]))[0].r;
      pages.push(page);
      cursor = page.next;
    } while (cursor);
    const first = pages[0];
    firsts.set(w, first);
    for (const [scan, s] of Object.entries(SCANS)) {
      const doc = first.scans[scan];
      if (!doc) continue; // a wallet scan of an untracked wallet
      const covered: Range[] = doc.covered;
      const omitted = new Set((doc.omitted as Any[]).map((o) => `${parseInt(o.blockNumber, 16)}:${parseInt(o.logIndex, 16)}`));
      const served = new Set(pages.flatMap((p) => p.scans[scan].logs).map((l: Any) => `${parseInt(l.blockNumber, 16)}:${parseInt(l.logIndex, 16)}`));
      const want = new Set<string>();
      for (const r of covered) {
        const f = { fromBlock: hex(r[0]), toBlock: hex(r[1]), address: s.addresses ?? undefined,
                    topics: [s.topic0, ...Array(s.walletTopic - 1).fill(null), [pad(w)]] as (string[] | null)[] };
        for (const l of chain.query(f, chain.head)) { const k = `${l.block}:${l.index}`; if (!omitted.has(k)) want.add(k); }
      }
      assertEquals(served, want, `${w} ${scan}`);
    }
  }
  return firsts;
}

const summaries: Any[] = [];

Deno.test({ name: "history-indexer: runs converge on the fake chain, keeping the invariant", sanitizeOps: false, sanitizeResources: false }, async (t) => {
  violations.length = 0;
  committed.length = 0;
  const world = buildWorld();
  const { chain } = world;
  const db = await setUp(world);
  const clock = new VirtualClock(Date.parse("2026-10-08T12:00:00Z"));
  const net = new FakeNetwork(chain, clock, BEHAVIOUR);
  try {
    await t.step("repeated runs until nothing is left to read", async () => {
      for (let run = 0; run < 12; run++) {
        const d = deps(db, clock, net, chain);
        const summary = await runIndexer(d, {});
        summaries.push(summary);
        const c = summary.counts as Any;
        console.log(`  run ${run}: ${summary.stop} in ${summary.ms} ms (virtual), requests ${JSON.stringify(c.requests)}, commits ${c.commits}, ` +
                    `logs ${c.logs}, items ${JSON.stringify(c.items)}, firstTx ${JSON.stringify(c.firstTx)}, holes ${c.holesMarked}, ` +
                    `dense ${c.dense}, timeouts ${c.timeouts}, pastHead ${c.pastHead}, invalid ${c.invalid}, errors ${JSON.stringify(summary.errors)}`);
        assertEquals(violations, [], "the invariant after every commit");
        const items = Object.values(c.items as Record<string, number>).reduce((a, b) => a + b, 0);
        const firstTx = Object.values(c.firstTx as Record<string, number>).reduce((a, b) => a + b, 0);
        assert(["done", "deadline"].includes(String(summary.stop)), `run ${run}: ${summary.stop} ${JSON.stringify(c.errors ?? summary.errors)}`);
        if (summary.stop === "done" && items <= 6 && firstTx === 0) break; // only the follow of an idle chain is left
        assert(run < 11, "the backlog must drain");
        clock.t += 30_000;
      }
    });

    await t.step("every enrolled wallet's served history equals the chain's, within what is covered", async () => {
      const state = await one<Any>(db, "select head_block::bigint::text h from public.history_indexer_state");
      assertEquals(Number(state.h), H);
      const firsts = await assertServedMatchesChain(db, chain, world.enrolled);
      for (const w of world.enrolled) {
        const first = firsts.get(w);
        assertEquals(first.tracked, true);
        for (const [scan, s] of Object.entries(SCANS)) {
          const doc = first.scans[scan];
          const covered: Range[] = doc.covered;
          // Coverage: global scans down to their floors; every wallet's window; deep only for wallets with activity.
          const holes: Range[] = doc.holes;
          const floor = Math.max(s.global ? FLOORS[scan] : 0, doc.capFloor ?? 0);
          const deep = !s.global && (chain.firstTx.has(w) || chain.logs.some((l) => l.topics[0] === TRANSFER && (l.topics[1] === pad(w) || l.topics[2] === pad(w))));
          const low = s.global || deep ? floor : Math.max(floor, H - WINDOW + 1);
          const missing = subtract([[low, H]], merge([...covered, ...holes]));
          assertEquals(missing, [], `${w} ${scan}: [${low}, ${H}] covered or a hole`);
        }
      }
    });

    await t.step("spam: a hole at the spam block, older history intact, no cap; the busy wallet capped by count only", async () => {
      const spam = (await as<Any>(db, "anon", null, "select public.history_read($1, null, null, null, true) r", [world.spam]))[0].r.scans["transfers-in"];
      assertEquals(spam.holes, [[H - 50, H - 50]]);
      assertEquals(spam.capFloor, null);
      assertEquals(subtract([[0, H]], merge([...spam.covered, ...spam.holes])), []);
      const busy = (await as<Any>(db, "anon", null, "select public.history_read($1, null, null, null, true) r", [world.busy]))[0].r.scans["transfers-in"];
      assertEquals(busy.holes, [], "too slow or too dense never leaves a busy wallet with a hole or a density cap");
      const ins = chain.query({ fromBlock: "0x0", toBlock: "0x" + H.toString(16), topics: [[TRANSFER], null, [pad(world.busy)]] });
      const capFloor = ins[ins.length - 20_000].block; // HistoryStore.logCap: the newest 20,000, whole blocks
      assertEquals(busy.capFloor, capFloor);
      const stored = await one<Any>(db, "select log_count n from public.history_wallet_scans where wallet = $1 and scan = 'transfers-in'", [world.busy]);
      assertEquals(stored.n, ins.filter((l) => l.block >= capFloor).length);
      // The oversized log is listed as omitted, not served.
      const big = (await as<Any>(db, "anon", null, "select public.history_read($1, null, null, null, true) r", [world.oversized]))[0].r.scans.launchpad;
      assertEquals(big.omitted.map((o: Any) => parseInt(o.blockNumber, 16)), [2_200_000]);
    });

    await t.step("the straddle rule, the self-test, the lie, pacing and Retry-After", () => {
      for (const r of net.records) {
        if (r.label === "narrow" || r.label === "tiny" || r.label === "liar") {
          for (const p of r.pieces) if (!p.nothing) assert(p.to <= H - LAG, `${r.label} was given a piece ending at ${p.to}`);
        }
      }
      assertEquals(summaries[0].straddle.liar, "clamps", "the self-test caught the endpoint that only claims to refuse");
      assertEquals(summaries[0].straddle.wide, "refuses");
      assertEquals(net.lies, 1);
      const invalid = summaries.reduce((n, s) => n + (s.counts.invalid as number), 0);
      assertEquals(invalid, 1, "the lying answer was rejected");
      // The tiny endpoint refused an array once; every later request to it was a bare object.
      const tiny = net.records.filter((r) => r.label === "tiny");
      assert(tiny.filter((r) => r.array).length <= 1);
      for (const label of Object.keys(BEHAVIOUR)) {
        const starts = net.records.filter((r) => r.label === label).map((r) => r.at).sort((a, b) => a - b);
        for (const t0 of starts) {
          const burst = net.records.filter((r) => r.label === label && r.at >= t0 && r.at < t0 + 1_000);
          assert(burst.length <= 4, `${label}: more than 4 starts in a second: ${JSON.stringify(burst.map((r) => [r.at - t0, r.methods.join("+")]))}`);
        }
        const cap = ENDPOINTS.find((e) => e.label === label)!.inFlight;
        assert((net.maxInFlight[label] ?? 0) <= cap, `${label}: ${net.maxInFlight[label]} in flight > ${cap}`);
      }
      const wide = net.records.filter((r) => r.label === "wide");
      for (const r of wide.filter((x) => x.throttled)) {
        const next = wide.find((x) => x.at > r.at);
        if (next) assert(next.at >= r.end! + 2_000, `Retry-After honoured (${next.at - r.end!} ms)`);
      }
      assert(wide.some((r) => r.throttled), "the wide endpoint throttled at least once");
    });

    await t.step("summaries: valid JSON under 16 KB, counts only, no address; endpoint memory kept", async () => {
      for (const s of summaries) {
        const text = JSON.stringify(s);
        assert(text.length <= 16_384);
        assert(!/0x[0-9a-fA-F]{40}/.test(text), "no wallet address in a summary");
        assert(!text.includes(".test"), "no URL in a summary");
      }
      const memory = (await one<Any>(db, "select endpoints from public.history_indexer_state")).endpoints;
      assertEquals(Object.keys(memory).sort(), ["liar", "narrow", "tiny", "wide"]);
      assert(memory.liar.clampsUntil > 0, "the reclassification is remembered");
      assertEquals(memory.tiny.batch, 1, "the batch refusal is remembered");
      const runs = await one<Any>(db, "select count(*)::int n, count(released_at)::int r from public.history_indexer_runs");
      assertEquals(runs.n, runs.r);
      const firstTx = await one<Any>(db, "select count(*) filter (where first_tx_state = 'found')::int f, count(*) filter (where first_tx_state = 'none')::int z from public.history_wallets");
      assertEquals([firstTx.f, firstTx.z], [100, 50]);
      const found = (await db.query<Any>("select wallet, first_tx_block::bigint::text b from public.history_wallets where first_tx_state = 'found'")).rows;
      for (const r of found) assertEquals(Number(r.b), chain.firstTx.get(r.wallet), r.wallet);
    });

    await t.step("following the head: new blocks are read by the next run", async () => {
      chain.head = H + 3_000;
      const w = world.enrolled[4];
      const added: FakeLog = chain.add({ address: addr(0x7000), topics: [TRANSFER, pad(world.strangers[3]), pad(w)], data: word(1), block: H + 2_000 });
      // The head of the chain is read only by the refusing endpoint, which this fake throttles hard: allow a few runs.
      let served = false;
      for (let run = 0; run < 4 && !served; run++) {
        const summary = await runIndexer(deps(db, clock, net, chain), {});
        assert(["done", "deadline"].includes(String(summary.stop)), String(summary.stop));
        assertEquals(violations, []);
        const read = (await as<Any>(db, "anon", null, "select public.history_read($1, null, $2) r", [w, H]))[0].r;
        served = read.scans["transfers-in"].logs.some((l: Any) => parseInt(l.blockNumber, 16) === added.block);
        clock.t += 30_000;
      }
      assert(served, "the new transfer is served");
      chain.head = H;
    });
  } finally {
    clock.stop();
    await db.close();
  }
});

Deno.test({ name: "history-indexer: stops — a redefinition, pausing, two runs at once, slow commits", sanitizeOps: false, sanitizeResources: false }, async (t) => {
  violations.length = 0;
  committed.length = 0;
  const world = buildWorld();
  const { chain } = world;
  const db = await setUp(world);
  const clock = new VirtualClock(Date.parse("2026-10-08T12:00:00Z"));
  const net = new FakeNetwork(chain, clock, BEHAVIOUR);
  const snapshot = () => one<Any>(db, `select
    (select string_agg(id || covered::text || holes::text, ';' order by id) from public.history_scans) c,
    (select sum(def_version)::int from public.history_scans) v,
    (select string_agg(wallet || scan || covered::text || holes::text, ';' order by wallet, scan) from public.history_wallet_scans) w,
    (select count(*)::int from public.history_logs) n`);
  try {
    await t.step("a redefinition after the run read its state: the run stops with defs and stores nothing", async () => {
      const before = await snapshot();
      const d = deps(db, clock, net, chain, {}, {}, false);
      // Redefine every scan right after the run's state read (the definitions it builds filters from are then stale).
      const inner = d.db.state.bind(d.db);
      d.db.state = async (...args) => {
        const s = await inner(...args);
        for (const scan of Object.keys(SCANS)) await db.query("select public.history_redefine_scan($1, null, null, null, 9999999999)", [scan]);
        return s;
      };
      const summary = await runIndexer(d, {});
      assertEquals(summary.stop, "defs");
      const after = await snapshot();
      assertEquals([after.w, after.n, after.c], [before.w, before.n, before.c]);
      assertEquals(after.v, before.v + 5);
    });

    await t.step("paused mid-run: the run stops with paused at its next call", async () => {
      let calls = 0;
      const d = deps(db, clock, net, chain, {}, {}, false);
      const inner = d.db.commit.bind(d.db);
      d.db.commit = async (c) => {
        if (++calls === 3) await db.exec("update public.history_indexer_state set paused = true where id");
        return await inner(c);
      };
      const summary = await runIndexer(d, {});
      assertEquals(summary.stop, "paused");
      await db.exec("update public.history_indexer_state set paused = false where id");
      // A paused indexer is not even leased.
      await db.exec("update public.history_indexer_state set paused = true where id");
      assertEquals((await runIndexer(deps(db, clock, net, chain, {}, {}, false), {})).stop, "paused");
      await db.exec("update public.history_indexer_state set paused = false where id");
    });

    await t.step("two runs started together: one holds the lease, the other returns at once", async () => {
      const a = runIndexer(deps(db, clock, net, chain, { options: { workMs: 60_000, minRunMs: 1_000, plan: { window: WINDOW } } }, {}, true), {});
      const b = runIndexer(deps(db, clock, net, chain, {}, {}, false), {});
      const [ra, rb] = await Promise.all([a, b]);
      assertEquals([ra.stop === "busy" || rb.stop === "busy", ra.stop === "busy" && rb.stop === "busy"], [true, false]);
      assertEquals(violations, [], "the invariant after every commit of the run that held the lease");
    });

    await t.step("slow commits: smaller commits, one retry, the lease kept, the run ends before its deadline", async () => {
      let slow = 0;
      const d = deps(db, clock, net, chain, {}, {
        latency: (fn) => (fn === "history_commit" ? 3_000 : 0),
        inject: (fn) => (fn === "history_commit" && ++slow % 4 === 1 ? { code: "55P03", message: "canceling statement due to lock timeout" } : null),
      }, true);
      const started = clock.now();
      const summary = await runIndexer(d, {});
      const c = summary.counts as Any;
      assert(["done", "deadline"].includes(String(summary.stop)), String(summary.stop));
      assert(c.commitSlow > 0 && c.commitRetries > 0, JSON.stringify(c));
      assert(clock.now() - started <= 240_000 + 15_000 + 30_000 + 5_000, `${clock.now() - started} ms`);
      assertEquals(violations, [], "the invariant after every commit, the re-split retries of slow commits included");
    });

    await t.step("a run shut down mid-way leaves a consistent database", async () => {
      const signal: { shutdown?: string } = {};
      const d = deps(db, clock, net, chain, {}, {}, true);
      const inner = d.db.commit.bind(d.db);
      let n = 0;
      d.db.commit = async (c) => { if (++n === 2) signal.shutdown = "CPUTime"; return await inner(c); };
      const summary = await runIndexer(d, signal);
      assertEquals(summary.stop, "shutdown:CPUTime");
      assertEquals(violations, [], "the invariant after every commit before the shutdown");
      // Whatever this test's runs committed (and however they stopped), every touched wallet's served history equals
      // the chain's within what is covered.
      const touched = touchedWallets(chain);
      assert(touched.size > 0);
      await assertServedMatchesChain(db, chain, touched);
      const runs = await one<Any>(db, "select count(*)::int n, count(released_at)::int r from public.history_indexer_runs");
      assertEquals(runs.n, runs.r);
    });
  } finally {
    clock.stop();
    await db.close();
  }
});

Deno.test({ name: "history-indexer: broken endpoints — resting at the start, refusing everything, failing every call, no timestamps, a gateway error", sanitizeOps: false, sanitizeResources: false }, async (t) => {
  violations.length = 0;
  committed.length = 0;
  const T0 = Date.parse("2026-10-08T12:00:00Z");
  const getLogs = (r: { methods: string[]; pieces: { nothing: boolean }[] }) => r.methods.includes("eth_getLogs") && r.pieces.some((p) => !p.nothing);

  {
    const world = smallWorld();
    const { chain } = world;
    const db = await setUp(world);
    const clock = new VirtualClock(T0);
    const net = new FakeNetwork(chain, clock, BEHAVIOUR);
    try {
      await t.step("rpc2 resting at the start (a remembered Retry-After of 60 s): the head, the self-test and the reads go on without it", async () => {
        await db.query("update public.history_indexer_state set endpoints = $1::jsonb where id", [JSON.stringify({ wide: { restUntil: T0 + 60_000 } })]);
        const summary: Any = await runIndexer(deps(db, clock, net, chain), {});
        assert(["done", "deadline"].includes(String(summary.stop)), String(summary.stop));
        assertEquals(violations, []);
        const resting = net.records.filter((r) => r.at < T0 + 60_000);
        assert(resting.length > 0 && resting[0].at < T0 + 5_000, `the head was read at once (${resting[0]?.at - T0} ms)`);
        assertEquals(resting.filter((r) => r.label === "wide").length, 0, "nothing was sent to the resting endpoint");
        // Head-of-line: while rpc2 rests, the clamping endpoints read whatever they may (below head − lag).
        const meanwhile = resting.filter(getLogs);
        assert(meanwhile.length >= 20, `${meanwhile.length} log requests while rpc2 rested`);
        // Once ready, rpc2 is probed (deferred self-test) and reads the tops parked for a refusing endpoint.
        assertEquals([summary.straddle.wide, summary.straddle.liar], ["refuses", "clamps"]);
        const head = summary.head as number;
        assert(net.records.some((r) => r.label === "wide" && r.at >= T0 + 60_000 && r.pieces.some((p) => !p.nothing && p.to === head)),
               "the follow's top, parked for rpc2, was read by it");
        await assertServedMatchesChain(db, chain, world.enrolled);
      });

      await t.step("an endpoint refusing everything (HTTP 401) and one failing every call: sidelined, their pieces never holes", async () => {
        for (let run = 0; run < 6; run++) {
          clock.t += 30_000;
          const s = await runIndexer(deps(db, clock, net, chain), {});
          assertEquals(violations, []);
          if (s.stop === "done") break;
          assert(run < 5, "the small world converges");
        }
        // New blocks to follow, read first by two broken endpoints placed ahead of the others. Their span (100 blocks)
        // makes every global piece they get "minimal": three counted failures would make it a hole.
        chain.head = H + 3_000;
        const w = world.enrolled[2];
        const t1 = chain.add({ address: addr(0x7100), topics: [TRANSFER, pad(world.strangers[0]), pad(w)], data: word(9), block: H + 1_000 });
        chain.add({ address: addr(0x5100), topics: [CURVEBUY, pad(w), pad(addr(0x6300))], data: word(9), block: H + 1_500 });
        const behaviour: Record<string, FakeBehaviour> = {
          ...BEHAVIOUR,
          broken: { url: "https://broken.test", span: 100, spanMessage: "Block range is too large", straddle: "clamps", archive: true, arrays: "ok",
                    latency: latency(50), refuse: { status: 401, body: "unauthorized: the API key is invalid" } },
          strikes: { url: "https://strikes.test", span: 100, spanMessage: "Block range is too large", straddle: "clamps", archive: true, arrays: "ok",
                     latency: latency(50), callError: { code: -32000, message: "the API key is invalid" } },
        };
        const custom: Endpoint[] = [
          { label: "broken", url: "https://broken.test", span: 100, batch: 1, rps: 4, inFlight: 2, archive: true, straddle: "clamps", lag: LAG, priority: 0 },
          { label: "strikes", url: "https://strikes.test", span: 100, batch: 1, rps: 4, inFlight: 2, archive: true, straddle: "clamps", lag: LAG, priority: 1 },
        ];
        const net2 = new FakeNetwork(chain, clock, behaviour);
        const sums: Any[] = [];
        let served = false, sidelined = false;
        const memory = async () => (await one<Any>(db, "select endpoints from public.history_indexer_state")).endpoints;
        for (let run = 0; run < 8 && !(served && sidelined); run++) {
          clock.t += 30_000;
          const s = await runIndexer(deps(db, clock, net2, chain, { endpoints: [...custom, ...ENDPOINTS].map((e) => ({ ...e })) }), {});
          sums.push(s);
          assert(["done", "deadline"].includes(String(s.stop)), String(s.stop));
          assertEquals(violations, []);
          const read = (await as<Any>(db, "anon", null, "select public.history_read($1, null, $2) r", [w, H]))[0].r;
          served = read.scans["transfers-in"].logs.some((l: Any) => parseInt(l.blockNumber, 16) === t1.block) &&
                   read.scans.launchpad.logs.some((l: Any) => parseInt(l.blockNumber, 16) === H + 1_500);
          const m = await memory();
          sidelined = m.broken?.sidelinedUntil > clock.now() && m.strikes?.sidelinedUntil > clock.now();
        }
        assert(served, "the new blocks are followed");
        assert(sidelined, JSON.stringify(await memory()));
        assertEquals([...new Set(sums.flatMap((s) => s.counts.sidelined))].sort(), ["broken", "strikes"]);
        assertEquals(sums.reduce((n, s) => n + s.counts.holesMarked, 0), 0, "no piece refused by a broken endpoint became a hole");
        const holes = await one<Any>(db, `select (select count(*)::int from public.history_scans where holes <> '{}') g,
                                                 (select count(*)::int from public.history_wallet_scans where holes <> '{}') w`);
        assertEquals([holes.g, holes.w], [0, 0]);
        // At most SIDELINE_AFTER refusals reached the HTTP-refusing endpoint; the other took its strikes (and the head
        // reads that went to it first); both stay sidelined across runs (the endpoint memory).
        const broken = net2.records.filter((r) => r.label === "broken");
        const strikes = net2.records.filter((r) => r.label === "strikes" && getLogs(r));
        assert(broken.length <= SIDELINE_AFTER, `${broken.length} requests to the refusing endpoint`);
        assert(strikes.length <= STRIKES_TO_REFUSAL + SIDELINE_AFTER - 1, `${strikes.length} log requests to the failing endpoint`);
        // Sidelined, they get nothing in the next run, head reads included.
        clock.t += 30_000;
        const next: Any = await runIndexer(deps(db, clock, net2, chain, { endpoints: [...custom, ...ENDPOINTS].map((e) => ({ ...e })) }), {});
        assertEquals([next.counts.requests.broken ?? 0, next.counts.requests.strikes ?? 0, next.straddle.broken], [0, 0, "sidelined"]);
        assertEquals(violations, []);
        await assertServedMatchesChain(db, chain, touchedWallets(chain));
        chain.head = H;
      });
    } finally {
      clock.stop();
      await db.close();
    }
  }

  await t.step("logs without blockTimestamp, every slot held: the header reads never wait on the run's in-flight cap", async () => {
    const world = smallWorld(true);
    const { chain } = world;
    const db = await setUp(world);
    const clock = new VirtualClock(T0);
    const behaviour: Record<string, FakeBehaviour> = {
      notime: { url: "https://notime.test", span: 10_000, spanMessage: "eth_getLogs is limited to a 10,000 range", straddle: "refuses", archive: true,
                arrays: "ok", latency: latency(150), noTimestamps: true },
    };
    const endpoints: Endpoint[] = [
      { label: "notime", url: "https://notime.test", span: 10_000, batch: 1, rps: 4, inFlight: 8, archive: true, straddle: "refuses", lag: LAG, priority: 0 },
    ];
    const net = new FakeNetwork(chain, clock, behaviour);
    try {
      const summary = await runIndexer(deps(db, clock, net, chain, { endpoints, options: { ...TEST_OPTIONS, maxInFlightTotal: 2, workMs: 120_000 } }), {});
      const c = summary.counts as Any;
      assert(c.commits > 0 && c.logs > 0, JSON.stringify({ stop: summary.stop, c }));
      assertEquals(violations, []);
      const rows = (await db.query<Any>("select block_number::bigint::text b, block_timestamp::bigint::text s from public.history_logs where scan = 'launchpad'")).rows;
      assert(rows.length >= 40, `${rows.length} launchpad logs`);
      for (const r of rows) assertEquals(Number(r.s), chain.timestamp(Number(r.b)), `block ${r.b}`);
    } finally {
      clock.stop();
      await db.close();
    }
  });

  await t.step("a gateway error (HTML 502) for one range: three attempts each, and the rest of the backfill goes on", async () => {
    const world = smallWorld();
    const { chain } = world;
    const db = await setUp(world);
    const clock = new VirtualClock(T0);
    const bad = { from: 2_400_000, to: 2_400_100, status: 502 };
    const behaviour: Record<string, FakeBehaviour> = {
      gw: { ...BEHAVIOUR.wide, url: "https://gw.test", throttleEvery: undefined, behindEvery: undefined, gatewayError: bad },
    };
    const endpoints: Endpoint[] = [{ ...ENDPOINTS[0], label: "gw", url: "https://gw.test" }];
    const net = new FakeNetwork(chain, clock, behaviour);
    try {
      const summary = await runIndexer(deps(db, clock, net, chain, { endpoints }), {});
      assert(["done", "deadline"].includes(String(summary.stop)), String(summary.stop));
      assertEquals(violations, []);
      // The pieces holding the range (launchpad, fee-sharing, and the two wallet windows): each in a batch, then three
      // times alone, then dropped for this run — not retried for the whole run.
      const touching = net.records.filter((r) => r.pieces.some((p) => p.from <= bad.to && p.to >= bad.from));
      assert(touching.length <= 4 * 4, `${touching.length} requests touched the failing range`);
      assert((summary.counts as Any).failed >= 3);
      const lp = (await as<Any>(db, "anon", null, "select public.history_read($1, null, null, null, true) r", [world.enrolled[0]]))[0].r.scans.launchpad;
      assertEquals(subtract([[FLOORS.launchpad, H]], lp.covered), [[2_400_000, 2_409_999]], "everything else is covered");
      await assertServedMatchesChain(db, chain, world.enrolled);
    } finally {
      clock.stop();
      await db.close();
    }
  });
});

// ── A keyed Alchemy endpoint (ALCHEMY_MONAD_RPC) ────────────────────────────────────────────────────────────────

const ALCHEMY_KEY = "fAkEaLcHeMyKeY-must-never-be-logged-0123";   // a test value
const ALCHEMY_URL = `https://monad-mainnet.g.alchemy.test/v2/${ALCHEMY_KEY}`;
const ALCHEMY_PAYG: FakeBehaviour = {
  url: ALCHEMY_URL, span: 10_000_000, spanMessage: "block range too large", straddle: "clamps", archive: true, arrays: "403",
  maxLogs: 10, latency: latency(150),
};
const FREE_TIER = "Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range. Based on your parameters, " +
  "this block range should work: [0x0, 0x9]. Upgrade to PAYG for expanded block range.";

Deno.test({ name: "history-indexer: a keyed Alchemy endpoint — wide backfill, the follow on rpc2, its refusals, and never its URL", sanitizeOps: false, sanitizeResources: false }, async (t) => {
  violations.length = 0;
  committed.length = 0;
  const T0 = Date.parse("2026-10-09T12:00:00Z");
  const alchemy = alchemyEndpoint(ALCHEMY_URL).endpoint!;
  const endpoints = () => [alchemy, ...ENDPOINTS].map((e) => ({ ...e }));
  const redact = redactor([{ url: ALCHEMY_URL, label: "alchemy" }]); // as index.ts builds it
  const lines: string[] = [];
  const outputs: string[] = [];   // every summary, log line, run row and endpoint memory written
  const leaks = (text: string) => text.includes(ALCHEMY_KEY) || text.includes("alchemy.test") || text.includes("/v2/");
  const run = async (db: PGlite, clock: VirtualClock, net: FakeNetwork, chain: FakeChain) => {
    const summary: Any = await runIndexer(deps(db, clock, net, chain, { endpoints: endpoints(), redact, log: (l: string) => { lines.push(l); } }), {});
    outputs.push(JSON.stringify(summary));
    assertEquals(violations, [], "the invariant after every commit");
    assert(["done", "deadline", "budget"].includes(String(summary.stop)), `${summary.stop} ${JSON.stringify(summary.errors)}`);
    return summary;
  };
  const memory = async (db: PGlite) => (await one<Any>(db, "select endpoints from public.history_indexer_state")).endpoints;
  const stored = async (db: PGlite) => {
    outputs.push(JSON.stringify(await memory(db)));
    for (const r of (await db.query<Any>("select stop, summary, version from public.history_indexer_runs")).rows) outputs.push(JSON.stringify(r));
  };
  const getLogs = (r: { methods: string[]; pieces: { nothing: boolean }[] }) => r.methods.includes("eth_getLogs") && r.pieces.some((p) => !p.nothing);

  await t.step("Pay As You Go: backfill in wide ranges (split at Alchemy's suggested range), the follow and the head read on rpc2", async () => {
    const world = smallWorld(true);
    const { chain } = world;
    const db = await setUp(world);
    const clock = new VirtualClock(T0);
    const net = new FakeNetwork(chain, clock, { ...BEHAVIOUR, alchemy: ALCHEMY_PAYG });
    try {
      const sums: Any[] = [];
      for (let k = 0; k < 6; k++) {
        const s = await run(db, clock, net, chain);
        sums.push(s);
        if (s.stop === "done") break;
        clock.t += 30_000;
      }
      assertEquals(sums[sums.length - 1].stop, "done", "the backlog drains");
      assertEquals(sums[0].align, 5_000_000, "the run planned pieces as wide as alchemy's span");
      await assertServedMatchesChain(db, chain, world.enrolled);
      const a = net.records.filter((r) => r.label === "alchemy");
      const wide = a.filter(getLogs).filter((r) => r.pieces.some((p) => p.to - p.from + 1 > 10_000));
      assert(wide.length > 0, "alchemy read ranges wider than rpc2's 10,000 blocks");
      for (const r of a) for (const p of r.pieces) if (!p.nothing) assert(p.to <= H - LAG, `alchemy clamps: a piece ending at ${p.to}`);
      assert(a.every((r) => !r.array), "bare objects only");
      assert(!a.some((r) => r.methods.includes("eth_getBlockByNumber")), "the head is read on the public endpoints");
      assert(sums.reduce((n, s) => n + s.counts.dense, 0) > 0, "Alchemy's 10K-log cap was met and split at its suggested range");
      // Everything above head − lag (the follow's top) was read by the refusing endpoint only.
      const top = net.records.filter((r) => r.pieces.some((p) => !p.nothing && p.to > H - LAG));
      assertEquals([...new Set(top.map((r) => r.label))], ["wide"]);
      // The backfill's blocks: most of them read by alchemy, in a few wide requests.
      const blocks = (label: string) => net.records.filter((r) => r.label === label && getLogs(r))
        .reduce((n, r) => n + r.pieces.reduce((m, p) => m + (p.nothing ? 0 : p.to - p.from + 1), 0), 0);
      const all = ["alchemy", ...Object.keys(BEHAVIOUR)].reduce((n, l) => n + blocks(l), 0);
      assert(blocks("alchemy") > all / 2, `alchemy read ${blocks("alchemy")} of ${all} blocks`);
      console.log(`  alchemy: ${a.length} requests (${wide.length} wider than 10,000 blocks), ${blocks("alchemy")} of ${all} blocks; ` +
                  `others: ${JSON.stringify(Object.fromEntries(Object.keys(BEHAVIOUR).map((l) => [l, net.records.filter((r) => r.label === l).length])))}`);
      await stored(db);
    } finally {
      clock.stop();
      await db.close();
    }
  });

  await t.step("the Free tier: one refused request, then no log reads for a day; the others carry the backfill; no hole", async () => {
    const world = smallWorld();
    const { chain } = world;
    const db = await setUp(world);
    const clock = new VirtualClock(T0);
    const net = new FakeNetwork(chain, clock, { ...BEHAVIOUR, alchemy: { ...ALCHEMY_PAYG, span: 10, spanMessage: FREE_TIER, spanStatus: 400 } });
    try {
      const first = await run(db, clock, net, chain);
      assertEquals(net.records.filter((r) => r.label === "alchemy" && getLogs(r)).length, 1);
      assert(first.errors.some((e: string) => e.startsWith("alchemy: its plan refuses eth_getLogs ranges (HTTP 400")), JSON.stringify(first.errors));
      const m = await memory(db);
      assert(m.alchemy.logsOffUntil >= T0 + 86_000_000, JSON.stringify(m.alchemy));
      assertEquals(m.alchemy.span, undefined, "not mistaken for a 10-block span");
      clock.t += 30_000;
      const second = await run(db, clock, net, chain);
      assertEquals(second.straddle.alchemy, "nologs");
      assertEquals(net.records.filter((r) => r.label === "alchemy" && getLogs(r)).length, 1, "no further log request this day");
      assertEquals(first.counts.holesMarked + second.counts.holesMarked, 0);
      await stored(db);
    } finally {
      clock.stop();
      await db.close();
    }
  });

  await t.step("a bad key (401), a spent month (429), a failing fetch, errors quoting the URL: sidelined or off, never quoted", async () => {
    const world = smallWorld();
    const { chain } = world;
    const db = await setUp(world);
    const clock = new VirtualClock(T0);
    const cases: { name: string; behaviour: Partial<FakeBehaviour>; expect: (m: Any, requests: number, s: Any) => void }[] = [
      { name: "401", behaviour: { refuse: { status: 401, body: `{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Must be authenticated! ${ALCHEMY_URL}"}}` } },
        expect: (m, n, s) => {
          assertEquals(n, 1, "one request, then sidelined");
          assert(m.alchemy.sidelinedUntil > clock.now(), JSON.stringify(m.alchemy));
          assert(s.errors.includes("alchemy: HTTP 401: sidelined for 15 min (the key, or Monad not enabled for it?)"), JSON.stringify(s.errors));
          assert(s.counts.sidelined.includes("alchemy"));
        } },
      { name: "403 text", behaviour: { refuse: { status: 403, body: `Monad is not enabled for this app. Visit https://dashboard.alchemy.test/apps/x?key=${ALCHEMY_KEY}` } },
        expect: (m, n) => { assertEquals(n, 1); assert(m.alchemy.sidelinedUntil > clock.now()); } },
      { name: "spent", behaviour: { refuse: { status: 429, body: "Monthly capacity limit exceeded." } },
        expect: (m, n, s) => {
          assertEquals(n, 1);
          assertEquals(m.alchemy.offUntil, Date.parse("2026-10-10T00:00:00Z"));
          assert(s.errors.some((e: string) => e.startsWith("alchemy: monthly capacity spent (HTTP 429)")), JSON.stringify(s.errors));
        } },
      { name: "fetch throws", behaviour: { throwFetch: `error sending request for url (${ALCHEMY_URL}): client error (Connect)` },
        expect: (_m, n) => assert(n >= 1) },
      { name: "call errors", behaviour: { callError: { code: -32000, message: `invalid api key ${ALCHEMY_KEY} for ${ALCHEMY_URL}` } },
        expect: (m, n) => { assert(n >= 1); assert(m.alchemy.sidelinedUntil > clock.now() || (m.alchemy.strikes ?? 0) > 0, JSON.stringify(m.alchemy)); } },
    ];
    try {
      for (const c of cases) {
        // A fresh start for alchemy's memory each time; the chain moves on, so there is new work to hand it.
        await db.query("update public.history_indexer_state set endpoints = endpoints - 'alchemy' where id");
        await db.exec("delete from public.history_wallet_scans; delete from public.history_logs");
        await db.query(`update public.history_scans set covered = '{}', holes = '{}', head_block = null where true`);
        const net = new FakeNetwork(chain, clock, { ...BEHAVIOUR, alchemy: { ...ALCHEMY_PAYG, ...c.behaviour } });
        await db.query("insert into public.history_wallet_scans (wallet, scan) select w.wallet, s.id from public.history_wallets w, public.history_scans s where s.kind = 'wallet' on conflict do nothing");
        const s = await run(db, clock, net, chain);
        const requests = net.records.filter((r) => r.label === "alchemy").length;
        c.expect(await memory(db), requests, s);
        assertEquals(s.counts.holesMarked, 0, `${c.name}: an endpoint's refusal never makes a hole`);
        await stored(db);
        clock.t += 30_000;
      }
    } finally {
      clock.stop();
      await db.close();
    }
  });

  await t.step("nowhere: the key, the host or the path in a log line, an error, a summary, a run row or the endpoint memory", () => {
    assert(lines.length > 0 && outputs.length > 0);
    for (const text of [...lines, ...outputs]) assert(!leaks(text), `leaked: ${text.slice(0, 300)}`);
  });
});
