# Deploying the DyorHQ contracts to Monad mainnet

What is live today is listed in `contracts/deployments/*.json`: the Launchpad factory `0x6B1C…` (2026-09-23) and
Moments cohort 3 (`moments-143.json`), plus retired stacks that still hold value. `contracts/src` holds the **v2**
fixes, which are **not deployed** (`contracts/CHANGELOG-v2.md`). The wallet that runs a deploy becomes the owner of
the new Launchpad factory and, until it hands over, the governance of the new Moments factory. Those keys control
every policy knob, so:

- **Sign only with a hardware wallet (`--ledger`) or an encrypted Foundry keystore (`--account <name>`).** Never a
  raw private key, never a key in a `.env` file (security audit 2026-09-26, SEC-1). The scripts refuse
  `PRIVATE_KEY` and similar variables on chain 143, and `script/mainnet.sh` refuses `--private-key`, `--mnemonic` and
  `--interactive` on the command line. `ALLOW_RAW_KEY_143=1` overrides both; do not use it for real funds.
- Prefer a Safe for ownership and governance (`OWNER=` / `GOVERNANCE=` below), and a separate guardian key for Moments.
  Guard it as well as governance: nobody can replace the guardian, so losing its key, or a compromise that lets it
  cancel every policy proposal and pause publishing for good, means deploying a new Moments cohort (existing Moments
  keep working). It cannot renounce while its own pause is on (`UnpauseFirst`); it can hand the role on.

## Prerequisites

- Foundry 1.7+ (`forge --version`), submodules checked out: `git submodule update --init --recursive`
- `LaunchpadFactory` is above Ethereum's 24 KB EIP-170 limit; Monad allows 128 KB, and `foundry.toml` sets
  `code_size_limit` accordingly. Ignore forge's "above the contract size limit" lint.
- MON on Monad mainnet (chain id 143) for gas. Monad charges gas by the **limit** you set, not by what is used, so
  keep `--gas-estimate-multiplier` modest.
- `forge test --code-size-limit 100000000` green from `contracts/` (see `CHANGELOG-v2.md` for the fork suites).

## The v2 deployment: `script/deploy-v2.sh`

```bash
cd contracts
export GOV=0x…            # the signer: your Ledger / keystore address (owner of the new stacks unless OWNER/GOVERNANCE)
export TREASURY=0x…       # launch fees + the protocol share of curve/pool fees; the Moments treasury (expiry share)
export FEES=0x…           # Monday LP swap fees (MondayFeeVault) and the Moments platform share
export GUARDIAN=0x…       # Moments guardian: a different key that can cancel a pending policy and pause publishing
export LAUNCH_FEE_WEI=5000000000000000000   # 5 MON per launch, as on the live stack
export THRESHOLD_USDC=771428571             # Moments graduation threshold ($2,000 FDV, as cohort 3)
# optional: OWNER=0x<Safe> GOVERNANCE=0x<Safe>  (two-step: the Safe calls acceptOwnership() / acceptGovernance())
DRY_RUN=1 script/deploy-v2.sh            # pre-flight, live prices, both simulations; sends nothing
LEDGER=1 script/deploy-v2.sh             # or: ACCOUNT=<keystore name> script/deploy-v2.sh
```

It refuses raw keys, checks chain 143 on two RPCs, the roles (four distinct addresses) and the balance, reads live
MON and aBIL prices from two sources (`relaunch/prices.py`, 2% agreement), then for each stack simulates, asks, and
broadcasts. `Deploy.s.sol` seals the Launchpad modules in the same run (`sealModules()`), so no module can be swapped
before the first launch. Rehearse it first on a fork (`FORK=1`, below).

Records: a dry run writes `deployments/dryrun-143.json` / `dryrun-moments-143.json`; a broadcast on chain 143 writes
`deployments/pending-143.json` / `pending-moments-143.json`. Both kinds are git-ignored. **No script writes
`143.json` or `moments-143.json`**: the keepers and `npm run sync:deployment` trust those files, and a dry run or fork
rehearsal used to overwrite them. After the broadcast:

