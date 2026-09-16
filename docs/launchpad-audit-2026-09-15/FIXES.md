# DyorHQ Launchpad — Audit Fixes (2026-09-15)

Applied on branch `feat/launchpad-venue-economics` in the worktree `/Users/jerry/Hackathon-launchpad-fix`
(UNCOMMITTED, per the pause). `src` diff vs the branch base: 8 files, ~200 lines. Every fix has a regression
test that fails on the old code and passes now. Full suite: **all tests green** (repo unit + Monad-fork, plus the
audit PoCs converted to regressions under `contracts/test/audit/`).

## What changed, by finding

### H-1 — Flash-take reward-sniping (v4 holder-fee-sharing)  → `src/HolderFeeSharing.sol`
Rewards are no longer distributed the instant they arrive. `notifyReward` now QUEUES the reward and stamps the
block; `_release` (run at the start of every `beforeTransfer` / `claim` / `exclude` / `notifyReward`) only
distributes it once a LATER block has begun, splitting it by the eligible balances that stand at that moment.
A flash-borrowed balance (v4 `take`/`settle` inside one `unlock`) cannot survive a block boundary, so it is never
present when the reward is released. `_release` runs BEFORE any balance is added in `beforeTransfer`, so a flasher
cannot even skim an already-queued reward. New view `queuedRewards`; `pendingRewards` accounts for a releasable
queue. Regression: `test/audit/Z_MyFlashSnipe.t.sol::test_C5_flash_snipe_is_defeated` (sniper now captures 0).

