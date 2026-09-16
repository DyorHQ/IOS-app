# Red-team review — Execution Architecture & iOS/Worker Engineering ("the Spine")

Reviewer stance: skeptical senior engineer. Verified the design against the brief AND against the live code it
claims to build on (`PerplTradeClient.swift`, `PerplTrading.swift`, `MMWatcher.swift`, `worker/index.ts`,
`PerplExchange.swift`). Verdict up front: **solid-with-fixes.** The architecture decision is the right one and
the custody/kill design is genuinely excellent, but there are five real correctness/risk holes — one of them
load-bearing — that will bite before this ships.

---

## Lens 1 — iOS feasibility

**Overall: the core call is correct.** iOS suspends the app within seconds of backgrounding; a 10–1000-min
requoting loop and a persistent authenticated socket cannot live on-device. Moving the executor into a Cloudflare
Durable Object and making the phone a cockpit is the only architecture that meets the headline promise. The
"compute in `actor MMEngine`, send from the one `@MainActor PerplTrading`" split is clean and matches how the code
is already structured. BGTasks-as-notify-only (not executor) is exactly right per brief §4.

Grounding confirms the design's premises: `worker/index.ts` really is a vinext (Next-on-Workers) entry that already
dials Perpl's WS via `fetch(url,{Upgrade:'websocket'})` and returns `upstream.webSocket` — so the outbound-WS
pattern the DO needs exists in-repo. `PerplTrading.enableForwarding` really does treat a confirmed tx as authority
(not the WS `fw` echo). `MMWatcher.tick` really does bail on `try?`→nil rather than treating it as flat.
`MMExecutor.stop` really does cancel+flatten+verify-clean. Good — "build on this" is realistic.

Problems:

1. **SSE "survives phone backgrounding/foregrounding cleanly" is overstated (medium).**
   *Why it breaks:* a `URLSession.bytes(for:)` stream is suspended within seconds of the app backgrounding, same as
   any other connection. SSE survives the *transition* (reconnects with `Last-Event-ID` on foreground) but does NOT
   receive in the background. The "phone in a pocket, alert me on max-loss" story therefore rests entirely on APNs
   — which §8 flags as not yet wired. So the alerting half of the value prop is currently unbuildable, not just
   "to be integrated."
   *Fix:* reword the SSE claim to "reconnects cleanly on foreground"; make APNs (Worker→phone push on
   max-loss/error/completion/key-expiry) a hard prerequisite, not a footnote; and state that until APNs exists a
   backgrounded phone learns nothing until reopened. The DO is still authoritative, so the *session* is safe — only
   *notification* is gated.

