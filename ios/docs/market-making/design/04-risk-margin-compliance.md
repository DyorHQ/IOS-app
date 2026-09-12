# DyorHQ Market-Making — Section: Risk, Margin Maintenance & Compliance

Owner lens: derivatives risk manager (prop-MM desk limits) + markets-compliance.
Scope: every guardrail between "user taps Start" and "session is torn down clean." This section defines the
limits, the on-chain/WS signals each limit reads, the exact trip conditions with numbers, the de-risk ladder, the
kill switch + SAFE teardown, the pre-flight gates, and the required compliance disclosures/consents.

It builds directly on the shipped v1 (`MMExecutor.stop`, `MMWatcher`, the "failed read ≠ flat" invariant, the
per-level native TP/SL brackets). Nothing here contradicts the brief's honest-economics or connection/rate limits.

---

## 0. Ground truth this section relies on (verified in-repo)

| Fact | Source in code | Used for |
|---|---|---|
| `initMarginFraction`, `maintMarginFraction` already exposed as fractions of notional (0.10 = 10%, 0.05 = 5%; `fraction = 100/value`) | `PerplExchange.market(...)` → `PerpMarket` | leverage clamp, margin ratio, maintenance buffer |
| Max leverage clamp already applied: `min(strategy.leverage, floor(1/initMarginFraction))` | `MMExecutor.place` L22-24 | hard leverage-to-market-cap clamp (extend for bias) |
| Liquidation price per position: `entry + sign·(mmr − margin − premium)/size`, `mmr = entry·size·maintFraction` | `PerplExchange.liquidationPrice`, stored as `PerpPosition.liquidation` | distance-to-liquidation |
| Per-position `margin`, `unrealized` (premium included), `premium`, `notional`, `mark`, `leverage` | `PerpPosition` | live margin ratio, kill PnL |
| Realized PnL = `balance − startBalance` (collateral Δ, net of fees); Unrealized = Σ `position.unrealized` | `MMStatusView` L26-29 | Max-Loss kill |
| SAFE teardown exists: cancel-all + flatten + **verify clean**, returns false if anything remains | `MMExecutor.stop` L62-80 | kill teardown core |
| "A failed `try?`→nil read must NOT be treated as flat" | `MMWatcher.tick` L109-113 | RPC/read-failure breaker |
| Market signals: `mark`, `oracle`, `last`, `markTimestamp`, `fundingRatePct100k`, `status`, OI | `PerpMarket`; live via `PerplFeed.state` (`PerplLiveState`) | staleness / funding / volatility breakers |
| Book: `bestBid`, `bestAsk`, `spread`, `bidShare`; trades tape; `heartbeat@143` gap → resubscribe | `PerplFeed` / `OrderBook` | spread-blowout / vol breakers |
| Trading-socket close reasons decoded: 3401 auth, 1008 conn-cap, 1008 rate-limit, 1011, 1013, 1001, 0 transport | `PerplClose` | socket-loss breaker |
| Connection limits: **4 sockets/wallet, ~120 req/min/socket, keep-alive `mt:1` @30s = 2/min ⇒ ~2 order-ops/s budget** | `PerplTradeClient`, brief §2 | every de-risk action must be rate-aware |

**Two gaps this section depends on being closed (flagged to infra/arch, §9):**
1. `PerplOrderFrame` does not emit **post-only** (`fl:1`) — limit entries currently go as GTC (`fl: ioc ? 4 : 0`).
   The "repeated post-only rejects" breaker and the honest maker-only claim both require `fl:1` wiring.
2. `PerplTradeClient.handle` parses only `mt:19/21/3`. Real fill/reject outcomes (`mt:24`) and position ids
   (`mt:26/27`) are not consumed. The kill switch and post-only-reject breaker are far more accurate with `mt:24`;
   they are designed to degrade gracefully to on-chain polling if `mt:24` is unavailable.

---

## 1. Files & types this section adds

All under `ios/DyorHQ/Strategy/` unless noted. Pure math lives in `DyorKit` so both device and worker-mirroring
tests can exercise it.

