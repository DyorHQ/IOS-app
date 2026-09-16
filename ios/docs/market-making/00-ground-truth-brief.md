# DyorHQ Market-Making Feature — Shared Ground-Truth Brief

You are one of a team of specialists designing a professional **Market-Making / Volume-Generation feature**
for **DyorHQ**, a native **SwiftUI iOS app** (bundle `fun.dyorhq.app`) whose perps run on **Perpl** (an on-chain
perp DEX on **Monad**, chain 143). The goal: let a user generate a lot of **trading volume over a short, time-boxed
session while minimizing cost / ideally staying net-profitable**, matching or beating **tread.fi** and **Arbital**
volume/MM bots — but done correctly for iOS, not copied from a web/server bot.

Read this whole brief before writing your section. Everything here is verified against live code, the Perpl API,
and the tread.fi/Arbital docs. Do not contradict these facts; build on them.

────────────────────────────────────────────────────────────────────────
## 0. HONEST ECONOMICS (the frame every section must respect)

Generating perp volume is **not free money**. On Perpl each filled leg costs ~2.5 bp (≈1.5 bp maker + ~1.0 bp
builder). A buy+sell round-trip of notional N generates **2N of volume** and costs ~5 bp·N, i.e. **~$250 of fees
per $1,000,000 of volume** (matches Arbital's ~$150–250/$1M and tread.fi's "2 bp/order + venue maker"). "Cost/$1M"
is THE headline efficiency metric (it's a column in tread.fi's table).

Profit while generating volume comes ONLY from, in priority order:
1. **Spread capture** — maker buys below / sells above reference and the price oscillates back through the ladder,
   netting more than round-trip fees + adverse selection. Works in ranging markets (Grid); loses in trends.
2. **Maker rebates / MM reward programs / points / airdrops** — often the real reason to farm volume. (Must confirm
   whether Perpl/Monad pays these — see API-needs.)
3. NOT from wash/self-trading. **Compliance line:** this is legitimate two-sided liquidity provision filled by the
   real order book (genuine counterparty + inventory risk). Self-matching to fake volume is market manipulation,
   is against venue ToS, and on Perpl just churns your own fees. It is OUT OF SCOPE. Design must make honest cost
   and risk unmissable; never promise costless profit.

The feature's real promise: **"hit your volume target within a chosen time box, at the lowest possible cost/$1M,
under hard risk limits, with live visibility."**

────────────────────────────────────────────────────────────────────────
## 1. WHAT ALREADY EXISTS IN DyorHQ (build on this; don't reinvent)

Repo: `~/Hackathon/ios` (git remote github.com/DyorHQ/IOS-app). App sources in `ios/DyorHQ/`, shared logic in the
Swift package `ios/DyorKit/`. XcodeGen (`project.yml`, run `xcodegen generate`). iOS 18+ target. A Cloudflare
`worker/` and a Supabase backend already exist in the monorepo (`~/Hackathon/worker`, `~/Hackathon/supabase`).

Existing Strategy module (`ios/DyorHQ/Strategy/`), a working **v1** of exactly this feature, ported from the
Nadobro bot and adapted to a confirm-based mobile flow:

- **MarketMakingStrategy.swift** — `MMStrategy` model (Codable, persisted per-wallet in `MMStore` via UserDefaults).
  Modes `"mid"` and `"grid"`. `levels(mark:)` builds the ladder:
  - Mid: symmetric two-sided maker ladder; half-spread floored at `midFloorBp = 2.5`; flat/linear/geometric size
    curve; directional-bias skew (`bias·0.2`); `perSide = deployed/2`, `deployed = capital·leverage`.
  - Grid: directional arithmetic grid; equal quote/level; per-level take-profit one step away; step floored at
    `gridFloorBp = 6.8`; maker offset `max(step/2, 0.00015)`.
  - `MMLevel {side, entry, size, takeProfit?, stopLoss?}`, `MMFill {side, price, size, time, notional}`.
  - Bracket TP/SL computed as ± pct of entry.
