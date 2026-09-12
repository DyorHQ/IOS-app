# Market-Microstructure Quant — the strategy engine

*DyorHQ Market-Making feature · the quoting/strategy core. Scope: reference-price models, sizing, the
volume↔duration↔participation schedule, the requote loop, the honest profit/cost model, and an optional
Avellaneda-Stoikov core. All math is pure, O(levels), and computable on-device from `PerplFeed` + REST candles,
inside the 120 req/min socket budget.*

Cross-section markers used below: **[arch]** execution location / socket ownership, **[infra]** DyorKit frames +
data plumbing, **[risk]** kill-switch / caps / liquidation, **[reco]** regime→preset defaults, **[ux]** config &
status UI. **[NEEDS-USER]** flags an external API/datum/credential the user must supply or confirm.

---

## 0. What this section owns, and what it reuses

The engine is a set of **pure functions** over live market data that emit the exact `[MMLevel]` ladder the existing
executor already knows how to place. It **extends** `MMStrategy.levels(mark:)` (`ios/DyorHQ/Strategy/MarketMakingStrategy.swift`),
it does not replace it. The two existing branches — `midLevels(mark:)` and `gridLevels(mark:)` — become two of six
reference-price models; the shared helpers (`curveWeights`, `bracket`, `deployed`, `perSide`, the fee floors) are kept
verbatim and reused by all six.

Reused ground truth from the current code (do not change these values):

| Constant / rule | Value | Meaning |
|---|---|---|
| `midFloorBp` | 2.5 bp | half-spread floor = one maker leg fee |
| `gridFloorBp` | 6.8 bp | grid step floor = clears the ~5 bp round-trip + margin |
| `feeRateBp` (MMStatusView) | 5.0 bp | round-trip fee (≈1.5 maker + 1.0 builder, ×2 legs) |
| `deployed` | `capital · leverage` | total notional the ladder may rest |
| `perSide` | `deployed / 2` | notional per side (Mid) |
| bias skew | `bias · 0.2` | ±20% spread skew (matches Arbital "+up to 20% at bias") |
| makerOffset | `max(step/2, 0.00015)` | grid inside-offset so rungs never cross |
| `near()` | rel-diff < 0.0008 (8 bp) | "same price" tolerance for fill/leave detection |

New Swift files this section defines (all in `ios/DyorHQ/Strategy/`, all `Sendable`, no I/O):

- **`MMQuoteEngine.swift`** — `RefModel` enum, `QuoteInputs`, `func levels(_:_:) -> [MMLevel]`, per-model builders,
  `func resetDecision(...) -> Reset`, and the optional AS core.
- **`MMMarketStats.swift`** — `sigma`, `rsi14`, `efficiencyRatio`, `ewmaVol` from `[PerpCandle]` (DyorKit type).
- **`MMSchedule.swift`** — participation presets, `autoDuration`, `childClip`, per-mode spread/cadence/fill map.

`MMStrategy` gains fields (§7). The requote loop extends `MMWatcher`/`MMExecutor` (§5). DyorKit needs two small
**[infra]** additions — a `t:7` Change (amend) frame and real `fl:1` PostOnly wiring (§5.1) — flagged there.

---

## 1. Reference price and shared quote primitives

Every model quotes around a **reference price `r`** and produces levels via one shared kernel. `QuoteInputs` bundles
everything the six models can need; it is filled from `PerplFeed.state` (`PerplLiveState`: `mark, mid, bid, ask,
volume24h`), the L2 `book`, and `MMMarketStats` over REST candles.

```swift
struct QuoteInputs: Sendable {
    var mark: Double            // PerplLiveState.mark  (keeper mark; SL/liq reference)
    var mid: Double             // PerplLiveState.mid   (touch mid; primary quote reference)
    var bestBid: Double         // book.bestBid
    var bestAsk: Double         // book.bestAsk
    var sigmaBar: Double        // stdev(log returns) over one candle bar (fraction)
    var barSec: Double          // candle resolution in seconds (e.g. 60)
    var rsi: Double             // RSI(14), 0…100
    var er: Double              // Kaufman efficiency ratio, 0…1 (trend vs chop)
    var inventory: Double       // signed net position, base units (+long / −short)
    var tRemainingFrac: Double  // (T − t)/T of the session box, 1→0  (AS horizon)
}
```

**Reference choice.** The current code quotes off `mark`. tread.fi's *Mid Price* model quotes off the **touch mid**.
We adopt `r = mid` (fallback `mark` when the book is one-sided or `mid ≤ 0`) for Mid/Grid/RGrid/Blend/Signal, and use
`mark` only for stop-loss / liquidation reference (the keeper triggers on mark). Rationale: quoting off mid keeps us
symmetric around the real book and improves fill symmetry; mark can lag mid intra-second on Perpl.

**Vol over the quote horizon.** From one-bar vol `sigmaBar` (e.g. 1-min), scale to any horizon `h` seconds by the
√-of-time rule:  `σ_h = sigmaBar · sqrt(h / barSec)`. This single quantity drives DGrid's optimal spread, the AS core,
and the honest adverse-selection estimate.

