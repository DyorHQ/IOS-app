# Delta-Neutral Funding Strategy on Perpl — Parameters, Formulas, Blockers

Status: implemented in the iOS app (Strategy → Delta Neutral) on 2026-09-16. Every number below is either read live
from Perpl's Exchange contract / gateway or fixed from Perpl's documentation, and the math is unit-tested in
`DyorKit/Tests/DyorKitTests/DeltaNeutralTests.swift`.

## 1. The trade

Long `N` dollars of the asset on a Monad spot venue (Kuru, Uniswap, Monday Trade — best quote wins), short `N`
dollars of the same asset on Perpl. Price moves cancel; the short collects funding every interval while **longs pay
shorts**. When the sign flips the short pays instead, which is the exit signal.

Hedgeable markets (a spot token exists on Monad): **BTC** (perp 1: WBTC, cbBTC, LBTC), **ETH** (perp 20: WETH, rETH,
ezETH), **MON** (perp 10: native MON, gMON, sMON, aprMON, shMON). SOL, HYPE and ZEC have no Monad spot and cannot be
hedged here. Derivatives (cbBTC, rETH, gMON…) hedge the price but carry their own peg / yield basis; the app flags them
and defaults to the plain asset.

## 2. Perpl facts the strategy relies on (verified 2026-09-16)

| Fact | Value | Source |
|---|---|---|
| Funding interval | every 8 571 blocks ≈ 1 hour (0.42 s blocks assumed by Perpl) | docs.perpl.xyz/exchange/funding |
| Rate definition | Σ over the interval of `max(ImpactBid−Oracle,0) − max(Oracle−ImpactAsk,0)` / Oracle | same |
| Sign | **positive ⇒ longs pay shorts**; negative ⇒ shorts pay longs | same |
| On-chain field | `getPerpetualInfo(id)[20] = fundingRatePct100k` = rate in **parts per 100 000** per interval (BTC 4 ⇒ 0.004 %/h) | Exchange `0x34B6…2a6F` |
| Gateway field | `context.markets[].funding.rate` = same rate in **parts per million** (BTC 40); `div` scales the funding index, not the rate | app.perpl.xyz/api/v1/pub/context |
| Clamp | `absFundingClampPctPer100K` = 10 on BTC/ETH/MON today ⇒ \|rate\| ≤ 0.01 %/h (87.6 %/yr) | on-chain |
| Schedule anchor | `fundingStartBlock` (BTC/MON 55 077 246, ETH 61 814 052); next settlement = start + ⌈(head−start)/8571⌉·8571 | on-chain |
| Accrual | virtual (funding-product sum); shows on the position as `premiumPnlCNS` (`PerpPosition.premium`), settles to the balance when the position closes | docs + contract |
| Fees | **open only, close free**. Tier 1 (<$5M / 14 d): maker 0.9 bp, taker 6.9 bp; tiers down to −1 bp / 2.5 bp | docs.perpl.xyz/exchange/fees, `config.taker_fees` |
| Margin | isolated; IMR = N / IMF, MMR = N / MMF. BTC 15× max / 4 % maint; ETH 12× / 5 %; MON 10× / 5 % | `getMarginFractions`, context config |
| Liquidation | short: `P_liq = P_entry − (MMR − margin − premium) / size`; 80 % of remaining margin returned | docs.perpl.xyz/exchange/liquidation |
| Minimum size | one lot: BTC 0.00001, ETH 0.001, MON 1 (`size_decimals`) | docs.perpl.xyz/exchange/minimum-orders |
| Account | first deposit ≥ $10 AUSD (`min_account_open_amount`); collateral is AUSD (6 dp) | context `instances[0]` |
| Market order | marketable limit at the slippage bound, IOC; VWAP fill | docs.perpl.xyz/exchange/order-types |
| Native TWAP | "coming soon" on Perpl — the app slices both legs itself | same |

## 3. Simple mode and Pro mode

