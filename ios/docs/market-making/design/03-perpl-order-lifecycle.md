# Perpl Execution & Order-Lifecycle Engineering

*Section owner: exchange-connectivity / order-router. Consumes the ladder from **quant**, the
host/custody choice from **arch**, background-execution + worker runtime from **infra**, the
kill-switch policy from **risk**, presets from **reco**, and hands state/events to **ux**. This
section owns everything between "here is the desired ladder" and "orders are resting, filling,
and reconciled on Perpl", plus the socket that carries it.*

Everything here is built on the live code: `DyorKit/Sources/DyorKit/Services/Perpl/PerplTradeClient.swift`,
`PerplOrders`, `PerplService.swift`, `PerplFeed.swift`, `PerplAuth.swift`, and the app-side
`DyorHQ/Wallet/PerplTrading.swift`, `DyorHQ/Strategy/MMWatcher.swift`. Where I change those files I say so;
where I add files I name them.

---

## 0. The one-paragraph shape of the design

The requoting MM engine is a **pure state machine** (`PerplExecutionEngine`, new in DyorKit) that drives one
`PerplTradeClient` (the single authenticated socket) and one `PerplReads` port (on-chain + signed-REST truth). It
keeps two-sided **post-only (`fl:1`)** ladders, **moves resting quotes with amend (`t:7`) not cancel+replace**,
**protects positions on fill** with reduce-only TP/SL linked by position id (`lp`, `lb:0`), and never books a fill
except from authoritative truth (mt:24 / signed-REST fills / corroborated on-chain delta) through an **idempotent
fill ledger**. A **token bucket** rations the 120 req/min socket budget; **threshold-gated amend** keeps steady
state cheap. A **write-ahead session log + SlotMap + single-writer lease** make it crash- and reconnect-safe with no
orphaned or duplicated orders. The identical engine logic runs on-device (Architecture B) and is re-implemented in
the Cloudflare **worker Durable Object** (Architecture C); when the worker runs a session the phone is a
**cockpit** (no trading socket) so the 4-socket-per-wallet cap and the single-writer rule both hold.

---

## 1. Where the engine runs, and the DyorKit / app / worker split

**arch** picks A/B/C; I build so the same order-lifecycle logic serves all three, and I state the socket/writer
implications of each.

