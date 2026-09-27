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
| `buybacks` | MO-2 | `MomentBuyback.execute(uint256,uint256)` | Runs every due round (graduated, at least `MIN_AMOUNT`, at least `MIN_INTERVAL` since the last run). It simulates first and passes `minCoinOut` = simulated × (1 − `--slippage-bps`). It alerts when a cohort's shared locker holds more than `--locker-idle-alert` USDC units of idle balance, which is the amount a spot-price sandwich could get at. On a v2 locker, which adds at most 0.5% of a position per round and keeps the rest for that Moment, the alert is per Moment (`heldOf`), so routine remainders in the shared locker do not page. |
| `sweeps` | LP-2 | `MemeHook.sweepPoolFees(bytes32,address)` | For every graduated Uniswap v4 launch, it sweeps quote-asset fees on holder-sharing launches once the backlog is worth the sweep (native MON: twice the sweep's gas cost; an ERC-20: 0.01 token), because a backlog can be captured by a one-block holder but a dust backlog is not worth capturing, and sweeping dust on every run would drain the keeper's gas. Other fees are swept only above `--min-sweep-other`. On a v2 hook the protocol's cut (`pendingProtocolFees`) counts too. |
| `launchpad-graduation` | LP-1 | `LaunchpadFactory.graduate(address)`, `graduateFallback(address)` | **Before completion:** for every Monday-venue launch it looks for a pre-created (squatted) Monday pool. It computes the exact graduation price, as the executor would, and counts the initialized ticks the realign swap would have to cross (from the pool's `tickBitmap`, at ~30k gas each). It then alerts: `light` = info, `heavy` = warning, `blocking` = warning, or **critical** on a Monday-only pair (aBIL), where only the owner can unblock it. **After completion:** it retries stuck launches. It tries `graduate(token)` first, with a 25M gas limit for Monday so the realign can finish on the creator's venue, then `graduateFallback(token)` with 25M. If both fail, it raises a critical alert with the time from which the owner can rescue, naming `allowV4Fallback` for a Monday-only pair. |
| `governance` | SEC-1 | none (read-only) | Compares every launchpad factory's modules, owner, pending owner and protocol fee recipient, every Monday fee vault's owner and LP fee recipient, and every Moments factory's governance, pending governance and pending policy with the deployment records: any drift is **critical**. A launchpad with no launch whose modules are not sealed (the live `0x6B1C…` today) is a warning once a day: until its first launch the owner key can still swap any module. A retired Moments cohort that publishes again is critical. With `--logs-lookback N` it reports every governance event (ModulesSet, MondayExecutorSet, FeePolicySet, OwnershipTransferStarted, LpFeeRecipientSet, CreatorFeeRecipientChangeProposed, V4FallbackAllowed, LaunchRescued, PolicyProposed, PolicyApplied, GuardianPaused, …; the list is `LAUNCHPAD_GOV_EVENTS` / `MOMENTS_GOV_EVENTS` in `lib/jobs.mjs`) of the last N blocks as critical. A creator-fee takeover proposal names the token, the new recipient and the window in which anyone can execute it: warn that creator, who can cancel it until then. |

`MomentCollect.expire` is **never** called. Calling it is the harmful outcome MO-1 leads to.

## Running

```sh
# dry run (default): read state, simulate, print the exact `cast send` commands, alert
node contracts/keepers/keeper.mjs all

# one job, only the live deployments
node contracts/keepers/keeper.mjs moments-graduation --only-live

# really send (explicit flag + a signer; the keeper's own address pays gas)
node contracts/keepers/keeper.mjs all --send --account dyor-keeper --password-file ~/.keeper-pw \
  --state-file ~/.dyor-keeper/state.json --webhook "$KEEPER_WEBHOOK_URL"
# or: --keystore /path/to/keystore.json [--password-file …]    or: --ledger [--hd-path "m/44'/60'/0'/0/0"]
```

To create a keeper keystore once: `cast wallet new ~/.foundry/keystores dyor-keeper` (or `cast wallet import
dyor-keeper --interactive`). Fund it with a little MON only. It needs no role, allowance or ownership anywhere. Give
each scheduled job its **own** keeper account (below), so a drained or stuck sweeps wallet can never stop graduation
retries.

Options: `--rpc-url` (or `MONAD_RPC_URL`; default `https://rpc3.monad.xyz`, which served every read of a full run;
`https://rpc1.monad.xyz` rate-limited a full run after ~20 reads on 2026-09-27, and `https://rpc.monad.xyz` caps
`eth_getLogs` at 100 blocks, which the scans adapt to), `--sim-from <addr>` (the keeper's own
address, used for simulations and the balance check, `KEEPER_ADDRESS`), `--min-balance` (2 MON: warn below it),
`--state-file` (`KEEPER_STATE_FILE`), `--webhook` (`KEEPER_WEBHOOK_URL`: JSON `{text, alerts}`, which works with
Slack and Discord incoming webhooks), `--deployments <dir>`, `--slippage-bps` (50), `--locker-idle-alert` (50000000 =
$50), `--min-sweep-other`, `--logs-lookback` (0 = off), `--logs-chunk` (100 blocks per `eth_getLogs`; halves itself on
a range error), `--watch-progress-bps` (0 = check squats on every open Monday launch).

**Records.** `143.json` and `moments-143.json` are required: if either is missing, unreadable or not for chain 143 the
keeper exits 1 instead of silently skipping the live stacks, and a live record whose factory differs from the pin in
`lib/deployments.mjs` is a critical alert. The retired launchpads `0x10F3`, `0x2F02` and `0xad3d` and every retired
Moments cohort are covered too; `0xad3d` is a legacy factory (16-field launch record, its Monday executor in the
`graduationExecutor` slot, no fallback), marked `legacyRecord` in its record.

**Secrets.** The keeper never prints, logs or posts an RPC or webhook URL beyond its origin (an API key in the path or
query is dropped), and hands the RPC URL to `cast` through `ETH_RPC_URL`, not the command line (`ps`).

**Gas.** Monad bills the gas limit. Sends use the node's estimate × 1.2, capped at each job's old fixed limit; the
Monday graduation and the fallback keep 25M on purpose (the realign must get as much gas as one transaction allows,
and the v2 `graduateFallback` needs ~22.1M).

**Exit codes:** `0` means nothing needs a human, `2` means at least one warning or critical alert, and `1` means the
keeper itself failed (for example RPC down). Alert the on-call on both `1` and `2`. Only warning and critical alerts
are posted to the webhook.

## Scheduling

Monad produces a block about every 0.4 s. Graduation retries are cheap and time-critical, and MO-1's clock is 7 days.
Buybacks are rate-limited to one per hour per Moment on-chain.

```cron
# m h dom mon dow   (the keeper's host, UTC). One account and one lock per job: two runs never send from the same
# account at once (nonce collisions), and an overlapping run of the same job waits instead of double-sending.
*/5 * * * *   cd /srv/IOS-app && flock -n /run/dyor-keeper-grad.lock node contracts/keepers/keeper.mjs moments-graduation launchpad-graduation --send --account dyor-keeper-grad --password-file /srv/keeper/pw-grad --sim-from 0x<grad keeper> --state-file /srv/keeper/state-grad.json --logs-lookback 1000 >> /var/log/dyor-keeper.log 2>&1
*/15 * * * *  cd /srv/IOS-app && flock -n /run/dyor-keeper-sweeps.lock node contracts/keepers/keeper.mjs sweeps --send --account dyor-keeper-sweeps --password-file /srv/keeper/pw-sweeps --sim-from 0x<sweeps keeper> >> /var/log/dyor-keeper.log 2>&1
7 * * * *     cd /srv/IOS-app && flock -n /run/dyor-keeper-buybacks.lock node contracts/keepers/keeper.mjs buybacks --send --account dyor-keeper-buybacks --password-file /srv/keeper/pw-buybacks --sim-from 0x<buybacks keeper> >> /var/log/dyor-keeper.log 2>&1
17 * * * *    cd /srv/IOS-app && flock -n /run/dyor-keeper-gov.lock node contracts/keepers/keeper.mjs governance --state-file /srv/keeper/state-gov.json --logs-lookback 10000 >> /var/log/dyor-keeper.log 2>&1
```

Wrap each line in the scheduler's failure hook (non-zero exit leads to a page). The governance watch sends nothing
and needs no signer; 10,000 blocks is about an hour of Monad blocks, so the hourly run covers every event. A systemd timer or a GitHub
Actions/Cloud Scheduler job works the same way, as long as the keystore password is available to it as a file or
secret (never as a key). Run a **dry run** from a second, independent host as a watchdog. With no signer it can
still alert on everything.

## LP-1 manual procedure (a `blocking` squat)

On an ordinary pair a `blocking` squat needs no manual step: the live `graduateFallback` with enough gas (it works
from ~12–16M; the keeper sends 25M) graduates the launch on Uniswap v4 as soon as it completes, because the out-of-gas
happens frames below it and each reverted frame hands back the 1/64 it kept (`test/sec2/Sec2LiveV1.t.sol`). The
creator's Monday venue is lost, but nobody is locked in. The procedure below matters for a **Monday-only** pair
(aBIL), whose fallback needs the owner, or to keep the creator's Monday venue.

The keeper does not pre-align pools itself. Pre-aligning means trading on the squatted pool with protocol funds, and
that needs a human decision. Note that a pre-alignment can be undone: the crossed dust ticks stay initialized, so the
squatter can push the price back across them for the same gas. The robust answers are a high-gas `graduate` right
after completion (the keeper's 25M), the owner's `allowV4Fallback` / rescue, or the v2 contracts (a Monday-only launch
falls back publicly after one day stuck). When a Monday-venue launch gets a `blocking` alert:

1. **Before the curve completes (best):** pre-align the Monday pool to the `graduation target` sqrtPriceX96 printed in
   the alert (`mondayTargetSqrtPriceX96`: the pool at `graduationThreshold` quote vs `reservedTokens`). Because the
   squat is dust liquidity, the trade costs almost nothing. The cost is **gas**: each initialized tick crossed
   costs ~29k (measured on Monday Trade under Monad's gas schedule). So split it into several swaps through Monday's router (`exactInputSingle` with a small
   `amountIn`). Give each swap a `sqrtPriceLimitX96` a few hundred ticks further toward the target, and end
   exactly on the target. Then re-run `keeper.mjs launchpad-graduation`. The pool should now show `none`.
2. **After completion (stuck):** the automatic graduation already failed. Pre-align as in step 1, then run
   `keeper.mjs launchpad-graduation --send`. It retries `graduate(token)` with 25M gas, which lands on Monday.
3. **Monday-only pair (aBIL), or nobody can pre-align:** the owner calls `allowV4Fallback(token)` (the keeper then
   sends the fallback), or `rescue(token)` from `stuckSince + 7 days`, which reopens the curve for fee-free sells.
   Treat a stuck Monday-only launch as an owner page: holders cannot sell until one of these happens.
4. Product mitigations that need no code: make Uniswap v4 the default venue in the UI, and consider unapproving
   Monday-only pairs until the v2 factory is live.

## Tests

```sh
node --test contracts/keepers/test/*.test.mjs        # or: npm run keepers:test
```

`test/decide.test.mjs` covers the pure decision rules. `test/jobs.test.mjs` runs every job against a mocked chain
with a dry-run sender and checks exactly which calls it would send and which alerts it raises, including the
2026-09-26 ops-audit cases (a capped `eth_getLogs`, a failing read, dust sweeps, the legacy record, the governance
watch, missing or replaced records). `test/send.test.mjs` covers signer handling (named accounts and Ledger only, no
raw keys, dry-run never spawns `cast`) and that no URL with a key is ever printed or passed on the command line. None
of the tests touch a network; `test/abis.test.mjs` compares the ABIs with `forge build` artifacts when they exist.
