# Execution Architecture & iOS/Worker Engineering — the Spine

*DyorHQ Market-Making feature. This section decides the execution model the other five sections
(quant / infra / risk / reco / ux) hang off. Everything here is grounded in the live code
(`PerplTrading.swift`, `MMWatcher.swift`, `PerplTradeClient.swift`, `worker/index.ts`, the DyorHQ Supabase
project `fmnjqrguvopusfufmirs`) and the verified Perpl API facts in the brief. Prefer decisions over menus.*

---

## 0. The one-paragraph decision

**Default architecture = Hybrid (brief §4·C), with the executor living in a Cloudflare Durable Object and the
phone as a cockpit — but built as the *safest* variant that still hits "lots of volume over a short time box."**
The requote loop and the single Perpl trading socket run **server-side in a Durable Object**, because iOS suspends
an app within seconds of backgrounding and *cannot* sustain a 10–1000-minute requoting loop or hold a socket in a
pocket (brief §4). The DO trades with a **session-scoped, trade-only (scope_mask=2, cannot withdraw),
auto-expiring, phone-revocable Ed25519 key whose secret is generated inside the DO and never leaves it** — the
phone only ever sees the *public* key and supplies the wallet's EIP-712 signature that binds it to trade scope.
We also ship **Option B (on-device, foreground-only, fully self-custodial)** as an explicit **"Attended
(max-custody)"** mode for short sessions, where the key stays in Keychain and nothing leaves the device — honest
about the tradeoff: it only runs while the app is on screen. The custody cost of Hybrid is real and is stated
plainly to the user at arm time; the mitigations (no-withdraw scope, time-box, unilateral on-chain kill) make it
a bounded, revocable, user-granted trust decision rather than a blank cheque.

**Why not pure server-side (A):** identical infra to Hybrid, but it discards the on-device self-custodial path that
some users will (rightly) demand for small/attended runs, and it hides the custody decision instead of foregrounding
it. Hybrid = A's engine + B's honesty + a hard kill the phone owns.

**Why not pure on-device (B) as default:** it structurally cannot meet the headline promise. A phone that suspends
mid-session stops requoting, stops generating volume, and can only rely on the native TP/SL keeper to protect
existing positions. Fine for a 10-minute attended burst; useless for a 3-hour campaign.

---

## 1. The load-bearing constraint that shapes everything: one socket + 120/min, **per wallet**

Two Perpl limits dominate the whole design and are *per wallet address*, not per key or per device (brief §2):

- **Hard cap 4 trading sockets per wallet**, shared with app.perpl.xyz browser tabs. A 5th → `1008 "too many
  connections"`.
- **~120 requests/min per socket.** Keep-alive `{mt:1}` every 30 s costs 2/min, leaving **~118/min ≈ 1.97
  order-ops/second** for the *entire* wallet across all levels and all markets.

Consequences that are non-negotiable:

1. **One socket owner per wallet, not per session.** rq (the strictly-increasing per-account request id seeded
   from `AccountUpdate.lfr`) is also per-account. Therefore a wallet running MM on BTC *and* ETH must **share one
   socket and one rq sequence**. The executor is a **per-wallet Durable Object (`PerplSocketDO`, id =
   `idFromName(walletLower)`)** that multiplexes N market sessions over the single socket. Sessions are internal
   `SessionRunner` objects, not separate sockets.
2. **The phone must release its trading socket while a Hybrid session runs.** Phone `PerplTrading` (1 socket) +
   `PerplSocketDO` (1 socket) = 2, leaving 2 slots of headroom for the Perpl web app. On arm, the phone calls
   `PerplTrading.disconnect()` and thereafter reads status from the DO stream and reads
   positions/orders from **on-chain RPC** (which needs no trading socket). The phone never competes with its own
   executor for a slot.
3. **Amend (`t:7 Change`) is mandatory, cancel+replace is the fallback.** At 1.97 ops/s a naive cancel→place→tp→sl
   for a 5-level-per-side ladder (10 orders) is 20–40 ops ≈ 10–20 s per requote — too slow to "stay near market."
   The requote engine diffs desired-vs-live and **amends in place** (~1 op/drifted level). See §5.

> **Dependency — quant/infra:** the 4-socket cap means concurrent-session count per wallet is bounded by socket
> *ops budget*, not sockets. Quant must size ladders and requote cadence to fit 118/min shared across all a wallet's
> live markets. Infra must ensure the Perpl web app isn't also burning slots for a power user.