- `DyorKit/.../Perpl/PerplRiskMath.swift` — **pure, Sendable, no I/O**. The formulas below as static funcs so the
  device monitor, the pre-flight gate, and (a TS port of) the worker all agree bit-for-bit. Unit-tested.
- `Strategy/MMRisk.swift` — `RiskLimits` (Codable, persisted on `MMStrategy`), `RiskState` (live snapshot),
  `RiskLevel` enum (`green/amber/orange/red`), `RiskAction` enum, `Breaker` enum + `BreakerState`.
- `Strategy/MMRiskMonitor.swift` — `@MainActor final class MMRiskMonitor` — the fast risk loop (device side).
- `Strategy/MMKillSwitch.swift` — `MMKillSwitch` — idempotent SAFE teardown coordinated device↔worker.
- `Strategy/MMPreflight.swift` — `MMPreflight` — the pre-Start gate returning `[PreflightResult]`.
- `Strategy/MMRiskBar.swift` — the live risk status bar (SwiftUI).
- `Strategy/MMPreflightSheet.swift`, `Strategy/MMConsentSheet.swift` — pre-trade analytics + disclosures/consent.
- Extend `MMStrategy` with: `var limits: RiskLimits`, `var startEquity: Double`, `var killedReason: String?`,
  `var killedAt: Int?`, `var breakerLog: [BreakerEvent]` (capped).

`RiskLimits` (defaults are risk-desk defaults; reco/quant may tune per market — dep):

```swift
struct RiskLimits: Codable, Hashable {
    var maxLossPct: Double = 15          // Max Loss = maxLossPct% × capital (tread.fi)
    var takeProfitPct: Double            // mirrors strategy.takeProfitPct; session-level winner close
    var maxInventoryNotional: Double     // I_max; default = capital (net inventory ≤ 1× margin)
    var leverageBiasHaircut = 0.20       // directional bias raises required margin up to +20% (Arbital)
    // maintenance buffer bands (health = equity / maintenanceRequirement)
    var healthAmber = 2.00
    var healthOrange = 1.50
    var healthRed = 1.25
    // circuit-breaker thresholds (see §5)
    var volSpikeSigma = 4.0              // 1-min return z-score vs trailing 30-min σ
    var markStaleSec = 15               // no fresh mark/heartbeat
    var fundingBlowoutPctPerHr = 0.10    // |funding| > 0.10%/hr (≈ 876%/yr) → pause opens
    var spreadBlowoutMult = 3.0          // book spread > 3× the session-median spread
    var postOnlyRejectStreak = 3         // consecutive PO rejects → back off
    var socketLossSec = 20              // trading socket down > T
    var heartbeatLossSec = 45           // worker heartbeat gap (hybrid)
}
```

---

## 2. Margin maintenance

### 2.1 Init vs maintenance margin, and the hard leverage clamp (with directional bias)

Signals: `PerpMarket.initMarginFraction` (f_i), `.maintMarginFraction` (f_m). Bias `b ∈ [−1, 1]` from the config.

- Market leverage cap (already shipped): `L_max = floor(1 / f_i)`. E.g. f_i = 0.10 → 10×; f_i = 0.05 → 20×.
- **Bias haircut (Arbital "+up to 20% margin at higher bias"):** required init fraction scales with |bias|:

  ```
  f_i' = f_i · (1 + leverageBiasHaircut · |b|)          // 0.10 · (1 + 0.20·1) = 0.12
  L_cap = max(1, floor(1 / f_i'))                        // 0.12 → 8×  (was 10×)
  ```

  Applied in `MMExecutor.place` in place of the current `marketMaxLev`, and mirrored in pre-flight so the UI shows
  the *effective* cap the instant the bias slider moves. Rationale: a directional book is riskier, so we demand
  more margin per unit notional exactly as Arbital does — implemented as a lower leverage cap (mathematically
  identical to raising margin) because Perpl leverage is per-order.

- `PerplRiskMath.leverageCap(initFraction:bias:haircut:)` → the number the clamp and UI both use.

### 2.2 Live margin ratio & distance-to-liquidation

Per open position on the strategy's market (from a `PerpPosition`):

