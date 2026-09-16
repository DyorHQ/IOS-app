# Moments — Monad mainnet runbook

## Status (2026-09-16)

Live on Monad mainnet (chain 143), deployed by the owner, recorded in `contracts/deployments/moments-143.json`:

| contract | address |
|---|---|
| factory | `0x47D989a54232D3bCdB7A7760D10E596647D986BA` |
| collect | `0x582E63927Ef364b3737c5F4861517C2C99a8B784` |
| vesting | `0xB58894e56737cd21e8dD70B9cc69e89D2AAe2466` |
| graduation | `0xC626493540d9eA868b58cBe912E027d4236e5B6F` |
| locker | `0x125a957360DE495600a1872E19C72823f329b68c` |
| hook | `0x54E83342f4910853A8B1630654754Eb49123e0cC` (permission bits `0x20cc`) |
| buyback | `0xaB5A89779F451d812855206833d8fbe7873f00C8` |

Governance = the deployer `0xCf7A…7e10` (nothing pending); platform `0xf4D4…Cfb48`; treasury `0x5282…f045`.

Verified: on-chain wiring, policy and constants read back correctly; all seven runtime bytecodes match the source at
`optimizer_runs = 44444444` (via_ir, cancun, solc 0.8.26 — the `v4core` profile); all seven are **verified on Sourcify**
(creation + runtime match, 2026-09-16 11:33–11:35 UTC, `https://sourcify-api-monad.blockvision.org/v2/contract/143/<address>`);
`test/moments/fork/LiveDeployment.t.sol` runs the whole $10 lifecycle through the deployed contracts on a mainnet fork.

**Not yet done:** the independent audit (spec §14) and the Phase 4 security self-review. Nobody should put real
money into these contracts before those, and the owner wallet should never be the one doing it (below).

## Redeploy v1.1 (owner action, pending)

The v1 set above stays on-chain but will be paused; the app (Phase 5) wires to the v1.1 set. v1.1 = branch commit
`ac33952`: v1 + constructor zero-address checks, NFT metadata JSON escaping, policy floors (threshold ≥ 1 USDC,
min price ≥ $0.01). Full suite green on that commit (106 tests). The v1 record is archived as
`contracts/deployments/moments-143-v1.json`; the script overwrites `moments-143.json` with the v1.1 addresses.

Dry run as the owner address (nonce 67) predicted these addresses — they hold only if the deployment transactions
are the owner wallet's next eight transactions, in order; otherwise the recorded JSON is the truth:

| contract | predicted v1.1 address |
|---|---|
| factory | `0x64698c7702d85F87f43a6dFF7D495CDD2327C020` |
| vesting | `0x360E2068eAEc5b5A9AF60A7c4059Bd4b30B7209C` |
| collect | `0xb4EE9e67d9e1772BC6949748e3755EA7C1DFE32c` |
| locker | `0x832851A42Bf1FD1aF7a19c82cF132290c605E406` |
| graduation | `0x307De00950F039969855eFb859A6088d695e76b1` |
| buyback | `0x03282D5421a3bE3ff79c5962819c9a6e5E0b52d2` |
| hook | `0x7987611588FDEdf0753176Aa8036206c26C560CC` (salt `0x2bd`, bits `0x20cc`) |

Estimated cost from the simulation: about 22.9M gas (≈ 4.6 MON at the 202 gwei quoted at the time). Governance,
platform and treasury are unchanged (`0xCf7A…7e10`, `0xf4D4…Cfb48`, `0x5282…f045`); nothing is pending.

Broadcast (encrypted keystore, recommended — one-time `cast wallet import owner --interactive`):

```bash
cd /Users/jerry/Hackathon-moments/contracts && PLATFORM=0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48 TREASURY=0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045 ~/.foundry/bin/forge script script/moments/Deploy.s.sol:DeployMoments --rpc-url monad --broadcast --non-interactive --account owner --code-size-limit 200000
```

or, as done for v1, with the key in the environment (`--private-key $OWNER_KEY` in place of `--account owner`).

After it lands: report the written `deployments/moments-143.json`; verification (wiring, bytecode at the v4core
profile, live-fork lifecycle through the new contracts, Sourcify) follows, then the v1 factory is paused so no
Moment can be published on the old set (governance call from the owner wallet):

```bash
~/.foundry/bin/cast send 0x47D989a54232D3bCdB7A7760D10E596647D986BA "setPublishingPaused(bool)" true --rpc-url monad --account owner
```