Shared kernel (unchanged math, lifted from `midLevels`/`gridLevels`):

```
weights   = curveWeights(n)              // flat=1; linear=i+1; geometric=2^i
W         = Σ weights
sizeQuote_i (AUSD) = perSide · weights_i / W
size_i (contracts) = sizeQuote_i / price_i
bracket(entry, side) → (tp, sl) = entry·(1 ± tpPct/100), entry·(1 ∓ slPct/100)   // long/short
```

---

## 2. The six reference-price models (exact math)

`RefModel` replaces the current `mode` String; `"mid"`/`"grid"` decode-map for back-compat (§7).

```swift
enum RefModel: String, Codable, CaseIterable { case mid, grid, rgrid, dgrid, blend, signal }
```

### 2.1 Mid Price (+ directional bias) — *unchanged kernel, reference = mid*

This is the existing `midLevels`, with `r = mid` instead of `mark`. For each level `i ∈ 0..<n`, both sides:

```
skew    = bias · 0.2                              // bias ∈ [−1,1]  → skew ∈ [−0.2, 0.2]
bidBp_i = max(2.5, spreadBp·(1 − skew)) + spreadBp·i
askBp_i = max(2.5, spreadBp·(1 + skew)) + spreadBp·i
bid_i   = r · (1 − bidBp_i/10_000)
ask_i   = r · (1 + askBp_i/10_000)
size    = sizeQuote_i / price
```

**Directional bias semantics** (only exposed in Mid, per tread.fi): `bias > 0` (Long) tightens the bid
(`1 − skew`) and widens the ask (`1 + skew`) → fills the buy side more often → accumulates long. `bias < 0` mirrors
to short. `bias = 0` = symmetric. Optionally also skew *size* by `(1 + skew)`/`(1 − skew)` for a stronger tilt
(matches Arbital "margin +up to 20% at higher bias") — keep spread-skew as default, size-skew as an advanced toggle.

- **Profits when:** price oscillates through the ladder in a range; each completed round trip nets full spread
  (`bidBp+askBp ≥ 5 bp`) minus the 5 bp round-trip fee. Highest *fill rate* of any model → best for pure volume.
- **Loses when:** trend. One side fills repeatedly, inventory builds against the move, mark-to-market loss on the
  growing position exceeds spread captured (classic adverse selection).
- **Recenter rule:** requote (amend) when `|mid_now − r_quoted| / r_quoted ≥ recenterPct`, with
  `recenterPct = max(0.5 · innermost half-spread, thresholdPct)`. Default threshold `0.125%`. Also recentre on the
  mode's requote cadence (§4).

### 2.2 Grid — buy-low/sell-high, sideways — *Grid Reset Threshold*

Generalises the existing directional `gridLevels` to the canonical **two-sided** grid anchored at placement price
`r_anchor` (the grid does **not** follow price until it resets). Let `g = max(gridFloorBp, gridStepBp)` bp,
`stepFrac = g/10_000`, `n = gridLevels` rungs per side, `sizeQuote = deployed / (2n)`.

```
buy rung  j = 1..n:  entry = r_anchor · (1 − j·stepFrac)
                     TP    = entry · (1 + stepFrac)          // sell one step up (mean-revert)
                     SL    = entry · (1 − stopLossPct/100)   // optional hard stop
sell rung j = 1..n:  entry = r_anchor · (1 + j·stepFrac)
                     TP    = entry · (1 − stepFrac)          // buy back one step down
size = sizeQuote / entry
```

Per completed rung round-trip: gross = `stepFrac − feeRoundtrip` ≥ `6.8 − 5 = 1.8 bp`. (The `gridFloorBp = 6.8`
floor exists precisely so a rung cycle clears fees with margin.) The single-direction existing grid (`gridLong`)
remains available as a degenerate case (only the buy or only the sell rungs) for a user who wants pure directional
accumulation.

- **Profits when:** sideways / mean-reverting; price wiggles across rungs, harvesting `step − fee` each cycle.
- **Loses when:** strong trend. All buy rungs fill as price falls (or all sells as it rises); the far rung's TP
  never triggers, inventory grows one-sided and underwater → the "stuck order" tread.fi warns about → eventually
  stop-lossed.
- **Grid Reset Threshold `θ_grid` ∈ {0.05, 0.125, 0.25, 0.5, 1}%:** re-centre when
  `|mid_now − r_anchor| / r_anchor ≥ θ_grid`. Reset = cancel unfilled rungs, set `r_anchor = mid_now`, re-place;
  inventory is carried (its native TP/SL rides). **Anti-thrash guard:** require `θ_grid ≥ n·stepFrac` (the grid's
  own half-span) or the grid resets before it can fill, churning fees. E.g. `n=3, step=15 bp → span 45 bp = 0.45%`
  → pick `θ_grid = 0.5%`. **[reco]** default `θ_grid` per market from `n·step`.

### 2.3 RGrid — reverse grid, trending/volatile — *TP Reset Threshold*

