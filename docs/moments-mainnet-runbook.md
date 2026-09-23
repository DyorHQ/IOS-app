# Moments — Monad mainnet runbook

## Status (2026-09-23)

**Cohort 3 is live on Monad mainnet (chain 143):** factory `0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26` (deploy
block 107 311 600), recorded in `contracts/deployments/moments-143.json`. Platform = the new fees wallet
`0x15ED…5Cd7`, treasury = the new treasury `0x5aDb…A371`, threshold 771.428571 USDC ($2,000 FDV), every other
policy field as before; code byte-identical to cohort 2. Deployed by the 2026-09-23 relaunch that followed the
treasury-key leak: §1c. Cohort 2 (`0xc12B…a581`, §1b), cohort 1 (`0x6469…C020`, below) and v1 are paused; their
Moments (3 on cohort 1, 2 on cohort 2) stay on-chain with the old wallets snapshotted.

### Cohort 1 — v1.1 (2026-09-16), retired

v1.1 went live on 2026-09-16, deployed by the owner at nonce 67 (24,520,475 gas / 2.501 MON), record now
`contracts/deployments/moments-143-cohort1.json`, source tag `moments-mainnet-v1.1`:

| contract | address |
|---|---|
| factory | `0x64698c7702d85F87f43a6dFF7D495CDD2327C020` |
| collect | `0xb4EE9e67d9e1772BC6949748e3755EA7C1DFE32c` |
| vesting | `0x360E2068eAEc5b5A9AF60A7c4059Bd4b30B7209C` |
| graduation | `0x307De00950F039969855eFb859A6088d695e76b1` |
| locker | `0x832851A42Bf1FD1aF7a19c82cF132290c605E406` |
| hook | `0x8Aa322471Bef2996D3B50cB12F63C6A0054460Cc` (salt `0x11a2b`, permission bits `0x20cc`) |
| buyback | `0x03282D5421a3bE3ff79c5962819c9a6e5E0b52d2` |

Governance = the deployer `0xCf7A…Fe10` (nothing pending); platform `0xf4D4…Cfb48`; treasury `0x5282…f045`; policy
$10 threshold / $0.10 minimum / 20-5-75 / 10% max allocation / 70% expiry creator share / 5% ERC-2981 royalty;
`externalBaseURI` = `https://dyorhq.fun/moments/` (corrected 2026-09-17, tx `0x7f0757eb…3b75`, from the unregistered
`dyorhq.app` originally set 2026-09-16 tx `0xd4930561…4c75e6`; metadata only, changeable by governance any time).

Verified 2026-09-16: on-chain wiring, policy and constants read back correctly; all seven runtime bytecodes match the
source at `optimizer_runs = 44444444` (via_ir, cancun, solc 0.8.26 — the `v4core` profile); all seven are verified on
Sourcify; `test/moments/fork/LiveDeployment.t.sol` ran the whole $10 lifecycle through the deployed contracts on a
fresh mainnet fork (terminal collect + graduation 989,002 gas). That test now targets cohort 3 (§1c).

**v1** (factory `0x47D989a54232D3bCdB7A7760D10E596647D986BA`, record `contracts/deployments/moments-143-v1.json`, tag
`moments-mainnet-v1`) is superseded: no Moments were published on it and its publishing is paused (tx `0xe7cc3d8e…37f714`, 2026-09-16).

**Launch is unblocked:** ruling 18 waived the legal/KYC/geofence line and ruling 19 defers the independent audit
until after the validation launch (interim posture in `docs/moments-launch-gates.md`). The owner wallet is never the
one collecting.

## Governance calls after the redeploy — done 2026-09-16 (kept for the record)

Pause publishing on the superseded v1 factory so no Moment can ever be created on the old set:

```bash
~/.foundry/bin/cast send 0x47D989a54232D3bCdB7A7760D10E596647D986BA "setPublishingPaused(bool)" true --rpc-url monad --account owner
```

