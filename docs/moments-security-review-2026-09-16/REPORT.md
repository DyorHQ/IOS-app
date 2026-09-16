# Moments — Phase 4 security self-review, invariant & fork report (2026-09-16)

**This is a self-review by the implementer, not an independent audit.** Spec §14 requires an independent audit
before real money; this document is the hand-off package for it. Nothing in it should be read as clearing the
contracts for a launch.

## 1. Scope

| item | value |
|---|---|
| repo / branch | `DyorHQ/IOS-app`, branch `moments/v1` (worktree `~/Hackathon-moments`) |
| deployed source | tag `moments-mainnet-v1` (= commit `37f9d0f`; `src/moments` unchanged since `5eb7bc5`) |
| review source | branch HEAD = v1.1 candidate: `moments-mainnet-v1` + NFT metadata escaping + the v1.1 hardening listed in §5 (NOT deployed) |
| contracts | `contracts/src/moments/`: MomentsFactory, MomentCoin, MomentNFT, MomentCollect, MomentVesting, MomentGraduation, MomentLocker, MomentFeeHook, MomentBuyback, libraries MomentPoolMath, MomentHookAddress; interfaces IMoments, IMomentsMarket |
| build | solc 0.8.26, via_ir, evm cancun, bytecode_hash none; deployed at optimizer_runs 44444444 (`v4core` profile) |
| chain | Monad mainnet 143; PoolManager `0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e`, USDC `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` (6 dp), Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`, Universal Router `0x0D97Dc33264bfC1c226207428A79b26757fb9dc3` |
| live addresses | factory `0x47D989a54232D3bCdB7A7760D10E596647D986BA`, collect `0x582E63927Ef364b3737c5F4861517C2C99a8B784`, vesting `0xB58894e56737cd21e8dD70B9cc69e89D2AAe2466`, graduation `0xC626493540d9eA868b58cBe912E027d4236e5B6F`, locker `0x125a957360DE495600a1872E19C72823f329b68c`, hook `0x54E83342f4910853A8B1630654754Eb49123e0cC`, buyback `0xaB5A89779F451d812855206833d8fbe7873f00C8`; all Sourcify-verified (creation + runtime match) |
| out of scope | the Launchpad contracts (separately audited and redeployed 2026-09-16; Moments imports none of them), Uniswap v4 core, OpenZeppelin 5.0.2, USDC, Permit2 |

Trust model: no owner on any money path. Governance (`0xCf7A…7e10`) can only change policy for FUTURE Moments
after a 48-hour timelock, pause publishing, and hand governance over. Every per-Moment parameter and beneficiary is an
immutable snapshot; modules are wired once. Assets only ever sit in: `MomentCollect` (USDC owed to reserve /
creator / platform / treasury), `MomentFeeHook` (USDC owed to creator / platform / buyback), `MomentBuyback` (USDC
carry), `MomentLocker` (dust + the locked position inside the PoolManager).

## 2. Method

1. §11 checklist as an explicit review of every contract (matrix in §3), plus an adversarial pass per contract.
2. Foundry stateful invariants: the Phase 1 suite (accounting on a mock executor) and a new whole-stack market
   suite on a real PoolManager — collects, graduations, expiries, claims, swaps both ways, buybacks, fee
   withdrawals, time — 256 runs × 500 calls each, 0 reverts.
3. Property fuzzing of the arithmetic (clamp, split, bundle-rate conservation, sqrt price, hook fee both shapes,
   vesting monotonicity), 256 runs each.
4. Monad mainnet-fork suites against the real PoolManager / USDC / Permit2 / Universal Router: the $10 lifecycle
   reconciled to `economics.py`, the adversarial matrix, and a smoke test through the LIVE deployed contracts.
5. Slither 0.11.6 on an isolated copy of `contracts/` (Moments-only triage in §4.3).

## 3. §11 checklist matrix

| requirement | where it is enforced | evidence |
|---|---|---|
| Pull-based only; no push loops over holders | Collect `withdrawCreator/Platform/Treasury`, Hook `withdrawCreator/Platform`, Vesting `claim/claimAll` mint to `msg.sender`; no loops over holders anywhere | `Collect.t.sol` withdrawals, `Hook.t.sol` withdrawals, `Expiry.t.sol`, invariants `usdc_solvency` / `usdc_and_coin_solvency` |
| No owner backdoor on any money path | Factory has no money function; modules read peers from the factory, wired once (`setModules`); no pause/kill on graduate/claim/buyback; hook fees only to snapshot beneficiaries; reserve only to the executor or, after expiry, to snapshot creator/treasury | `Factory.t.sol` (modules once, policy timelock, no money functions), `Collect.t.sol` reserve-release auth, `Locker.t.sol` role gates, `Hook.t.sol` register/init auth |
| Reentrancy guards + CEI on collect / graduate / claim / buyback | `nonReentrant` on `collect`, `collectWithPermit2`, `expire`, all withdrawals, `claim`, `claimAll`, `graduate`, `execute`; effects before external calls (book → pull → deliver; claimed before mint; carry/lastRun before unlock) | `Collect.t.sol` + `Adversarial.t.sol` receive-hook reentrancy, `Graduation.t.sol` retry, `Buyback.t.sol` |
| Per-Moment supply invariant after every mint and at graduation | `MomentVesting._claim` (SupplyInvariant after mint), `MomentGraduation.graduate` (nothing minted before, identity after), `ERC20Capped(S)` | invariants `supply` / `supply_identity`, `Graduation.t.sol`, fork lifecycle `_assertSupply` at every step |
| Immutable beneficiaries; executor cannot be re-pointed | `Moment` struct written once (no setter); `factory.graduation()` fixed after `setModules`; coin/NFT minters are constructor immutables | `Factory.t.sol` snapshot test, `Collect.t.sol` minters locked down |
| Clean-room isolation | no import from `src/*.sol`; own libraries; separate deployment, hook and locker | `grep`: only `lib/` and `./` imports under `src/moments` |
| Independent audit before real money | **open** — this document is the hand-off | — |

Additional properties proven: reserve lands exactly on the threshold (`testFuzz_terminal_clamp_is_exact`); split
sums exactly; `pool = S − creator − Σent` holds for any threshold/split/allocation/price within the fuzz domain;
opening price = collectors' rate up to the clamp shift; locked liquidity only grows and is the pool's only
liquidity; the hook and buyback never hold coin; the NFT closes exactly when the Moment ends; vesting is monotone
and bounded per account.

## 4. Findings

No Critical or High severity issue was found in this self-review. Severity follows the Launchpad audit's scale
(impact × likelihood). "v1.1" means fixed on the branch but NOT in the live deployment.

### 4.1 Medium — none found

### 4.2 Low

| id | finding | status |
|---|---|---|
| L-1 | **Fee avoidance through alternate pools.** Anyone can create a hook-less coin/USDC pool (v4 with no hook, v3, Monday) and provide liquidity there; trades routed there pay neither the 1% Moments fee nor feed the buyback. Fund safety is unaffected; only fee revenue and buyback depth leak. Same limitation as the Launchpad's MemeHook. | Accepted design limitation. The app must route Moments trades through the canonical pool (`MomentGraduation.poolKeyOf`) and label other venues. |
| L-2 | **NFT metadata JSON injection.** `tokenURI` concatenated creator-supplied `name`, `place` and `mediaURI` without escaping; a `"` or control character produced malformed JSON (broken marketplace rendering; self-inflicted, no fund impact). | **v1.1 fixed** (`MomentNFT._json`; `NFTMetadata.t.sol` parses the decoded document). Requires a factory redeploy to take effect. |
| L-3 | **Missing zero-address checks in module constructors.** A mis-wired immutable (e.g. wrong USDC) could not be corrected after deployment. The deploy script and the live wiring test mitigate it. | **v1.1 fixed**: constructors revert on zero addresses. |
| L-4 | **Policy sanity floors.** `threshold` / `minPrice` only had to be non-zero; a degenerate policy (sub-cent threshold) would make graduation math meaningless. Governance-only and timelocked, so likelihood is low. | **v1.1 fixed**: `threshold ≥ 1 USDC`, `minPrice ≥ 0.01 USDC`. |
| L-5 | **Predictable buyback cadence.** `execute` is permissionless with a 1% impact cap and 1-hour interval; a sandwich in the same block loses money (proven), but a patient trader can still position ahead of a known buyback and unwind later. Bounded by the cap; inherent to any public buyback. | Accepted; documented in `MomentBuyback`. |
| L-6 | **Treasury benefits when graduation fails.** After the deadline + 7-day grace an un-graduated reserve is wound down 70/30 to creator/treasury. Graduation has no admin lever (no pause, no re-pointing), so the platform cannot cause a failure; the only failure modes are PoolManager reverts or bugs. | Accepted (owner ruling 5); the auditor should confirm the "no lever" claim. |

### 4.3 Informational

| id | note |
|---|---|
| I-1 | `quote()` reverts once the deadline has passed (same check as `collect`); the app must handle the revert as "closed". |
| I-2 | USDC is upgradeable and has a blacklist; a blacklisted beneficiary cannot withdraw, and a blacklisted Moments contract would freeze its balances. External dependency, same as every USDC-denominated protocol on Monad. |
| I-3 | A late successful graduation retry and `expire()` (after deadline + grace) are both permissionless; whichever lands first wins. Intended. |
| I-4 | Integer dust (≤ 2 USDC units, wei-level coin) stays in the locker per add; it is re-added on the next increase. |
| I-5 | `GRADUATION_GAS = 3,000,000` is fixed; the live terminal collect measured 986,085 gas (3× margin). The PoolManager is immutable, so the profile cannot drift. |
| I-6 | ERC-721 marketplace standards were incomplete in v1 (no ERC-2981, no ERC-4906/ERC-7572, no `animation_url`/`external_url`). **v1.1 implements them** (owner ruling 15): ERC-2981 royalties to the immutable creator (policy `royaltyBps`, cap 10%), ERC-4906 refresh on close, ERC-7572 `contractURI()`, `owner()` = creator as the marketplace admin convention (no on-chain power), numeric rank with `max_value`, optional `animation_url`, `external_url` from a governance-set, metadata-only base URI. No burn / takedown; transferable bearer badge — spec §13 accepted. |
| I-7 | `MomentCoin` has no EIP-2612 `permit`; the app sells coin through Permit2 (allowance transfer), which is what the Universal Router expects. |
| I-8 | Slither (Moments-only triage): `reentrancy-no-eth` on `collect`, `collectWithPermit2`, `graduate`, `execute`, `unlockCallback` — every flagged call is to a contract of ours or to the PoolManager, the entry points are `nonReentrant` / `onlyPoolManager`, and the receive-hook reentrancy test fails closed; `incorrect-equality` — sentinel `== 0` checks by design; `divide-before-multiply` in `creatorVestedBps` — floor-months by design; `uninitialized-local` in `_json` — defaults to 0; `unused-return` on `initialize`/`settle`/`getSlot0` — values not needed; `timestamp` — deadlines and cliffs are second-granular by design; `missing-zero-check` — L-3. No detector hit remains unexplained. (Slither also reports Launchpad items in the shared `src/`; out of scope, covered by the Launchpad audit.) |

## 5. v1.1 changes on the branch (not deployed)

- `MomentNFT._json` escaping (L-2) with `NFTMetadata.t.sol`.
- Zero-address checks in the constructors of Collect, Vesting, Graduation, Locker, FeeHook, Buyback, Coin and NFT (L-3), `Constructors.t.sol`.
- `MomentsFactory._validate`: `threshold ≥ 1_000_000`, `minPrice ≥ 10_000` (L-4).
- Marketplace standards on `MomentNFT` (I-6): ERC-2981 / ERC-4906 / ERC-7572, `owner()` convention, `animation_url`, `external_url` (factory `externalBaseURI`, governance-settable, metadata only); `Policy.royaltyBps` and `Provenance.animationURI` added; `NFTMetadata.t.sol` covers interface ids, royalty math, refresh events, contract metadata and transfers through standard approvals.
- Test-side: the "implied pool vs remainder" rounding bound now scales with `BPS/reserveBps` (it was only correct
  for prices that split exactly).

Redeploying v1.1 means a new factory (it embeds the coin + NFT creation code) and therefore all modules (they
hold the factory as an immutable). The live v1 has no Moments published; the owner decides whether to redeploy
before or after the external audit (recommended: after, once, with the audit's changes folded in).

## 6. Invariant, fuzz and fork results

Total: 106 tests (94 local + 12 on Monad mainnet forks), all passing on the v1.1 branch; the deployed v1 passed
the same suites minus the v1.1-only ones (`NFTMetadata`, `Constructors`).

| suite | what | result |
|---|---|---|
| `Invariant.t.sol` | Phase 1 accounting invariants (supply, solvency, reserve/edition bounds) on a mock executor, incl. expiry | 3/3, 256 runs × 500 calls, 0 reverts |
| `MarketInvariant.t.sol` | whole stack on a real PoolManager: supply identity, USDC/coin solvency of every contract, locked liquidity monotone + sole LP, ledger/NFT consistency, vesting bounds | 5/5, 256 runs × 500 calls, 0 reverts |
| `Fuzz.t.sol` | clamp exactness, split sum, bundle-rate conservation, sqrt-price accuracy (1e-9), hook fee exact-in buy/sell, vesting monotonicity | 7/7 × 256 runs |
| `Collect/Economics/Vesting/Factory/Expiry/Graduation/Hook/Locker/Buyback/NFTMetadata/Constructors.t.sol` | unit + exact-value + adversarial + v1.1 hardening | 76/76 |
| `PermitFork.t.sol` | real Permit2 + real USDC (Monad fork) | 3/3 |
| `fork/Lifecycle.t.sol` | $10 lifecycle on mainnet state, reconciled to `economics.py` (allocation, price, dump impacts) | 2/2 |
| `fork/Adversarial.t.sol` | self-graduation, single holder / whale, threshold race + locked path, dead Moment, vesting boundaries, 4% allocation, reentrancy + sandwich, decimal edges | 8/8 |
| `fork/LiveDeployment.t.sol` | the deployed contracts: wiring/policy + full lifecycle | 2/2 |

Model reconciliation (from the fork lifecycle): collectors 51,428,574 / pool 38,571,426 / creator 10M (identity
exact; 2.57-coin clamp shift vs the model), opening price 2.5926e-7 USDC/coin, +0.00% first-buy jump after fees,
dump impacts within 0.1 pp of the fee-adjusted constant product (creator 2M 9.57%, monthly 7.77%, $1 bundle 17.28%,
all liquid 69.00%, 10% float 14.20%), self-graduation recovers 7.21 of 13.33 USDC.

## 7. Hand-off to the independent auditor

- Check out tag `moments-mainnet-v1` for the live code, branch HEAD for v1.1; `cd contracts && forge build`;
  tests: `forge test --code-size-limit 100000000 --match-path 'test/moments/*.t.sol'` and
  `… --match-path 'test/moments/fork/*.t.sol' --fork-url monad` (rpc alias in `foundry.toml`).
- Specification: `docs/moments-spec.md` (frozen), rulings `docs/moments-decisions.md`, plan `docs/moments-build-plan.md`,
  model `docs/moments-analysis/economics.py`, oracle files `test/moments/EXPECTED.md`, `test/moments/fork/EXPECTED-phase3.md`.
- Questions we would like answered specifically: (a) v4 hook delta accounting in `MomentFeeHook` for all four swap
  shapes, including the `take` inside the callback; (b) LP-fee folding in `MomentLocker.unlockCallback`
  (zero-delta modify → take to self → re-add) — any way to extract value from the locker; (c) `MomentBuyback`
  price-limit and pairing math under manipulation; (d) the Permit2 path and the terminal clamp; (e) the rounding
  bound in §5 and the fuzz domain; (f) the "no admin lever on graduation" claim (L-6); (g) anything reachable by an
  ERC-721 receiver or an ERC-20 callback.
- Accepted residual risks are enumerated in spec §13 (self-graduation, securities/AML, transferable provenance,
  negative-sum cohort, most Moments never graduate) and rulings 5, 8, 11 in the decisions log.
