# Moments — decisions log (rulings that refine the frozen spec)

The spec (`docs/moments-spec.md`, frozen 2026-09-15) wins on everything it covers. The rulings below were made by
the owner during the build and take precedence where they refine or override spec wording. Each item names the
contract that implements it so a reviewer can check the code against the ruling.

## Phase 1 gate review — 2026-09-16

1. **Supply invariant (spec §6 / gate 1 wording).** The literal "Σ(entitlements) + reserve-implied pool + creator ≤ S"
   is not satisfiable exactly with integer clamping: the terminal collect's accepted gross is rounded UP so the
   reserve lands exactly on the threshold, which makes the rate-implied pool exceed the actual remainder by a few
   coin-wei. **Ruling:** the asserted law is the exact conservation identity `pool = S − creator − Σentitlements`
   (holds by construction at every step, asserted at graduation), plus the rigorous bound
   `impliedPool − remainderPool ≤ collects × ⌈rateNum/rateDen⌉`. Implemented in `MomentCollect.supplyCheck`,
   `MomentGraduation.graduate`, `test/moments/Invariant.t.sol`.

2. **"Refund" wording (spec §6, build plan gate 1).** There is no refund transfer. The terminal collect is clamped
   and **only the accepted amount is pulled** from the collector (approve path: `transferFrom(gross)`; Permit2 path:
   `requestedAmount = gross` against a larger permit). The `Quote.excess` field is informational: the part of the
   request that never left the wallet. Implemented in `MomentCollect._prepare` / `collectWithPermit2`.

3. **Collect window.** Each Moment has a creator-set collect window at publish, bounded to
   `[1 hour, 30 days]` (`MomentTypes.MIN_COLLECT_WINDOW` / `MAX_COLLECT_WINDOW`). Collecting is possible strictly
   before `deadline = publishedAt + window`; it also ends immediately at graduation (terminal collect). The 1-hour
   floor is a build choice (the ruling only fixed the 30-day maximum). Implemented in `MomentsFactory.publish`,
   `MomentCollect._prepare`.

4. **Wind-down of an un-graduated Moment (replaces spec §4 "Rescue: fee-free wind-down").** Once the deadline has
   passed without graduation, anyone may call `MomentCollect.expire`: the NFT collection closes (fixed edition),
   no coin is ever minted, entitlements never vest, and the reserve is booked **70% to the creator / 30% to the
   treasury** (policy `expiryCreatorBps = 7000`, snapshotted immutably per Moment), both pull-only by the immutable
   beneficiaries. The creator's 20% and the platform's 5% collect-time shares are unaffected. Nothing goes to the
   caller and nothing can go to an admin address that is not the Moment's snapshotted treasury.

5. **Stuck graduation (threshold reached, executor keeps failing).** Same wind-down as (4), but only once BOTH the
   deadline and a 7-day grace after the first failure (`MomentTypes.STUCK_GRACE`) have passed, so permissionless
   retries always come first. The grace period is a build choice. Incentive note for the auditor: the treasury
   benefits if graduation fails, so the graduation path must have — and has — no admin lever (no pause, no
   re-pointing; modules are wired once in `MomentsFactory.setModules`).

6. **Singletons.** `MomentCollect`, `MomentVesting`, `MomentGraduation`, `MomentLocker`, `MomentFeeHook` and
   `MomentBuyback` are singletons keyed by `momentId`; `MomentCoin` and `MomentNFT` are per-Moment (CREATE2).
   Confirmed at the Phase 1 gate.

7. **Other Phase 1 defaults confirmed at the gate:** the clamped terminal collect mints `⌈accepted/price⌉`
   editions; a vesting month is 30 days; the factory policy timelock is 48 hours; the creator's USDC share absorbs
   the ≤2-unit split rounding.