Canonical "reverse grid / buy-high-sell-low" means momentum entries (buy-stops above, sell-stops below). **Perpl's
only trigger primitive is a reduce-only Close** (brief §2) — there is **no native stop-*entry***. **[NEEDS-USER /
open API question]** confirm whether Perpl supports open-trigger orders; if not (assumed), RGrid is implemented
maker-only with a **trailing take-profit**, which preserves RGrid's economic character (let winners run in a trend)
and is exactly why it uses the **TP Reset Threshold** rather than the Grid Reset Threshold.

Directional (trend side = `gridLong`). Entries are the same non-crossing maker rungs as Grid, but the exit is a
single **wide, trailing** TP instead of a tight per-rung TP:

```
tpDistFrac = tpResetK · stepFrac          // tpResetK ≥ 3 (wide; "let it run"); default 4
long RGrid  buy rung j: entry = r_anchor·(1 − makerOffset − j·stepFrac)
                        TP    = anchorTP     (shared, trailing — see below)
                        SL    = entry·(1 − stopLossPct/100)
short RGrid sell rung j: entry = r_anchor·(1 + makerOffset + j·stepFrac)
                        TP    = anchorTP
anchorTP (long)  = r_anchor·(1 + tpDistFrac)      // initial
```

**TP Reset Threshold `θ_tp` ∈ {0.05, 0.125, 0.25, 0.5, 1}%:** each time the mid advances by `θ_tp` in the trend
direction beyond the last TP anchor, **ratchet the TP by θ_tp** (trail up for long, down for short) and re-issue the
reduce-only Close triggers at the new level; **never ratchet backwards**. This is a discrete trailing stop-profit.

- **Profits when:** sustained trend / high volatility — the trailing TP rides the move far past `step`, capturing
  many multiples of the fee.
- **Loses when:** chop / range — entries fill, price reverses before `θ_tp` is reached, the SL takes the loss;
  repeated whipsaw. (The exact mirror of Grid.)

### 2.4 DGrid — dynamic — *vol/trend switch + historical-vol-optimal spread*

DGrid picks Grid vs RGrid from a **trend-vs-range forecast** and sets the spread/step from **historical vol**.

**Switch signal — Kaufman Efficiency Ratio** over the last `N` closes (default `N = 20`, 1-min):
```
ER = |c_t − c_{t−N}| / Σ_{k=t−N+1..t} |c_k − c_{k−1}|      ∈ [0,1]
```
ER→1 = clean trend (net move ≈ path length) → **RGrid**; ER→0 = choppy/range → **Grid**. Threshold with hysteresis
to avoid flip-flop: switch to RGrid when `ER ≥ 0.40`, back to Grid when `ER ≤ 0.25`; hold otherwise. (An EWMA-vol
ratio `σ_short/σ_long > 1.3` may corroborate, but ER alone is the primary switch because it *directly* measures the
Grid-vs-RGrid suitability axis.)

**Historical-vol-optimal spread/step.** Set the half-spread to the expected mid move over the quote's expected
lifetime plus the fee floor:
```
h              = expected time-to-refresh (mode cadence Δt, §4)
σ_h            = sigmaBar · sqrt(h / barSec)
halfSpread*bp  = max(midFloorBp, k · σ_h · 10_000)      // k ≈ 1.0 (see AS §6 for the principled k)
step*bp        = max(gridFloorBp, 2 · halfSpread*bp)
```
Worked number: 1-min `sigmaBar = 0.0008` (8 bp), refresh `h = 20 s`, `barSec = 60` →
`σ_h = 8·sqrt(20/60) = 4.6 bp` → `halfSpread* = 4.6 bp`, `step* = 9.2 bp`. In calm markets DGrid tightens toward the
floors (more fills, more volume); in volatile markets it widens (fewer, safer, larger-capture rungs).

- **Profits when:** the forecast is right — Grid in the ranges it detects, RGrid in the trends it detects.
- **Loses when:** regime flips faster than the hysteresis band + reset cadence can follow (whipsaw at the switch).
- **Reset:** uses the reset rule of whichever mode is currently active (`θ_grid` in Grid state, `θ_tp` in RGrid
  state). On a switch, cancel & re-place with the new geometry (a cancel/replace, not an amend — geometry changes).

### 2.5 Blend — Mid + Grid superposition

Deploy a fraction `β ∈ [0,1]` (default 0.5) of `deployed` as a **Mid** ladder (tight, near-touch → maximises fill
rate/volume) and `1−β` as a **Grid** ladder (deeper mean-reversion rungs with TP → captures larger swings). Build
both with their own kernels using scaled `perSide`/`deployed`, then **merge**: where a Mid level and a Grid rung
collide within `near()` (8 bp), sum sizes and cap the merged size at the per-market max-lot / the level's original
budget. Reset = the **tighter** of the Mid recenter and the Grid `θ_grid` trigger.

- **Profits when:** mixed regimes — the Mid layer keeps volume/fee-farm flowing near touch while the Grid layer
  harvests the occasional larger swing.
