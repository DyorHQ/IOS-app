# DyorHQ Market-Making — Product / UX and the LIVE STATUS BAR

**Section owner:** UX + SwiftUI. **Target:** iOS 18+, `fun.dyorhq.app`, native SwiftUI, HIG-first.
**Evolves:** `MarketMakingView.swift`, `MMStatusView.swift`, `StrategyView.swift`.
**Frame:** honest economics (Cost/$1M is the headline; no costless profit; no self-matching), hard connection
limits (1 socket/wallet, ~120 req/min ⇒ ~2 order-ops/sec), and the iOS background reality.

Dependency tags used inline: **[arch]** architecture choice + key custody · **[quant]** ladder/schedule/spread math ·
**[infra]** worker endpoints, APNs, WS bridge · **[risk]** liq/margin/max-loss formulas + kill · **[reco]**
recommendation + pre-trade analytics numbers · **[ux]** this section.

---

## 0. What ships in this section (buildable inventory)

New/changed files under `ios/DyorHQ/Strategy/` unless noted:

| File | Type | Role |
|---|---|---|
| `MMSession.swift` | model | Supersedes `MMStrategy` (adds volume target, duration, participation, reference model, reset thresholds, status, campaign). Keep `MMStrategy` as the ladder-math engine it already is; `MMSession` embeds it. |
| `MMSessionManager.swift` | `@Observable @MainActor` | The single UI-facing state hub for the running session: live metrics, connection health, Live Activity lifecycle, notification scheduling. Wraps `MMWatcher` + `PerplTrading` + (server mode) the worker stream. |
| `MMConfigView.swift` | View | Reworked `MarketMakingView` — the full tread.fi config surface. |
| `MMStatusView.swift` | View | Reworked expanded dashboard (THE live status surface, expanded form). |
| `MMLiveBar.swift` | View | The persistent, glanceable **Live Status Bar** (compact, app-wide). |
| `MMSessionsView.swift` | View | Active / History / Scheduled / Analytics / Campaigns tabs + table. |
| `MMSessionRow.swift` | View | One rich row (used in `List`; `Table` columns on regular width). |
| `MMPreTradeAnalyticsCard.swift` | View | Available margin, Max Loss, Cost/$1M, est. fills/duration, liq price, insufficient-margin gate. |
| `MMRecommendationBanner.swift` | View | ✨ suggested preset + rationale. |
| `MMSchedulePreview.swift` | View | Participation schedule timeline (Swift Charts). |
| `ReferenceModelPicker.swift` | View | Mid/Grid/DGrid/RGrid/Blend/Signal selector + conditional field routing. |
| `MMPreset.swift` | model | `MMPreset` + `MMPresetStore` (Conservative/Balanced/Aggressive + user-saved + recommended). |
| Shared design components (put in `DyorHQ/Design/`): `MetricTile.swift`, `ProgressRing.swift`, `CountdownRing.swift`, `SkewBar.swift`, `RiskGauge.swift` | Views | Reused across bar + dashboard + rows. Promote the private `StatTile` in `MMStatusView` into shared `MetricTile`. |
| `DyorHQWidgets` (new app-extension target) | target | `MMActivityAttributes.swift` (shared with app via membership) + `MMLiveActivityWidget.swift` for Live Activity / Dynamic Island. Needs `project.yml` target + `xcodegen generate`. |

Existing symbols reused verbatim: `Color.positive/.negative/.attention/.brand/.allocationSpot`; `Haptics.tap/.commit/.selection/.success/.warning/.error`; `PrimaryButton`; `InlineError`; `DetailRow`/`DetailRows`; `NumberStyle.number/.percent/.basisPoints`; `RelativeTime.short`; `BiometricGate.authenticate`; `AppSettings.requireBiometrics/.notifyFills/.notificationsEnabled`; `PerplTrading.status/.isReady/.accountId/.failureMessage/.ensureConnected/.submitBracket/.cancel/.closePosition`; `MMStore`, `MMExecutor.place/.stop`, `MMWatcher`; `env.perpl.markets/.account/.positions/.openOrders`; `OrderInput`, `BracketResult`; `.mmStrategyChanged`; `Router.openPerp`.

---

## 1. Design language (tokens applied to trading data)

**Semantic color, sign-first (color is never the only cue — existing house rule):**
- `Color.positive` → gains: net PnL ≥ 0, healthy margin/liq distance, filled-on-pace, spread capture credit.
- `Color.negative` → losses: net PnL < 0, kill fired, liquidation imminent, order rejects that stop trading.
- `Color.attention` → warnings that need a decision but haven't broken anything: approaching Max Loss, connection degraded, insufficient margin, requote throttled, one-sided-limit reached.
- `Color.brand` → progress/identity: volume ring, selected preset, primary CTA, live "quoting" pulse.
- `Color.allocationSpot` → Market-Making's identity tile (already used in `MMStatusView.headerSection` and the `StrategyCard`). Identity only, never status.

**Numerals:** every number uses `.monospacedDigit()`. The big Live-Bar and dashboard readouts use
`.font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()` so digits don't jitter as they
update. Signed money always carries an explicit `+`/`−`.

**Motion:** ring fills and the requote countdown animate with `.easeOut(0.25)`; under `Reduce Motion` they
crossfade values with no sweep. A subtle 1 Hz opacity pulse on the "Quoting" dot conveys liveness; suppressed under
Reduce Motion (dot goes solid).

---

## 2. Navigation / information architecture

`StrategyView` → **Market Making** card now routes to **`MMSessionsView`** (the home), not straight to config.
Rationale: tread.fi/Arbital's mental model is a *table of sessions* with Start on top, and a user with a running
session needs to land on status, not a fresh form.

```
StrategyView
└─ MarketMakingView == MMSessionsView (tabs: Active · History · Scheduled · Analytics · Campaigns)
   ├─ toolbar: [＋ New session] → MMConfigView
   ├─ Active row / Live Bar tap → MMStatusView (expanded dashboard)
   └─ History/Scheduled row → MMStatusView (read-only / editable-schedule variants)
```

