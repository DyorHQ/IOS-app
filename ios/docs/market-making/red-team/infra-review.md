# Red-team review — "Perpl Execution & Order-Lifecycle Engineering" (file: mm-section-infra.md)

Reviewer: skeptical senior / order-router. Verified against live code:
`DyorKit/.../Perpl/PerplTradeClient.swift` (+`PerplModels.swift`), `DyorHQ/Wallet/PerplTrading.swift`,
`DyorHQ/Strategy/MMWatcher.swift`, `worker/index.ts`.

**Verdict: solid-with-fixes.** The wire/truth/idempotency architecture is genuinely good and it correctly
catches a real v1 bug (post-only never wired). But it ships one dangerous iOS regression (protect-on-fill vs
suspension), rests its whole cost model on an untested Perpl primitive (amend), and has budget + kill-path holes
that can silently lose money or strand positions. Fix C1–C4 before build.

Note up front: **the filename says `infra` but this document is the execution/order-router section** ("section
owner: exchange-connectivity / order-router") and it *punts* iOS background execution and the worker runtime to a
separate "infra" dep (§12). Do not credit this section with solving iOS background execution — it explicitly
assumes "my loop lives inside whatever foreground/worker lifetime infra provides." See I2.

────────────────────────────────────────────────────────────
## CRITICAL (breaks, loses money, or orphans exposure)

### C1 — Protect-on-fill silently removes the "protection works while the app is closed" safety net on-device
**Issue.** §4.3 replaces the v1 mechanism (TP/SL placed *atomically with the entry* via `tr`/`linkedRequestId`,
`submitBracket`) with "protect-on-fill": place the reduce-only TP/SL only *after* an mt:24 fill arrives. The design
runs "the identical engine … on-device (Architecture B) and … worker (C)" (§0), so protect-on-fill is proposed for
the device too.
**Why it breaks.** iOS suspends the app seconds after it backgrounds (brief §4). The current code places the
trigger with the entry precisely so the keeper fires it server-side even when the app is dead — MMWatcher's own
header: exits "work even when the app is closed," and the brief calls native venue triggers "the current safety
net." With protect-on-fill, if a resting entry fills while the app is suspended, **mt:24 never arrives, `onFill`
never runs, and the leveraged position sits with no stop until the user reopens the app** — unbounded naked
exposure. None of the §4.3 backstops cover "device suspended at the moment of fill" (market-flatten-on-protect-fail
and the max-loss kill both also require the engine to be alive). This is a straight regression from v1 and the
single most dangerous item in the doc.
Also note the design's own justification is wrong: it says "a resting stop can't be pre-armed while flat because
`lp` needs a live position, so protect-on-fill is the earliest correct moment." But v1 pre-arms via **`tr`**
(`linkedPositionId: nil`, `linkedRequestId = entryRq`), which the wire supports ("activate when this request
trades") and which the doc itself acknowledges in §13. So the tr-linked bracket already protects from the instant
of fill, server-side, app-independent — earlier and crash-safe than protect-on-fill.
**Fix.** Keep the **tr-linked bracket** as the on-device (B) protection path — protection must be armed at
placement, not at fill. Use protect-on-fill **only in the always-on worker (C)**, where the executor is guaranteed
alive to react to mt:24. If the amend/coupling concern is real, resolve the §13 question (does `t:7` preserve a
tr-linked trigger?); if it does not, only amend the few levels that have no armed protection, and cancel+replace
the rest — do not trade away the safety net for the whole ladder.

### C2 — The entire rate-budget/cadence thesis rests on amend (`t:7`), which is unused and unproven in this codebase
**Issue.** §4.2/§5 argue "amend is 2× the cadence of cancel+replace," "requoting is cheap," and size the whole
120/min plan around amend as the common case. Grep confirms **`PerpOrderType.change` exists but has zero
builders and zero call sites** — amend has never been sent to Perpl from this app. §2's `PerplOrders.change` is
new and untested.
**Why it breaks.** If Perpl implements Change as an internal cancel+replace, it costs 2 ops (not 1), can drop the
`oid`, and/or reset queue position — collapsing the budget tables (the "amend full-requote period" column becomes
the "cancel+replace" column) and the "amend never leaves a gap" claim. The design would then over-promise cadence
and, worse, quietly over-spend the rate budget and hit 1008.
**Fix.** Before committing to amend-centric budgeting, empirically verify on Perpl testnet that `t:7` (a) returns/
keeps the same `oid`, (b) is a single forwarded request, (c) preserves `fl:1` post-only and reduce-only. Build the
cancel+replace path as a first-class fallback and make the budget model *default to the pessimistic (cancel+replace)
column* until amend is observed to behave. Don't ship the optimistic numbers as the plan of record.

### C3 — The 120 req/min budget has zero margin and omits sign-in / reconnect frames
**Issue.** §5 allocates 2 (keep-alive) + 100 (steady bucket, refill = exactly 100/min) + 18 (burst reserve) =
**exactly 120**. Nothing is reserved for the `mt:29` sign-in sent on *every* (re)connect, keep-alive timing jitter
(can be 3 in a minute near a boundary), or the re-place burst immediately after a reconnect/reject-storm.
**Why it breaks.** Perpl's limit is "~120 requests/min"; a rolling-window limiter trips on the 121st frame. The
unbudgeted frames all cluster at reconnect — the same moment the burst reserve and re-seed are firing — so the
design is most likely to breach the cap exactly when it's mid-recovery, and a 1008 rate-limit close then strands the
resting ladder.
**Fix.** Budget to a ceiling of ~105–110, not 120: steady ~85–90/min, burst reserve ~15, and an explicit ~5/min
line for connect + keep-alive jitter. Treat the reconnect re-place burst as drawing from the burst reserve, and
add sign-in to the accounting.

### C4 — The kill/teardown path can exceed its own budget, and the `allowOrderForwarding(false)` backstop may neuter pre-placed stops
**Issue.** §5/§8 size the burst reserve at 18 and teardown at "10 cancels (+ up to 5 protect cancels)" = 15. That
omits the **market-flatten of every filled level** (each is a close order). A 2-sided N=5 ladder with several
fills needs up to 10 cancels + 5 protect-cancels + 5 flattens ≈ 20 > 18. Separately, §7 offers
`allowOrderForwarding(false)` as the ultimate kill.
**Why it breaks.** (a) The kill switch can hit 1008 mid-flatten and strand open positions at the worst possible
moment. (b) `allowOrderForwarding(false)` stops *new* forwarded orders (sr:34) — so once it's off you can no
longer place the market closes needed to flatten. And it is unverified whether it also disables the keeper's
already-resting TP/SL triggers; if it does, the "global kill" leaves open positions with neither protection nor a
route to flatten.
**Fix.** Sequence the kill as **flatten-first (forwarding ON) → verify flat → then forwarding OFF**. Let the kill
path use the full socket budget (not a fixed 18) and, when throttled, **prioritize flattens over cancels** — an
unfilled cancelled order is harmless, an unflattened leveraged position bleeds. Confirm with Perpl whether
`allowOrderForwarding(false)` preserves resting keeper triggers before relying on it as the safety backstop.

────────────────────────────────────────────────────────────
## IMPORTANT (fix, not fatal)

### I1 — oid adoption is single-point-dependent on fresh RPC and uses a fuzzy match
The engine learns `oid`s by matching on-chain `openOrders` by side+priceBucket+size (§3), and the brief warns
public Monad RPC can serve ~24h-stale state. Stale reads → levels "pinned"/immovable indefinitely, or adoption of
a gone/wrong oid → orphaned amends or duplicate places. The side+priceBucket+size key is ambiguous after a
shrink/re-seed when two levels share a bucket+size. **Fix:** make a fresh, current-state RPC a *hard prerequisite*
(not the §13 "possible API-need"); add a deterministic tiebreaker (placement order / nearest-unmatched) to the
match; run reconcile after *any ack timeout* (not just reject storms), since a silently-failed place otherwise
stays pinned until the 15s slow reconcile; and pursue whether the trading WS pushes an OrderUpdate carrying `oid`
(§13/§14) — that removes the whole pin-latency + RPC dependency.

### I2 — Cross-section scoping: iOS background execution and the DO runtime are punted, and the worker is greenfield-er than implied
This section assumes infra supplies the foreground/worker lifetime; it does not solve background execution. Reality
check on the worker: `worker/index.ts` is a **73-line stateless market-data proxy** (`fetch(PERPL_WS,{Upgrade})`
bridging an inbound browser socket) — there is **no Durable Object, no storage, no alarm loop**. The design's
"re-implement the engine in a `PerplExecutorDO`" is a large greenfield lift with real CF constraints the doc glosses:
a DO does **not** run a free-running 1.5s tick (it hibernates when idle and must be alarm-driven or kept alive by an
inbound connection), and holding a **long-lived outbound authenticated trading WS** in a DO for up to 1000 minutes
is unproven here. **Fix:** flag the filename/ownership mismatch to the integrator; have infra explicitly validate
that a DO can hold the outbound Perpl WS for a full session, tick at the needed cadence via alarms, and persist
lease+WAL — and re-derive the tick cadence against the DO alarm model, not just the device timer. The engine's
*correctness* (reconcile/WAL/lease) survives; its *cadence numbers* need re-validation for C.

### I3 — Engine `actor` vs `@MainActor` client; forwarding flag can lag; token bucket must clamp on wake
The engine is an `actor` (§9) while `PerplTradeClient` is `@MainActor` — every order-op is a cross-actor hop
(latency only, fine at this cadence). But §10's tick gates on `socket.forwardingEnabled`, the raw WS flag, which
lags the on-chain grant; `PerplTrading` already compensates with `forwardingGrantedOnChain`/`isForwarding`. The
engine must gate on `PerplTrading.isForwarding` (the OR), else a freshly-enabled session's first ticks no-op.
Also the `TokenBucket` refill (`elapsed × 1.667`) must **cap at capacity on foreground-wake** — after a long
suspension a naive computation dumps a token flood right when the socket is likely stale. Both are small, easily
fixed.

────────────────────────────────────────────────────────────
## GENUINELY STRONG — keep

- **S1 — the post-only fix is a real, correctly diagnosed v1 bug.** `OrderInput.postOnly` exists and
  `MMExecutor.place` already passes `postOnly: true`, but `PerplOrders.entry` **never reads it** — it emits
  `fl: ioc ? 4 : 0`, so the MM ladder rests as **GTC**. Threading `OrderFlag` through `PerplOrderFrame.json()` is
  exactly right: guaranteed-maker cost control *and* the compliance guard against self-trading. Keep it, and keep
  the paired pre-submit self-cross refusal (bid ≥ own ask rejected before the wire).
- **S2 — the wire mapping is accurate against the live enum.** `wireType = rawValue+1`; with the actual enum
  (`cancel=4`, `increasePositionCollateral=5`, `change=6`) this yields t:5 Cancel, t:6 (collateral, the gap), t:7
  Change — matching brief §2. `lb:0` retained on amend matches the existing "last exec block too high" fix. §2 frame
  shapes are faithful to `PerplOrderFrame.json()`.
- **S3 — the fill-truth discipline is excellent** and correctly generalizes MMWatcher's existing rule (a failed
  `try?`→nil read is not "flat"). Booking requires positive evidence (mt:24 / signed-REST / corroborated on-chain
  delta); "order left the book" is only a reconcile hint; the idempotent id-keyed ledger dedups the WS-then-REST
  double-sighting; reconcile-before-act + WAL + rq re-seed give exactly-once *effect* over at-least-once transport.
  Materially better than v1's recycle-only-from-double-flat.
- **S4 — single-writer lease + cockpit/executor mode** correctly honors the 4-socket/wallet cap and the shared-`rq`
  hazard; the phone holding **no** trading socket while the worker runs is the right call and is the correct reading
  of §3's rq-collision problem.
- **S5 — making the engine a pure, protocol-injected, unit-testable type** (`PerplReads` + mock socket) is the right
  foundation for device/worker parity and is a real upgrade over the @MainActor-timer MMWatcher.

────────────────────────────────────────────────────────────
## Economics / compliance check
No economic error in the section: ~5 bp round-trip, fees only on fills, amend 0 bp on fees — consistent with brief
§0 (~$250/$1M). It correctly delegates Cost/$1M display to quant/ux and only supplies the mt:24 `fee`/maker input.
Compliance stance is right (post-only + self-cross refusal ⇒ fills only from the real book). One honest consequence
to surface in UX (the doc gestures at it but should state it): on an illiquid market, correctly refusing self-match
means **low volume**, not cheap volume — don't let a preset imply otherwise.

## Bottom line
Keep S1–S5 as-is. Block on C1 (don't ship protect-on-fill to the device — it removes the app-closed safety net),
de-risk C2 (verify amend before basing the budget on it), and tighten C3/C4 (budget margin + kill sequencing).
I1–I3 are cleanups. With C1–C4 addressed this is a buildable, largely-correct order-router.
