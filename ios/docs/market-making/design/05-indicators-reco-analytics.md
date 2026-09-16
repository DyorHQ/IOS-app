# DyorHQ Market-Making — Section: Indicators & Financial-Recommendation Layer + Analytics

Author: quant/analytics specialist. This section designs the **brains**: the on-device indicator library, the
pre-trade analytics engine, the recommendation ("financial recommendation layer") engine, and post-session TCA.
It is decision-support only (see §0.2). It produces *signals and estimates*; the **executor loop, requote pacing,
socket/rate budgeting, and the hard kill-switch are owned by the arch/risk sections** — every hand-off is marked
`→DEP(section)`.

Everything here is grounded in verified code: `DyorKit/Services/Perpl/PerplService.swift` (candles REST, fills),
`PerplFeed.swift` (book/trades/market-state WS), `PerplModels.swift` (`PerpMarket`, `PerpPosition`), and the
existing `ios/DyorHQ/Strategy/*` (`MMStrategy`, `MMStore`, `MMWatcher`, `MMStatusView`).

---

## 0. Frame, ownership, compliance

### 0.1 Honest-economics constants (single source of truth — put in `DyorKit/Services/Quant/MMEcon.swift`)
```
feeMakerBp     = 1.5     // Perpl maker, per leg
feeBuilderBp   = 1.0     // DyorHQ builder code, per leg
feePerLegBp    = 2.5     // = maker + builder, charged on EACH filled leg
roundTripBp    = 5.0     // = 2 legs; informational only
rebateBp       = 0.0     // ⚠ UNKNOWN — see §6, must be user-confirmed; default 0 (assume none)
```
**Cost/$1M identity (the headline metric).** Volume `V` = Σ notional of *every* filled leg. Gross fees on that
volume are `feePerLegBp/10_000 · V`. Therefore the gross-fee floor is:
```
CostPer1M_grossFloor = feePerLegBp · 100 = 2.5 · 100 = $250 / $1M       (derivation: (2.5/10_000)·1e6)
```
Net economic cost is the headline: `CostPer1M = −(realizedNetPnL) / V · 1e6`. Positive = it cost you; negative =
you were paid to make volume. This equals `+250` when there is zero spread capture and zero rebate, and drops as
spread capture / rebates rise.

> **⚠ Concrete correction to existing code (hand-off to arch).** `MMStatusView.feeRateBp = 5.0` is applied to
> `strategy.volume`, and `MMWatcher` only increments `volume` on *entry* fills (TP/SL closes fire via the Perpl
> keeper and are never counted). So today: volume is ~½ true (entry-only) × a 5 bp round-trip rate ≈ the right
> number *by accident*, and it breaks the moment recycling or one-sided fills change the entry/close ratio.
> **Standardize:** count **every leg** (entry + keeper close) from the authenticated fills feed
> `PerplService.fills` (`/v1/trading/fills`), and charge `feePerLegBp` per leg. This is the ground truth for
> Volume, Filled %, Net Fees and Cost/$1M. `→DEP(arch)`: executor's realized-volume counter should read the fills
> feed, not the resting-order diff.

### 0.2 Compliance framing (must hold in every output string and every UI surface)
- The recommendation engine emits **operational parameters for a volume-generation session under the user's own
  stated constraints** — never "advice", never "you will profit", never a price prediction.
- Every `Recommendation` carries a fixed `disclaimer` (§3.5) and is labelled "Suggested configuration —
  decision-support, not investment advice." The user always confirms with biometrics before anything is placed
  (existing confirm flow in `MarketMakingView`).
- No personalized investment advice: outputs are deterministic functions of public market data + user inputs, with
  assumptions and confidence shown. This is consistent with the app being self-custodial and the brief's
  compliance line.

---

## 1. Indicator Library (on-device, from Perpl candles + WS)

### 1.1 Files & types (new, in DyorKit so it is pure + unit-testable and portable to the worker)
```
DyorKit/Sources/DyorKit/Services/Quant/Indicators.swift      // pure stateless funcs over [PerpCandle]/OrderBook
DyorKit/Sources/DyorKit/Services/Quant/IndicatorEngine.swift // @Observable @MainActor: fetch + subscribe + publish
DyorKit/Sources/DyorKit/Services/Quant/QuantModels.swift     // IndicatorSnapshot, Regime, VolStats, etc.
```
`Indicators.swift` is **pure** (`[Double] → Double/[Double]`) so the identical math runs client-side and, for the
server-executor architecture, inside the Cloudflare `worker/`. `→DEP(arch)`.

```swift
public struct IndicatorSnapshot: Sendable, Hashable {
    // candle-derived (recomputed on each closed candle, ~1/min)
    public let rsi14: Double            // 0…100
    public let sigmaRet1m: Double       // per-1min close-to-close realized vol (return units), e.g. 0.0005 = 5bp
    public let sigmaEwma1m: Double      // EWMA(λ=0.97) per-1min vol
    public let volForecast1m: Double    // one-step-ahead vol forecast (return units, per 1min)
    public let atr14: Double            // in price units
    public let atrPct: Double           // atr14 / mark
    public let efficiencyRatio: Double  // 0…1 (Kaufman ER)
    public let adx14: Double            // 0…100
    public let regime: Regime
    public let regimeConfidence: Double // 0…1
    public let volZScore: Double        // (volForecast − mean)/std over trailing window → DGrid switch
    // book/tape-derived (recomputed on book delta, throttled ~2/s)
    public let obImbalance: Double      // −1…+1  (+ = bid-heavy)
    public let microprice: Double       // size-weighted fair value (see 1.7)
    public let weightedMid: Double
    // context
    public let volume24hUsd: Double     // for participation → duration
    public let mark: Double
    public let asOf: Date
}

public enum Regime: String, Sendable, Codable {
    case quiet          // low vol, low ER → tight Grid works, thin edge
    case ranging        // low ER, moderate vol → Grid sweet spot
    case trendingUp
    case trendingDown
    case volatileChop   // high vol, low ER → widen / DGrid
}
```

