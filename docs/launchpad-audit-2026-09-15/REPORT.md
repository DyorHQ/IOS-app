# DyorHQ Launchpad — Deep Security Audit (2026-09-15)

Scope: the deployed launchpad on Monad mainnet (factory `0x2F02972E…`) and the fixed, not-yet-deployed
branch `feat/launchpad-venue-economics` (HEAD `b561c5c`). Method: full line-by-line re-read plus runnable
Foundry PoCs (unit + Monad-mainnet fork). Every "CONFIRMED" finding has a passing/【documented】PoC under
`contracts/test/audit/`. This extends the 2026-09-12 audit; it does not restate its fixed items
except where they are still LIVE on `0x2F02…`.

"LIVE" = exploitable on the deployed `0x2F02…` today. "BRANCH" = present in the fixed code that will ship on the
planned redeploy unless addressed. Live coins: GMGM `0x74b215C1…` (holderFeeSharing ON, Monday venue),
BPP `0xB281906b…` (Monday venue). Both curves currently hold 1–2 wei — nothing at risk *yet*, but both are open.

---

## CRITICAL

### C-1 — Holder-reward self-transfer drain (LIVE, unpatchable in place)
`src/HolderFeeSharing.sol` (deployed build). Documented 2026-09-12 and fixed on the branch (`from==to` early
return). It remains LIVE on `0x2F02…`: any holder of a holder-fee-sharing coin drains every other holder's
rewards via `token.transfer(self, bal); claim()`. GMGM has holderFeeSharing ON. No rewards have accrued yet
(curve at 2 wei), so there is nothing to steal *today*, but it is live the instant fees flow. This is the single
reason a redeploy is mandatory; the branch fix is correct (regression test `test/PoC_HolderDrain.t.sol`).

---

## HIGH

### H-1 — Flash-take reward-sniping on v4 holder-fee-sharing launches (BRANCH — NOT yet fixed) · CONFIRMED
`src/MemeHook.sol:212 sweepPoolFees` (permissionless) + `src/HolderFeeSharing.sol:108 notifyReward` +
`src/LaunchToken.sol` (v4 pool reserves are flash-borrowable). After a holder-fee-sharing coin graduates to a
Uniswap v4 pool, anyone can, in one atomic transaction and with **zero capital**:
1. `PoolManager.unlock` → `take` the launch token out of the pool (its whole reserve is borrowable);
2. call the permissionless `sweepPoolFees`, which distributes the pending swap fees to holders via
   `notifyReward` — crediting the attacker's flash-inflated balance its full pro-rata slice;
3. `claim` that slice, then repay the flash.

The attacker captures `poolReserve / (poolReserve + circulating)` of **every** fee sweep, forever, risk-free.
PoC `contracts/test/audit/Z_MyFlashSnipe.t.sol::test_C5_flash_take_snipes_holder_rewards_zero_capital`: sniper took **16.6 %** of a
0.5 MON sweep with 0 capital (= its 1658-bps flash balance share; the honest holder got 0.4167 instead of 0.5).
Under the live √10 economics (~31.6 % of supply reserved) the skim rises to ~31 % of every distribution. This is
theft from the exact holders the feature is meant to reward, and it ships on the redeploy unless fixed.
Fix: make reward eligibility flash-resistant — reject `sweepPoolFees`/`notifyReward` while a PoolManager unlock is
open, and/or make a balance acquired in the current block ineligible for that block's distribution (track the last
balance-change block per account). Monday-venue coins are unaffected (no per-swap hook).

