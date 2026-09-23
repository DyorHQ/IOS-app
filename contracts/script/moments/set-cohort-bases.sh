#!/usr/bin/env bash
# Gives each retired Moments cohort its own NFT link base, so old NFTs stop linking to cohort-3 pages.
#
# Every cohort's MomentNFT reads `<factory.externalBaseURI()><momentId>` LIVE for its `external_url`, and cohorts 1, 2
# and 3 all use https://dyorhq.fun/moments/ while Moment ids restart at 1 per factory — so cohort-1 #2 (graduated, real
# holders) and cohort-2 #1–2 would link to cohort 3's Moments of the same number once cohort 3 publishes. This sets
#   cohort 1 (0x6469…C020) → https://dyorhq.fun/moments/c1/
#   cohort 2 (0xc12B…a581) → https://dyorhq.fun/moments/c2/
# and leaves cohort 3 on https://dyorhq.fun/moments/. Metadata only: `setExternalBaseURI` touches no money path.
# Marketplaces cache metadata — use their "refresh metadata" button afterwards if an old link still shows.
#
#   cd /Users/jerry/Hackathon-moments/contracts && ./script/moments/set-cohort-bases.sh
#
#   DRY_RUN=1   checks + the two calls it WOULD send; sends nothing
#   LEDGER=1    sign on a Ledger instead of PRIVATE_KEY
#   YES=1       no confirmation prompt
#   FORK=1      rehearsal against a local anvil fork (RPC=http://127.0.0.1:8545); signs with --unlocked as governance
#
# The governance key comes from PRIVATE_KEY in the environment, else ~/Hackathon/.env; it is handed to cast as
# --private-key and never printed or logged (all tool output is scrubbed of it). Re-running is safe: a cohort already
# on its base is skipped.
set -euo pipefail
umask 077
for v in $(env | grep -oE '^(FOUNDRY|DAPP|ETH|CAST)_[A-Za-z0-9_]*=' || true); do unset "${v%=}"; done

CAST=~/.foundry/bin/cast
RPC=${RPC:-https://rpc.monad.xyz}
REFERENCE_RPC=https://rpc1.monad.xyz
GOV=0xCf7A9f1DE835a691f969B76e6eb4842BFaA7Fe10
COHORT1=0x64698c7702d85F87f43a6dFF7D495CDD2327C020
COHORT2=0xc12B6b6948185cef75F861c5327702c30CB8a581
COHORT3=0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26
BASE1=https://dyorhq.fun/moments/c1/
BASE2=https://dyorhq.fun/moments/c2/
BASE3=https://dyorhq.fun/moments/

say() { printf '%s\n' "$*"; }
die() { printf '\n\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }
confirm() { [ "${YES:-0}" = 1 ] && return 0; local a; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || die "stopped — nothing was sent"; }
lc() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
eq() { [ "$(lc "$1")" = "$(lc "$2")" ]; }
call() { $CAST call "$@" --rpc-url "$RPC" 2>/dev/null; }
scrub() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "${PK:-}" ]; then line=${line//$PK/[redacted]}; line=${line//${PK#0x}/[redacted]}; fi
    printf '%s\n' "$line"
  done
}
rcpt() { python3 -c "import json,sys; raw=sys.stdin.read(); print(json.loads(raw[raw.index('{'):]).get(sys.argv[1]))" "$1" 2>/dev/null || echo "?"; }

# ---------------------------------------------------------------- signer (never printed)
MODE=key; CAST_SIGN=()
if [ "${DRY_RUN:-0}" = 1 ]; then MODE=dry; ADDR=$GOV
elif [ "${FORK:-0}" = 1 ]; then
  case "$RPC" in http://127.0.0.1:*|http://localhost:*) ;; *) die "FORK=1 needs RPC=http://127.0.0.1:<port>" ;; esac
  MODE=fork; ADDR=$GOV; CAST_SIGN=(--unlocked --from "$GOV")
elif [ "${LEDGER:-0}" = 1 ]; then MODE=ledger; ADDR=$GOV; CAST_SIGN=(--ledger --from "$GOV")
else
  PK=${PRIVATE_KEY:-}
  if [ -z "$PK" ] && [ -f /Users/jerry/Hackathon/.env ]; then PK=$(grep -m1 '^PRIVATE_KEY=' /Users/jerry/Hackathon/.env | cut -d= -f2- | tr -d "\"' \r"); fi
  [ -n "$PK" ] || die "PRIVATE_KEY is not set and is not in ~/Hackathon/.env (or run with LEDGER=1)"
  case "$PK" in 0x*) ;; *) PK=0x$PK ;; esac
  ADDR=$($CAST wallet address --private-key "$PK" 2>/dev/null) || die "PRIVATE_KEY is not a valid key"
  CAST_SIGN=(--private-key "$PK")