### 1.2 Data sources & cadence (respect the connection budget)
| Indicator group | Source | Perpl frame | Cadence | Cost |
|---|---|---|---|---|
| RSI, realized/EWMA vol, vol-forecast, ATR, ADX, ER, regime | 1-min candles | REST `PerplService.candles(marketId, resolution:60, from:now−4h, to:now, priceDecimals)` for warmup (240 candles < 1024 cap); then roll with WS `candles@<id>*60` (mt 11/12) | recompute on each candle close (~1/min) | O(N≤240), <1 ms; 1 REST call on open, then WS |
| Order-book imbalance, microprice, weighted mid | live book | WS `order-book@<id>` (mt 15/16) — **reuse the existing `PerplFeed`**, do not open a new socket | on book delta, throttle to ≤2/s | O(40) |
| Realized micro-vol cross-check, markout capture | trade tape | WS `trades@<id>` (mt 17/18) via `PerplFeed.trades` | streaming | negligible |
| 24h volume, mark/mid/bid/ask | market state | WS `market-state@143` (mt 9) `PerplFeed.state.volume24h`; fallback `MarketContext.volume24h` from `PerplService.context()` | streaming; context fetch on open | negligible |

**Socket budget:** the indicator engine uses **only the unauthenticated market-data WS** and **shares the one
`PerplFeed`** the trade screen already runs. It consumes **zero** of the 4 trading-socket cap and **zero** of the
120 req/min trading budget, leaving the full ~2 order-ops/s for the executor. `→DEP(arch)`: hold a single shared
`PerplFeed` in `AppEnvironment` and `focus()` it on the MM market.

### 1.3 RSI (Signal mode) — Wilder, period n = 14 on 1-min closes
```
Δ_t = c_t − c_{t−1}
U_t = max(Δ_t, 0);   D_t = max(−Δ_t, 0)
seed:  avgU = mean(U_1..U_n),  avgD = mean(D_1..D_n)
roll:  avgU_t = (avgU_{t−1}·(n−1) + U_t)/n     // Wilder smoothing (same for D)
RS    = avgU / max(avgD, ε)
RSI   = 100 − 100/(1 + RS)
```
Signal-mode use (`→DEP(reco §3.4)`): `RSI ≥ 70` → skew quotes to sell / gate new buy levels; `RSI ≤ 30` → skew to
buy / gate new sell levels; 30–70 → symmetric. Warmup needs ≥ n+1 candles; require ≥ 30 for a stable value else
mark `regimeConfidence` down.

### 1.4 Realized vol, EWMA vol, and the short-horizon forecast (DGrid switch + optimal spread)
Return series on 1-min closes: `r_t = ln(c_t / c_{t−1})`.

**Close-to-close realized (window N = 30):**
```
σ_ret1m = sqrt( (1/(N−1)) · Σ (r_t − r̄)² )
```
**Parkinson (uses OHLC, ~5× more efficient — better at low candle counts):**
```
σ_P² = (1/(4·ln2·N)) · Σ ( ln(h_t/l_t) )²
```
Report `sigmaRet1m = max(σ_ret1m, σ_P)` (Parkinson stabilizes the tail; C2C anchors the mean).

**EWMA (RiskMetrics, adaptive — the DGrid workhorse), λ = 0.97 for 1-min bars:**
```
σ²_t = λ · σ²_{t−1} + (1−λ) · r_t²        // seed σ²_0 = σ_ret1m²
sigmaEwma1m = sqrt(σ²_t)
```
**One-step-ahead forecast** (EWMA is already a martingale one-step forecast; blend with realized for stability):
```
volForecast1m = 0.7 · sigmaEwma1m + 0.3 · sigmaRet1m
```
> v1 = EWMA blend. **Upgrade path (flag, not v1):** GARCH(1,1) `σ²_t = ω + α·r²_{t−1} + β·σ²_{t−1}` fit on-device
> (60–240 pts, closed-form or 20-iter MLE). Only worth it if backtests show EWMA lags at regime turns. `→DEP(quant
> future)`.

**Scale to any horizon τ (minutes):** `σ_τ = volForecast1m · sqrt(τ)` (i.i.d.-return assumption; stated).

**DGrid Grid↔RGrid switch** (`→DEP(arch/executor` consumes this; hysteresis prevents flapping):
```
volZScore = (volForecast1m − mean_W) / std_W      // W = trailing 60 candles of the EWMA series
switch:  volZScore > +0.5  → RGrid  (high expected vol: buy-high/sell-low, ride the move)
         volZScore < −0.5  → Grid   (low expected vol: buy-low/sell-high, harvest oscillation)
         −0.5 … +0.5       → HOLD current mode   (dead-band = anti-flap)
gate:    also require ER (1.6) to agree — RGrid only if ER ≥ 0.35, else stay Grid.
```

**Optimal half-spread from vol (DGrid "uses historical volatility to set an optimal spread"):**
```
δ*_frac = max( midFloorBp/10_000 ,  k_σ · σ_τ  + 0.5 · advDragFrac )
k_σ = 1.2   // half-spread ≈ 1.2σ of the expected move over one requote horizon τ
τ   = requote interval in minutes (from arch; default 20s = 0.33 min)
```
`midFloorBp = 2.5` is the existing fee floor in `MMStrategy`. Example: `σ_ret1m = 0.0005 (5bp)`, `τ = 0.33`,
`σ_τ = 0.0005·√0.33 = 2.9bp` → `δ* = max(2.5, 1.2·2.9) = 3.5 bp` half-spread. Placing at ≈1.2σ keeps a resting
order out-of-the-money ~88% of a horizon so it isn't instantly run over. `→DEP(reco §3.3, arch)`.

