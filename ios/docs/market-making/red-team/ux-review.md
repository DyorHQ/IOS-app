# Red-team review — `mm-section-ux.md` (Product/UX + Live Status Bar)

Reviewer stance: adversarial, verified against the live code in `~/Hackathon/ios`, the brief, and the Perpl
client. Bottom line: **the UX architecture is sound and unusually buildable** (the reuse inventory is accurate,
the honest-economics discipline is exemplary), but it rests on three foundation assumptions that are **not true in
the current code** and would silently break the economics/compliance premise or fake the headline metric. Fix
those and this ships. Verdict: **solid-with-fixes.**

Files inspected to verify: `Strategy/MMWatcher.swift`, `Strategy/MarketMakingStrategy.swift`,
`Wallet/PerplTrading.swift`, `DyorKit/.../Perpl/PerplTradeClient.swift`, `PerplModels.swift`, `PerplFeed.swift`,
`PerplService.swift`, `App/RootView.swift`, `App/Router.swift`.

---

## CRITICAL

### C1 — Post-only (`fl:1`) is never actually sent; the whole maker/honest-economics premise is unenforced
- **Issue.** MM places entries through `PerplTrading.submitBracket → PerplOrders.entry`, which sets `ioc: false`
  for limit orders, and `PerplOrderFrame.json` emits **only** `"fl": ioc ? 4 : 0` (GTC or IOC). `OrderInput.postOnly`
  is honored **solely** in the on-chain `PerplExchange` path (`PerplExchange.swift:107`), **never** in the
  authenticated WS path the bot uses. So every "maker" ladder order goes out as **GTC, not PostOnly** — even though
  `MMExecutor.place` passes `postOnly: true`.
- **Why it breaks.** (a) *Economics*: a limit that is or becomes marketable (price moved between compute and place)
  takes liquidity and pays **taker** fees and forfeits any maker rebate — the brief's ~2.5 bp/leg maker assumption
  and the spread-floor rationale ("below this you can't clear round-trip fees", §3.10) no longer hold. (b)
  *Compliance*: brief §2 lists PostOnly (`fl:1`) as a hard requirement; without it a two-sided **Mid** ladder can
  self-cross → accidental self-match/wash — exactly what §12 forbids. (c) The section advertises "post-only limit"
  (§0 reuse, §3.10, §12) as a guarantee it cannot currently deliver.
- **Fix.** Add a post-only flag to the WS frame: give `PerplOrderFrame` a `postOnly` field, emit `"fl": 1` for
  resting maker entries, and thread it from `OrderInput.postOnly` in `PerplOrders.entry`. Confirm Perpl's `fl:1`
  reject-on-cross semantics (see API needs). The UX section must list this as a **hard DyorKit prerequisite**, not
  assume it — until it lands, the honest-economics and no-self-match guarantees are false.

### C2 — Fill/volume double-count once a requote/amend loop exists → headline metric silently inflates, Cost/$1M silently understates
- **Issue.** The existing `MMWatcher` detects a fill as *"a resting price left the book"* and adds `entry×size`
  to `volume`. The design keeps `MMWatcher` (`MMSessionManager` "wraps `MMWatcher`", §0.1/§4.0) **and** adds
  quant's continuous cancel/replace/**amend `t:7`** requote loop, **and** §8 lists BOTH `MMSession.volume (watcher)`
  and `mt:24` as the source for volume/fills with no reconciliation.
- **Why it breaks.** Under a requote loop a resting price leaving the book is usually a **cancel/amend, not a fill**.
  The watcher counts every requote as a fill → volume massively over-counted. Because
  `costPer1M = −totalPnL × 1e6 / volume`, **inflated volume makes the honest cost look artificially LOW** — the one
  number this feature exists to be honest about. The two fill sources (price-diff vs `mt:24`) will also disagree.
