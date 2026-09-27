#!/usr/bin/env bash
# Deploys the v2 contracts (contracts/CHANGELOG-v2.md) on Monad mainnet: a new Launchpad stack and a new Moments cohort.
# Security audit 2026-09-26: it signs only on a Ledger (LEDGER=1) or with an encrypted Foundry keystore (ACCOUNT=name),
# never with a raw key (SEC-1); every money role and price is explicit (LP-7); and it never writes a live deployment
# record (RO-7): the new records land in deployments/pending-*.json and are promoted by hand after verification.
#
#   cd contracts
#   GOV=0x… TREASURY=0x… FEES=0x… GUARDIAN=0x… LAUNCH_FEE_WEI=… THRESHOLD_USDC=… LEDGER=1 script/deploy-v2.sh
#
#   GOV            the signer (the owner's hardware wallet / keystore address); owner of the new stacks unless:
#   OWNER          launchpad owner to hand over to (e.g. a Safe; it must call acceptOwnership())       [default GOV]
#   GOVERNANCE     Moments governance to hand over to (a Safe; it must call acceptGovernance())         [default GOV]
#   TREASURY       launchpad protocol fees + Moments treasury (expiry share)                             [required]
#   FEES           Monday LP fees (launchpad) + Moments platform share                                   [required]
#   GUARDIAN       Moments guardian: can cancel a pending policy and pause publishing (a different key)  [required]
#   LAUNCH_FEE_WEI launch fee in wei (the live stack charges 5 MON = 5000000000000000000)                  [required]
#   THRESHOLD_USDC Moments graduation threshold in USDC units (cohort 3: 771428571)                        [required]
#   LEDGER=1 | ACCOUNT=<keystore name>   how to sign (exactly one)
#   DRY_RUN=1      pre-flight, live prices and both simulations; sends nothing (no signer needed)
#   FORK=1         rehearsal on a local anvil fork (RPC=http://127.0.0.1:<port>, started with --auto-impersonate and
#                  --disable-code-size-limit, since LaunchpadFactory is above Ethereum's 24 KB limit);
#                  signs with --unlocked as GOV; every file the run writes is restored on exit
#   ONLY=launchpad | moments   deploy one stack only
#   YES=1          no confirmation prompts
#
# Steps, stopping at the first failure: 0. pre-flight (no raw key anywhere, chain 143 on two RPCs, roles distinct,
# balance) · 1. live MON/aBIL prices from two sources (script/relaunch/prices.py) · 2. launchpad: simulate, confirm,
# broadcast (the modules are sealed in the same run) · 3. Moments: simulate, confirm, broadcast · 4. the follow-ups.
set -euo pipefail
umask 077
# forge/cast honour FOUNDRY_* (compiler config), ETH_* (sender, keystore, rpc), CAST_* and DAPP_*: none may leak in.
for v in $(env | grep -oE '^(FOUNDRY|DAPP|ETH|CAST)_[A-Za-z0-9_]*=' || true); do unset "${v%=}"; done

cd "$(dirname "$0")/.." # contracts/
FORGE=~/.foundry/bin/forge
CAST=~/.foundry/bin/cast
RPC=${RPC:-https://rpc3.monad.xyz}
REFERENCE_RPC=https://rpc1.monad.xyz
MIN_BALANCE_MON=${MIN_BALANCE_MON:-15}
SNAP=$(mktemp -d)
cp -R deployments "$SNAP/deployments"
for d in broadcast cache; do if [ -d "$d" ]; then cp -R "$d" "$SNAP/$d"; fi; done
cleanup() {
  # FORK rehearsals leave nothing behind (records, broadcast logs, script caches); a real run keeps its
  # pending-*.json records and broadcast logs.
  if [ "${FORK:-0}" = 1 ]; then
    rm -rf deployments && cp -R "$SNAP/deployments" deployments
    for d in broadcast cache; do
      rm -rf "$d"
      if [ -d "$SNAP/$d" ]; then cp -R "$SNAP/$d" "$d"; fi
    done
  fi
  rm -rf "$SNAP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

say() { printf '%s\n' "$*"; }
bold() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }
confirm() { [ "${YES:-0}" = 1 ] && return 0; local a; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || die "stopped: nothing further was sent"; }
lc() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
need() { [ -n "${!1:-}" ] || die "$1 must be set (see the header of this script)"; }
isaddr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "$2 is not an address: $1"; }

