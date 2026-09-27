# Contracts v2 changes: NOT DEPLOYED

These source changes answer the 2026-09-26 security audit (`docs/security-audit-2026-09-26/REPORT.md`, findings
MO-1, MO-2, LP-1, LP-2, LP-3, and in the second round (sec2, below) MO-4, MO-8, LP-6, SEC-1, LP-7, RO-7 and the
re-audit's findings on the first round). **None of them is deployed.** The Launchpad (`deployments/143.json`) and every
Moments cohort (`deployments/moments-143*.json`) on Monad are immutable. They keep running the v1 bytecode until a
new deployment replaces them. Until then, the keepers in `contracts/keepers/` contain the risk on the live contracts.

## Deployed source (the v1 baseline)

The deployed bytecode corresponds to the source of these files as of commit `3fc1f47` (the merge of PR #24). Its
parents `7c79361` and `557b4bd` hold identical `contracts/src` (`git diff 3fc1f47^1 3fc1f47 -- contracts/src` and
`… 3fc1f47^2 …` are both empty). Each changed file was last modified before this change by:

| File | Last commit before v2 |
|---|---|
| `src/moments/MomentLocker.sol` | `ac33952` (2026-09-16) Moments Phase 4: security self-review … v1.1 hardening |
| `src/moments/MomentFeeHook.sol` | `ac33952` (2026-09-16) |
| `src/moments/MomentBuyback.sol` | `ac33952` (2026-09-16) |
| `src/moments/interfaces/IMomentsMarket.sol` | `490c8f4` (2026-09-16) Moments Phase 2: graduation, locker, fee hook, buyback |
| `src/LaunchpadFactory.sol` | `94e0fb1` (2026-09-16) Launchpad: fix all 2026-09-15 audit findings |
| `src/MemeHook.sol` | `94e0fb1` (2026-09-16) |
| `src/interfaces/ILaunchpad.sol` | `94e0fb1` (2026-09-16) |
| `src/LaunchLocker.sol` | `f8f1d30` (2026-09-08) Build the DyorHQ launchpad for Monad mainnet on Uniswap v4 |

These commits were not compared byte-for-byte against the on-chain code in this change, because the Monad RPC is
not reachable from the sandbox. Before relying on the table, run `script/verify-143.sh` and
`script/moments/verify-moments-143.sh` against these commits.

## Changes

### MO-1: graduation cannot be griefed from inside a `PoolManager.unlock()` (Medium)

- **`MomentLocker`**: when the PoolManager is already unlocked (a terminal collect made from inside someone's
  `unlock` callback), `seed`/`increase` now add the position **in-line** instead of calling `unlock()` again, which
  reverts `AlreadyUnlocked`. v4 books deltas per caller, and the locker settles all of its own deltas to zero in the
  same call (sync → transfer → settle / take), so the outer unlocker's accounting is unaffected. As a result,
  graduation completes in the attacker's own transaction: no `GraduationFailed`, no stuck clock, nothing to
  `expire()`.
- `MomentCollect` is unchanged. A genuine graduation failure still starts the 7-day stuck clock, as before.
- Tests:
  - `test/audit/Z_MomentsUnlockGrief.t.sol` (the original PoC, 3/3) now runs against
    `test/audit/V1MomentLocker.sol`, a verbatim copy of the deployed locker, so it keeps proving the live bug.
  - `test/audit/Z_MomentsUnlockGriefFixed.t.sol` runs the same attack against v2. The Moment graduates in both
    currency orders, emits no `GraduationFailed`, and can never be expired.

### MO-2: per-Moment locker accounting and an in-block price guard on buybacks (Low)

- **`MomentLocker`**: balances are attributed per Moment (`heldOf[momentId][currency]`, `tracked[currency]`).
  Untracked tokens are credited to the Moment being added to. That covers the reserve at seed, the buyback's top-up
  at increase, and any stray transfer. An add only spends that Moment's own balance, and the checked subtraction
  reverts rather than spend another Moment's USDC.
- **`MomentFeeHook`**: records the pool price before the first swap of every block (one packed slot per Moment,
  written once per block) and exposes `blockOpenSqrtPrice(momentId)`.
- **`MomentBuyback`**:
  - `execute` reverts `PriceMoved` if the live price is more than `MAX_OPEN_DEVIATION_BPS` = 2% away from the
    block-open price, which rules out the same-block sandwich.
  - The pairing top-up is sized against `locker.available(momentId, …)` instead of the locker's whole USDC balance.
  - A price move under 2% costs the sandwicher more in fees (1% hook + 0.5% LP, each way) than an add ≤2% off-price
    can yield. `test/moments/Buyback.t.sol` covers both cases.
- Residual (corrected in sec2): a manipulation held across a block boundary is not caught. The original note said it
  was "exposed to arbitrage for a full block, and the 1%/hour impact cap still applies"; neither protects: a Moment's
  coin trades only on its own pool, and the 1% cap bounds only the buyback's swap, not the liquidity add. The re-audit
  showed the cross-block sandwich profitable; sec2 caps the add (below).
- Tests: `test/audit/Z_MomentsLockerAccounting.t.sol`. In `test/moments/Buyback.t.sol`, the sandwich test now expects
  `PriceMoved`, and a new test covers a small in-tolerance sandwich, which still loses money.

### LP-1: the Monday→v4 fallback always keeps enough gas for v4 (Medium)

- **`LaunchpadFactory.graduateFallback`**:
  - A full `GRADUATION_GAS + GRADUATION_GAS/32` is reserved for the v4 path, and the Monday retry gets all the gas
    above that reserve. v1 forwarded 63/64 of all gas to the retry. (Correction, sec2: that does not starve v4 for a
    caller who brings enough gas. The out-of-gas happens several frames down, and each reverted frame returns the
    1/64 it kept, so the live `graduateFallback` recovers a dense squat with ~12–16M gas and reverts as a whole below
    that; see `test/sec2/Sec2LiveV1.t.sol`. What v2 adds is recovery that does not depend on call depth or on the
    caller's gas.)
  - The call requires `2 × GRADUATION_GAS + GRADUATION_GAS/32` gas up front (`InsufficientGasForGraduation`), so the
    retry gets at least `GRADUATION_GAS`, and the v4 path always keeps its full budget after a failed retry.
  - A caller who brings more gas lets a heavy-but-realignable Monday pool still graduate on Monday (the creator's
    venue), which the post-merge adversarial review asked for; only a Monday path that still reverts falls back.
- Tests: `test/audit/Z_MondayTickGrief.t.sol` uses a v3-style pool that charges a fresh storage write per crossed
  dust tick. With 1,500 ticks, the auto graduation fails and even a 29M-gas Monday retry runs out of gas. The v2
  fallback still graduates on v4 within 30M, and with just the reserved budget. It rejects too little gas. A light
  squat still graduates on Monday.

### LP-2: holders' cut of pool fees is forwarded in the swap that earned it (Low)

- **`MemeHook`**: for launches with holder fee sharing, the holders' cut of every quote-asset fee is passed to
  `HolderFeeSharing.notifyReward` inside the swap. This is exactly what `BondingCurve` already does on every curve
  trade.
  - v1 kept it in the hook until someone called `sweepPoolFees`. A large backlog could then be captured by
    buy → sweep → hold one block → sell.
  - The protocol's cut waits in the new `pendingProtocolFees` and is paid by `sweepPoolFees`.
  - Launches without sharing, and token-denominated fees, are unchanged.
- Tests: `test/audit/Z_HolderBacklog.t.sol`. There is no backlog in the hook, the sweep pays the protocol, and a
  one-block holder gets at most the holders' cut of their own buy fee (they lose money), while long-term holders
  keep the organic fees.

### LP-3: `LaunchLocker.locked[]` keyed by the launch token whatever the sort order (Low)

- **`LaunchLocker`**: the key is now the launch token. It is resolved from the factory's launch record: currency0
  is the token exactly when its record exists and names currency1 as its quote. A native quote is always currency0.
  v1 used currency0 unless it was native, so an ERC-20 quote sorting below the token (AUSD, some USDC) became the
  key, and each such launch overwrote the previous one.
- New view `lockedLiquidity(token)` reads the position straight from the PoolManager.
- Live contracts: `locked(token)` is wrong for affected launches. Proof of lock can be read from the PoolManager
  directly, using position key `keccak256(locker, tickLower, tickUpper, bytes32(0))` on the launch's `poolId` via
  `StateLibrary.getPositionLiquidity`.
- Tests: `test/audit/Z_LockerKey.t.sol` covers a quote sorting first, a quote sorting last, native, and two launches
  on the same low quote.

## Second round (sec2, 2026-09-27): re-audit findings, MO-4, MO-8, LP-6, SEC-1

Every item has a test in `test/sec2/` that failed on the first-round v2 source and passes now (`Sec2Launchpad.t.sol`,
`Sec2Moments.t.sol`), or that documents what the live v1 code does (`Sec2LiveV1.t.sol`, on `V1LaunchpadFactory.sol`,
a verbatim copy of the deployed factory source at `3fc1f47`). Checked against Monad's Sourcify
(https://sourcify-api-monad.blockvision.org, 2026-09-27): the verified source of the live launchpad factory `0x6B1C…`
equals `V1LaunchpadFactory.sol` apart from its import paths, name and header, and that of the live Moments cohort 3
factory `0x0FD4…` equals `3fc1f47` apart from one comment.

### Launchpad

- **LP-1, low-gas venue override (re-audit, Low).** v2's fallback reserved the v4 budget but let a caller send just
  enough for a 2M Monday retry, so anyone could move a heavy-but-realignable Monday launch to Uniswap v4 by sending
  ~4.1M gas. `graduateFallback` now requires `MONDAY_RETRY_GAS` (20M) for the retry on top of the reserve (about 22.1M
  in all), and the retry gets all the gas above the v4 reserve. A caller can no longer move a squat that 20M realigns.
  - Corrected after the second review: this does **not** mean that only a squat no single transaction can realign
    falls back. A squat that needs between ~20M and ~27.9M (about 950–1,200 dust ticks on the mock pool) still moves
    to Uniswap v4 when the caller sends the minimum, and stays on Monday at 29.9M
    (`test_LP1_squatAboveTheRetryFloor_keepsMondayOnlyWithNearFullGas`). Holders are never harmed either way (they get
    a locked v4 pool); what is at stake is the creator's venue.
  - The floor stays at 20M: at ~27M the fallback would need ~29.1M, too close to Monad's 30M per-transaction cap
    once calldata and a smart wallet's overhead are added, and a fallback nobody can call leaves holders stuck until
    the 7-day rescue. Venue fidelity therefore rests on callers sending ~29.9M: the keeper now does (it sent 25M,
    which on a copy of the live factory moved 1,100–1,200-tick squats to v4, `Sec2LiveV1.t.sol`), and the apps must
    (the checklist below; the iOS `graduateFallbackPlan` sends no gas limit today, so estimation lands near the
    minimum).
- **LP-1, Monday-only freeze (re-audit, Low).** A dense squat on a Monday-only pair (aBIL) froze holders until the owner
  called `allowV4Fallback`, in v1 and in v2. Now anyone may take the v4 fallback once the launch has been stuck for
  `MONDAY_ONLY_FALLBACK_DELAY` (1 day); the owner can still allow it at once. **Owner decision:** this relaxes the
  "aBIL graduates only on Monday" rule after a day of being stuck; drop it (one condition in `_graduate`) if aBIL must
  never leave Monday, and keep the owner's SLA instead.
- **Module window before the first launch (re-audit, Medium on the live factory).** The live factory freezes its
  modules only at the first launch, and `0x6B1C…` has none, so the owner key can still swap any module and the next
  launch would freeze the swap in. New `sealModules()` (owner) freezes them at once; `Deploy.s.sol` calls it as its
  last wiring step. The first launch still seals too. New view `modulesSealed()` and event `ModulesSealed`.
- **Snipe-tax exemption on a recipient change (re-audit, Info).** `BondingCurve.setCreatorFeeRecipient` no longer
  exempts the new recipient (a chain of hand-offs inside the 4-second window exempted any number of wallets past
  `MAX_EXEMPTIONS`). The launch-time exemptions are unchanged.
- **LP-6, owner-config validation (Info):** `setFeePolicy` and the constructor refuse a zero fee recipient (FeeEscrow's
  push to address(0) burned native fees); `addLaunchConfig` refuses a tick spacing outside v4's 1..32767
  (`InvalidTickSpacing`; 0 divided by zero in `minUsableTick`); a fee-on-transfer quote asset can never trade
  (`BondingCurve.UnsupportedQuoteToken`: the curve checks it received exactly what it books); and `setPairMondayOnly`
  affects only later launches (the rule is snapshotted per launch in `launchMondayOnly`).

### Moments

- **MO-2, cross-block sandwich (re-audit, Low).** `MomentLocker.increase` adds at most `MAX_INCREASE_BPS` (0.5%) of
  the position's liquidity per call; the rest stays held for the Moment and later rounds add it (nothing is lost, and
  the seed is not capped). The block-open guard stays.
  - The cap is in liquidity, not value, so what one round hands a push made in an earlier block grows with the push:
    about the cap from the add, plus up to ~0.5% from the round's own fee-exempt swap, which the pusher sells into.
    The first cut of this fix used 2% and claimed the sandwich lost "whatever its size". The second review showed
    that false for the Moment's **creator**, who gets 20% of the hook fee back and so pays only ~2.1% for the round
    trip: on the $10-threshold test pool with a large carried budget, pushes of 200, 500 and 1,000 USDC (6–30× the
    pool's USDC side) made the creator +0.39, +1.48 and +3.31 USDC in one round (it scales with pool size). At 0.5%
    the same pushes lose 2.30, 5.61 and 11.14 USDC, and an outsider loses 15.13 on 1,000 USDC
    (`test/sec2/Sec2Moments.t.sol`, which fails at 2%).
  - **Residual, not closed by the cap:** a push **held across several hourly rounds**, with each round kept funded
    (a round needs `MIN_AMOUNT` of budget; the pusher can refill it with small round trips), spends the Moment's
    held balance at the pushed price, one capped add per round. Measured at 0.5% on the $10 test pool: 1,000 USDC held
    for 12 rounds +5.6 USDC (+0.55%); 5,000 USDC held for 12 rounds on a Moment with ~99 USDC of buyback funds
    +82.8 USDC (+1.65%). The cap bounds the rate, not the total: what is at risk is that Moment's own idle buyback
    funds (buyback carry plus its locker remainder), and the pusher must keep a pumped price for hours while every
    other holder of the coin can sell into it. Closing it needs a reference price the pool cannot move quickly (for
    example one kept by the fee hook that follows the pool price at a bounded speed, with rounds refused while the
    price is far from it). That also pauses buybacks after large genuine moves, so it is an owner decision.
  - The cap leaves USDC idle in the locker routinely; the keeper's idle alert is per Moment (`heldOf`) on a v2 locker.
- **MO-4 (Low):** `publish(PublishParams, bytes32 expectedTermsHash)` reverts `TermsChanged` unless the hash equals
  `termsHash()` = keccak256(abi.encode(policy, externalBaseURI)), the terms the creator's app showed, so applying a
  matured proposal in front of a publish no longer changes a creator's terms. A proposal lapses (`PolicyLapsed`) if
  nobody applies it within `POLICY_APPLY_WINDOW` (7 days) of becoming applicable. A **guardian** (a second key, set by
  governance only while wiring, then handed on only by itself: `setGuardian`) can `cancelPolicy()` and
  `setGuardianPaused(true)`, a pause governance cannot lift. Under a stolen governance key the guardian cancels every
  proposal within its 48h timelock and stops publishing.
  - Second review: the guardian can no longer renounce (`setGuardian(address(0))`) while its pause is on
    (`UnpauseFirst`), which made the pause permanent. It can still hand the role on while paused. Nobody can replace a
    **lost** guardian key, and a **compromised** one can cancel every proposal and pause publishing for good; either
    means a new cohort (existing Moments are unaffected: collecting, graduation and trading never read the guardian).
    A governance path to replace an unresponsive guardian (for example a 30-day timelock the guardian can cancel) is
    an owner decision; it is not implemented.
  - The terms binding holds only if the app derives the hash from exactly what it showed (checklist below). An app
    that re-reads `termsHash()` when the creator taps Publish accepts any change silently.
  - Residual: `setExternalBaseURI` has no timelock. A stolen governance key can point the links of Moments published
    from then on at another site at once (existing NFTs keep theirs, MO-8); the keeper's governance watch alerts on
    `ExternalBaseURISet` and on a base that differs from the expected one, and the guardian can pause publishing.
    The apps should also refuse to publish when `externalBaseURI()` is not the expected DyorHQ base. Timelocking it
    (instant only while wiring) is an owner decision.
- **MO-8 (Low):** each `MomentNFT` stores the factory's `externalBaseURI` at publish (constructor argument, public
  `externalBaseURI()`), so changing the factory's base never rewrites existing NFTs; the base is capped at 256 bytes
  (`BaseURITooLong`; a 40 KB base made every tokenURI cost ~15M gas).
- **Price ceiling (re-audit, Info):** `publish` reverts `PriceTooHigh` above ceil(threshold·BPS/reserveBps), the gross
  that completes the reserve; above it the only edition was clamped to that gross and never charged its price. The
  policy check (`_validate`: constructor, `proposePolicy`) refuses a `minPrice` above that ceiling, which would have
  made every publish revert until another 48h proposal. The live cohort 3 has no ceiling: its threshold of
  $771.428571 at 75% makes it $1,028.57, and a Moment listed higher sells its first edition for $1,028.57 (the creator
  gets 20% of that, not of the listed price). Both create flows refuse a higher price now (web `validate()`, iOS
  `priceProblem`), on the live cohort as on v2.

### Scripts (SEC-1, LP-7, RO-7)

- `script/lib/MainnetGuard.sol`: on chain 143 every deploy/ops script refuses PRIVATE_KEY, TREASURY_KEY, OWNER_KEY,
  DEPLOYER_PRIVATE_KEY and ETH_PRIVATE_KEY in the environment (`ALLOW_RAW_KEY_143=1` overrides), and a deploy script
  never writes a live record: dry runs write `deployments/dryrun-*.json`, broadcasts on 143 write
  `deployments/pending-*.json` for promotion by hand after verification (both git-ignored).
- `script/mainnet.sh`: wrapper for forge/cast; resolves the RPC's chain and on 143 (or an unreadable chain) refuses
  `--private-key(s)`, `--mnemonic(s)`, `--interactive(s)` and the key variables.
- `Deploy.s.sol` (launchpad) on 143: `PROTOCOL_FEE_RECIPIENT`, `FEES`, `LAUNCH_FEE_WEI`, `MON_USD_E8` and
  `ABIL_USD_E8` have no default; the money roles must differ from each other and from the deployer/owner; prices
  must sit in a sanity band ($0.005–$0.20 MON, $50–$150 aBIL); it seals the modules; optional `OWNER` (a Safe) gets
  ownership (two-step) and owns the Monday fee vault. `moments/Deploy.s.sol` on 143: `GOVERNANCE`, `GUARDIAN`,
  `PLATFORM`, `TREASURY` and `THRESHOLD_USDC` have no default and must be distinct; it names the guardian and sets the
  link base while wiring.
- `script/deploy-v2.sh`: the v2 deployment with the relaunch script's pre-flight: Ledger or keystore only, chain 143
  on two RPCs, distinct roles, live prices from two sources (`relaunch/prices.py`), simulate → confirm → broadcast,
  and a check that no live record changed. `DRY_RUN=1` and `FORK=1` (anvil) modes.
- `relaunch/relaunch-new-wallets.sh` and `relaunch/rehearse.sh` are retired (exit at once): the relaunch is done,
  their source pin no longer matches, and the script passed a raw key on the command line.

### Keepers (`contracts/keepers`)

- Robustness: default RPC `https://rpc3.monad.xyz` (rpc1 rate-limited a full run; rpc.monad.xyz caps log ranges);
  viem retries; log scans in chunks of `--logs-chunk` (100) that
  halve on a range cap; all retries of every cohort run before any log scan; every cohort, launchpad, item and job is
  isolated, so one failing read is an alert and the rest still runs.
- Records: `143.json` and `moments-143.json` are required (missing, unparsable or wrong-chain throws, exit 1), the live
  factories are pinned in `lib/deployments.mjs` (a mismatch is critical), and the live factories must have code. New
  records `143-retired-0x2F02.json` and `143-retired-0xad3d.json` (read on-chain at block 108,334,691); the 0xad3d
  legacy record (16 fields, Monday executor in the `graduationExecutor` slot) is decoded.
- Gas: sends use estimateGas × 1.2 capped at the old fixed limits (Monad bills the limit), except the Monday
  graduation/fallback, which send 29.9M on purpose (25M until the second review: see LP-1 above); a holder backlog is
  swept only when it is worth the sweep (native: 2× its gas cost; ERC-20: 0.01 token); `--min-balance` alert for
  `--sim-from`.
- Secrets: the RPC URL reaches cast through `ETH_RPC_URL`, never argv, and every printed line, alert and webhook post
  shows URLs as their origin only.
- LP-1: per-tick cost 30k (≈28.7k measured on Monday Trade under Monad's gas schedule); a blocking squat is critical
  only on a Monday-only pair (elsewhere the live fallback recovers it); stuck Monday-only launches name the owner action.
- v2 wiring: `pendingProtocolFees` counts toward sweeps (0 on the live hooks).
- New job `governance`: compares every factory's and fee vault's modules, owner, pending owner and fee recipients
  with the records, flags an unsealed factory with no launch (daily), pending governance/policy, a retired cohort that
  publishes again, and (with `--logs-lookback`) every governance event.

### Test results (sec2: forge 1.7.1, solc 0.8.26, `--code-size-limit 100000000`)

- Offline, fork suites excluded (`forge test --offline --no-match-path <the 11 fork suites>`): **31 suites, 195 tests,
  all pass.** On the first-round v2 source 16 of the 19 new `test/sec2` tests failed (the MO-2 PoCs made +57,836 and
  +868,744 USDC units; they now lose 105,666 and 139,001).
- Fork suites (`MondayFeeVault`, `MondayGraduation`, `PermitFork`, `Z_LiveDeployment`, `Z_MyLiveExecutorFork`,
  `Z_MyMondayFork`, `Z_MyMondayFork2`, `Z_Relaunch`, `moments/fork/{LiveDeployment,Lifecycle,Adversarial}`), against a
  local `anvil --fork-url https://rpc3.monad.xyz` with `FOUNDRY_RPC_ENDPOINTS='{monad="http://127.0.0.1:8620"}'`:
  **11 suites, 45 tests, all pass.** The Moments fork suites pin block 105,303,689, which no public Monad RPC serves
  any more; `MOMENTS_FORK_BLOCK` now re-pins them (run at 108,341,572). `Lifecycle` and `Adversarial` had never run
  against the first-round guard: a buyback in the same block as a >2% burst reverts `PriceMoved`, so they now roll a
  block first, and the adversarial sandwich expects `PriceMoved`.
- Keepers: `node --test contracts/keepers/test/*.test.mjs`: 66/66 (43 before; ABI parity checked against the build).
- `script/deploy-v2.sh`: `DRY_RUN=1` and `FORK=1` both complete on the anvil fork (the fork run broadcasts both stacks;
  the new factory reports `modulesSealed() == true` with no launch and refuses `setMondayExecutor`); the scripts
  refuse `PRIVATE_KEY` on chain 143, a missing money role and a $1 MON price.
- Second review (same toolchain): offline **31 suites, 203 tests, all pass** (8 new: the creator's and an outsider's
  sandwich of pushes many times the pool, both failing at 2%; fee folds above the cap; the guardian renounce, twice; the
  `minPrice` policy check; the LP-1 gas window on v2 and on the live copy). The two first-round MO-2 PoCs now lose
  175,904 and 258,955 USDC units. Fork suites (anvil fork of rpc3 at block 108,392,390, `MOMENTS_FORK_BLOCK` the
  same): **11 suites, 45 tests, all pass**, `Lifecycle` and `Adversarial` included. Keepers: 75/75. iOS: DyorKit
  `swift test` 304 tests (3 skipped), 0 failures, and the app builds for the simulator; web: `tsc --noEmit` reports no
  error outside `supabase/functions` (Deno code, which it cannot check).

### What needs a redeploy and rewiring

Nothing in `contracts/src` is live. Every item above needs the v2 redeploy (both stacks, whole: every module holds its
factory immutably): `script/deploy-v2.sh`, then the steps in `script/README.md`. The keeper, script and record changes
work on the live v1 contracts today. Owner actions before and after are listed in `script/README.md` and the handoff.
The second review's contract changes ride on the same v2 redeploy; its keeper changes and the create flows' price cap
work on the live contracts as soon as they ship.

## Test results (first round: `forge test --offline`, forge 1.3.5, solc 0.8.26)

| | Suites | Passed | Failed | Total |
|---|---|---|---|---|
| Before (v1 source at `3fc1f47`) | 34 | 143 | 11 | 154 |
| After (v2) | 39 | 166 | 11 | 177 |

Both runs have the same 11 failures. They are the fork suites (`test/moments/fork/*`, `MondayGraduation`,
`MondayFeeVault`, `PermitFork`, `Z_LiveDeployment`, `Z_MyLiveExecutorFork`, `Z_MyMondayFork*`, `Z_Relaunch`), which
fail in `setUp` because the sandbox cannot reach the Monad RPC. Every non-fork test passes.

## ABI and storage changes (first round: all additive; no constructor changed)

| Contract | Storage | ABI |
|---|---|---|
| `MomentLocker` | + `heldOf` (mapping, slot after `_positions`), + `tracked` (mapping) | + `heldOf(uint256,address)`, + `tracked(address)`, + `available(uint256,address)` |
| `MomentFeeHook` | + `_blockOpen` (private mapping, appended) | + `blockOpenSqrtPrice(uint256)`; hook permissions unchanged, but the init code changed, so the CREATE2 salt must be mined again at deploy |
| `MomentBuyback` | none | + `MAX_OPEN_DEVIATION_BPS()`, + error `PriceMoved()`; `execute` can now revert with it |
| `IMomentsMarket` | n/a | `IMomentLocker.available`, `IMomentFeeHook.blockOpenSqrtPrice` |
| `LaunchpadFactory` | none | none (reuses `InsufficientGasForGraduation`); `graduateFallback` needs ≥ 4,062,500 gas |
| `LaunchLocker` | none (same `locked` layout; key semantics fixed) | + `lockedLiquidity(address)` |
| `ILaunchpadFactory` | n/a | + `getLaunchedToken(address)` (the factory already implements it) |
| `MemeHook` | + `pendingProtocolFees` (mapping, appended) | + `pendingProtocolFees(bytes32,address)`, + event `HolderFeesForwarded` |

Gas: swaps on holder-sharing v4 pools cost one `notifyReward`, the same call a curve trade already makes. Swaps
on Moments pools cost one extra SLOAD, plus one SSTORE on the first swap of each block. The deploy scripts need
no change beyond re-mining hook salts.

Indexers and apps: `MemeHook.pendingFees` stays 0 for the quote asset on holder-sharing pools. The protocol part
is in `pendingProtocolFees`, and holder rewards appear in `HolderFeeSharing` right away as queued rewards.

## ABI and storage changes (second round, sec2)

Not all additive this time: `MomentsFactory.publish` and the `MomentNFT` constructor change, so the apps must be
rewired for v2 anyway (they must also be pointed at the new addresses).

| Contract | Storage | ABI |
|---|---|---|
| `LaunchpadFactory` | + `modulesSealed` (bool, packed after `launchDeployer`), + `launchMondayOnly` (mapping, appended) | + `sealModules()`, `modulesSealed()`, `launchMondayOnly(address)`, `MONDAY_RETRY_GAS()`, `MONDAY_ONLY_FALLBACK_DELAY()`, event `ModulesSealed`, error `InvalidTickSpacing`; `graduateFallback` now needs ≥ 22,062,500 gas; `setFeePolicy` and the constructor revert `ZeroAddress` on a zero recipient |
| `BondingCurve` | none | + error `UnsupportedQuoteToken`; `setCreatorFeeRecipient` no longer sets `snipeTaxExempt` |
| `MomentsFactory` | + `guardian`, `guardianPaused` (after `pendingGovernance`) | **`publish(PublishParams, bytes32 expectedTermsHash)`** (replaces `publish(PublishParams)`), + `termsHash()`, `setGuardian(address)`, `guardian()`, `setGuardianPaused(bool)`, `guardianPaused()`, `POLICY_APPLY_WINDOW()`, `MAX_EXTERNAL_BASE_URI_LENGTH()`, events `GuardianSet`, `GuardianPaused`, errors `NotGuardian`, `NotGovernanceOrGuardian`, `PolicyLapsed`, `TermsChanged`, `BaseURITooLong`, `PriceTooHigh`, `UnpauseFirst`; `cancelPolicy` is also open to the guardian; `setGuardian(address(0))` reverts while `guardianPaused`; a policy whose `minPrice` is above the completion gross is `InvalidPolicy` |
| `MomentNFT` | + `externalBaseURI` (string) | constructor takes a 9th argument (the link base), + `externalBaseURI()`; `tokenURI`/`contractURI` no longer read the factory |
| `MomentLocker` | none | + `MAX_INCREASE_BPS()`; `increase` adds at most 0.5% of the position |

Apps and indexers after a v2 deploy:

- Terms: derive the hash passed to `publish` from exactly the terms the review screen showed. Either read `policy()`,
  `externalBaseURI()` and `termsHash()` in one call at one block tag (a multicall), or compute
  `keccak256(abi.encode(policy, externalBaseURI))` locally from the values shown; keep it with the review screen and
  never re-read `termsHash()` when the creator taps Publish. Show `TermsChanged` as "the terms changed, review them
  again". Show the platform and treasury addresses as well as the bps, and refuse to publish when
  `externalBaseURI()` is not the expected DyorHQ base.
- Price: refuse a collect price above ceil(threshold × 10,000 / reserveBps) (`PriceTooHigh`, the gross that completes
  the reserve), next to the `minPrice` check. This applies to the live cohort 3 today too (there a higher price is
  silently clamped to $1,028.57).
- Check `guardianPaused()` next to `publishingPaused()`.
- Launchpad: send `graduate` (Monday launches) and `graduateFallback` with an explicit 29.9M gas limit; estimation
  settles near the minimum, where a squat that more gas would realign moves to Uniswap v4. Offer the fallback for a
  Monday-only launch only when `v4FallbackAllowed(token)` or `block.timestamp >= stuckSince(token) +
  MONDAY_ONLY_FALLBACK_DELAY()` (read `launchMondayOnly(token)`, the per-launch snapshot, not `pairMondayOnly`), or
  when a simulation succeeds.
- Count `pendingProtocolFees` in the pool-fee figures; compare the factory's module getters (and `modulesSealed()`)
  with the baked addresses before offering Launch.