The **Live Status Bar (`MMLiveBar`)** is mounted app-wide in `RootView` (above the tab bar), so a running session
is glanceable from *any* tab, matching "Now Playing." See §4.

---

## 3. THE CONFIG SCREEN — `MMConfigView`

A grouped `List` (`.insetGrouped`), `scrollDismissesKeyboard(.interactively)`, `keyboardDoneButton()`, with a
persistent bottom `safeAreaInset` action bar. Section order top→bottom:

1. Recommendation banner (if reco available)
2. Presets
3. Account
4. Pair
5. Capital (Margin + Leverage)
6. Volume target
7. Participation Rate → Duration
8. Reference Price model (+ its conditional fields)
9. Spread
10. Stop-Loss / Take-Profit
11. Ladder preview + Schedule preview
12. Pre-Trade Analytics (with insufficient-margin gate)
13. Honest-economics disclosure
→ bottom bar: Start (biometric-confirmed) / gates.

### 3.0 State

```swift
struct MMConfigView: View {
    // identity
    @State private var market: PerpMarket?
    @State private var account: PerpAccount?
    // config (mirrors MMSession fields)
    @State private var referenceModel: MMReferenceModel = .grid
    @State private var marginText = "100"
    @State private var leverage = 5.0
    @State private var volumeTargetText = ""            // empty ⇒ use heuristic
    @State private var participation: MMParticipation = .normal
    @State private var durationAuto = true
    @State private var durationMin = 20.0
    @State private var spreadBp = 8.0
    @State private var bias: MMBias = .neutral           // Mid only
    @State private var gridResetPct = 0.25               // Grid/DGrid
    @State private var tpResetPct = 0.25                 // RGrid/DGrid
    @State private var stopLossPct = 15.0
    @State private var takeProfitPct = 0.5
    @State private var blendWeight = 0.5                 // Blend only (mid↔grid)
    @State private var rsiPeriod = 14                    // Signal only
    // gates / flow
    @State private var analytics: MMPreTradeAnalytics?   // [reco]/[quant]/[risk]
    @State private var confirmStart = false
    @State private var placing = false
}
```

New enums (in `MMSession.swift`):

```swift
enum MMReferenceModel: String, CaseIterable, Identifiable {
    case mid, grid, dgrid, rgrid, blend, signal
    var id: String { rawValue }
    var label: String { switch self { case .mid:"Mid"; case .grid:"Grid"; case .dgrid:"DGrid"
        case .rgrid:"RGrid"; case .blend:"Blend"; case .signal:"Signal" } }
    var blurb: String { … } // one line each, shown in the picker
}
enum MMParticipation: String, CaseIterable, Identifiable { case aggressive, normal, passive
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var pct: Double { switch self { case .aggressive: 0.10; case .normal: 0.05; case .passive: 0.02 } } // [quant] owns real values
}
enum MMBias: String, CaseIterable, Identifiable { case short, neutral, long; var id:String{rawValue} }
```

### 3.1 Recommendation banner — `MMRecommendationBanner` **[reco]**

Top card (Brand-tinted, like `StrategyView.pendingBanner`). Shows the suggested preset for `market` + `margin`:
> ✨ **Recommended: Grid · 8 bp · Normal** — "MON is ranging (24h realized vol 34%); a tight grid captures the
> chop. ~$15k volume in ~22 min, est. Cost/$1M **$180**." **[Apply]**

Tapping applies the whole preset (fills every field, sets `referenceModel`, `spreadBp`, `participation`,
`durationAuto=true`) with `Haptics.selection()`. **[dep: reco]** supplies `MMRecommendation { model, spreadBp,
participation, rationale, estCostPer1M }` from a `env.reco.marketMaking(market:margin:)` call. If reco unavailable,
the banner is hidden (never blocks).

### 3.2 Presets — `MMPresetStore`

Horizontal `ScrollView` of chips inside a section: `Conservative` · `Balanced` · `Aggressive` · `✨ Recommended` ·
user-saved · `Custom`. Selecting fills all fields; editing any field flips selection to `Custom`. A "Save preset…"
row (context menu on a chip → rename/delete). Built-ins:

| Preset | model | spread | participation | SL% | TP% | lev |
|---|---|---|---|---|---|---|
| Conservative | Grid | 14 bp | Passive | 8 | 0.4 | 3× |
| Balanced | Grid | 8 bp | Normal | 15 | 0.5 | 5× |
| Aggressive | DGrid | 5 bp | Aggressive | 25 | 0.6 | 8× |

```swift
struct MMPreset: Codable, Identifiable, Hashable { var id: String; var name: String
    var model: MMReferenceModel; var spreadBp: Double; var participation: MMParticipation
    var leverage: Double; var stopLossPct: Double; var takeProfitPct: Double; var builtIn: Bool }
enum MMPresetStore { /* per-wallet UserDefaults, mirrors MMStore */ }
```

### 3.3 Account

Perpl is one-account-per-wallet today (`accountId` from the trading WS == on-chain account). Render **read-only**,
not a picker:

```
Account   0x1a2b…9f0   ▸        (tap → wallet switch if app has >1 wallet)
          Available 92.10 AUSD · Balance 100.00 AUSD
```
`LabeledContent` + a secondary line for available/locked from `env.perpl.account(owner)`.
**[open question]** Does Perpl expose sub-accounts? If yes, this becomes a `Picker`. Flagged in §11.

### 3.4 Pair — `MarketPickerRow` → sheet

Row shows logo + `BTC:PERP-AUSD` + mark + 24h change. Tapping opens a searchable sheet listing markets with **24h
volume** (needed downstream for duration). Reuses `TokenLogo`. Populated from `env.perpl.markets()` filtered to
`status == 0 || mark > 0` (existing filter). 24h volume field: **[dep: infra/quant]** — see §11 (must confirm it's
on `market-state@143` or derive from candles).

### 3.5 Capital — Margin + Leverage

```
Margin        [ 100 ] AUSD
Leverage      ●———————  5×        (Slider 1…marketMax, marketMax = floor(1/initMarginFraction))
              Deployed ≈ 500 AUSD notional
```
`AmountField`-style margin entry (decimal pad). Leverage is a `Slider(1...marketMax, step: 1)` (not the old
`Stepper 1…10`) because tread.fi runs 15× and the market cap can be higher; `MMExecutor.place` already clamps to
`marketMaxLev`. Live "Deployed" caption = `margin × leverage`.

