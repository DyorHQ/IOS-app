#!/bin/bash
# Secret-leak scanner. Looks for the VALUES of the local secrets (the repo's .env and the iOS Secrets.xcconfig), for
# well-known key and token patterns and for key-shaped literals, and reports only file:line and the variable/pattern
# NAME — a value is never printed.
#
#   scripts/dev/secret-scan.sh                  # staged changes: added lines of `git diff --cached` (pre-commit hook)
#   scripts/dev/secret-scan.sh --all            # every tracked file in the working tree
#   scripts/dev/secret-scan.sh --path DIR       # any file or directory, e.g. dist/ or an .xcarchive
#   scripts/dev/secret-scan.sh --pre-push       # commits being pushed, refs on stdin as git passes them (pre-push hook)
#   scripts/dev/secret-scan.sh --history [REV…] # added lines of every commit `git log REV…` lists (default: --all),
#                                               # e.g. the whole history, or origin/main..HEAD in CI
#   scripts/dev/secret-scan.sh --repo DIR …     # any mode above in another repository, with this one's secret values
#   scripts/dev/secret-scan.sh --install-hook   # same as scripts/dev/install-hooks.sh (the tracked .githooks/)
#
# What counts as secret:
#   .env (+ .env.local / .env.production / .env.production.local when present): every value of 12+ characters whose
#     variable is not NEXT_PUBLIC_* and is not a plain 0x-address — plus any NEXT_PUBLIC_* value shaped like a private
#     key (32-byte hex, e.g. NEXT_PUBLIC_DEV_WALLET_KEY), because vinext inlines NEXT_PUBLIC_ values into the bundle.
#   ios/DyorHQ/Config/Secrets.xcconfig: every value of 8+ characters whose variable is not a public identifier
#     (same PUBLIC_VARS and value handling as ios/scripts/testflight.sh).
#   Variables in PUBLIC_VARS (public identifiers such as the Privy app id) are skipped in both files.
#   32-byte hex values are matched case-insensitively and without the 0x; for a URL value the key part (its last path
#     segment, when 16+ characters) is matched on its own too.
#   Patterns (add_pattern below): keyed RPC-provider and bundler URLs (Alchemy, Infura, QuickNode, Pimlico), PEM and
#     age private keys, `…KEY=0x<64 hex>` and `private_key`/`privateKey`/`--private-key` assignments, provider tokens
#     (GitHub, AWS, Slack, Discord and Slack webhooks, Stripe live, Anthropic, OpenAI, Google, npm, Privy, Supabase,
#     Telegram), JSON Web Tokens, and a known secret variable (AURORA_API_KEY, PRIVY_APP_SECRET, …) given a literal.
#   Heuristics (HEURISTICS_AWK below): BIP-39 seed phrases (12+ consecutive words of bip39-english.txt, next to this
#     script) and 32-byte hex literals in a key-named array or passed to a key or wallet constructor.
#   Public values are masked before the patterns and heuristics run: the anvil/hardhat default keys, the fork-only dev
#     keys, the AWS documentation example keys, Supabase anon JWTs (the publishable sb_publishable_ key matches no
#     pattern) and well-known public test seed phrases. Test directories skip the key-literal heuristics only.
#   Committed env/key files are reported by name (scripts/dev/forbidden-paths.sh covers the full list).
#   Compressed archives (tar, tar.gz, zip, ipa, gz) are unpacked in memory and their contents checked as a whole.
# Sources are read from the main worktree (the parent of the git common dir) and from the current worktree.
# SECRET_SCAN_ENV / SECRET_SCAN_XCCONFIG replace the source files (tests use fake ones — never test with real values).
# Exit status: 0 clean, 1 findings, 2 usage or setup error. Runs on macOS /bin/bash 3.2.

# Never trace: the values below live in shell variables, and `bash -x`, SHELLOPTS=xtrace or a BASH_ENV that runs
# `set -x` would print every one of them to stderr.
set +x

# Byte-wise matching: binaries (an .xcarchive, a bundle) are not valid UTF-8, and grep skips bytes it cannot decode.
export LC_ALL=C

# Public identifiers that ship in the app by design. Mirrors PUBLIC_VARS in ios/scripts/testflight.sh; both gates run at
# upload time, so if the lists drift the stricter one wins — a drift can block an upload, never let a secret through.
PUBLIC_VARS=$(echo DEVELOPMENT_TEAM DYOR_SLASH PRIVY_APP_ID PRIVY_CLIENT_ID PASSKEY_RP_ID PERPL_BUILDER_ID \
  SOCIAL_LOGINS_ENABLED PASSKEYS_ENABLED LAUNCHPAD_FACTORY LAUNCH_ROUTER FEE_ESCROW HOLDER_FEE_SHARING MEME_HOOK \
  AURORA_FEE_RECIPIENT)