Set the metadata-only base for the NFTs' `external_url` / `external_link` (replace with the real Moment page base;
the NFT appends the Moment id; can be changed any time by governance, touches no money path):

```bash
~/.foundry/bin/cast send 0x64698c7702d85F87f43a6dFF7D495CDD2327C020 "setExternalBaseURI(string)" "https://dyorhq.fun/moments/" --rpc-url monad --account owner
```

## Wallet hygiene (non-negotiable)

- The **owner / governance wallet** (`0xCf7A…Fe10`) does governance only: `proposePolicy`, `applyPolicy`,
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

Historical (cohort 1): this command names the OLD wallets (`0xf4D4…` / the leaked `0x5282…`) — never re-run it.

```bash
cd contracts && PLATFORM=0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48 TREASURY=0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045 ~/.foundry/bin/forge script script/moments/Deploy.s.sol:DeployMoments --rpc-url monad --broadcast --non-interactive --ledger --code-size-limit 200000
```

`--code-size-limit 200000` silences forge's EIP-170 lint: the factory embeds the coin + NFT creation code and is
27 KB, which Monad allows (128 KB limit; the Launchpad factory deployed the same way). The Launchpad's
`deployments/143.json` is never touched.

## 1b. Cohort-2 redeploy — the $2,000 graduation FDV baked in (2026-09-22) — DONE

Historical: cohort 2 is paused since 2026-09-23 (§1c). `redeploy-cohort2.sh` and the commands below hard-code the
OLD wallets (`0xf4D4…` / the leaked `0x5282…`) — never re-run them.

**Executed 2026-09-22 with `script/moments/redeploy-cohort2.sh`** from the governance wallet: factory
`0xc12B6b6948185cef75F861c5327702c30CB8a581` (block 106 984 957), collect `0x8f65…2493`, vesting `0xe087…6C99`,
graduation `0x353F…045b`, locker `0x9957…9a8a`, hook `0x501D…20Cc`, buyback `0xacae…c6F5`; 8 transactions,
24.52M gas; policy threshold 771 428 571 read back from the chain; `externalBaseURI` set; cohort-1 factory
`0x6469…C020` paused (tx `0xb1d5cd08…9d852`); all seven contracts verified on Sourcify; `moments-status.mjs` all
invariants OK. Record: `deployments/moments-143.json` (cohort 1 kept in `moments-143-cohort1.json`).

The owner chose a fresh deployment over the timelocked policy change (ruling 20): the new stack starts with the
cohort-2 policy in its constructor (threshold 771.428571 USDC, everything else as before) and the cohort-1 stack is
retired. Rehearsed end to end on an anvil fork the same day — deploy → publish → terminal collect → atomic
graduation at $1,999.999999 FDV → `scripts/moments-status.mjs` all invariants OK. Two fork gotchas that are not
mainnet problems: anvil needs `--code-size-limit 200000` as well or it rejects the 66 KB factory at 24 KB, and
forge's own size lint must be silenced with `--non-interactive` (it otherwise waits for a confirmation).
Estimated cost 24.2M gas ≈ 4.9 MON at 202 gwei; the governance wallet held 27.6 MON.

**One-command form:** `script/moments/redeploy-cohort2.sh` does steps 1–5 below in order with a confirmation
before the real deployment, signing with `PRIVATE_KEY` from the shell (or the repo `.env`) exactly as every
deployment here is signed — or `LEDGER=1` for the hardware wallet; `DRY_RUN=1` simulates only. It refuses any
signer other than the cohort-1 governance wallet, checks the chain and the balance, keeps the cohort-1 record, and
never prints the key. Because CREATE addresses depend only on the deployer's nonce, the addresses the dry run prints
are the ones the real run lands on unless that wallet sends something else first.

```bash
cd /Users/jerry/Hackathon-moments/contracts && ./script/moments/redeploy-cohort2.sh
```

The individual steps, for reference:

1. Deploy, signed on the Ledger. `--sender` pins the governance address: if the Ledger presents any other
   account forge aborts before sending anything. The cohort-1 record is kept as `deployments/moments-143-cohort1.json`;
   the script overwrites `deployments/moments-143.json` with the new stack.