The setup screen opens in **Simple** mode: market chips ranked by what a short earns right now (green pays), an
amount in USDC with quick amounts, and one "At a Glance" card — what the amount earns a day at today's rate, what
the round trip costs and when it pays for itself, the rally that would liquidate the short (with 1×/2× chips), and a
readiness checklist (USDC for the spot leg, AUSD for the margin, with a one-tap opt-in to convert USDC for a
shortfall). Each line has an ⓘ that opens the full table. Details holds the exact legs, the entry plan and the
auto-exit switch. Starting shows a receipt (buy, short, margin, entry length, costs, earnings, auto exit, "keep the
app open for N minutes"). The dashboard opens on one card — earned, per day now, health — with one primary action
and the rest in a menu; legs, funding, P&L, health and events sit under Details and Activity.

Simple mode picks `twapSlices` itself: one per $100 of spot, 1–8, doubled (up to 20) while one slice's quoted impact
exceeds `maxSpotImpactBps`; the interval stays 45 s. The market defaults to the best positive funding and the amount
to half the wallet's USDC ($20–$500). **Pro** mode (menu) shows every parameter and table and leaves the steppers to
the user. The three "how it works" cards appear once.

## 4. Parameters (`DeltaNeutral.Parameters`)

| Parameter | Default | Bounds | Meaning |
|---|---|---|---|
| `spotCapitalUSD` | 200 | ≥ 20 | **USDC** spent on the spot leg; the perp notional matches it |
| `perpLeverage` λ | 2 | 1 … min(3, market max) | margin = N / λ. 1× = equal collateral both sides |
| `twapSlices` k | 4 | 1 … 20 | Spot buy split into k swaps; the short is added after each |
| `twapIntervalSeconds` | 45 | 10 … 900 | Gap between slices |
| `spotSlippageBps` | 50 | 5 … 500 | Min-received bound on each spot swap |
| `maxSpotImpactBps` | 30 | 5 … 500 | A slice quoting above this is skipped and retried next interval |
| `perpSlippageBps` | 50 | 5 … 500 | Bound on each perp market short |
| `exitFundingHourly` | 0 | −0.02 % … +0.02 %/h | Exit threshold on the hourly rate (fraction) |
| `exitAfterIntervals` | 3 | 1 … 48 | Consecutive settlements at/below threshold before "exit recommended" |
| `liquidationBufferPct` | 15 | 2 … 50 | Alert when the mark is within this % of the short's liquidation |
| `maxDeltaDriftPct` | 2 | 0.5 … 20 | Alert when \|spot value − perp notional\| / notional exceeds this |
| `takerFeeBps` / `makerFeeBps` | 6.9 / 0.9 | 0 … 10 | Perpl open fees (tier 1) |
| `marginBufferFraction` | 2 % | 0 … 50 % | Extra **AUSD** deposited above the margin for the open fee / first adverse intervals |
| `topUpAUSDFromUSDC` | off | — | Swap USDC → AUSD for a margin shortfall before depositing (off: the perp leg must be funded in AUSD) |
| `autoExitOnFundingFlip` | on | — | After `exitAfterIntervals` settlements at or below `exitFundingHourly`, the watcher starts the exit itself (app open) |

## 5. Formulas

Sizing (both legs equal):
```
usable   = capital × (1 − reserve)
N_raw    = usable / (1 + 1/λ)              # spot N + margin N/λ = usable
size     = floor(N_raw / price / lot) × lot # perp lots
N        = size × price                    # both legs
margin   = N / λ
```
Costs (round trip, before funding):
```
spot_entry = N × costBps_slice / 10 000    # effective slice price vs perp mark, from a live quote
spot_exit  = spot_entry                    # assumed symmetric
perp_entry = N × takerBps / 10 000         # 6.9 bp tier 1 (0.9 bp if post-only maker)
perp_exit  = 0                             # Perpl charges to open only
gas        ≈ 6 tx × 0.02 MON
```
Funding:
```
f_h        = fundingRatePct100k / 100 000  (= gateway rate / 1e6)
income/h   = N × f_h        (short earns when f_h > 0)
per day    = 24 × income/h ;  APR (simple) = f_h × 8 760
breakeven  = total_cost / income/h  (undefined when f_h ≤ 0)
```
Health:
```
netDelta   = spotUnits × spotPrice − perp.size × mark
drift %    = |netDelta| / (perp.size × mark) × 100
P_liq(short) = entry − (entry×size×MMF − margin − premium) / size
distance % = (P_liq − mark) / mark × 100
```
P&L on the dashboard: `funding (premium + realized) + price P&L (spot value − spot cost + short's price move) − fees
(perp open fee + quoted spot execution cost)`.

## 6. Execution (what the app does, in order)

1. Refuse if the wallet already holds a position on the market (accounting must be exact).
2. Ensure Perpl collateral: account exists and holds ≥ margin × (1 + buffer) (≥ $10 to open). The AUSD is deposited
   from the wallet; if it is short the run stops with "not enough AUSD" — unless the user turned on "Top up AUSD from
   USDC", in which case USDC → AUSD is swapped for the shortfall first. The setup screen shows the required AUSD, what
   the wallet and the free Perpl balance hold, and a shortcut to the USDC → AUSD swap.
3. For each slice: quote USDC → spot (best venue), check impact ≤ cap, swap, measure the balance delta, then short
   exactly the acquired units (lot-rounded, never above target) as an on-chain IOC market order at the slippage bound.
   Partial fills are read back from the position. Progress is persisted after every transaction.
4. After the last slice, top up the hedge for any residual ≥ 1 lot.
5. Monitor every 30 s while the app is open: funding sign (notify on flip, in dollars a day), intervals below the
   exit level (start the exit when `autoExitOnFundingFlip` is on, else notify "exit recommended"), liquidation
   distance (notify + Add margin), drift, missing hedge.
6. Exit: close the short (market, free), then sell the spot to USDC in slices.

Every transaction is signed by the session wallet on the device; nothing is delegated.

## 7. Blockers and honest limits

1. **No execution while the app is closed.** iOS suspends the app; the TWAP entry, the exit and the monitor run only
   in the foreground (the run resumes on next open). A funding flip at 3 a.m. is noticed at the next open.
   Fix: a server monitor (public data, no keys) that pushes via APNs. APNs needs the paid Apple Developer team the
   project does not have yet (the personal team cannot sign the push entitlement).
2. **Automated exit from a server is not possible without custody.** The perp leg could be delegated (Perpl's
   trade-scoped Ed25519 key cannot withdraw), but the spot leg needs the wallet key. A keeper would need a session
   key / delegated account on Monad (EIP-7702 or a smart account) — a separate design.
3. **Funding is only known ~1 minute ahead.** Perpl sets the rate up to 143 blocks before settlement; there is no
   predicted-funding feed, so projections assume the current rate holds.
4. **Perpl TWAP is not live** ("coming soon"); the perp leg is sliced by the app as market orders (taker fee). A
   post-only maker entry (0.9 bp) is possible but may not fill; not enabled by default.
5. **Fee tier** is assumed tier 1; the gateway does not expose the account's tier without auth (`AccountStatsUpdate`
   mt:28 may — untested).
6. **Rally risk at leverage > 1.** The spot gain lives in the wallet, the short's margin on Perpl; a fast rally can
   liquidate the short before margin is moved. The app caps leverage at 3×, alerts on the buffer and offers
   Add margin, but cannot move funds unattended.
7. **Spot venue risk**: price impact on thin Monad pools (mitigated by TWAP + impact cap), derivative-token pegs.
8. **Verification**: rehearsed on an anvil fork of mainnet (`--no-rate-limit`, rpc3 upstream). Two fork-only
   quirks matter: Perpl rejects any order once its reference price is older than `refPriceMaxAgeSec` = 60 s (the
   fork's oracle is frozen at the fork block), so `scripts/dev/perpl-oracle-relay.py` replays the keepers'
   `execPerpOps` price updates from mainnet onto the fork; and public-RPC state fetches make the first swap slow, so
   the runner waits out late receipts instead of failing; and Kuru Flow's routes are built by its API against
   mainnet order books, so on a fork whose books the rehearsal itself has moved they can revert before sending —
   the runner then falls back to the next-ranked venue (Uniswap v4 in the rehearsal) and logs which venue said no.
   Live funding numbers were checked against the contract and the gateway. A real mainnet run with a small wallet
   is still the final check.