### H-2 — Monday graduation mispricing via pool pre-init (LIVE executor `0x3d92…`) · CONFIRMED
Deployed `MondayGraduationExecutor` (commit `62a8439`, `mondayExecutor 0x3d92023c…` in `deployments/143.json`) has
**no price guard**: `if (current == 0) initialize(sqrtPrice)` with no `else revert`. Monday's factory is
permissionless, so an attacker pre-creates and initializes the TOKEN/WMON pool at a price of their choosing; at
graduation the executor mints the entire graduating reserve as liquidity at the attacker's price, then the attacker
buys the token back cheap. PoC `contracts/test/audit/Z_MyLiveExecutorFork.t.sol::test_L1…` (fork, exact deployed source): attacker
pre-inits 30 % below fair, then buys **36.4 % more tokens** for 500 WMON than the graduation price implies. Both
live coins chose Monday, so any that fills its curve is exposed. Fixed on the branch (`PoolPreInitialized` revert),
but that fix creates H-3.

### H-3 — Monday graduation griefing / permanent DoS (BRANCH — residual of the H-2 fix) · CONFIRMED
`src/MondayGraduationExecutor.sol:88` now reverts `PoolPreInitialized` when a pre-existing Monday pool sits at any
price ≠ the curve's. Because the pool is permissionless, **anyone can create+initialize it at a wrong price for
~555k gas** and permanently block graduation: the completing buy's auto-graduation fails, the launch is marked
stuck, and holders cannot exit until the owner calls `rescue` — only allowed 7 days later. PoC
`contracts/test/audit/Z_MyMondayFork.t.sol::test_F2_/test_F3_`. Affects aBIL (forced Monday) and every Monday launch; the trade is a
cheap, repeatable denial of service on a competitor's or victim's launch with a mandatory 7-day holder lock-up.
Fix: instead of reverting on a mispriced pre-existing pool, swap it to the target price before minting when it has
no liquidity, or fall back to the Uniswap v4 venue, so a squatter cannot brick graduation.

### H-4 — Owner can swap the graduation executor / router / deployer after launches (LIVE `0x2F02…`)
Deployed `LaunchpadFactory.setModules` (commit `62a8439`, line ~153) freezes only `hook/locker/escrow/sharing`
once launches exist — **not** `graduationExecutor`, `mondayExecutor`, `router` or `launchDeployer`. The EOA owner
`0xCf7A9f1D…` can therefore swap in a malicious executor that seizes the next graduation's swept reserves (all the
raised quote + reserved supply). Documented 2026-09-12; fully frozen on the branch (`88257ee`), so the redeploy
closes it — flagged here because it is LIVE now and the owner is a single EOA with no timelock.

---

## MEDIUM

### M-1 — Owner can rewrite the fee split of existing launches (LIVE + BRANCH) · CONFIRMED
`LaunchpadFactory.setFeePolicy` sets `protocolFeeShareBps`/`protocolFeeRecipient`, which curves and the hook read
**live**. The owner (EOA, no timelock) can set the protocol share to 100 % and redirect the recipient, taking the
entire base fee from every existing and future launch — even though `expectedEconomics` pinned a 50/50 split at
launch time (the pin only covers launch, not later trading). PoC `contracts/test/audit/Z_MyUnit.t.sol::test_U3…`. Fix: put policy
changes behind the same freeze/timelock as modules, or snapshot the split per launch.

### M-2 — aBIL / Monday external-dependency & compliance risk (LIVE + BRANCH)
aBIL (`0x4FC5B9f8…`, the forced-Monday RWA quote) is an **upgradeable beacon proxy** (beacon `0xfe296A…`, impl
`0x45ad0F…`) whose transfers are gated by a compliance module `0xF1aeD4…` with a **denylist** and global
`TransferPaused`/`RedemptionPaused`, plus an external `MINTER_ROLE` (`0x35Ac64…`, `0xF462C8…`) and admin
`0xcb438964…2000` — all outside DyorHQ. If aBIL pauses transfers or denylists a curve/pool, an aBIL-quoted launch
freezes mid-lifecycle and the ERC-20 path has **no rescue** (rescue only reopens curve sells, which also revert if
aBIL is paused). Monday pools are themselves upgradeable proxies (impl `0x25cC…`→`0x622b…`). Confirmed on-chain +
fork (fresh-address transfers work today: denylist, not allowlist — `contracts/test/audit/Z_MyMondayFork.t.sol::test_F6_`). Treat
aBIL as a trusted-but-external dependency; document the freeze risk and consider a longer/asset-aware rescue path.