fi
say "mode: $MODE   signer: $ADDR   rpc: $RPC"
eq "$ADDR" "$GOV" || die "the signer $ADDR is not the governance wallet $GOV"

# ---------------------------------------------------------------- pre-flight (read-only)
[ "$($CAST chain-id --rpc-url "$RPC")" = 143 ] || die "$RPC is not Monad mainnet (143)"
if [ "$MODE" = key ] || [ "$MODE" = ledger ]; then
  case "$RPC" in *127.0.0.1*|*localhost*|*0.0.0.0*) die "refusing to sign for real against a local RPC ($RPC)" ;; esac
  B=$(( $($CAST block-number --rpc-url "$RPC") - 20 ))
  [ "$($CAST block "$B" --field hash --rpc-url "$RPC")" = "$($CAST block "$B" --field hash --rpc-url "$REFERENCE_RPC")" ] \
    || die "$RPC and $REFERENCE_RPC disagree on block $B — not mainnet, or a lagging node; retry"
fi
for f in "$COHORT1" "$COHORT2" "$COHORT3"; do eq "$(call "$f" 'governance()(address)')" "$GOV" || die "$f is not governed by $GOV"; done
[ "$(call "$COHORT3" 'externalBaseURI()(string)')" = "\"$BASE3\"" ] || die "cohort 3's base is not $BASE3 — stopping rather than guessing"
say "cohort 3 Moments published so far: $(call "$COHORT3" 'momentCount()(uint256)' | awk '{print $1}') (its base stays $BASE3)"

# ---------------------------------------------------------------- the two calls
SENT=0
set_base() {  # <factory> <base> <label>
  local f=$1 base=$2 label=$3 cur out status hash
  cur=$(call "$f" 'externalBaseURI()(string)')
  if [ "$cur" = "\"$base\"" ]; then say "   $label ($f) already → $base"; return 0; fi
  if [ "$MODE" = dry ]; then say "   would send: setExternalBaseURI(\"$base\") on $label $f (now $cur)"; return 0; fi
  out=$($CAST send "$f" 'setExternalBaseURI(string)' "$base" --rpc-url "$RPC" ${CAST_SIGN[@]+"${CAST_SIGN[@]}"} --json 2>&1 | scrub) \
    || { printf '%s\n' "$out" | tail -5; die "$label: transaction failed"; }
  status=$(printf '%s' "$out" | rcpt status); hash=$(printf '%s' "$out" | rcpt transactionHash)
  [ "$status" = 0x1 ] || [ "$status" = 1 ] || die "$label: status $status (tx $hash)"
  SENT=$((SENT + 1))
  say "   sent: setExternalBaseURI(\"$base\") on $label $f   tx $hash"
}
say "plan: cohort 1 → $BASE1, cohort 2 → $BASE2 (metadata only)"
[ "$MODE" = dry ] || confirm "Send?"
set_base "$COHORT1" "$BASE1" "cohort 1"
set_base "$COHORT2" "$BASE2" "cohort 2"
[ "$MODE" = dry ] && { say "DRY_RUN — nothing was sent"; exit 0; }

# ---------------------------------------------------------------- read-back
fail=0
for pair in "$COHORT1|$BASE1" "$COHORT2|$BASE2" "$COHORT3|$BASE3"; do
  f=${pair%%|*}; base=${pair##*|}
  if [ "$(call "$f" 'externalBaseURI()(string)')" = "\"$base\"" ]; then say "   PASS  $f → $base"; else say "   FAIL  $f"; fail=1; fi
done
# One real NFT per retired cohort must now carry its own base in the tokenURI's external_url (<base><momentId>).
MOMENT_TUPLE='(address,address,address,address,address,uint256,uint256,uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint64,uint64)'
for pair in "$COHORT1|$BASE1" "$COHORT2|$BASE2"; do
  f=${pair%%|*}; base=${pair##*|}
  nft=$(call "$f" "getMoment(uint256)($MOMENT_TUPLE)" 1 | tr -d '()' | awk -F', ' '{print $5}')
  ext=$(call "$nft" 'tokenURI(uint256)(string)' 1 | python3 -c "import base64,json,sys; u=json.loads(sys.stdin.read()); print(json.loads(base64.b64decode(u.split(',',1)[1])).get('external_url',''))" 2>/dev/null || true)
  if [ "$ext" = "${base}1" ]; then say "   PASS  $f Moment #1 NFT ($nft) external_url = $ext"
  else say "   FAIL  $f Moment #1 NFT external_url = '${ext:-?}' (expected ${base}1)"; fail=1; fi
done
[ "$fail" = 0 ] || die "read-back failed"
say "transactions sent: $SENT"
say "done."