### 3.6 Volume target

First-class, tread.fi's core addition:
```
Volume target   [ 15,000 ] $        [×10] [×20] [×50]
                Default ≈ margin × 20
```
`AmountField` + quick-multiplier chips. Empty field ⇒ heuristic `margin × 20` (shown as placeholder). Changing
margin re-suggests the placeholder but never overwrites a typed value. `Haptics.selection()` on chip tap.

### 3.7 Participation Rate → Duration (auto-computed)

```
Participation   [ Aggressive | Normal | Passive ]      (segmented)
                ≈ 5.0% of market volume · target ~22 min

Duration        ●——————————  22 min      [Auto ✓]
                (Slider 10…1000, disabled tint when Auto; drag flips Auto off)
```
Segmented `Picker` for participation. Below it, a caption computed live. Duration is a `Slider(10...1000)` with an
`Auto` toggle:

- **Auto ON:** `durationMin` = **[quant]** `computeDuration(volumeTarget, market.vol24h, participation.pct)`.
  Reference formula (quant owns the real one): your per-minute share of market flow is
  `share/min = participation.pct × market.vol24h / 1440`; `duration = volumeTarget / share`.
  Worked example: target $15,000, MON 24h vol $43,200,000, Normal 5% ⇒ share/min = 0.05 × 43.2M / 1440 = **$1,500/min**
  ⇒ duration = 15,000 / 1,500 = **10 min** → clamped to `[10,1000]`. (Aggressive 10% → ~5 min → clamps to 10;
  Passive 2% → ~25 min.)
- **Auto OFF:** user drags; participation caption recomputes backward (effective % for the chosen duration).

### 3.8 Reference Price model — `ReferenceModelPicker` + conditional fields

Six models don't fit a segmented control. Use a `Menu`-backed picker row showing the label, or (recommended) a
2-col chip grid where each chip shows label + one-line blurb; selection sets `referenceModel` and animates the
conditional fields in/out with `.animation(.snappy, value: referenceModel)`.

**Conditional field visibility (the exact rules):**

| Field | Mid | Grid | RGrid | DGrid | Blend | Signal |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| Directional Bias (Short/Neutral/Long) | ✅ | — | — | — | ✅ | — |
| Spread (bp slider) | ✅ | ✅ | ✅ | auto* | ✅ | ✅ |
| Grid Reset Threshold | — | ✅ | — | ✅ | ✅ | — |
| TP Reset Threshold | — | — | ✅ | ✅ | — | — |
| Blend weight (mid↔grid) | — | — | — | — | ✅ | — |
| RSI period + thresholds | — | — | — | — | — | ✅ |
| Levels per side / grid levels | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Size curve (flat/linear/geo) | ✅ | — | — | — | ✅ | — |

\*DGrid shows spread as a **computed, read-only** value ("Adaptive · ~6 bp from 34% realized vol") because it uses
historical volatility to set spread; a "override" toggle reveals the manual slider for power users. **[quant]** owns
DGrid vol→spread, Blend weighting, and Signal RSI gating; UX renders whatever `MMSession.levels(mark:)` produces.

Model blurbs (copy):
- **Mid** — "Quote both sides of the mid. Add a directional lean."
- **Grid** — "Buy low, sell high. Best in ranging markets. Re-centers past the reset threshold."
- **RGrid** — "Buy high, sell low. Best in trends. Uses a TP reset threshold."
- **DGrid** — "Switches Grid↔RGrid on predicted volatility; spread set from history."
- **Blend** — "Mix of Mid and Grid behavior."
- **Signal** — "Quote skewed/gated by RSI."

### 3.9 Grid / TP Reset Threshold

Rendered inside the model section per the table. Segmented or `Menu`:
```
Grid Reset   [ 0.05% · 0.125% · 0.25% · 0.5% · 1% ]
```
Footer copy differs by model: Grid/DGrid → "Re-center the ladder when price moves beyond this."; RGrid → "Reset
take-profits when price runs this far." **[quant]** consumes `gridResetPct`/`tpResetPct` in the requote loop.

### 3.10 Spread

```
Spread    safer ●——————— aggressive    8 bp
          Floor 2.5 bp (Mid) / 6.8 bp (Grid) — below this you can't clear round-trip fees.
```
`Slider` with a gradient track (positive→attention) purely decorative. Value clamps to the fee floors
(`MMStrategy.midFloorBp = 2.5`, `gridFloorBp = 6.8`). Footer states the honest floor so a user can't dial in a
guaranteed-loss spread. Hidden/auto in DGrid (§3.8).

### 3.11 Stop-Loss / Take-Profit

```
Stop-Loss    ●———————  15%     Max Loss ≈ $15.00     (SL% × margin, live)
Take-Profit  ●——————— 0.5%     per-level bracket
```
Two `Slider`s. SL caption computes **Max Loss = stopLossPct/100 × margin** live (tread.fi: 15%×$100=$15) and is
the kill threshold surfaced later. SL = 0 → "Off" (allowed, but the pre-trade card then flags "no automatic kill").
TP/SL are placed as native Perpl triggers per level (existing `submitBracket`), so they fire venue-side even when
the app is dead — say so in the footer (existing copy).

### 3.12 Ladder preview + Schedule preview

Two previews:

**Ladder preview** (keep existing `previewSection`): resting bid/ask (or buy/sell) rows with size + TP/SL, sorted
by price, from `session.strategy.levels(mark:)`. Header shows order count + total deployed.

**Schedule preview** — `MMSchedulePreview` (new, Swift Charts): a horizontal bar/area of planned child-order
*slices* over the duration, so the user sees the pace ("~$1,500/min for 10 min"). **[quant]** supplies
`[MMSlice { offsetSec, plannedNotional }]`; if unavailable, degrade to a single caption "≈ 20 requotes over 10 min."