**Theoretical grounding (documented; v1 ships the simplified form above).** Avellaneda–Stoikov:
```
reservation price   r = mid − q·γ·σ²·(T−t)          // q = signed inventory, γ = risk aversion
optimal total spread Δ = γ·σ²·(T−t) + (2/γ)·ln(1 + γ/κ)   // κ = order-flow intensity decay
bid = r − Δ/2 ,  ask = r + Δ/2
```
v1 approximates: spread = `2·δ*` (above), inventory skew = linear `−(q/qMax)·skewMax` replacing the current fixed
`bias·0.2` in `MMStrategy.midLevels`. `κ` estimate (optional): fit `λ(δ)=A·e^{−κδ}` from tape fill distances, or
`κ ≈ 1/δ̄_fill`. Ship A-S full form only if v1 skew underperforms in TCA. `→DEP(quant future)`.

### 1.5 ATR — Wilder, period 14 on 1-min candles
```
TR_t = max( h_t − l_t ,  |h_t − c_{t−1}| ,  |l_t − c_{t−1}| )
ATR_t = (ATR_{t−1}·13 + TR_t)/14       // seed = mean(TR_1..TR_14)
atrPct = ATR / mark
```
Uses: (a) stop-loss distance sanity (`SL% ≥ k·atrPct`, else SL is inside the noise band and will whipsaw — see
§2 max-loss and §3), (b) grid-step / grid-reset-threshold sizing (§3.3).

### 1.6 Trend/regime classifier (ranging vs trending)
Composite of three cheap, robust signals; primary = **Kaufman Efficiency Ratio**, confirmed by **ADX**, direction
from the sign of the net move.
```
Efficiency Ratio (window n = 20):
  ER = |c_t − c_{t−n}| / Σ_{i=t−n+1..t} |c_i − c_{i−1}|          // 0 (chop) … 1 (pure trend)

ADX (Wilder, 14):
  +DM = max(h_t−h_{t−1},0) if > (l_{t−1}−l_t) else 0 ;  −DM symmetric
  +DI = 100·EMA(+DM)/ATR ;  −DI = 100·EMA(−DM)/ATR
  DX  = 100·|+DI − −DI|/(+DI + −DI)
  ADX = Wilder-smoothed DX over 14
```
Classification (with vol overlay from §1.4):
```
trendStrength = clamp( 0.6·ER + 0.4·min(ADX/50, 1) , 0, 1 )
dir           = sign(c_t − c_{t−n})
highVol       = volZScore > +0.5  OR  atrPct > atrPct_median·1.5

regime =
  highVol        && trendStrength < 0.35              → .volatileChop
  trendStrength ≥ 0.5                                 → dir>0 ? .trendingUp : .trendingDown
  trendStrength < 0.25 && atrPct < atrPct_median      → .quiet
  else                                                → .ranging

regimeConfidence = clamp( 0.5 + 0.5·|2·ER − 1|·agreement , 0, 1 )
  // agreement = 1 if ADX and ER point the same way (both trend / both range), else 0.5;
  // downweighted to ≤0.5 while warmup candle count < 30.
```

### 1.7 Order-book imbalance & microprice (from `PerplFeed.book`)
`PerplFeed` already exposes `book.bidShare = Σbid/(Σbid+Σask)` over visible depth. Add:
```
Order-book imbalance (top K = 5 levels):
  OBI = (ΣbidSize_K − ΣaskSize_K) / (ΣbidSize_K + ΣaskSize_K)     // = 2·bidShare_K − 1, in [−1,+1]

Microprice (Stoikov fair value — weights toward the THIN side, where price is likelier to go):
  microprice = (bestBid·askSize + bestAsk·bidSize) / (bidSize + askSize)

Weighted mid (for reference-price models that want a stable center):
  weightedMid = (bestBid·bidSize + bestAsk·askSize) / (bidSize + askSize)
```
Use: microprice is the **reference price** for Mid/Blend quoting instead of raw mark, and OBI adds a short-horizon
skew (`skew += OBI·kOBI`, `kOBI ≈ 0.15`). `→DEP(reco §3.2, arch)`. Throttle recompute to ≤2/s; O(K).

### 1.8 24h volume (participation → duration)
`volume24hUsd`: prefer `PerplFeed.state.volume24h · mark` (units×price); fallback
`MarketContext.volume24h · mark` from `PerplService.context()`. Refresh on open + every 60s from the WS state
frame (free). This is the denominator of the duration formula (§2.3).

---

## 2. Pre-Trade Analytics engine (match/beat tread.fi's panel)