### M-3 — No creator or holder fees after a Monday graduation (LIVE + BRANCH, design gap)
Monday pools use Monday's own fee tier; the launchpad has no per-swap hook there. Post-graduation, only the LP swap
fees are harvestable (permissionlessly, to the `fees` address) via `MondayFeeVault.collectFees`, and only if a
keeper pokes it. Creators and holders of Monday coins earn **nothing** after graduation — both live coins are
Monday. Not a theft, but a material economics gap versus the v4 venue; make it explicit in the UI/docs.

---

## LOW

- **L-1 — Opening-window buys revert or zero-out (LIVE+BRANCH, CONFIRMED `U1`/`U2`).** With the deployed
  schedule, second 0 is 98 % snipe + 1 % fee + creator tax: at max tax (10 %) total > 100 % → every non-exempt buy
  and `quoteBuy` reverts with an arithmetic panic; at exactly 100 % the buy takes the whole input for **zero
  tokens**. Griefs the launch's first seconds and can burn a careless buyer. Consider capping total bps < 100 % or
  clamping snipe tax so a buy always returns > 0.
- **L-2 — Router dev-buy snipe-tax footgun (LIVE+BRANCH, CONFIRMED `U4`).** `currentSnipeTaxBps` keys on
  `recipient`, not the exempt deployer, so `launchAndBuy` with `recipient ≠ msg.sender` pays the 98 % snipe tax
  (half to the protocol). Exempt the deployer's chosen recipient, or document it loudly.
- **L-3 — Creator fee recipient can be set to `address(0)` (LIVE+BRANCH, CONFIRMED `U7`).** The escrow's push to
  `address(0)` "succeeds", so fees are burned rather than booked. Reject the zero address in
  `transferCreatorFeeRecipient`/`_setCreatorFeeRecipient`.
- **L-4 — Monday executor/pool/vault not excluded from HolderFeeSharing (BRANCH, CONFIRMED `U6`).** Benign today
  (no reward source after a Monday graduation), but a latent accounting mismatch if Monday ever notifies rewards.

---

## Checked and found safe (with evidence)
- Auto-graduation fits the 2,000,000-gas cap in every configuration — v4 & Monday, holder-sharing on/off, real
  aBIL; measured `graduate()` ≈ 1.15–1.27M gas (`Z_MyUnit U5/U5b`, `Z_MyMondayFork F1/F4/F5`).
- Real aBIL end-to-end: launch → complete → Monday graduation → `collectFees` all succeed on a fork (`F5`).
- FeeEscrow push-then-escrow: value-conserving, `nonReentrant`, bounded 60k-gas push, malformed/`false`/return-bomb
  ERC-20 returns fall back to a claimable balance and never brick the payer (2026-09-13 review; unchanged).
- LP principal permanently locked: v4 `LaunchLocker` (no withdraw path) and Monday `MondayFeeVault` (`burn(…,0)`
  only) — fork-verified principal stays locked while only fees leave.
- Curve solvency: sweep/refund/fee rounding leaves sub-wei dust in the protocol's favor; `sweep` is single-shot.
- FeeEscrow/HolderFeeSharing claims are strictly `msg.sender`; already-credited funds cannot be seized.

## Priority for the redeploy
1. Fix **H-1** (flash-snipe) and **H-3** (Monday griefing) in the branch *before* redeploying — they are new/residual
   and would otherwise ship. 2. The redeploy itself closes C-1, H-2, H-4. 3. Address **M-1** (policy timelock) and
   document **M-2/M-3**. 4. Clean up the LOWs. 5. Retire `0x2F02…`, GMGM and BPP after the new deployment.
