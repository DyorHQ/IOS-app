# Red-team review — Indicators & Financial-Recommendation Layer + Analytics

Reviewer: skeptical senior. Verified against live code in `~/Hackathon/ios`:
`DyorHQ/Strategy/{MarketMakingStrategy,MMWatcher,MMStatusView}.swift`,
`DyorKit/.../Perpl/{PerplService,PerplFeed,PerplHistory,PerplModels,PerplTradeClient}.swift`.

Verdict: **solid-with-fixes.** The section is unusually well-grounded — types, fields, and Perpl frames
mostly check out against the code, the socket/rate discipline is correct, and the compliance framing is right.
But there are **two material correctness bugs on the headline Cost/$1M metric** that make the projection and the
post-session number optimistically biased — which is exactly the "never promise costless profit" line the brief
draws — plus three feasibility overreaches. All are fixable without redesign.

---

## LENS 3 — Risk & economics (the serious ones)

### C1 (critical). Pre-trade EV omits the losing branch — projected Cost/$1M is structurally optimistic
**Issue.** §2.6's net-P&L is
`netEconomicPnL = expectedSpreadCaptureUsd + rebates − grossFees − expectedAdverseDragUsd`, where
`expectedSpreadCaptureUsd = edge · estRoundTrips · pClose` and `pClose = P(TP completes before SL/reset)`.
The `(1 − pClose)` fraction of round-trips that hit **SL or grid-reset** contribute zero capture **and their
losses are never debited.** `expectedAdverseDragUsd` is not that loss — in the worked example it is 0.25 bp
(`0.5·0.1·5`) ≈ $0.075, three orders of magnitude smaller than a real stop-out.

**Why it breaks.** Take the design's own ranging example: pClose 0.8, estRoundTrips 30 → **6 losing RTs**. A losing
RT realizes at least the grid-reset distance (`gridResetPct` 0.5%) and up to the stop (`stopLossPct` 1.5%) on
avgLegNotional $50:
- reset-loss floor: `0.005·$50·6 = $1.50`
- stop-loss ceiling: `0.015·$50·6 = $4.50`

Capture in that example is $1.80. So true `netPnL ≈ 1.80 − 0.75(fees) − [1.50…4.50] = −$0.45 to −$3.45`, i.e.
**Cost/$1M ≈ +$150 to +$1,150**, not the advertised **−$325/$1M ("you get paid")**. The sign flips. The "Grid in
ranging = negative cost" headline — the emotional core of the whole panel — is an artifact of not subtracting
losses. This is precisely the honest-economics violation the brief forbids: a screen that structurally cannot show
the stop-out cost will read as "free money."

**Fix.** Model each round-trip as a full expectation, not capture-only:
```
lossBpPerRT = clamp( gridResetPct*100 , … , stopLossPct*100 )   // realized loss distance on a loser, in bp
expectedLossUsd = (lossBpPerRT/10_000 · avgLegNotional) · estRoundTrips · (1 − pClose)
netEconomicPnL  = expectedSpreadCaptureUsd + rebates − grossFees − expectedAdverseDragUsd − expectedLossUsd
```
Keep advDrag as the *within-horizon* markout term, but the discrete SL/reset loss must be its own line and must
appear in the panel's breakdown (capture vs fees vs **expected stop-out loss**). This also makes the "Grid in
trending = you pay" case honest instead of accidentally right.

### C2 (critical). TCA Cost/$1M likely double-*omits* fees — headline understated by ~$250/$1M
**Issue.** §0.1 defines the headline as **net of fees**: `CostPer1M = −realizedNetPnL/V·1e6`, and states it
"equals +250 when there is zero spread capture and zero rebate" — which is only true if `realizedNetPnL` already
subtracts the 2.5 bp/leg fee. But §4.3 computes `costPer1M = −realizedPnLUsd/volumeUsd·1e6` with
`realizedPnLUsd = Σ position-history (dpnl + fnd)`. In the code, `PerplPositionRecord.realizedPnl = dpnl + fnd`
(`PerplHistory.swift:111`) — a price-difference + funding P&L. Venue position P&L is almost always **gross of
trading fees** (fees are separate line items, charged per fill: `PerplFill.fee`, `PerplHistory.swift:24/66`).

**Why it breaks.** If `dpnl` is gross of fees, §4.3's `costPer1M` omits the entire fee floor, so a session that
truly cost the +$250/$1M floor will display **≈ $0/$1M**, and a break-even-gross session will display
**−$250/$1M ("paid to trade")** when it actually just paid its fees. §4.3's own attribution identity contradicts
its cost line: `realizedPnL ≈ spreadCapture + inventoryPnL + funding − grossFees` treats realizedPnL as *net* of
fees, while the cost line treats it as raw. One of the two is wrong for the same variable.