```swift
Chart(slices) { s in
    BarMark(x: .value("t", s.offsetSec/60), y: .value("$", s.plannedNotional))
        .foregroundStyle(Color.brand.gradient)
}.frame(height: 90).chartYAxisLabel("$/min")
```

### 3.13 Pre-Trade Analytics — `MMPreTradeAnalyticsCard` (with the margin gate)

A prominent card above the action bar (recomputes on any field change, debounced 300 ms). Mirrors tread.fi's panel.
Numbers come from **[reco]/[quant]/[risk]**; UX composes them into `MMPreTradeAnalytics`:

```swift
struct MMPreTradeAnalytics {
    let availableMargin: Double      // [risk] account.balance − locked
    let requiredMargin: Double       // [quant] to sustain the ladder over the schedule
    let maxLoss: Double              // [ux] stopLossPct/100 × margin
    let estFeesTotal: Double         // [quant] volumeTarget × 5bp/1e4  (≈ $75 on $15k)
    let estCostPer1M: Double         // [quant] net cost per $1M of volume (see §4 formula)
    let estFills: Int                // [quant]
    let estDurationMin: Double       // [quant] (== durationMin when Auto)
    let liquidationPrice: Double?    // [risk]
    let sufficient: Bool             // requiredMargin ≤ availableMargin
}
```

Layout: a `DetailRows` receipt —
```
Available margin      92.10 AUSD
Max Loss              −$15.00           (attention)
Est. fees (round-trip) $75.00
Est. Cost/$1M          $180             (brand if ≤ $250, attention if higher)
Est. fills             ~120
Est. duration          10 min
Liquidation price      $2.91  (−7.2% away)   (negative tint if <2% away)
```

**Insufficient-margin gate:** when `!analytics.sufficient`, replace Start with an inline `InlineError` styled like
tread.fi: **"This session needs $100.00 but only $7.10 is available. Lower the margin or fund Perpl."** and swap
the bottom button to **Fund Perpl** (`router.openPerp(id:)`). This extends the existing `capital <= available`
check in `MarketMakingView.start()` to be *pre-emptive and continuous*, not only at tap.

### 3.14 Start — biometric-confirmed flow

Bottom `safeAreaInset` action bar handles all gates in priority order (same ladder as today, extended):

1. **Existing running session on this pair** → "View running session" (Brand) → `MMStatusView`.
2. **No funded account** → "Fund Perpl" (Brand) → `router.openPerp`.
3. **One-click trading off** (`!perplTrading.isReady`) → "Enable One-Click Trading" → `PerplTradingView`.
4. **Insufficient margin** → the gate in §3.13.
5. **Ready** → `PrimaryButton("Start Session")`.

Start sequence:
```
tap Start
 → Haptics.commit()
 → if AppSettings.requireBiometrics: await BiometricGate.authenticate(reason:
       "Confirm to start a market-making session on \(pair)")  // false ⇒ abort, no error toast
 → confirmation sheet (see below)
 → [arch] server/hybrid only: key-grant consent step (see §3.15)
 → place: MMExecutor.place(...) (existing), persist MMSession BEFORE placing (existing invariant)
 → success: Haptics.success(); start Live Activity; route to MMStatusView
 → failure: Haptics.error(); InlineError with result.error
```

Confirmation sheet (`.confirmationDialog` or a custom `.sheet` for the richer content) states the honest deal:
> **Start Balanced · Grid on MON-PERP?**
> Deploys ≈ 500 AUSD across 6 bracketed orders. Target $15,000 volume in ~10 min. **Max Loss −$15.00**
> (auto-flatten). Est. cost **$180 / $1M**. Each level auto-closes at its take-profit or stop-loss.
> **[Start & place 6 orders]**

### 3.15 Key-custody consent (server/hybrid only) **[dep: arch]**

If **[arch]** chooses B (on-device foreground) this step doesn't exist — the key never leaves the Keychain and the
session runs only while the app is open (say so plainly, see §6.running). If **[arch]** chooses A/C (worker
executor), Start must render an explicit, revocable, auto-expiring trust decision — this is a **standing
configuration change**, so it requires clear consent (never buried):

> **Run this in the background?**
> To keep quoting while your phone is locked, DyorHQ will hand a **trade-only key** (cannot withdraw funds) to the
> DyorHQ worker. It **auto-expires at session end (~10 min)** and you can revoke it instantly with Stop.
> **[Run in background]**  ·  **[Keep it on-device only]**

UX renders it; **[arch]** owns the session-scoped key mint + `scope_mask=2` enrollment + auto-expiry, **[infra]**
owns the worker endpoint. If the user picks "on-device only," fall back to §6.running foreground behavior.

---

## 4. THE LIVE STATUS BAR (the must-have)

Two coordinated surfaces backed by one state object, `MMSessionManager`:

- **Compact bar `MMLiveBar`** — always visible, app-wide, one line. The "Now Playing" of trading.
- **Expanded dashboard `MMStatusView`** — the full instrument panel (evolves today's view).

Plus off-app: **Live Activity + Dynamic Island** and **push**.

### 4.0 The state object — `MMSessionManager`

```swift
@Observable @MainActor
final class MMSessionManager {
    private(set) var live: MMLiveMetrics?     // nil when no active session
    private(set) var connection: MMHealth = .init()
    // drives everything below; recomputed from WS ticks (throttled 2 Hz) + on-chain polls (5–8 s)
}

struct MMLiveMetrics {
    let session: MMSession
    // time
    var startedAt: Date; var plannedEnd: Date
    // volume / fills
    var volume: Double; var volumeTarget: Double
    var filledPct: Double          // schedule adherence, see formula
    // economics
    var realizedPnL: Double; var unrealizedPnL: Double     // total = sum
    var feesSoFar: Double
    var costPer1M: Double
    // inventory
    var inventoryBase: Double; var inventoryNotional: Double; var skew: Double  // −1…+1
    // book
    var liveSpreadBp: Double; var restingOrders: Int; var nextRequoteAt: Date?
    // risk
    var marginRatio: Double; var liquidationPrice: Double?; var distToLiqPct: Double?
    var maxLoss: Double; var drawdown: Double     // drawdownPct = drawdown / maxLoss
    var status: MMStatus
}

struct MMHealth { var trading: PerplTrading.Status = .notEnrolled
    var marketData: Bool = false; var worker: MMWorkerHealth = .na
    var lastTick: Date? }
enum MMStatus: String, Codable { case scheduled, running, paused, finished, canceled, killed }
```

**Exact formulas (numbers):**
- `elapsed = now − startedAt`; `remaining = max(0, plannedEnd − now)`.
- `volumePct = volume / volumeTarget` → e.g. 9,300 / 15,000 = **62%**.
- `filledPct` **[quant]** = executed scheduled slices / total slices; if slices unavailable, fall back to
  `min(1, volumePct / max(0.01, elapsed/plannedDuration))` capped at 100% (pace vs. plan). Documented as
  "execution vs. schedule," distinct from `volumePct`.
- `realizedPnL = account.balance − session.startBalance` (collateral delta, already net of paid fees — existing).
- `unrealizedPnL = Σ position.unrealized` (existing).
- `totalPnL = realizedPnL + unrealizedPnL`.
- `feesSoFar` = precise from `mt:24` fill fees if captured **[infra/quant]**, else estimate `volume × 5 / 10_000`
  (existing `feeRateBp = 5.0`).
- **`costPer1M = −totalPnL × 1_000_000 / max(volume, 1)`** — the headline. Positive ⇒ it's costing you
  $X per $1M; negative ⇒ net credit. Example: totalPnL −$2.70 on $9,300 volume ⇒ cost = **$290/$1M** (Attention,
  above the ~$250 fee floor). Color: `costPer1M <= 250` → Brand; `> 250` → Attention; `< 0` → Positive.
- `skew = inventoryNotional / max(deployed, 1)` clamped −1…+1 (−1 fully short, +1 fully long).
- `liveSpreadBp` **[quant]** = (bestAsk − bestBid)/mid × 10_000 from `order-book@id`.
- `distToLiqPct` **[risk]** = `(mark − liquidationPrice)/mark` (long) — color Positive >5%, Attention 2–5%,
  Negative <2%.
- `drawdownPct = max(0, −totalPnL) / max(maxLoss, 0.01)` → the distance-to-kill bar fills toward 100%; at ≥100%
  the **[risk]** kill fires (cancel all + flatten), `status = .killed`.

### 4.1 Compact bar `MMLiveBar` — layout, pinning, cadence

Mounted in `RootView` via a `.mmLiveBar(manager:)` modifier (an `overlay(alignment: .bottom)` offset above the tab
bar, or `safeAreaInset(edge:.bottom)` on the `TabView`). Visible whenever `manager.live?.status ∈ {running,
paused}`. Height ≈ 56 pt, `.regularMaterial` background, 1 pt hairline top border, `RoundedRectangle` 16 pt inset
8 pt from edges. Tap → present `MMStatusView`. Long-press → context menu (Pause/Resume, Stop & Flatten, Share).

```
┌───────────────────────────────────────────────────────────────┐
│ ◐ MON·Grid   (▓▓▓▓▓▓░░░ 62%)   ⏱ 12:04   +$3.21   ⚠︎   ›       │
└───────────────────────────────────────────────────────────────┘
  glyph+pair   volume ring+%      remaining   netPnL  risk pip  chevron
```

What pins where (left→right, priority under Dynamic Type truncation):
1. **Mode glyph + pair** (identity; `square.grid.3x3`/`arrow.left.and.right`, `allocationSpot`). Never dropped.
2. **Volume `ProgressRing` + %** (Brand). The single most-glanceable "am I done yet." Never dropped.
3. **Remaining time** — `Text(timerInterval: now...plannedEnd, countsDownFrom:)` ticks with zero timer code.
   Drops to icon-only at AX3+.
4. **Net PnL** — Positive/Negative, signed, monospaced. Drops before time.
5. **Risk pip** — a single dot that turns `Attention` when `drawdownPct ≥ 0.7` **or** `distToLiqPct < 0.05` **or**
   connection degraded; `Negative` when kill/liq imminent; hidden when healthy. Drops last (it's a safety cue).

Cadence: the bar reads cached `manager.live` (no network of its own). The ring/PnL update at the manager's 2 Hz
display coalesce; the time label self-ticks. At AX sizes the bar grows to two lines (identity+ring on line 1,
time+PnL+pip on line 2).

Paused state: ring desaturates to `.secondary`, a "Paused" pill replaces the % ; PnL still live.

### 4.2 Expanded dashboard `MMStatusView` — full instrument panel

Reworks today's `MMStatusView`. A `List` with a **pinned header** (the same 5 glances, larger) + a **pinned risk
footer** above the action bar; the middle scrolls. `TimelineView(.periodic(from:.now, by: 1))` wraps the time/countdown
tiles; everything else driven by `manager`.

**Pinned header (hero):**
```
◐  Grid · MON-PERP                                   ● Quoting
   ⏱ 12:04 left · 07:56 elapsed
   ┌──────── Volume ────────┐   Net PnL
   │   ◐ 62%   $9,300 / 15k │   +$3.21
   └────────────────────────┘   (realized +$1.02 · unreal +$2.19)
```
`ProgressRing` (Brand) for volume; PnL split into realized/unrealized subline (both signed, colored).

**Metric grid** (`MetricTile` 2-up, promoted from the private `StatTile`; adds a caption + optional trend):
| Tile | value | color rule |
|---|---|---|
| Cost / $1M | `$290` | Brand ≤250 · Attention >250 · Positive <0 |
| Fees so far | `$4.65` | secondary |
| Filled % | `71%` | secondary (Attention if <40% mid-session ⇒ orders not getting hit) |
| Resting orders | `6` | secondary (Attention if 0 while running) |
| Live spread | `8 bp` | secondary |
| Next requote | countdown `0:07` (`CountdownRing`) | Attention if "throttled" |

**Inventory & skew** — full-width `SkewBar` (bipolar): `short ◄──●──► long`, thumb at `skew`, label
"Net +0.014 MON (+$63, long)". Positive/Negative tint by side; center notch at 0.

**Risk footer (pinned):** three compact gauges via `RiskGauge`:
- **Margin ratio** (equity/maint) — arc, Positive→Attention→Negative.
- **Distance to liquidation** — `−7.2% · $2.91` , color by `distToLiqPct` bands (§4.0).
- **Distance to Max-Loss kill** — a bar filling toward the −$15.00 kill; label "−$2.70 of −$15.00 (18%)"; turns
  Attention at 70%, Negative at 100% (kill).

**Connection/worker health** — a small row under the header: three chips
`Trading ● · Market data ● · Worker ●` mapping `manager.connection`. Colors: connected→Positive dot, connecting→
Attention, failed→Negative + tap shows `PerplClose`/`failureMessage` reason. Worker chip only in server/hybrid mode.

**Fills feed** — keep today's list (`s.fills.reversed().prefix(20)`), add per-fill notional and side coloring
(already partly there). Add "Load older" if backed by mt:24 history **[infra]**.

**Bottom action bar:** `Pause` (secondary) · `Stop & Flatten` (destructive, existing confirmation + verify-clean
`MMExecutor.stop`) · `Share` (see §5). While `.finished`/`.killed`/`.canceled`, the bar becomes
`Clone` + `View report`.

**Cadence (foreground, dashboard open):**
- Market-data WS (`order-book@id`, `market-state@143`) → mid/spread/unrealized, coalesced to **2 Hz**.
- Authoritative on-chain poll (`account`,`positions`,`openOrders`) → **every 5 s** while expanded (today's view
  polls 8 s; tighten when on-screen), **8 s** when only the bar is showing. Reuses the `.mmStrategyChanged`
  notification + `refreshable`.
- Countdowns/elapsed → local `TimelineView` 1 Hz, no network.
- Server mode: replace polls with a worker push stream **[infra]** (`GET /api/mm/session/:id/stream` SSE/WS) so
  the device is a pure cockpit; on-chain poll becomes a 30 s reconciliation fallback.

### 4.3 Live Activity / Dynamic Island + push (backgrounded / closed) **[dep: infra, arch]**

New extension target `DyorHQWidgets`. `MMActivityAttributes` (static: pair, mode, startedAt, plannedEnd,
volumeTarget, maxLoss) + `ContentState` (dynamic: volume, totalPnL, costPer1M, drawdownPct, status, staleDate).

**Start/update/end:**
- On Start success, app calls `Activity.request(attributes:content:pushType:)`. In **on-device mode**, the app
  updates the Activity while foregrounded and sets `staleDate = plannedEnd`; the countdown ticks via
  `Text(timerInterval:)` with **no** pushes needed.
- In **server/hybrid mode**, request with `.pushType(.token)`, send the token to the worker **[infra]**; the worker
  pushes `ContentState` updates via **APNs Live Activity** so the ring/PnL move while the app is closed. Throttle to
  **material events + a 60 s floor** to respect ActivityKit's budget: fills crossing 25/50/75/100% volume, risk
  crossing 70% max-loss, kill, requote-failing, finished.
- `Activity.end(...)` on finish/kill/cancel with a final frame that persists briefly (dismissal policy `.after`).

**Dynamic Island:**
- *Compact leading:* mode glyph. *Compact trailing:* volume % (or PnL when risk elevated).
- *Minimal:* the volume `ProgressRing`.
- *Expanded:* volume ring + `$9,300/15k`; remaining `Text(timerInterval:)`; `Cost/$1M`; distance-to-kill bar;
  a Stop deep-link button (`Link(destination: dyorhq://mm/stop/:id)`).
- *Lock Screen / banner:* essentially the compact `MMLiveBar` in Live-Activity form.

**Push notifications** (separate from Live Activity, gated by `AppSettings.notifyFills`/`.notificationsEnabled`):
volume milestones, approaching Max Loss, kill fired, liquidation warning, session finished, connection lost >60 s,
requotes failing. **On-device mode**: local `UNUserNotification`s scheduled/fired when the app wakes or is
foregrounded (plus a "session may be paused — reopen to resume" note, since iOS suspends the loop). **Server mode**:
real APNs pushes from the worker so they arrive with the app closed. **[infra]** owns APNs; §11 lists the required
Apple credentials.

---

## 5. The sessions table — `MMSessionsView`

Native SwiftUI, not a web table. A `Picker(.segmented)` selects the tab; content is a `List` on compact width and a
`Table` on regular width (iPad / landscape / Stage Manager) via `horizontalSizeClass`.

Tabs: **Active · History · Scheduled · Analytics · Campaigns**.

**Columns** (tread.fi parity): Mode · Pair · Account · Volume · Fees · PnL · Cost/$1M · Spread · Filled % · Status.
On compact width these become a two-line `MMSessionRow`:
```
◐ Grid · MON-PERP                          ● Running
  $9,300 vol · +$3.21 PnL · $290/$1M · 8bp · 62% filled · fees $4.65
```
On regular width, a real `Table`:
```swift
Table(sessions) {
    TableColumn("Mode") { ... }; TableColumn("Pair") { ... }; TableColumn("Account") { ... }
    TableColumn("Volume") { USDText(value: $0.volume) }
    TableColumn("Fees")   { USDText(value: $0.fees) }
    TableColumn("PnL")    { PnLText($0.pnl) }
    TableColumn("Cost/$1M"){ CostText($0.costPer1M) }
    TableColumn("Spread") { Text("\(Int($0.spreadBp)) bp") }
    TableColumn("Filled") { Text(NumberStyle.percent($0.filledPct, signed:false)) }
    TableColumn("Status") { MMStatusPill($0.status) }
    TableColumn("") { MMRowMenu($0) }   // actions
}.monospacedDigit()
```

**Status pill** `MMStatusPill` (evolves the private `RunPill`): running→Positive+pulse, paused→Attention,
scheduled→Brand(clock), finished→secondary(check), canceled→secondary, killed→Negative(bolt).

**Row actions** (swipe actions + `.contextMenu` + the `⋯` menu, so each is reachable per HIG):
- **Clone** → opens `MMConfigView` prefilled from this session (Haptics.selection).
- **Cancel** (running/scheduled only) → confirm → `MMExecutor.stop` (running) or unschedule (scheduled),
  destructive, `Haptics.warning`.
- **Restart / Repeat** (finished/canceled) → clone + immediate Start flow (§3.14).
- **Share** → `ShareLink` with a rendered summary card (see below) — no PII, honest metrics.

**Toolbar:** `＋ New session` (→ config) always; on the Scheduled tab, `Schedule…`; on History/Analytics, a range
`Menu` (24h/7d/30d/All).

**Active tab:** live rows bound to `MMSessionManager`; the top one mirrors the Live Bar.

**Scheduled tab:** future sessions (`status == .scheduled`, `scheduledStartAt`). Rows show the countdown + edit.
Scheduling itself is a date/time picker in the config's action area ("Start now ▾ / Schedule for…"). **[infra/arch]**:
a scheduled session that must fire while the app is closed **requires the worker** (iOS can't self-launch a bot);
on-device-only mode can only *remind* the user to open the app at the time (local notification) — surface this
limitation honestly in the schedule sheet.

**Analytics tab:** aggregate over the range — total volume, total fees, blended **Cost/$1M** trend, realized PnL,
win-rate of sessions, best pair. Swift Charts: a `LineMark` Cost/$1M over sessions and a `BarMark` volume/day. Ties
to tread.fi's "Lifetime Summary (Volume, Net Fees)."

**Campaigns tab:** a **campaign** = a named group of sessions targeting a cumulative volume goal, optionally
repeating (e.g. "$1M over a week, 10 sessions/day"). `MMCampaign { id, name, targetVolume, sessionIds, repeatRule,
progress }`. Row shows cumulative volume ring + blended cost + a repeat/swap-sides control (alternate long/short
grid direction each run to keep inventory neutral over the campaign). Running a campaign end-to-end while closed is
**server-only [dep: arch/infra]**; on-device mode runs its sessions one at a time, attended.

**Share card** (rendered off-screen `ImageRenderer` → PNG, then `ShareLink`): mode·pair, volume, Cost/$1M, PnL%,
duration, DyorHQ wordmark. Honest by construction — shows cost, not just volume. No wallet address, no absolute
balance.

---

## 6. States & feedback

| State | Trigger | UX | Haptic | Notification |
|---|---|---|---|---|
| **Empty / onboarding** | no sessions ever | `MMSessionsView` shows a hero card: what MM is, the honest-economics line ("volume isn't free — you pay ~$250/$1M in fees; profit comes from spread capture + incentives"), "Start your first session" CTA. | — | — |
| **One-click gate** | `!perplTrading.isReady` | config bottom bar → "Enable One-Click Trading" → `PerplTradingView` (existing). | tap | — |
| **Funding gate** | no account / insufficient | "Fund Perpl" + the §3.13 margin gate. | warning | — |
| **Running** | placed OK | Live Bar + dashboard live; "Quoting" pulse. On-device mode adds a persistent note: "Keep DyorHQ open to keep quoting; TP/SL stay armed if you close." | success on start | fill milestones |
| **Paused** | user Pause, or app backgrounded in on-device mode | orders cancelled/held per policy, position kept; bar shows "Paused"; Resume CTA. | selection | "Session paused — reopen to resume" (on-device) |
| **Approaching Max Loss** | `drawdownPct ≥ 0.7` | risk bar Attention; bar risk-pip Attention. | warning | "MON session near Max Loss (−$10.50 of −$15)" |
| **Killed** | `drawdownPct ≥ 1` (**[risk]** flatten) | dashboard turns to a killed report; status pill Negative. | error | "MON session stopped at Max Loss. Flattened." |
| **Finished** | volume target hit or duration elapsed (graceful wind-down: stop quoting, flatten, verify) | success report: final volume, Cost/$1M, PnL, fees; Clone/Repeat CTA. | success | "MON session finished — $15k volume, $190/$1M." |
| **Connection lost** | `PerplTrading.status == .failed` / WS down >60 s | health chips Negative; banner with reason (`failureMessage`/`PerplClose`); auto-reconnect per existing single-flight/backoff. | warning | "Trading connection lost — session paused." |
| **Order reject** | `submitBracket` result error / naked-entry cancelled | toast + fills-feed annotation; if it repeats, escalate to the connection banner. | error | — |

**Error surfaces:** inline (`InlineError`) in config; a dismissible banner at the top of the dashboard for
session-level faults; toasts for transient order rejects. Always show the *real* reason (`PerplClose`, sr codes)
translated by `describe(_:)` — never a generic "something went wrong."

**Notifications** are all gated by `AppSettings.notificationsEnabled` + the specific toggle (`notifyFills` for
milestones; a new `notifyRisk`/`notifySessions` toggle — add to `AppSettings` — for kill/finish/connection).
Delivery honesty: on-device mode says notifications may be delayed (app suspended); server mode delivers via APNs.

---

## 7. Accessibility · Dynamic Type · light/dark

- **Color is never sole cue:** every status carries a sign, word, or glyph (PnL `+`/`−`; status pills have icons;
  risk uses labels). Already the house rule (`ChangeText`, Colors.swift note) — extended to all new metrics.
- **VoiceOver:** each metric tile combines label+value into one accessibility element with a spoken sentence, e.g.
  `MetricTile` sets `.accessibilityLabel("Cost per million dollars, 290 dollars, above the fee floor")`. The Live
  Bar is one element: `"MON grid session, 62 percent of volume target, 12 minutes 4 seconds remaining, up 3 dollars
  21 cents, risk elevated. Double-tap to open."` `SkewBar`/`RiskGauge` expose `.accessibilityValue`.
- **Dynamic Type:** all text uses text styles (no fixed sizes except the deliberate rounded-mono readouts, which use
  `.dynamicTypeSize(...DynamicTypeSize.accessibility2)` clamps + `minimumScaleFactor(0.7)`). Live Bar reflows to two
  lines at AX sizes (§4.1); the `Table` collapses to stacked `MMSessionRow`s at AX / compact width. Config sliders
  keep 44 pt hit targets.
- **Light/dark:** all colors are the existing dynamic semantic set (asset-catalog + `Color(light:dark:)`), so both
  themes are automatic; monospaced digits and material backgrounds already adapt. Live Activity ships light+dark
  variants and honors `.widgetRenderingMode`.
- **Reduce Motion:** ring sweeps/pulses become crossfades (§1). **Reduce Transparency:** the bar's `.regularMaterial`
  falls back to a solid `Color(.secondarySystemGroupedBackground)`.
- **Haptics** respect the system; the `Haptics` tick already honors the silent switch.

---

## 8. Data-source map (every metric → source → cadence)

| Metric | Source | Cadence | Dep |
|---|---|---|---|
| mid / mark / live spread | `order-book@id`, `market-state@143` (WS, via worker bridge for market-data) | 2 Hz coalesced | infra/quant |
| unrealized PnL | mark × on-chain position; recompute local + reconcile | 2 Hz / 5–8 s | risk |
| realized PnL, fees (precise) | `account.balance − startBalance`; `mt:24` fill fees | 5–8 s / on fill | quant |
| volume, fills, filled % | `MMSession.volume` (watcher) + `mt:24`; slices | on tick / on fill | quant |
| resting orders, next requote | `openOrders`; requote cadence (≤2 ops/s) | 5–8 s / 1 Hz local | quant |
| inventory, skew | `positions` | 5–8 s | risk |
| margin ratio, liq price, dist-to-liq | `account` + `position` (Multicall) | 5–8 s | risk |
| max-loss drawdown / kill | `totalPnL` vs `stopLossPct×margin` | 2 Hz | risk |
| connection/worker health | `PerplTrading.status`, WS heartbeat, worker `GET /health` | event / 15 s | infra |
| all countdowns/elapsed | local clock | 1 Hz (`TimelineView`) | ux |

Server mode replaces the on-chain polls with a worker push stream and keeps a 30 s reconciliation poll.

---

## 9. External API / data / credentials the user must provide (flagged)

1. **APNs (Apple Push) credentials** for background notifications + Live Activity remote updates: an APNs Auth Key
   `.p8`, its **Key ID**, and the **Team ID**. Without these, background mode degrades to on-device local
   notifications only. **[infra]**
2. **Per-market 24h volume** feed — required for duration auto-compute (§3.7) and participation %. Confirm whether
   `market-state@143` carries a 24h volume field per market; if not, we derive from REST candles
   (`GET /api/v1/market-data/<id>/candles/<res>/<from>-<to>`) — needs the endpoint confirmed live. **[quant/infra]**
3. **Whether Perpl/Monad pays maker rebates / MM-reward / points / airdrop** for this volume (brief §0.2). This
   flips the honest-economics copy from "cost you minimize" to "cost offset by rewards," and adds a "Rewards
   earned (est.)" tile. Need the program terms / an API. **[reco/quant]**
4. **Server executor + session-scoped key custody** design (whether background mode exists at all, and its trust
   model). Everything in §3.15, §4.3 (remote), §5 Scheduled/Campaigns background depends on this. **[arch/infra]**
5. **Does Perpl support sub-accounts?** Decides whether "Account" (§3.3) is a picker or a static row. **[arch]**
6. **RSI / realized-vol inputs** for Signal and DGrid (candles are available; confirm the indicator source/params
   the quant model expects). **[quant]**

---

## 10. Explicit dependencies on other sections

- **[arch]** architecture A/B/C choice drives §3.15 (key consent), §4.3 (remote Live Activity), §5 (scheduled &
  campaigns backgrounding), and the entire "background" story. UX is built to render *either* on-device-only or
  server/hybrid without a redesign — the manager exposes `mode` and swaps polls↔push and the consent step.
- **[quant]** owns `MMSession.levels(mark:)` for the new models (DGrid/RGrid/Blend/Signal), the requote loop
  (cancel/replace/**amend t:7** within ≤2 ops/s), the participation→duration→slice schedule, spread-from-vol, and
  `filledPct`. UX renders whatever these produce (ladder preview, schedule preview, live spread, next-requote).
- **[risk]** owns liq price, margin ratio, distance-to-liq, Max-Loss kill (flatten + cancel), and the numbers in
  the pre-trade card + risk footer. UX surfaces thresholds and fires the kill report state.
- **[reco]** owns the recommended preset + pre-trade analytics numbers (Cost/$1M, est. fills/duration). UX renders
  the banner + card; both degrade gracefully if reco is absent.
- **[infra]** owns the worker endpoints (`/api/mm/session/:id/stream`, `/health`, Live-Activity push), APNs, the
  market-data bridge (already exists at `/api/perpl/ws`), and mt:24 fill history.

## 11. Open questions

- **`filledPct` definition:** decided as *schedule/execution adherence* (distinct from `volumePct`); confirm with
  [quant] this matches the tread.fi column semantics, else collapse to `volumePct`.
- **Live Activity update budget** vs a fast MM session: the 60 s floor + material-event policy (§4.3) is a UX
  guess; [infra] to confirm APNs Live-Activity rate limits and whether high-frequency `.priority` is warranted.
- **Pause semantics:** cancel-and-hold vs. keep-resting-stop-recycling — needs [quant]/[risk] to define what
  "paused" does to inventory; UX assumes "cancel resting orders, keep position, no recycle."
- **Scheduled/Campaign backgrounding** is impossible without the worker; if [arch] picks on-device-only, these tabs
  become "reminders," and the copy must not overpromise.
- **Perpl sub-accounts** (§3.3) — picker vs static row.

## 12. Compliance / honesty guardrails baked into the UI (non-negotiable)

- Cost/$1M is shown **everywhere** volume is shown (bar-adjacent, dashboard tile, every table row, share card),
  colored against the ~$250 fee floor — the user can never see volume without its cost.
- Pre-trade and confirm sheets state **Max Loss in dollars** and that fills come from the **real order book**
  (genuine counterparty + inventory risk). No copy ever implies costless profit or self-matching.
- Spread floors (2.5/6.8 bp) are enforced and explained, so a user can't configure a guaranteed-loss spread.
- On-device mode states plainly that closing the app pauses quoting (only native TP/SL stay armed); server mode
  states plainly that a trade-scoped, auto-expiring, revocable key runs it.
