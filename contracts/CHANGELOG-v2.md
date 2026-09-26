# Contracts v2 changes: NOT DEPLOYED

These source changes answer the 2026-09-26 security audit (`docs/security-audit-2026-09-26/REPORT.md`, findings
MO-1, MO-2, LP-1, LP-2, LP-3). **None of them is deployed.** The Launchpad (`deployments/143.json`) and every
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
- Residual: a manipulation held across a block boundary is not caught. It is exposed to arbitrage for a full block,
  and the 1%/hour impact cap still applies.
- Tests: `test/audit/Z_MomentsLockerAccounting.t.sol`. In `test/moments/Buyback.t.sol`, the sandwich test now expects
  `PriceMoved`, and a new test covers a small in-tolerance sandwich, which still loses money.

### LP-1: the Monday→v4 fallback always keeps enough gas for v4 (Medium)

- **`LaunchpadFactory.graduateFallback`**:
  - The Monday retry is capped at `GRADUATION_GAS` (2M, the automatic graduation's own budget). v1 forwarded 63/64
    of all gas, so a squatted pool full of dust ticks could burn it all.
  - The call now requires `2 × GRADUATION_GAS + GRADUATION_GAS/32` gas up front (`InsufficientGasForGraduation`),
    so the v4 path always has a full `GRADUATION_GAS` after a failed retry.
  - A Monday path that cannot finish within the automatic budget falls back to v4. The fallback is only reachable
    after the automatic attempt with the same budget has already failed, so the rule is unchanged.
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

## Test results (`forge test --offline`, forge 1.3.5, solc 0.8.26)

| | Suites | Passed | Failed | Total |
|---|---|---|---|---|
| Before (v1 source at `3fc1f47`) | 34 | 143 | 11 | 154 |
| After (v2) | 39 | 166 | 11 | 177 |

Both runs have the same 11 failures. They are the fork suites (`test/moments/fork/*`, `MondayGraduation`,
`MondayFeeVault`, `PermitFork`, `Z_LiveDeployment`, `Z_MyLiveExecutorFork`, `Z_MyMondayFork*`, `Z_Relaunch`), which
fail in `setUp` because the sandbox cannot reach the Monad RPC. Every non-fork test passes.

## ABI and storage changes (all additive; no constructor changed)

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