```bash
cd /Users/jerry/Hackathon-moments/contracts && THRESHOLD_USDC=771428571 PLATFORM=0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48 TREASURY=0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045 ~/.foundry/bin/forge script script/moments/Deploy.s.sol:DeployMoments --rpc-url monad --broadcast --non-interactive --code-size-limit 200000 --ledger --sender 0xCf7A9f1DE835a691f969B76e6eb4842BFaA7Fe10
```

2. Metadata base for the new NFTs' external links (PolicyOps now reads the new factory from the JSON):

```bash
cd /Users/jerry/Hackathon-moments/contracts && BASE=https://dyorhq.fun/moments/ ~/.foundry/bin/forge script script/moments/PolicyOps.s.sol:PolicyOps --rpc-url monad --broadcast --non-interactive --ledger --sender 0xCf7A9f1DE835a691f969B76e6eb4842BFaA7Fe10 --sig "setBase()"
```

3. Retire the cohort-1 stack: pause publishing on the OLD factory (explicit address — the JSON now names the new
   one). Contracts cannot be deleted: Moments 1–3, their coins, NFTs and the Bitcoin Diva pool stay on-chain and
   tradable; they simply disappear from the app once it points at the new factory.

```bash
~/.foundry/bin/cast send 0x64698c7702d85F87f43a6dFF7D495CDD2327C020 "setPublishingPaused(bool)" true --rpc-url monad --ledger
```

4. Verify on Sourcify, no key: `cd /Users/jerry/Hackathon-moments/contracts && ./script/moments/verify-moments-143.sh`.

5. Wire the app: `MomentsAddresses.monadMainnet` in `ios/DyorKit/Sources/DyorKit/Services/Moments/MomentsModels.swift`
   (all seven module addresses plus `deployBlock` = the factory-creation block in
   `broadcast/Deploy.s.sol/143/run-latest.json`), `npm run sync:moments` for the web app, then
   `node scripts/moments-status.mjs` and the app's Moments tab: empty feed, Publish screen reading
   "Graduates at $771.43 reserve · $2,000 FDV".

## 1c. Cohort-3 relaunch (2026-09-23) — DONE

The treasury key `0x5282…` leaked on 2026-09-17 and the owner rotated the money wallets (treasury → `0x5aDb…A371`,
fees → `0x15ED…5Cd7`). Moments policies are snapshotted per stack and per Moment, so the fix was a fresh stack with
the new wallets in its constructor.

- **How it ran:** as steps 4–5 of the launchpad repo's one-command relaunch,
  `/Users/jerry/Hackathon/contracts/script/relaunch/relaunch-new-wallets.sh`, signed by the governance wallet
  `0xCf7A…Fe10`, from this worktree's source at `3db2294` (`script/moments/Deploy.s.sol:DeployMoments`,
  `THRESHOLD_USDC=771428571 PLATFORM=0x15ED3bb488231213b141A2f78b62358D52235Cd7 TREASURY=0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371`).
  Log: `/Users/jerry/Hackathon/contracts/deployments/relaunch-20260923-113538.log`; full record with every tx hash:
  `/Users/jerry/Hackathon/docs/relaunch-2026-09-23.md`.
- **Stack** (8 transactions, blocks 107 311 600–107 311 630, 24.37M gas estimated): factory
  `0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26` (tx `0x10f15e0a…2c2efa`), collect `0xb538…1D30`, vesting
  `0x0558…b021`, graduation `0xA223…b9aA`, locker `0x37C5…f455`, hook `0xD5BF…60CC` (salt `0x36fa`), buyback
  `0x3B57…a913`. Record: `deployments/moments-143.json` (cohort 2 kept in `moments-143-cohort2.json`).
- **Governance calls:** `setExternalBaseURI("https://dyorhq.fun/moments/")` on cohort 3 (tx `0x0f181132…2dcd12`)
  and `setPublishingPaused(true)` on cohort 2 (tx `0x5c8e5908…b34ebe`); cohort 1 and v1 were already paused.
