# Moments — Monad mainnet runbook (owner-operated)

Everything here is broadcast by **you** with your own key. Nothing in this repo holds or reads a private key.
Chain 143, RPC alias `monad` (`https://rpc.monad.xyz`), run from `contracts/`.

Reminder from the spec (§14) and the decisions log (ruling 11): a live lifecycle puts about **$13.34 of USDC
plus gas** on contracts that have not had an independent audit yet. That is your call; keep the policy at the
$10 threshold and treat this as the plumbing validation, not a launch.

## Deployed 2026-09-16

Live on Monad mainnet (chain 143) by the owner, recorded in `contracts/deployments/moments-143.json`:
factory `0x47D989a54232D3bCdB7A7760D10E596647D986BA`, collect `0x582E63927Ef364b3737c5F4861517C2C99a8B784`,
vesting `0xB58894e56737cd21e8dD70B9cc69e89D2AAe2466`, graduation `0xC626493540d9eA868b58cBe912E027d4236e5B6F`,
locker `0x125a957360DE495600a1872E19C72823f329b68c`, hook `0x54E83342f4910853A8B1630654754Eb49123e0cC`,
buyback `0xaB5A89779F451d812855206833d8fbe7873f00C8`. Governance = deployer `0xCf7A…7e10` (nothing pending),
platform `0xf4D4…Cfb48`, treasury `0x5282…f045`. Section 1 is done; sections 2 and 3 are still to run.

Verified 2026-09-16: on-chain wiring, policy and constants read back correctly; all seven runtime bytecodes match the
source at `optimizer_runs = 44444444` (via_ir, cancun, solc 0.8.26 — the `v4core` profile, which the Sourcify script
tries first); and `test/moments/fork/LiveDeployment.t.sol` runs the full lifecycle through the deployed contracts
on a fresh mainnet fork (terminal collect + graduation 986,085 gas).

## 0. Prerequisites

- Owner wallet with MON for gas (≈ 0.1 MON is plenty) and ≥ 15 USDC (`0x754704Bc059F8C67012fEd69BC8A327a5aafb603`).
- `export OWNER_KEY=0x…` in the shell that runs the commands (never commit it).
- Decide the beneficiaries. Defaults are the deployer for all three; override with env vars:
  `GOVERNANCE` (policy multisig; two-step, it must call `acceptGovernance()`), `PLATFORM` (5% + 0.3% fee
  receiver), `TREASURY` (30% of an expired reserve). Policy overrides: `THRESHOLD_USDC` (default 10_000_000),
  `MIN_PRICE_USDC` (100_000), `EXPIRY_CREATOR_BPS` (7_000).

## 1. Deploy (dry run first)

```bash
cd contracts && ~/.foundry/bin/forge script script/moments/Deploy.s.sol:DeployMoments --rpc-url monad --code-size-limit 200000
```

```bash
cd contracts && PLATFORM=0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48 TREASURY=0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045 ~/.foundry/bin/forge script script/moments/Deploy.s.sol:DeployMoments --rpc-url monad --broadcast --non-interactive --private-key $OWNER_KEY --code-size-limit 200000
```

`--code-size-limit 200000` silences forge's EIP-170 lint: the factory embeds the coin + NFT creation code and is
27 KB, which Monad allows (its limit is 128 KB; the Launchpad factory deployed the same way).