- **Loses when:** trend (both layers are mean-reverting) — same failure mode as Mid+Grid, partially hedged by
  smaller per-layer size.

### 2.6 Signal — RSI-gated / skewed

Compute **RSI(14)** (Wilder) from candle closes:
```
avgGain = Wilder-smoothed mean of up-moves over 14;  avgLoss likewise
RS  = avgGain / avgLoss ;   RSI = 100 − 100/(1 + RS)
```
Derive a bias from RSI and feed it into the **same skew machinery as Mid** (so Signal reuses the Mid kernel):
```
signalBias = clamp((50 − RSI)/50 · gain, −1, 1)      // gain default 1.0
skew       = signalBias · 0.2
```
RSI 70 → `signalBias = −0.4` → short skew (fade overbought). RSI 30 → `+0.4` → long skew (fade oversold).
**Hard gate:** if `RSI ≥ gateHigh (75)` drop the *buy* side (size 0 — don't add long into overbought); if
`RSI ≤ gateLow (25)` drop the *sell* side. 25–75 → two-sided.

- **Profits when:** RSI mean-reverts (extremes fade) in a range.
- **Loses when:** trend keeps RSI pinned (>70 while price climbs) — you're flat/short and either miss it or your
  remaining sells get run over.
- **Reset:** recompute on each candle close; requote when `|signalBias_new − signalBias_quoted| ≥ 0.2`, else on the
  normal cadence.

### 2.7 Model → threshold → regime summary

| Model | Quotes | Best regime | Reset knob | Profit driver | Loses in |
|---|---|---|---|---|---|
| Mid | both sides @ mid | any (volume-max) | recenter (drift) | spread capture / fills | trend |
| Grid | buy-low / sell-high | sideways | **Grid Reset** θ_grid | `step − fee` per cycle | trend (stuck rung) |
| RGrid | trend-side maker + trailing TP | trend / volatile | **TP Reset** θ_tp | winner rides | chop (whipsaw) |
| DGrid | Grid⇄RGrid by ER | adapts | active mode's | right forecast + vol-optimal spread | fast regime flip |
| Blend | Mid ⊕ Grid | mixed | tighter of the two | volume + swings | trend |
| Signal | Mid kernel, RSI skew/gate | ranging extremes | RSI-change | fade extremes | pinned RSI trend |

---

## 3. Volume ↔ Duration ↔ Participation

Inputs: Margin `M`, leverage `L`, Volume target `V_target` ($), market 24h volume `V24` ($), participation `p`.

**Default volume heuristic** (tread.fi "≈ margin×20"): `V_target = 20 · M`.

**Participation presets** (calibrated so Aggressive/Normal/Passive give ~10/20/100-min boxes, matching tread.fi's
observed 1:2:10 duration ratio):

| Preset | `p` (share of market volume) | rel. duration |
|---|---|---|
| Aggressive | 10% (0.10) | 1× |
| Normal | 5% (0.05) | 2× |
| Passive | 1% (0.01) | 10× |

**Participation identity.** Your volume should be `p` of the market's volume over the window `D` minutes. Market
trades `V24 · D/1440` over `D`. Therefore
```
p = V_target / (V24 · D / 1440)
```

**Auto-Duration** (solve for `D`, clamp to tread.fi's 10–1000 range):
```
D = clamp( round( 1440 · V_target / (p · V24) ), 10, 1000 )   [minutes]
```
Sanity check against tread.fi: `V_target = $15,000`, `p = 0.10`, market `V24 ≈ $21.6M/day`
→ `D = 1440·15000/(0.10·21.6e6) = 10 min` (Aggressive). Same inputs at `p = 0.05 → 20 min` (Normal),
`p = 0.01 → 100 min` (Passive). ✔ The model reproduces tread.fi's ladder exactly. **[NEEDS-USER]** confirm whether
`market-state`'s `dv` (→ `PerplLiveState.volume24h`) is **base** or **quote/USD** volume; if base, `V24_USD =
volume24h · mark`. The formula above needs `V24` in **USD**.

**Per-interval (TWAP) child sizing.** Split `D` into `K = ⌈ D·60 / Δt ⌉` requote intervals (`Δt` = mode cadence,
§4). Volume per interval `v = V_target / K`. Each interval must *generate* `v` of volume = a buy fill of `v/2`
notional + a sell fill of `v/2` (a round trip of `v/2` makes `v` volume). Because resting maker orders only fill
when price reaches them, the **targeted clip must be inflated by the inverse fill rate** to actually hit the target:
```
clipNotional_perSide = (v/2) / fillRate(mode)          // AUSD
clipSize (contracts) = clipNotional_perSide / price
```
Cap `clipNotional_perSide ≤ perSide` (never exceed the deployed budget). If the required clip exceeds the budget,
the honest UI must say *"can't hit V_target in D at this margin — raise margin, raise participation (shorter D,
tighter quotes), or lower V_target."* This is the on-device analogue of tread.fi's insufficient-margin warning.

**Aggressive / Normal / Passive → spread · cadence · fill:**

| Mode | half-spread (bp) | cadence `Δt` | expected fillRate | adverse `a` | note |
|---|---|---|---|---|---|
| Aggressive | `max(2.5, 1·σ_Δt)` (≈ near touch) | 5–10 s | 0.6–0.9 | high | hits volume fast; usually pays |
| Normal | `max(6, 2·σ_Δt)` | 15–20 s | 0.3–0.5 | medium | balanced |
| Passive | `max(12, 3·σ_Δt)` | 30–60 s | 0.1–0.2 | low | cheapest/$1M; may miss target |

`fillRate` is *estimated* here for the pre-trade panel and refined live from observed fills/requote (§5.4). These are
the tread.fi "wider = safer/less reward, tighter = aggressive/riskier" and Arbital "refresh speed + spread width"
mappings made numeric.

---

## 4. The requote / refresh loop

The v1 `MMWatcher` only **recycles from flat** (re-arms after two consecutive fully-flat reads). The MM loop adds
**continuous requoting** while capping inventory, extending — not discarding — that flat-recycle safety and its
critical "a failed read must never be treated as flat" rule.

### 4.1 [infra] Two DyorKit prerequisites (my loop depends on these)

1. **`fl:1` PostOnly is not currently wired.** `PerplOrders.entry` sends `fl: ioc ? 4 : 0` — a maker limit ships as
   **GTC (0), not PostOnly (1)**, despite `OrderInput.postOnly`. A maker MM must never cross. Add a `flags: Int`
   (or `postOnly: Bool`) to `PerplOrderFrame`/`entry` and emit `fl: 1` for resting levels. **Without this the ladder
   can take, paying taker fees and inverting the economics.** (Flag to [infra]; small change.)
2. **`t:7` Change (amend) frame is missing.** `PerpOrderType.change = 6` exists but there is no builder. Add:
   ```swift
   // PerplOrders
   static func change(perpId: Int, orderId: Int, newPrice: Double, newSize: Double,
                      market: PerpMarket, accountId: Int) -> PerplOrderFrame  // t:7, oid set, lb:0, fl:1
   // PerplTrading
   func amend(perpId:, orderId:, newPrice:, newSize:, env:) async throws -> PerplOrderAck
   ```
   Amend is **one op**; cancel+replace is **two** (plus re-arming the linked TP/SL = up to two more). Amend is the
   difference between fitting and busting the 120/min budget (§4.3).

### 4.2 amend vs cancel/replace vs leave

For each currently-resting level, compute its new target `(price*, size*)`:

- **Leave** if `|price_now − price*| / price_now < ε` **and** `|size_now − size*|/size_now < ε_s`, with
  `ε = max(0.1 · halfSpreadFrac, 0.0002)` (2 bp) and `ε_s = 0.1`. Saves ops; also avoids losing book priority. (2 bp
  sits just under the 8 bp `near()` fill tolerance, so a leave can't be mistaken for a fill.)
- **Amend (t:7)** when only price and/or size changed, the order is **still on the correct maker side of the mark**
  (amending across the mark would cross — forbidden), and it hasn't filled. Cheapest requote.
- **Cancel + replace** when: the side flips; a partial fill needs a fresh linked bracket; geometry changes
  (DGrid switch, threshold reset, model change); or an amend is rejected. The native TP/SL of a *filled* entry is
  owned by the keeper and rides — never try to amend that; manage it via the reduce-only Close re-issue path (RGrid
  trailing, §2.3).

### 4.3 Rate-budget arithmetic (120 req/min, one socket)

Budget = 120/min − 2 (keep-alive `mt:1` @30 s) = **118 order-ops/min ≈ ~2/s**, shared across every level and market.

Per requote of a ladder with `Ln` levels:
```
amend-only            : Ln ops
cancel + replace      : 2·Ln ops
cancel + replace + re-arm TP&SL : 4·Ln ops
```
Requotes/min `= 60/Δt`. So ops/min `= (60/Δt) · opsPerLevel · Ln`. Examples (must stay ≤ 118):

| Ladder | Δt | amend | c+r | c+r+brackets |
|---|---|---|---|---|
| Mid n=2 (Ln=4) | 5 s | 48 | 96 | 192 ✗ |
| Mid n=2 (Ln=4) | 10 s | 24 | 48 | 96 |
| Grid 2×3 (Ln=6) | 15 s | 24 | 48 | 96 |
| Grid 2×3 (Ln=6) | 5 s | 72 | 144 ✗ | ✗ |

**Conclusion:** aggressive cadence (Δt ≤ 5–10 s) is only feasible with **amend**; cancel/replace forces Δt ≥ 15 s or
fewer levels; re-arming brackets every requote is never affordable at speed — so **don't**: place the entry
post-only and let the keeper hold the TP/SL; only re-issue triggers when a level actually fills or a reset moves it.
The loop must also **coalesce**: batch all amends for a tick, and skip the tick entirely (leave everything resting)
when nothing breached `ε` — a calm market spends ~0 ops.

### 4.4 Two-sided convergence with an inventory cap  [risk]

Track signed inventory `I` (base units) from positions (live, via trading-WS `mt:26/27` — see §8). Two controls:

1. **Skew toward flat (soft):** shift the reference by `−γ·I` before building levels (this *is* the AS reservation
   price, §6): the side that would grow `|I|` is pushed out (fills less), the reducing side pulled in (fills more).
   Keeps buy and sell volume converging over the run without ever self-matching.
2. **One-sided cutoff (hard):** when `|I| ≥ I_max` (`I_max = deployed · capFrac / price`, `capFrac ≈ 0.6` **[risk]
   owns the value**), **stop quoting the side that increases `|I|`**; quote only the reducing side until `|I|` falls
   back under `capFrac/2 · …` (hysteresis). Mirrors Arbital "stop one-sided trading when limits hit; total buy/sell
   volume converges over the run." Because we always eventually flatten, cumulative buy ≈ sell volume → genuine
   two-sided liquidity, not directional punting.

### 4.5 Loop shape (extends MMWatcher)

Keep `MMWatcher`'s 20 s on-chain reconciliation tick and its flat-recycle safety, but add a **fast requote tick**
driven off the **live `PerplFeed`** (not on-chain reads, which can be ~24 h stale on public RPC — brief §2):

```
on PerplFeed change (throttled to Δt):
  q = QuoteInputs(from feed + cached MMMarketStats + live inventory)
  if resetDecision(strategy, q).shouldReset { cancelReplaceAll(newGeometry) ; return }
  target = MMQuoteEngine.levels(strategy, q)          // pure
  for each resting level: leave / amend / cancel-replace  (§4.2, coalesced, ≤ budget)
  place any missing levels (post-only)
20 s slow tick (existing): reconcile on-chain, detect fills the fast tick missed, flat-recycle, self-heal socket
```

`resetDecision` returns `.none / .recenter(mid) / .switch(RefModel) / .trailTP(level)` per §2. **[arch]** owns where
this loop physically runs (device-foreground vs worker); the engine functions are location-agnostic and identical in
both. **[arch/ux]** the fast tick only runs while the trading socket is live; iOS backgrounding stops it — the
native TP/SL keeper triggers are the safety net (already true in v1).

---

## 5. Profit / cost model (honest economics)

Let all rates be fractions: round-trip fee `F = 0.0005` (5 bp), full spread `s`, adverse-selection cost `a`,
completion probability `ρ` (fraction of round trips that close at the intended spread rather than being run over).

**Volume ↔ notional.** A round trip of notional `q` makes `2q` volume. Total volume `V = 2·Σq`, so
`Σq = V/2`.

**Fees.** `Fees = F · Σq = 0.0005 · V/2 = 0.00025·V`  →  **Cost_fees per $1M volume = $250.** (Matches Arbital
$150–250 and tread.fi.) This floor is unavoidable and independent of strategy.

**Expected PnL per round trip** of notional `q`:
```
E[pnl] = q·( ρ·s − (1−ρ)·a − F )
```
**Expected PnL per $1M volume** (`q = V/2` ⇒ per $1M, notional = $500,000):
```
E[PnL]/$1M = 500_000 · ( ρ·s − (1−ρ)·a − F )
Cost/$1M   = − E[PnL]/$1M = 500_000 · ( F + (1−ρ)·a − ρ·s )
```

**Break-even spread** (`E[pnl] = 0`):
```
s* = [ (1−ρ)·a + F ] / ρ
```
Worked: `F=5 bp, ρ=0.6, a=8 bp` → `s* = (0.4·8 + 5)/0.6 = 8.2/0.6 = 13.67 bp` full spread → **half ≈ 6.8 bp** —
i.e. the existing `gridFloorBp = 6.8` is exactly break-even under these typical params. Below it you *pay* for
volume; above it you can profit **if the market ranges** (ρ high, a low).

**How each knob moves Cost/$1M:**

| Change | ρ | a | s | Cost/$1M |
|---|---|---|---|---|
| Aggressive / tighter spread | ↑ (fills both sides) | ↑ (run over more) | ↓ | ↑ (usually pays; near $250+adverse) |
| Passive / wider spread | ↓ | ↓ | ↑ | ↓ (cheapest; may profit but risks missing V_target) |
| Higher participation `p` | — (shorter D, tighter quotes) | ↑ | ↓ | ↑ |
| Ranging market (Grid fits) | ↑ | ↓ | — | ↓ (can go **negative** = profit) |
| Trending market | ↓ | ↑↑ | — | ↑↑ (always loses; see below) |

Illustrative Cost/$1M (F=5 bp):

| Regime / mode | ρ | a (bp) | s (bp) | Cost/$1M |
|---|---|---|---|---|
| Ranging, Passive Grid | 0.8 | 4 | 16 | `5e5·(0.0005 + 0.2·0.0004 − 0.8·0.0016)` = **−$240** (profit) |
| Ranging, Normal | 0.6 | 6 | 12 | `5e5·(0.0005 + 0.4·0.0006 − 0.6·0.0012)` = **+$10** |
| Trending, Aggressive Mid | 0.3 | 15 | 6 | `5e5·(0.0005 + 0.7·0.0015 − 0.3·0.0006)` = **+$685** (bleeds) |

**Be honest (must surface in UI):** to *guarantee* hitting a large volume target inside a short box you must quote
tight/aggressively, which pushes ρ·s below (1−ρ)·a + F → **you will most likely pay** (Cost/$1M > 0, i.e. > the $250
fee floor once adverse selection is added). Net profit only happens when spread capture in a **ranging** market
beats fees + adverse selection — never guaranteed, and **trending markets always lose**. The only reliable offset is
**maker rebates / MM-reward / points programs**, which must be confirmed for Perpl/Monad (**[NEEDS-USER]**, §9).
Self-matching to fake volume is out of scope and on Perpl just burns your own fees (brief §0).

---

## 6. Optional advanced core — Avellaneda-Stoikov reservation price

A single principled engine that subsumes the inventory skew (§4.4) and the vol-optimal spread (§2.4). Offer it as a
**"Pro" toggle** that DGrid can drive.

**Reservation price** (skews the reference toward flattening inventory):
```
r_res = mid − q · γ · σ² · (T − t)
```
`q` = signed inventory (normalise to units of `deployed/price` so γ is dimensionless), `γ` = risk aversion
(default 0.1; higher = flatten harder), `σ` = per-second vol (`sigmaBar/√barSec`), `(T−t)` = seconds left in the
session box (`tRemainingFrac · D·60`).

**Optimal half-spread:**
```
δ = ½·γ·σ²·(T−t) + (1/γ)·ln(1 + γ/κ)
bid = r_res − δ ,  ask = r_res + δ
```
`κ` = order-flow intensity (fills per unit distance), calibrated from the trade tape: fit `λ(δ) = A·e^{−κ·δ}` to
observed fill distances over a rolling window. The first term is the inventory/vol premium; the second is the
fee/liquidity premium (this is the principled source of DGrid's `k`).

**Is it worth it on Perpl's rate/latency budget?**
- **Adopt** the *reservation-price skew* (`− q·γ·σ²·(T−t)`): near-zero cost, and it *is* the inventory-convergence
  control the feature needs anyway. High value.
- **Adopt** the *vol term* of δ (already DGrid's optimal spread). Good value.
- **Skip / defer** full **κ-calibrated GLFT intensity optimisation**: κ needs a dense, low-latency fill history and
  frequent requoting to exploit; with on-chain fills landing in seconds and a **~2 ops/s** ceiling, the marginal
  δ-tuning it buys is dominated by fee + adverse-selection noise. Ship AS-lite (reservation skew + vol spread) as
  the DGrid "Pro" core; leave κ-GLFT as a documented future upgrade if the user provides a fills dataset for
  offline calibration (**[NEEDS-USER]**, optional).

All AS quantities are computable on-device from `PerplFeed` + `MMMarketStats`; no server math required.

---

## 7. MMStrategy changes  [ux/arch consume these]

Extend the struct (Codable; keep back-compat by mapping the old `mode` on decode):

```swift
// replace `mode: String` with:
var refModel: String            // RefModel.rawValue; decode "mid"/"grid" from legacy `mode`
// schedule
var volumeTarget: Double        // $, default 20·capital
var participation: String       // "aggressive" | "normal" | "passive"
var durationMin: Int            // auto-computed; user-editable 10…1000
var startedAt / endsAt: Int     // box; endsAt = startedAt + durationMin·60  [risk kill at endsAt]
// model knobs
var gridResetPct: Double        // θ_grid ∈ {0.05,0.125,0.25,0.5,1}
var tpResetPct: Double          // θ_tp   (RGrid)
var blendWeight: Double         // β, Blend
var rsiGate: Bool ; var rsiPeriod: Int   // Signal (default 14)
var proAS: Bool ; var gamma: Double      // AS-lite toggle + risk aversion
// runtime caches (for the fast tick / status)
var anchorPrice: Double         // grid/RGrid r_anchor
var tpAnchor: Double            // RGrid trailing TP level
var activeSubModel: String      // DGrid's current Grid/RGrid
var requoteCount: Int           // for rate-budget display
```

Legacy migration: on decode, if `mode == "mid"` → `refModel = "mid"`; `"grid"` → `"grid"`; default the new fields
(`participation = "normal"`, `volumeTarget = 20·capital`, thresholds to per-model defaults). Existing persisted
strategies keep running.

---

## 8. Data plumbing (on-device, live) — dependencies

| Datum | Source | Freshness | Note |
|---|---|---|---|
| `mid, mark, bestBid/Ask` | `PerplFeed.state` / `.book` (market-data WS) | live | quote reference |
| `V24` (24h volume) | `PerplLiveState.volume24h` (`dv`) | live | **[NEEDS-USER]** base vs USD scaling |
| candles → σ, RSI, ER | REST `GET /api/v1/market-data/<id>/candles/<res>/<from>-<to>` → `[PerpCandle]` | poll on candle close | 1-min default; cache; ~1 req/min |
| inventory `I`, fills | **[infra]** trading-WS `mt:24` (fills) + `mt:26/27` (position ids) | live | **do not** use on-chain `openOrders`/`positions` for the fast tick — public RPC can be ~24 h stale (brief §2); those stay for the 20 s reconcile only |
| resting order ids (for amend/cancel) | trading-WS order state | live | **[infra]** the client currently reads orders on-chain; the fast requote needs a live WS order map |

**[infra] gap to flag:** `PerplTradeClient` today surfaces only `mt:19/21/3` (account/ack). The requote loop needs
**`mt:24` fill events, `mt:26/27` position ids, and a live resting-order map** exposed on the client so the loop can
detect fills and target amends without on-chain reads. This is the single biggest infra dependency; without it the
loop falls back to the (possibly stale) 20 s on-chain path and cannot requote tightly.

---

## 9. UI (concrete additions to MarketMakingView / MMStatusView)  [ux owns layout]

**Config (`MarketMakingView`)** — replace the 2-way Mode segmented with:
- **Reference Price** picker: Mid / Grid / RGrid / DGrid / Blend / Signal (menu; footer explains regime fit from
  the table in §2.7).
- **Directional Bias** slider — *shown only when refModel == mid* (existing control; move under Mid).
- **Volume** field ($) — default `20·capital`, live-editable.
- **Participation** segmented: Aggressive / Normal / Passive — each showing its `p%` and the resulting **auto
  Duration** (`D` from §3), e.g. "Normal · 5% · ~20 min". Duration is also editable (10–1000); editing it back-solves
  `p`.
- **Threshold** segmented `0.05 / 0.125 / 0.25 / 0.5 / 1%` — labelled **Grid Reset** for Grid/DGrid-grid, **TP
  Reset** for RGrid; hidden for Mid/Signal.
- **Spread** slider (bps) — footer "wider = safer / less reward; tighter = more fills / more risk" (tread.fi copy).
- **Blend weight** slider (β) — Blend only. **RSI period + gates** — Signal, advanced disclosure. **Pro (AS)**
  toggle + γ — advanced.
- **Pre-Trade Analytics** card (compute from §3/§5 at preview time): **Available Margin**, **Max Loss**
  (`stopLossPct·capital` — [risk]), **Est. Duration**, **Est. fills** (`K·fillRate`), **Est. Volume**, **Cost/$1M**
  (with the honest ρ/a assumptions shown), **Break-even spread `s*`**, **Liquidation price** ([risk]). Reuse the
  existing insufficient-margin guard pattern; add a "can't hit target in D" warning (§3).

**Status (`MMStatusView`)** — add to the existing Session PnL / Volume / Fees rows:
- **Cost/$1M (live)** = `(fees − realizedSpreadPnL)/(volume/1e6)`; **Filled %** = `volume / V_target`;
  **Participation (actual)** vs target; **Inventory gauge** (`I` vs `I_max`, one-sided-cutoff indicator);
  **Time left** in the box; **Requotes / rate-budget used** (`requoteCount`, ops/min vs 118). Keep Stop & Flatten.

---

## 10. Dependencies, open questions, external needs

**Depends on other sections:**
- **[arch]** execution location (device-foreground vs worker) and single-socket ownership; the fast-tick lifecycle
  vs iOS backgrounding. Engine functions are identical in both locations.
- **[infra]** the two DyorKit changes (§4.1: `fl:1` PostOnly, `t:7` Change/amend) and the live WS fill/position/order
  feed (§8). Hard blockers for tight requoting.
- **[risk]** `I_max`/`capFrac`, Max-Loss real-time kill (`stopLossPct·capital`), liquidation price, per-market
  leverage cap (already clamped in `MMExecutor.place` via `1/initMarginFraction`), session end-time flatten.
- **[reco]** default refModel + threshold + participation per market regime, fed by my ER/σ/RSI outputs.
- **[ux]** lays out the controls/analytics/status fields I specify in §9.

**Open questions:**
- RGrid semantics: confirm against tread.fi live behaviour that "buy-high/sell-low" is the trailing-TP maker
  implementation (§2.3) given Perpl has no stop-entry primitive.
- Exact ρ/a to seed Cost/$1M pre-trade (I use ρ=0.6, a=8 bp as honest defaults; calibrate from early fills live).

**[NEEDS-USER] external API / data / credentials:**
1. **Perpl/Monad maker-rebate / MM-reward / points / airdrop program** — does it exist and at what rate? This is the
   only reliable profit offset; it materially changes Cost/$1M and whether any mode can be net-positive. (brief §0.)
2. **`market-state` `dv` scaling** — is `volume24h` in **base** or **quote/USD** units? Needed to make `V24` USD for
   the auto-duration formula (§3).
3. **REST candle endpoint** — confirm available resolutions (need ≥ 1-min; 1-s helps σ/ER) and its rate limit, so
   `MMMarketStats` polling stays inside budget.
4. *(optional, AS-Pro)* a **historical fills dataset** for offline κ (GLFT) calibration — only if the κ engine is
   pursued beyond AS-lite (§6).
