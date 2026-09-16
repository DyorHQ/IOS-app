# Red-team review — Risk, Margin Maintenance & Compliance section

Reviewer: skeptical senior reviewer. Verified against live code in `~/Hackathon/ios` (DyorHQ + DyorKit),
the brief, and Perpl facts. Verdict: **solid-with-fixes.** The bones are right — it respects v1's invariants,
correctly flags the two real infra gaps (post-only `fl:1`, `mt:24`), and the breaker/teardown structure is
genuinely good. But there are three must-fix correctness problems (one silently corrupts session accounting, one
gets the section's own headline honesty number wrong, one has no actual rate governor) plus several high/medium
issues. Details below, each as issue → why it breaks → concrete fix.

Legend: [C]=critical, [H]=high, [M]=medium, [L]=low.

---

## What is genuinely strong (keep it)

- **"Failed read ≠ flat/zero-loss" extended to the kill switch.** §3.1 guard 1 + §5 RPC breaker. Matches the shipped
  `MMWatcher.tick` L108-113 invariant exactly. This is the single most important safety property and it's correct.
- **Two-tick confirmation for flatten/kill, with an instant-trip exception when `unrealized` alone already breaches.**
  §3.1 / §2.3. Right balance between spoof-resistance and not sitting on a real, already-incurred loss.
- **SAFE teardown = cancel-all → flatten → verify-clean, idempotent/convergent, retried.** §3.2 mirrors the real
  `MMExecutor.stop` (L62-80) and `MMStatusView.stop` (persist active=false first). Correct.
- **Refusing to auto-offer "add margin to defend a losing MM inventory."** §2.3. Correct prop-desk discipline.
- **Pre-flight gate set** (insufficient margin, min-notional/lot, crossing-book, market-halted, forwarding/socket
  ready) maps precisely to the real failure modes and to tread.fi's panel. §6 is buildable as written.
- **Diligence on the two infra gaps is accurate.** I verified both:
  - Post-only is NOT wired on the authenticated WS path: `PerplOrders.entry` never reads `input.postOnly`, and
    `PerplOrderFrame.json` hardcodes `"fl": ioc ? 4 : 0` → an MM limit entry goes as **GTC (`fl:0`)** even though
    `MMExecutor.place` passes `postOnly: true` (MMWatcher.swift L33). (The *on-chain* path honors post-only —
    `PerplExchange` L107 — but the MM uses the WS path.) Flagged correctly.
  - `mt:24` (fills/rejects) and `mt:26/27` (position ids) are NOT parsed — `PerplTradeClient.handle` handles only
    `mt:19/21/3`. Flagged correctly.
- **Breaker table shape** (detect+confirm → action → recover; "never reduce risk on a failed read"; "two breakers ⇒
  escalate one level") is a good, real risk framework.

---

## Lens 2 + 3 — Perpl correctness & risk/economics (the real problems)

### [C] 1. De-risk cancels silently corrupt v1's fill/volume accounting (and can arm phantom recycles)
- **Issue.** `MMWatcher.manage` (MMWatcher.swift L148-155) detects fills purely by book-diff: *"a resting price no
  longer on the book ⇒ a fill,"* adds an `MMFill`, and increments `s.volume`. Its own comment states the invariant
  it relies on: *"in normal operation the only way a resting order leaves the book is a fill."* This section's de-risk
  actions **cancel resting orders**: §2.3 AMBER "stop adding to the losing side," ORANGE "cancel the furthest 50% of
  resting levels," plus the quant requote loop's cancel/replace. Every such cancel makes a resting price disappear.
- **Why it breaks.** The next `MMWatcher` tick counts each cancelled level as a **fabricated fill** → phantom entries
  in the fills feed, inflated `s.volume` (the product's headline metric — so also a mild honesty problem), and a
  false step toward `recycleArmed`, which can re-place a ladder. So the section's own de-risk actively violates the
  invariant that the section elsewhere relies on. This is not "graceful degradation to polling" — it is *actively
  wrong* accounting the moment any de-risk fires.
- **Fix.** Make `mt:24` a **hard prerequisite** for any de-risk that cancels, not a nice-to-have — fill/volume
  attribution must come from real `mt:24` fills, never from book-diff, once requote/de-risk exists. Until `mt:24`
  lands, either (a) forbid de-risk cancels, or (b) have every cancel path transactionally remove that price from
  `s.restingPrices`/`s.placedLevels` in the *same* store write so the watcher can't misread it. Unify order lifecycle
  under one execution owner so cancels and fill-detection share state.

### [C] 2. The section's own "Cost/$1M" honesty number is wrong (and misreads the brief)
- **Issue.** §8.2 / §6 state the headline metric as `cost/$1M = 2·feeRateBp·100` and text it as "~$500/$1M at 5 bp
  round trip," and claim it is "restating the brief's ~$250/$1M **per direction**."
- **Why it breaks.** The brief §0 says plainly: *"~$250 of fees per $1,000,000 of **volume**"* (2.5 bp/leg; a
  round-trip of notional N = 2N volume, cost 5 bp·N = $250 per $1M of volume). It is per **volume**, not "per
  direction." The formula `2·feeRateBp·100` with `feeRateBp=5` evaluates to **1000**, and the prose says **500** —
  neither equals the correct **$250/$1M of volume**, and both are internally inconsistent. A section whose §8 mandate
  is "honest economics, never costless profit" and whose §6 has a literal "Cost/$1M honesty" gate is shipping the
  honesty number ~2–4× wrong. (Note the shipped `MMStatusView.estFees = volume·5bp/1e4` likely double-counts too,
  since `volume` sums both legs; reconcile there as well.)
- **Fix.** `cost/$1M of volume = perLegFeeBp × 100 = 2.5 × 100 = $250` (equivalently `roundTripBp × 50`). Correct the
  formula, the "$500" text, and the "per direction" misquote. Recompute the §6 "Max-Loss sanity" gate (compares
  Max-Loss to est. round-trip fee on a ladder) with the corrected fee model.

### [C]/[H] 3. No actual rate governor — the 2 s risk loop can blow the 120 req/min budget; teardown has no reserved budget
- **Issue.** The section repeatedly says actions are "rate-budget-aware" and "use amend not cancel+replace," but there
  is **no concrete mechanism**: no per-tick op cap, no token bucket, no coalescing, and the risk UI/loop is specified
  at "~2 s tick" (§7) with de-risk actions that touch *many* levels per tick (widen ×1.5 across the ladder, cancel
  50%, skew both sides).
- **Why it breaks.** Brief §2: ~120 req/min/socket, keep-alive costs 2/min ⇒ **~2 order-ops/s total across all
  levels/markets**. A 10-level ladder re-amended every 2 s = ~300 ops/min ≫ 120 → 1008 "too many requests," which
  itself is a breaker, which triggers more actions → thrash. Worse: the kill/teardown path (cancel-all + flatten +
  verify, retried 5×) competes for the *same* budget with no reservation, so the most safety-critical action can be
  starved exactly when breakers are firing hardest. And §3.2's teardown reconnect retries at 0/2/5/10/20 s conflict
  with §5's own "1008 conn-cap ⇒ back off 30 s."
- **Fix.** Add a shared `PerplRateBudget` token bucket (~100 ops/min, leaving headroom for keep-alive + the read
  loop) that **every** order op draws from (quote, requote, de-risk, TP, cancel, kill). De-risk must degrade to
  "adjust once, then hold" instead of re-amending every tick; coalesce per-tick changes into the minimum frames.
  **Reserve** a slice of the budget for teardown and give kill frames priority; make teardown respect the conn-cap
  backoff rather than hammering.

### [H] 4. Dead-man "catastrophe SL at Start" is not implementable; worker "auto-revoke forwarding" is infeasible
- **Issue.** §3.2 "both offline" tier proposes, at Start, registering a single reduce-only stop sized to the *whole
  expected inventory* at the price where `netPnL ≈ −MaxLoss$`; and a hybrid "auto-revoke `allowOrderForwarding(false)`
  if the device stops renewing its lease."
- **Why it breaks.**
  - At Start there is **no position** (entries are resting, unfilled). Perpl TP/SL are reduce-only Closes linked to a
    position via `lp` (brief §2) and, in the shipped bracket, activated when the entry trades via `tr`
    (`PerplTrading.submitBracket` L282-289). You cannot link a whole-inventory stop to a position that doesn't exist,
    and the eventual filled size/price (hence the −MaxLoss$ trigger price) is unknown at Start (maybe 3 of 10 levels
    fill). A reduce-only order larger than the real position is clamped/rejected. So this can't be one static trigger.
  - `allowOrderForwarding(bool)` is a **wallet EIP-712 / on-chain tx** (`PerplTrading.enableForwarding` L192-194,
    signed by the wallet). The worker holds only a **trade-scoped Ed25519 key (scope_mask=2, no withdrawal)** — it
    cannot sign a wallet tx, so it **cannot** flip forwarding. And forwarding is a **global** one-click toggle, so
    turning it off also kills the user's manual one-click trading, not just this session.
- **Fix.** The real dead-man is the **per-level native SLs** (already sized to each fill, keeper-fired app-dead) —
  say so and drop the "whole-inventory catastrophe SL at Start." If a session catastrophe stop is wanted, it must be
  (re)amended as inventory accrues, which needs a live device/worker (acknowledge it isn't a both-offline net). For
  hybrid revocation, define it as **destroy/rotate the delegated key + stop the executor** (+ optional server key
  auto-expiry), and reserve `allowOrderForwarding(false)` as an explicit *user/device* action, noting it disables all
  one-click. Fix the same wording in §8.4 consent item 6 ("Revoke now" = forget key, not forwarding-off).

### [H] 5. Kill/realized-PnL from account-balance-delta is unreliable on a shared account
- **Issue.** §3.1 `realized = accountBalance − strategy.startBalance`; the secondary floor uses account equity across
  ALL markets.
- **Why it breaks.** AUSD balance is account-wide and the account is shared with app.perpl.xyz tabs (brief §1) and
  with the user's manual/other-market positions. A **deposit** mid-session raises balance and *masks* a real MM loss
  (missed kill); a **withdrawal** or an unrelated losing position *fakes* a loss (false kill / false secondary-floor
  trip). Turning the section's most dangerous action (flatten) on a signal polluted by unrelated activity is unsafe.
- **Fix.** Scope the kill to the strategy's own market: `unrealized` on the market + realized from the session's own
  attributed fills (`mt:24`), not raw balance delta. Keep balance-delta only as a coarse secondary, and detect
  balance jumps not explained by fills (deposit/withdrawal) to suppress false trips.

### [H] 6. Session-level Take-Profit uses margin-return semantics vs the native TP's price-move semantics
- **Issue.** §4.3 belt-and-suspenders: close when `unrealized ≥ takeProfitPct% · position.margin`. But the config's
  `takeProfitPct` is a **price-move** percent — `MarketMakingStrategy.bracket` sets `tp = entry·(1 ± tpPct/100)`.
- **Why it breaks.** A price move of `tpPct%` at leverage L is a return-on-margin of ≈ `tpPct%·L`. So
  "unrealized ≥ tpPct%·margin" fires at a price move of only `tpPct/L` — e.g. tpPct=1%, L=10 → the session TP fires
  at a **0.1%** move while the native TP is at **1%**. The "belt-and-suspenders" becomes the *primary* exit, caps
  winners at ~1/L of the intended profit, and over-trades (more closes → more fees → worse cost/$1M). Directly harms
  the "net-profitable, low cost/$1M" goal.
- **Fix.** Give the session-level TP the *same* price-move semantics as the native TP: close only when
  `mark` has crossed `entry·(1 ± tpPct/100)` **and** the native TP is confirmed not resting.

### [M] 7. De-risk cancels can strip live positions' protective triggers → naked exposure
- **Issue.** §2.3 ORANGE "cancel the furthest 50% of resting levels (frees margin)" and AMBER "stop adding" don't
  distinguish resting *entry* orders from resting *reduce-only TP/SL triggers* of already-filled positions.
- **Why it breaks.** Cancelling a filled position's TP/SL to "free margin" leaves it naked — and §5's socket-loss
  breaker explicitly relies on native TP/SL still covering the position ("DO NOT flatten on socket loss; TP/SL cover
  it"). Remove them and that assumption is false.
- **Fix.** De-risk cancels must target only *unfilled entry* orders (and their not-yet-activated triggers); never
  cancel a reduce-only trigger tied to a live position. `MMExecutor` already knows entries vs `reduceOnly` on
  `PerpOrder` — filter on it.

### [M] 8. Health (mark-based) vs liquidation (entry-based) use different maintenance bases; high leverage compresses the whole ladder inside the liquidation distance
- **Issue.** §2.2 health `Mm = notional·f_m = size·mark·f_m` (mark-based). The verified liquidation formula
  (`PerplExchange.liquidationPrice` L246-251, stored on `PerpPosition.liquidation`) uses `mmr = entry·size·f_m`
  (**entry-based**). H and DTL therefore measure different things and cross their thresholds inconsistently.
- **Why it breaks.** The bands are leverage-agnostic constants (H 2.0/1.5/1.25), but the *price distance* they map to
  shrinks with leverage. Worked from the section's own MON example (f_m 0.05, 10×): RED (H<1.25) fires at mark ≈1.919
  while liquidation ≈1.90 — ~1% headroom. ORANGE only starts ~2% out. So GREEN→RED spans a ~5% move at 10×, and at
  15–20× (tread.fi shows 15×) a single candle jumps the whole ladder into liquidation before a 2-read RED
  confirmation + reduce-only market close (which itself pays 1.5% slippage, `slippageBps:150`) can complete.
- **Fix.** Derive the primary gauge from **DTL against the stored on-chain `liquidation`** (the exchange's real
  trigger) and make de-risk bands a function of leverage (guarantee ≥ N ticks of reaction given tick cadence + vol).
  Cap automated-MM leverage below the manual cap, and/or place the native SL *inside* the RED band so the keeper, not
  the app loop, is the primary liquidation-avoider at high leverage. Also reconcile H's `Mm` to the entry-based `mmr`
  so H and DTL agree.

### [M] 9. Triggered TP/SL are taker legs that can self-match the own resting ladder on a thin book — post-only doesn't cover them
- **Issue.** §8.1 leans on post-only (`fl:1`) as the anti-wash control, plus self-cross avoidance on the resting
  book. But TP/SL are reduce-only **IOC market** closes (`PerplOrders.takeProfit/stopLoss` → `ioc:true`, i.e.
  taker). In Grid mode all entries are one side (e.g. all bids); a triggered TP is a market **sell** that crosses
  down into resting **bids** — including the user's *own* resting entry ladder on the same account.
- **Why it breaks.** That is self-trading, and post-only cannot prevent it because the TP leg is a taker. On a thin
  book where the user is the dominant liquidity, this is a concrete wash pathway — exactly what §8 is meant to
  structurally prevent — and it is not covered by the stated controls.
- **Fix.** Confirm and set an **STP flag** on `mt:22` (the section already opens this as a §9 question — elevate it
  to a compliance dependency). Absent STP, gate/limit triggered closes when the own resting ladder sits within the
  close's marketable range, and document the residual risk in the honest-economics disclosure.

### [M] 10. Funding-blowout breaker has a units ambiguity (%/interval vs %/hr; interval unknown)
- **Issue.** §5 reads `PerpMarket.fundingRatePct100k` and says "÷100k = %/interval," then compares to
  `fundingBlowoutPctPerHr` (%/hr). Verified: the field is on-chain `fundingRatePct100k` (`PerplExchange` L156), and
  the **funding interval length is not established** anywhere in the code or brief.
- **Why it breaks.** If Perpl funding is 8-hourly (common) or continuous, comparing a per-interval rate to a
  per-hour threshold is off by up to ~8×, so the breaker fires too early or never.
- **Fix.** Add "funding interval seconds" to the §9 per-market-params request; normalize `fundingRatePct100k` to a
  per-hour rate before the threshold compare.

### [L] 11. Amend (`t:7`) is entirely unbuilt, yet load-bearing for the rate argument
- **Issue.** The rate story ("amend not cancel+replace") depends on `t:7`. Verified: only the enum case
  `PerpOrderType.change = 6` (wire 7) exists — there is **no** `PerplOrders.change` builder and no
  `PerplTrading.amend` wrapper, and `mt:24` isn't parsed to confirm an amend's outcome.
- **Why it matters.** The whole "rate-aware de-risk" premise rests on an unimplemented, unvalidated primitive (does
  `t:7` change price+size atomically? preserve queue priority? reset `lb`?).
- **Fix.** Flag amend as an explicit infra dependency (build + validate against Perpl) alongside `fl:1`/`mt:24`; until
  validated, the rate governor (#3) must assume cancel+replace costs.

### [L] 12. Multiple loops write `MMStore` (UserDefaults) non-transactionally
- **Issue.** `MMWatcher` (20 s), the new `MMRiskMonitor` (~2 s), `MMStatusView.stop`, and quant's requote loop all
  read-modify-write the same `MMStrategy` in `MMStore`. Only `MMWatcher` does the careful "merge runtime fields onto
  a fresh read" (MMWatcher.swift L124-134).
- **Why it breaks.** A new writer (e.g. appending `breakerLog`) that doesn't replicate that merge will clobber
  concurrent fill/volume updates (last-write-wins).
- **Fix.** Single owner of `MMStore` writes (or an actor/serial queue with the same merge discipline) shared by all
  loops.

### [L] 13. Minor numeric slips
- §2.2 worked example writes liq as `2.00 + (100 − 100 − 0)/500` — the `mmr` slot should be `entry·size·f_m = 50`,
  not `100`; correct value ≈1.90 (they disclaim "uses exact stored value," but fix the inline number).
- §6 `requiredMargin = deployed / L_cap` uses the *max* cap; for a user who picked leverage < L_cap this understates
  required margin. Use the chosen leverage (≈ `capital`), or Σ per-level margin.

---

## Newly surfaced external/API needs (add to §9)
1. **Perpl funding interval length** (seconds) — to fix breaker #10.
2. **Can a trade-scoped (scope_mask=2) key toggle `allowOrderForwarding`, and does Perpl support key auto-expiry?**
   — determines whether any worker-side auto-revoke in #4 is even possible.
3. **Confirmation of a fresh read path for margin/PnL** — brief §2 warns "public RPC serves ~24h-old state for some
   calls"; the real-time kill (#5) must not run on stale reads. Prefer mark-from-`PerplFeed` × known size for
   unrealized, or confirm the account/positions multicall path is fresh.
4. **STP flag on `mt:22`** — elevate from open question to a compliance dependency (#9).

## Bottom line
Keep the architecture, the invariants, the teardown, the pre-flight gates, and the breaker framework. Before it's
safe to ship: (1) make `mt:24` a hard prerequisite so de-risk cancels stop corrupting fill/volume accounting; (2)
fix the Cost/$1M honesty number and formula; (3) add a real shared rate governor with reserved teardown budget; then
the high-severity kill-signal, dead-man, and TP-semantics fixes. All are additive, not an architecture rewrite —
hence solid-with-fixes.