- **MMWatcher.swift** — `MMExecutor.place(...)` places each level as a **post-only limit** with linked native
  **TP/SL trigger** via `submitBracket`, cancelling any level whose protective trigger was rejected (never leaves a
  naked entry). `MMExecutor.stop(...)` cancels all resting orders + flattens all positions on the market, then
  verifies clean. `MMWatcher` = a `@MainActor` loop, **20s tick, only while app is active**: reconnects the trading
  socket, detects fills (a resting price that left the book), tracks session volume, and **recycles from flat** only
  after TWO consecutive fully-flat reads (can never stack on a just-filled position). CRITICAL correctness rule
  already encoded: a failed on-chain read (`try?`→nil) must NOT be treated as "flat/no orders" (would fabricate
  fills / double exposure) — the tick bails and retries.
- **MMStatusView.swift** — the current live dashboard: Session PnL (realized = collateral Δ since start +
  unrealized), Volume, Unrealized, Est. fees (`feeRateBp = 5.0` round-trip), open positions, open orders, fills
  feed; Stop & Flatten button. Polls every 8s + listens for `.mmStrategyChanged`.
- **MarketMakingView.swift** — the config screen: Mode (Mid/Grid) segmented, market picker, capital + leverage
  (1–10), spread bp, levels/side, size curve, bias slider, grid direction/levels/step, TP/SL steppers, ladder
  preview, one-click-trading gate, confirm dialog. Requires one-click trading + funded Perpl account.

**Gaps vs tread.fi/Arbital that this project must close:** volume as a first-class target; time-box/duration;
participation-rate (Aggressive/Normal/Passive) → schedule; auto-computed duration; DGrid/RGrid/Blend/Signal
reference-price models; grid-reset / TP-reset thresholds; a real requote/refresh loop (v1 only recycles from flat,
no continuous cancel/replace/amend); Max-Loss real-time kill switch; pre-trade analytics (Cost/$1M, Max Loss, est.
fills, est. duration, liquidation price); presets; a sessions table (Active/History/Scheduled/Analytics/Campaigns);
and above all a **live status bar** of the running session. And it must solve **iOS background execution** so a
10–1000 min session actually runs when the phone is in a pocket.

────────────────────────────────────────────────────────────────────────
## 2. PERPL API — HARD FACTS (verified; violating these = the bot breaks)

- **On-chain Exchange** `0x34B6552d57a35a1D042CcAe1951BD1C370112a6F`, Monad chain 143. Collateral **AUSD**
  `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a`, 6 decimals. Markets: BTC 1, MON 10, ETH 20, SOL 31, HYPE 40, ZEC 50
  (network-specific; never hardcode across nets). The contract has only 7 primitives and **no trigger/stop type**.
- **Real TP/SL, and any keyless (no per-order wallet signature) automation, REQUIRE the authenticated API path**:
  an **Ed25519 API key** enrolled with the wallet's EIP-712 signature, `scope_mask = 2 (trade)` — **trade scope
  CANNOT withdraw funds**. Stored in Keychain today (ThisDeviceOnly, non-synced).
- **Order forwarding ("one-click") is a prerequisite**: the account must `allowOrderForwarding(true)` on-chain or
  every API order fails (sr:34). No on-chain getter; read state from WS `Account.fw`; a confirmed tx is the authority.
- **Market-data WS** `wss://app.perpl.xyz/ws/v1/market-data` (no auth, works from native w/ no Origin). Streams:
  `market-state@143`, `order-book@<id>`, `trades@<id>`, `candles@<id>*<sec>`, `heartbeat@143`. Prices/sizes are
  scaled ints (divide by market decimals). REST candles `GET /api/v1/market-data/<id>/candles/<res>/<from>-<to>`.