# ---------------------------------------------------------------- 0. pre-flight
bold "0. pre-flight"
for v in PRIVATE_KEY TREASURY_KEY OWNER_KEY DEPLOYER_PRIVATE_KEY ETH_PRIVATE_KEY; do
  [ -z "${!v:-}" ] || die "$v is set: unset it. This script signs only with LEDGER=1 or ACCOUNT=<keystore> (SEC-1)."
done
for v in GOV TREASURY FEES GUARDIAN LAUNCH_FEE_WEI THRESHOLD_USDC; do need "$v"; done
OWNER=${OWNER:-$GOV}
GOVERNANCE=${GOVERNANCE:-$GOV}
for v in GOV OWNER GOVERNANCE TREASURY FEES GUARDIAN; do isaddr "${!v}" "$v"; done
[[ "$LAUNCH_FEE_WEI" =~ ^[0-9]+$ && "$THRESHOLD_USDC" =~ ^[0-9]+$ ]] || die "LAUNCH_FEE_WEI and THRESHOLD_USDC must be integers"
roles=$(printf '%s\n' "$(lc "$GOV")" "$(lc "$TREASURY")" "$(lc "$FEES")" "$(lc "$GUARDIAN")")
[ "$(printf '%s\n' "$roles" | sort -u | wc -l | tr -d ' ')" = 4 ] || die "GOV, TREASURY, FEES and GUARDIAN must be four different addresses"
for r in "$OWNER" "$GOVERNANCE"; do
  for x in "$TREASURY" "$FEES" "$GUARDIAN"; do [ "$(lc "$r")" != "$(lc "$x")" ] || die "OWNER/GOVERNANCE must not be a money role or the guardian"; done
done

SIGN=()
if [ "${DRY_RUN:-0}" = 1 ]; then
  MODE=dry
elif [ "${FORK:-0}" = 1 ]; then
  case "$RPC" in http://127.0.0.1:* | http://localhost:*) ;; *) die "FORK=1 needs RPC=http://127.0.0.1:<port> (a local anvil fork), got $RPC" ;; esac
  MODE=fork
  SIGN=(--unlocked)
elif [ "${LEDGER:-0}" = 1 ] && [ -z "${ACCOUNT:-}" ]; then
  MODE=ledger
  SIGN=(--ledger)
elif [ -n "${ACCOUNT:-}" ] && [ "${LEDGER:-0}" != 1 ]; then
  MODE=account
  SIGN=(--account "$ACCOUNT")
else
  die "choose exactly one signer: LEDGER=1 or ACCOUNT=<keystore name> (or DRY_RUN=1 / FORK=1)"
fi
say "mode: $MODE   signer: $GOV   rpc: ${RPC%%\?*}"

CHAIN=$($CAST chain-id --rpc-url "$RPC") || die "cannot reach the RPC"
[ "$CHAIN" = 143 ] || die "the RPC is chain $CHAIN, not Monad mainnet (143)"
if [ "$MODE" != fork ]; then
  REF=$($CAST chain-id --rpc-url "$REFERENCE_RPC") || die "cannot reach $REFERENCE_RPC"
  [ "$REF" = 143 ] || die "$REFERENCE_RPC is chain $REF"
fi
BAL=$($CAST balance "$GOV" --rpc-url "$RPC" --ether | cut -d. -f1)
[ "$BAL" -ge "$MIN_BALANCE_MON" ] || [ "$MODE" = dry ] || die "$GOV holds $BAL MON; the two deployments need about $MIN_BALANCE_MON"
say "chain 143 · $GOV holds ~$BAL MON"