---

## 2. Component map

```
┌────────────────── iPhone (SwiftUI / DyorKit) ──────────────────┐
│  MarketMakingView ── config + pre-trade analytics (quant)       │
│  MMSessionConfig / MMSessionStatus / MMSessionState (models)    │
│  MMSessionClient  ── @MainActor @Observable REST + /stream      │
│  MMSessionView    ── live cockpit + KILL switch (ux)            │
│  MMEngine (actor) ── Option-B on-device attended engine         │
│  PerplTrading (@MainActor) ── forwarding on/off, enroll, Opt-B  │
│  BackgroundTasks  ── BGAppRefresh + BGProcessing (notify only)  │
└──────────┬───────────────────────────────────┬────────────────┘
    HTTPS  │ Supabase JWT (wallet_address)      │  WS/SSE status
    /api/mm│                                    │
┌──────────▼───────────────────────────────────▼────────────────┐
│           Cloudflare Worker  (~/Hackathon/worker)               │
│  mm/router.ts  → routes /api/mm/* to the DO                     │
│  ┌──────────── PerplSocketDO  (id = walletLower) ───────────┐   │
│  │  ONE authed Perpl trading WS  (mt:29 → mt:22 …)          │   │
│  │  session Ed25519 key (secret AES-GCM-wrapped, DO-only)   │   │
│  │  rq counter · order-intent ledger · token-bucket budget  │   │
│  │  SessionRunner[]  (one per live market session)          │   │
│  │  alarm() → requote tick + expiry + reconcile             │   │
│  │  status fan-out (WS/SSE) · Supabase mirror (service key) │   │
│  └─────────────────────────────────────────────────────────┘   │
└───────┬───────────────────────────────┬───────────────────────┘
   Perpl │ trading + market-data WS      │  service_role writes
   Monad │ RPC (rpc1) reads = truth      ▼
         ▼                        Supabase  mm_sessions / mm_fills /
   app.perpl.xyz                  mm_events / mm_presets  (RLS by wallet)
```

---

## 3. iOS: what runs on-device, what must not, and how a session survives app death

### 3.1 On-device (attended, fast, user-facing) — new & evolved Swift types

| File | Type | Role |
|---|---|---|
| `Strategy/MMSession.swift` *(new)* | `struct MMSessionConfig: Codable, Sendable` | Superset of today's `MMStrategy`: adds `volumeTarget`, `durationS`, `participation` (`.aggressive/.normal/.passive`), `referenceModel` (`.mid/.grid/.rgrid/.dgrid/.blend/.signal`), `gridResetBp`, `tpResetBp`, `maxLossPct`, `custody` (`.hybrid/.attended`). |
| `Strategy/MMSession.swift` | `struct MMSessionStatus: Codable, Sendable` | The live snapshot streamed from the DO: `state`, `volumeDone`, `volumeTarget`, `realizedPnl`, `unrealizedPnl`, `feesPaid`, `costPerMillion`, `filledPct`, `restingCount`, `lastRequoteAt`, `expiresAt`, `budgetUsedPct`, `lastError`. |
| `Strategy/MMSession.swift` | `enum MMSessionState: String, Codable` | `draft, preparing, awaitingSignature, arming, running, paused, stopping, reconciling, settled, expired, killed, error`. |
| `Strategy/MMSessionClient.swift` *(new)* | `@MainActor @Observable final class MMSessionClient` | Talks to the Worker: `prepare/start/pause/resume/stop/kill/status`, and subscribes to `/stream`. Holds the Supabase JWT. This is the cockpit's data source in Hybrid mode. |
| `Strategy/MMEngine.swift` *(new)* | `actor MMEngine` | The **Option-B on-device** requote engine (background actor; see §3.4). |
| `Strategy/MMSessionView.swift` *(new; supersedes `MMStatusView`)* | SwiftUI | Live cockpit: PnL, volume vs target, Cost/$1M, budget, fills feed, **Stop & Flatten** + **hard Kill** (ux). |
| `Strategy/MMWatcher.swift` *(evolved)* | `@MainActor final class MMWatcher` | Becomes the **app-lifecycle bridge** (foreground→`engine.resume()`, background→`engine.suspend()`) for Attended mode, and the stream re-attach driver for Hybrid. The 20 s flat-only recycle is retired in favor of `MMEngine.requote()`. |
| `Wallet/PerplTrading.swift` *(extend)* | add `func disableForwarding(env:wallet:)` | Sends `allowOrderForwarding(false)` from the user's wallet — the on-chain kill (§6). Mirrors the existing `enableForwarding`. |