- **Trading WS** `wss://app.perpl.xyz/ws/v1/trading`. First frame `mt:29` ApiKeySignIn (Ed25519). Orders `mt:22`.
  Order types `t`: 1 OpenLong, 2 OpenShort, 3 CloseLong, 4 CloseShort, 5 Cancel, **7 Change (amend)**.
  Flags `fl`: 0 GTC, **1 PostOnly**, 2 FOK, 4 IOC. Market = `p:0 + ms:<slipBps> + fl:4`.
  **TP/SL = reduce-only Close with `tp`(trigger), `tpc`(1 GTELast/2 LTELast/3 GTEMark/4 LTEMark), `lp`(linked
  position id), `lb:0`.** `rq` = strictly-increasing per-account request id seeded from AccountUpdate `lfr`.
  **`lb` (last-exec block) MUST be 0 on every order** (else "last exec block too high" 400). mt:3 ack code 0 =
  admitted-for-forwarding only; the REAL fill/outcome arrives on **mt:24**; position ids on mt:26/27; account/fw on
  mt:19 (`Wallet.as`) and mt:21 AccountUpdate.
- **CONNECTION LIMITS (these dominate the whole design):**
  - **Hard cap 4 trading sockets per WALLET** (shared with app.perpl.xyz browser tabs). A 5th → close 1008. Keep
    exactly ONE socket, tear old down before new, single-flight connect, back off on failure. (DyorHQ already does
    this in `PerplTrading.swift`.)
  - **Rate limit ~120 requests/min per socket.** App keep-alive ping `{mt:1}` every ~30s costs 2/min. So a requoting
    MM loop has a budget of **~2 order-ops/second total** across ALL levels/markets. This makes **amend (t:7)** and
    batching essential vs naive cancel+replace. Rate-limit breach → 1008 "too many requests".
  - Bad key → 3401 (never retry same key). URLSession masks every server close as POSIX 57; real reason is in
    `closeCode`/`closeReason` (DyorKit `PerplClose`).
- **On-chain reads** (DyorKit services, via Monad RPC + Multicall3): `env.perpl.markets()`, `.account(addr)`,
  `.positions(account, markets:)`, `.openOrders(account, markets:)`. Public RPC serves ~24h-old state for some
  calls; getLogs range differs by RPC (use rpc1 for log scans). Margin fractions: fraction = 100/value; a market's
  init-margin cap → max leverage = floor(1/initMarginFraction).

────────────────────────────────────────────────────────────────────────
## 3. TREAD.FI MARKET-MAKER BOT — full model to match/beat (from docs + the live UI screenshot)

Config inputs (screenshot ground truth): **Account** (exchange sub-account); **Pair** (e.g. BTC:PERP-AUSD);
**Presets**; **Margin** ($) + **leverage** (e.g. 15×); **Volume** ($ target, e.g. $15,000; default heuristic ≈
margin×20); **Participation Rate** = Aggressive (~10 min) / Normal (~20 min) / Passive (1h40m), shown as a % of
market volume (e.g. 10.0% ⇒ your order is 1/10 of the volume traded over the window; bot spreads it over the time
the market trades ~9× your size); **Duration** (minutes, range 10–1000; **auto-computed from margin, market 24h
volume, and participation rate**); **Reference Price** model; **Grid Reset Threshold** (0.05/0.125/0.25/0.5/1%);
**Spread** (bps slider; wider=safer/less reward, tighter=aggressive/more competitive/riskier); **Stop Loss %** and
**Take Profit %** sliders.

Reference-price models:
- **Mid Price** — quote around the mid; **Directional Bias (Short/Neutral/Long) appears only in Mid mode**.
- **Grid** — buy low → sell high; best for **sideways** markets; uses **Grid Reset Threshold** (re-center when price
  moves beyond it); risk: an order gets "stuck" as price trends away → eventually stop-lossed.
- **RGrid (reverse grid)** — buy high → sell low; best for **trending + volatile** markets; uses **TP Reset
  Threshold** instead of Grid Reset Threshold.
- **DGrid (dynamic grid)** — **switches between Grid and RGrid based on volatility predictions** (high expected vol
  → RGrid, low → Grid); uses **historical volatility to set an optimal spread**.
- **Blend** — blended mode (combines behaviors; e.g. mid + grid weighting).
- **Signal** — market-make **based on RSI** (skew/gate quoting by an indicator).

