# Moments — build plan (hand this to a fresh Claude Code session in this repo)

You are building **Moments**, a new feature for DyorHQ (Monad, chain 143). This plan is the execution order. **The authoritative design is [`docs/moments-spec.md`](moments-spec.md); the economics are in [`docs/moments-analysis/economics.py`](moments-analysis/economics.py). Read both fully before writing any code.** If anything here conflicts with the spec, the spec wins — stop and flag it.

Work phase by phase. **Do not skip a phase's acceptance gate.** Commit at each gate on a feature branch (`moments/…`), never on `main`.

---

## 0. Non-negotiables (read first, violate none)

- **Clean-room contracts.** Build all Moments contracts fresh under `contracts/src/moments/`. **Import nothing from the Launchpad `src/*.sol`** (BondingCurve, GraduationExecutor, LaunchLocker, MemeHook, HolderFeeSharing, LaunchpadFactory, etc.). You may import only `lib/` (v4-core, OpenZeppelin, solmate). If you need a Launchpad utility, **copy it in and own it** — do not reference it. A Moments bug must never be able to touch Launchpad funds. Do not modify any existing Launchpad contract or `contracts/deployments/143.json`.
- **Security is the point.** The Launchpad previously shipped a critical holder-reward drain + owner backdoors. Apply the §11 checklist to every contract: pull-based only, **no owner backdoor on any money path**, reentrancy guards + checks-effects-interactions, per-Moment supply invariant asserted after every mint and at graduation, immutable beneficiaries. "Tests pass" is **not** an audit — an independent audit is a pre-launch gate (§14).
- **Decimals.** USDC = **6 decimals**, MomentCoin = **18 decimals**. Every rate / entitlement / pool-seed / price-continuity calc must scale the 6↔18 gap explicitly with integer math, covered by exact-value tests. This is the single most likely place to introduce a bug.
- **USDC only.** Settle and pair in USDC `0x754704Bc059F8C67012fEd69BC8A327a5aafb603`. No MON pair, no AUSD dual-pair. Collect via Permit2 (already wired in `app/lib/swap`) or `approve` — do not assume native EIP-2612 on this USDC; verify.
- **No mainnet money until the pre-launch gates (§14) pass.** All work is local + fork + testnet until then.

## Locked parameters (from the spec — do not re-derive)