# ---------------------------------------------------------------- 1. prices
if [ "${ONLY:-}" != moments ]; then
  bold "1. live prices"
  PRICES=$(python3 script/relaunch/prices.py "$RPC") || die "prices unavailable, or the two sources disagree: nothing was sent"
  MON_USD_E8=$(printf '%s' "$PRICES" | tail -1 | sed -E 's/.*MON_USD_E8=([0-9]+).*/\1/')
  ABIL_USD_E8=$(printf '%s' "$PRICES" | tail -1 | sed -E 's/.*ABIL_USD_E8=([0-9]+).*/\1/')
  [[ "$MON_USD_E8" =~ ^[0-9]+$ && "$ABIL_USD_E8" =~ ^[0-9]+$ ]] || die "could not parse the prices"
  say "MON_USD_E8=$MON_USD_E8 ABIL_USD_E8=$ABIL_USD_E8 (Deploy.s.sol also refuses prices outside its sanity band)"
fi

run_script() { # <label> <target> <env...> -- simulate, confirm, broadcast
  local label=$1 target=$2
  shift 2
  bold "$label: simulation"
  env "$@" "$FORGE" script "$target" --rpc-url "$RPC" --code-size-limit 200000 --sender "$GOV" || die "$label: the simulation failed; nothing was sent"
  [ "$MODE" = dry ] && return 0
  confirm "$label: broadcast these transactions as $GOV?"
  bold "$label: broadcast"
  env "$@" "$FORGE" script "$target" --rpc-url "$RPC" --code-size-limit 200000 --sender "$GOV" --broadcast --slow --non-interactive "${SIGN[@]}" \
    || die "$label: the broadcast did not complete. Do NOT start over: finish it with the same command plus --resume."
}

# ---------------------------------------------------------------- 2. launchpad
if [ "${ONLY:-}" != moments ]; then
  run_script "2. launchpad" script/Deploy.s.sol:Deploy \
    PROTOCOL_FEE_RECIPIENT="$TREASURY" FEES="$FEES" OWNER="$OWNER" LAUNCH_FEE_WEI="$LAUNCH_FEE_WEI" \
    MON_USD_E8="$MON_USD_E8" ABIL_USD_E8="$ABIL_USD_E8"
fi

# ---------------------------------------------------------------- 3. Moments
if [ "${ONLY:-}" != launchpad ]; then
  run_script "3. Moments" script/moments/Deploy.s.sol:DeployMoments \
    GOVERNANCE="$GOVERNANCE" GUARDIAN="$GUARDIAN" PLATFORM="$FEES" TREASURY="$TREASURY" THRESHOLD_USDC="$THRESHOLD_USDC"
fi

# ---------------------------------------------------------------- the live records were not touched
for f in "$SNAP"/deployments/*.json; do
  cmp -s "$f" "deployments/$(basename "$f")" || die "deployments/$(basename "$f") changed during the run: restore it from git before anything reads it"
done

bold "4. next (script/README.md, 'v2 deployment')"
if [ "$MODE" = dry ]; then
  say "dry run: nothing was sent. Simulated records: deployments/dryrun-143.json, deployments/dryrun-moments-143.json"
else
  say "records: deployments/pending-143.json, deployments/pending-moments-143.json (not yet read by anything)"
  say "- verify every new contract on Sourcify: RECORD=deployments/pending-143.json script/verify-143.sh (and the Moments one)"
  say "- if OWNER/GOVERNANCE is a Safe: acceptOwnership() on the factory, acceptGovernance() on the Moments factory"
  say "- close the old launchpad 0x6B1C… to launches, pause publishing on cohort 3, then promote the pending records"
  say "  (keep the old ones as 143-retired-0x6B1C.json / moments-143-cohort3.json) and update keepers/lib/deployments.mjs"
fi