- **Fix.** Choose ONE authoritative fill/volume source: the trading-WS **`mt:24` executions** (note:
  `PerplTradeClient` does **not** parse `mt:24` today — only `mt:19/21/3`; this is new client work). Retire the
  watcher's price-diff fill detection the moment a requote loop is active, and make §8 name a single source.

### C3 — Two order-managing loops can race → double-place / orphan
- **Issue.** Recycle-from-flat (`MMWatcher.manage`) re-places a full ladder after two consecutive flat reads; a
  requote loop that cancels-all-then-replaces briefly presents a flat book. Nothing designates a single owner of
  order state; the manager "wraps" both.
- **Why it breaks.** During a requote's cancel→replace window `MMWatcher` can see "flat", arm, and re-place a full
  ladder **on top of** the requote's replacement → double exposure; or the two loops cancel each other's fresh
  orders → orphaned/naked state. (The watcher's own failed-read-bails guard does not protect against a *genuinely*
  empty book mid-requote.)
- **Fix.** One loop owns placement per running session (recycle-from-flat XOR continuous requote, never both). The
  manager must **disable `MMWatcher` recycle** for any session driven by quant's requote loop.

---

## HIGH

### H1 — Session Max-Loss kill is foreground-only, but the UI presents it as an always-on guardrail
- **Issue.** The kill (`drawdownPct ≥ 1` → cancel all + flatten, §4.0/§6) runs in the `@MainActor` loop off
  on-chain polls. iOS suspends the app seconds after backgrounding (brief §4). In **on-device mode, backgrounded**,
  the aggregate kill does not run — only per-level native Perpl TP/SL fire.
- **Why it breaks.** The risk footer shows a "distance-to-Max-Loss" bar and "auto-flatten at −$15"; a user believes
  it's enforced. Backgrounded on-device, aggregate loss can blow past Max Loss with no kill — per-level SLs don't
  sum to the session cap, and a trend can hold inventory *between* SL levels.
- **Fix.** State plainly (copy + footer) that the session Max-Loss kill runs only while **foreground** (on-device)
  or on the **worker** (server); make the worker the required executor for any unattended Max-Loss enforcement.
  Don't imply the kill is always armed.

### H2 — On-device "pause on background = cancel resting orders" is not achievable, and "Paused" mislabels a live state
- **Issue.** §6 triggers Paused on "app backgrounded in on-device mode" with "orders cancelled/held per policy."
  Cancelling N orders at the ≤2 ops/s trading budget takes seconds; the background grace (~5 s, ~30 s with
  `beginBackgroundTask`) may not cover it, and once suspended no code runs. Meanwhile resting **GTC** orders +
  native TP/SL stay **live** and can fill while "Paused."