```
equity            E   = margin + unrealized            // unrealized already includes premium/funding
maintenanceReq    Mm  = notional · f_m  = size·mark·f_m
marginRatio       MR  = Mm / E                          // ≥ 1 ⇒ liquidatable
health            H   = E / Mm  = 1 / MR                // > 1 safe; the primary gauge
distanceToLiq     DTL = |mark − liquidation| / mark     // uses stored PerpPosition.liquidation
```

`PerplRiskMath.health(position:market:)` and `.distanceToLiquidation(position:)`. Aggregate over positions
(normally ≤1 per market) by taking the **worst** H and smallest DTL.

Worked example (MON, f_i 0.10 / f_m 0.05, mark 2.00, 10× target): margin $100, notional $1000, size 500.
Mm = 1000·0.05 = $50. Fresh: unrealized 0 → E $100 → H = 2.0 (amber edge). If mark drops to 1.90 (long),
unrealized = (1.90−2.00)·500 = −$50 → E $50, Mm = 950·0.05 = $47.5 → H ≈ 1.05 (RED). Liq ≈ entry + (mmr −
margin − prem)/size = 2.00 + (100 − 100 − 0)/500... (uses the exact stored value). This is why de-risk must fire
well before H → 1.

### 2.3 Maintenance buffer — de-risk BEFORE liquidation

The buffer is a **health ladder** evaluated every risk tick (§4). Actions escalate; each is rate-budget-aware and
uses **amend (t:7) not cancel+replace** wherever possible (brief §2: ~2 order-ops/s ceiling).

| Level | Trigger (worst position) | Action |
|---|---|---|
| GREEN | H ≥ 2.0 **and** DTL ≥ 8% | normal quoting |
| AMBER | 1.5 ≤ H < 2.0 **or** 4% ≤ DTL < 8% | widen half-spread ×1.5; cut *new* level size 50%; stop adding to the losing side (one-sided → reducing side only) |
| ORANGE | 1.25 ≤ H < 1.5 **or** 2% ≤ DTL < 4% | cancel the furthest 50% of resting levels (frees margin); **skew-to-flatten** (§4.3); reduce inventory to ≤ 50% of `maxInventoryNotional` via reduce-only closes |
| RED | H < 1.25 **or** DTL < 2% | reduce-only **market-close the position on this market**; pause requoting for this market for `cooldown = 60s`; log breaker. Two RED entries within one session ⇒ escalate to **Max-Loss kill** (§3) |

Confirmation rule (inherited from `MMWatcher`): AMBER/ORANGE fire on a single confirmed read; **RED and kill
require two consecutive confirmed reads OR one read where `unrealized` alone already breaches** — a single bad
read never triggers a flatten, and a *failed* read never de-escalates (§5, RPC breaker). "Add margin instead of
de-risk" is intentionally **not** offered automatically: topping up collateral to defend a losing MM inventory is
throwing good money after bad and is a manual, explicit user action only (`PerplExchange.addMarginDesc` exists).

Depends on: **quant** for the requote/amend loop these actions drive; **arch** for whether ORANGE/RED reduce-only
closes are issued by device or worker.

---

## 3. Max-Loss kill switch

### 3.1 The metric and the exact trip condition

```
MaxLoss$   = (limits.maxLossPct / 100) · capital            // tread.fi: StopLoss% × margin. 15% × $100 = $15
realized   = accountBalance − strategy.startBalance         // collateral Δ since Start (net of fees)
unrealized = Σ position.unrealized  (this market)           // MTM incl. premium/funding
netPnL     = realized + unrealized
```

**Trip when `netPnL ≤ −MaxLoss$`.** Two guards make it safe and un-spoofable:

1. **Never trip on a failed read.** `accountBalance` and positions come from on-chain reads; if either read failed
   (`try?`→nil) the tick aborts (as `MMWatcher` already does) — a missing read is *unknown*, never *zero loss*.
2. **Two-tick confirmation for the realized+unrealized path**, but an **instant trip** if `unrealized` alone
   (from a single good read) is already ≤ −MaxLoss$ (a real, already-incurred MTM loss needs no confirmation).