1. Verify every new contract on Sourcify: `RECORD=deployments/pending-143.json script/verify-143.sh` and
   `RECORD=deployments/pending-moments-143.json script/moments/verify-moments-143.sh`.
2. If `OWNER` / `GOVERNANCE` is a Safe, accept ownership / governance from it.
3. Retire the old stacks: on `0x6B1C…` `setWhitelistEnabled(true)` + `setLaunchConfigEnabled(0, false)`; on cohort 3
   `setPublishingPaused(true)`.
4. Promote the records: `git mv deployments/143.json deployments/143-retired-0x6B1C.json`, then
   `mv deployments/pending-143.json deployments/143.json` (the same for Moments, keeping cohort 3 as
   `moments-143-cohort3.json`), update `LIVE_FACTORIES` and the file lists in `keepers/lib/deployments.mjs`, and commit.
5. Rewire the apps (`npm run sync:deployment`, `python3 scripts/dev/check-launchpad-addresses.py`, the iOS
   constants, `app/lib/moments-deployment.json`) for the v2 ABI changes listed in `CHANGELOG-v2.md`.

Other knobs (optional): `PROTOCOL_FEE_SHARE_BPS` (5000 = half of the 1% base fee), `MAX_CREATOR_TAX_BPS` (1000),
`SUPPLY`, `CURVE_FEE_BPS`, `POOL_FEE_BPS`, `TICK_SPACING`, `POOL_MANAGER`, `EXTERNAL_BASE_URI` (Moments link base,
default `https://dyorhq.fun/moments/`).

## Rehearse on a local fork first

```bash
anvil --fork-url https://rpc3.monad.xyz --no-rate-limit --auto-impersonate --disable-code-size-limit --port 8620   # terminal 1
cd contracts && FORK=1 RPC=http://127.0.0.1:8620 YES=1 GOV=… TREASURY=… FEES=… GUARDIAN=… \
  LAUNCH_FEE_WEI=… THRESHOLD_USDC=… script/deploy-v2.sh
```

`FORK=1` signs with `--unlocked` as `GOV` on the fork and restores `deployments/`, `broadcast/` and `cache/` on
exit. `--disable-code-size-limit` matters: anvil enforces Ethereum's 24 KB limit by default, and `LaunchpadFactory` is
bigger (Monad allows 128 KB). A fork of Monad also
reports chain 143. Use fresh addresses for anything you sign with on a fork: anvil's default accounts carry EIP-7702
code on Monad mainnet.

## Ops on a live factory

Every forge/cast call that can sign goes through `script/mainnet.sh`:

```bash
FACTORY=0x... PAIR_TOKEN=0x... PHANTOM_QUOTE=1000000000 GRADUATION_THRESHOLD=4000000000 \
script/mainnet.sh forge script script/AddPairToken.s.sol:AddPairToken --rpc-url monad --broadcast --ledger
script/mainnet.sh cast send 0x6B1C… 'setWhitelistEnabled(bool)' true --rpc-url https://rpc1.monad.xyz --account owner
```

Moments governance operations are in `script/moments/PolicyOps.s.sol` (propose/apply/cancel a policy, pause, the link
base; on v2 factories also the guardian's pause).

A stuck Monday launch retried by hand (`graduate` or `graduateFallback`, which anyone may call) needs
`--gas-limit 29900000`: with an estimated limit a squat that more gas would realign moves to Uniswap v4
(`contracts/keepers/README.md`, LP-1).

## Verify

Contracts are verified on Sourcify (`script/verify-143.sh`, `script/moments/verify-moments-143.sh`; Monad's instance
is https://sourcify-api-monad.blockvision.org). `forge verify-contract --verifier sourcify` also works per contract;
constructor arguments are in `broadcast/<script>/143/run-latest.json`.

## Retired scripts

`relaunch/relaunch-new-wallets.sh` (the 2026-09-23 relaunch) and `relaunch/rehearse.sh`, `moments/redeploy-cohort2.sh`
and `DeployFeeVault.s.sol` exit at once. They are kept for the record.
