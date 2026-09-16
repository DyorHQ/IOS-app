# Moments — v1 build spec (frozen 2026-09-15)

**Status:** design frozen; **build unblocked** — the Launchpad audit fixes (holder-reward drain + owner backdoors) are fixed as of 2026-09-16. Contracts are **clean-room** — no Launchpad code is imported or reused. Owner deploys; non-custodial. Build handoff: [`moments-build-plan.md`](moments-build-plan.md).

This spec is the single source of truth for the build. It supersedes the earlier "Moments" proposals. Numbers are backed by the runnable model in [`moments-analysis/economics.py`](moments-analysis/economics.py) (settles in USDC; all allocation %, float:pool ratios and dump impacts are quote-asset-independent).

---

## 1. What Moments is

People publish special real-world moments onchain and earn when others collect them and trade the related coin. Each Moment is a **transferable NFT collectible** (the media + provenance) with a **per-moment ERC-20 coin** underneath it. Collecting is a cheap USDC action that both mints the keepsake and accrues a coin entitlement; if enough is collected, the coin **graduates** into a live Uniswap v4 market. Wedge audience: travelers + crypto enthusiasts.

Design principle: **the product must be lovable with the money turned off.** The keepsake + provenance stand alone; the coin is optional upside layered on top.

---

## 2. Locked parameters

| Parameter | Value |
|---|---|
| Settlement / pair asset | **USDC only** (no MON pair, no dual-pair with AUSD — concentrate liquidity) |
| Coin supply per Moment `S` | 100,000,000 (100M), fixed |
| Collect price | Creator-set, **min $0.10 (0.10 USDC)**, fixed per Moment |
| Collect proceeds split | **creator 20% / platform 5% / reserve 75%** |
| Graduation threshold | **$10 USDC — initial small-cap validation launch.** Raised for later cohorts via factory policy (no redeploy). |
| Emergent allocation at graduation | collectors **51.4%** / pool **38.6%** / creator **10%** |
| Creator coin allocation | ≤ **10%** of `S`, creator-chosen; **20% unlocks at graduation, then 16% of the allocation per month × 5** |
| Collector coin vesting | **60% liquid at graduation, +20% at month 1, +20% at month 2** (monthly cliffs) |
| Post-grad trading fee | **1%**, split **0.2% creator / 0.3% platform / 0.5% buyback-and-LP** |
| Buyback mechanism | **buyback-and-LP** (fee USDC buys the coin and adds to the locked pool), MEV-aware |
| NFT | ERC-721, **transferable**; **collection closes at graduation** (fixed edition) |
| Graduation gate | **none** (USDC-reserve threshold only); contained in UI (§12), not contract |

### 2.1 Chain & repo facts (for the build)

