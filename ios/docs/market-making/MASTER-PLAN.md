# DyorHQ Market-Making / Volume Feature — Master Build Plan

*Chief-architect integration of six specialist designs (arch · quant · infra · risk · reco · ux) with every
red-team fix applied. This is the single buildable plan of record. Where two sections conflicted, the resolution is
stated inline as **[RESOLVED]** with the losing option and the reason. Everything is grounded in the live code
(`ios/DyorHQ/Strategy/*`, `ios/DyorKit/Sources/DyorKit/Services/Perpl/*`, `worker/index.ts`, Supabase project
`fmnjqrguvopusfufmirs`) and the verified Perpl/Monad facts in the brief.*

---

## 1. Executive summary + the honest promise

**The promise (unchanged across every section, enforced in code and copy):**
> *Hit your volume target within a chosen time box, at the lowest possible **Cost/$1M**, under hard risk limits,
> with live visibility — using genuine two-sided maker liquidity filled by the real order book. Not costless, never
> self-matched, profit not guaranteed.*

Generating perp volume costs money. On Perpl each **filled leg** costs ~2.5 bp (≈1.5 bp maker + ~1.0 bp builder). A
buy+sell round-trip of notional N makes **2N of volume** and costs ~5 bp·N ⇒ **~$250 per $1,000,000 of volume**.
That $250/$1M is the unavoidable fee **floor** and the headline metric. Profit above the floor comes only from (1)
spread capture in a *ranging* market and (2) maker rebates / reward programs *if Perpl pays them* (unconfirmed —
until confirmed, `rebateBp = 0` and every screen shows the pessimistic number). Trending markets always lose.
Self-matching is out of scope, structurally prevented, and on Perpl just churns your own fees.

**Single source of truth for economics — `DyorKit/.../Quant/MMEcon.swift`:**
```
feeMakerBp = 1.5 ; feeBuilderBp = 1.0 ; feePerLegBp = 2.5 ; roundTripBp = 5.0 ; rebateBp = 0.0  // until confirmed
CostPer1M_floor = feePerLegBp · 100 = $250 / $1M of volume
CostPer1M(live) = −realizedNetPnL / Volume · 1e6      // positive = it cost you; negative = you were paid
```
**[RESOLVED — Cost/$1M number]** The risk section's `2·feeRateBp·100` (=$500–$1000) and the existing
`MMStatusView.feeRateBp = 5.0 × volume` are both wrong (they treat 5 bp as per-volume-dollar; it is per-round-trip
= 2.5 bp per volume dollar). The reco section's `$250/$1M` is canonical. Fix `MMStatusView`, the risk section's
§6/§8, and the ux pre-trade card (which showed inconsistent $75 fees / $180 cost on a $15k target — correct is
$37.50 fees / ≥$250/$1M).

**What we ship, in one line each:**
- A **strategy engine** (six reference-price models: Mid/Grid/RGrid/DGrid/Blend/Signal) that extends the shipped
  `MMStrategy.levels()` with volume-target, participation→duration scheduling, and a real requote loop.
- A **Perpl order-lifecycle engine** with post-only (`fl:1`) makers, amend-first requoting inside the rate budget,
  mt:24-authoritative fills, and crash-safe reconciliation.
- A **risk layer**: health/DTL ladder, real-time Max-Loss kill, circuit breakers, SAFE teardown, compliance
  gates + consent.
- An **indicators + recommendation + pre-trade analytics** layer (all on-device from free market data).
- A **UX** layer: config screen, the **LIVE STATUS BAR**, expanded dashboard, sessions table, Live Activity.
- Two custody modes: **Attended** (on-device, self-custodial, foreground) ships first; **Hybrid** (Cloudflare
  Durable Object executor with a session-scoped no-withdrawal key) ships second and makes "phone in pocket" real.

---

## 2. Recommended execution architecture

### 2.1 The decision — Hybrid, built as the safest variant, with Attended as a first-class self-custodial mode

**Default = Hybrid (brief §4·C): the requote loop and the single Perpl trading socket run server-side in a
Cloudflare Durable Object; the phone is a cockpit.** iOS suspends an app within seconds of backgrounding and
*cannot* sustain a 10–1000-minute requoting loop or hold a socket in a pocket (brief §4), so a phone alone
structurally cannot meet the headline promise for anything but a short attended burst.

We also ship **Attended (max-custody)**: the identical engine runs **on-device, foreground-only**, the Ed25519 key
never leaves the Keychain, and nothing touches a server. It is honest about its limit — it only quotes while the app
is on screen — and it is what ships first (Phase 1).

**[RESOLVED — why not pure A or pure B]** Pure server-side (A) hides the custody decision and discards the
self-custodial path; pure on-device (B) can't meet the promise. Hybrid = A's engine + B's honesty + a hard kill the
phone owns.

### 2.2 The key-custody tradeoff, stated plainly

In **Hybrid**, a DyorHQ server can place and cancel trades on your Perpl account for the life of the session. The
mitigations that make this a bounded, revocable, user-granted decision rather than a blank cheque:
- The session key is **generated inside the Durable Object** and never leaves it; the phone only ever sees the
  *public* key. The phone's wallet signs one EIP-712 payload binding that public key to **scope_mask = 2 (trade)**,
  which Perpl enforces as **cannot withdraw funds**.
- The key **auto-expires** at `endsAt + grace` (DO alarm; plus a Perpl-side TTL if the enroll endpoint supports one).
- The secret is **AES-GCM-wrapped** (`SESSION_WRAP_KEY`) in DO storage and is **never written to Supabase** (only
  the public key + fingerprint + expiry, for audit).
- **Dual kill switch (the trust anchor).** The kill button fires *both* in parallel: (1) the phone sends
  `allowOrderForwarding(false)` to the Exchange contract **from the user's own wallet** — every forwarded order then
  fails `sr:34`, independent of the DO, the key, or network reachability; (2) `POST /kill` → the DO cancels/flattens
  best-effort, **destroys/rotates the delegated key**, and wipes the secret.