On-device responsibilities, all of them:
- **Config + pre-trade analytics** (Cost/$1M, Max Loss, est. fills/duration, liq price) — *quant/risk own the math*.
- **Two explicit wallet actions** at arm: (a) `allowOrderForwarding(true)` on-chain via `PerplTrading.enableForwarding` (existing, correct — treats a confirmed tx as authority, doesn't wait on the WS `fw` echo); (b) a single **secp256k1 EIP-712 signature** binding the session key to trade scope (via `any DigestSigner` — `LocalWallet` or Privy, exactly as `PerplTrading.enroll` already does).
- **Live status** (subscribe to the DO stream) and **the kill switch** (§6).
- **Attended execution** for `custody == .attended` (the whole loop runs on-device while the app is foreground).

### 3.2 What MUST run server-side (never on-device)

- The **continuous requote loop** for the full time box. iOS gives no general long-running background execution.
- The **single persistent authenticated trading socket** for the session. iOS drops it on suspend; URLSession masks the close as POSIX 57 (we already decode the real reason via `PerplClose`, but we can't keep it *open* backgrounded).
- **Rate-budgeted order ops, reconciliation, and time-box expiry** — must fire on wall-clock time the phone can't guarantee.

### 3.3 BGProcessingTask / BGAppRefreshTask — the realistic (small) role

They are **not** the executor and must never be sold as one (brief §4). They are opportunistic, minutes-to-hours apart, not guaranteed, and cannot hold a socket. Concrete registration in `App/BackgroundTasks.swift`:

- `BGAppRefreshTaskRequest("fun.dyorhq.mm.refresh")` — when granted, do a *bounded* job: `MMSessionClient.status()` for each running session, one on-chain reconcile read, and **fire a local notification** if the session errored, tripped max-loss, or finished. No trading.
- `BGProcessingTaskRequest("fun.dyorhq.mm.reconcile")` (`requiresNetworkConnectivity=true`, `requiresExternalPower=true`) — a longer opportunistic on-chain reconcile + Supabase sync while charging.

**The real signal channel is APNs push from the Worker** (the DO sends a push on: max-loss trip, error, fill-of-note, completion, key-expiry). This *wakes/notifies* the user; it does not run a loop. **Flag (external):** APNs is not yet wired — see §8.

### 3.4 Swift concurrency model — the @MainActor client vs the background engine actor

- **`PerplTrading` stays `@MainActor @Observable`** — the single foreground trading client. It owns the on-chain forwarding toggle, enrollment, the Attended-mode socket, and UI-observable status. Keep it on the main actor: it's small, event-driven, and everything it mutates is UI state.
- **New `actor MMEngine` (Sendable, off the main actor)** owns the Attended-mode requote *logic*. It computes ladders (pure functions on the value type `MMSessionConfig`/`MMStrategy`, already `Codable/Hashable` → naturally `Sendable`) off-main, then hands finished `[PerplOrderFrame]` (already `Sendable`) to the `@MainActor PerplTrading.placeAll(...)` via `await`. This is the clean split the brief asks for: **compute in the actor, send from the one main-actor client.**
- Concurrency correctness already established in the code we keep: single-flight connect, tear-down-before-connect, the "failed on-chain read (`try?`→nil) must NOT be read as flat" rule (`MMWatcher.tick`), backoff on `PerplClose`. `MMEngine` inherits all of it by delegating I/O to `PerplTrading`.

### 3.5 How a session survives app close / kill / relaunch

- **Hybrid:** the session lives in the **DO** — independent of the phone entirely. On relaunch the phone lists active sessions (Supabase `mm_sessions where wallet=? and status in (running,paused)`), re-attaches `MMSessionClient` to `/stream`, and shows live state. A local mirror `MMSessionStore` (UserDefaults, keyed per wallet like `MMStore`) remembers the active `sessionId` for an instant re-attach; **Supabase/DO are the source of truth**, UserDefaults is only a hint. App killed for hours → session kept running → user reopens to a live cockpit. This is the property Option B can never have.
- **Attended:** the config is persisted (`MMStore`, `active=true`); native venue TP/SL keeps open positions protected while the app is dead (the current safety net); on relaunch `MMEngine` **reconciles against on-chain reads before placing anything** (§7) and resumes. It generated no volume while suspended — which is exactly why Attended is the non-default, short-session mode.

---

## 4. The Worker: `PerplSocketDO` (Cloudflare Durable Object)

The existing `worker/index.ts` is a vinext (Next-on-Workers) entry that already proxies Perpl's market-data WS
(`/api/perpl/ws`). We **add** an MM subsystem under `worker/mm/` and a Durable Object binding. DOs are the right
primitive: single-threaded per-instance (no rq races), durable `ctx.storage` that survives eviction, and
`ctx.storage.setAlarm()` as the requote/expiry timer. **Cloudflare Workers WebCrypto supports Ed25519**
(`crypto.subtle.generateKey({name:"Ed25519"},…)`, sign/verify), so the session key is generated and used entirely
inside the DO with no third-party lib.

### 4.1 Modules (`worker/mm/`)

| Module | Responsibility |
|---|---|
| `router.ts` | Routes `/api/mm/*` → `env.PERPL_SOCKET_DO.get(idFromName(wallet))`. Verifies the Supabase JWT and that its `wallet_address` matches the session wallet. |
| `PerplSocketDO.ts` | The DO class: one authed socket, rq counter, key store, intent ledger, `SessionRunner[]`, `alarm()`, status fan-out. |
| `perplTrading.ts` | TS mirror of DyorKit `PerplTradeClient`/`PerplOrders`: `mt:29` sign-in, `mt:22` frame build (`t`,`fl`,`tp`,`tpc`,`lp`,`tr`,**`lb:0`**), keep-alive `mt:1`, and inbound handling of `mt:3` ack (code 0 = admitted-for-forwarding only), **`mt:24` real fill outcome**, `mt:26/27` position ids, `mt:19 (as)`/`mt:21` account+fw+lfr. |
| `perplAuth.ts` | Ed25519 via WebCrypto; `POST /v1/api-key/payload`, `enroll`, and `revoke/delete` (see §8 flag); PoP over the 32-byte EIP-712 digest. |
| `requote.ts` | Ladder eval (mirror `MMStrategy.levels`) + the desired-vs-live diff/amend engine (§5). **Depends on quant.** |
| `reconcile.ts` | Monad RPC + Multicall3 reads of `openOrders`/`positions` = source of truth on reconnect and every Nth tick (§7). |
| `budget.ts` | Token bucket: capacity 4, refill 118/60 ≈ 1.97/s; every send acquires a token. |
| `supabase.ts` | Service-role writes to `mm_sessions/mm_fills/mm_events` (mirror for History/Analytics + phone re-attach). |
| `auth.ts` | Supabase JWT verify (`wallet_address` claim), reusing the `wallet-auth` function's signing model. |
| `crypto.ts` | AES-GCM wrap/unwrap of the session secret with `env.SESSION_WRAP_KEY` (defense in depth over DO-at-rest encryption). |

### 4.2 DO storage keys (`ctx.storage`)

```
key:pub            hex Ed25519 public key of the session key
key:secret         AES-GCM(wrapped) 32-byte Ed25519 secret   ← never leaves the DO
key:token          Perpl api_key bearer token
key:expiresAt      ms epoch — session hard stop
fw:granted         bool — allowOrderForwarding confirmed on-chain this session
rq:last            last strictly-increasing request id (re-seeded = max(stored, lfr) on reconnect)
sessions:index     [sessionId]
session:<sid>      { config, state, startedAt, volumeDone, pnl, fees, filledPct, market }
intent:<sid>:<levelId>  { levelId, side, targetPrice, targetSize, rq, oid?, tpOid?, slOid?, state }
status:<sid>       last status snapshot (for late subscribers / BGRefresh polls)
```

`levelId` is deterministic: `"<market>:<side>:<priceBucket>:<generation>"` — the anti-double-place primitive (§7).

### 4.3 The one socket, the budget, and status streaming

- **Socket:** the DO opens exactly one `wss://app.perpl.xyz/ws/v1/trading`, signs in `mt:29`, keeps alive with the
  **application** ping `{mt:1}` every 30 s (a WebSocket protocol ping is answered at the CF edge and never counts as
  activity — the same lesson already encoded in `PerplTradeClient`). On close it decodes the real reason (3401 →
  never retry the key; `1008 too many connections` → back off 30 s; `1008 too many requests` → back off + slow the
  budget) and reconnects with the intent ledger intact.
- **Budget:** `budget.ts` token bucket gates *every* `mt:22`. Requote ticks are sized to the remaining bucket; ops
  that don't fit spill to the next tick.
- **Status → device:** the DO exposes `/api/mm/session/:id/stream`. **Use SSE** (`text/event-stream`) as the
  primary channel — it survives phone backgrounding/foregrounding cleanly, auto-reconnects with `Last-Event-ID`, and
  is trivial from `URLSession.bytes(for:)`. Offer WS only if a section needs bidirectional. The DO also **persists**
  each material change to Supabase so a phone with no live stream still reads accurate state via RLS.

### 4.4 Device ↔ Worker API + session state machine

All requests carry `Authorization: Bearer <supabase-jwt>`; the Worker matches the JWT `wallet_address` to the
session wallet. Two-step arm keeps the session secret in the DO:

```
POST /api/mm/session/prepare
  body: { wallet, config }
  → DO creates the session, generates the Ed25519 key IN the DO, calls Perpl /v1/api-key/payload
  → 200 { sessionId, publicKeyHex, typed_data, mac, expiresAt }

  # phone: wallet secp256k1-signs the EIP-712 digest; ensures allowOrderForwarding(true) on-chain

POST /api/mm/session/start
  body: { sessionId, walletSignature, config }
  → DO computes Ed25519 PoP with its own secret, calls /v1/api-key/enroll (scope_mask=2),
    stores {token,secret,pub,expiresAt}, connects the trading WS, arms the first SessionRunner,
    sets the requote alarm.  → 200 { state: "running" }

POST /api/mm/session/:id/pause    → cancel resting, KEEP positions (protected by native TP/SL); state=paused
POST /api/mm/session/:id/resume   → re-place ladder after a fresh reconcile; state=running
POST /api/mm/session/:id/stop     → graceful: cancel-all + flatten + verify clean (port MMExecutor.stop)
                                      → reconciling → revoke key → settled
POST /api/mm/session/:id/kill     → hard: best-effort cancel+flatten, revoke key, wipe key:secret; state=killed
GET  /api/mm/session/:id/status   → MMSessionStatus snapshot
GET  /api/mm/session/:id/stream   → SSE live status
GET  /api/mm/wallet/:addr/sessions→ list active (also mirrored in Supabase for RLS reads)
POST /api/mm/wallet/:addr/panic   → revoke key + stop ALL sessions for the wallet (worker-side half of the kill)
```

**Session state machine** (`MMSessionState`, enforced in the DO):

```
draft → preparing → awaitingSignature → arming → running ⇄ paused
running/paused → stopping → reconciling → settled
any → error   (recoverable: back off & retry, or surface)
alarm@expiresAt → stopping (auto time-box)
kill → killed (terminal, key wiped)
```

---

## 5. The requote loop (evolving `MMWatcher`'s flat-only recycle into a real MM engine)

Today `MMWatcher` only **recycles from flat** after two consecutive fully-flat reads — safe, but it can't "stay near
market," and it wastes the round trip when price drifts inside the band. The real loop, run by `requote.ts` in the DO
(and by `MMEngine` in Attended mode), is a **desired-vs-live diff with amend-first**:

```
tick():
  reconcileGate()                         # a failed read is NOT "flat" — bail (keep the MMWatcher rule)
  desired = strategy.levels(mark)         # quant owns the ladder + reference model
  live    = openOrdersForMarket()         # from WS state, verified on-chain every Nth tick
  ops = []
  for L in desired:
    m = nearestLiveSameSide(L, live, band)
    if m == nil:                     ops += placeBracket(L)          # 1–3 ops (entry + tp[+sl])
    elif drift(m, L) > requoteThresholdBp or sizeΔ(m,L) > sizeTol:
                                     ops += amend(m.oid → L.price,L.size)   # 1 op  (t:7 Change)
    # else: leave it resting (0 ops)
  for O in live not paired and (outsideBand(O) or excess):
                                     ops += cancel(O.oid)            # 1 op
  ops = ops[0 : budget.available()]       # cap to the token bucket; spill to next tick
  send(ops)
  scheduleAlarm(nextTickInterval)
```

**Numbers (respecting 118/min ≈ 1.97 ops/s):**
- 5 levels/side (10 orders). Full cancel+replace = 20–40 ops ≈ 10–20 s. Amend-only when everything drifted = ≤10 ops ≈ 5 s. In steady ranging markets most ticks amend 1–3 levels ≈ 1–2 s of budget.
- Tick interval by participation (bounded below by `ceil(opsThisTick / 1.97)`): **Aggressive ≈ 5 s** (cap ~10 ops/tick), **Normal ≈ 12 s**, **Passive ≈ 30 s**. *Quant sets the exact mapping and `requoteThresholdBp` (suggest `spreadBp/4`) and `sizeTol`.*
- Fees stay the honest headline: ~2.5 bp/filled leg → **~$250 cost per $1M of volume** (round-trip 2N volume ≈ 5 bp·N). `costPerMillion` is computed live and streamed.

**Amend caveat (flag → verify with quant against api-docs):** confirm `t:7 Change` can move price+size on a
PostOnly resting order *while preserving* the linked `tr`/`lp` TP/SL. If it cannot carry the linkage, fall back to
cancel+replace-with-re-linked-bracket for that level (2–4 ops) and let the budget absorb it. Either way the
**bracket-integrity rule is preserved: never leave a naked entry** (port `submitBracket` + `cancelEntry`).

> **Dependencies:** quant (ladder math, reference models Mid/Grid/RGrid/DGrid/Blend/Signal, `requoteThresholdBp`,
> `gridResetBp`/`tpResetBp`, participation→cadence, size curves); risk (max-loss trip, one-sided-trading throttle,
> inventory skew). The loop is the mechanism; those sections supply the parameters.

---

## 6. Custody & security

**Key generation & scope.** The Ed25519 session key is generated *inside the DO* (`crypto.subtle`). The phone
never sees the secret — only `publicKeyHex`. Enrollment is scope_mask=**2 (trade)**, which Perpl enforces as
**cannot withdraw funds**. The phone's wallet signs the EIP-712 `typed_data` that binds *this public key* to trade
scope, so the user cryptographically authorizes exactly one thing: a no-withdrawal trading delegate.

**Storage at rest.** `key:secret` is AES-GCM-wrapped with `env.SESSION_WRAP_KEY` before it touches DO storage
(DO storage is already CF-encrypted at rest; this is defense in depth so no single dump reveals it). **It is never
written to Supabase** — the DyorHQ Supabase security rule ("never store the Perpl Ed25519 secret") holds; the only
Perpl-key material in Postgres is the *public* key + fingerprint + `expiresAt` in `mm_sessions`, for auditability.
(Contrast the existing `copy_grants` table, which *does* hold an encrypted follower key with no SELECT policy — for
MM we go further and keep the secret out of the DB entirely, in the DO.)

**Time-box (auto-expire).** `key:expiresAt = startedAt + durationS + 120 s grace`. A DO alarm at `expiresAt`
force-runs `stop` (cancel+flatten+verify) then revokes the key. **Flag:** if Perpl's api-key enroll supports a
server-side TTL/expiry field, set it too so the key dies even if the DO is wedged (§8).

**Revocation (instant, phone-initiated).** `POST /kill` → DO cancels/flattens best-effort, calls the Perpl key
revoke endpoint, and wipes `key:secret`. Independent of that:

**Kill switch that works even if the Worker is unreachable.** The phone sends **`allowOrderForwarding(false)`
directly to the Exchange contract from the user's own wallet** (`PerplTrading.disableForwarding`). This makes
*every* forwarded order fail (`sr:34`) for the account **regardless of the DO, the key, or network reachability to
the Worker**. The kill button therefore does *both* in parallel: (1) fire the on-chain `allowOrderForwarding(false)`
tx, (2) `POST /kill`. Even if the Worker is down, dead, or compromised, action (1) alone stops all automated
trading. This is the honest backstop that makes delegated custody acceptable.

**What the phone can prove/verify (trust-minimization):**
- It holds the wallet; it authored the scope-2 EIP-712, so it *knows* the delegate can't withdraw.
- It reads **on-chain `positions`/`openOrders` via Monad RPC** independently of the DO — it can verify the DO's
  streamed status against ground truth at any moment (and BGProcessing does this opportunistically).
- It can revoke unilaterally on-chain with no cooperation from the Worker.
- Risk limits (max-loss, notional caps) are enforced in the DO **and** re-checked on the phone against on-chain
  reads; a divergence surfaces as an alert and can auto-trigger the on-chain kill.

**The tradeoff, stated plainly (ux copy at arm):** *"While this session runs, a DyorHQ server can place and cancel
trades on your Perpl account (it can never withdraw). The key expires at session end and you can revoke it instantly
from this screen, even if our servers are down."* No costless-profit language anywhere (brief §0).

> **Dependencies:** ux (consent screen + kill UI), risk (limit values enforced in the DO), infra
> (`SESSION_WRAP_KEY`, service-role secret, JWT verify).

---

## 7. Crash / idempotency / reconciliation — never orphan, never double-place

- **Deterministic intent ledger.** Every intended order has a `levelId = market:side:priceBucket:generation`. The
  DO writes `intent:<sid>:<levelId>` *before* sending and updates it with the `oid` on the `mt:24` outcome. Because
  `levelId` is deterministic, a crash-and-restart mid-place cannot create a second order for the same level: on
  restart the DO reconciles intents against reality first.
- **rq safety.** `rq:last` is persisted and, on every (re)connect, re-seeded `= max(rq:last, AccountUpdate.lfr)` so
  a restart never reuses or regresses a request id (the same seeding rule `PerplTradeClient` uses in memory, made
  durable).
- **On-chain reads are the source of truth.** On reconnect (and every Nth tick), `reconcile.ts` reads
  `openOrders`/`positions` from the Exchange via Monad RPC + Multicall3. The DO trusts *these*, not its own cached
  WS view, to decide what actually rests. Then: intents with a matching resting order → mark `placed` (no re-send);
  intents with no match and no position → (re)place; positions with no owning intent → adopt into the session's
  inventory (they came from a fill the DO missed while down). **The `MMWatcher` rule is preserved and elevated to a
  hard invariant: a failed read (`nil`, not `[]`) is never treated as "flat/no orders" — the DO bails the tick and
  retries, never re-places on top of live exposure.** Use **rpc1** for any log scan (rpc.monad.xyz caps getLogs at
  100 blocks; public RPC can also serve ~24 h-stale state — reconcile tolerates lag by cross-checking WS `mt:24`).
- **Never orphan a position.** Entries carry linked native TP/SL (`tr`/`lp`) so the **Perpl keeper protects the
  position even if the DO dies** — the same server-side safety net Attended mode relies on. Graceful `stop`
  cancels-all + flattens + **verifies clean** (port `MMExecutor.stop`'s post-teardown check) before revoking the key.
- **Idempotent control ops.** `pause/stop/kill` are safe to repeat; each first checks current on-chain state, so a
  retried `kill` after a partial failure simply finishes the teardown.

> **Dependency — infra:** the DO needs a Monad RPC URL (rpc1) and a TS Multicall3/eth_call client — the logic
> exists in DyorKit (Swift, `env.perpl.openOrders/positions`) and must be reimplemented in `reconcile.ts`.

---

## 8. Supabase schema (new migration `10_market_making.sql`, project `fmnjqrguvopusfufmirs`)

RLS by lowercased wallet via the existing `public.app_wallet()` JWT claim (same model as every other table).
Reads: owner-only. Writes: service_role (the Worker) only, except `mm_presets` (owner writes).

```sql
-- mm_sessions: one row per session; public key only, NEVER the secret.
create table public.mm_sessions (
  id uuid primary key default gen_random_uuid(),
  wallet text not null,                    -- lowercased 0x..40  (RLS: app_wallet())
  market_id int not null, mode text not null,
  config jsonb not null,                   -- MMSessionConfig
  state text not null default 'preparing',
  do_id text,                              -- PerplSocketDO name (= wallet)
  pubkey text, key_fingerprint text, key_expires_at timestamptz,   -- audit; no secret
  volume_target numeric, volume_done numeric default 0,
  realized_pnl numeric default 0, fees_paid numeric default 0,
  cost_per_million numeric, filled_pct numeric default 0,
  started_at timestamptz, expires_at timestamptz,
  created_at timestamptz default now(), updated_at timestamptz default now()
);
create table public.mm_fills (   -- from mt:24; drives volume/PnL/Cost/$1M and History
  id bigserial primary key, session_id uuid references public.mm_sessions on delete cascade,
  wallet text not null, market_id int not null, side text not null,
  price numeric, size numeric, notional numeric, fee numeric, realized_pnl numeric,
  block bigint, ts timestamptz default now()
);
create table public.mm_events (  -- event log: arm, requote, pause, error, maxloss-trip, kill
  id bigserial primary key, session_id uuid references public.mm_sessions on delete cascade,
  wallet text not null, kind text not null, detail jsonb, ts timestamptz default now()
);
create table public.mm_presets ( -- owner-writable saved configs (tread.fi "Presets")
  id uuid primary key default gen_random_uuid(), wallet text not null,
  name text not null, config jsonb not null, created_at timestamptz default now()
);
```

The Worker mirrors live state here every material change so History/Analytics/Sessions-table survive the DO and the
phone re-attaches after a kill/relaunch. **The session secret is never in Postgres.**

> **Dependency — reco/ux:** the Sessions table (Active/History/Scheduled/Analytics/Campaigns) and its columns
> (Mode, Pair, Volume, Fees, PnL, **Cost/$1M**, Spread, Filled%, Status) read from `mm_sessions`/`mm_fills`. Scheduled
> sessions are a `state='scheduled'` row + a DO alarm that arms at a future time with **no phone present** — a free
> capability of the server executor.

---

## 9. Open questions & external things the user must provide

**External credentials / APIs to supply (they offered):**
1. **APNs auth key `.p8` + Key ID + Team ID** (bundle `fun.dyorhq.app`) — for Worker→phone push (max-loss/error/
   completion). Already flagged as missing in the Supabase backend; MM needs it for the "phone in pocket" story.
2. **Cloudflare Workers Paid plan** (Durable Objects require it) + a `wrangler.toml` DO binding
   `PERPL_SOCKET_DO` and migration; the user owns/deploys the Worker.
3. **Worker secrets:** `SESSION_WRAP_KEY` (32-byte AES key), Supabase **service_role** key, and the Supabase JWT
   signing secret (to verify `wallet_address`). The user must set these — the MCP can't read the JWT secret.
4. **Monad RPC URL for the Worker** (use **rpc1** for reconciliation/log scans).

**Perpl API confirmations needed (verify against `PerplFoundation/delegated-account` + `api-docs`):**
5. **Key lifecycle:** is there a revoke/delete endpoint for an enrolled api-key, and does `enroll` accept a
   server-side **expiry/TTL** field? This decides whether time-box is DO-alarm-only or also enforced by Perpl.
6. **Amend semantics:** can `t:7 Change` move price+size on a PostOnly order while preserving the linked `tr`/`lp`
   TP/SL? (Determines requote op-cost; §5.) The verified `mt:24` = real fill outcome and `mt:26/27` = position ids
   must be confirmed as the DO's event source (the Swift client currently keys off `mt:3`/on-chain reads only).
7. **Delegated-account path:** does Perpl expose a first-class *delegate* (separate delegated account) that would let
   the DO trade **without** the account ever enabling global `allowOrderForwarding`? If so, prefer it — it narrows
   the on-chain surface and makes the on-chain kill even cleaner. Until confirmed, the design above (scope-2 api-key
   + `allowOrderForwarding`) is the verified path.

**Economics (the reason custody risk may be worth it):**
8. **Does Perpl/Monad pay maker rebates / MM rewards / points / airdrop credit for this volume?** *(quant/reco own
   the answer.)* If not, the honest promise is strictly "hit a volume target at the lowest Cost/$1M under hard risk
   limits" — never net-profit by default (brief §0). The architecture is neutral to the answer; the UX copy is not.

---

## 10. Dependency summary (what this spine hands to / takes from each section)

- **quant →** ladder math + reference models (Mid/Grid/RGrid/DGrid/Blend/Signal), `requoteThresholdBp`, `sizeTol`,
  participation→tick-cadence, duration auto-compute, size curves. *This section provides the requote *mechanism* and
  the op budget those parameters must fit.*
- **risk →** Max-Loss trip (`stopLoss% × margin`), liq price, one-sided-throttle, notional caps. *The DO enforces
  them in `alarm()`/on `mt:24`; the phone re-verifies against on-chain reads and can auto-fire the on-chain kill.*
- **infra →** Cloudflare DO deploy, secrets, Supabase migration `10_*`, APNs pipeline, Monad RPC, `wrangler.toml`.
- **reco →** Cost/$1M, est. fills/duration, presets, Sessions table columns; **all sourced from `mm_sessions`/
  `mm_fills`/`mm_events` this section defines.**
- **ux →** config screen, live cockpit `MMSessionView`, custody-consent copy, the dual (on-chain + worker) kill
  switch, sessions/scheduled UI. *This section names the client (`MMSessionClient`) and the state it streams.*

**Honest-economics & compliance frame respected throughout:** two-sided maker liquidity filled by the real book
(genuine counterparty + inventory risk), no self-matching, Cost/$1M surfaced live, no costless-profit claims.