2. **The DO's mark-price source is unspecified (medium).** §5 `tick()` needs `mark`, and real-time max-loss needs
   it too (see Risk #3), but the component map only gives the DO the *trading* WS. The DO must also hold a
   *market-data* WS (`market-state@143`/`order-book@<id>`), which is unauthenticated and does NOT count against the
   4-trading-socket cap — so it is free, but it must be named as a component and wired.

3. **Multi-hour outbound WebSocket from a DO — feasibility + cost verification (low/medium).** An outbound *client*
   WS obtained via `fetch(...,{Upgrade})` is **not hibernatable** (WS Hibernation covers accepted *server* sockets).
   The DO must stay resident for the whole session, billed for continuous active duration × concurrent wallets, and
   is still evictable — on eviction the socket drops and quotes go stale until the alarm reconnects (interacts with
   Risk #4). The alarm-reconnect design mitigates correctness; confirm CF supports multi-hour outbound client WS and
   understand the GB-s billing before promising 1000-min sessions.

4. **Sendable claim is loosely argued (low).** "`MMSessionConfig`/`MMStrategy`, already `Codable/Hashable` →
   naturally `Sendable`" is not sound: `Codable`/`Hashable` do not confer `Sendable`. The *new* types explicitly
   declare `Sendable` (good), but the existing `MMStrategy` value crosses the `actor MMEngine` boundary and must be
   made (or confirmed) `Sendable` — otherwise strict-concurrency builds fail. Trivial to fix, but state it.

---

## Lens 2 — Perpl correctness (against brief §2)

Correct and grounded: one-socket-per-wallet via `PerplSocketDO(idFromName(walletLower))` (rq is per-account, so
one socket per wallet is mandatory — right call); phone releases its trading socket on arm; `lb:0` on every order
(matches `PerplOrder.json`'s `"lb": lastExecutionBlock` with the "Perpl substitutes the ttl window" comment);
rq re-seed `= max(rq:last, AccountUpdate.lfr)` (matches `lastForwardedRq = max(..., lfr)` at line 378); keep-alive
`{mt:1}`/30s = 2/min (matches the code comment); `mt:3` ack code 0 = admitted-for-forwarding-only with real
outcome on `mt:24` (the design correctly notes the current Swift client keys off `mt:3`/on-chain only and must add
`mt:24`/`mt:26`); scope_mask=2 = no-withdrawal. All good.

**Load-bearing defect:**

5. **PostOnly (fl:1) is NOT emitted on the WS `mt:22` path the executor uses — the whole amend-first loop assumes
   protection that isn't wired (CRITICAL).**
   *Evidence:* `PerplOrderFrame.json` emits `"fl": ioc ? 4 : 0` — only IOC(4) or GTC(0); there is **no fl:1 path**.
   `OrderInput.postOnly:true` (set in `MMExecutor.place`) is consumed ONLY by the on-chain ABI route
   (`PerplExchange.swift:107 .bool(input.postOnly && kind==.limit)`), never by the keyless WS route. So today's v1
   keyless maker entries go out **GTC, not PostOnly**, and the proposed `requote.ts`/`MMEngine` inherit that.
   *Why it breaks:* the design's §5 loop moves orders toward market with `t:7` amend to "stay near market," and §5
   explicitly reasons about "PostOnly resting order." Without fl:1, an amend (or a place) that lands crossing the
   book **executes as a taker fill** instead of being rejected — it pays the taker fee (not ~1.5bp maker), takes an
   aggressive position the MM never intended, silently breaks the ~2.5bp/leg maker economics and any maker-rebate
   premise, and defeats the "post-only reject → reprice" safety the design leans on. (v1 only dodges this because
   `MMExecutor` skips levels that cross *at placement*; the new loop's whole point is to move orders, so it will
   cross.)
   *Fix:* add a `postOnly` flag to `PerplOrderFrame`/`PerplOrders` and emit **fl:1** on the WS path (brief §2:
   fl 1=PostOnly); mirror it in `worker/mm/perplTrading.ts`; and handle the post-only-reject outcome on
   `mt:24`/`mt:3` by repricing one tick behind, never blind-retrying at the crossing price. This is the single most
   important fix in the section — the brief lists post-only as a hard fact and the design depends on it, but it
   isn't on the code path.

**Field precision:**

6. **Bracket linkage `tr` vs `lp` is conflated (medium/low).** §4.1/§5/§7 say "linked `tr`/`lp` TP/SL," but they
   are different mechanisms. The live frame builder links a bracket via **`tr` = linkedRequestId** (set at entry
   time, before any position exists) — that's how "never leave a naked entry" is achievable *atomically*. Brief §2
   describes the **`lp` = linkedPositionId** path (a position id only exists post-fill, from `mt:26/27`). The design
   should state precisely: entry-time bracket = `tr` (linked request id); post-fill reduce-only Close = `lp`. It
   also correctly flags the open question of whether `t:7 Change` preserves `tr`/`lp` on amend — keep that flag;
   if amend drops linkage, the "never naked" invariant forces cancel+replace-with-re-link for that level.

**Rate budget:** capacity-4 token bucket + 1.97/s refill, ping counted separately (118 order + 2 ping = 120) is
consistent with the brief. Fine — but see Risk #4 (fairness) and Risk #3 (emergency ops are rate-limited too).

---

## Lens 3 — Risk & economics

The honest frame is respected: two-sided real-book liquidity, Cost/$1M surfaced live, no costless-profit copy, the
dual kill switch. The base Cost/$1M math checks out: round-trip of N = 2N volume, cost 2×2.5bp×N = 5bp·N ⇒
$250/$1M. But several paths silently lose money or breach a guardrail:

7. **Idempotency key collides with amend-in-place — can double-place or orphan (HIGH).**
   *Why it breaks:* the intent ledger is keyed `levelId = market:side:priceBucket:generation` (§4.2/§7), but §5
   amends orders *in place* (keeps the `oid`, changes the price). When price drifts across a bucket boundary the
   *same physical order* now maps to a *different* `levelId` — the ledger entry (with the `oid`) is stranded under
   the old key while the new key has no `oid`. On crash-restart mid-amend, reconcile sees a resting order it can't
   match to the new key → re-places → **double-place** (or cancels a live order it thinks is orphaned). Two desired
   levels can also collapse into one bucket after a move → key collision.
   *Fix:* key the ledger by a **stable slot identity** (`market:side:rungIndex:generation`), with `targetPrice`/
   `targetSize` as mutable *fields* updated on amend — not part of the key. Then amend-in-place keeps the same key
   and reconcile maps `oid`→slot cleanly. Keep on-chain `openOrders` as the truth for "what rests"; use the ledger
   only for in-flight (sent, no `mt:24` yet) dedup, and pair unacked live orders to desired slots by side+price+size
   before ever placing (so a crash between send and `mt:24` can't double-place).

8. **Attended (on-device) and Hybrid (DO) can run concurrently on the same wallet → double-place, self-match, and
   rq collision (HIGH).**
   *Why it breaks:* the DO is the single arbiter *for Hybrid*, but Attended runs on-device independent of the DO.
   Nothing stops a user arming Attended on ETH while a Hybrid ETH session runs. Two independent quoters on one
   market = double exposure and self-matching. Worse, both open a trading socket and both seed rq from the same
   account `lfr` → **two sockets issuing the same rq numbers** → rejects/misattribution (brief: rq is per-account).
   *Fix:* make the DO the per-wallet mutual-exclusion authority. Attended must register a lease with the DO (or the
   DO must refuse to arm a market that an Attended lease holds, and vice versa). One live quoter per wallet+market,
   full stop; and never let two sockets on one wallet both source rq.

9. **Max-loss guardrail: detection latency + rate-limited emergency exit + taker-cost overshoot (HIGH).**
   *Why it breaks:* max-loss is checked on the requote tick (Aggressive 5s … Passive 30s) and on `mt:24`. Between
   ticks a fast move can blow past `maxLossPct × margin` before the next check. Then teardown is itself gated by the
   1.97 ops/s bucket, and the flatten is a **taker IOC with 150bps slippage** (`MMWatcher.closePosition(...,
   slippageBps:150, ioc:true)`), so the exit both lands late and lands expensive. Portfolio max-loss is coarser than
   tread.fi's "real-time cancel/flatten."
   *Fix:* (a) subscribe the DO to market-data mark and check max-loss on every mark update, not only on ticks;
   (b) size per-position native TP/SL triggers so their worst-case sum ≤ maxLoss (sub-tick backstop that fires even
   if the DO is down); (c) on a max-loss trip, **flatten first** (one net Close per market) ahead of cancels in the
   budget, and account the taker+slippage cost in the risk display.

10. **Cross-session budget starvation → stale quotes get picked off (MEDIUM).**
    *Why it breaks:* one socket, one 118/min budget, N markets, no described fairness. A volatile market's requote
    can consume the whole bucket each tick; other markets' quotes aren't refreshed, drift from mid, and get
    adversely filled (you're the stale resting order the market runs through). Silent, steady losses.
    *Fix:* per-session fair-share of the bucket (or priority to "cancel stale before starve"): if a session can't
    be requoted within k ticks, cancel its exposed side rather than leave it resting mispriced.

11. **Self-trade prevention is absent — a compliance slip, not just a cost (HIGH for the ethics narrative).**
    *Why it breaks:* the whole legitimacy story (brief §0) is "filled by the real book, no self-matching." But a
    two-sided ladder with a tight spread on a thin market can **match your own bid against your own ask** — during
    spread compression or a requote race that transiently posts an ask ≤ your own resting bid. That is self-trade =
    wash volume = exactly what the compliance line forbids, and on Perpl it just churns your own fees.
    *Fix:* confirm whether Perpl has venue STP; regardless, enforce in the engine that best resting bid price <
    best resting ask price at all times, and **sequence requote ops** (cancel/raise the near side before lowering
    the opposite side) so you never transiently cross your own book. Add this to the compliance section as an
    explicit guarantee.

12. **Taker-flatten cost is missing from Cost/$1M (MEDIUM).** Every graceful stop, max-loss trip, and time-box
    expiry flattens with a taker IOC + 150bps slippage. The headline $250/$1M assumes all-maker; a short/choppy
    session that stops and restarts pays materially more. *Fix:* fold flatten (taker fee + realized slippage) into
    the live `costPerMillion`, and prefer maker/reduce-only limit exits on graceful stop where time allows,
    reserving IOC for emergencies.

---

## What is genuinely strong — keep it

- **The architecture decision (Hybrid DO executor + phone cockpit) and its honesty.** Correct given iOS; the
  "why not A / why not B" is tight and right.
- **The dual kill switch** — phone fires `allowOrderForwarding(false)` on-chain from the user's own wallet
  (`sr:34` kills every forwarded order) **in parallel with** `POST /kill`, so trading stops even if the Worker is
  down/compromised. This is the trust anchor that makes delegated custody defensible. Grounded in the existing
  confirmed-tx-is-authority pattern. Keep exactly as-is.
- **Secret-in-DO custody:** key generated in the DO, phone only ever signs the EIP-712 binding the *public* key to
  scope-2; secret AES-GCM-wrapped, never in Postgres (goes further than the existing `copy_grants` table). Strong.
- **"Failed read ≠ flat" elevated to a hard DO invariant, with on-chain `openOrders`/`positions` as source of
  truth** (not the cached WS view). This is the single most important correctness rule in v1 and the design
  preserves and generalizes it.
- **Durable rq re-seed `max(stored, lfr)`** — makes the in-memory rule crash-safe. Correct.
- **Amend-first requoting** to fit the 1.97 ops/s budget — the right mechanism (once fl:1 is actually wired).
- **One DO per wallet** (rq and the 4-cap are per-account) multiplexing N market sessions — correct primitive.
- **SSE + Supabase mirror for re-attach**, and scheduled sessions as a `state='scheduled'` DO alarm with no phone
  present — a clean free capability of the server executor.
- **Honest self-flagging** of the real open questions (amend linkage, key TTL, delegate path, APNs, mt:24 as the
  event source). This section knows where its own soft spots are.

---

## Added external/API needs surfaced by this review (beyond §9's list)

- Confirm **Perpl WS mt:22 accepts fl:1 (PostOnly)** and its reject signature (so the executor can reprice) — the
  api-docs the design cites should nail this before the loop is built (ties to CRITICAL #5).
- Confirm **CF Durable Objects support multi-hour outbound client WebSockets** and the active-duration billing
  model (ties to iOS #3).
- Confirm whether **Perpl provides venue-side self-trade prevention** (ties to Risk #11); if not, engine-side STP is
  mandatory.
- The already-listed APNs `.p8`/Key ID/Team ID is not optional — the backgrounded-alerting value prop depends on it.