### H-3 — Monday graduation griefing / DoS  → `src/MondayGraduationExecutor.sol`, `src/LaunchpadFactory.sol`
Two layers:
1. **Realign** (executor): a squatted, mispriced Monday pool is no longer a hard revert. Before minting, a bounded
   swap (≤ `MAX_ALIGN_BPS` = 1% of the executor's reserve of the input asset) with the curve price as its limit
   moves the pool to the target. Through an empty/dust pool this is free (no liquidity to resist) and defeats the
   ~555k-gas squat; against real liquidity it trades toward fair (in the executor's favour) and, if it still can't
   land exactly on the curve price, reverts `PoolPreInitialized` so the factory fallback takes over. Liquidity is
   now sized from the executor's ACTUAL post-realign balances, so the mint can never demand more than it holds.
2. **Venue fallback** (factory): `graduateFallback(token)` lets anyone graduate a STUCK Monday launch on Uniswap v4
   immediately — no 7-day lock. Monday-only quote assets (aBIL) keep their rule unless the owner allows the fallback
   for that launch via `allowV4Fallback(token)`. Regressions: `Z_MyMondayFork.t.sol::test_F2a_empty_pool_squat_is_realigned`
   (fork), `Z_MyFallback.t.sol` (4 tests: stuck→v4, owner override for Monday-only, guards).

### M-1 — Owner rewriting an existing launch's fee split  → `src/BondingCurve.sol`, `src/MemeHook.sol`, `ILaunchpad.sol`, `src/LaunchpadFactory.sol`
The protocol's share of the base fee is now PINNED at launch: `BondingCurve.protocolShareBps` is immutable (set
from the factory at launch), and the hook copies it into `PoolLaunch.protocolShareBps` at graduation. Neither reads
`factory.protocolFeeShareBps()` live any more, so `setFeePolicy` only affects launches created afterwards.
`setFeePolicy` doc updated. Regression: `Z_MyUnit.t.sol::test_U3_owner_cannot_change_fee_split_of_existing_launch`.

### L-1 — Opening-second buys reverting / zeroing  → `src/BondingCurve.sol`
`_buyBreakdown` clamps the snipe portion so fee + creator tax + snipe never exceeds `MAX_TOTAL_BPS` (99%). A buy in
second 0 with the max creator tax now settles (heavily taxed) instead of an arithmetic panic, and never returns
zero tokens for a full input. Regressions: `Z_MyUnit.t.sol::test_U1_…`, `test_U2_…`.

### L-2 — Router dev-buy snipe-tax footgun  → `src/LaunchAndBuyRouter.sol`
`launchAndBuy` now adds the buy `recipient` to the snipe-tax exemption list (unless it is the deployer already), so a
dev buy delivered to another wallet is not taxed 98%. Regression: `Z_MyUnit.t.sol::test_U4_router_recipient_is_snipe_exempt`.

### L-3 — Creator fee recipient = address(0) burning fees  → `src/LaunchpadFactory.sol`
`_setCreatorFeeRecipient` and `proposeCreatorFeeRecipient` reject `address(0)` (`ZeroAddress`). Regression:
`Z_MyUnit.t.sol::test_U7_fee_recipient_zero_is_rejected`.

### L-4 — Monday executor/vault/pool counted as eligible holders  → `src/LaunchpadFactory.sol`, `ILaunchpad.sol`, mock
At launch, when a Monday executor is configured, the executor AND its position owner (the fee vault) are added to
the holder-fee-sharing exclusion set; at a Monday graduation the pool itself is excluded. Regression:
`Z_MyUnit.t.sol::test_U6_monday_executor_excluded_from_holder_accounting`.

### Hardening — `src/LaunchpadFactory.sol`
`setPairEconomics` rejects a zero phantom reserve or zero graduation threshold for an approved asset
(`InvalidEconomics`). Regression: `Z_MyUnit.t.sol::test_U8_zero_pair_economics_rejected`.

## Not code-fixable here (documented residuals)
- **C-1, H-2, H-4** are already closed on this branch; the pending REDEPLOY retires the vulnerable live deployment
  `0x2F02…` (and coins GMGM/BPP) that still carry them. `Z_MyLiveExecutorFork.t.sol` retains the live-bug PoC as
  evidence.
- **M-2 (aBIL dependency):** aBIL is an external upgradeable/pausable/denylistable token; a pause or denylist can
  still freeze an aBIL-quoted launch. Mitigation added: `allowV4Fallback` lets the owner rescue a stuck aBIL launch
  onto Uniswap v4. Treat aBIL as a trusted external dependency and monitor it.
- **M-3 (no fees after a Monday graduation):** Monday has no per-swap hook; only LP fees are harvestable (to the
  fees address, via the keeper). This is a venue limitation to surface in the UI, not a contract bug.

## Existing tests touched (behaviour change from H-1's one-block reward delay)
`test/Launchpad.t.sol` (holder accounting), `test/Pool.t.sol` (holders share pool fees), `test/PoC_HolderDrain.t.sol`
each advance one block (`vm.roll`) before observing a distributed reward. Economic outcomes for real holders are
unchanged; only the observation shifts by one block.

## Post-fix adversarial review (2026-09-16) — hardening applied
Re-read every changed line as new attack surface. Three tightenings, each with a regression:
- **Venue preference in `graduateFallback`** — it now retries the creator's chosen venue first (`try this.graduate`)
  and only falls back to Uniswap v4 if Monday *still* reverts. Previously anyone could use the entry point to force a
  stuck-but-recoverable Monday launch onto v4. Gas games cannot force the fallback (the 63/64 rule leaves the retry
  far more gas than the v4 path would get). Regression: `Z_MyFallback.t.sol::test_H3_fallback_prefers_monday_when_it_still_works`.
- **Fee bounds per launch** — `_launch` rejects `curveFee + creatorTax >= 100%` and `poolFee + creatorTax >= 100%`
  (the latter would make every v4 swap revert and trap holders in an unsellable pool), and `addLaunchConfig` bounds
  the pool fee against the max creator tax like it already did for the curve fee. Closes the ordering hole where a
  later `setMaxCreatorTaxBps` could exceed the config-time check. Regression: `Z_MyUnit.t.sol::test_U9…`.
- **`PoolRealigned` event** — sign-safe `spent` (cosmetic).
Also tightened `Z_MyMondayFork.t.sol::test_F2a` to prove the realign completes inside the AUTOMATIC 2M-gas graduation
(no stuck state, no manual call). Final tally: **58 tests, 0 failures** (47 unit + 11 Monad-fork).

The regression tests live in `contracts/test/audit/`. Worktree: `/Users/jerry/Hackathon-launchpad-fix` (uncommitted).
