# Launchpad: new treasury and fee wallets (2026-09-17)

Why: the private key of the treasury wallet `0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045` was printed into a
Claude Code session log on 2026-09-17, so the owner rotated the money roles. New wallets (from the local `.env`,
public addresses only):

| Role | Env | New address |
| --- | --- | --- |
| Treasury (launch fees + protocol share of curve fees) | `TREASURY` → `PROTOCOL_FEE_RECIPIENT` | `0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371` |
| Monday LP swap-fee recipient (`MondayFeeVault.lpFeeRecipient`) | `FEES` | `0x15ED3bb488231213b141A2f78b62358D52235Cd7` |

Owner stays `0xCf7A9f1DE835a691f969B76e6eb4842BFaA7Fe10`. The three roles are distinct (the deploy script requires it).

**Do first, whichever path you choose:** move the 0.254 MON left in `0x5282…` to the new treasury and never use
that key again. Nothing else sits there (USDC 0, escrow claimable 0) and no launch has happened on the current
factory, so no fees have gone to it yet.

## Path A — repoint the live deployment (two owner transactions, no redeploy)

Both addresses are owner-settable on the audited deployment (`0x10F3…`): `LaunchpadFactory.setFeePolicy` and
`MondayFeeVault.setLpFeeRecipient`. The factory has zero launches, so nothing is pinned to the old treasury.
Rehearsed on an anvil fork of mainnet on 2026-09-17 (owner impersonated): both succeed, 30,972 + 29,914 gas,
and the read-backs equal the new addresses.

```bash
RPC=https://rpc3.monad.xyz
cast send 0x10F34A174d9C393a90aFf94BDED7E1Db185446D7 "setFeePolicy(address,uint16)" 0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371 5000 --rpc-url $RPC --private-key $OWNER_KEY
cast send 0x42a1C1c1d6BC2544d3f478E4d42F5b5ec75888De "setLpFeeRecipient(address)" 0x15ED3bb488231213b141A2f78b62358D52235Cd7 --rpc-url $RPC --private-key $OWNER_KEY
cast call 0x10F34A174d9C393a90aFf94BDED7E1Db185446D7 "protocolFeeRecipient()(address)" --rpc-url $RPC   # → 0x5aDb…
cast call 0x42a1C1c1d6BC2544d3f478E4d42F5b5ec75888De "lpFeeRecipient()(address)" --rpc-url $RPC        # → 0x15ED…
```

Then record it (the deployment file mirrors chain state) and commit:

```bash
python3 - <<'PY'
import json; p='contracts/deployments/143.json'; d=json.load(open(p))
d['treasury']='0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371'; d['feesRecipient']='0x15ED3bb488231213b141A2f78b62358D52235Cd7'
json.dump(d, open(p,'w'), indent=2); open(p,'a').write('\n')
PY
```

Keeps: the Sourcify-verified contracts, the audit's fork smoke test, both apps' wiring, ~6 MON of gas. This is the
recommended path unless you also want a fresh owner nonce history or new module addresses.

## Path B — full redeploy (what you asked for; prepared and simulated)

Simulated on 2026-09-17 against live mainnet state from the owner (no broadcast):

- Inputs: `PROTOCOL_FEE_RECIPIENT=0x5aDb…`, `FEES=0x15ED…`, `LAUNCH_FEE_WEI=5000000000000000000`,
  `MON_USD_E8=2259579` (CoinGecko $0.02259579), `ABIL_USD_E8=9158765833` (Monday aBIL/USDC 0.3% pool
  `0xb8700E…7898`, $91.5877 — unchanged since the 16th). Everything else at the script's defaults ($2,000 launch FDV,
  supply 1e9, 1%/1% fees, tick 60, snipe schedule 98/25/3/0.3%).
- Result: SIMULATION COMPLETE, 29,158,069 gas, 5.89 MON at 202 gwei. The `Unknown0 … > 24576` line at the end is
  forge's size lint; Monad's limit is 128 KB.
- Addresses it will produce if the owner's nonce has not moved (CREATE): factory `0x235A430952424d37E400a10b9bb1F2Da14F85A47`,
  hook `0xaeFA248f810baCa027F00D629a5eb4Af91B0e0Cc`, v4 executor `0x353F245A2458B994a65116A4c69643cf6608045b`,
  Monday executor `0x0c60e132A38B9Af3c843178062B9bF55D3b6c363`, router `0xD9d3Cad36BaA5ebc0e7F6f06d1D09E1220dbb2ca`,
  fee vault `0xacae95377513C54DA9ff549DFE5cB77001F6c6F5`. Any owner transaction before the broadcast shifts them.

Run from `contracts/` (dry run first, then broadcast; refresh the two prices right before):

```bash
export PROTOCOL_FEE_RECIPIENT=0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371
export FEES=0x15ED3bb488231213b141A2f78b62358D52235Cd7
export LAUNCH_FEE_WEI=5000000000000000000
export MON_USD_E8=2259579
export ABIL_USD_E8=9158765833
forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc3.monad.xyz --sender 0xCf7A9f1DE835a691f969B76e6eb4842BFaA7Fe10
forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc3.monad.xyz --broadcast --private-key $OWNER_KEY
```

After the broadcast, in order:

1. `contracts/script/verify-143.sh` (Sourcify, `v4core` profile) — all 11 contracts plus CurveDeployer.
2. From the repo root: `npm run sync:deployment` (web record + the iOS constant) and
   `python3 scripts/dev/check-launchpad-addresses.py`; `cd ios/DyorKit && swift test --filter LaunchpadDeploymentTests`.
3. Commit `contracts/deployments/143.json`, `app/lib/deployment.json`, `ios/DyorKit/.../LaunchpadModels.swift`.
4. Retire `0x10F3…`: `setWhitelistEnabled(true)` and `setLaunchConfigEnabled(0, false)` from the owner.
5. Rebuild and ship both apps (`vinext deploy`; iOS archive). Fork smoke test: `contracts/test/audit/Z_LiveDeployment.t.sol`
   with the new addresses.

## Web hosting

`app/lib/chain.ts` now treats `app/lib/deployment.json` as the source of truth; `NEXT_PUBLIC_LAUNCHPAD_*` only
apply with `NEXT_PUBLIC_LAUNCHPAD_OVERRIDE=1` (fork rehearsals). So the next `vinext deploy` fixes production even if
the hosting environment still carries old values — you can delete those variables at leisure.