Writes `contracts/deployments/moments-143.json` (the Launchpad's `143.json` is never touched). The hook lands on a
mined CREATE2 address whose low 14 bits are `0x20CC` (beforeInitialize, beforeSwap, afterSwap, both return deltas).
If you set `GOVERNANCE` to a multisig, it must call `acceptGovernance()` on the factory to take over policy.

## 2. Verify on Sourcify

```bash
cd contracts && ./script/moments/verify-moments-143.sh
```

## 3. Live $10 lifecycle (one `--sig` per step, all from the owner wallet)

Publish the validation Moment ($1 collects, 10% creator allocation, 30-day window; override `COLLECT_PRICE_USDC`,
`CREATOR_ALLOC_BPS`, `COLLECT_WINDOW`, `MOMENT_NAME`, `MOMENT_SYMBOL`, `MEDIA_URI`, `PLACE`, `SALT`):

```bash
cd contracts && ~/.foundry/bin/forge script script/moments/Lifecycle.s.sol:MomentsLifecycle --rpc-url monad --broadcast --non-interactive --private-key $OWNER_KEY --sig "publish()"
```

Collect until graduation — 14 collects: 13 × $1 and one clamped to 0.333334 USDC; the last one graduates the
Moment inside the same transaction (pool opened on the real PoolManager, position locked, vesting started):

```bash
cd contracts && MOMENT_ID=1 ~/.foundry/bin/forge script script/moments/Lifecycle.s.sol:MomentsLifecycle --rpc-url monad --broadcast --non-interactive --private-key $OWNER_KEY --sig "collectUntilGraduated()"
```

Trade $1 through the real Universal Router (Permit2-funded, exactly like the app): the hook takes 1% of the USDC
leg (0.2% creator / 0.3% platform / 0.5% buyback) on top of the pool's 0.5% LP fee:

```bash
cd contracts && MOMENT_ID=1 ~/.foundry/bin/forge script script/moments/Lifecycle.s.sol:MomentsLifecycle --rpc-url monad --broadcast --non-interactive --private-key $OWNER_KEY --sig "trade()"
```

Claim vested coins (60% collector tranche + 20% creator tranche at graduation; rerun after each 30-day cliff):

```bash
cd contracts && MOMENT_ID=1 ~/.foundry/bin/forge script script/moments/Lifecycle.s.sol:MomentsLifecycle --rpc-url monad --broadcast --non-interactive --private-key $OWNER_KEY --sig "claim()"
```

Withdraw pull-only USDC (creator collect share 2.666668 USDC + creator trading fees; run from the platform /
treasury wallets for their shares):

```bash
cd contracts && MOMENT_ID=1 ~/.foundry/bin/forge script script/moments/Lifecycle.s.sol:MomentsLifecycle --rpc-url monad --broadcast --non-interactive --private-key $OWNER_KEY --sig "withdraw()"
```

Buyback-and-LP (permissionless; needs ≥ 1 USDC of accrued buyback fees, i.e. ≥ $200 of volume at 0.5%):

```bash
cd contracts && MOMENT_ID=1 ~/.foundry/bin/forge script script/moments/Lifecycle.s.sol:MomentsLifecycle --rpc-url monad --broadcast --non-interactive --private-key $OWNER_KEY --sig "buyback()"
```

Read-only status at any time:

```bash
cd contracts && MOMENT_ID=1 ~/.foundry/bin/forge script script/moments/Lifecycle.s.sol:MomentsLifecycle --rpc-url monad --sig "status()"
```

## 4. What to expect (reconciled against economics.py and the fork run)

| step | expected on-chain figure |
|---|---|
| total collected | 13.333334 USDC (creator 2.666668 / platform 0.666666 / reserve 10.000000) |
| pool seed | 10 USDC + 38,571,426.000000000000000012 coins; collectors 51,428,573.999999999999999988; creator 10,000,000 |
| opening price | 2.5926e-7 USDC per coin (FDV ≈ $25.93); first buy lands within 0.05% of the collectors' rate after fees |
| $1 buy | 10,000 units hook fee → 2,000 / 3,000 / 5,000; pool receives 990,000 minus the 0.5% LP fee |
| claim at graduation | 60% of each entitlement; creator 2,000,000 coins |

Note the wallet that publishes and collects everything is doing a self-graduation: the fork run shows it recovers
~7.21 of the 13.33 USDC if it dumps everything liquid at open. That is the accepted, UI-contained risk from spec §13.
