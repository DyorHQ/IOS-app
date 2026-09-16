# Red-team review — Market-Microstructure Quant (strategy engine)

Reviewer stance: skeptical senior, verified against live code in `~/Hackathon/ios`.
Verdict: **solid-with-fixes.** The math is largely right, it catches two real live bugs, and the
skeleton is buildable. But several claims that are true only for a *server* executor are presented as
on-device truths, one headline input (`V24`) is in the wrong units per the actual code, the amend
economics are optimistic because every model uses brackets, and the biggest infra dependency (a live
WS resting-order map) is **unverified — no such feed exists in the code or the brief's frame list**.

Legend: 🔴 critical (breaks / silently loses money / breaches a guardrail) · 🟠 high · 🟡 medium · 🟢 keep.

---

## Lens 2 first (Perpl correctness) — because two findings are code-proven

### 🟢 STRONG, CONFIRMED catches (keep — these are the best parts)

- **Post-only is genuinely not wired (§4.1 #1) — CONFIRMED.** `PerplOrders.entry` sets `ioc: market`
  only, and `PerplOrderFrame.json` emits `"fl": ioc ? 4 : 0` (PerplTradeClient.swift:48, 84). It never
  reads `OrderInput.postOnly` (PerplModels.swift:201), even though `MMExecutor.place` passes
  `postOnly: true` (MMWatcher.swift:33). **Today the entire v1 MM ladder rests as `fl:0` GTC and can
  cross → taker fees, inverting the economics.** This is a live bug the section correctly identifies.
- **`t:7` amend builder is missing (§4.1 #2) — CONFIRMED.** `PerpOrderType.change = 6`
  (PerplModels.swift:30) → `wireType = 7` (PerplTradeClient.swift:42). No builder exists. Correct.
  (Note: `t:6` is `increasePositionCollateral`, rawValue 5 — the brief's list omitted it; the amend
  builder must use `.change`, which the design does.)
- **mt:24 fills / mt:26-27 position ids are dropped (§8) — CONFIRMED.** `handle()` switches only 19/21/3
  then `default: break` (PerplTradeClient.swift:353-367); grep finds no 24/26/27 anywhere. The live
  fill/inventory feed the fast loop needs does not exist yet. Correct.
- Break-even derivation is right: `s* = [(1−ρ)a + F]/ρ` with F=5bp, ρ=0.6, a=8bp → 13.67bp full →
  **6.83bp half ≈ `gridFloorBp = 6.8`**. The claim that the existing floor is exactly break-even is
  correct and a nice sanity anchor. Keep.
- Reuse of the existing kernel/floors and the `mode → refModel` back-compat decode (§7) is pragmatic
  and correct.

### 🔴 1. `V24` is base units, not USD — auto-duration is off by ~`mark` (a factor of thousands)

- **Issue.** §3's `D = 1440·V_target/(p·V24)` needs `V24` in **USD**, and the section only *flags this as
  an open question* ([NEEDS-USER] #2). The code settles it: `volume24h = dv / sizeScale` in **both**
  `PerplFeed.swift:241` and `PerplService.swift:157` — i.e. `dv` is divided by the *lot* scale, so
  `PerplLiveState.volume24h` is **base units** (e.g. BTC count), not dollars.
- **Why it breaks.** Feeding `volume24h` straight into the formula (as the worked examples implicitly do,
  using "$21.6M") over-states `V24` by ~`mark`. For BTC (mark ~$60k) the computed duration is wrong by
  ~4–5 orders of magnitude → every session either clamps to 10 min or 1000 min and the whole
  volume↔duration↔participation model is meaningless.
- **Fix.** Treat it as a confirmed bug, not an open question: `V24_USD = volume24h · mark`. State it in
  §3 and the pre-trade panel, and still [NEEDS-USER]-confirm `dv`'s exact semantics with Perpl, but the
  code is unambiguous that as-consumed it is size-scaled.

### 🟠 2. Quoting off `mid` while the executor's cross-guard + engine use `mark`, with no post-only-reject path

- **Issue.** §1 switches the reference to `r = mid`, but `MMExecutor.place`'s "don't cross" guard is
  `entry >= mark` / `entry <= mark` (MWatcher.swift:29-31) and Perpl matches on its own book/mark. The
  section defines *when* to recenter but never defines behavior when a post-only order is **rejected**
  (mid moved, so the maker price is now marketable → Perpl rejects the post-only, or — with bug #1
  live — it crosses and takes).
- **Why it breaks.** With post-only unwired (confirmed) a mid-based bid above mark **takes**. Once
  post-only is wired, the same order is **rejected and silently never rests** → the ladder goes
  one-sided → fill asymmetry, missed `V_target`, and unbounded inventory on the side that did rest.
- **Fix.** Make post-only-reject a first-class loop state: on reject, reprice to `min(target, bestAsk −
  1 tick)` for asks / `max(target, bestBid + 1 tick)` for bids and retry (counts against the op budget).
  Reconcile the cross-guard to use the same reference the quotes use. Keep `mark` only for SL/liq.

### 🔴 3. Amend of a *bracketed, unfilled* entry orphans / stale-prices its TP/SL — and every model uses brackets

- **Issue.** §4.2 lets a level be amended (`t:7`, 1 op) "when only price/size changed." But the current
  bracket links the TP/SL to the *unfilled* entry via `tr = entry.requestId` with an **absolute**
  trigger price computed from the *pre-amend* entry (PerplTrading.swift:281-290, `bracket()` in
  MarketMakingStrategy.swift:78). Amending the entry's price does not move the linked trigger, and it is
  unspecified whether the `tr` linkage even survives a new `rq`.
- **Why it breaks.** After a price amend, the pending TP/SL sits at the *old* distance (or is orphaned).
  On fill the position gets a mispriced/absent bracket. Worse for the **rate budget**: §4.3's cheap
  "amend-only = Ln ops" rows assume amend is available, but **Mid (bracket), Grid (per-rung TP), RGrid
  (trailing TP), Blend, DGrid all carry triggers** → the safe cheap-amend path barely exists, so most
  requotes are cancel+replace (2–4× ops). The tight-cadence (Δt ≤ 5–10 s) feasibility conclusion is
  therefore optimistic.
- **Fix.** Change the placement contract for the fast-requoting volume ladder: **bare post-only entries,
  no pre-linked bracket; arm the keeper TP/SL on fill** (mt:24 → Close with `lp` = position id). Then a
  resting entry is genuinely amend-cheap. Recompute the §4.3 table with "amend = size/price only,
  bracket-less levels" vs "bracketed rungs = cancel+replace, Δt ≥ 15 s." (This interacts with §4 below —
  read them together.)

### 🟠 4. `placeAll` stops on first rejection → one reject truncates the ladder

- **Issue.** `placeAll` breaks the loop on the first non-accepted ack (PerplTradeClient.swift:275-280).
  The requote loop places independent levels; one post-only reject (finding #2) or one rate hiccup
  aborts every later level.
- **Why it breaks.** Ladder ends up partial/one-sided → asymmetric inventory, missed volume.
- **Fix.** For independent ladder levels, submit per-frame and collect all acks (don't reuse the
  stop-on-first-reject bracket helper); only keep stop-on-first-reject for a true entry→trigger bracket.

### 🟡 5. `rq` collision with the user's app.perpl.xyz browser tabs

- **Issue.** `rq` is strictly-increasing **per account**, seeded from `lfr` (PerplTradeClient.swift:284,
  378). Perpl allows 4 sockets/wallet *shared with browser tabs* (brief §2). A high-frequency requote
  loop makes concurrent-increment collisions with an open Perpl tab far more likely.
- **Fix.** Re-seed `rq` from the latest mt:21 `lfr` each AccountUpdate; on an `rq`-reject bump and retry;
  warn the user to close app.perpl.xyz tabs for the session's duration.

### 🟡 6. Trailing-TP re-issue (RGrid §2.3) has an unprotected gap + budget cost

- **Issue.** "Re-issue the reduce-only Close at the new level" each `θ_tp` ratchet = cancel-old +
  place-new = 2 ops per position per step, with a window where the position has *no* TP between the two.
  Small `θ_tp` in a fast trend thrashes both budget and protection.
- **Fix.** Amend the trigger via `t:7` if Perpl supports amending trigger orders (open question — the
  brief doesn't confirm `t:7` field scope); else floor `θ_tp` and disclose the gap.

### 🟢 Correct on the rest of §2 Perpl usage
`fl:1` PostOnly, `lb:0` on every frame, TP/SL as reduce-only Close with `tpc`/`lp`, `mt:22` orders,
Ed25519 `mt:29` sign-in, trade-scope-cannot-withdraw, forwarding prerequisite, one-socket/4-cap,
120 req/min minus the 30 s `mt:1` keepalive — all consistent with the code and brief. Good.

---

## Lens 1 — iOS feasibility

### 🔴 7. "Real-time Max-Loss kill" + "endsAt flatten" + on-fill bracket arming are NOT enforceable on-device

- **Issue.** §7/§9 promise a real-time Max-Loss kill and a session-end flatten; finding #3's fix arms
  brackets *on fill*. All three require the app to be **foreground and alive**. iOS suspends the app
  seconds after backgrounding (brief §4), and `MMWatcher` runs "only while app active" (confirmed,
  MMWatcher.swift:91-99). The trading socket dies on suspend.
- **Why it breaks.** Backgrounded: (a) a fill can land with no app to arm its bracket → an *unprotected*
  position exactly when the brief's keeper safety net was supposed to cover a dead app; (b) the box can
  end with positions still open past `endsAt`; (c) Max-Loss can be breached with nothing watching. The
  brief's whole safety story ("native keeper TP/SL fire even when the app is dead") is **undermined** if
  protection is armed on-fill by a possibly-dead app.
- **Fix.** Be explicit that real-time kill + endsAt flatten are **arch-C/A (worker) features, not
  device-only**. For device-only sessions, preserve app-independent protection: either keep a
  pre-linked bracket on each resting entry (accepting the cancel+replace cost from #3) **or** maintain a
  single *position-level* keeper stop sized to Max-Loss (SL at the mark where cumulative loss =
  `stopLossPct·capital`) re-armed after each fill, so a server-side stop exists whenever the app sleeps.
  This is the honest reconciliation of #3 and the iOS reality.

### 🔴 8. Two loops mutating the resting set → double-place via stale on-chain reads

- **Issue.** The plan retains v1's 20 s slow tick (on-chain `account/positions/openOrders`, which are
  plain `ethCall`s — PerplService.swift:57-93 — and "public RPC serves ~24h-old state," brief §2) with
  its **flat-recycle-then-place** (MMWatcher.swift:160-176), *and* adds a fast WS-driven requote loop.
- **Why it breaks.** A stale on-chain read returns an empty/old order set → the slow tick sees "flat,"
  arms, and on the next flat tick **re-places a full ladder on top of the orders the fast loop already
  has resting** → double the ladder, double exposure. The v1 "failed read ≠ flat" guard doesn't help: a
  *successful but stale* read legitimately returns `[]`.
- **Fix.** Make the **WS order/position map the single source of truth** while the fast loop owns the
  market; demote the slow tick to read-only reconciliation that **never places** and only flags drift;
  disable flat-recycle entirely under continuous requoting (it's a v1 artifact for the recycle-from-flat
  model, incompatible with continuous quoting).

### 🟠 9. The load-bearing WS resting-order map is unverified — it may not exist

- **Issue.** §8 depends on "a live resting-order map (order ids) from the trading WS" for amend/cancel.
  But the brief's authenticated-WS frame list is mt:3/24/26/27/19/21 — **none is a per-account
  open-orders frame** — and in code, `orderId` only ever comes from the on-chain `PerpOrder`
  (PerplModels.swift:134) or is supplied by the caller to `cancel` (PerplTradeClient.swift:109). There
  is zero evidence Perpl pushes assigned order ids on the trading socket.
- **Why it breaks.** If order ids aren't pushed, amend-by-`oid` is impossible without the stale on-chain
  read, and the entire tight-requote-via-amend architecture (and its rate budget) collapses to
  cancel-all/replace-all.
- **Fix.** Elevate this from an [infra] task to a **[NEEDS-USER] API confirmation**: which frame carries
  the assigned `oid` after an accepted `mt:22`? If it's on mt:24/ack, build the map by correlating
  `sn`/`rq` at placement → `oid`. If nothing carries it, redesign around cancel+replace keyed by `rq`
  (no amend) and rebuild §4.3 accordingly.

### 🟡 10. Fast-tick re-entrancy + main-actor serialization
`send` awaits each ack with an 8 s timeout and `place`/`placeAll` await frames **sequentially**
(PerplTradeClient.swift:296-305, 260-281). A 6-level cancel+replace = 12 serial round-trips; a slow ack
can make one "tick" outlast `Δt` and pile up. Add an `isRequoting` guard (drop-if-busy) and cap
in-flight frames. The pure quote math on `@MainActor` per feed push is fine *if throttled before* the
work, as specified.

---

## Lens 3 — risk & economics

### 🔴 11. No runtime rate governor → self-inflicted 1008 + orphaned/dropped orders

- **Issue.** §4.3 *computes* the 118/min budget but nothing *enforces* it at runtime. A volatile market
  + tight cadence + multi-level ladder + a volume-chasing controller (see #12) will exceed 118 ops/min.
- **Why it breaks.** Breach → `1008 "too many requests"` closes the socket (PerplClose.isRateLimit,
  PerplTradeClient.swift:148) → reconnect spends 1 of the 4 wallet slots and interrupts the session; any
  in-flight requote can leave the book half-updated (orphaned/one-sided orders).
- **Fix.** A shared **token-bucket** (refill 118/min, 1 token/frame). When empty: skip amends this tick,
  always reserve tokens for safety cancels/flatten, and back-pressure the volume controller. Surface
  "ops/min vs 118" live (the section already lists this field in §9 — wire it to a real limiter).

### 🟠 12. Volume schedule is open-loop → systematically misses `V_target`

- **Issue.** §3 computes `childClip` once from an *estimated* `fillRate`; there is no controller closing
  the loop on actual cumulative volume vs plan. Maker fills are stochastic; tread.fi/Arbital do
  participation *targeting* (a feedback loop), which the section reduces to a one-shot clip.
- **Why it breaks.** In practice you drift behind plan (fills lag the estimate) and finish under target,
  or over-correct and over-trade. Either way "hit your volume target in the time box" — the feature's
  headline promise — isn't actually controlled.
- **Fix.** Add a proportional controller on `volume(t)` vs `plan(t)`: behind → step spread toward touch
  / grow clip within `perSide` and the rate governor; ahead → widen. This is also the knob that must
  obey #11 so chasing volume can't blow the budget.

### 🔴 13. Self-match / wash-trading exposure is not closed

- **Issue.** The section correctly states self-matching is out of scope (§5), but never adds a guard.
  With inventory skew (§4.4) and reservation-price skew (§6) shifting `r`, plus optional size-skew, a
  requote can place a bid at/above a still-resting *own* ask (or vice-versa) during a cancel/replace
  interleave. Perpl STP behavior is unstated.
- **Why it breaks.** If Perpl lacks self-trade prevention and post-only is off (current bug #1), your own
  orders fill each other = exactly the manipulation the brief prohibits (§0), and even with post-only it
  churns your own fees. This is the compliance slip.
- **Fix.** (a) Post-only mandatory — it doubles as a self-trade guard (a crossing maker is rejected, not
  matched). (b) Per-tick invariant: after merge/skew, assert `max(own bids) < min(own asks)` across the
  whole ladder; refuse to place otherwise. (c) [NEEDS-USER] confirm Perpl STP semantics.

### 🟡 14. Cost/$1M table — row 1 arithmetic is wrong
"Ranging, Passive Grid": `5e5·(0.0005 + 0.2·0.0004 − 0.8·0.0016) = 5e5·(−0.0007) = −$350`, not the
printed **−$240**. Direction (profit) is right; the headline number in the *honest-economics* table is
off by ~45%. Rows 2 (+$10) and 3 (+$685) check out. Fix the number.

### 🟡 15. `D` clamped at 1000 but still infeasible → silent participation overshoot
When `V_target` is large vs `p·V24`, `D` clamps to 1000 while the required participation quietly rises
above the selected preset — forcing you to trade a larger share than maker resting can achieve → market
impact / crossing. The §3 "can't hit target" warning covers clip>budget but not this clamp case.
**Fix.** Compute and display *effective* `p` after clamping; warn when it exceeds the chosen preset.

### 🟢 Economics that are right (keep)
- Fee floor `$250/$1M` derivation (F·V/2, per-$1M notional = $500k) — correct, matches brief.
- The "tight quoting to guarantee volume usually pays; trending always loses; net-positive only in a
  range and only reliably with rebates/points" conclusion — correct and honestly framed. Keep it front
  and center.
- AS-lite adopt (reservation skew + vol spread) / κ-GLFT defer given ~2 ops/s — correct cost/benefit.
- Duration/participation identity and the 10/20/100-min reproduction — math is internally consistent.

---

## Consolidated external needs the section under-flags (add to [NEEDS-USER])

1. **Which authenticated-WS frame carries the assigned `oid`** after an accepted `mt:22` (finding #9) —
   hard blocker for amend; the whole tight-requote architecture hinges on it.
2. **Perpl self-trade-prevention (STP) behavior** (finding #13) — compliance + correctness.
3. **`dv` scaling is confirmed base in code** (finding #1) — still worth a one-line Perpl confirmation,
   but implement `·mark` now; don't ship the USD-assuming formula.
4. `t:7` Change field scope — does it amend price *and* size, preserve `fl`, and keep `tr` linkage?
   (findings #3, #6). Already partly the section's own open question; make it explicit.
The section's existing [NEEDS-USER] on maker-rebate/points programs is correct and remains the single
biggest swing factor on whether any mode is net-positive — keep it #1.

## Bottom line
Keep the model taxonomy, the kernel reuse, the honest break-even/cost framing, and the three confirmed
infra catches — they're strong. Before "buildable," the section must: fix the `V24` units, resolve the
amend-vs-bracket-vs-iOS-protection knot honestly (bare post-only + on-fill/position-level keeper stop,
and admit real-time kill/flatten need the worker), verify or replace the WS order-map assumption, add a
real rate governor + closed-loop volume controller, and close the self-match guard.