- **Verification:** all seven contracts verified on Sourcify; chain read-back PASS (governance, platform, treasury,
  full policy, open, base URI; v1 and cohorts 1–2 paused); runtime code byte-identical to cohort 2 after swapping
  addresses. Smoke test: `test/moments/fork/Relaunch.t.sol` against mainnet, 5/5 — the record, wiring and policy,
  the paused cohorts, and a full lifecycle (10 × $100 + a terminal 28.571428 USDC collect → graduation at exactly
  771.428571 USDC → trade → payouts) that pays only the new wallets; the leaked treasury and the old platform
  wallet cannot withdraw. `test/moments/fork/LiveDeployment.t.sol` runs the same stack end to end (vesting,
  Universal Router, buyback, expiry), 2/2.
- **Not fixable:** cohort-1 and cohort-2 Moments keep platform `0xf4D4…` and treasury `0x5282…` (snapshotted at
  publish). All three factories share `externalBaseURI` `https://dyorhq.fun/moments/` while Moment ids restart at 1,
  so their NFT links collide — owner follow-up: `setExternalBaseURI` on cohorts 1 and 2 to per-cohort bases plus
  read-only web routes.

## 2. Verify on Sourcify — done

```bash
cd contracts && ./script/moments/verify-moments-143.sh
```

No key and no transaction: it uploads source + metadata and Sourcify matches them against the chain.

## 3. The live lifecycle runs through the app, not through scripts

The build plan's order is: Phase 4 security self-review → Phase 5 web app (`app/moments`) verified against a fork →
Phase 6 deploy gates and the curated small-cap validation launch. The validation launch *is* the live lifecycle:

1. A creator (dedicated wallet, via the app) publishes a Moment with a collect price (e.g. $100 on cohort 3; $1
   would take ~1,029 editions to graduate) and a 30-day window.
2. A few collectors (dedicated wallets, via the app, Permit2-signed) collect until the reserve reaches the
   threshold. On cohort 3 that is 771.428571 USDC — e.g. 10 collects of $100 and a terminal one clamped to
   28.571428 USDC; under the cohort-1 $10 policy it was 14 collects at $1: 13 full ones and one clamped to
   0.333334 USDC (§4's figures are that $10 policy). The last collect graduates the Moment on the
   real PoolManager in the same transaction; the app shows the pool, the fixed edition and the vesting schedule.
3. Collectors claim 60% at graduation and the rest at the 30- and 60-day cliffs; the creator claims 20% then
   16% per month; the app's portfolio view drives `claim` / `claimAll`.
4. Trades go through the app's existing v4 swap path (Universal Router + Permit2); the hook takes 1% of the USDC
   leg on top of the pool's 0.5% LP fee. Once ≥ 1 USDC of buyback fees has accrued (~$200 of volume) anyone can
   trigger the buyback from the app; it can only add to the locked position.
5. The platform and treasury wallets pull their USDC when they choose.

No step above involves the owner wallet, a private key in a shell, or an unlimited approval. Total exposure of a
graduated Moment on cohort 3 is the collectors' ≈ $1,028.57 of USDC (≈ $771.43 reserve) plus gas (it was ~$13.34 under the
cohort-1 $10 policy), on contracts that — per spec §14 — should be audited
first; that remains the owner's decision.

`script/moments/Lifecycle.s.sol` is a **fork-only** rehearsal of the same steps for app development against
`anvil --fork-url monad` (guarded by `FORK_REHEARSAL=1`, exact approvals, anvil's throwaway keys). It is not a
mainnet procedure.

## Phase 6 — launch gates

See `docs/moments-launch-gates.md`: gate status (audit and legal sign-offs are the owner's), the curated validation
launch run-of-show, the threshold-raise procedure (`PolicyOps.s.sol`, 48h timelock) and the monitor
(`node scripts/moments-status.mjs`).

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