- **Why it breaks.** Orders orphan (can't be cancelled in time), and calling a state where inventory can still
  change "Paused" understates risk.
- **Fix.** On background in on-device mode, **leave orders resting** (TP/SL armed) and label it "Running
  unattended — quoting paused, resting orders live," not "Paused." Reserve true cancel-on-pause for the explicit
  foreground Pause action. Update the §11 pause-semantics assumption.

### H3 — No shared rate-limiter across all trading-socket writes → 1008 rate-limit / dropped socket
- **Issue.** `PerplTradeClient.send` has **no throttling**. The design adds Pause (burst of cancels) and Stop
  (cancels + closes, `MMExecutor.stop` loops with no pacing) as UX flows, on top of quant's requote loop and the
  2/min keepalive — yet "≤2 ops/s" is mentioned only in quant's context, not as one global budget all writers share.
- **Why it breaks.** A Stop, or rapid Pause/Resume during active requoting, bursts past ~120/min → 1008 "too many
  requests" → socket close **mid-teardown** (the worst moment to lose the socket).
- **Fix.** One token-bucket limiter in `PerplTrading`/`PerplTradeClient` that ALL writes pass through (requote,
  pause-cancel, stop-flatten, keepalive), sized to 120/min; Stop/Pause pace within it and show progress instead of
  firing a burst.

### H4 — On-chain poll freshness undermines the "live" dashboard and the kill
- **Issue.** §4.2/§8 drive inventory, margin, liq price, PnL and the Max-Loss kill from `account`/`positions`/
  `openOrders` on-chain polls every 5–8 s. Brief §2: "public RPC serves ~24h-old state for some calls."
- **Why it breaks.** If the RPC lags, the "live" numbers and the kill decision act on stale collateral/position
  data → kill fires late/never; wrong PnL/Cost shown as authoritative.
- **Fix.** Pin the fresh RPC (memory: rpc1/rpc3 serve current state; rpc.monad.xyz is the laggy one) for these
  reads, and/or drive PnL/inventory/kill primarily from the trading-WS `mt:21`/`mt:24` + market-data marks, using
  on-chain as a slower reconciliation. Name the RPC in the data-source map.

---

## MEDIUM

### M1 — Pre-Trade Analytics example numbers are internally inconsistent and dip below the honest fee floor
- **Issue.** §3.13 shows **Est. fees $75.00** and **Est. Cost/$1M $180** on a **$15,000** target. `$180/$1M × $15k
  = $2.70` total — not $75. By the card's own formula `volumeTarget × 5bp/1e4` fees = **$7.50** (a 10× slip to $75);
  by the brief's honest 2.5 bp/volume, fees = **$3.75** (⇒ $250/$1M floor). $180/$1M sits **below** the stated $250
  fee floor with **no confirmed rebate** (§9.3 flags rebates as unknown).
- **Why it breaks.** The flagship pre-trade card would display numbers that don't reconcile and quietly promise
  sub-floor cost — a breach of the honest-economics frame the section otherwise upholds well.
- **Fix.** est fees = `volume × 2.5bp/1e4`; est Cost/$1M ≥ $250 unless a *confirmed* rebate is subtracted (show the
  rebate as its own line). Fix the $75 → $7.50/$3.75 typo. Never show a pre-trade headline cost below the fee floor.

### M2 — `feeRateBp = 5.0` applied to volume double-counts vs the brief's honest number
- **Issue.** Existing (and §4.0's inherited fallback) `estFees = volume × 5/10_000` = **$500/$1M**. Brief §0 honest
  cost is **~$250/$1M** (5 bp is per round-trip *notional* = 2.5 bp per *volume* dollar, since a round trip makes 2×
  volume).
- **Why it breaks.** The fees-so-far fallback is ~2× high; if ever surfaced as Cost/$1M it contradicts both the
  brief and the live totalPnL-based figure.
- **Fix.** Estimate with **2.5 bp against volume** (`volume × 2.5/10_000`); keep the precise path on real `mt:24`
  fees.

### M3 — 24h-volume feed EXISTS but is in base-asset units — duration/participation must × mark
- **Issue.** §3.4/§3.7/§9.2 treat 24h volume as an open question and use `market.vol24h` as USD ("MON 24h vol
  $43,200,000"). It already exists: `PerplMarketState.volume24h` from `market-state@143` (`dv`/sizeScale,
  `PerplFeed.swift:241`) — but in **base units (coins)**, as `PerpTradeView.swift:151` shows by rendering
  `volume24h * mark`.
- **Why it breaks.** Feeding raw `volume24h` (coins) into the USD duration formula is wrong by a factor of `mark`
  (~20× for MON, ~60,000× for BTC) → nonsensical durations/participation %.
- **Fix.** Good news, this **de-risks §9.2**: the feed exists, no candle-derivation needed. But convert to USD with
  `× mark` before the duration/participation math, and correct the open question from "does it exist" to "convert
  base→USD."

### M4 — Market-data over-coupled to the worker bridge though it works natively
- **Issue.** §8 lists order-book/market-state as arriving "via worker bridge for market-data." Brief §2:
  market-data WS "works from native w/ no Origin," and DyorKit `PerplFeed` already connects directly.
- **Why it breaks.** Adds an unnecessary [infra] dependency + latency to the foreground cockpit for data needing no
  bridge.
- **Fix.** Consume market-data directly via `PerplFeed`; reserve the worker for the authenticated executor and
  background push only.

---

## LOW / notes
- **L1.** `mt:24/26/27` are unparsed by `PerplTradeClient` today (only `mt:19/21/3`). Every "precise fees," "fill
  history," and true position-id-linked feature is non-trivial client work, larger than §4.0/§8's "if captured"
  implies. (Current bracket TP/SL links via `tr`/`linkedRequestId`, a sound workaround for the missing `lp` since
  position ids arrive on `mt:26/27` which aren't parsed — keep that workaround.)
- **L2.** `filledPct` fallback `min(1, volumePct / max(0.01, elapsed/plannedDuration))` shows ~**100%** at session
  start (elapsed≈0, floored denominator) — looks great when nothing has happened. Suppress/clamp until a minimum
  elapsed.
- **L3.** Mounting `MMLiveBar` above the iOS 18 `Tab`-based `TabView` via a manual offset is fragile across
  home-indicator / landscape / Dynamic Type; prefer `safeAreaInset(.bottom)` on the TabView content and verify on
  notched + non-notched devices. (`MainTabView` uses the new `Tab {}` API — confirmed in `RootView.swift`.)
- **L4.** Pre-trade Cost/$1M ignores **funding** (`position.premium` is a real carried cost over 10–1000 min); at
  least disclaim it, ideally add an expected-funding term.
- **L5.** Live `costPer1M` uses unrealized PnL, which excludes close fees + funding → looks slightly better than
  realized. Fine if labelled; the "live" cost is optimistic by construction.
- **Verified NOT a bug:** `realizedPnL = balance − startBalance` + `unrealizedPnL` does **not** double-count —
  `PerpAccount.balance` is total collateral (free + locked; `available = balance − locked`, confirmed
  `MarketMakingView.swift:266`), and `position.unrealized` is separate. The PnL/Cost formula is sound provided
  `balance` excludes unrealized (it appears to — worth one confirming read).

---

## Genuinely strong — keep
- **Cost/$1M shown everywhere volume is shown, colored against the $250 floor (§12).** Exemplary honest-economics
  UI discipline — this is the feature's whole integrity story and the section nails it.
- **Preserves the two hard-won safety invariants:** failed-read-bails (no fabricated fills) and two-consecutive-flat
  recycle — correctly identified as load-bearing.
- **Native venue TP/SL leveraged as the only always-on safety net when the app is dead** — the right primitive.
- **Mode-swappable `MMSessionManager` that renders on-device OR server/hybrid without redesign**, plus the explicit,
  auto-expiring, instantly-revocable **trade-scoped** key consent (§3.15) — correct given [arch] is unresolved, and
  the right trust framing.
- **Accurate reuse inventory** — `PerplTrading.status/.isReady/.accountId/.failureMessage/.ensureConnected/`
  `.submitBracket/.cancel/.closePosition`, `MMExecutor.place/.stop`, `MMWatcher`, `env.perpl.*`, `Router.openPerp`
  all exist as claimed. High buildability.
- **Accessibility pass** (color-never-sole-cue, VoiceOver sentences, Dynamic Type reflow, Reduce Motion/
  Transparency) is thorough and HIG-correct; honest open-questions + dependency tagging throughout.

## Added API/venue needs (beyond the design's §9)
1. **Perpl self-trade-prevention policy** — does Perpl reject or self-match a crossing same-account order? Bounds
   the wash/compliance exposure while C1 (post-only) is outstanding.
2. **Confirm WS `fl:1` PostOnly is accepted + its reject-on-cross behavior, and the maker/taker fee schedule** —
   required to validate C1's fix and the $250/$1M economics.
3. **`mt:24` execution-frame field schema** (filled size, price, fee, order/position linkage) — required for the
   single-source volume/fees fix in C2.