RE_ADDRESS='^0x[0-9a-fA-F]{40}$'
RE_HEX32='^(0x)?[0-9a-fA-F]{64}$'
RE_URL='^[A-Za-z][A-Za-z0-9+.-]*://'
RE_NAME='^[A-Za-z_][A-Za-z0-9_]*$'
# An xcconfig setting: NAME, optional conditions (NAME[sdk=iphoneos*][arch=*]), `=`, value; captures name and value.
RE_XCCONFIG_PARTS='^([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])*[[:space:]]*=(.*)$'

# Generic patterns (POSIX ERE, for grep -E, git grep -E and bash =~) as parallel arrays of name, regex and an optional
# prefilter: a looser regex that starts with a literal, which grep and git grep search much faster. A line has to
# match the prefilter to be tested against the regex, so a prefilter must match everything its regex matches.
P_NAME=(); P_RE=(); P_FAST=()
add_pattern() { P_NAME[${#P_NAME[@]}]=$1; P_RE[${#P_RE[@]}]=$2; P_FAST[${#P_FAST[@]}]=${3:-$2}; }
add_pattern "Alchemy keyed RPC URL" 'alchemy(api)?\.(com|io)/v2/[A-Za-z0-9_-]{16,}'
add_pattern "Infura keyed RPC URL" 'infura\.io/v3/[0-9a-fA-F]{32}'
add_pattern "QuickNode keyed RPC URL" 'quiknode\.pro/[0-9a-fA-F]{16,}'
add_pattern "Pimlico keyed URL (apikey=)" "pimlico\.io/[^[:space:]\"'\`]*[?&][Aa][Pp][Ii][Kk][Ee][Yy]=[A-Za-z0-9_-]{8,}"
add_pattern "Pimlico API key (pim_)" '(^|[^A-Za-z0-9_])pim_[A-Za-z0-9]{20,}' 'pim_[A-Za-z0-9]{20,}'
add_pattern "API key in a URL query (apikey= / api_key=)" '[?&][Aa][Pp][Ii][_-]?[Kk][Ee][Yy]=[A-Za-z0-9_-]{16,}'
add_pattern "PEM private key" '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----'
add_pattern "age secret key" 'AGE-SECRET-KEY-1[0-9A-Z]{58}'
add_pattern "private key assignment (KEY=0x + 64 hex)" "[A-Z0-9_]*KEY[\"']?[[:space:]]*[:=][[:space:]]*[\"']?0x[0-9a-fA-F]{64}" \
  "KEY[\"']?[[:space:]]*[:=][[:space:]]*[\"']?0x[0-9a-fA-F]{64}"
# privateKey: "0x…", private_key = "…", --private-key 0x… (any case; the 0x is optional for forge/cast).
add_pattern "private key assignment (private_key / --private-key + 64 hex)" \
  "[Pp][Rr][Ii][Vv][Aa][Tt][Ee][_-]?[Kk][Ee][Yy][\"']?([[:space:]]*[:=][[:space:]]*|[[:space:]]+)[\"']?(0x)?[0-9a-fA-F]{64}([^0-9a-fA-F]|$)"
add_pattern "Supabase secret key (sb_secret_)" 'sb_secret_[A-Za-z0-9_-]{20,}'
add_pattern "Supabase access token (sbp_)" 'sbp_[0-9a-f]{40}'
# A JWT whose payload carries "service_role" (its base64url in each of the three byte alignments).
add_pattern "Supabase service_role JWT" 'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*(c2VydmljZV9yb2xl|NlcnZpY2Vfcm9sZ|zZXJ2aWNlX3JvbG)'
# Any other JWT (a Privy or Pinata token, a session): header.payload.signature. Supabase anon keys are masked first.
add_pattern "JSON Web Token" 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
add_pattern "Privy app secret (privy_app_secret_)" 'privy_app_secret_[A-Za-z0-9_-]{20,}'
add_pattern "Privy authorization key (wallet-auth:)" 'wallet-auth:[A-Za-z0-9+/]{40,}'
add_pattern "GitHub token (ghp_/gho_/ghs_/ghu_/ghr_)" 'gh[pousr]_[A-Za-z0-9]{36}'
add_pattern "GitHub fine-grained token (github_pat_)" 'github_pat_[A-Za-z0-9_]{60,}'
add_pattern "AWS access key id (AKIA/ASIA)" '(^|[^A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Za-z0-9]|$)' '(AKIA|ASIA)[0-9A-Z]{16}'
add_pattern "AWS secret access key assignment" \
  "[Aa][Ww][Ss][A-Za-z0-9_.-]{0,20}[Ss][Ee][Cc][Rr][Ee][Tt][A-Za-z0-9_.-]{0,20}[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9/+]{40}([^A-Za-z0-9/+=]|$)"
add_pattern "Slack token (xox*)" 'xox[abeoprs]-[0-9A-Za-z-]{10,}'
add_pattern "Slack webhook URL" 'hooks\.slack\.com/(services|workflows|triggers)/[A-Za-z0-9_/-]{20,}'
add_pattern "Discord webhook URL" 'discord(app)?\.com/api/webhooks/[0-9]{15,}/[A-Za-z0-9_-]{30,}'
add_pattern "Stripe live key (sk_live_/rk_live_)" '(sk|rk)_live_[0-9A-Za-z]{20,}'
add_pattern "Anthropic API key (sk-ant-)" 'sk-ant-[A-Za-z0-9_-]{20,}'
add_pattern "OpenAI API key (sk-proj-/sk-svcacct-/sk-admin-)" 'sk-(proj|svcacct|admin)-[A-Za-z0-9_-]{20,}'
add_pattern "OpenAI-style API key (sk-…)" '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9]{32,}([^A-Za-z0-9_-]|$)' 'sk-[A-Za-z0-9]{32,}'
add_pattern "Google API key (AIza)" 'AIza[0-9A-Za-z_-]{35}'
add_pattern "npm token (npm_)" '(^|[^A-Za-z0-9_])npm_[A-Za-z0-9]{36}([^A-Za-z0-9]|$)' 'npm_[A-Za-z0-9]{36}'
add_pattern "Telegram bot token" '(^|[^0-9])[0-9]{8,10}:AA[0-9A-Za-z_-]{33}([^0-9A-Za-z_-]|$)' ':AA[0-9A-Za-z_-]{33}'
# NAME=value for the secrets this project uses (also as the end of a longer name, e.g. NEXT_PUBLIC_…), when the value
# is a literal token: no $VAR, <placeholder>, call or dotted expression (JWTs and URLs are left to the patterns above).
add_pattern "known secret variable with a literal value" \
  "(APP_JWT_SECRET|PRIVY_APP_SECRET|AURORA_API_KEY|SUPABASE_SERVICE_ROLE_KEY|SERVICE_ROLE_KEY|PINATA_JWT|PINATA_API_KEY|PINATA_API_SECRET|OPENSEA_API_KEY|ALCHEMY_API_KEY|PIMLICO_API_KEY|TREASURY_KEY|OWNER_KEY|DEPLOYER_KEY|MNEMONIC|SEED_PHRASE)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9_+/=-]{16,}" \
  "(SECRET|_KEY|_JWT|MNEMONIC|SEED_PHRASE)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9_+/=-]{16,}"

# Masked before the patterns and heuristics run, so they never count as findings (a value from .env is still matched
# even if it is one of these):
#   anvil / hardhat default accounts 0-9 (the public "test test … junk" mnemonic): world-known dev keys;
#   the fork-only dev keys of IOS-app's scripts/dev/seed-moments-fork.mjs, keccak256("dyorhq-moments-fork-wallet-1..3"):
#   derived from public labels, for local anvil forks only, never funded on mainnet.
PUBLIC_TEST_KEYS="($(echo \
  ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
  5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a \
  7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6 \
  47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a \
  8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba \
  92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e \
  4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356 \
  dbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97 \
  2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6 \
  57bcbb515c0a9835560414863de2a2903e4f195eb93fa071b8d0557608ee952a \
  3470e801c46dde26c5827e7caa3e523b54f026eec2b2d0bbbae6ad2e98179270 \
  130eadc747f9b9e2c55ec6772c90b96a89e3b2890fa0f66ebd35aba462e32dd5 | tr ' ' '|'))"
# A Supabase anon key: a JWT whose payload carries "role":"anon" (base64url in each byte alignment). It is public by
# design (row-level security protects the data), like the sb_publishable_ key the apps ship today.
ANON_JWT='eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*(InJvbGUiOiJhbm9uI|Jyb2xlIjoiYW5vbi|icm9sZSI6ImFub24i)[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*'
# The example credentials of the AWS documentation.
AWS_EXAMPLES='AKIAIOSFODNN7EXAMPLE|wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
# Well-known public test seed phrases, "|"-separated: the BIP-39 vector for entropy 0x00…1f (DyorKit's Mera tests),
# the anvil/hardhat mnemonic and the all-zero-entropy vector. Low-entropy vectors (repeated words) never count anyway.
PUBLIC_PHRASES="abandon amount liar amount expire adjust cage candy arch gather drum bullet absurd math era live bid rhythm alien crouch range attend journey unaware|test test test test test test test test test test test junk|abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

usage() { sed -n '6,13p' "$0" | sed 's/^# //' >&2; exit 2; }
die() { echo "secret-scan: $*" >&2; exit 2; }

MODE=staged; TARGET=; FORCE=; REPO=; HIST_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --staged) MODE=staged ;;
    --all) MODE=all ;;
    --path) [ $# -ge 2 ] || usage; MODE=path; TARGET=$2; shift ;;
    --pre-push) MODE=push; break ;; # git passes the remote's name and URL after it; the refs come on stdin
    --history) MODE=history; shift; HIST_ARGS=("$@"); break ;; # the rest are git-log revision arguments
    --repo) [ $# -ge 2 ] || usage; REPO=$2; shift ;;
    --install-hook) MODE=install ;;
    --force) FORCE=1 ;;
    *) usage ;;
  esac
  shift