| Item | Value |
|---|---|
| Chain | Monad mainnet, id **143** (RPC `https://rpc.monad.xyz`; testnet `https://testnet-rpc.monad.xyz`) |
| USDC | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` — **6 decimals** |
| AUSD (fallback only, not used) | `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a` — 6 decimals |
| Uniswap v4 PoolManager | `0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` (already wired in `app/lib/swap`) |
| Universal Router | `0x0d97dc33264bfc1c226207428a79b26757fb9dc3` |
| Contracts | Foundry, solc **0.8.26**, `evm_version = cancun`, `via_ir = true`. v4-core in `lib/v4-core`, OZ via `@openzeppelin/contracts/` remap |
| Deployed Launchpad addrs | `contracts/deployments/143.json` (do not touch these) |
| App scripts | `npm run abis` (export ABIs), `npm run sync:deployment` (addrs → `app/lib/deployment.json`) |

**Decimals are a bug magnet:** USDC = 6 dp, MomentCoin = 18 dp. Every rate, entitlement, pool-seed and price-continuity calculation must scale the 6↔18 gap explicitly with integer math and be covered by exact-value tests.

---

## 3. Objects

- **MomentNFT (ERC-721):** transferable collectible. Metadata: media (content-addressed), place, date, creator, and the collector's **edition/rank** (#N). Minted on each collect until graduation; **no new mints after graduation** → fixed edition size = number of collects at graduation.
- **MomentCoin (ERC-20, 18 decimals):** one per Moment. **Minting is gated** to the graduation + claim logic only. No owner mint, no backdoor mint, no transfer tax. Coins are **not minted to collectors pre-graduation** (see §7).
- **USDC (6 decimals):** the settlement + pair asset (`0x7547…b603`). Collects paid in USDC via **Permit2** (already integrated in `app/lib/swap`) or standard `approve` — **do not assume native EIP-2612** on this USDC; verify before relying on it. Pool is `coin/USDC` (ERC-20/ERC-20; sort currencies by address for the v4 PoolKey).

---

## 4. Lifecycle & states

`Collecting → GraduationPending → Graduated` (plus `Rescue` as a stuck-state valve, carried from Launchpad design lessons).

- **Collecting:** NFTs mint on collect; USDC proceeds split; reserve accrues; coin entitlements accrue. No coin market.
- **Graduation trigger:** the collect that pushes reserve ≥ threshold marks the curve complete and attempts graduation atomically.
- **Graduated:** pool live; NFT collection **closed**; coin tradable; entitlements claimable on schedule; trading fees flow to creator/platform/buyback.
- **Never graduates:** stays in Collecting forever as cheap keepsakes. **No coin is ever minted** (entitlements never vest) → no dead coin, no dead pool, no wallet clutter. This is the intended outcome for the ~majority of Moments.
- **Rescue:** if graduation is stuck (repeated failure) past a fixed window, permissionless valve puts the Moment into fee-free wind-down; never sweeps funds to an admin.

---

## 5. Collect & entitlement accrual

On `collect(momentId, quantity)` paid in USDC (permit):
1. Split proceeds: 20% → creator (claimable/escrow), 5% → platform, 75% → reserve.
2. Mint NFT edition(s) to `msg.sender`; assign next rank(s); write provenance.
3. **Record a coin entitlement** for `msg.sender` at the fixed price-continuous rate (do **not** mint coin yet).
4. If reserve ≥ threshold → enter graduation (§6).

Bundle rate is derived for **price continuity**: a collector's coins-per-USDC equals the pool's opening price, so graduation neither gifts nor rugs them at open (model verifies +0.00% jump at exact threshold).

---

## 6. Graduation

Attempted in an isolated subcall that either completes fully or reverts (atomic): seed pool, lock LP, flip claimable, close NFT minting, update registry.

- **Terminal-collect clamp (overshoot):** clamp the collect that would cross the threshold so reserve lands **exactly** at threshold, and **refund the excess USDC** (mirrors the Launchpad's final-buy clamp). This keeps `Σ(entitlements)` exactly equal to the collector budget so **`pool_coins + Σ(entitlements) + creator_alloc == S` holds exactly** (assert it at the graduation block). Coin entitlement per collect = gross USDC paid × the **publish-time constant rate** (`rate = S·(1−creator_alloc) / (threshold/reserve_frac + threshold)`, with decimal scaling). Lock the collect path during graduation so concurrent collects can't break fixed-supply accounting.
- **Pool seed:** deposit reserve USDC + reserved coins into a full-range v4 `coin/USDC` position; transfer to `MomentLocker` (no withdrawal path).
- **Permissionless retry:** anyone can retry a stuck graduation (no reset of the rescue clock).

---

## 7. Coin distribution & vesting (pull-based portfolio claim)

**Coins are minted only at/after graduation, only via claim.** No mass airdrop, no manual distribution, no pre-grad tokens in wallets.

- Contract stores per-account `totalEntitlement` and `claimed`.
- `claimable(account) = vestedFraction(now) * totalEntitlement − claimed`.
- **Collector schedule:** 60% at graduation, +20% at month 1, +20% at month 2.
- **Creator schedule:** 20% at graduation, +16% of allocation per month × 5.
- `claim()` mints the vested-available amount to `msg.sender`, updates `claimed` (pull-based, checks-effects-interactions, monotonic).
- **`claimAll()` multicall** sweeps every vested tranche across all a user's graduated Moments in one tx (low-fee UX).
- Portfolio UI shows: pending (pre-grad), claimable now, vesting schedule, claimed.

Monthly cliffs are deliberate: they give collectors a reason to return each month (retention).

**Un-taken creator allocation** (creator picks < 10%): must be defined on-chain, not left dangling. Default: the freed coins **deepen the locked pool** (re-derive the bundle rate from the actual creator allocation so supply still sums to `S`). No owner/treasury default destination.

---

## 8. Fees & buyback

- **Collect:** 20% creator / 5% platform / 75% reserve (USDC).
- **Post-grad trading (1% hook fee):** 0.2% creator / 0.3% platform / 0.5% **buyback-and-LP**.
- **Buyback-and-LP:** the 0.5% share (USDC) buys the coin and adds coin+USDC to the locked pool, so **depth grows with volume** — the antidote to a locked full-range pool's depth-only-decays problem. Execution is MEV-aware (keeper-batched, randomized/TWAP), never a predictable lump.

---

## 9. Economics (reference: `economics.py`)

**Emergent-allocation identity:** `collector_coins / pool_coins = 1 / reserve_frac`. At reserve 75% → collectors 51.4% / pool 38.6% / creator 10%. Invariant to threshold and holder count — and `pool_coins` is even threshold-independent (= `S·(1−creator_alloc)/(1/reserve_frac + 1)`), so raising the threshold later only scales the USDC side and the unit price, never the allocation.

**Initial launch — small-cap validation ($10 threshold):**
- Total collected ≈ **$13.33**; creator earns **$2.67**, platform **$0.67**, pool reserve **$10**.
- Pool at open: 10 USDC + 38.57M coins; opening price ≈ $2.59e-7; FDV ≈ **$26**.
- Allocation (threshold-independent): collectors 51.43M / pool 38.57M / creator 10M.
- **Purpose is mechanism validation, not a market.** A $10 pool has no real depth; any non-trivial trade craters it, and a high collect price can graduate with ~1 holder. These coins are validation/low-cap by design — see containment in §12–13. Every contract path (collect → graduate → claim → buyback) executes identically to production.

**Later cohorts (candidate $10,000 threshold, same design):**
- Total collected ≈ **$13,333**; creator **$2,667**, platform **$667**, pool reserve **$10,000**.
- Pool at open: 10,000 USDC + 38.57M coins; opening price ≈ $2.59e-4; FDV ≈ **$25,926**.
- **Launch-day liquid float : pool = 0.80×** → if 10% of liquid collectors dump at open, price −14.3% (worst case all dump: −69%); creator grad-day unlock (2% of supply) if dumped: **−9.6%**.

**Honest framing (must be reflected in UX):** the coin is a lottery on external demand layered on a keepsake, **not** a way for the collector cohort to profit as a group — 25% of collect proceeds (creator+platform) leaves before trading, so absent new external buyers the cohort recovers less than it paid. Do not market "earn" as the core promise.

---

## 10. Clean-room contract set

All fresh, no Launchpad imports. Immutable (no proxies) except where noted; modules wired once.

| Contract | Responsibility | Key invariants / MUST-NOT |
|---|---|---|
| `MomentsFactory` | Publish a Moment; CREATE2 the per-moment contracts; registry; policy (threshold, split, min collect) **snapshotted immutably into each Moment at publish**; policy is **governance-updatable for FUTURE Moments only** (2-of-3 + timelock) so the threshold can rise $10 → higher without redeploy; publication pause | Cannot change a live Moment's params, withdraw reserves, or mint |
| `MomentCoin` | ERC-20 coin | Mint gated to graduation+claim only; no owner mint; no transfer tax; supply capped at `S` |
| `MomentNFT` | ERC-721 collectible | Transferable; **no mint after graduation**; provenance immutable; batch cap; owner-id pagination |
| `MomentCollect` | Collect action: USDC in (permit), split, mint NFT, accrue entitlement + reserve | Exact accounting; refund terminal overshoot; no reentrancy |
| `MomentGraduation` | Atomic seed + lock + flip-claimable + close-NFT + registry; permissionless retry | Assert `pool+Σentitlements+creator==S`; lock collect path during grad; no funds to admin |
| `MomentLocker` | Owns the full-range v4 `coin/USDC` position | No liquidity-withdrawal path; may **increase** liquidity for buyback-LP only |
| `MomentVesting` | Pull-based collector + creator claims | Immutable alloc snapshot; monotonic `claimed`; CEI; claimAll multicall |
| `MomentBuyback` | Route 0.5% fee to buyback-and-LP | MEV-aware; can only add to the locked position; no arbitrary external calls |
| `MomentFeeHook` | v4 hook: charge 1% post-grad, split 0.2/0.3/0.5; guard pool init | Only the executor may initialize the registered pool |

Beneficiaries (creator, platform) are **immutable addresses** per Moment.

---

## 11. Security carry-forward checklist (from the Launchpad drain — reuse lessons, not code)

- Pull-based rewards/claims only; no push loops over holders.
- **No owner backdoor on any money path** (no owner mint, no reserve access, no fee redirect on live Moments).
- Reentrancy guards on collect / graduate / claim / buyback; checks-effects-interactions.
- Per-Moment **supply invariant asserted at graduation** and after every mint.
- Immutable beneficiaries; graduation executor cannot be re-pointed to drain the seed.
- Independent audit of the fresh code before any real money (do **not** substitute "tests passed" for an audit).
- Clean-room isolation verified: a Moments bug cannot touch Launchpad funds and vice versa.

---

## 12. UI / UX requirements

- **USD everywhere** (native, via USDC) — prices, thresholds, FDV shown in $.
- **Low-friction collect** via Permit2 (app-wired) or approve; single-tap where possible.
- **Gas is MON** → validate Privy gas sponsorship so users only need USDC (onboarding dependency, not a blocker).
- **Containment (accepted):** never show a "proven demand" / trust badge; always surface **holder count + top-holder %** on every coin, so a thin or self-graduated coin visibly reads as one. Buyers self-judge.
- Portfolio: pending / claimable / vesting / claimed, with `claimAll`.
- Pre-collect plain-language disclosure: financial asset, may lose value, taxable on sale, sellable supply vs pool depth.
- Provenance shown honestly on the NFT (see §13 shelved fix).

---

## 13. Accepted residual risks (documented, carried forward on purpose)

1. **Ungated graduation → self-graduation/self-rug.** One wallet can self-collect to threshold and sell behind a "graduated" coin. Not fixed in contract (owner's call); contained only by UI honesty (§12). *Shelved fix if revisited:* distinct-funded-wallet gate + per-wallet cap + exclude creator self-collects.
2. **Securities / AML / app-store.** A bundled, appreciating, fungible coin sold to retail is likely a security; the USDC on-ramp + payout implicate money-transmission/VASP; iOS collect flow risks Apple 3.1.5(b). *Mitigations required before real money:* web-first (coin purchase off the iOS binary), KYC'd licensed on-ramp, geofencing (incl. Ghana), disclosures, per-jurisdiction legal opinion.
3. **Transferable NFT = "I was there" is a bearer badge**, and nothing verifies the creator was present or owns the media. *Shelved fix (cheap, keeps transferability):* split an immutable soulbound attendance-receipt (minter + rank) from the transferable collectible; add capture attestation + media-hash dedup + takedown/burn.
4. **Collector cohort is negative-sum absent external demand** (§9) — manage via honest framing + the buyback sink, not marketing.
5. **Most Moments never graduate** — acceptable because non-graduated Moments mint no coin (keepsakes only), but sets the real TAM expectation.

---

## 14. Pre-launch gates (before real money)

- [x] Launchpad audit fixes done (holder-reward drain + owner backdoors) — 2026-09-16. Build unblocked.
- [ ] Independent audit of the clean-room Moments contracts; critical/high resolved.
- [ ] Fork test on Monad v4 with real USDC pool: collect → graduate → trade → claim → buyback.
- [ ] Legal determination per operating jurisdiction; geofencing + KYC on-ramp wired.
- [ ] iOS: coin purchase off-binary; web-first transaction surface.
- [ ] Privy gas sponsorship validated (or documented "user needs MON for gas").
- [ ] Small-cap launch containment: curated cohort, coins labeled **early / low-cap / validation**, holder-count + top-holder % shown, **not marketed as investments**; raise the threshold via factory policy as the product proves out.

---

## 15. Sequencing

1. ~~Deploy Launchpad audit fixes~~ — done 2026-09-16.
2. Build clean-room Moments contracts + fork tests (this spec) — see [`moments-build-plan.md`](moments-build-plan.md).
3. Independent audit.
4. Web app: publish, collect, portfolio/claim, buyback visibility, provenance/holder-count UI.
5. Legal/compliance gates, then curated pilot.