### 2.1 File & type
```
DyorKit/Sources/DyorKit/Services/Quant/PreTradeAnalytics.swift   // pure: (inputs) -> PreTradeEstimate
ios/DyorHQ/Strategy/PreTradePanelView.swift                      // renders it in MarketMakingView
```
```swift
public struct PreTradeInputs: Sendable {
    let marginUsd: Double          // C  (capital)
    let leverage: Double           // L
    let targetVolumeUsd: Double    // V_target
    let participation: Participation // p ∈ {.aggressive .10, .normal .05, .passive .01}
    let spreadBp: Double           // configured half-spread (bp) or δ* from §1.4
    let nLevels: Int               // total resting levels (Mid: 2·levelsPerSide; Grid: gridLevels)
    let takeProfitPct: Double
    let stopLossPct: Double
    let market: PerpMarket         // mark, initMarginFraction, maintMarginFraction, lotDecimals
    let account: PerpAccount       // balance, locked (AUSD 6dp)
    let ind: IndicatorSnapshot     // sigma, regime, atr, volume24hUsd
}

public struct PreTradeEstimate: Sendable {
    let availableMarginUsd, requiredMarginUsd: Double
    let marginOK: Bool
    let maxLossUsd: Double
    let durationMin: Double
    let estFills: Int
    let estRoundTrips: Int
    let volumeAttainableUsd: Double        // min(participation ceiling, capital-cycling capacity)
    let participationCeilingUsd: Double
    let projectedCostPer1M: Double         // net economic, can be negative
    let projectedNetFeesUsd: Double
    let grossFeesUsd, expectedSpreadCaptureUsd, expectedAdverseDragUsd: Double
    let liquidationPrice: Double?
    let liqDistancePct: Double?
    let verdict: Verdict                   // .go / .caution / .noGo
    let verdictMessage: String
}
public enum Verdict: String, Sendable { case go, caution, noGo }
```

### 2.2 Available Margin, Required Margin, Max Loss
```
deployed  D = C · L                                   // matches MMStrategy.deployed
availableMargin A = fromCNS(account.balance) − fromCNS(account.locked)     // AUSD 6dp
requiredMargin  M_req = Σ_levels (levelNotional / L) = D / L = C
marginOK = A ≥ M_req  (= A ≥ C)
  // insufficient warning, tread.fi-style: "Order requires $\(C) but only $\(A) available."
maxLoss ML = stopLossPct/100 · C                     // tread.fi: 15%·$100 = $15
  // hard backstop: ML is also floored by liquidation (§2.7); executor's kill-switch uses min(ML, liq-loss). →DEP(risk)
```
ATR sanity: if `stopLossPct/100 < 1.0·atrPct` flag "stop is inside 1×ATR noise — likely whipsaw." (advisory).