Secondary equity floor (defense in depth): also trip if `accountEquity < startEquity·(1 − maxLossPct/100 − 0.02)`
where `accountEquity = balance + Σ unrealized across ALL markets` — catches loss bleeding from a position the
strategy didn't open (`startEquity` captured at Start).

`PerplRiskMath.maxLossTripped(realized:unrealized:capital:maxLossPct:) -> Bool`.

### 3.2 SAFE teardown (works from device AND worker, and if one is offline)

Teardown = **cancel all → flatten all → verify clean**, idempotent and convergent (already the shape of
`MMExecutor.stop`). `MMKillSwitch.teardown(strategy:env:reason:)`:

```
1. Mark strategy.active = false, killedReason = reason, killedAt = now  → persist FIRST (MMStore),
   so no watcher/executor recycles mid-teardown (mirrors MMStatusView.stop L79).
2. Cross-actor claim: write { killRequested:true, killedBy, killedAt, reason } to the session record
   (Supabase, dep: infra). Whoever writes first owns the teardown; the other becomes a verifier.
3. cancel all resting orders on strategy.marketId  (authenticated cancel, lb:0)
4. flatten every position on strategy.marketId      (reduce-only market close, slippageBps 150)
5. verify: re-read account/orders/positions; if leftoverOrders || leftoverPositions → return false.
6. Retry with backoff (0s, 2s, 5s, 10s, 20s) up to 5×; between tries, if socket dropped, ensureConnected().
   Each retry is safe because cancel/close are convergent (a second cancel of a filled order is a no-op).
7. On success: strategy.volume/fills finalized; post .mmStrategyChanged; leave Stop visible until verified clean.
```

**Three-tier authority so a kill always happens:**

- **Device online:** `MMRiskMonitor` detects the trip and runs `teardown`. Fastest path.
- **Worker online (hybrid, arch dep):** the worker independently evaluates the *same* `RiskLimits` from the session
  record against its own live reads and runs the *same* teardown logic (TS port of `PerplRiskMath` +
  cancel/flatten/verify). Either side can kill; both are idempotent; step 2 prevents double-flatten thrash.
- **Both offline:** two server-side safety nets that need no running process:
  - **Native per-level TP/SL** already attached to every entry (Perpl keeper fires even when the app is dead).
  - **Dead-man auto-flatten:** at Start, in addition to per-level SL, register a **catastrophe SL** — a
    reduce-only stop trigger sized to the *whole* expected inventory at the price where `netPnL ≈ −MaxLoss$`, so
    Perpl's keeper flattens even if neither device nor worker is alive. Plus a worker "session deadline" flatten at
    `endsAt` (from the time-box) and, on hybrid, **auto-revoke** `allowOrderForwarding(false)` if the device stops
    renewing its lease (§5 heartbeat breaker) so a runaway executor cannot keep trading.

`RiskAction.kill(reason:)` is the only action that calls `teardown`; every breaker maps to `pause | deRisk(level:)
| flatten | kill`.

External/creds needed for the worker tier: see §9 (delegated key custody, Supabase service creds, worker deploy).

---

## 4. Inventory risk

Net signed inventory on the market:

```
N$ = Σ (side == .long ? +1 : −1) · position.notional      // net dollar inventory
skew = clamp(N$ / maxInventoryNotional, −1, +1)            // −1 fully short … +1 fully long
```

### 4.1 Max inventory cap + one-sided-trading stop (Arbital)

- `maxInventoryNotional` (I_max) default = `capital` (net exposure ≤ 1× posted margin), user-tunable, hard-capped by
  the leverage clamp (§2.1) so I_max can never exceed `capital·L_cap`.
- **When `|N$| ≥ I_max`:** stop placing any level that *increases* `|N$|` (the "adding" side). Only the reducing
  side is quoted until inventory comes back inside the band — Arbital's "stop one-sided trading when limits hit,"
  while total buy/sell volume still converges over the run. Implemented as a filter in `MMExecutor.place`:
  `if increasesInventory(level, N$) && |N$| ≥ I_max { continue }`.

### 4.2 Skew-to-flatten

Below the cap, bias quotes toward flat instead of hard-stopping. Applied on top of the ladder from `MMStrategy.levels`:

```
sizeMult(reducingSide) = 1 + 0.5·|skew|      // up to +50% size on the flattening side
sizeMult(addingSide)   = 1 − 0.5·|skew|      // up to −50% size on the side that grows inventory
spreadShift            = quoteSkewBp · skew  // widen the adding side, tighten the reducing side
```

This reuses the existing directional-bias plumbing (`bias·0.2` skew) but drives it from *live inventory*, not a
static slider. Depends on **quant** owning the final ladder function; this section supplies `skew` and the
multipliers as `PerplRiskMath.inventorySkew(netNotional:cap:)`.

### 4.3 Take-Profit% closes winners

Two layers:
1. **Per-level native TP** already placed with each entry (`submitBracket`) — the primary, app-closed-safe exit.
2. **Session-level winner close (belt-and-suspenders):** each risk tick, if a position's `unrealized ≥
   takeProfitPct% · position.margin` **and** its native TP is not currently resting (detected from open orders),
   issue a reduce-only market close. Guards against a TP trigger that was rejected at placement or cancelled during
   a de-risk step. `PerplRiskMath.shouldTakeProfit(position:takeProfitPct:)`.

---

## 5. Circuit breakers

Each runs in `MMRiskMonitor` (device) and mirrors in the worker (hybrid). Pattern for every breaker:
**detect (signal + threshold + confirmation) → action → recover (auto-resume condition)**. All actions respect the
~2 order-ops/s budget; "pause" = stop new opens but keep existing native TP/SL live.

| Breaker | Signal(s) | Detect | Action | Recover |
|---|---|---|---|---|
| **Volatility spike** | `PerplFeed.state.mark` / trade tape; trailing 1-min returns; σ over 30 min (from `PerplService.candles` at Start + live) | 1-min return z-score > `volSpikeSigma` (4σ) **or** 1-min range > 5·median | pause opens; widen spread ×2; cancel levels within 1σ of mark | 2 consecutive ticks back < 2σ → resume (spread eases over 60s) |
| **Mark/oracle staleness** | `PerpMarket.markTimestamp`, `heartbeat@143` sn gaps, `PerplFeed.connected` | `now − markTimestamp > markStaleSec` (15s) **or** heartbeat gap **or** \|mark−oracle\|/oracle > 1% | pause opens (never quote on a stale price); keep TP/SL | fresh mark within tolerance for 1 tick → resume |
| **Funding blowout** | `PerpMarket.fundingRatePct100k` (÷100k = %/interval) / `MarketContext.fundingRate` | \|funding\| > `fundingBlowoutPctPerHr` (0.10%/hr) **or** funding sign persistently against inventory | stop adding to the side that pays funding; skew-to-flatten; if \|funding\| > 3× → flatten | funding back inside band for 3 ticks |
| **Spread blowout** | `OrderBook.spread`, `bestBid/bestAsk` | live spread > `spreadBlowoutMult`× session-median spread **or** one side empty | pause opens (thin/illiquid book = adverse selection); cancel crossed/near-touch levels | spread < 1.5× median and both sides present |
| **Repeated post-only rejects** | `mt:24` reject reason (dep: infra §9) or `mt:3` non-zero on a `fl:1` frame | `postOnlyRejectStreak` (3) consecutive PO rejects on a market | back off requoting 30s; widen offset by +1 step (we're quoting inside the touch); halve requote rate | first accepted PO placement resets the streak |
| **Socket loss > T** | `PerplClose` code/reason, `PerplTrading.status`, `client.signedIn` | trading socket down > `socketLossSec` (20s). **3401 auth ⇒ do not retry** (re-enroll); **1008 conn-cap ⇒ back off 30s** (respect 4-socket cap); rate-limit ⇒ back off | pause opens (can't manage risk blind); DO NOT flatten on socket loss alone — native TP/SL cover it | `ensureConnected()` succeeds → resume; hybrid: worker keeps managing meanwhile |
| **RPC / read failure** | `try?`→nil on `account`/`positions`/`openOrders` | any required read failed this tick | **abort the tick, change nothing** — never treat unknown as flat/zero-loss (the invariant). Count consecutive failures | first good read resumes; if failures > 6 (~2 min) → pause opens + surface "risk monitoring degraded" banner |
| **Worker-heartbeat loss** (hybrid) | Supabase/worker heartbeat timestamp (dep: infra) | device sees no worker heartbeat for `heartbeatLossSec` (45s) | device assumes execution authority on next foreground; if device also backgrounded, dead-man (§3.2) is the net | worker heartbeat resumes → device yields back, one owner at a time via the session record lease |

Cross-cutting rules:
- **A breaker never *reduces* risk on a failed read** (only the RPC breaker fires; others hold their last state).
- **Two breakers active simultaneously ⇒ escalate one level** (e.g. vol-spike + spread-blowout together ⇒ flatten,
  not just pause).
- Every fire appends a `BreakerEvent{kind, at, detail, action}` to `strategy.breakerLog` (capped 100) and shows in
  the status view's event log (parity with Arbital's "trade history & event log").

Depends on: **quant** for σ/vol-forecast inputs (shared with DGrid) and the requote loop the actions steer;
**infra** for `mt:24` parsing + worker heartbeat channel; **arch** for who owns the action when hybrid.

---

## 6. Pre-flight risk gates (before Start)

`MMPreflight.evaluate(strategy:market:account:env:) -> [PreflightResult]` where
`PreflightResult{gate, status: .pass/.warn/.block, message}`. **Any `.block` disables the Start button.** Runs on
the config screen and re-runs on Confirm (state can drift between). Uses on-chain reads + the live `PerplFeed`.

| Gate | Check | Status |
|---|---|---|
| Insufficient margin (tread.fi) | `requiredMargin = deployed / L_cap` (or Σ level margin) vs `availableMargin = account.balance − account.locked`. Message mirrors tread.fi: *"Order requires $100 but only $7.10 available."* | **block** if required > available |
| Min notional / lot | every level `size ≥ 10^(−lotDecimals)` and `size·price ≥ marketMinNotional`; drop sub-min levels; block if **no** level survives | block if none valid; warn if some dropped |
| Leverage > cap | `strategy.leverage > L_cap` (bias-adjusted, §2.1) | block (or auto-clamp + warn — recommend **warn+clamp**, matching `MMExecutor` behavior, so Start still works) |
| Absurd spread | configured half-spread < book half-spread (we'd cross ⇒ taker fees, breaks maker-only) OR > 500 bp (economically pointless) | block if crossing; warn if > 200 bp |
| Market halted | `PerpMarket.status != open` / `MarketContext.isOpen == false` / stale mark (§5) | block |
| Forwarding / socket ready | `PerplTrading.status == .connected` (one-click on, socket signed in) | block if not (already gated in `MarketMakingView`) |
| Max-Loss sanity | `MaxLoss$ ≥ 2× est. round-trip fee on one full ladder` (else you'll be killed by fees before spread capture) | warn |
| Cost/$1M honesty | show computed `cost/$1M = 2·feeRateBp·100` ($ per $1M) next to the volume target | info (not a gate; see §8) |

`PerplRiskMath` provides `requiredMargin`, `minNotionalOK`, `crossesBook`. Depends on **reco** for recommended
default limits per market and **ux** for where the panel renders (it is the "Pre-Trade Analytics" panel from
tread.fi: Available Margin, Max Loss, insufficient-margin warning, est. fills, est. duration, liquidation price).

---

## 7. Live risk UI (what the running session shows)

`MMRiskBar` — a persistent bar at the top of `MMStatusView` (and mirrored in the session row's status). Ground
truth to render every ~2s tick:

- **Risk level chip**: GREEN/AMBER/ORANGE/RED (from §2.3), color from the health ladder.
- **Health / DTL gauge**: `H = 2.4` · `Liq 1.842 (−6.1%)` — smallest DTL across positions, monospaced.
- **Max-Loss meter**: `−$8.20 / −$15.00` used, a horizontal bar filling toward the kill line; turns red at 80%.
- **Inventory meter**: net `+$640 / $1,000` with a centered zero, so skew is visible.
- **Active breakers**: pills (e.g. "Spread ×3", "Stale mark 18s") with the action taken.
- **Kill button**: always present, one tap → confirm → `MMKillSwitch.teardown`. Never hidden while anything is open
  (inherits `MMStatusView` rule: keep Stop visible until verified clean).

`killedReason` renders as a banner when a session auto-stopped ("Stopped: Max Loss −$15 reached at 14:22").

Depends on **ux** for placement/theme; this section owns the fields, thresholds, and colors.

---

## 8. Compliance & legitimacy (brief §0)

The feature is **genuine two-sided liquidity provision** filled by Perpl's real order book (real counterparty, real
inventory risk). The design must make honest cost/risk unmissable and must structurally prevent wash trading.

### 8.1 Designed AGAINST self-matching / wash trading

- **Post-only maker-only entries** (`fl:1`, dep §9): our resting orders never take; volume only counts when a
  *third-party* taker hits us. This is the single most important anti-wash control — enforce it.
- **Self-match prevention:** never quote a bid ≥ our own resting ask (or ask ≤ our own bid) on the same account.
  `MMExecutor.place` already skips levels that cross the mark; extend to skip any level that would cross *our own*
  resting book (compute from `openOrders`). If Perpl exposes an STP flag on `mt:22`, set it (open question §9).
- **No paired buy+sell at the same instant/price to fake prints** — the ladder is priced around the mark with a
  fee-clearing floor (`midFloorBp 2.5`, `gridFloorBp 6.8`), so a round trip only profits on genuine price
  oscillation, never on matching ourselves.
- **One account per side** — we do not, and must not, run two DyorHQ accounts to cross each other. Out of scope,
  documented as prohibited.

### 8.2 Honest economics surfaced (never "costless profit")

- Pre-trade panel shows, before Start: **Cost/$1M** (the headline metric: `2·feeRateBp·100` = ~$500/$1M at 5 bp
  round trip — restate the brief's ~$250/$1M per *direction* correctly as $/$1M of *volume*), **Max Loss $**, est.
  fees for the target volume, and a one-line: *"Generating volume costs fees. Profit is not guaranteed and depends
  on spread capture in a ranging market; trending markets can lose."*
- Live: realized PnL is labeled "collateral change since start (net of fees)"; est. fees shown; no projected-profit
  number is ever displayed as a promise.
- If maker rebates / MM rewards exist (open question §9), show them as *potential* offsets clearly separated from
  realized PnL — never netted into a "profit" headline until actually received.

### 8.3 ToS / jurisdiction / not-advice

- Perpl/venue **Terms of Service**: automated trading and API keys must be permitted by Perpl's ToS; link it and
  require the user to confirm they've read it. Trade-scope key **cannot withdraw** (brief §2) — state that.
- **Jurisdiction:** perp DEX access is restricted in some jurisdictions; the app must not facilitate use where
  prohibited. Show a jurisdiction acknowledgment; do not geo-spoof or bypass any venue geoblock.
- **Not investment advice:** presets, "recommended" spreads, and DGrid predictions are tools, not advice. Standard
  disclaimer, once per session and in settings.
- **Non-custodial:** keys are the user's (Keychain, ThisDeviceOnly). If the **hybrid worker** holds a delegated
  key, that is an explicit, revocable, auto-expiring trust decision — see §8.4.

### 8.4 Required in-app disclosures & consents BEFORE Start (`MMConsentSheet`)

A single sheet on first Start (and re-shown when terms/version change), each item an explicit checkbox — **Start
stays disabled until all required boxes are checked**, and the consent + version is persisted per wallet:

1. ☐ *"I understand generating volume costs ~$X in fees for my $Y target and profit is not guaranteed."* (numbers
   filled from the pre-trade panel). **Required.**
2. ☐ *"I understand my position can be liquidated and I can lose up to my Max Loss of $Z (or more in a gap)."*
   **Required.**
3. ☐ *"This is legitimate two-sided market making. I will not use it to wash trade or manipulate markets."*
   **Required.**
4. ☐ *"I have read Perpl's Terms of Service and market making / automated trading is permitted for me in my
   jurisdiction."* **Required.**
5. ☐ *"I understand this is not investment advice."* **Required.**
6. **(Hybrid only)** ☐ *"I authorize DyorHQ's server to place trades with a trade-only (no-withdrawal) key that
   auto-expires at session end (`endsAt`) and can be revoked instantly."* + shows expiry + a **Revoke now** control
   (`allowOrderForwarding(false)` + forget key). **Required only if worker execution is chosen.**

Consent is recorded with a timestamp and terms-version in the per-wallet store (and the Supabase session record for
hybrid, so the worker refuses to execute a session lacking recorded consent — dep: infra).

---

## 9. Dependencies & external needs

**Cross-section dependencies (marked inline above):**
- **arch** — picks architecture A/B/C. Determines: whether a worker executor exists (§3.2 worker tier, §5 heartbeat
  breaker), kill authority/lease ownership, and delegated-key custody/expiry/revocation. *If B (device-only), the
  worker tiers degrade to native TP/SL + dead-man SL only — the design already covers this.*
- **quant** — owns the requote/amend loop and ladder function that de-risk/skew actions steer; supplies σ / vol
  forecast (shared with DGrid) consumed by the volatility breaker and the maintenance-buffer dynamics.
- **infra** — (1) wire **post-only `fl:1`** into `PerplOrderFrame.json`; (2) parse **`mt:24`** (fill/reject) and
  **`mt:26/27`** (position ids) in `PerplTradeClient` for accurate fill/PnL/post-only-reject detection; (3) worker
  endpoints + Supabase session schema below; (4) worker heartbeat channel.
- **reco** — recommended per-market `RiskLimits` defaults (maxLossPct, maxInventoryNotional, spread) and presets.
- **ux** — placement/theme of `MMRiskBar`, `MMPreflightSheet`, `MMConsentSheet` (fields/thresholds owned here).

**Worker endpoints this section assumes (hybrid; dep infra/arch to build):**
- `POST /mm/session` — register a session's `RiskLimits`, `endsAt`, consent record; returns session id.
- `POST /mm/heartbeat` — device ↔ worker liveness + lease renewal (drives §5 heartbeat breaker + dead-man).
- `GET  /mm/state` — worker's current risk snapshot (health, netPnL, breakers) for the cockpit.
- `POST /mm/kill` — request SAFE teardown (idempotent; honored by whichever side is alive).
- Worker must run the TS port of `PerplRiskMath` + cancel/flatten/verify to keep device/worker trip logic identical.

**External API / data / credentials the USER must provide:**
1. **Maker rebate / MM-reward confirmation** — does Perpl/Monad pay maker rebates, MM-program rewards, points, or
   airdrops for this volume? (Brief §0 priority-2 profit source.) Needed to honestly show potential offsets (§8.2).
   *Source: Perpl team / PerplFoundation docs.*
2. **Per-market risk params from Perpl** — `refPriceMaxAgeSec` (staleness threshold, present in `getPerpetualInfo`
   index 8 but not surfaced), `order_ttl_blocks`, min-notional, and whether an **STP (self-trade-prevention)** flag
   exists on `mt:22` (§8.1). *Source: PerplFoundation/api-docs; a small DyorKit read change, no external creds.*
3. **(Hybrid only) worker execution credentials** — a hosting secret store for the delegated trade-scoped Ed25519
   key, Supabase **service-role** creds for the session/heartbeat tables, and worker deploy access. The delegated
   key is generated per session with `scope_mask=2` (no withdrawal) and auto-expires at `endsAt`. *User must
   provision/authorize.*
4. **Perpl ToS URL / jurisdiction policy** — the exact ToS link and any geo-restriction list to render in
   `MMConsentSheet` (§8.3). *Source: Perpl.*

**Open questions:**
- Does `mt:24` carry a machine-readable post-only-reject reason, or must we infer PO rejects from a resting order
  never appearing? (Affects §5 post-only breaker fidelity.)
- Does Perpl expose STP on `mt:22`? If yes, set it and simplify §8.1 self-match prevention.
- Recommended default `maxLossPct` — I default 15% (tread.fi's example); reco to confirm per-market.
```