**Fix.** Make the two sections agree and subtract fees explicitly:
```
realizedNetPnLUsd = realizedPnLUsd − grossFeesUsd + rebatesUsd    // grossFees from Σ PerplFill.fee
costPer1M         = −realizedNetPnLUsd / volumeUsd · 1e6
```
AND resolve the open question in §6: **confirm whether Perpl `dpnl` is gross or net of trading fees.** If it is
already net, then don't subtract again — but then §0.1's "+250 floor" identity is wrong. Either way this is a
$250/$1M swing on THE metric and must be nailed before ship.

### R3 (moderate, keep-and-strengthen). Analytics can — and should — surface self-trade / wash risk
The compliance framing is good (see below), but the section is where wash-trading would first show up as data.
A tight two-sided **Mid** ladder rests bid and ask on the *same account*; if Perpl lacks self-trade prevention,
your ask can match your own resting bid. That is both the compliance line the brief bans *and* pure fee churn.
**Fix:** have TCA flag it — e.g. a `selfMatchSuspectRatio` from fills where a maker buy and maker sell at the same
price/timestamp pair off — and add "confirm Perpl self-trade-prevention behavior" to §6. Cheap, and it turns the
analytics layer into the honesty backstop instead of a blind spot. `→DEP(arch)` for placement avoidance.

### Economics that are CORRECT (checked the arithmetic)
- Gross-fee floor `feePerLegBp·100 = $250/$1M` derivation ✓. Duration `T = 1440·V/(p·V24h)` and the 10/20/100-min
  preset self-consistency ✓. estFills/estRoundTrips internal consistency (60/30 for the example) ✓. δ* half-spread
  (`max(2.5, 1.2·2.9)=3.5bp`) ✓. capacity `cyclesPerMin = σ²/δ² = 0.25` ✓. `requiredMargin = D/L = C`, and the full
  two-sided ladder locks exactly `C`, so `marginOK = A ≥ C` is consistent ✓.
- `volume24hUsd = volume24h · mark` is the **right** unit conversion: both `PerplFeed.state.volume24h` and
  `MarketContext.volume24h` are `dv / sizeScale` (base-asset units), confirmed at `PerplFeed.swift:241` and
  `PerplService.swift:157`. No unit bug here.
- One caveat to state (not a bug): participation-vs-24h assumes uniform intraday flow; in thin windows your ladder
  is a much larger share of real flow (impact/adverse selection spikes). Worth a one-line disclosure on the panel.

---

## LENS 2 — Perpl correctness

Everything this section actually touches on the Perpl API checks out; the frame-level claims it *asserts* have two
that aren't backed by the code.

- **Fills / history feed** ✓. `PerplService.fills` → `/v1/trading/fills` and `positionHistory` →
  `/v1/trading/position-history` exist (`PerplService.swift:194/201`). `PerplFill` carries `fee`, `isMaker`,
  `isClose`, `notional` — so counting **every leg incl. keeper closes** (the §0.1 fix) and `makerFillRatio` are
  genuinely supported. `liquidationPrice(side:entry:size:margin:premium:maintenanceFraction:)` signature matches
  §2.7 exactly (`PerplService.swift:277`); `PerpMarket.maintMarginFraction`/`initMarginFraction` exist. Good.
- **Socket / rate budget** ✓ (a real strength). Indicators use only the unauthenticated market-data WS and share
  the one `PerplFeed`; they consume **zero** of the 4-socket cap and **zero** of the 120 req/min trading budget,
  leaving the full ~2 ops/s for the executor. This obeys §2 correctly and is the right call.
- **P2 (moderate). "Roll with WS `candles@<id>*60` (mt 11/12)" is not backed by `PerplFeed`.** `PerplFeed`
  subscribes to `heartbeat`, `market-state`, `order-book`, `trades` only (`PerplFeed.swift:130-138`) and its
  `handle()` switch has cases 15/16/17/18/9/100 — **no candle case, and the mt 11/12 numbers are unverified.**
  So "reuse the existing PerplFeed" is only true for book/trades/state; candles need new work. **Fix:** either add
  a candle subscription+parser to `PerplFeed` *after verifying the real mt code against Perpl docs* (do not ship
  the guessed 11/12), or — simpler and I'd recommend it — just re-fetch REST candles every 60s (1 unauth call/min,
  already implemented in `PerplService.candles`, no socket, no auth). The indicator recompute is 1/min anyway.
