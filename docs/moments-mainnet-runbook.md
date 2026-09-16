# Moments — Monad mainnet runbook

## Status (2026-09-16)

**v1.1 is live on Monad mainnet (chain 143)**, deployed by the owner at nonce 67 (24,520,475 gas / 2.501 MON), recorded
in `contracts/deployments/moments-143.json`, source tag `moments-mainnet-v1.1`:

| contract | address |
|---|---|
| factory | `0x64698c7702d85F87f43a6dFF7D495CDD2327C020` |
| collect | `0xb4EE9e67d9e1772BC6949748e3755EA7C1DFE32c` |
| vesting | `0x360E2068eAEc5b5A9AF60A7c4059Bd4b30B7209C` |
| graduation | `0x307De00950F039969855eFb859A6088d695e76b1` |
| locker | `0x832851A42Bf1FD1aF7a19c82cF132290c605E406` |
| hook | `0x8Aa322471Bef2996D3B50cB12F63C6A0054460Cc` (salt `0x11a2b`, permission bits `0x20cc`) |
| buyback | `0x03282D5421a3bE3ff79c5962819c9a6e5E0b52d2` |

Governance = the deployer `0xCf7A…7e10` (nothing pending); platform `0xf4D4…Cfb48`; treasury `0x5282…f045`; policy
$10 threshold / $0.10 minimum / 20-5-75 / 10% max allocation / 70% expiry creator share / 5% ERC-2981 royalty;
`externalBaseURI` = `https://dyorhq.app/moments/` (set 2026-09-16, tx `0xd4930561…4c75e6`; metadata only).

Verified 2026-09-16: on-chain wiring, policy and constants read back correctly; all seven runtime bytecodes match the
source at `optimizer_runs = 44444444` (via_ir, cancun, solc 0.8.26 — the `v4core` profile); all seven are verified on
Sourcify; `test/moments/fork/LiveDeployment.t.sol` runs the whole $10 lifecycle through the deployed contracts on a
fresh mainnet fork (terminal collect + graduation 989,002 gas).

**v1** (factory `0x47D989a54232D3bCdB7A7760D10E596647D986BA`, record `contracts/deployments/moments-143-v1.json`, tag
`moments-mainnet-v1`) is superseded: no Moments were published on it and its publishing is paused (tx `0xe7cc3d8e…37f714`, 2026-09-16).

**Not yet done:** the independent audit (spec §14). Nobody should put real money into these contracts before the
audit, and the owner wallet should never be the one doing it.

## Governance calls after the redeploy — done 2026-09-16 (kept for the record)

Pause publishing on the superseded v1 factory so no Moment can ever be created on the old set:

```bash
~/.foundry/bin/cast send 0x47D989a54232D3bCdB7A7760D10E596647D986BA "setPublishingPaused(bool)" true --rpc-url monad --account owner
```

Set the metadata-only base for the NFTs' `external_url` / `external_link` (replace with the real Moment page base;
the NFT appends the Moment id; can be changed any time by governance, touches no money path):

```bash
~/.foundry/bin/cast send 0x64698c7702d85F87f43a6dFF7D495CDD2327C020 "setExternalBaseURI(string)" "https://dyorhq.app/moments/" --rpc-url monad --account owner
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

## Phase 5 — the web app (`app/moments`)

Routes: `/moments` (explore), `/moments/create` (publish), `/moments/:id` (detail: collect, state, position, creator
pulls, holders), `/moments/portfolio` (pending / claimable / vesting / claimed, `claimAll`). Graduated coins trade on
`/swap` through their hooked pool (route label "moments 1.5%"). Reads are multicalls against
`app/lib/moments-deployment.json` (written by `npm run sync:moments`; ABIs by `npm run abis`); every write is
simulated first. Collects pay through a Permit2 signature (Permit2 approved once) or an exact approval of the collect
contract. Containment: every card and page carries "Early · low-cap · validation", the holder panel shows coin
holders + largest-wallet share + pool share (rebuilt from Transfer logs; no indexer yet) and edition holders, the
pre-collect disclosure must be acknowledged, and nothing anywhere says "proven demand".

Rehearsal against a mainnet fork (the v1.1 contracts already exist in the forked state; anvil's default keys are
7702-delegated on Monad, so the scripts use fresh throwaway keys):

```bash
~/.foundry/bin/anvil --fork-url https://rpc.monad.xyz --chain-id 143 --port 8545
```

```bash
cd /Users/jerry/Hackathon-moments && node scripts/dev/seed-moments-fork.mjs
```

Then start the `web-fork` dev server from `.claude/launch.json` (RPC and log RPC on the fork, the seed's wallet 1 as
an in-page EIP-6963 wallet via `NEXT_PUBLIC_DEV_WALLET_KEY`, dev builds only) and open http://localhost:3100/moments.

## 4. What to expect (reconciled against economics.py and the fork runs)

| step | expected on-chain figure |
|---|---|
| total collected | 13.333334 USDC (creator 2.666668 / platform 0.666666 / reserve 10.000000) |
| pool seed | 10 USDC + 38,571,426.000000000000000012 coins; collectors 51,428,573.999999999999999988; creator 10,000,000 |
| opening price | 2.5926e-7 USDC per coin (FDV ≈ $25.93); first buy lands within 0.05% of the collectors' rate after fees |
| $1 buy | 10,000 units hook fee → 2,000 / 3,000 / 5,000; pool receives 990,000 minus the 0.5% LP fee |
| claim at graduation | 60% of each entitlement; creator 2,000,000 coins |
| terminal collect + graduation | ≈ 986,000 gas on the live contracts (3,000,000 reserved for the subcall) |