- Supply `S` = **100,000,000** (100M), fixed, 18 dp.
- Collect: creator-set price, **min $0.10 (0.10 USDC)**; split **creator 20% / platform 5% / reserve 75%**.
- Graduation threshold: **$10 USDC** (initial small-cap validation launch; a factory-policy value, raisable for future Moments without redeploy).
- Emergent allocation at graduation: **collectors 51.43M / pool 38.57M / creator 10M** (threshold-independent).
- Bundle rate (publish-time constant): `rate = S·(1−creator_alloc) / (threshold/reserve_frac + threshold)`, decimal-scaled. Entitlement per collect = gross USDC × rate. Price-continuous (collector cost == pool opening price).
- Creator alloc ≤ 10%, creator-chosen; vest **20% at graduation + 16% of alloc/month × 5**. Un-taken (<10%) portion → **deepen the locked pool** (re-derive rate from actual alloc so supply still sums to S).
- Collector coin vesting: **60% at graduation, +20% month 1, +20% month 2** (monthly cliffs).
- Post-grad trading fee **1%** → **0.2% creator / 0.3% platform / 0.5% buyback-and-LP**.
- NFT: ERC-721, transferable, **collection closes at graduation** (fixed edition).
- Graduation gate: **none** (owner's decision) — contained in UI (holder count + top-holder %, no "proven demand" badge), not contract.

## Repo conventions

- Contracts: Foundry, solc **0.8.26**, `evm_version = cancun`, `via_ir = true` (see `contracts/foundry.toml`). v4-core in `lib/v4-core`; OZ via `@openzeppelin/contracts/`. Put Moments code in `contracts/src/moments/`, tests in `contracts/test/moments/`, scripts in `contracts/script/moments/`.
- Addresses: PoolManager `0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e`, Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`, Universal Router `0x0d97dc33264bfc1c226207428a79b26757fb9dc3`.
- App: Next.js under `app/`. Mirror `app/launchpad` patterns — reads via multicall (`app/lib/launchpad.ts`), simulate-then-write (`app/lib/actions.ts`), generated ABIs (`app/lib/abi.ts` via `npm run abis`), chain/wallet in `app/lib/chain.ts` / `app/lib/wallet.tsx`, Permit2 flow in `app/lib/swap`. New code: `app/moments/` routes + `app/lib/moments.ts`.
- Deploy: script writes `contracts/deployments/<chainId>.json`; `npm run sync:deployment` copies addrs into `app/lib/deployment.json`. Fork rehearsal pattern: `scripts/dev/seed-fork.mjs` (mirror it for Moments).

---

## Phase 1 — Core accounting (no market yet)

Build and unit-test the value-handling core before any Uniswap integration.

Contracts: `MomentCoin` (ERC-20, mint gated to graduation/vesting only, cap S, no owner mint), `MomentNFT` (ERC-721, transferable, mint only while Collecting, ranks, provenance, batch cap, owner-id pagination), `MomentsFactory` (publish via CREATE2, immutable per-Moment policy snapshot, governance-updatable policy for future Moments, publication pause), `MomentCollect` (USDC in via Permit2/approve → split 20/5/75, mint NFT, accrue entitlement + reserve, **clamp+refund the terminal collect**), `MomentVesting` (per-account entitlement + `claimed`, collector & creator schedules, `claim()` + `claimAll()` multicall).

**Acceptance gate 1:**
- `forge build` clean; `forge test` green.
- Exact-value tests for the bundle rate and split at 6/18 decimals (assert integer amounts, no rounding drift).
- Supply invariant test: after any sequence of collects, `Σ(entitlements) + reserve-implied pool + creator ≤ S`, and `== S` only after graduation.
- Terminal-collect clamp: the collect crossing threshold lands reserve exactly at threshold and refunds the excess.
- No coin is minted to anyone during Collecting.

## Phase 2 — Graduation, liquidity, fees, buyback

Contracts: `MomentGraduation` (atomic: seed pool + lock + flip entitlements claimable + close NFT minting + registry; assert `pool + Σentitlements + creator == S`; permissionless retry; `Rescue` valve after a stuck window), `MomentLocker` (owns the full-range v4 `coin/USDC` position via PoolManager; **no withdrawal path**; increase-only for buyback), `MomentFeeHook` (v4 hook: 1% post-grad fee split 0.2/0.3/0.5; only the graduation executor may initialize the registered pool), `MomentBuyback` (routes the 0.5% USDC to buy coin and increase the locked position; MEV-aware — keeper-batched/randomized).

Sort currencies by address for the PoolKey (USDC vs the CREATE2 coin address). Handle the fee in the input asset per swap direction (mirror the fee-on-swap cases the Launchpad `MemeHook` documents, but reimplemented clean-room for a USDC pair).

**Acceptance gate 2:** unit tests for graduation accounting, locker no-withdrawal, hook fee math for all swap directions, buyback increases locked liquidity and cannot be pointed elsewhere.

## Phase 3 — Full $10 lifecycle fork test (the real gate)

Fork Monad and run the entire lifecycle against the **real** v4 PoolManager + real USDC:
`anvil --fork-url https://rpc.monad.xyz --chain-id 143` (use the `deal` cheatcode / whale impersonation to fund test wallets with USDC). Mirror `scripts/dev/seed-fork.mjs`.

Scenario to pass end-to-end at the **$10 threshold**: N wallets collect → terminal clamp → graduation seeds the USDC/coin pool and locks it → coin trades on v4 → collectors `claim()` at graduation (60%) and across the month-1/month-2 cliffs → creator claims 20% + monthly → trading generates the 1% fee → buyback buys coin and deepens the locked pool.

**Assert against `economics.py`:** allocation 51.43M/38.57M/10M, price continuity (~0% jump at open), and the dump-impact figures. Verify the supply invariant holds at every step.

**Adversarial test matrix (must all be covered):**
- Self-graduation: one wallet self-collects to $10 and captures pool + creator bag (document the extraction — it's an accepted, UI-contained risk, but the accounting must still be exact).
- High collect price → graduate with ~1 holder; whale collects the majority.
- Terminal overshoot + two collects racing the graduation block (locked collect path).
- Dead Moment: never reaches threshold → **no coin ever minted**, NFTs remain, no pool.
- All liquid collectors dump at open; 10%-dump; claims exactly at each vesting boundary and just before/after.
- Un-taken creator allocation (creator picks 4%): freed coins deepen the pool; supply still sums to S.
- Reentrancy attempts on collect/graduate/claim/buyback; buyback MEV/sandwich.
- Decimal edge cases (min 0.10 USDC collect; dust; rounding).

**Acceptance gate 3:** the full fork scenario + entire matrix pass; numbers reconcile with the model.

## Phase 4 — Security self-review, then external audit

Run the §11 checklist as an explicit review; add invariant/fuzz tests (Foundry `invariant_`), Slither if available. Produce an invariant + fork report. **Then hand off to an independent audit** (external — not this session). Do not deploy real money before critical/high findings are resolved.

## Phase 5 — Web app

Under `app/moments/` + `app/lib/moments.ts`, mirroring `app/launchpad`:
- **Publish** a Moment (media upload, place/date, set collect price, choose creator alloc ≤10%).
- **Collect** (USDC via Permit2/approve, simulate-then-write, USD display).
- **Portfolio claim**: pending / claimable / vesting / claimed, with `claimAll()`.
- **Containment UI (required):** holder count + top-holder % on every coin; **no "proven demand" badge**; "early / low-cap / validation" labeling; pre-collect plain-language disclosure. Holder counts for the coin need Transfer-event indexing — use the existing Supabase backend (see the DyorHQ Supabase memory); the NFT has on-chain owner pagination.
- Buyback visibility; provenance display.
- `npm run abis` + `npm run sync:deployment` to wire ABIs/addresses.

**Acceptance gate 5:** publish → collect → graduate → claim → see buyback, working against a fork/testnet deployment, verified in the browser preview.

## Phase 6 — Deploy gates & small-cap launch

Only after §14 gates: independent audit clear, legal/geofence/KYC on-ramp, iOS coin-off-binary (web-first), Privy gas sponsorship validated (or "user needs MON for gas" documented), small-cap containment labeling in place. Deploy the **$10** config and run the curated small-cap validation launch. Scale the threshold later via factory policy (governance), no redeploy.

---

## What NOT to do

- Don't import or modify Launchpad contracts, or `contracts/deployments/143.json`.
- Don't add an owner path that can mint, touch reserves, redirect fees on a live Moment, or drain the seed.
- Don't mint coins to collectors before graduation.
- Don't market coins as investments or add a "proven demand" badge.
- Don't deploy to mainnet with real money before the §14 gates.
- Don't assume native EIP-2612 on USDC; don't hardcode the 6-decimal scaling implicitly.
