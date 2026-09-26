# Keepers for the live contracts

The deployed Launchpad and Moments contracts on Monad (chain 143) are immutable. The v2 source fixes in
`contracts/src` (see `contracts/CHANGELOG-v2.md`) only take effect after a redeploy. Until then, these keepers
contain the audit findings MO-1, MO-2, LP-1 and LP-2 on the **live** contracts. They only call functions that
anyone can already call.

They run from Node (`viem` is already a root dependency), read the deployment records in `contracts/deployments/`,
and send through Foundry's `cast`. Why this setup:

- Node matches the repo's other operational scripts (`scripts/moments-status.mjs`). No build step is needed. The ABIs
  are written out by hand in `lib/abis.mjs` to match the **deployed** bytecode, so no `forge build` is needed either.
- `cast send` handles the signing. Keys stay in a Foundry keystore, a named `~/.foundry/keystores` account, or a
  Ledger. The keepers never read key material. They refuse `--private-key`-style options, and they refuse to start if
  `PRIVATE_KEY` (or a similar variable) is set.

## Jobs

| Job | Finding | Contract call (permissionless, verified in source) | What it does |
|---|---|---|---|
| `moments-graduation` | MO-1 | `MomentGraduation.graduate(uint256)` | Scans every Moments cohort: live cohort 3, retired cohorts 2 and 1, and the v1 record. Every Moment in `GraduationPending` gets an alert, because on the live contracts that state only exists after a graduation failure. The job simulates the retry and sends it. If the retry reverts, the alert is **critical**. Severity also escalates when expiry is less than 24h away, or when the same Moment was seen failing on an earlier run (`--state-file`). With `--logs-lookback N` it also reports `GraduationFailed` events from the last N blocks. |
| `buybacks` | MO-2 | `MomentBuyback.execute(uint256,uint256)` | Runs every due round (graduated, at least `MIN_AMOUNT`, at least `MIN_INTERVAL` since the last run). It simulates first and passes `minCoinOut` = simulated × (1 − `--slippage-bps`). It alerts when a cohort's shared locker holds more than `--locker-idle-alert` USDC units of idle balance, which is the amount a spot-price sandwich could get at. |
| `sweeps` | LP-2 | `MemeHook.sweepPoolFees(bytes32,address)` | For every graduated Uniswap v4 launch, it sweeps quote-asset fees on holder-sharing launches whenever anything is pending, because any backlog can be captured by a one-block holder. Other fees are swept only above `--min-sweep-other`. |
| `launchpad-graduation` | LP-1 | `LaunchpadFactory.graduate(address)`, `graduateFallback(address)` | **Before completion:** for every Monday-venue launch it looks for a pre-created (squatted) Monday pool. It computes the exact graduation price, as the executor would, and counts the initialized ticks the realign swap would have to cross (from the pool's `tickBitmap`). It then alerts: `light` = info, `heavy` = warning, `blocking` = **critical**. **After completion:** it retries stuck launches. It tries `graduate(token)` first, with a 25M gas limit for Monday so the realign can finish on the creator's venue, then `graduateFallback(token)`. If both fail, it raises a critical alert with the time from which the owner can rescue. |

`MomentCollect.expire` is **never** called. Calling it is the harmful outcome MO-1 leads to.

## Running

```sh
# dry run (default): read state, simulate, print the exact `cast send` commands, alert
node contracts/keepers/keeper.mjs all --rpc-url "$MONAD_RPC_URL"

# one job, only the live deployments
node contracts/keepers/keeper.mjs moments-graduation --only-live

# really send (explicit flag + a signer; the keeper's own address pays gas)
node contracts/keepers/keeper.mjs all --send --account dyor-keeper --password-file ~/.keeper-pw \
  --state-file ~/.dyor-keeper/state.json --webhook "$KEEPER_WEBHOOK_URL"
# or: --keystore /path/to/keystore.json [--password-file …]    or: --ledger [--hd-path "m/44'/60'/0'/0/0"]
```

To create a keeper keystore once: `cast wallet new ~/.foundry/keystores dyor-keeper` (or `cast wallet import
dyor-keeper --interactive`). Fund it with a little MON only. It needs no role, allowance or ownership anywhere.

Options: `--rpc-url` (or `MONAD_RPC_URL`), `--sim-from <addr>` (the account used for simulations, `KEEPER_ADDRESS`),
`--state-file` (`KEEPER_STATE_FILE`), `--webhook` (`KEEPER_WEBHOOK_URL`: JSON `{text, alerts}`, which works with
Slack and Discord incoming webhooks), `--deployments <dir>`, `--slippage-bps` (50), `--locker-idle-alert` (50000000 =
$50), `--min-sweep-other`, `--logs-lookback` (0 = off), `--watch-progress-bps` (0 = check squats on every open
Monday launch).

**Exit codes:** `0` means nothing needs a human, `2` means at least one warning or critical alert, and `1` means the
keeper itself failed (for example RPC down). Alert the on-call on both `1` and `2`. Only warning and critical alerts
are posted to the webhook.

## Scheduling

Monad produces a block about every 0.4 s. Graduation retries are cheap and time-critical, and MO-1's clock is 7 days.
Buybacks are rate-limited to one per hour per Moment on-chain.

```cron
# m h dom mon dow   (the keeper's host, UTC)
*/5 * * * *   cd /srv/IOS-app && node contracts/keepers/keeper.mjs moments-graduation launchpad-graduation --send --account dyor-keeper --password-file /srv/keeper/pw --state-file /srv/keeper/state.json --logs-lookback 1000 >> /var/log/dyor-keeper.log 2>&1
*/15 * * * *  cd /srv/IOS-app && node contracts/keepers/keeper.mjs sweeps --send --account dyor-keeper --password-file /srv/keeper/pw >> /var/log/dyor-keeper.log 2>&1
7 * * * *     cd /srv/IOS-app && node contracts/keepers/keeper.mjs buybacks --send --account dyor-keeper --password-file /srv/keeper/pw >> /var/log/dyor-keeper.log 2>&1
```

Wrap each line in the scheduler's failure hook (non-zero exit leads to a page). A systemd timer or a GitHub
Actions/Cloud Scheduler job works the same way, as long as the keystore password is available to it as a file or
secret (never as a key). Run a **dry run** from a second, independent host as a watchdog. With no signer it can
still alert on everything.

## LP-1 manual procedure (a `blocking` squat)

The keeper does not pre-align pools itself. Pre-aligning means trading on the squatted pool with protocol funds, and
that needs a human decision. When a Monday-venue launch gets a `blocking` alert:

1. **Before the curve completes (best):** pre-align the Monday pool to the `graduation target` sqrtPriceX96 printed in
   the alert (`mondayTargetSqrtPriceX96`: the pool at `graduationThreshold` quote vs `reservedTokens`). Because the
   squat is dust liquidity, the trade costs almost nothing. The cost is **gas**: each initialized tick crossed
   costs ~20–25k. So split it into several swaps through Monday's router (`exactInputSingle` with a small
   `amountIn`). Give each swap a `sqrtPriceLimitX96` a few hundred ticks further toward the target, and end
   exactly on the target. Then re-run `keeper.mjs launchpad-graduation`. The pool should now show `none`.
2. **After completion (stuck):** the automatic graduation already failed. Pre-align as in step 1, then run
   `keeper.mjs launchpad-graduation --send`. It retries `graduate(token)` with 25M gas, which lands on Monday.
3. **If nobody can pre-align:** the owner can `rescue(token)` from `stuckSince + 7 days`. That reopens the curve for
   fee-free sells. For aBIL (Monday-only) launches, `allowV4Fallback(token)` needs the owner too.
4. Product mitigations that need no code: make Uniswap v4 the default venue in the UI, and consider unapproving
   Monday-only pairs until the v2 factory is live.

## Tests

```sh
node --test contracts/keepers/test/*.test.mjs        # or: npm run keepers:test
```

`test/decide.test.mjs` covers the pure decision rules. `test/jobs.test.mjs` runs every job against a mocked chain
with a dry-run sender and checks exactly which calls it would send and which alerts it raises. `test/send.test.mjs`
covers signer handling: keystore, account and Ledger only, no raw keys, dry-run never spawns `cast`. None of the tests
touch a network.