**[RESOLVED — what the worker can and cannot revoke]** (risk review #4 / infra review C4) The worker holds only a
trade-scoped Ed25519 key; it **cannot** sign a wallet EIP-712 tx, so it **cannot** flip `allowOrderForwarding`.
Worker-side "revoke" therefore means **destroy the key + stop the executor** (+ Perpl key-revoke/TTL if available),
never forwarding-off. `allowOrderForwarding(false)` is a **phone/user-only** capability and is **global** (it also
disables the user's manual one-click). The kill **sequences flatten-first (forwarding ON) → verify flat → then
forwarding-off**, because once forwarding is off you can no longer place the closing orders, and it is unconfirmed
whether forwarding-off preserves already-resting keeper TP/SL triggers (open API question).

### 2.3 Diagram-in-words: device ↔ worker ↔ Perpl ↔ Supabase

```
┌──────────────────────── iPhone (SwiftUI / DyorKit) ────────────────────────┐
│  MMConfigView ─ config + pre-trade analytics + recommendation + consent      │
│  MMSessionManager (@Observable @MainActor) ─ the one UI state hub:           │
│      wraps → MMSessionClient (worker REST + SSE)   [Hybrid cockpit]          │
│            → PerplExecutionEngine host             [Attended, on-device]     │
│            → MMRiskMonitor, connection health, Live Activity lifecycle       │
│  MMStatusView (expanded dashboard) · MMLiveBar (app-wide compact bar)        │
│  MMSessionsView (Active/History/Scheduled/Analytics/Campaigns)               │
│  PerplTrading (@MainActor) ─ mode {.executor|.cockpit}, forwarding on/off,   │
│      Ed25519 enroll, Attended socket, the on-chain KILL                      │
│  BackgroundTasks ─ BGAppRefresh + BGProcessing (NOTIFY/reconcile only)       │
└───────┬──────────────────────────────────────────────────┬─────────────────┘
        │ HTTPS  Authorization: Bearer <supabase wallet-JWT>│ SSE status stream
        │ /api/mm/*                                          │ (foreground)
        │                                        APNs push ◄─┼─ (background alerts +
┌───────▼────────────────────────────────────────────────┐ │   Live Activity updates)
│              Cloudflare Worker (worker/)  [Paid plan]    │ │
│  mm/router.ts → verifies JWT wallet_address              │ │
│  ┌──────── PerplSocketDO  (id = walletLower) ─────────┐  │ │
│  │  ONE authed Perpl trading WS (mt:29 → mt:22 …)     │◄─┼─┘
│  │  ONE market-data WS (mark/book — unauth, off-cap)  │  │
│  │  session Ed25519 secret (AES-GCM wrapped, DO-only) │  │
│  │  rq counter · SlotMap · FillLedger(WAL) · budget   │  │
│  │  single-writer lease · SessionRunner[] (cap 1 @v1) │  │
│  │  alarm() → requote tick · reconcile · expiry       │  │
│  └───────────────────────────────────────────────────┘  │
└───┬──────────────────────────────────────────┬──────────┘
Perpl trading WS + market-data WS      service_role writes │
Monad RPC (rpc1) reads = truth ────────────────────────────▼
      │                                    Supabase (fmnjqrguvopusfufmirs)
      ▼                                    mm_sessions / mm_fills / mm_events /
  app.perpl.xyz / Exchange 0x34B6…a6F      mm_presets  (RLS by lowercased wallet)
```

**The load-bearing constraint that shapes all of it (per wallet, not per key/device):** **4 trading sockets max per
wallet** (shared with app.perpl.xyz tabs) and **~120 req/min per socket**. Keep-alive `{mt:1}`/30 s costs 2/min ⇒
**~118 order-ops/min ≈ 1.97/s** for the entire wallet across every level and market. Consequences enforced
everywhere: **one socket owner per wallet** (one `PerplSocketDO`, `idFromName(walletLower)`, multiplexing sessions
over one socket and one rq sequence); the **phone releases its trading socket while a Hybrid session runs** (mode
`.cockpit`, reads truth from SSE + on-chain RPC); **amend (t:7) over cancel+replace** to fit the budget; **one live
quoter per wallet+market** (single-writer lease — Attended and Hybrid can never both quote the same wallet).

### 2.4 The session state machine (enforced in the DO for Hybrid; mirrored on-device for Attended)

```
draft → preparing → awaitingSignature → arming → running ⇄ paused
running/paused → stopping → reconciling → settled
alarm@endsAt → stopping                       (auto time-box)
any → error   (recoverable: back off & retry, or surface)
kill → killed (terminal: key destroyed, secret wiped)
scheduled → (alarm@startAt) → arming …        (Hybrid only; no phone present)
```

---

## 3. The integrated layers

### 3.1 Strategy engine + the six reference-price models  *(owner: quant; consumed by infra/risk/reco/ux)*

The engine is a set of **pure, Sendable, O(levels), I/O-free** functions that emit the exact `[MMLevel]` ladder the
executor places. It **extends** `MMStrategy.levels(mark:)`; the two existing branches (`midLevels`, `gridLevels`)
become two of six models and the shared helpers (`curveWeights`, `bracket`, `deployed`, `perSide`, the fee floors
`midFloorBp = 2.5`, `gridFloorBp = 6.8`) are reused verbatim.

**Reference price.** Quote off **microprice** (size-weighted fair value) for Mid/Blend, **mid** for the grid
family, and use **mark** only for stop-loss / liquidation reference (the keeper triggers on mark). Vol scales by
√-time: `σ_h = σ_1m · √(h/60)`.

**The six models (exact math in the quant section §2, kept as-is):**

| Model | Quotes | Best regime | Reset knob | Profit driver | Loses in |
|---|---|---|---|---|---|
| Mid (+bias) | both sides @ micro/mid | any (volume-max) | recenter on drift | spread capture / high fill rate | trend |
| Grid | buy-low / sell-high | sideways | **Grid Reset** θ_grid | `step − fee` per cycle | trend (stuck rung) |
| RGrid | trend-side maker + **trailing TP** | trend / volatile | **TP Reset** θ_tp | winner rides | chop (whipsaw) |
| DGrid | Grid⇄RGrid by vol/ER | adapts | active mode's | right forecast + vol-optimal spread | fast regime flip |
| Blend | Mid ⊕ Grid (β) | mixed | tighter of the two | volume + swings | trend |
| Signal | Mid kernel, RSI skew/gate | ranging extremes | RSI change | fade extremes | pinned-RSI trend |

**[RESOLVED — RGrid]** Perpl has **no stop-entry primitive** (only reduce-only Close triggers). RGrid is
implemented **maker-only with a discrete trailing take-profit** (ratchet the reduce-only Close by θ_tp in the trend
direction, never backwards). Confirm the interpretation against tread.fi (open decision). The trailing re-issue has
an unprotected gap between cancel-old and place-new — floor θ_tp and, if amend of a trigger is supported, amend it
instead.

**[RESOLVED — DGrid switch]** Combine both proposals: primary switch on `volZScore` with a **±0.5σ dead-band**
(anti-flap), **gated by ER** (go RGrid only if ER ≥ 0.35; else Grid). Optimal half-spread from vol:
`δ* = max(midFloorBp, k_σ·σ_τ)` with `k_σ ≈ 1.2`. On a switch, **cancel+replace** (geometry changes), not amend.
Validate the dead-band against real BTC/MON tapes before locking (open decision).

**Volume ↔ Duration ↔ Participation (quant §3, one correction applied):**
- `V_target` default `= 20 · margin`. Participation `p`: **Aggressive 10% / Normal 5% / Passive 1%** (fix the ux
  enum which had Passive 2%).
- **[RESOLVED — V24 units, was "open question", now a fixed bug]** `PerplLiveState.volume24h` is **base units**
  (`dv / sizeScale`, confirmed at `PerplFeed.swift:241` and `PerplService.swift:157`). Auto-duration needs USD:
  **`V24_USD = volume24h · mark` — implement now.** Then `D = clamp(round(1440·V_target/(p·V24_USD)), 10, 1000)`
  min. Reproduces tread.fi's 10/20/100-min ladder. When D clamps to 1000, compute and **display the *effective* p**
  and warn if it exceeds the chosen preset (silent participation overshoot otherwise).
- **[RESOLVED — closed-loop volume control]** (quant review #12) The child-clip schedule is **not** open-loop. A
  proportional controller tracks `volume(t)` vs `plan(t)`: behind → step spread toward touch / grow clip within
  `perSide` **and the rate governor**; ahead → widen. This is the participation *targeting* tread.fi/Arbital do, and
  it must obey the rate governor (§3.2) so chasing volume can't blow the budget.

**Inventory convergence (shared with risk):** skew the reference by `−γ·I` toward flat (this is the
Avellaneda-Stoikov reservation-price skew — **adopt AS-lite**: reservation skew + vol spread; **defer** full
κ-GLFT intensity calibration, which the ~2 ops/s ceiling doesn't justify). Hard one-sided cutoff at `|I| ≥ I_max`
(quote only the reducing side; hysteresis). Guarantees cumulative buy ≈ sell volume = genuine two-sided liquidity.

**`MMStrategy` gains** (Codable, back-compat: decode legacy `mode` "mid"/"grid" → `refModel`): `refModel`,
`volumeTarget`, `participation`, `durationMin`, `startedAt/endsAt`, `gridResetPct`, `tpResetPct`, `blendWeight`,
`rsiPeriod`, `proAS`+`gamma`, runtime caches (`anchorPrice`, `tpAnchor`, `activeSubModel`, `requoteCount`), and the
risk/analytics fields listed in §3.3/§3.4.

### 3.2 Perpl order lifecycle + rate budget  *(owner: infra; the executor spine)*

The lifecycle is a **pure state machine, `PerplExecutionEngine` (DyorKit actor)**, protocol-injected over a
`PerplTradeClient` (the one authed socket) and a `PerplReads` port (on-chain + signed-REST truth). It runs
**identically on device (Attended) and, re-implemented in TypeScript, in the DO (Hybrid)** — the Swift is the spec.
Making it pure + mockable is a real upgrade over the `@MainActor`-timer `MMWatcher` and gives device/worker parity.

**Four DyorKit prerequisites (Phase 0 — every downstream loop depends on them; all are confirmed-real gaps):**

1. **Post-only (`fl:1`) is NOT wired — CRITICAL, confirmed by all reviewers.** `PerplOrders.entry` emits
   `fl: ioc ? 4 : 0`, so today's v1 maker ladder rests as **GTC and can cross → taker fees**, silently inverting
   the economics and enabling self-match. Fix: add `enum OrderFlag {gtc=0, postOnly=1, fok=2, ioc=4}`; replace
   `PerplOrderFrame.ioc: Bool` with `flags: OrderFlag`; `json()` emits `"fl": flags.rawValue`; `entry` maps a limit
   maker leg to `.postOnly`. Handle **post-only reject** as a first-class state (reprice one tick inside best, ≤2
   retries from the burst reserve; never blind-resubmit). Whether reject is an `mt:3` non-zero code or an
   admit-then-kill on `mt:24` is an open API question — handle both defensively.
2. **`mt:24/26/27` are dropped — CRITICAL for honest accounting.** `PerplTradeClient.handle` parses only
   `mt:19/21/3`. Add `case 24` (→ `onFill`: stable fill id, mkt, oid, side, price, size, **fee**, maker flag,
   **pid**), `case 26/27` (→ `onPosition`: pid for `lp`). **This is the single authoritative fill/volume source.**
3. **`t:7` Change (amend) builder is missing.** Add `PerplOrders.change(oid:price:size:market:accountId:postOnly:)`
   (wire `t:7`, `lb:0`, carries new p/s + oid) and `PerplTrading.amend(...)`.
4. **`placeAll` stops on first reject** — truncates the ladder on one post-only reject. For independent ladder
   levels, submit per-frame and **collect all acks** (pipeline, resolve by `cid`); keep stop-on-first-reject only
   for a true entry→trigger bracket.

**[RESOLVED — protect-on-fill vs pre-linked bracket, the most important safety call]** (infra review C1 + quant
review #7)
- **Attended (on-device):** place the **`tr`-linked bracket at placement** (`submitBracket`, `linkedRequestId =
  entryRq`). Protection is armed the instant the entry trades, **server-side by the Perpl keeper, even when the app
  is suspended**. Accept the cancel+replace cost this implies — Attended sessions are short and the safety net is
  non-negotiable. Protect-on-fill on-device is a **regression** (a fill while suspended = naked position) and is
  rejected.
- **Hybrid (DO):** use **protect-on-fill** — bare post-only entries (amend-cheap), then on the `mt:24` fill place
  the reduce-only TP/SL linked by **position id `lp`** for the filled size, same tick. Safe because the DO is
  always alive. Backstop: if the protect place fails, **market-flatten that filled leg** immediately.
- Precise field usage: **entry-time bracket = `tr` (linkedRequestId); post-fill reduce-only Close = `lp`
  (linkedPositionId).** Do not conflate them (arch review #6).

**[RESOLVED — amend economics are not assumed]** (infra review C2, risk review #11) `t:7` has never been sent from
this app. **Default the budget model to the pessimistic cancel+replace column** until amend is empirically validated
on Perpl (same oid? single forwarded request? preserves fl:1 / reduce-only? preserves tr/lp?). Amend is a
Phase-2/3 optimization gated on that confirmation, not a Phase-1 promise. In the DO, protect-on-fill's bare entries
make amend genuinely cheap *when* it's validated.

**Requote loop (the mechanism; quant supplies the parameters):**
```
tick():
  reconcileGate()                     # a failed read is NOT "flat" — bail (the invariant, elevated to hard rule)
  desired = strategy.levels(ref)      # quant: microprice/mid + reference model + inventory skew
  live    = SlotMap (WS state, verified on-chain every Nth tick)   # single source of truth while loop owns market
  for each desired slot:
     missing     → place (post-only; pinned until oid adopted, <2s)
     side-flip / geometry change / partial fill → cancel+replace
     price/size drift > driftBp (and amend validated) → amend (t:7)
     else        → leave (0 ops)
  cancel unpaired/excess live orders (UNFILLED ENTRIES ONLY — never a live position's reduce-only trigger)
  ops = prioritise then cap to token bucket; coalesce (keep only newest target per slot); spill to next tick
```
- **Slot identity, not price bucket** (arch review #7). Key the ledger `slotKey = sessionId:mkt:side:rungIndex:
  generation`; `targetPrice`/`targetSize` are mutable fields. Amend-in-place keeps the same key; reconcile maps
  `oid → slot` cleanly (deterministic tiebreaker on ambiguous side+price+size). This removes the double-place/orphan
  hazard of a price-bucket key.
- **oid discovery:** learn oids from `PerplReads.openOrders` (Multicall, off the WS budget); a just-placed level is
  "pinned" (immovable) until adopted, typically <2 s. If Perpl's WS pushes an OrderUpdate with `oid`, wire it and
  drop the pin (open API question).

**[RESOLVED — the rate governor is real and shared]** (every review: quant #11, risk #3, infra C3, ux H3, arch #10)
A single **token bucket** in `PerplTradeClient` (device) and the DO (worker) that **every** write draws from
(place/amend/cancel/protect/keep-alive/de-risk/kill). Budget to a **ceiling of ~105–110, not 120** (Perpl's limit
is "~120"; a rolling window trips on the 121st, and sign-in/keep-alive-jitter/reconnect-burst all cluster at
reconnect): **steady ~85–90/min, burst reserve ~15, ~5/min for connect + keep-alive jitter.** Priority order:
**P0 kill (flatten-first) > P1 protect-on-fill > P2 inner levels > P3 outer levels > P4 reseed.** On backpressure:
serve by priority, coalesce, auto-widen `driftBp` (graceful degradation → "Throttled" to ux), and — critically —
**cross-session fair-share** so a volatile market can't starve another market's quotes into being picked off
(cancel a session's exposed side rather than leave it resting mispriced). Cap the token bucket to capacity on
foreground-wake (no token flood after suspension).

**Fills & truth (never fabricate, never lose):** authoritative sources in order — (1) `mt:24`, (2) signed-REST
`/v1/trading/fills` (backfills socket-down gaps), (3) corroborated on-chain delta. An order **leaving the book is
only a reconcile hint, never a booked fill.** Idempotent **FillLedger keyed by stable fill id** dedups the
WS-then-REST double sighting. **[RESOLVED — retire book-diff fill detection]** (ux C2/C3, quant #8, risk #1) The
moment a requote loop is active, `MMWatcher`'s "a resting price left the book ⇒ a fill" detection is **disabled** —
under requoting a vanished price is usually a cancel/amend, which would fabricate fills and inflate the headline
volume (making Cost/$1M look artificially low). **One execution owner per session**; the slow on-chain tick becomes
**read-only reconciliation that never places** (kills the stale-read double-place race).

**Crash/idempotency:** single-writer lease (`wallet:accountId`), write-ahead session log (intent → outcome),
reconcile-before-act (never place a fresh ladder blind; adopt existing resting orders), durable `rq` re-seed
`= max(persisted, lfr)`, idempotent teardown (cancel/flatten/verify-clean in a loop). Fresh Monad RPC (**rpc1**) is
a **hard prerequisite** — public RPC's ~24h-stale reads would corrupt oid adoption and fill-by-delta.

### 3.3 Risk, margin, kill-switch + compliance  *(owner: risk)*

Pure math in `DyorKit/.../Perpl/PerplRiskMath.swift` (Sendable, unit-tested, TS-ported for the worker so device and
DO trip identically). App-side `MMRiskMonitor` (fast loop), `MMKillSwitch`, `MMPreflight`, `MMConsentSheet`.

**Margin maintenance — health ladder (de-risk BEFORE liquidation):**
- Leverage clamp with bias haircut: `f_i' = f_i·(1 + 0.20·|bias|)`; `L_cap = max(1, floor(1/f_i'))`. **[RESOLVED —
  cap automated-MM leverage below the manual cap** (risk review #8) so a single candle can't jump the whole ladder
  into liquidation before a 2-read confirmation + taker flatten completes.
- **[RESOLVED — primary gauge = Distance-to-Liquidation against the stored on-chain `liquidation`** (entry-based
  `mmr`), not the mark-based health number, which measured a different thing and crossed thresholds inconsistently.
  De-risk bands are a **function of leverage** (guarantee ≥ N ticks of reaction given cadence + vol). At high
  leverage, place the native SL *inside* the RED band so the keeper, not the app loop, is the primary
  liquidation-avoider.
- Ladder: GREEN (normal) → AMBER (widen ×1.5, cut new size 50%, stop adding to losing side) → ORANGE (cancel
  furthest 50% of **unfilled entries only**, skew-to-flatten, reduce inventory) → RED (reduce-only market-close,
  cooldown 60 s; two REDs ⇒ Max-Loss kill). AMBER/ORANGE fire on one confirmed read; **RED/kill require two
  confirmed reads OR one read where `unrealized` alone already breaches**; a **failed read never de-escalates and
  never trips** (the invariant). **Never auto-offer "add margin"** to defend a losing MM inventory.

**Max-Loss kill:**
```
MaxLoss$ = (maxLossPct/100)·capital        // tread.fi: 15%×$100 = $15 (default 15%, confirm per market)
netPnL   = realized + unrealized ; trip when netPnL ≤ −MaxLoss$
```
- **[RESOLVED — scope the kill signal to the strategy's own market** (risk review #5). AUSD balance is account-wide
  and shared with app.perpl.xyz tabs / other positions; a deposit masks a loss, a withdrawal fakes one. Use
  **`unrealized` on the market (mark × known size) + realized from the session's own attributed `mt:24` fills**;
  keep balance-delta only as a coarse secondary, and suppress trips on balance jumps not explained by fills.
- **[RESOLVED — check on every mark update, not only on the tick** (arch review #9): between a 5–30 s tick a fast
  move can blow past MaxLoss. Subscribe the executor (DO and Attended) to market-data mark and evaluate max-loss on
  each mark update. **Kill sequence: flatten-first (one net Close per market, from the burst reserve, priority over
  cancels) → verify flat → cancel residual → forwarding-off (phone).** Fold the taker+slippage cost of every
  flatten (IOC 150 bps) into the live `costPer1M` (it's not all-maker on a stop/expiry).
- **[RESOLVED — drop the "whole-inventory catastrophe SL at Start"** (risk review #4): there is no position at Start
  (entries are resting), the filled size/price is unknown, and a reduce-only order larger than the real position is
  rejected. The real app-dead net is the **per-level native SLs armed to each fill** (Attended: `tr`-linked at
  placement; Hybrid: on-fill). A session-level catastrophe stop must be (re)amended as inventory accrues, which
  needs a live device/worker — it is **not** a both-offline net.
- Three-tier authority: device online → `MMRiskMonitor`; worker online → DO evaluates the same `RiskLimits` and runs
  the same teardown (both idempotent, lease prevents double-flatten thrash); both offline → per-level native TP/SL +
  DO deadline flatten at `endsAt`.

**Session-level Take-Profit (belt-and-suspenders):** **[RESOLVED — use price-move semantics** (risk review #6), not
margin-return: close only when `mark` crosses `entry·(1 ± tpPct/100)` **and** the native TP is confirmed not
resting. The margin-return form fired at `tpPct/L` (~0.1% at 10×), turning the backup into the primary exit and
over-trading.

**Circuit breakers** (detect+confirm → action → recover, all rate-budget-aware): volatility spike (>4σ), mark/oracle
staleness (>15 s or |mark−oracle|/oracle >1%), funding blowout, spread blowout (>3× median), repeated post-only
rejects (≥3), socket loss (>20 s; 3401 never-retry, 1008 conn-cap back-off 30 s), RPC/read failure (abort tick,
change nothing), worker-heartbeat loss (hybrid). **[RESOLVED — funding units** (risk review #10): normalize
`fundingRatePct100k` to **%/hr** before comparing (needs the funding-interval length — external need). Two
simultaneous breakers ⇒ escalate one level. Every fire logs a `BreakerEvent` (shown in the event log).

**Compliance (brief §0 — structural, not cosmetic):**
- **Post-only mandatory** (the anti-wash control: a crossing maker is rejected, not matched).
- **Self-match prevention:** engine invariant `max(own bids) < min(own asks)` enforced **pre-wire**, and requote
  ops **sequenced** so the book never transiently self-crosses. **[RESOLVED — triggered TP/SL are taker legs**
  (risk review #9) that can self-match the own resting ladder on a thin book (post-only can't cover them): gate/limit
  triggered closes when the own ladder sits in the close's marketable range, and TCA surfaces a
  `selfMatchSuspectRatio`. **Confirm Perpl STP flag on `mt:22`** and set it if present (external need — elevated to a
  compliance dependency).
- **Honest economics surfaced everywhere** Cost/$1M ≥ $250 floor unless a *confirmed* rebate is a separate line;
  never a projected-profit promise; realized PnL labeled "collateral change since start (net of fees)."
- **Consent sheet `MMConsentSheet`** (required checkboxes, persisted per wallet + Supabase for Hybrid): fee-cost
  understanding, liquidation/Max-Loss understanding, no-wash-trading attestation, Perpl ToS + jurisdiction
  acknowledgment, not-investment-advice, and (Hybrid only) the trade-only-key authorization with expiry + **Revoke
  now** (= destroy key + stop executor; the phone can additionally fire forwarding-off).

### 3.4 Indicators + recommendation + pre-trade analytics + TCA  *(owner: reco; decision-support only)*

All on-device, pure, in `DyorKit/.../Quant/` (`Indicators.swift`, `MMMarketStats.swift`/`IndicatorEngine.swift`,
`MMEcon.swift`, `PreTradeAnalytics.swift`, `Recommendation.swift`, `TCA.swift`). **Uses only the unauthenticated
market-data WS, sharing the one `PerplFeed`** — zero of the 4-socket cap, zero of the 120/min trading budget.

- **Indicators:** RSI(14) Wilder, realized/EWMA/Parkinson vol + one-step forecast, ATR(14), Kaufman ER, ADX(14),
  regime classifier (quiet/ranging/trendingUp/Down/volatileChop + confidence), order-book imbalance, **microprice**
  (the Mid/Blend reference), weighted mid. **[RESOLVED — candle source** (reco review P2): the WS `candles@` frame
  (guessed mt 11/12) is **not** in `PerplFeed` and unverified — **use periodic REST candles** (`PerplService.candles`,
  1/min, unauth, off-budget) for warmup and rolling recompute; add a WS candle parser only if the real mt code is
  confirmed. Throttle book-driven recompute to a hard ≤2/s coalescing timer.
- **[RESOLVED — worker parity** (reco review I1): the Cloudflare Worker runs JS/WASM, not Swift. **Port the pure
  indicator + econ + risk math to TypeScript, pinned to shared golden test-vectors** so client and worker cannot
  drift. (WASM is the heavier alternative; TS + vectors is the recommendation.)
- **Pre-trade analytics (tread.fi parity):** Available/Required margin (+ insufficient-margin gate), Max Loss,
  auto-Duration, est. fills/round-trips, attainable volume (participation ceiling ∧ capital-cycling capacity),
  **projected Cost/$1M for the current regime**, break-even spread, liquidation price, plain-English go/caution/no-go.
  **[RESOLVED — the projected EV must include the losing branch** (reco review C1): the capture-only formula was
  structurally optimistic (it never debited the `(1−pClose)` stop-out/reset losses), which flipped the sign and read
  as "free money." Add an explicit `expectedLossUsd = (lossBpPerRT/1e4·avgLegNotional)·estRoundTrips·(1−pClose)` line
  and show capture / fees / **expected stop-out loss** separately. Seed `pClose = 0.6`, `a = 8 bp` as honest defaults
  (open decision), recalibrate from live fills.
- **[RESOLVED — TCA Cost/$1M must be net of fees** (reco review C2): `realizedNetPnL = positionHistory(dpnl+fnd) −
  Σ PerplFill.fee + rebates`; `costPer1M = −realizedNetPnL/volume·1e6`. Confirm whether Perpl `dpnl` is gross or net
  of trading fees (external need — a $250/$1M swing). Count **every leg** (entry + keeper close) from the fills feed,
  not the entry-only book diff. TCA also surfaces `selfMatchSuspectRatio`, markouts (best-effort foreground;
  whole-session only under the worker tape subscription), maker-fill ratio, PnL attribution.
- **Recommendation layer:** regime → model + numeric recipe (spread/participation/leverage/TP/SL/reset/bias) from a
  risk appetite, each carrying a fixed **decision-support-not-advice disclaimer**. Presets store the *appetite* and
  re-derive against live indicators at Apply time. Persist local-first (`RecoPresetStore`, mirrors `MMStore`) +
  Supabase `mm_presets` sync when wallet-auth lands.

### 3.5 UX + sessions table  *(owner: ux)*

`StrategyView` → Market Making now lands on **`MMSessionsView`** (a table of sessions with New/Start on top), not a
fresh form. Config in **`MMConfigView`** (reworked `MarketMakingView`): recommendation banner → presets → account
(read-only unless Perpl exposes sub-accounts) → pair (with 24h volume) → margin+leverage (`Slider 1…marketMax`) →
volume target (+ ×10/×20/×50 chips) → participation→auto-duration → reference-model picker (2-col chips + blurbs +
conditional fields) → spread (with fee-floor footer) → SL/TP → ladder + schedule preview → pre-trade analytics card
(with continuous insufficient-margin gate) → honest-economics disclosure → biometric-confirmed Start (+ Hybrid
key-consent step). Sessions table: **Active · History · Scheduled · Analytics · Campaigns**, columns Mode · Pair ·
Account · Volume · Fees · PnL · **Cost/$1M** · Spread · Filled % · Status, `List` on compact / `Table` on regular
width, with clone/cancel/restart/share row actions and a share card that shows cost, not just volume.

**[RESOLVED — Scheduled/Campaigns honesty** (ux open decision): they run unattended only under the worker (Phase 2).
In Phase 1 (Attended-only) they are **reminder-only** (local notification to open the app), with copy that never
overpromises. We **keep the tabs** (we do ship the worker in Phase 2) rather than hiding them.

**[RESOLVED — filledPct** = schedule/execution adherence (executed slices / planned slices to-date); **volumePct**
= volume/target shown separately. Clamp the fallback so it doesn't read ~100% at t≈0.

**[RESOLVED — Pause semantics** (ux H2): explicit foreground **Pause** = cancel resting entries + hold position
(native TP/SL stay armed). **App backgrounded in Attended mode is NOT "Paused"** — orders can't be cancelled in the
~5–30 s background grace and resting orders + TP/SL stay live; label it **"Running unattended — quoting paused,
resting orders live."** Never imply the aggregate Max-Loss kill is armed while backgrounded on-device (it runs only
foreground, or on the worker).

**[RESOLVED — market data is consumed natively** (ux M4): market-data WS works from native with no Origin; the
foreground cockpit uses `PerplFeed` directly. The worker bridge is reserved for the authenticated executor +
background push, not for foreground market data.

---

## 3b. THE LIVE STATUS BAR — consolidated spec

Two coordinated surfaces backed by one `@Observable @MainActor MMSessionManager` (which holds cached `MMLiveMetrics`
+ `MMHealth`; the bar reads cache and does no network of its own):

- **Compact `MMLiveBar`** — mounted app-wide in `RootView` via `safeAreaInset(.bottom)` on the `TabView` (not a
  fragile manual offset — ux L3), height ≈ 56 pt, `.regularMaterial`, visible whenever a session is running/paused,
  the "Now Playing" of trading. One line, left→right, priority under Dynamic Type truncation:
  1. **Mode glyph + pair** (`allocationSpot` identity) — never dropped.
  2. **Volume `ProgressRing` + %** (Brand) — the "am I done yet" — never dropped.
  3. **Remaining time** — `Text(timerInterval:countsDownFrom:)`, self-ticking, zero timer code; icon-only at AX3+.
  4. **Net PnL** — signed, monospaced, Positive/Negative; drops before time.
  5. **Risk pip** — one dot, Attention when `drawdownPct ≥ 0.7` OR `distToLiqPct < 5%` OR connection degraded,
     Negative when kill/liq imminent, hidden when healthy; drops last.
  Tap → `MMStatusView`; long-press → Pause/Resume, Stop & Flatten, Share. Reflows to two lines at AX sizes.

- **Expanded `MMStatusView`** — pinned hero header (the 5 glances, larger: `● Quoting` pulse, `⏱ left · elapsed`,
  Volume ring `62% $9,300/15k`, Net PnL split realized/unrealized), a metric grid (`MetricTile` 2-up):
  Cost/$1M · Fees so far · Filled % · Resting orders · Live spread · Next requote (`CountdownRing`); a bipolar
  `SkewBar` (inventory); a **pinned risk footer** (margin-ratio arc, distance-to-liquidation, distance-to-Max-Loss
  bar filling toward the −$ kill); a connection/worker health row (`Trading ● · Market data ● · Worker ●` with real
  `PerplClose`/`failureMessage` on tap); the fills feed; and a bottom action bar (Pause · Stop & Flatten · Share,
  becoming Clone · View report when terminal).

**Every live datum → source → cadence:**

| Datum | Source | Cadence |
|---|---|---|
| mid / mark / live spread | `PerplFeed` `order-book@id`, `market-state@143` (native, direct) | 2 Hz coalesced |
| unrealized PnL | mark × known position size (primary); on-chain reconcile (secondary) | 2 Hz / 5–8 s |
| realized PnL, fees (precise) | session's own `mt:24` fill fees; balance-delta secondary | on fill / 5–8 s |
| volume, fills, filled % | **`mt:24` only** (book-diff retired under requoting); planned slices | on fill |
| resting orders, next requote | SlotMap / `openOrders`; requote cadence | 5–8 s / 1 Hz local |
| inventory, skew | `positions` (reconcile) + `mt:24` deltas | 2 Hz / 5–8 s |
| margin ratio, liq price, DTL | stored on-chain `liquidation` + position (Multicall, **rpc1**) | 5–8 s |
| Max-Loss drawdown / kill | market `unrealized` + session realized vs `MaxLoss$` | **every mark update** |
| connection/worker health | `PerplTrading.status`, WS heartbeat, worker `/health` | event / 15 s |
| countdowns / elapsed | local clock `TimelineView` | 1 Hz |
| Cost/$1M | `−totalPnL·1e6/max(volume,1)` — Brand ≤$250, Attention >$250, Positive <0 | 2 Hz |

**Cadence policy:** foreground dashboard open → 2 Hz WS + 5 s on-chain reconcile; bar-only → 8 s. **Hybrid replaces
the polls with the worker SSE stream** (reconnects on foreground via `Last-Event-ID`), keeping a 30 s on-chain
reconcile fallback.

**Backgrounded / closed behavior:**
- **SSE does not deliver in the background** (a `URLSession.bytes` stream suspends with the app — arch review #1).
  It reconnects cleanly on foreground; it is **not** the background alert channel.
- **The background alert channel is APNs push from the worker** (max-loss trip, error, fill-of-note, completion,
  key-expiry) — a **hard prerequisite** for the "phone in pocket" value prop, not a footnote. Until APNs is wired, a
  backgrounded phone learns nothing until reopened (the *session* is still safe — the DO is authoritative — only
  *notification* is gated).
- **Live Activity / Dynamic Island** (`DyorHQWidgets` extension): Attended mode updates the Activity while
  foregrounded with a self-ticking `Text(timerInterval:)`; Hybrid mode requests `.pushType(.token)` and the worker
  pushes `ContentState` via APNs Live Activity, throttled to **material events + a 60 s floor** (volume 25/50/75/100%,
  risk >70% max-loss, kill, requote-failing, finished). Confirm ActivityKit rate limits (open decision).

---

## 4. Component / file map

### 4.1 DyorKit (pure Swift; runs on device, TS-ported to the worker)

| File | Change | Contents |
|---|---|---|
| `Services/Perpl/PerplTradeClient.swift` | **extend** | parse `mt:24` (`onFill`), `mt:26/27` (`onPosition`); `OrderFlag` on `PerplOrderFrame`; pipeline `place/placeAll` (collect all acks); shared **token-bucket rate governor**; persist `rq_hi` in `nextRequestId()` |
| `Services/Perpl/PerplOrders` (in PerplTradeClient/PerplModels) | **extend** | `entry` honors `postOnly → fl:1`; new `change(oid:price:size:market:accountId:postOnly:)` (t:7, lb:0) |
| `Services/Perpl/PerplExecutionEngine.swift` | **new (actor)** | SlotMap, TokenBucket, FillLedger (WAL), `PerplReads` port; `start/requoteTick/onFill/onPosition/reconcile/killSwitch` — the pure lifecycle spec |
| `Services/Perpl/PerplRiskMath.swift` | **new** | leverage cap+bias, health, DTL (on-chain liq), max-loss trip, inventory skew, session-TP, required margin, crosses-book — Sendable, unit-tested |
| `Services/Quant/Indicators.swift` | **new** | RSI/vol/EWMA/Parkinson/ATR/ER/ADX/regime/OBI/microprice — pure |
| `Services/Quant/MMMarketStats.swift` / `IndicatorEngine.swift` | **new** | REST-candle warmup + rolling recompute; `@Observable` publish (throttled) |
| `Services/Quant/MMEcon.swift` | **new** | the fee/rebate/Cost-$1M single source of truth |
| `Services/Quant/MMQuoteEngine.swift` | **new** | `RefModel`, `QuoteInputs`, the six model builders, `resetDecision`, AS-lite core |
| `Services/Quant/MMSchedule.swift` | **new** | participation presets, `autoDuration` (V24·mark), child-clip, closed-loop volume controller |
| `Services/Quant/PreTradeAnalytics.swift` / `Recommendation.swift` / `TCA.swift` | **new** | pure estimate/reco/TCA engines (EV with loss branch; net-of-fees Cost/$1M) |

### 4.2 App (ios/DyorHQ)

| File | Change | Contents |
|---|---|---|
| `Strategy/MarketMakingStrategy.swift` | **extend** | `MMStrategy` gains `refModel`, schedule, model knobs, risk `limits`, runtime caches (§3.1); legacy `mode` decode |
| `Strategy/MMSession.swift` | **new** | `MMSessionConfig/Status/State`, `MMReferenceModel/MMParticipation/MMBias` enums; `MMSession` embeds `MMStrategy` |
| `Strategy/MMSessionManager.swift` | **new (@Observable @MainActor)** | the one UI state hub: wraps `MMSessionClient` (Hybrid) + on-device engine host (Attended) + `MMRiskMonitor` + health + Live Activity |
| `Strategy/MMSessionClient.swift` | **new** | worker REST (`prepare/start/pause/resume/stop/kill/status`) + SSE `/stream`; holds Supabase JWT |
| `Strategy/MMWatcher.swift` | **evolve** | app-lifecycle bridge (foreground↔background) + Attended engine driver; **flat-recycle retired under continuous requoting**; single `MMStore` writer discipline |
| `Strategy/MMExecutor` (in MMWatcher) | **fold** | `place/stop` become `engine.reconcile/killSwitch` drivers; de-risk cancels filter to unfilled entries only |
| `Strategy/MMRiskMonitor.swift` / `MMKillSwitch.swift` / `MMPreflight.swift` | **new** | fast risk loop, idempotent SAFE teardown (dual kill), pre-Start gates |
| `Strategy/MMConfigView.swift` | **rework of** `MarketMakingView.swift` | full config surface (§3.5) |
| `Strategy/MMStatusView.swift` | **rework** | expanded dashboard (§3b) |
| `Strategy/MMLiveBar.swift` | **new** | app-wide compact bar (§3b) |
| `Strategy/MMSessionsView.swift` / `MMSessionRow.swift` | **new** | tabs + table + rows |
| `Strategy/MMPreTradeAnalyticsCard.swift` / `MMRecommendationBanner.swift` / `MMSchedulePreview.swift` / `ReferenceModelPicker.swift` | **new** | config sub-views |
| `Strategy/MMConsentSheet.swift` / `MMRiskBar.swift` / `MMPreflightSheet.swift` | **new** | consent + live risk bar + pre-trade sheet |
| `Strategy/MMPreset.swift` / `RecoPresetStore.swift` / `MMSessionStore.swift` | **new** | presets (appetite-based) + session history persistence |
| `Design/MetricTile.swift` / `ProgressRing.swift` / `CountdownRing.swift` / `SkewBar.swift` / `RiskGauge.swift` | **new** | shared components (promote the private `StatTile`) |
| `Wallet/PerplTrading.swift` | **extend** | connection `mode {.executor,.cockpit}`, single-writer lease, `onFill/onPosition` fan-out, `disableForwarding` (the on-chain kill) |
| `App/BackgroundTasks.swift` | **new** | BGAppRefresh + BGProcessing (status poll + reconcile + local notify only — never trading) |
| `DyorHQWidgets` (extension target) | **new** | `MMActivityAttributes.swift` + `MMLiveActivityWidget.swift` (add to `project.yml`, `xcodegen generate`) |
| `App/RootView.swift` | **extend** | mount `MMLiveBar` via `safeAreaInset(.bottom)`; `dyorhq://mm/stop/:id` deep link |

### 4.3 Worker (`worker/`, greenfield Durable Object — today it is a 73-line stateless market-data proxy)

`worker/mm/`: `router.ts` (routes `/api/mm/*` to the DO, verifies Supabase JWT `wallet_address`), **`PerplSocketDO.ts`**
(one authed socket + one market-data socket, rq counter, key store, SlotMap, FillLedger/WAL, single-writer lease,
`SessionRunner[]` (cap 1 @ launch), `alarm()` = requote+reconcile+expiry, SSE fan-out), `perplTrading.ts` (TS mirror
of the wire: mt:29 sign-in, mt:22 build with `fl:1`/`lb:0`/`tp/tpc/lp`, mt:1 keep-alive, inbound mt:3/24/26/27/19/21),
`perplAuth.ts` (Ed25519 via WebCrypto: payload/enroll/revoke), `requote.ts` (TS port of the engine + quant ladder),
`reconcile.ts` (Monad RPC + Multicall3 reads via **rpc1**), `budget.ts` (token bucket, ~105–110 ceiling),
`crypto.ts` (AES-GCM wrap with `SESSION_WRAP_KEY`), `supabase.ts` (service-role mirror), `auth.ts` (JWT verify),
`push.ts` (APNs alerts + Live Activity). `quant.ts`/`riskMath.ts`/`econ.ts` = TS ports pinned to golden vectors.

**Endpoints:** `POST /api/mm/session/prepare|start`, `POST /api/mm/session/:id/pause|resume|stop|kill`,
`GET /api/mm/session/:id/status`, `GET /api/mm/session/:id/stream` (SSE), `GET /api/mm/wallet/:addr/sessions`,
`POST /api/mm/wallet/:addr/panic`, `GET /api/mm/health`. `wrangler.toml` adds DO binding `PERPL_SOCKET_DO` +
migration (Workers **Paid** plan).

### 4.4 Supabase (migration `10_market_making.sql`; 08/09 already exist)

`mm_sessions` (one row/session; config jsonb, state, do_id, **pubkey + fingerprint + expiry only — never the
secret**, volume/pnl/fees/cost_per_million/filled_pct, timestamps), `mm_fills` (from mt:24 — side/price/size/notional/
fee/realized_pnl/markouts), `mm_events` (arm/requote/pause/error/maxloss/kill log), `mm_presets` (owner-writable
appetite configs). RLS by lowercased wallet via `public.app_wallet()`; reads owner-only; writes service_role
(the worker) except `mm_presets` (owner). Plus `mm_lifetime_summary()` RPC. Needs the **`wallet-auth` Edge Function**
(not yet built — external need: JWT signing secret or enable Web3/SIWE); until then Analytics runs offline from local
`MMSessionStore` and syncs when auth lands.

---

## 5. Phased delivery roadmap

Each phase is independently shippable and testable.

### Phase 0 — DyorKit prerequisites (lands inside Phase 1; unblocks everything)
`fl:1` post-only wiring + post-only-reject handling; `mt:24/26/27` parsing (`onFill`/`onPosition`); `t:7` amend
builder; `placeAll` collect-all-acks; durable `rq` persist; the **shared token-bucket rate governor**; `MMEcon.swift`.
**Test:** `swift test` against a mock socket for the pure engine (place/amend/fill/reconcile/reject); verify `fl:1`
frame bytes and `lb:0`; golden vectors shared with the TS port.

### Phase 1 — Attended (on-device, fully self-custodial) — the first shippable product
Key stays in Keychain; runs foreground-only. Six reference models; microprice/mid quoting; `tr`-linked bracket at
placement (app-dead safety net); cancel+replace requote (amend only if validated); volume-target + participation→
auto-duration + closed-loop controller; real-time Max-Loss kill (foreground, mark-driven, flatten-first); health/DTL
ladder + circuit breakers + consent + compliance guards (post-only + self-cross refusal); pre-trade analytics
(EV with loss branch), recommendation, presets; the full config screen; the **LIVE STATUS BAR + expanded dashboard**
(foreground); sessions table (Active/History/Analytics from local `MMSessionStore`, Supabase when auth lands);
Scheduled/Campaigns as reminder-only with honest copy. Cost/$1M everywhere at $250 floor.
**Test on simulator:** all pure-math unit tests; market-data WS + indicators + pre-trade + recommendation + config +
previews + sessions table + bar/dashboard rendering (mock manager); Live Activity in the simulator; SSE client
against `wrangler dev` (for Phase 2 wiring). **Test on device:** real fills (small size), one-click enablement,
biometric Start, native TP/SL firing, on-chain forwarding tx, background suspension realism (verify the loop stops
and native triggers hold).

### Phase 2 — Hybrid worker/DO executor (makes "phone in pocket" real)
**Gate first on the validations:** DO holds a multi-hour outbound authed WS + alarm-cadence + Paid-plan billing;
amend semantics; the fresh RPC (rpc1); APNs credentials. Then: `PerplSocketDO` (one socket, one market-data socket,
lease, WAL, reconcile, expiry), session-key generated in the DO + two-step arm (prepare/start EIP-712), SSE stream,
**APNs push + remote Live Activity**, protect-on-fill (worker), dual kill + `/panic`, Supabase mirror, Scheduled
sessions (DO alarm, no phone present), cockpit mode on the phone (releases its trading socket). Background alerting,
scheduling, and campaigns become real.
**Test:** `wrangler dev` + Miniflare DO for the loop against a mock/testnet Perpl socket; SSE reconnect on
foreground/background transitions; kill-with-worker-down (phone forwarding-off alone stops trading); a full
time-boxed session end-to-end on a real device with APNs push and a locked screen.

### Phase 3 — Advanced models / analytics
Amend-first budgeting (once validated); DGrid vol-switch + AS-lite (reservation skew + vol spread); Blend; Signal
RSI gating; full TCA with worker tape markouts + PnL attribution + `selfMatchSuspectRatio`; Campaigns end-to-end
(repeat/swap-sides); calibrate `pClose`/`kAdv` from accumulated sessions (Supabase aggregate); GARCH/κ-GLFT deferred
(only with a historical fills dataset). **Test:** backtest the DGrid dead-band + volume controller against recorded
BTC/MON tapes; compare projected vs realized Cost/$1M to close the calibration loop.

---

## 6. Consolidated, deduped external APIs / data / credentials to request

**Credentials / infrastructure (Hybrid):**
1. **APNs auth key `.p8` + Key ID + Team ID** for `fun.dyorhq.app` — Worker→phone push (max-loss/error/completion/
   key-expiry) + remote Live Activity. **Hard prerequisite** for the backgrounded-alert value prop.
2. **Cloudflare Workers Paid plan** + `wrangler.toml` DO binding `PERPL_SOCKET_DO` + DO migration (user owns/deploys).
3. **Worker secrets:** `SESSION_WRAP_KEY` (32-byte AES), Supabase **service_role** key, Supabase **JWT signing
   secret** (verify `wallet_address`; also unblocks the still-unbuilt `wallet-auth` Edge Function — or enable
   Supabase Web3/SIWE).
4. **Fresh, low-latency, current-state Monad RPC (rpc1)** for account/positions/openOrders/log-scans — **hard
   prerequisite** (public RPC's ~24h-stale reads corrupt oid adoption, reconciliation, and the kill).

**Perpl protocol confirmations (verify against `PerplFoundation/delegated-account` + `api-docs`):**
5. **Amend `t:7` semantics:** does it keep the same `oid`, is it a single forwarded request, does it move price+size,
   preserve `fl:1` post-only / reduce-only, and preserve the linked `tr`/`lp` bracket? (Decides amend-first budgeting.)
6. **`mt:22 fl:1` PostOnly** accepted + the reject-on-cross signature (mt:3 non-zero code vs admit-then-mt:24), and
   the live maker/taker + builder fee schedule (per-leg or per-order).
7. **Inbound schemas:** `mt:24` fill fields (stable **fill id**, **fee**, maker/taker flag, position id **pid**),
   `mt:26/27` position frames, and **which frame (if any) carries the assigned `oid`** for a resting order.
8. **Self-trade-prevention (STP)** flag on `mt:22` / venue behavior on a crossing same-account order — **compliance
   dependency** (triggered taker TP/SL can self-match the own ladder).
9. **api-key lifecycle:** a revoke/delete endpoint, and whether `enroll` accepts a server-side **expiry/TTL** field
   (decides whether time-box is DO-alarm-only).
10. **First-class delegated-account path** — can the DO trade without the wallet enabling global
    `allowOrderForwarding`? (Would narrow the on-chain kill surface; until confirmed use scope-2 key + forwarding.)
11. **`allowOrderForwarding(false)`** — does it preserve already-resting keeper TP/SL triggers, or disable them?
    (Determines whether the global-kill backstop is safe.)
12. **Maker rebates / MM-reward / points / airdrop program** on Perpl/Monad, and an API to read accrued rewards per
    wallet/session — the only reliable profit offset; flips the honest-economics copy. (Until confirmed `rebateBp=0`.)
13. **Funding interval length (seconds)** — to normalize `fundingRatePct100k` to %/hr for the funding breaker.
14. **Per-market risk params:** `refPriceMaxAgeSec` (getPerpetualInfo idx 8), `order_ttl_blocks`, min-notional
    (DyorKit read change, but confirm the values).
15. **Position-history `dpnl`** gross or net of trading fees (a $250/$1M swing on the TCA Cost/$1M).
16. **`market-state` `dv` scaling** — confirm base vs quote units (implement `V24_USD = volume24h·mark` now regardless).
17. **REST candle resolutions** (need ≥1-min; 1-s helps σ/ER) + rate limit; and whether a **WS candle stream** exists
    and its real `mt` (before relying on it — else stay on periodic REST).

**Cloudflare / hosting confirmations:**
18. **Durable Objects support a multi-hour outbound *client* WebSocket** (not hibernatable) + the active-duration
    (GB-s) billing model + alarm-driven cadence — before promising 1000-min sessions.
19. Whether the trading WS accepts a **batched/multi-order `mt:22`** array (would cut per-frame budget), and whether
    `rq` is validated strictly `> lfr` (mandates the single-writer lease) or is monotonic-tolerant.

**Product / legal:**
20. **Perpl Terms-of-Service URL + jurisdiction/geo policy** for the consent sheet; whether Perpl exposes
    **sub-accounts** (Account picker vs static row); **APNs Live-Activity rate limits** / high-priority warranted.
21. *(Optional, AS-Pro only)* a **historical fills dataset** for offline κ (GLFT) calibration.

---

## 7. Top open decisions (each with recommendation + why)

1. **Concurrent MM sessions per wallet — cap to 1 at launch, or allow many?**
   *Recommend: cap to 1.* The 118/min budget and the single rq sequence are per-wallet; one session keeps the budget
   math and single-writer lease simple. Revisit once fair-share budgeting is proven.
2. **Protect-on-fill vs pre-linked `tr` bracket.**
   *Recommend: worker = protect-on-fill (bare, amend-cheap entries); device = `tr`-linked bracket at placement.*
   Protect-on-fill on a device that can suspend mid-fill leaves a naked position — unacceptable; the worker is always
   alive so it's safe there.
3. **Amend (`t:7`) budgeting.**
   *Recommend: default to the pessimistic cancel+replace column; treat amend as a Phase-2/3 optimization gated on live
   validation.* Amend has never been sent from this app; if Perpl implements Change as internal cancel+replace the
   optimistic cadence tables collapse and the budget silently overspends → 1008.
4. **Custody default.**
   *Recommend: ship Attended (self-custodial) first; make Hybrid opt-in with the dual-kill + no-withdraw framing.*
   Meets the promise for real sessions while foregrounding the custody decision honestly.
5. **Status stream — SSE vs WS.**
   *Recommend: SSE for the foreground cockpit + APNs for background.* SSE survives foreground/background transitions
   (Last-Event-ID) and is trivial from `URLSession.bytes`; it does not deliver backgrounded, so APNs is the required
   background channel — not a substitute you can skip.
6. **Rebates / points.**
   *Recommend: assume none (`rebateBp=0`), show the pessimistic Cost/$1M, add a "Rewards earned" tile only if Perpl
   confirms a program.* Determines whether the honest promise can ever say "net-positive" or strictly "lowest
   Cost/$1M."
7. **RGrid implementation.**
   *Recommend: maker-only with a discrete trailing take-profit (Perpl has no stop-entry primitive); validate the
   "buy-high/sell-low" economics against tread.fi live behavior.*
8. **Default `maxLossPct` + automated-MM leverage cap.**
   *Recommend: default 15% (tread.fi), and cap automated-MM leverage below the manual market cap* so a single candle
   can't cross the whole ladder into liquidation before the two-read kill + taker flatten completes.
9. **`pClose` / `kAdv` seeds and self-calibration.**
   *Recommend: ship priors (`pClose=0.6`, `a=8 bp`) and self-calibrate from the first N sessions via a Supabase
   aggregate* — and always show the loss branch in the pre-trade EV so the panel can't read as free money.
10. **`filledPct` semantics.**
    *Recommend: schedule/execution adherence (executed vs planned slices), with `volumePct` shown separately.*
    Matches tread.fi's "Filled %" column intent; clamp the fallback so it doesn't read ~100% at t≈0.
11. **Pause / background semantics (Attended).**
    *Recommend: explicit foreground Pause = cancel resting entries + hold position; backgrounded = "Running unattended
    — resting orders live," never mislabeled "Paused," never implying the aggregate kill is armed.*
12. **Scheduled / Campaigns in Attended-only builds.**
    *Recommend: keep the tabs (the worker ships in Phase 2) but make them reminder-only in Phase 1 with copy that
    never overpromises unattended execution.*
13. **DGrid dead-band + candle resolution.**
    *Recommend: `volZScore ±0.5σ` dead-band gated by `ER ≥ 0.35`, validated against real BTC/MON tapes before
    locking; auto-select 5-min candles when `V24_USD < $250k`, else 1-min.*