## Wallet hygiene (non-negotiable)

- The **owner / governance wallet** (`0xCf7A…7e10`) does governance only: `proposePolicy`, `applyPolicy`,
  `cancelPolicy`, `setPublishingPaused`, `transferGovernance`. It never publishes, collects, trades, approves USDC
  or holds allowances to any Moments contract. The platform and treasury wallets only ever *pull* their USDC.
- Governance transactions are signed with a hardware wallet or an encrypted keystore, not a raw key in the shell:
  `forge script … --ledger` / `cast send … --ledger`, or `cast wallet import owner --interactive` then `--account owner`.
  Do not keep `OWNER_KEY` in an environment variable or shell history.
- Product actions (publish, collect, claim, trade) are done through the DyorHQ app by ordinary wallets. For the
  validation launch use **dedicated, low-value wallets**: one creator wallet and a few collector wallets funded by a
  normal USDC transfer of a few dollars each, and nothing else in them. They approve exact amounts or use Permit2
  signatures (the app's default), never unlimited approvals.

## 1. Deploy — done

```bash
cd contracts && PLATFORM=0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48 TREASURY=0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045 ~/.foundry/bin/forge script script/moments/Deploy.s.sol:DeployMoments --rpc-url monad --broadcast --non-interactive --ledger --code-size-limit 200000
```

`--code-size-limit 200000` silences forge's EIP-170 lint: the factory embeds the coin + NFT creation code and is
27 KB, which Monad allows (128 KB limit; the Launchpad factory deployed the same way). The Launchpad's
`deployments/143.json` is never touched.

## 2. Verify on Sourcify — done

```bash
cd contracts && ./script/moments/verify-moments-143.sh
```

No key and no transaction: it uploads source + metadata and Sourcify matches them against the chain.

## 3. The live lifecycle runs through the app, not through scripts

The build plan's order is: Phase 4 security self-review → Phase 5 web app (`app/moments`) verified against a fork →
Phase 6 deploy gates and the curated small-cap validation launch. The validation launch *is* the live lifecycle:

1. A creator (dedicated wallet, via the app) publishes a Moment with a $1 collect price and a 30-day window.
2. A few collectors (dedicated wallets, via the app, Permit2-signed) collect until the reserve reaches $10 —
   14 collects at $1: 13 full ones and one clamped to 0.333334 USDC. The last collect graduates the Moment on the
   real PoolManager in the same transaction; the app shows the pool, the fixed edition and the vesting schedule.
3. Collectors claim 60% at graduation and the rest at the 30- and 60-day cliffs; the creator claims 20% then
   16% per month; the app's portfolio view drives `claim` / `claimAll`.
4. Trades go through the app's existing v4 swap path (Universal Router + Permit2); the hook takes 1% of the USDC
   leg on top of the pool's 0.5% LP fee. Once ≥ 1 USDC of buyback fees has accrued (~$200 of volume) anyone can
   trigger the buyback from the app; it can only add to the locked position.
5. The platform and treasury wallets pull their USDC when they choose.

No step above involves the owner wallet, a private key in a shell, or an unlimited approval. Total exposure of the
validation launch is the collectors' ~$13.34 of USDC plus gas, on contracts that — per spec §14 — should be audited
first; that remains the owner's decision.

`script/moments/Lifecycle.s.sol` is a **fork-only** rehearsal of the same steps for app development against
`anvil --fork-url monad` (guarded by `FORK_REHEARSAL=1`, exact approvals, anvil's throwaway keys). It is not a
mainnet procedure.

## 4. What to expect (reconciled against economics.py and the fork runs)

| step | expected on-chain figure |
|---|---|
| total collected | 13.333334 USDC (creator 2.666668 / platform 0.666666 / reserve 10.000000) |
| pool seed | 10 USDC + 38,571,426.000000000000000012 coins; collectors 51,428,573.999999999999999988; creator 10,000,000 |
| opening price | 2.5926e-7 USDC per coin (FDV ≈ $25.93); first buy lands within 0.05% of the collectors' rate after fees |
| $1 buy | 10,000 units hook fee → 2,000 / 3,000 / 5,000; pool receives 990,000 minus the 0.5% LP fee |
| claim at graduation | 60% of each entitlement; creator 2,000,000 coins |
| terminal collect + graduation | ≈ 986,000 gas on the live contracts (3,000,000 reserved for the subcall) |