done
[ "$MODE" = history ] && [ ${#HIST_ARGS[@]} -eq 0 ] && HIST_ARGS=(--all)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || TOP=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || TOP=
COMMON=
[ -n "$TOP" ] && COMMON=$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$COMMON" ]; then MAIN=$(cd "$COMMON/.." && pwd); else MAIN="$HOME/Hackathon"; fi
WORDLIST="$SCRIPT_DIR/bip39-english.txt"

# ---------- install the hooks: the tracked .githooks/, set up by install-hooks.sh ----------
if [ "$MODE" = install ]; then
  [ -f "$SCRIPT_DIR/install-hooks.sh" ] || die "install-hooks.sh is missing next to $0"
  exec /bin/bash "$SCRIPT_DIR/install-hooks.sh" ${FORCE:+--force}
fi

# ---------- collect secret values (kept in memory; a value is never echoed or passed as an argument) ----------
V_LABEL=(); V_VAL=(); V_ICASE=()
add_value() { # label value icase — an identical value from another variable just extends the label
  local i=0
  while [ $i -lt ${#V_VAL[@]} ]; do
    if [ "${V_VAL[$i]}" = "$2" ]; then V_LABEL[$i]="${V_LABEL[$i]}, $1"; return; fi
    i=$((i + 1))
  done
  V_LABEL[${#V_LABEL[@]}]=$1; V_VAL[${#V_VAL[@]}]=$2; V_ICASE[${#V_ICASE[@]}]=$3
}
trim() { _T=$1; _T="${_T#"${_T%%[![:space:]]*}"}"; _T="${_T%"${_T##*[![:space:]]}"}"; } # result in $_T (no subshell)
is_public() { case " $PUBLIC_VARS " in *" $1 "*) return 0 ;; esac; return 1; }
add_secret() { # label value — the value plus the other forms it can leak in
  local key
  if [[ $2 =~ $RE_HEX32 ]]; then add_value "$1" "${2#0x}" 1; return; fi
  add_value "$1" "$2" 0
  if [[ $2 =~ $RE_URL ]]; then
    key=${2%%[?#]*}; key=${key%/}; key=${key##*/}
    [ ${#key} -ge 16 ] && add_value "$1 (key part)" "$key" 0
  fi
}

SOURCES=()
load_env() { # file label
  local line name value q
  SOURCES[${#SOURCES[@]}]=$2
  while IFS= read -r line || [ -n "$line" ]; do
    trim "$line"; line=$_T
    case "$line" in ''|'#'*) continue ;; esac
    if [[ $line =~ ^export[[:space:]] ]]; then trim "${line#export}"; line=$_T; fi
    case "$line" in *=*) ;; *) continue ;; esac
    trim "${line%%=*}"; name=$_T
    [[ $name =~ $RE_NAME ]] || continue
    trim "${line#*=}"; value=$_T
    q=${value:0:1}
    if [ "$q" = '"' ] || [ "$q" = "'" ]; then
      value=${value:1}; value=${value%%"$q"*}
    else
      trim "${value%%[[:space:]]#*}"; value=$_T
    fi
    is_public "$name" && continue
    case "$name" in NEXT_PUBLIC_*) [[ $value =~ $RE_HEX32 ]] || continue ;; esac
    [[ $value =~ $RE_ADDRESS ]] && continue
    [ ${#value} -ge 12 ] || continue
    add_secret "$name ($2)" "$value"
  done < "$1"
}
load_xcconfig() { # file label — parsed exactly like ios/scripts/testflight.sh
  local line name value
  SOURCES[${#SOURCES[@]}]=$2
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ $RE_XCCONFIG_PARTS ]] || continue
    name=${BASH_REMATCH[1]}
    is_public "$name" && continue
    value=$(printf '%s' "${BASH_REMATCH[3]}" | sed -e 's:[[:space:]]//.*$::' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\$(DYOR_SLASH)/\//g')
    [[ $value =~ $RE_ADDRESS ]] && continue
    [ ${#value} -ge 8 ] || continue
    add_secret "$name ($2)" "$value"
  done < "$1"
}
SEEN_FILES=" "
load_once() { # env|xcconfig file label
  local key
  [ -f "$2" ] || return 0
  key="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
  case "$SEEN_FILES" in *" $key "*) return 0 ;; esac
  SEEN_FILES="$SEEN_FILES$key "
  if [ "$1" = env ]; then load_env "$2" "$3"; else load_xcconfig "$2" "$3"; fi
}

if [ -n "${SECRET_SCAN_ENV:-}${SECRET_SCAN_XCCONFIG:-}" ]; then
  [ -n "${SECRET_SCAN_ENV:-}" ] && load_once env "$SECRET_SCAN_ENV" "$(basename "$SECRET_SCAN_ENV")"
  [ -n "${SECRET_SCAN_XCCONFIG:-}" ] && load_once xcconfig "$SECRET_SCAN_XCCONFIG" "$(basename "$SECRET_SCAN_XCCONFIG")"
else
  for dir in "$MAIN" ${TOP:+"$TOP"}; do
    for f in .env .env.local .env.production .env.production.local; do load_once env "$dir/$f" "$f"; done
    load_once xcconfig "$dir/ios/DyorHQ/Config/Secrets.xcconfig" "Secrets.xcconfig"
  done
fi
[ ${#SOURCES[@]} -gt 0 ] || echo "secret-scan: warning — no .env or Secrets.xcconfig found; only the generic patterns are checked." >&2
[ -f "$WORDLIST" ] || echo "secret-scan: warning — $WORDLIST is missing; seed phrases are not checked." >&2

# --repo: everything below runs in that repository, with the values collected above.
if [ -n "$REPO" ]; then
  TOP=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || die "not a git repository: $REPO"
fi

# ---------- scanning: every finding is one "location: NAME" line; matched text is never output ----------
report() { echo "$1: $2"; }
values_all() { local i=0; while [ $i -lt ${#V_VAL[@]} ]; do printf '%s\n' "${V_VAL[$i]}"; i=$((i + 1)); done; }
icase_flag() { [ "${V_ICASE[$1]}" = 1 ] && printf '%s' -i; }
mask_public() { sed -E -e "s/$PUBLIC_TEST_KEYS/<public test key>/gI" -e "s/$ANON_JWT/<public anon JWT>/g" -e "s#$AWS_EXAMPLES#<public example key>#g"; }
PATTERN_ARGS=(); i=0
while [ $i -lt ${#P_FAST[@]} ]; do PATTERN_ARGS[${#PATTERN_ARGS[@]}]=-e; PATTERN_ARGS[${#PATTERN_ARGS[@]}]=${P_FAST[$i]}; i=$((i + 1)); done

# Key-shaped literals no fixed pattern describes, as one awk program for every input. MODE is "file" (the lines of the
# file FNAME), "tagged" (the added lines of a diff, "path<TAB>line<TAB>text") or "stream" (an archive's contents, where
# each name is printed once and without a location). Prints "location: NAME" lines; a matched value never leaves awk.
# Portable awk only (macOS awk, mawk, gawk): no interval expressions, no gawk extensions.
read -r -d '' HEURISTICS_AWK <<'AWK'
BEGIN {
  nbip = 0
  if (WL != "") { while ((getline w < WL) > 0) { bip[w] = 1; nbip++ } close(WL) }
  nphr = split(PHRASES, phr, "|")
}
function say(name) {
  if (MODE == "stream") { if (!(name in said)) { said[name] = 1; print name } }
  else print loc ": " name
}
# Test directories and test files hold test vectors (derived keys, fixture hashes): the key-literal checks skip them.
function is_test(p) {
  return p ~ /(^|\/|:)(test|tests|Tests|__tests__|fixtures|Fixtures)\// || p ~ /(\.test\.|\.spec\.|Tests?\.swift$|\.t\.sol$)/
}
# 1 when s has a quoted literal of exactly 32 bytes of hex (0x optional).
function has_hex32(s,   h) {
  while (match(s, /["'`](0x)?[0-9a-f]+["'`]/)) {
    h = substr(s, RSTART + 1, RLENGTH - 2); sub(/^0x/, "", h)
    if (length(h) == 64) return 1
    s = substr(s, RSTART + RLENGTH)
  }
  return 0
}
# 1 when a quoted 32-byte hex literal is passed to something named like a key or a wallet: privateKeyToAccount("0x…"),
# new Wallet("…"), Account(privateKeyHex: "…"), key = Data(hex: "…"), Account.from_key("…").
function key_call(s,   off, h, pre) {
  off = 0
  while (match(substr(s, off + 1), /["'`](0x)?[0-9a-f]+["'`]/)) {
    h = substr(s, off + RSTART + 1, RLENGTH - 2); sub(/^0x/, "", h)
    if (length(h) == 64) {
      pre = substr(s, 1, off + RSTART - 1)
      if (length(pre) > 60) pre = substr(pre, length(pre) - 59)
      if (pre ~ /(^|[^a-z0-9_])(private[a-z0-9_]*|privkey|secret[a-z0-9_]*|signing_?key|signer[a-z0-9_]*|wallet[a-z0-9_]*|from_key|keypair|key|pk|sk)["'` \t]*[(:=][^"'`]*$/) return 1
    }
    off += RSTART + RLENGTH - 1
  }
  return 0
}
function sorted(a, i, j,   k) { for (k = i; k < j; k++) if (!(a[k] < a[k + 1])) return 0; return 1 }
function distinct(a, i, j,   k, n, seen) {
  split("", seen); n = 0
  for (k = i; k <= j; k++) if (!(a[k] in seen)) { seen[a[k]] = 1; n++ }
  return n
}
# 1 when s has 12+ consecutive BIP-39 words that look like a real phrase: not in wordlist order (a copy of the list) and
# at least 10 distinct (test vectors repeat words). Separators: spaces, quotes, commas, brackets, "\n", a full stop.
function seed_phrase(s,   t, n, i, run, k) {
  s = s " "
  gsub(/\\n/, " ", s)
  gsub(/\.[ \t]/, " ", s)
  gsub(/[][ \t"'`,;(){}]+/, " ", s)
  for (k = 1; k <= nphr; k++) if (index(s, phr[k])) gsub(phr[k], " | ", s)
  n = split(s, t, " ")
  run = 0
  for (i = 1; i <= n + 1; i++) {
    if (i <= n && (t[i] in bip)) { run++; continue }
    if (run >= 12 && !sorted(t, i - run, i - 1) && distinct(t, i - run, i - 1) >= 10) return 1
    run = 0
  }
  return 0
}
{
  if (MODE == "tagged") {
    p = index($0, "\t"); path = substr($0, 1, p - 1); rest = substr($0, p + 1)
    p = index(rest, "\t"); ln = substr(rest, 1, p - 1) + 0; text = substr(rest, p + 1)
  } else { path = FNAME != "" ? FNAME : FILENAME; ln = FNR; text = $0 }
  loc = path ":" ln
  if (path != lastpath || ln != lastln + 1) depth = 0 # a key array only continues on the next line of the same file
  lastpath = path; lastln = ln
  s = tolower(text)
  if (PUBKEYS != "") gsub(PUBKEYS, "<public test key>", s)
  if (!is_test(path)) {
    # An array assigned to a name with key, secret, signer, wallet, seed…: `keys = [`, `signerKeys: string[] = [`.
    if (depth <= 0 && match(s, /[a-z0-9_]*(priv|secret|signer|signing|wallet|mnemonic|seed|key)[a-z0-9_]*[ \t]*(:[^=]*)?[=:][ \t]*\[/)) {
      seg = substr(s, RSTART)
      if (has_hex32(seg)) say("32-byte hex key in a key-named array")
      depth = gsub(/\[/, "[", seg) - gsub(/\]/, "]", seg)
    } else if (depth > 0) {
      seg = s
      if (has_hex32(seg)) say("32-byte hex key in a key-named array")
      depth += gsub(/\[/, "[", seg) - gsub(/\]/, "]", seg)
    }
    if (key_call(s)) say("32-byte hex key passed to a key or wallet constructor")
  }
  if (nbip && seed_phrase(s)) say("BIP-39 seed phrase (12+ wordlist words)")
}
AWK
HEURISTICS_WL=
[ -f "$WORDLIST" ] && HEURISTICS_WL=$WORDLIST
heuristics() { # mode label — the text on stdin
  awk -v MODE="$1" -v FNAME="$2" -v WL="$HEURISTICS_WL" -v PHRASES="$PUBLIC_PHRASES" -v PUBKEYS="$PUBLIC_TEST_KEYS" \
    "$HEURISTICS_AWK"
}
# Text files, NUL-separated on stdin, in as few awk runs as xargs needs (starting a process is the slow part). Binary
# files are left to the value and pattern checks; archives are read as a stream by scan_archive.
heuristics_files() {
  xargs -0 -r awk -v MODE=file -v FNAME= -v WL="$HEURISTICS_WL" -v PHRASES="$PUBLIC_PHRASES" -v PUBKEYS="$PUBLIC_TEST_KEYS" \
    "$HEURISTICS_AWK"
}

# Line numbers (only) where value i occurs in a file.
value_lines() { grep -naF $(icase_flag "$1") -f <(printf '%s\n' "${V_VAL[$1]}") -- "$2" 2>/dev/null | cut -d: -f1; }
# Every pattern that matches one line of text (already masked), reported at the location. The patterns are tested in
# bash, not with a grep each: starting processes is what makes a scan slow.
report_line() { # location text
  local i=0
  while [ $i -lt ${#P_RE[@]} ]; do
    [[ $2 =~ ${P_RE[$i]} ]] && report "$1" "${P_NAME[$i]}"
    i=$((i + 1))
  done
}
scan_file() {
  local i n line
  if [ ${#V_VAL[@]} -gt 0 ] && grep -qaiF -f <(values_all) -- "$1" 2>/dev/null; then
    i=0
    while [ $i -lt ${#V_VAL[@]} ]; do
      for n in $(value_lines $i "$1"); do report "$1:$n" "${V_LABEL[$i]}"; done
      i=$((i + 1))
    done
  fi
  while IFS= read -r line; do report_line "$1:${line%%:*}" "${line#*:}"; done \
    < <(grep -naE "${PATTERN_ARGS[@]}" -- "$1" 2>/dev/null | mask_public)
}

# File names that must never be committed, whatever they contain.
check_name() { # path [label]
  case "$1" in
    .env.example|*/.env.example) ;;
    .env|.env.*|*/.env|*/.env.*) report "${2:-$1}" "env file must not be committed" ;;
    Secrets.xcconfig|*/Secrets.xcconfig) report "${2:-$1}" "Secrets.xcconfig must not be committed" ;;
    AuthKey_*.p8|*/AuthKey_*.p8) report "${2:-$1}" "App Store Connect API key must not be committed" ;;
  esac
}

# Compressed archives are unpacked as a stream (bsdtar reads tar, tar.gz/bz2/xz, zip and ipa; gzip a plain .gz) and
# their contents checked as a whole: a hit names the archive and the variable, not the member or line. Nothing is
# extracted to disk.
ARCHIVE_GLOBS=('*.tar' '*.tgz' '*.tbz2' '*.txz' '*.tar.bz2' '*.tar.xz' '*.zip' '*.ipa' '*.gz')
ARCHIVE_FIND=('(')
for g in "${ARCHIVE_GLOBS[@]}"; do ARCHIVE_FIND=("${ARCHIVE_FIND[@]}" -name "$g" -o); done
ARCHIVE_FIND[${#ARCHIVE_FIND[@]} - 1]=')'
is_archive() { local g; for g in "${ARCHIVE_GLOBS[@]}"; do case "$1" in $g) return 0 ;; esac; done; return 1; }
unpack() { case "$1" in *.tar.gz|*.tgz) tar -xOf - ;; *.gz) gzip -dc ;; *) tar -xOf - ;; esac 2>/dev/null; } # name
scan_archive() { # label name reader... — the reader writes the archive's bytes to stdout
  local label=$1 name=$2 i h
  shift 2
  if ! "$@" | unpack "$name" >/dev/null; then report "$label" "compressed archive that cannot be unpacked for scanning"; return 0; fi
  if [ ${#V_VAL[@]} -gt 0 ] && "$@" | unpack "$name" | grep -qaiF -f <(values_all); then
    i=0
    while [ $i -lt ${#V_VAL[@]} ]; do
      if "$@" | unpack "$name" | grep -qaF $(icase_flag $i) -f <(printf '%s\n' "${V_VAL[$i]}"); then
        report "$label (inside the archive)" "${V_LABEL[$i]}"
      fi
      i=$((i + 1))
    done
  fi
  # Each pattern name once, however often it matches.
  report_line "$label (inside the archive)" "$("$@" | unpack "$name" | grep -aE "${PATTERN_ARGS[@]}" | mask_public | tr '\n\000' '  ')"
  "$@" | unpack "$name" | tr '\000' '\n' | heuristics stream "$label" | while IFS= read -r h; do
    report "$label (inside the archive)" "$h"
  done
  return 0
}

# A fast pass lists the candidate files (NUL-separated); the per-file pass then attributes each hit to a name. The
# heuristics read every text file.
scan_tree() { # all | path TARGET
  local f
  {
    if [ "$1" = all ]; then
      [ ${#V_VAL[@]} -gt 0 ] && git grep -l -z --text -i -F -f <(values_all)
      git grep -l -z --text -E "${PATTERN_ARGS[@]}"
    else
      [ ${#V_VAL[@]} -gt 0 ] && grep -rlaiF --null -f <(values_all) -- "$2"
      grep -rlaE --null "${PATTERN_ARGS[@]}" -- "$2"
    fi
  } 2>/dev/null | sort -zu | while IFS= read -r -d '' f; do scan_file "$f"; done
  if [ "$1" = all ]; then git grep -I -l -z -e ''; else find "$2" -type f -print0 | xargs -0 -r grep -I -l --null -e ''; fi 2>/dev/null |
    heuristics_files
  if [ "$1" = all ]; then git ls-files -z -- "${ARCHIVE_GLOBS[@]}"; else find "$2" -type f "${ARCHIVE_FIND[@]}" -print0; fi |
    while IFS= read -r -d '' f; do scan_archive "$f" "$f" cat -- "$f"; done
}

# Added lines of a diff on stdin as "path<TAB>line<TAB>text" ("sha:path" after a `commit <sha>` line of git log); a
# match keeps only path and line. A `+++ ` line is a file name only in a file header (between `diff --git` and the first
# `@@`); inside a hunk it is an added line that starts with "++ ". NUL bytes become \001 first, because awk ends a
# record at a NUL and would drop the rest of the line.
added_lines() {
  tr '\000' '\001' | awk '
    /^commit [0-9a-f]+$/ { c = substr($0, 8) ":"; next }
    /^diff --git / { hdr = 1; next }
    hdr && /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); f = c f; next }
    /^@@/ { hdr = 0; match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
    !hdr && /^\+/ { print f "\t" n "\t" substr($0, 2); n++ }'
}
DIFF_OPTS=(--no-color --no-ext-diff --no-textconv --text --src-prefix=a/ --dst-prefix=b/ -U0 --diff-filter=ACMRT)
# The added lines go to a private temporary file (removed on exit), which every pass below reads.
TMP_DIR=
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT
TMP_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/secret-scan.XXXXXX") || die "cannot create a temporary directory"
LINES="$TMP_DIR/added"
scan_lines() { # file of added_lines output
  local i p n line rest
  [ -s "$1" ] || return 0
  # One pass over everything first; the per-name passes below only run when something matched.
  if [ ${#V_VAL[@]} -gt 0 ] && grep -qaiF -f <(values_all) -- "$1"; then
    i=0
    while [ $i -lt ${#V_VAL[@]} ]; do
      while IFS=$'\t' read -r p n; do report "$p:$n" "${V_LABEL[$i]}"; done \
        < <(grep -aF $(icase_flag $i) -f <(printf '%s\n' "${V_VAL[$i]}") -- "$1" | cut -f1,2)
      i=$((i + 1))
    done
  fi
  while IFS= read -r line; do
    p=${line%%$'\t'*}; rest=${line#*$'\t'}
    report_line "$p:${rest%%$'\t'*}" "${rest#*$'\t'}"
  done < <(grep -aE "${PATTERN_ARGS[@]}" -- "$1" | mask_public)
  heuristics tagged "" < "$1"
}
scan_staged() {
  local p
  while IFS= read -r -d '' p; do
    check_name "$p"
    is_archive "$p" && scan_archive "$p" "$p" git cat-file blob ":$p"
  done < <(git diff --cached --name-only -z --diff-filter=ACMR)
  git diff --cached "${DIFF_OPTS[@]}" | added_lines > "$LINES"
  scan_lines "$LINES"
  return 0
}

# Commits being pushed. git writes "<local ref> <local sha> <remote ref> <remote sha>" per ref on stdin. Every commit
# no remote-tracking ref has yet is scanned patch by patch (a merge against its first parent), so a secret that was
# added and removed again inside the push is still caught — it would be in the pushed history.
commit_paths() { # sha — files the commit adds or changes (a merge: against its first parent), NUL-separated
  if git rev-parse -q --verify "$1^" >/dev/null; then git diff-tree -r --name-only -z --diff-filter=ACMR "$1^" "$1"
  else git diff-tree -r --root --no-commit-id --name-only -z --diff-filter=ACMR "$1"; fi
}
scan_commits() { # git-log revision arguments — names and archives of every listed commit, then their added lines
  local c s p
  for c in $(git rev-list "$@"); do
    s=$(git rev-parse --short "$c")
    while IFS= read -r -d '' p; do
      check_name "$p" "$s:$p"
      is_archive "$p" && scan_archive "$s:$p" "$p" git cat-file blob "$c:$p"
    done < <(commit_paths "$c")
  done
  git log -p --format='commit %h' --diff-merges=first-parent "${DIFF_OPTS[@]}" "$@" | added_lines > "$LINES"
  scan_lines "$LINES"
}
scan_pushed() {
  local refs lref lsha rref rsha
  refs=$(cat)
  while read -r lref lsha rref rsha; do
    case "$lsha" in *[!0]*) ;; *) continue ;; esac # a deleted ref pushes no commits
    git rev-parse -q --verify "$lsha^{commit}" >/dev/null || die "cannot read the pushed commit for $lref"
    set -- "$lsha" --not --remotes
    case "$rsha" in *[!0]*) git rev-parse -q --verify "$rsha^{commit}" >/dev/null && set -- "$@" "$rsha" ;; esac
    scan_commits "$@"
  done <<REFS
$refs
REFS
  return 0
}

case "$MODE" in
  staged)
    [ -n "$TOP" ] || die "not inside a git repository"
    cd "$TOP" || die "cannot enter $TOP"
    WHAT="staged changes"
    OUT=$(scan_staged) ;;
  all)
    [ -n "$TOP" ] || die "not inside a git repository"
    cd "$TOP" || die "cannot enter $TOP"
    WHAT="tracked files in $TOP"
    OUT=$(while IFS= read -r -d '' p; do check_name "$p"; done < <(git ls-files -z); scan_tree all) ;;
  path)
    [ -e "$TARGET" ] || die "no such file or directory: $TARGET"
    WHAT=$TARGET
    OUT=$(scan_tree path "$TARGET") ;;
  push)
    [ -n "$TOP" ] || die "not inside a git repository"
    cd "$TOP" || die "cannot enter $TOP"
    WHAT="commits being pushed"
    OUT=$(scan_pushed) || exit 2 ;;
  history)
    [ -n "$TOP" ] || die "not inside a git repository"
    cd "$TOP" || die "cannot enter $TOP"
    git rev-list -n 1 "${HIST_ARGS[@]}" >/dev/null 2>&1 || die "git log cannot read the revisions: ${HIST_ARGS[*]}"
    WHAT="commits of git log ${HIST_ARGS[*]} in $TOP"
    OUT=$(scan_commits "${HIST_ARGS[@]}") ;;
esac

if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
  echo "secret-scan: $(printf '%s\n' "$OUT" | wc -l | tr -d ' ') finding(s) in $WHAT — locations and names only, values are never printed." >&2
  echo "  Take the value out (keep it server-side or in an ignored env file) and rotate it if it was ever shared." >&2
  exit 1
fi
echo "secret-scan: clean — $WHAT (${#V_VAL[@]} secret value forms from ${SOURCES[*]:-no env files}, ${#P_RE[@]} patterns + seed-phrase and key-literal checks)." >&2
exit 0