| Layer | New/changed | Responsibility |
|---|---|---|
| **DyorKit (pure Swift)** | `PerplOrderFrame` (extend), `PerplOrders` (extend), **`PerplExecutionEngine` (new)**, **`PerplTradeClient` (extend for mt:24/26/27)**, **`PerplReads` protocol (new)** | The venue wire + the order-lifecycle state machine. No UIKit, no Keychain, fully unit-testable, runs identically on device. |
| **App (DyorHQ)** | `PerplTrading` (add connection *mode* + lease + fill/position fan-out), `MMWatcher`/`MMExecutor` (become thin drivers of the engine) | Socket ownership, Keychain, one-click gate, the cockpit switch, and the on-device host of the engine (Architecture B / attended). |
| **Worker (TypeScript, greenfield Durable Object)** | **`PerplExecutorDO` (new)**, `/api/mm/*` endpoints | A re-implementation of the engine algorithm (Swift can't run in the Worker) holding a session-scoped trade key, running the loop 24/7 (Architecture C). The pseudo-code + constants in §6/§10 are the spec it must match. |

**Why the engine is pure and in DyorKit:** Architecture B (on-device foreground) must run the *exact* same
lifecycle rules as the worker, or the two hosts drift and reconciliation gets ambiguous. Making the engine a pure
type that takes a `PerplTradeClient` and a `PerplReads` (both protocol-abstracted) lets it run on device today and
be ported verbatim in logic to the DO. It also lets us `swift test` the whole quote/amend/fill/reconcile path
against a mock socket — which the current `MMWatcher` (a `@MainActor` timer touching live services) cannot.

```swift
// DyorKit: the truth port the engine reads (implemented by PerplService on device;
// by direct RPC+REST in the worker). Nothing here consumes the 120/min WS budget.
public protocol PerplReads: Sendable {
    func markets() async throws -> [PerpMarket]
    func account(_ address: Address) async throws -> PerpAccount?
    func positions(_ account: PerpAccount, markets: [PerpMarket]) async throws -> [PerpPosition]
    func openOrders(_ account: PerpAccount, markets: [PerpMarket]) async throws -> [PerpOrder] // → oids
    func fills(key: PerplApiKey, markets: [PerpMarket], count: Int, cursor: String?) async throws -> PerplHistoryPage<PerplFill>
}
```
> **Dep — arch:** the custody decision (session-scoped key server-side vs Keychain-only) is arch's. I assume the
> **recommended Hybrid C** and design the cockpit split for it; on-device-only (B) is the same engine with the phone
> as the executor host and no worker.

---

## 2. The wire: exact frame shapes

Prices scale by `10^priceDecimals`, sizes by `10^lotDecimals` (see `PerplOrders.scalePrice/scaleSize`), leverage is
`×100` (`leverageHdths`). **`lb` is `0` on every order** — Perpl substitutes the market's `order_ttl_blocks`;
computing `head+ttl` overshoots and yields *"last exec block too high"* (already fixed in `PerplOrders`; keep it for
amend too). Outbound `t` is `PerpOrderType.rawValue + 1` (`wireType`): OpenLong=1, OpenShort=2, CloseLong=3,
CloseShort=4, Cancel=5, **Change=7**.

**Sign-in (first frame, mt:29)** — unchanged, `PerplAuth.wsSigninCanonical` + Ed25519:
```json
{"mt":29,"chain_id":143,"api_key":"<token>","timestamp":"<ms>","nonce":"<b64url>","signature":"<b64url>"}
```
**Keep-alive (mt:1)** — every 30 s, app-level (a protocol ping is answered at the edge and won't reset Perpl's idle
timer). 2 req/min. Unchanged.
```json
{"mt":1,"t":1731000000000}
```
**Post-only maker entry (mt:22, `t:1|2`, `fl:1`)** — *this is the fix; the ladder currently ships `fl:0` (GTC).*
```json
{"mt":22,"sn":41,"rq":512,"mkt":31,"acc":8801,"t":1,"p":14962500000,"s":250000,"fl":1,"lv":300,"lb":0}
```
**Amend a resting quote (mt:22, `t:7`, by `oid`)** — new builder. Moves price and/or size in place; no naked-book
window; **1 request** vs 2. Note it carries its own fresh `rq` but targets the existing `oid`:
```json
{"mt":22,"sn":63,"rq":540,"mkt":31,"acc":8801,"t":7,"oid":99213,"p":14971000000,"s":250000,"fl":1,"lv":300,"lb":0}
```
**Cancel (mt:22, `t:5`, by `oid`)** — unchanged; used only for side-flips, level-count shrink, and teardown.
```json
{"mt":22,"sn":70,"rq":544,"mkt":31,"acc":8801,"t":5,"oid":99213,"p":0,"s":0,"fl":0,"lv":0,"lb":0}
```
**Protect-on-fill — take-profit (reduce-only Close, trigger, `lp`, `lb:0`)** — placed *after* a fill, linked to the
concrete position id:
```json
{"mt":22,"sn":71,"rq":545,"mkt":31,"acc":8801,"t":3,"p":0,"s":250000,"fl":4,"lv":0,"lb":0,
 "tp":15100000000,"tpc":1,"lp":7742}
```
`tpc`: 1 GTELast / 2 LTELast (take-profit), 3 GTEMark / 4 LTEMark (stop). Long TP = `t:3,tpc:1`; short TP =
`t:4,tpc:2`; **stop-loss** = long `t:3,tpc:4`, short `t:4,tpc:3`. (Matches `PerplOrders.takeProfit/stopLoss`, which
already emit `p:0, fl:4(IOC-on-trigger), lb:0`.)

**Inbound.** Today `PerplTradeClient.handle` parses only **mt:19** (snapshot; accounts under `as`), **mt:21**
(AccountUpdate: `id`,`lfr`,`fw`), **mt:3** (ack: `cid` echoes our `sn`, `status.code==0` = admitted-for-forwarding).
I add:
- **mt:24 execution/fill report** — the authoritative fill. Expected fields (⚠ confirm, see §12): a stable fill id,
  `mkt`, `oid`, side, fill price, fill size, fee, maker/taker, **position id `pid`**, `ts`. → `onFill`.
- **mt:26 / mt:27 position open / update** — carries the **`pid`** used as `lp`. → `onPosition`.
```
mt:3   {"mt":3,"cid":41,"status":{"code":0}}                     // admitted (NOT a fill)
mt:24  {"mt":24,"fid":"...","mkt":31,"oid":99213,"sd":1,"p":...,"s":...,"fee":...,"mk":true,"pid":7742,"ts":...}
mt:26  {"mt":26,"pid":7742,"mkt":31,"sd":1,"sz":...,"e":...}     // position id for lp
```
> **Dep — quant/ux:** mt:24 gives exact size + **fee** + maker flag per fill; that's the honest `Cost/$1M` input and
> the fills feed. I expose it; they display/aggregate.

---

## 3. Request-id, correlation, and slot identity (concurrency-safe)

Three distinct ids; conflating them is the classic router bug.

**`rq` — per-ACCOUNT, strictly increasing, seeded from `lfr`.** This is the only id Perpl uses to order/forward
requests, and it is shared across *every* connection on the wallet (this app, browser tabs, the worker). Rule:
```
seed on connect:  rq_hi = max(persistedRqHi, lfr_from_mt19)
on every mt:21:   rq_hi = max(rq_hi, lfr)
allocate:         nextRq() = { rq_hi += 1; persist(rq_hi); return rq_hi }   // on the @MainActor → serialized
```
`PerplTradeClient` already does the `max(lastForwardedRq, lfr)` seed and a serialized `nextRequestId()`; I add the
**persist(rq_hi)** so a crash never reuses an id even if `lfr` momentarily lags very recent forwards. Re-seeding from
`lfr` on reconnect is what lets a fresh incarnation coexist with whatever the account already forwarded — and is why
**multi-writer must still be forbidden**: two writers that both read `lfr=100` and both allocate `101` collide; one
order is dropped/stale. The single-writer lease (§8) makes exactly one executor authoritative; the phone in cockpit
mode allocates no `rq`.

**`sn` — per-SOCKET correlation.** Monotonic per connection; echoed by Perpl as `cid` in mt:3. Used only to resolve
the `pending[sn]` continuation. Resets on each new socket. Keep as-is.

**`slotKey` — logical ladder identity, off-wire.** `"<sessionId>:<mkt>:<side>:<levelIndex>"`. Perpl's mt:22 has no
free-form client tag, so slot identity is **reconstructed**, never sent. The engine holds
`SlotMap: [slotKey: Slot]` where `Slot = {targetPrice, targetSize, oid?, lastRq, status, protection}`. This map is
the bridge between "the ladder I want" (quant) and "the orders resting on-chain" (oids).

**oid discovery.** mt:3 confirms *admission*, not the resting order's `oid`. We learn oids from
`PerplReads.openOrders` (one Multicall round-trip returns the whole market's book; **off the 120/min WS budget**) and
match by side+price-bucket+size back to a slot. Consequence: a **just-placed level is "pinned"** (can't be amended or
cancelled — both need the oid) **until the next reconcile adopts its oid**, typically <2 s. The requote loop treats a
pinned slot as immovable for that window. ⚠ *If Perpl's trading WS pushes an OrderUpdate carrying `oid` for our
resting orders, wire it in `handle` and drop the pin latency entirely (see §12).*

---

## 4. Order lifecycle

### 4.1 Post-only two-sided ladders (`fl:1`) — required fix
`PerplOrders.entry` currently emits `fl = ioc ? 4 : 0`, so the MM ladder rests as **GTC**, not post-only — it can
cross and pay taker fees, and can self-cross our own opposite quote. Fix by threading the flag:
```swift
public enum OrderFlag: Int { case gtc = 0, postOnly = 1, fok = 2, ioc = 4 }
// PerplOrderFrame: replace `ioc: Bool` with `flags: OrderFlag`; json() -> "fl": flags.rawValue
// PerplOrders.entry: for a limit maker leg, flags = input.postOnly ? .postOnly : .gtc
//                    for a market leg, flags = .ioc (unchanged)
```
Post-only makes the venue **reject any leg that would take** — including one that would cross *our own* resting
order. That is both a cost control (guaranteed maker, ~1.5 bp not taker) and the **compliance guard against
self-trading**: the engine additionally refuses to submit a bid ≥ its own resting ask (and vice-versa) before it
ever reaches the wire, so two-sided quoting can only be filled by the *real* book. (Honest-economics frame: moving a
quote via amend costs **0 bp** — fees are only on fills — so requoting is cheap; the cost lever is how often you
*fill*, which is quant/risk, not this layer.)

### 4.2 Amend (`t:7`) vs cancel(`t:5`)+replace — the core decision
For each drifting slot the engine chooses:

- **Amend (`t:7`, 1 req)** when the slot has a known `oid`, stays on the same side, and only price/size change. No
  naked-book gap; half the budget of cancel+replace. *Price changes lose queue priority regardless of method, so
  amend has no priority downside for a repricing MM — only upside.*
- **Cancel+replace (2 req)** only when: the level must **flip sides** across the mark (amend can't change `t`), the
  slot count shrinks/grows, or the `oid` is unknown/uncertain (post-reconnect before adoption). Emit as
  cancel-then-place; both count against the bucket.
- **Do nothing** when drift is below the requote threshold (§5). This dominates steady state.

> **Dep — quant:** quant supplies `desiredQuotes(mark, book, inventory) -> [DesiredLevel{side, price, size,
> levelIndex}]` each tick and the **requote threshold** `driftBp` (DGrid/RGrid/Blend/Signal reference models,
> grid-reset / TP-reset thresholds live there). I diff desired vs `SlotMap` and choose amend/cancel/place.

### 4.3 Protect-on-fill TP/SL (decouple protection from requoting)
The current design links TP/SL to the entry at placement (`tr` = entry's `rq`) via `submitBracket`, and cancels the
entry if a trigger is rejected. That is fine for one-shot orders but **fragile for a requoting bot**: every amend
would have to preserve the entry↔trigger coupling, and every ladder placement carries triggers that can be rejected
and must be swept up. I move to **protect-on-fill**:

1. **Requote phase (hot):** place/amend post-only entries **only** — no triggers. Cheap, amend-friendly, no coupling.
2. **Protect phase (on fill):** the instant a fill is *booked* (mt:24 → `pid`, or reconciled), place the reduce-only
   TP/SL linked to that **position id** (`lp`, `lb:0`) for exactly the filled size. One P1 op per fill.

This respects the real invariant — **never leave a naked *position*** (an unfilled resting limit is not exposure).
Exposure starts at fill; protection fires on the fill event, same tick. Backstops for the fill→protect window: (a)
if the protect place fails, immediately **market-flatten that filled leg** (you can't cancel a fill, so you close it)
rather than leave it naked — the adapted form of the existing "cancel the naked entry" rule; (b) the session
**max-loss kill** (risk) is the coarse net; (c) a resting *stop* can't be pre-armed while flat because `lp` needs a
live position, so protect-on-fill is the earliest correct moment.

> **Dep — risk:** TP/SL prices and the max-loss threshold are risk/quant's; I place, verify (mt:3 accepted), and
> flatten-on-failure. `submitBracket` stays available for manual one-shot tickets.

### 4.4 Batching
Over the authenticated WS each mt:22 is **one request** (there is no *confirmed* multi-order frame — ⚠ §12). So
"batching" here is: **(a) pipeline** frames (send back-to-back, resolve acks by `cid`) to cut wall-clock latency
without changing count — I change `place`/`placeAll` from await-each to send-all-then-collect; **(b) coalesce** —
prefer 1 amend over 2 cancel+replace, and collapse repeated requotes of the same slot within a tick to its newest
target (one op, not a stale queue); **(c)** the on-chain `execOrders([...])` *does* batch many descs in one tx, but
that's the gas/signature path — irrelevant to the keyless WS loop except for the final teardown fallback.

---

## 5. The 120 req/min budget

Per **socket**, per **minute**. Crucially, **on-chain reads (`PerplReads`) and signed-REST fills go over RPC/HTTPS,
not the trading WS**, so they cost **0** of the 120. The budget is only: sign-in, keep-alive, and order-ops
(place/amend/cancel/protect).

**Allocation (of 120/min):**
| Bucket | Budget | Notes |
|---|---|---|
| Keep-alive `mt:1` | **2** | 30 s cadence, fixed (already implemented). |
| Burst reserve | **18** | Never scheduled in steady state. Covers kill-switch cancel-all + flatten and post-only-reject re-prices. Full teardown of a 2-sided N=5 ladder = 10 cancels (+ up to 5 protect cancels) — 18 keeps it from starving requotes. |
| **Steady order-ops** | **100** | ≈ **1.667 req/s**. Requotes (amend) + protect-on-fill draw from here. |

**Token bucket** governs the steady pool: capacity **100**, refill **100/60 = 1.667 tokens/s**; each place/amend/
cancel costs **1**; keep-alive drawn from its own reserved 2/min, never the bucket. Kill-switch / protect-flatten may
dip into the 18-reserve when the bucket is dry.

**Max sustainable requote cadence for N levels/side (2N resting orders):**
- Amend, whole ladder every cycle: cost `2N`; `f_max = 100 / 2N` full requotes per minute → **period ≈ 1.2·N s**.

| N/side | orders 2N | amend full-requote period | cancel+replace-all period |
|---|---|---|---|
| 3 | 6 | **3.6 s** | 7.2 s |
| 5 | 10 | **6.0 s** | 12 s |
| 8 | 16 | **9.6 s** | 19.2 s |
| 10 | 20 | **12 s** | 24 s |

Amend is **2× the cadence** of cancel+replace-all at equal budget (and ~**4×** vs a naive cancel-all+replace-all
refresh, which is `4N`/cycle). **But you almost never move the whole ladder:** with a `driftBp` threshold only the
levels the price actually passed requote, so typical amends/cycle `m ≪ 2N`. Therefore **decouple the decision tick
from the amend budget**: run the tick fast (default **1.5 s**) and let the token bucket cap actual frames. Example:
tick 1.5 s, typical `m=2` inner levels drift → 2 req/1.5 s = 80/min < 100 → sustainable indefinitely while tracking
tightly.

**Backpressure / coalescing when the bucket runs low** (priority order):
- **P0** kill-switch cancel-all + flatten — may use the 18-reserve, bypasses the bucket.
- **P1** protect-on-fill (place TP/SL) — a fill without protection is exposure; always funded next.
- **P2** requote **inner** levels (nearest mark — highest fill probability, most adverse-selection sensitive).
- **P3** requote **outer** levels.
- **P4** (re)seed missing levels after reconcile.

When tokens < demand: (1) serve by priority, defer the rest; (2) **coalesce** — a slot keeps a single *pending
target*, so a newer requote overwrites an undrained older one (never queue stale prices); (3) **auto-widen** the
effective `driftBp *= backpressureFactor` so fewer levels qualify — graceful degradation — and surface "Throttled" to
ux. This is why **amend + threshold-gated requoting beats naive refresh**: naive refresh spends `4N` every tick
regardless of whether price moved, caps you at 5 cycles/min for N=5, and blinks the book naked each cycle; amend +
threshold spends only on levels that truly moved, tracks 2–4× tighter, and never leaves a gap.

---

## 6. Fills & truth — never fabricate, never lose a fill

**Authoritative sources, in order:** (1) **mt:24** fill report (real-time, exact size/fee/pid); (2) **signed REST
`/v1/trading/fills`** (`PerplService.fills`, already implemented — used to backfill anything missed while the socket
was down); (3) a **corroborated on-chain delta** (position/balance change confirmed across two reads). An order
**leaving the book is only a *hint* to reconcile — never itself a booked fill.** This generalizes the existing
`MMWatcher` correctness rule ("a failed `try?`→nil read must not be treated as flat"): *booking* requires positive
evidence, not absence.

**Idempotent fill ledger.** A persisted set keyed by a **stable fill id** (mt:24 `fid`; REST `PerplFill` id):
```
book(fill):  if ledger.contains(fill.id) { return }        // dedup: same fill via WS and later via REST → once
             ledger.insert(fill.id); session.volume += fill.price*fill.size; session.fees += fill.fee
             if fill.opensExposure { schedule(.protectOnFill(pid: fill.pid, ...)) , P1 }
```
Because booking is keyed by id, a fill seen on the socket *and* re-seen on the post-reconnect REST page is counted
exactly once — so **a dropped socket can neither fabricate nor lose a fill**.

**Post-only reject** (mt:3 `code != 0` on an entry = "quote would cross"): mark the slot *not resting*, do **not**
book anything, and re-price one tick **inside** the crossing side's best (`PerplFeed.bestBid/bestAsk`) before a
bounded retry (≤2), drawing from the burst reserve. Repeated rejects on a level → back it off by the spread floor and
let the next tick re-derive from quant. Never blind-resubmit (burns budget, can loop).

**Reconcile routine** (run on every connect, after any reject storm, and on a fixed slow cadence, e.g. 15 s):
```
1. mt:19 snapshot            → seed rq_hi from lfr; adopt any snapshot open orders/positions
2. REST fills since lastTs   → book(fill) for each (dedup by id)      // recovers socket-down fills
3. openOrders (on-chain)     → rebuild SlotMap oids (match side+priceBucket+size); flag orphans
4. positions (on-chain)      → ensure every live position has protection; place if missing (P1)
5. resume requoting
```
> **Dep — arch/infra:** `PerplReads.openOrders/positions/account` must hit a **fresh** Monad RPC. The brief warns
> public RPC can serve ~24 h-old state for some calls — that would corrupt oid adoption and fill-by-delta. Confirm
> `config.rpcURL` is a low-latency, current-state endpoint for these reads (possible API-need, §13).

---

## 7. Connection management for a long session

**One socket, 4/wallet cap, shared with browser tabs — and now the worker.** `PerplTrading` already enforces one
socket, single-flight connect (`connectTask`), tear-down-before-connect, backoff (5/10/20/40/80 s cap 120; conn-cap
starts 30 s), 3401-never-retry, and app-level `mt:1` idle avoidance. I keep all of it and add:

**Executor vs Cockpit mode.** The 4 slots are shared across the app, any `app.perpl.xyz` tabs, **and the worker**. So
during a **worker-run session the phone must not also hold a trading socket** — two writers would collide on `rq`
(§3) and burn slots. `PerplTrading` gains a mode:
- `.executor` — owns the socket, holds the single-writer lease, runs the engine (Architecture B / attended).
- `.cockpit` — **no trading socket**; observes the running session from the worker's status stream + reads truth
  directly (on-chain `PerplReads` + signed-REST fills, both keyless of the WS). This is the phone's state whenever
  the worker holds the session. Emergency stop from cockpit calls the worker's kill endpoint (preferred) or, as the
  ultimate backstop, sends `allowOrderForwarding(false)` on-chain — a global kill that needs no lease and makes every
  forwarded order fail `sr:34`.

**Self-healing mid-session.** `ensureConnected()` today is *lazy* (reconnects on the next order-op). For an active
executor that leaves the ladder stale after a drop. Add **eager self-heal**: on `onDisconnect` for a non-auth,
non-cap close during an active session, schedule a reconnect after backoff and, on success, run the **reconcile
routine** (§6) before resuming — so a drop never strands resting orders or loses a fill. Auth (3401) and cap (1008)
closes stay surfaced to ux, not auto-retried blindly (cap retries only after the 30 s+ backoff, with a "close Perpl
web tabs" hint the code already produces in `PerplClose.message`).

**Health surface** for the ux status bar: socket age, last `mt:1` sent, last frame received, `PerplClose` reason,
mode, and slots-hint. Cheap fields off the client.

---

## 8. Idempotency & crash recovery (no orphaned / duplicated orders)

Five mechanisms, layered:

1. **Single-writer lease.** A record (Supabase table or the DO's own storage) keyed `wallet:accountId`:
   `{holder, mode, epoch, expiresAt}`. An executor must hold a valid unexpired lease to place orders and heartbeats
   to extend it; a restarted worker takes the lease only after the old one expires/releases, *then* reconciles. The
   phone in cockpit takes no lease. This kills the fundamental duplication source: two incarnations placing at once.
2. **Write-ahead session log (intent → outcome).** Before any order-op, persist the *intent*
   `{slotKey, op, targetPrice, targetSize, rq, ts}` (device: a small SQLite/JSON store; worker: DO storage/D1).
   After the mt:3 ack and oid adoption, persist the outcome. On restart, replay every intent lacking an outcome:
   reconcile it against on-chain openOrders + REST fills → *landed* (adopt oid), *filled* (book once), or *absent*
   (safe to re-place). Transport is at-least-once; this makes the *effect* exactly-once.
3. **Reconcile-before-act.** A (re)started engine **never places a fresh ladder blind**. It first snapshots on-chain
   open orders/positions, adopts existing resting orders into the SlotMap (so it *manages*, not duplicates, what a
   prior incarnation left), and places only the missing slots. Prevents both duplication (won't re-place a resting
   slot) and orphans (adopts prior orders so teardown can find them).
4. **`rq` re-seed from `lfr`** (§3) — a replayed op gets a *fresh* `rq > lfr`, so the server never silently folds it
   into a stale request; combined with reconcile-first, replays only ever target genuinely-missing slots.
5. **Idempotent teardown.** `MMExecutor.stop` already cancels every resting order for the market, closes every
   position, and **verifies clean**, returning false to retry if anything remains. Cancels are idempotent (cancelling
   a gone oid is a harmless reject). Keep this; the engine's `killSwitch()` calls it in a loop until clean, funded
   from the burst reserve.

---

## 9. Concrete Swift/worker deliverables

**DyorKit — extend the wire:**
- `PerplOrderFrame`: replace `ioc: Bool` → `flags: OrderFlag`; `json()` emits `"fl": flags.rawValue`.
- `PerplOrders.entry(_:accountId:head:ttlBlocks:)`: honor `input.postOnly` → `flags = .postOnly` for limit legs.
- `PerplOrders.change(oid:price:size:market:accountId:leverageHdths:postOnly:)` → `PerpOrderType.change` (wire `t:7`),
  `lb:0`, carries new `p`/`s` and `oid`.
- `PerplTradeClient.handle`: add `case 24` (→ `onFill`), `case 26, 27` (→ `onPosition`); add
  `public var onFill/onPosition` callbacks; change `place/placeAll` to pipeline (send-all, resolve by `cid`);
  add `persist(rq_hi)` in `nextRequestId()`.

**DyorKit — new engine:**
- `PerplExecutionEngine` (actor): holds `SlotMap`, `TokenBucket`, `FillLedger`, `SessionLog`; API
  `start(strategy:)`, `requoteTick(desired:)`, `onFill(_:)`, `onPosition(_:)`, `reconcile()`, `killSwitch()`.
- `TokenBucket` (capacity 100, refill 1.667/s), `FillLedger` (id-keyed, persisted), `SessionLog` (WAL),
  `PerplReads` protocol (§1).

**App:** `PerplTrading` gains `mode`, lease client, and fans `onFill/onPosition` into the engine; `MMWatcher`
becomes the on-device *driver* that pulls `desiredQuotes` from quant each tick and calls `engine.requoteTick`;
`MMExecutor.place/stop` fold into `engine.reconcile/killSwitch`.

**Worker (greenfield):** `PerplExecutorDO` Durable Object — Ed25519 sign-in, one socket, the §10 algorithm,
`/api/mm/start|stop|status(SSE)|kill`; enforces lease + auto-expiry at `session.endsAt` (calls `killSwitch` then
`allowOrderForwarding(false)`).

---

## 10. Pseudo-code

```swift
// ── Quote-update path (one tick). Runs on device (MMWatcher driver) and, ported, in the DO. ──
func requoteTick(desired: [DesiredLevel]) async {          // desired: from quant
    guard leaseHeld, socket.signedIn, socket.forwardingEnabled else { return }
    let ops = plan(desired: desired, slots: slotMap)       // classify each slot
    for op in ops.sorted(by: priority) {                   // P0 kill > P1 protect > P2 inner > P3 outer > P4 seed
        guard bucket.tryTake(1) || op.priority <= .protect else {  // P0/P1 may dip into burst reserve
            coalescePending(op); continue                  // budget tight → keep newest target only, defer
        }
        log.intent(op)                                     // write-ahead BEFORE the wire
        let rq = client.nextRequestId()
        switch op.kind {
        case .amend(let oid):  send(PerplOrders.change(oid: oid, price: op.price, size: op.size, ...), rq)
        case .place:           send(PerplOrders.entry(op.input(postOnly: true), ...), rq)   // fl:1
        case .cancel(let oid): send(PerplOrders.cancel(perpId: op.mkt, orderId: oid, ...), rq)
        }
    }
}

func plan(desired, slots) -> [Op] {
    var ops = [Op]()
    for d in desired {
        let slot = slots[d.slotKey]
        if slot == nil { ops.append(.place(d)) }                          // missing → seed (needs oid before it can move)
        else if slot!.oid == nil { continue }                             // pinned: oid not yet adopted (<2s) → leave
        else if d.side != slot!.side { ops.append(.cancel(slot!.oid!)); ops.append(.place(d)) } // side flip
        else if driftBp(d.price, slot!.targetPrice) >= threshold*backpressureFactor {
            ops.append(.amend(slot!.oid!, price: d.price, size: d.size)) // the common, cheap case
        }                                                                 // else: within threshold → no-op
    }
    for s in slots where !desired.contains(s.slotKey) { ops.append(.cancel(s.oid!)) } // shrink ladder
    return ops
}

// ── Fill truth ──
func onFill(_ f: FillEvent) {                              // from mt:24
    guard !ledger.contains(f.id) else { return }           // idempotent
    ledger.insert(f.id); session.volume += f.notional; session.fees += f.fee
    if let slot = slotMap.bySide(f.mkt, f.side, near: f.price) { slot.status = .filled }
    if f.opensExposure { schedule(.protect(pid: f.pid, size: f.size), priority: .protect) }
}

// ── Reconnect / restart ──
func onReconnectOrStart() async {
    let snap = try? await client.awaitSnapshot()           // mt:19 → seeds rq_hi from lfr
    if let page = try? await reads.fills(since: session.lastFillTs) { page.forEach(book) } // socket-down backfill
    let acct = try? await reads.account(owner)             // ⚠ fresh RPC
    let orders = try? await reads.openOrders(acct, [market]); adoptOids(orders)  // reconcile-before-act
    let pos = try? await reads.positions(acct, [market]);   ensureProtected(pos)
    replayUnfinished(log)                                   // WAL: land / book / re-place
    resumeRequoting()
}
```

---

## 11. UI I own (hand the rest to ux)

Inside the live status bar (`MMStatusView` today), a compact **execution row**:
- **Connection pill:** `Connected · 42s` / `Reconnecting… (5s)` / `Cockpit (worker)` / `Throttled` / the exact
  `PerplClose.message` on 1008 auth/cap.
- **Budget meter:** `req 78/100·min` with the current requote period (`every 1.5s`), turning amber when
  `backpressureFactor > 1` (throttled) so the user *sees* the rate limit at work.
- **Truth line:** last booked fill time + source (`socket` / `reconciled`), so a user knows fills aren't guessed.

The Sessions table, presets, pre-trade analytics, and the volume/duration/participation config are **ux/quant/reco**;
I only feed them `session.{volume, fees, fills[], costPer1M}` and the connection/budget health.

---

## 12. Explicit dependencies on other sections

- **arch:** custody + host decision (session-scoped key server-side vs Keychain-only); I assume Hybrid C and build
  the cockpit split + lease around it. The lease store (Supabase vs DO storage) is a shared choice.
- **quant:** `desiredQuotes(mark, book, inventory) -> [DesiredLevel]`, the `driftBp` requote threshold, TP/SL prices,
  reference-price models (DGrid/RGrid/Blend/Signal), grid-reset/TP-reset thresholds. I execute; I don't price.
- **infra:** iOS background execution (BGTask/push) and the Worker/DO runtime + deployment; a **fresh Monad RPC** for
  `PerplReads` (non-stale state). My self-heal/keep-alive lives *inside* whatever foreground/worker lifetime infra
  provides.
- **risk:** max-loss kill threshold, inventory caps, liquidation math. I provide the fast `killSwitch()` + fill/
  position truth they trigger on; the on-chain `allowOrderForwarding(false)` global-kill is the shared backstop.
- **reco:** default cadence/threshold/level-count presets per participation rate (Aggressive/Normal/Passive) — feed
  them into the tick period and `driftBp`.
- **ux:** consumes the state/events in §11; owns the Sessions table and config screens.

## 13. External APIs / data / credentials the user must provide
- **Fresh Monad RPC endpoint** (current-state, low-latency) for `account`/`positions`/`openOrders` during a session —
  public RPC's ~24 h-stale reads would corrupt reconciliation. (Paid RPC likely.)
- **Confirmation from the user's Perpl contacts of the inbound schemas:** mt:24 fill fields (esp. a **stable fill
  id**, `fee`, maker flag, `pid`), mt:26/27 position frames, and **whether the trading WS pushes an OrderUpdate with
  `oid`** for resting orders (would remove the oid-pin latency). Design is safe without it (on-chain oid adoption) but
  tighter with it.
- **Whether Perpl's trading WS accepts a batched/multi-order mt:22 array** (would cut the per-frame budget cost).
- **Whether `t:7` Change preserves a `tr`-linked trigger's activation** — moot under protect-on-fill (which uses
  `lp` post-fill), but confirms the fallback.
- **Perpl/Monad maker-rebate / MM-reward / points program terms** (from §0/§2 of the brief) — needed to state honest
  net cost; not required to build the engine.

## 14. Open questions
- Does mt:3 ever carry the resting `oid` (some venues put it in the ack)? If so, adopt from the ack and skip the pin.
- Post-only reject: is it an mt:3 non-zero code, or an admit-then-immediate-kill on mt:24? Determines whether the
  reject handler keys off the ack or a fill/cancel report. (Handle both defensively until observed.)
- Multi-writer edge: is `rq` validated as strictly-`> lfr`, or monotonic-per-connection-tolerant? If strict, the
  single-writer lease is mandatory (assumed); if tolerant, cockpit could co-exist for read-only order-status — still
  not recommended for slot pressure.
```