Mechanics: simultaneously places buy & sell **limit (maker-only)** orders around the reference; notional split
equally between sides; refreshes orders periodically to stay near market; automates placement, spread management,
rebalancing, participation-rate targeting, and risk controls. **Max Loss = Stop Loss% × margin** (e.g. 15%×$100 =
$15); bot monitors PnL in real time and **cancels/flattens when net loss hits Max Loss**. Builder fee 2 bp/order +
venue maker fee.

Pre-Trade Analytics panel: **Available Margin**, **Max Loss**, insufficient-margin warning ("Order requires $100 but
only $7.0991 available"). **Configuration** summary: Duration, Participation Rate. **Lifetime Summary**: Volume,
Net Fees.

Sessions table tabs: **Active / History / Scheduled / Analytics / Campaigns**. Columns: **Mode, Pair, Account,
Volume, Fees, PnL, Cost/$1M, Spread, Filled %, Status** (Running/Finished/Canceled), **Actions** (clone, cancel,
restart, share). Plus **Start Trading**, schedule, and a repeat/swap-sides control.

## 3b. ARBITAL model (TWAP Market Making) — corroborating design points
Directional Bias Short/Neutral/Long (**margin +up to 20% at higher bias**); Execution Mode Aggressive/Normal/Passive
(refresh speed + spread width); **Expected Budget** = max-loss tolerance, bot stops if exceeded. Inventory mgmt:
reduce buys when too long, reduce sells when too short, adjust spreads dynamically, **stop one-sided trading when
limits hit**, but total buy/sell volume converges over the run. Non-custodial (own wallet/accounts). Profit = spread
capture + MM/ecosystem incentives. Dashboard: active/paused/completed, total volume, realized PnL, budget usage,
trade history & event log.

────────────────────────────────────────────────────────────────────────
## 4. THE iOS REALITY (the thing that makes this different from a web/server bot)

A market maker must run continuously for the whole session (10–1000 min), requoting as price moves. **iOS suspends
an app seconds after it backgrounds.** There is no general long-running background execution. Options:
- BGProcessingTask/BGAppRefreshTask: opportunistic, minutes-to-hours apart, NOT guaranteed, cannot hold a socket.
- Foreground: full execution only while the app is on-screen and the device awake.
- Silent/normal push: can wake the app briefly / prompt the user, not run a loop.
- Native venue TP/SL triggers (Perpl keeper): fire server-side even when the app is dead — the current safety net.

Therefore a phone alone **cannot** reliably manufacture a large, time-boxed volume session. The realistic
architectures (a core deliverable is to choose and justify one, honestly stating trust/security tradeoffs):
- **A. Server-side executor** (like tread.fi/Arbital): a worker runs the MM loop 24/7 using a **delegated
  trade-scoped (no-withdrawal) Ed25519 key**; device is a remote cockpit; live status streamed back. DyorHQ already
  has a Cloudflare `worker/` (bridges Perpl WS) + Supabase. Key must live server-side → a real, explicit,
  user-granted, revocable, auto-expiring trust decision.
- **B. On-device foreground-only**: fully self-custodial (key stays in Keychain), runs only while app is open;
  native TP/SL + a stored session so it resumes on next open; realistic only for short/attended sessions.
- **C. Hybrid** (recommended to evaluate): device = cockpit + confirmation + attended execution; worker = the
  time-boxed executor holding a session-scoped key that auto-expires at session end and is instantly revocable
  (allowOrderForwarding(false) / forget). Best coverage; must be honest about the key-custody tradeoff and default
  to the safest option that still meets "lots of volume over a short period."

────────────────────────────────────────────────────────────────────────
## 5. YOUR OUTPUT
Return a rigorous, buildable design for YOUR section only (another teammate integrates them). Be concrete: name
Swift types/files, Perpl frames, worker endpoints, formulas with numbers, and exact UI. Call out every place your
section depends on another. Flag open questions and any **external API/data/credentials you need the user to
provide** (they offered to supply APIs). Prefer decisions over menus; where you must offer a choice, recommend one
and say why. Respect the connection/rate limits and the honest-economics + compliance frame above. No fluff.