### 2.3 Estimated Duration (auto) — from margin, market 24h volume, participation
```
marketRatePerMin = volume24hUsd / 1440
durationMin      T = targetVolumeUsd / (participation · marketRatePerMin)
                   = 1440 · targetVolumeUsd / (participation · volume24hUsd)
clamp T to [10, 1000] min   (tread.fi range)
```
**Self-consistency check vs tread.fi** (participation presets 10% / 5% / 1%): T ∝ 1/p, so for fixed V, V24h the
three presets give **T₀ / 2T₀ / 10T₀ = 10 / 20 / 100 min** — exactly tread.fi's "Aggressive ~10m / Normal ~20m /
Passive 1h40m." The "your order is 1/10 of volume, market trades ~9× your size" note is the p = 10% case. Default
volume heuristic (when the user hasn't set one) = `min(margin·20, participationCeiling)`.

```swift
public enum Participation: Double, Sendable, Codable {
    case aggressive = 0.10, normal = 0.05, passive = 0.01
    var typicalLabel: String { self == .aggressive ? "~fast" : self == .normal ? "~medium" : "~slow" }
}
```

### 2.4 Estimated fills / round-trips
```
avgLegNotional = D / nLevels
one requote cycle = open all levels + keeper-close all = 2·nLevels legs, turnover 2D volume
cyclesNeeded  = V_target / (2D)
estFills      = nLevels · V_target / D          // = 2·nLevels·cyclesNeeded
estRoundTrips = estFills / 2 = nLevels · V_target / (2D)
```
Example: C=$100, L=3 → D=$300; nLevels=6, V=$3000 → cyclesNeeded=5, estFills=60, estRoundTrips=30.
Apply fill-efficiency η (§2.5) to the *time* to reach these, not the count (you still need this many fills to hit
V; η says how long that takes / whether it's attainable).

### 2.5 Estimated Volume attainable (is V_target reachable in T?)
Two ceilings; attainable = the smaller.
```
(a) Participation ceiling (market can't give you more than your share of its flow):
    participationCeilingUsd = participation · volume24hUsd · (T / 1440)
      // note: with T from §2.3 this ≡ V_target, so (a) binds only when T hit the [10,1000] clamp.

(b) Capital-cycling capacity (how fast YOUR ladder can turn over given vol vs spread):
    // driftless BM: expected time to traverse half-spread band ±δ is τ_fill = δ² / σ²  (per-min units)
    δ = spreadBp/10_000                       // half-spread fraction
    σ = ind.sigmaRet1m                        // per-1min return vol
    cyclesPerMin = σ² / δ²                     // fills of a two-sided level per minute
    volumeRatePerMin = 2D · cyclesPerMin      // both sides turn over → 2D per cycle
    capacityUsd = volumeRatePerMin · T

volumeAttainableUsd = min(participationCeilingUsd, capacityUsd)
```
Worked number: δ=10bp=0.001, σ=5bp=0.0005 → cyclesPerMin = (0.0005)²/(0.001)² = 0.25 (one fill / 4 min).
D=$300 → volumeRatePerMin = 2·300·0.25 = $150/min; over T=20min → capacity $3000 → V=$3000 attainable. If the
user then tightens spread to 5bp, cyclesPerMin=1.0, rate=$600/min → capacity $12000 (fills faster but more
adverse selection, §2.6). This is the honest tension the panel makes visible.

### 2.6 Projected Cost/$1M, Net Fees, spread capture, adverse-selection drag
```
grossFeesUsd            = feePerLegBp/10_000 · V_target                       // 2.5bp on all legs
rebatesUsd              = rebateBp/10_000 · V_target                          // ⚠ 0 until confirmed (§6)

// Expected spread capture: each completed round-trip earns its edge minus the 2 legs' fees.
captureBpPerRT          = (grid ? gridStepBp : 2·spreadBp)                    // edge earned per round-trip
expectedSpreadCaptureUsd= (captureBpPerRT/10_000 · avgLegNotional) · estRoundTrips · pClose
  // pClose = P(TP completes before SL / reset) — from regime:
  //   ranging/quiet: 0.80,  trendingUp/Down (with-trend side): 0.55,  volatileChop: 0.45
  //   (calibrate from TCA history over time, §4)

// Adverse-selection drag: fills that get run over. Scales with trend strength and vol.
advDragBp               = kAdv · trendStrength · sigmaRet1m·10_000            // kAdv ≈ 0.5
expectedAdverseDragUsd  = advDragBp/10_000 · V_target

projectedNetFeesUsd     = grossFeesUsd − rebatesUsd                           // tread.fi "Net Fees" column
netEconomicPnL          = expectedSpreadCaptureUsd + rebatesUsd − grossFeesUsd − expectedAdverseDragUsd
projectedCostPer1M      = −netEconomicPnL / V_target · 1e6
```
Worked: V=$3000, gross fees = 2.5bp·3000 = $0.75; ranging Grid step 15bp, avgLegNotional=$50, RT=30, pClose=0.8 →
capture = (15/10_000·50)·30·0.8 = $1.80; advDrag (ER≈0.1, σ=5bp): 0.5·0.1·5 = 0.25bp → $0.075.
netPnL = 1.80 + 0 − 0.75 − 0.075 = **+$0.975** → CostPer1M = −0.975/3000·1e6 = **−$325/$1M** (paid to trade — the
good case). Flip to trending (pClose 0.55, advDrag up): capture $1.24, advDrag ~$0.5 → netPnL = 1.24−0.75−0.5 =
**−$0.01** → CostPer1M ≈ **+$3/$1M**, and if you tighten spread it goes sharply positive. This is the whole point:
**Grid in ranging = negative cost; Grid in trending = you pay.** The panel shows the number *for the current
regime*, so the user sees it before committing.

### 2.7 Estimated liquidation price (worst-case inventory)
Reuse the shipped formula `PerplService.liquidationPrice(side:entry:size:margin:premium:maintenanceFraction:)`:
```
worst-case one-directional fill:
  Grid:  size = D / mark,        entry ≈ mark·(1 − avgHalfSpreadFrac)  (long grid; symmetric for short)
  Mid:   size = (D/2) / mark,    entry ≈ mark·(1 − avgHalfSpreadFrac)  (one side fully filled)
liqPrice = liquidationPrice(side, entry, size, margin: C, premium: 0, maintenanceFraction: market.maintMarginFraction)
liqDistancePct = |liqPrice − mark| / mark · 100
```
Warn if `liqDistancePct < 2·(stopLossPct)` — SL may not trigger before liquidation in a gap. `→DEP(risk)` owns the
live liq monitor; I provide the pre-trade estimate.

### 2.8 Plain-English go/no-go
```
verdict:
  noGo   if !marginOK
      or liqDistancePct < stopLossPct                       (liq inside stop)
      or volumeAttainableUsd < 0.5·V_target                 (can't get halfway)
  caution if projectedCostPer1M > +250                      (you'd pay MORE than the fee floor — regime mismatch)
      or regime is trending while mode = Grid               (stuck-order risk)
      or durationMin == 1000 (clamped: target too big for participation)
      or regimeConfidence < 0.4
  go     otherwise
message: templated, e.g.
  .go:      "Ranging market, low vol. ~30 round-trips over ~20 min; projected −$325/$1M (spread capture > fees). Margin OK."
  .caution: "Trending up while in Grid — orders may get stuck and stop out. Consider RGrid or reduce size. Projected +$120/$1M."
  .noGo:    "Order requires $100 but only $7.10 available." / "Liquidation ($61,240) is inside your 1.5% stop."
```
Every message states the *why* and the number. Decision-support, never "do this."

---

## 3. Recommendation layer ("financial recommendation layer")

### 3.1 File & type
```
DyorKit/Sources/DyorKit/Services/Quant/Recommendation.swift   // pure engine + presets
ios/DyorHQ/Strategy/RecommendationView.swift                  // "Suggested setup" card + Apply
ios/DyorHQ/Strategy/RecoPresetStore.swift                     // per-wallet persist + Supabase sync
```
```swift
public enum RefModel: String, Sendable, Codable { case mid, grid, rgrid, dgrid, blend, signal }
public enum RiskAppetite: String, Sendable, Codable { case conservative, balanced, aggressive }

public struct Recommendation: Sendable {
    let refModel: RefModel
    let spreadBp: Double
    let participation: Participation
    let leverage: Double
    let takeProfitPct: Double
    let stopLossPct: Double
    let gridResetPct: Double        // Grid reset threshold (or TP reset threshold for RGrid)
    let directionalBias: Double     // −1…+1, only meaningful for .mid / .blend
    let confidence: Double          // 0…1
    let rationale: String           // one line
    let disclaimer: String          // fixed compliance string (§3.5)
}
public func recommend(regime ind: IndicatorSnapshot, goal: PreTradeInputs, appetite: RiskAppetite) -> Recommendation
```

### 3.2 Regime → reference-price model (the core decision table)
| Regime (from §1.6) | Recommended model | Why (rationale seed) |
|---|---|---|
| `.ranging` | **Grid** | buy-low/sell-high harvests oscillation; negative cost/$1M when it works |
| `.quiet` | **Grid** (tight) or **Mid** | little movement; tight Grid or symmetric Mid; thin edge, warn low fills |
| `.trendingUp` / `.trendingDown` | **RGrid** | buy-high/sell-low rides the move; avoids stuck grid orders |
| `.volatileChop` | **DGrid** | vol forecast flips Grid↔RGrid per §1.4; wide, vol-scaled spread |
| conflicting / `regimeConfidence < 0.4` | **Blend** (Mid + Grid) or **Mid** neutral | hedge model risk; symmetric quoting |
| `RSI ≤ 30` or `≥ 70` (any regime) | overlay **Signal** skew | gate/skew quoting by RSI extreme (§1.3) |

Reference price used by the chosen model: **microprice** (§1.7) for Mid/Blend, **mark** for Grid/RGrid center,
plus OBI skew. `→DEP(arch)` consumes `refModel` + reference price in the ladder builder (extends
`MMStrategy.levels(mark:)` to accept a `referencePrice` and the new models).

### 3.3 Spread, participation, leverage, TP/SL, grid-reset — the numeric recipe
Base from risk appetite, then regime-modulated:
```
spreadBp     = clamp( max(midFloorBp, kσ·σ_τ·10_000) · appetiteSpreadMult , midFloorBp , 60 )
               appetiteSpreadMult: conservative 1.5, balanced 1.0, aggressive 0.8
participation: conservative .passive(1%), balanced .normal(5%), aggressive .aggressive(10%)
leverage     = min( appetiteLevCap, marketMaxLev )
               appetiteLevCap: conservative 2, balanced 5, aggressive 10 ;  marketMaxLev = floor(1/initMarginFraction)
stopLossPct  = max( kSL·atrPct·100 , appetiteSLFloor )
               kSL: conservative 3.0, balanced 2.0, aggressive 1.5 ; appetiteSLFloor: 1.0 / 1.5 / 2.5
takeProfitPct= regime==ranging/quiet ? 0.6·stopLossPct : 1.2·stopLossPct   // range: harvest small; trend: let winners run
gridResetPct = clamp( 2.5·atrPct·100 , 0.05 , 1.0 )   // re-center when price leaves ±2.5·ATR; snapped to tread.fi steps {0.05,0.125,0.25,0.5,1.0}
               // for RGrid this same number is used as the TP-reset threshold
directionalBias(mid/blend) = clamp( OBI·0.15 + trendStrength·dir·0.3 , −1, 1 )
```
Worked (Balanced, ranging BTC, atrPct=0.15%, σ_τ=3bp): spread = max(2.5, 1.2·3)·1.0 = 3.6bp; part = 5%; lev =
min(5, 25)=5; SL = max(2.0·0.15, 1.5) = 1.5%; TP = 0.6·1.5 = 0.9%; gridReset = clamp(2.5·0.15,…)=0.375 → snap
0.5%. All values land in `MMStrategy` fields directly (`spreadBp`, `leverage`, `takeProfitPct`, `stopLossPct`,
`gridStepBp`←derived, plus new `refModel`, `gridResetPct`, `participation`).

### 3.4 Confidence & rationale
```
confidence = clamp(
    0.35
  + 0.30·regimeConfidence                          // §1.6
  + 0.20·(agreement of OBI sign with dir)          // book confirms trend?
  + 0.15·(warmupCandles ≥ 60 ? 1 : warmupCandles/60)
  , 0, 1)
rationale = "\(regime.title) (ER \(ef.2f), ADX \(adx.0f)), vol \(σbp.1f)bp → \(refModel.title) at \(spread.1f)bp; reset ±\(reset)%.  Projected \(cost)/$1M."
```
Example: `"Ranging (ER 0.18, ADX 14), vol 5.0bp → Grid at 3.6bp; reset ±0.5%. Projected −$310/$1M."`
Confidence is shown as a bar; below 0.4 the card says "Low confidence — market unclear; consider waiting or Mid
neutral."

### 3.5 Presets: definitions, persistence, load
**Built-in presets** (`RecoPreset.builtins`, `isBuiltIn = true`) — the three appetites, each auto-tuned to live
regime at Apply time (they store the *appetite*, not frozen numbers, so they always re-derive against current
indicators):
```
Conservative — lev≤2, SL 1.0%, Passive(1%), spread ×1.5, TP 0.6·SL, gridReset wide (0.5–1%)
Balanced     — lev≤5, SL 1.5%, Normal(5%),  spread ×1.0, TP 0.6–1.2·SL, gridReset 0.25–0.5%
Aggressive   — lev≤10, SL 2.5%, Aggressive(10%), spread ×0.8, TP 1.2·SL, gridReset 0.125–0.25%
+ regime-tuned variants surfaced contextually: "Grid — Ranging", "RGrid — Trending", "DGrid — Volatile"
  (these pin refModel and let the rest derive from the active appetite).
```
**User presets:** captured from the current config via a "Save as Preset…" action (name + current field values +
the appetite). Frozen numeric snapshots (`isBuiltIn=false`).

**Persistence (mirror the existing `MMStore` pattern exactly):**
```swift
enum RecoPresetStore {                         // ios/DyorHQ/Strategy/RecoPresetStore.swift
    // local, per-wallet, offline-first (same shape as MMStore):
    static func presets(owner: Address?) -> [RecoPreset]   // key "mm.presets.v1.<wallet>"
    static func save(_:owner:) / upsert(_:owner:) / remove(id:owner:)
}
```
Local UserDefaults is the source of truth for instant load/offline; **cross-device sync via Supabase**
`mm_presets` table (§4.4) — on sign-in, merge remote→local (last-write-wins by `updated_at`); on save, upsert
local then best-effort push remote. `→DEP(infra)`: needs the `wallet-auth` Edge Function (memory: not yet built)
to write authenticated. Reads are world-readable-free with the publishable key under wallet RLS.

**Load UX:** "Presets" menu at the top of `MarketMakingView` (matches tread.fi). Selecting a preset calls
`recommend(...)` (built-in) or applies the frozen snapshot (user), fills every config field, and shows the
`Recommendation` card with confidence + rationale + disclaimer. The user can then tweak before confirming.

### 3.6 Fixed disclaimer (compliance)
```
disclaimer = "Suggested configuration from live market conditions and your inputs — decision-support, not
investment advice. Generating volume has real, non-refundable costs (~$250/$1M in fees before spread capture).
Outcomes are not guaranteed. You confirm and remain in control."
```

---

## 4. Post-session Analytics / TCA

### 4.1 Files & types
```
DyorKit/Sources/DyorKit/Services/Quant/TCA.swift        // pure: fills + markouts -> TCAReport
ios/DyorHQ/Strategy/AnalyticsView.swift                 // Analytics tab + Lifetime Summary
ios/DyorHQ/Strategy/MMSessionStore.swift                // Supabase read/write of sessions/fills
```
```swift
public struct TCAReport: Sendable {
    let volumeUsd: Double
    let grossFeesUsd, rebatesUsd, netFeesUsd: Double
    let realizedPnLUsd: Double
    let costPer1M: Double
    let spreadCaptureUsd, adverseSelectionUsd, inventoryPnLUsd, fundingUsd: Double  // PnL attribution
    let makerFillRatio: Double        // filled maker legs / placed maker orders
    let filledPct: Double             // volumeUsd / targetVolumeUsd
    let markoutBps: [Int: Double]     // horizon(sec) -> avg markout in bp, by side
}
```

### 4.2 Ground-truth inputs
- **Fills:** `PerplService.fills(key:markets:)` → `/v1/trading/fills` — every leg incl. keeper-fired TP/SL closes,
  with fee. Join to P&L by `(marketId, orderId)` per the memory note (order ids are per-market).
- **Realized P&L:** `PerplService.positionHistory(...)` → `/v1/trading/position-history`; realized = `dpnl + fnd`
  (funding). Opens realize nothing.
- **Markouts:** the mid/microprice at t+Δ after each fill. **Only capturable while a client is subscribed to the
  tape** — the on-device engine records `MarkoutSample` into the session while the app is foreground; for
  background/whole-session coverage the **worker** must subscribe to `trades@`/`market-state@` and store markouts.
  `→DEP(arch/infra)` — flag: markouts are best-effort on-device, complete only under the server-executor arch.

### 4.3 TCA formulas
```
volumeUsd            = Σ_legs notional                                  // every leg (fixes §0.1 double-count)
grossFeesUsd         = Σ_legs fee   (from fills feed; sanity ≈ feePerLegBp/10_000·volume)
rebatesUsd           = Σ rewards accrued this session   (⚠ needs rewards API, §6; else 0)
netFeesUsd           = grossFeesUsd − rebatesUsd
realizedPnLUsd       = Σ position-history (dpnl + fnd)                  // authoritative
costPer1M            = −realizedPnLUsd / volumeUsd · 1e6

// PnL attribution (decompose realizedPnL):
spreadCaptureUsd     = Σ_{closed RTs} (exit − entry)·size·sideSign  restricted to intended-edge closes (TP/maker close)
inventoryPnLUsd      = Σ_{closed RTs} directional component beyond the intended edge (SL closes, drift)
fundingUsd           = Σ fnd
adverseSelectionUsd  = − Σ_legs markout(h*)·notional     // h* = 30s default; negative markout = adverse
   check identity:  realizedPnL ≈ spreadCapture + inventoryPnL + funding − grossFees   (report residual)

makerFillRatio       = filledMakerLegs / placedMakerOrders             // all our orders are post-only maker
filledPct            = min(1, volumeUsd / targetVolumeUsd)
markoutBps[h]        = mean_legs( (mid_{t+h} − fillPrice)/fillPrice·10_000 · sideSign )   for h ∈ {1,5,30,60}s
```
Interpretation surfaced in UI: `makerFillRatio` high + markouts negative ⇒ spread too tight (getting picked off);
markouts ≈ 0 or positive ⇒ healthy capture. `capture vs adverse selection` shown as a two-bar split of gross edge.

### 4.4 Supabase storage (new tables; same RLS model as existing — wallet-owned, no keys)
Add migration `08_mm_sessions.sql` to `~/Hackathon/supabase` (project ref `fmnjqrguvopusfufmirs`). All tables:
`wallet_address text` lowercased, RLS via `public.app_wallet()`; public-read with publishable key, writes require
the matching authenticated wallet. **No private keys, no Ed25519 secret — records only.**
```sql
mm_sessions(
  id uuid pk, wallet_address text, market_id int, symbol text, mode text, ref_model text,
  preset_name text, started_at timestamptz, ended_at timestamptz, status text,      -- running|finished|canceled
  margin numeric, leverage numeric, spread_bp numeric, participation numeric,
  target_volume numeric, volume numeric, gross_fees numeric, rebates numeric, net_fees numeric,
  spread_capture numeric, adverse_selection numeric, inventory_pnl numeric, funding numeric,
  realized_pnl numeric, cost_per_1m numeric, maker_fill_ratio numeric, filled_pct numeric,
  updated_at timestamptz )
mm_fills(
  id uuid pk, session_id uuid fk, wallet_address text, market_id int, side text,
  price numeric, size numeric, notional numeric, fee numeric, is_maker bool, ts timestamptz,
  markout_1s numeric, markout_5s numeric, markout_30s numeric, markout_60s numeric )
mm_presets(
  id uuid pk, wallet_address text, name text, risk_appetite text, config jsonb, is_builtin bool, updated_at timestamptz )
```
**Lifetime Summary** (tread.fi "Volume, Net Fees") — a security-definer RPC or view aggregating the caller's
sessions:
```sql
-- rpc mm_lifetime_summary() -> (total_volume, total_net_fees, total_realized_pnl, avg_cost_per_1m, session_count)
select sum(volume), sum(net_fees), sum(realized_pnl),
       case when sum(volume)>0 then -sum(realized_pnl)/sum(volume)*1e6 else 0 end,
       count(*)
from mm_sessions where wallet_address = public.app_wallet() and status='finished';
```
`→DEP(infra)`: writes need the `wallet-auth` Edge Function (memory: still to build; needs the project JWT signing
secret from the user, or enable Supabase Web3/SIWE). Until then, Analytics works **offline** from local session
records (extend `MMStore` to keep a `history` list) and syncs when auth lands. `→DEP(ux)` for the tab layout.

### 4.5 Analytics tab & Sessions table (columns match/beat tread.fi)
`AnalyticsView` renders the Sessions table (tabs Active / History / Scheduled / **Analytics** / Campaigns —
`→DEP(ux)` owns the table shell; I own the Analytics tab content and the per-session detail):
- Sessions columns: Mode, Pair, Volume, Net Fees, PnL, **Cost/$1M**, Spread, Filled %, Maker Fill %, Status.
- Session detail: PnL attribution bars (spread capture / inventory / funding / −fees), markout curve by horizon,
  capture-vs-adverse-selection split, the realized-vs-projected Cost/$1M delta (calibrates §2.6's `pClose`).
- Header **Lifetime Summary**: Volume, Net Fees (from the RPC), plus avg Cost/$1M and total sessions.

---

## 5. Dependencies on other sections
| Tag | What I need / hand off |
|---|---|
| `→DEP(arch)` | Share **one** `PerplFeed` (market-data WS) in `AppEnvironment`; do not open a second socket for indicators. Extend `MMStrategy.levels(mark:)` → `levels(referencePrice:refModel:)` to consume `RefModel` + microprice + inventory skew. Executor consumes: `volForecast1m`, `volZScore` (DGrid switch), `δ*` (optimal spread), per-minute volume budget `V_target/T`, and the recommendation output. Executor's realized-volume counter must read the **fills feed**, not the resting-order diff (fixes §0.1). Requote interval `τ` feeds my spread scaling. |
| `→DEP(risk)` | I compute `maxLoss`, `liquidationPrice`, `liqDistancePct`, ATR-vs-SL warnings; risk owns the live kill-switch (stop+flatten at `min(ML, liq-loss)`), inventory caps, one-sided-trading halt. |
| `→DEP(reco)` | (self) — but the ladder-builder integration and Signal/RGrid/DGrid/Blend placement logic live with arch. |
| `→DEP(infra)` | `wallet-auth` Edge Function + JWT signing secret (not yet built, per memory) to write `mm_sessions/mm_fills/mm_presets` and run `mm_lifetime_summary`. Migration `08_mm_sessions.sql`. Optional: worker subscribes to `trades@`/`market-state@` to capture whole-session markouts under the server-executor arch, and runs the **same** pure `Indicators.swift` math server-side. |
| `→DEP(ux)` | Sessions table shell + tabs; I fill the Analytics tab, Pre-Trade panel, Recommendation card, Presets menu. Confirm all disclaimer strings render. |
| `→DEP(quant future)` | GARCH(1,1) vol forecast, full Avellaneda–Stoikov spread + `κ` estimation, `pClose`/`kAdv` calibration from accumulated TCA history. |

---

## 6. External APIs / data / credentials to request from the user
1. **Maker-rebate / MM-reward / points / airdrop program on Perpl or Monad** — *does one exist, and is there an
   API/endpoint to read accrued rewards per wallet/session?* This is the difference between honest and dishonest
   Cost/$1M: rebates can turn `+$250/$1M` into net-negative. **Until confirmed, `rebateBp = 0` and Cost/$1M shows
   the pessimistic (no-rebate) number** with a note "excludes any rewards program." (Brief already flags this as
   an API-need.)
2. **Supabase project JWT / signing secret** (or enable Web3/SIWE auth) so the `wallet-auth` Edge Function can
   mint wallet-scoped JWTs — required to persist sessions/fills/presets and the Lifetime Summary cross-device.
   (Memory: the function and secret are still outstanding.)
3. **Confirmed exact fee schedule** — I use maker 1.5 bp + builder 1.0 bp = 2.5 bp/leg (from the brief). If the
   builder code or Perpl maker tier differs, `MMEcon` is the one place to change it. Please confirm the live
   numbers and whether builder fee is per-leg or per-order.

No external market-data vendor is needed: every indicator is computed on-device from Perpl's own free candles,
book and tape. That keeps the feature self-contained, offline-capable at config time, and honest.

---

## 7. Open questions
- **pClose / kAdv calibration:** initial constants in §2.6 are principled priors; they should be fit from the first
  N real sessions' TCA. Ship with priors, recalibrate via a Supabase aggregate. Acceptable?
- **Markout completeness:** on-device markouts only cover foreground time. Is whole-session markout important
  enough to justify the worker tape subscription now, or defer to the server-executor arch decision?
- **DGrid dead-band width (±0.5σ z-score):** anti-flap vs responsiveness — validate against BTC/MON tapes before
  locking.
- **Candle resolution:** 1-min is the default; MON/low-liquidity markets may need 5-min for stable vol/ADX. Auto-
  pick by `numOrders`/`volume24h`? (Proposed: use 5-min when `volume24hUsd < $250k`.)