- **P4 (moderate). The live volume-counter hand-off (§0.1) is under-specified and partly unwired.** §0.1 tells the
  executor to "read the fills feed, not the resting-order diff." For **post-session** that's REST fills ✓. For
  **live** counting the brief says the real outcome is **mt:24** — but `PerplTradeClient.handle()` only parses
  mt:19/21/3 (`PerplTradeClient.swift:353-367`); **mt:24/26/27 are not handled today** (that's *why* `MMWatcher`
  diffs resting orders). So the hand-off silently requires either (a) adding mt:24 parsing to the trade client, or
  (b) polling REST `/v1/trading/fills` during the session. If (b), specify cadence + dedupe: poll once per requote
  tick, page only new rows by cursor, dedupe by `PerplFill.id`. Note REST fills is HTTP (not the trading WS) so it
  doesn't eat the 120/min WS budget, but unbounded polling can still hit a gateway limit. State the mechanism.
- **`t:7` amend** exists at the frame layer (`PerpOrderType.change = 6`, `wireType = raw+1 = 7`), consistent with
  brief §2, though the section only references it as `→DEP(arch)`; no issue. `lb:0`, post-only, TP/SL
  `tp/tpc/lp` frames all present and correct in `PerplOrders`/`PerplOrderFrame` — not owned here, just confirming
  the substrate the section leans on is real.

---

## LENS 1 — iOS feasibility

This section is decision-support (pre-trade + post-trade), so it does **not** need background execution — a
genuine advantage, and it correctly scopes markouts as "best-effort foreground only, complete only under the
server-executor arch." That is the honest and right answer. Two feasibility snags:

- **I1 (moderate). "The identical pure `Indicators.swift` math runs client-side and inside the Cloudflare
  `worker/`" is not literally possible.** The Cloudflare Worker runs JS/WASM, not Swift; you cannot drop a `.swift`
  file into it (§1.1, §1.2, §5-infra all assert this). Options: (a) port the pure functions to TypeScript and pin
  them to a shared golden test-vector file so client/worker can't drift (the drift risk is exactly what "pure"
  was meant to prevent, so the vectors are mandatory), or (b) compile the Swift to WASM (heavier, but preserves
  one source). Pick and state one; today the doc implies a free lunch that doesn't exist.
- **I2 (minor). Book-driven recompute throttling is asserted but load-bearing.** `PerplFeed.book` updates on every
  mt:16 delta (many/sec on BTC); an `@Observable` `IndicatorEngine` recomputing microprice/OBI on each would burn
  main-actor cycles. §1.7 says "throttle to ≤2/s" — good, but make it a hard coalescing timer, not a hope. Cheap
  to get right; just call it out as a requirement, not a footnote.
- Candle warmup sizing ✓ (4h × 1-min = 240 < the 1024 cap the code documents at `PerplService.swift:166`).
  `@MainActor` engine doing O(≤240) math 1/min is trivially fine.

---

## What is genuinely strong (keep as-is)

1. **The §0.1 catch is excellent and correct.** Verified: `MMWatcher` increments `volume` only on entry fills
   (`MMWatcher.swift:150-155`), keeper TP/SL closes never counted; `MMStatusView.feeRateBp = 5.0` applied to that
   half-true volume (`MMStatusView.swift:24/29`). The "right by accident, breaks the moment the entry/close ratio
   changes" diagnosis is exactly right. Standardizing on per-leg counting from the fills feed is the correct fix
   (just wire the live path per P4).
2. **Socket/rate discipline** — indicators off the trading socket entirely. This is the single most important
   constraint in the brief and the section nails it.
3. **Compliance framing** — decision-support not advice, no price prediction, `rebateBp = 0` until confirmed, the
   $250/$1M floor surfaced, fixed disclaimer string. Matches the brief's honesty mandate. (Rename risk only: a
   layer literally called "financial recommendation" invites the "personalized investment advice" reading the
   safety line prohibits; the disclaimers mitigate it, but keep the label discipline tight.)
4. **DGrid switch with a ±0.5σ hysteresis dead-band + ER gate** — principled anti-flap design that also protects
   the rate budget from mode-churn. Keep.
5. **Cost/$1M as the headline, shown *for the current regime* before commit** — the correct mental model
   ("ranging Grid can be net-negative cost; trending Grid you pay"). Keep the framing; just fix C1/C2 so the
   numbers behind it are honest.
6. **Grounded in real types** — fills carry `fee/isMaker/isClose`; liq-price signature matches; margin from
   `fromCNS(balance) − fromCNS(locked)`. Buildable, not hand-wavy.
7. **Supabase schema** mirrors the existing wallet-RLS, publishable-key, no-private-keys model (consistent with
   memory), and correctly degrades to offline-from-`MMStore` until the `wallet-auth` Edge Function lands.

---

## Added API/data needs (beyond the section's §6, which already lists rebates / JWT / fee schedule)
- **Confirm whether Perpl position-history `dpnl` is gross or net of trading fees** (drives C2 — a $250/$1M swing).
- **Confirm Perpl self-trade-prevention behavior** (drives R3 — compliance + fee-churn on tight Mid ladders).
- **Verify the real WS candle frame `mt` (and whether a candle stream exists at all)** before relying on it (P2),
  or drop it for periodic REST.
