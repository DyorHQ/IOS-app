#!/bin/bash
# Secret-leak scanner. Looks for the VALUES of the local secrets (the repo's .env and the iOS Secrets.xcconfig) and for
# well-known key patterns, and reports only file:line and the variable/pattern NAME — a value is never printed.
#
#   scripts/dev/secret-scan.sh                  # staged changes: added lines of `git diff --cached` (pre-commit hook)
#   scripts/dev/secret-scan.sh --all            # every tracked file in the working tree
#   scripts/dev/secret-scan.sh --path DIR       # any file or directory, e.g. dist/ or an .xcarchive
#   scripts/dev/secret-scan.sh --pre-push       # commits being pushed, refs on stdin as git passes them (pre-push hook)
#   scripts/dev/secret-scan.sh --install-hook   # install the pre-commit, pre-merge-commit and pre-push hooks (shared
#                                               # by every worktree)
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
#   Patterns: keyed RPC-provider URLs, PEM private keys, `…KEY=0x<64 hex>` and
#     `private_key`/`privateKey`/`--private-key` assignments, Supabase secret keys (sb_secret_…, service_role JWTs),
#     committed env/key files.
#   Compressed archives (tar, tar.gz, zip, ipa, gz) are unpacked in memory and their contents checked as a whole.
# Sources are read from the main worktree (the parent of the git common dir) and from the current worktree.
# SECRET_SCAN_ENV / SECRET_SCAN_XCCONFIG replace the source files (tests use fake ones — never test with real values).
# Exit status: 0 clean, 1 findings, 2 usage or setup error. Runs on macOS /bin/bash 3.2.

# Never trace: the values below live in shell variables, and `bash -x`, SHELLOPTS=xtrace or a BASH_ENV that runs
# `set -x` would print every one of them to stderr.
set +x

HOOK_MARKER="# dyorhq-secret-scan"
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

# Generic patterns (ERE) as parallel arrays of name and regex.
P_NAME=(); P_RE=()
add_pattern() { P_NAME[${#P_NAME[@]}]=$1; P_RE[${#P_RE[@]}]=$2; }
add_pattern "Alchemy keyed RPC URL" 'alchemy\.com/v2/[A-Za-z0-9_-]{16,}'
add_pattern "Infura keyed RPC URL" 'infura\.io/v3/[0-9a-fA-F]{32}'
add_pattern "QuickNode keyed RPC URL" 'quiknode\.pro/[0-9a-fA-F]{16,}'
add_pattern "PEM private key" '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----'
add_pattern "private key assignment (KEY=0x + 64 hex)" "[A-Z0-9_]*KEY[\"']?[[:space:]]*[:=][[:space:]]*[\"']?0x[0-9a-fA-F]{64}"
# privateKey: "0x…", private_key = "…", --private-key 0x… (any case; the 0x is optional for forge/cast).
add_pattern "private key assignment (private_key / --private-key + 64 hex)" \
  "[Pp][Rr][Ii][Vv][Aa][Tt][Ee][_-]?[Kk][Ee][Yy][\"']?([[:space:]]*[:=][[:space:]]*|[[:space:]]+)[\"']?(0x)?[0-9a-fA-F]{64}([^0-9a-fA-F]|$)"
add_pattern "Supabase secret key (sb_secret_)" 'sb_secret_[A-Za-z0-9_-]{20,}'
# A JWT whose payload carries "service_role" (its base64url in each of the three byte alignments).
add_pattern "Supabase service_role JWT" 'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*(c2VydmljZV9yb2xl|NlcnZpY2Vfcm9sZ|zZXJ2aWNlX3JvbG)'
# anvil / hardhat default accounts 0-9 (the public "test test … junk" mnemonic): world-known dev keys, so they are
# masked before the patterns run. A value from .env is still matched even if it is one of these.
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
  2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6 | tr ' ' '|'))"

usage() { sed -n '5,10p' "$0" | sed 's/^# //' >&2; exit 2; }
die() { echo "secret-scan: $*" >&2; exit 2; }

MODE=staged; TARGET=; FORCE=
while [ $# -gt 0 ]; do
  case "$1" in
    --staged) MODE=staged ;;
    --all) MODE=all ;;
    --path) [ $# -ge 2 ] || usage; MODE=path; TARGET=$2; shift ;;
    --pre-push) MODE=push; break ;; # git passes the remote's name and URL after it; the refs come on stdin
    --install-hook) MODE=install ;;
    --force) FORCE=1 ;;
    *) usage ;;
  esac
  shift
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || TOP=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || TOP=
COMMON=
[ -n "$TOP" ] && COMMON=$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$COMMON" ]; then MAIN=$(cd "$COMMON/.." && pwd); else MAIN="$HOME/Hackathon"; fi

# ---------- install the hooks ----------
# pre-commit and pre-merge-commit scan the staged lines. pre-push scans every commit being pushed, which also covers
# what the commit hooks never see: cherry-picks, rebases, `git am`, commits made with --no-verify or in another clone.
install_hook() { # hook-name what scanner-mode
  local hook="$HOOKS/$1"
  if [ -e "$hook" ] && ! grep -qF "$HOOK_MARKER" "$hook"; then
    if [ -z "$FORCE" ]; then
      echo "secret-scan: $hook already exists and is not this scanner's hook — left untouched." >&2
      echo "  Re-run with --install-hook --force to replace it (the old hook is kept as $1.bak)." >&2
      return 1
    fi
    cp -p "$hook" "$hook.bak" || die "cannot back up $hook"
    echo "secret-scan: replacing the existing $1 hook (backup: $hook.bak)." >&2
  fi
  cat > "$hook" <<EOF || die "cannot write $hook"
#!/bin/bash
$HOOK_MARKER $1 hook (installed by scripts/dev/secret-scan.sh --install-hook).
# Blocks $2 whose added lines carry a secret value from .env / Secrets.xcconfig or a known key pattern. Only
# file:line and the variable name are printed. Uses the worktree's scripts/dev/secret-scan.sh when it has one, else
# the copy installed next to this hook. Only after checking that a finding is a false positive: --no-verify
top=\$(git rev-parse --show-toplevel) || exit 1
scanner="\$top/scripts/dev/secret-scan.sh"
[ -f "\$scanner" ] || scanner="$HOOKS/secret-scan.sh"
if [ ! -f "\$scanner" ]; then
  echo "$1: secret-scan.sh not found; refusing to continue unscanned." >&2
  exit 1
fi
# A traced or BASH_ENV-injected shell could print the values the scanner holds.
exec env -u BASH_ENV -u SHELLOPTS /bin/bash "\$scanner" $3 "\$@"
EOF
  chmod 755 "$hook" || die "cannot make $hook executable"
  echo "secret-scan: $1 hook installed at $hook."
}
if [ "$MODE" = install ]; then
  [ -n "$COMMON" ] || die "not inside a git repository"
  if hooks_path=$(git -C "$TOP" config --get core.hooksPath); then
    echo "secret-scan: note — core.hooksPath is set ($hooks_path), so git does not run hooks from $COMMON/hooks." >&2
  fi
  HOOKS="$COMMON/hooks"
  mkdir -p "$HOOKS" || die "cannot create $HOOKS"
  # A copy of the scanner next to the hooks keeps every worktree covered, including branches without this script.
  { cp "$SCRIPT_DIR/secret-scan.sh" "$HOOKS/secret-scan.sh" && chmod 755 "$HOOKS/secret-scan.sh"; } ||
    die "cannot copy the scanner into $HOOKS"
  STATUS=0
  install_hook pre-commit "a commit" --staged || STATUS=1
  install_hook pre-merge-commit "a merge commit" --staged || STATUS=1
  install_hook pre-push "a push" --pre-push || STATUS=1
  [ $STATUS = 0 ] && echo "secret-scan: hooks are shared by every worktree of this repository."
  exit $STATUS
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

# ---------- scanning: every finding is one "location: NAME" line; matched text is never output ----------
report() { echo "$1: $2"; }
values_all() { local i=0; while [ $i -lt ${#V_VAL[@]} ]; do printf '%s\n' "${V_VAL[$i]}"; i=$((i + 1)); done; }
icase_flag() { [ "${V_ICASE[$1]}" = 1 ] && printf '%s' -i; }
mask_test_keys() { sed -E "s/$PUBLIC_TEST_KEYS/<public test key>/gI"; }
PATTERN_ARGS=(); i=0
while [ $i -lt ${#P_RE[@]} ]; do PATTERN_ARGS[${#PATTERN_ARGS[@]}]=-e; PATTERN_ARGS[${#PATTERN_ARGS[@]}]=${P_RE[$i]}; i=$((i + 1)); done

# Line numbers (only) where value/pattern i occurs in a file.
value_lines() { grep -naF $(icase_flag "$1") -f <(printf '%s\n' "${V_VAL[$1]}") -- "$2" 2>/dev/null | cut -d: -f1; }
pattern_lines() { grep -naE -e "${P_RE[$1]}" -- "$2" 2>/dev/null | mask_test_keys | grep -aE -e "${P_RE[$1]}" | cut -d: -f1; }
scan_file() {
  local i n
  i=0
  while [ $i -lt ${#V_VAL[@]} ]; do
    for n in $(value_lines $i "$1"); do report "$1:$n" "${V_LABEL[$i]}"; done
    i=$((i + 1))
  done
  i=0
  while [ $i -lt ${#P_RE[@]} ]; do
    for n in $(pattern_lines $i "$1"); do report "$1:$n" "${P_NAME[$i]}"; done
    i=$((i + 1))
  done
}

# File names that must never be committed, whatever they contain.
check_name() {
  case "$1" in
    .env.example|*/.env.example) ;;
    .env|.env.*|*/.env|*/.env.*) report "$1" "env file must not be committed" ;;
    Secrets.xcconfig|*/Secrets.xcconfig) report "$1" "Secrets.xcconfig must not be committed" ;;
    AuthKey_*.p8|*/AuthKey_*.p8) report "$1" "App Store Connect API key must not be committed" ;;
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
  local label=$1 name=$2 i
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
  if "$@" | unpack "$name" | grep -aE "${PATTERN_ARGS[@]}" | mask_test_keys | grep -qaE "${PATTERN_ARGS[@]}"; then
    i=0
    while [ $i -lt ${#P_RE[@]} ]; do
      "$@" | unpack "$name" | grep -aE -e "${P_RE[$i]}" | mask_test_keys | grep -qaE -e "${P_RE[$i]}" &&
        report "$label (inside the archive)" "${P_NAME[$i]}"
      i=$((i + 1))
    done
  fi
  return 0
}

# A fast pass lists the candidate files (NUL-separated); the per-file pass then attributes each hit to a name.
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
scan_lines() { # output of added_lines
  local i p n
  [ -n "$1" ] || return 0
  # One pass over everything first; the per-name passes below only run when something matched.
  if [ ${#V_VAL[@]} -gt 0 ] && printf '%s\n' "$1" | grep -qaiF -f <(values_all); then
    i=0
    while [ $i -lt ${#V_VAL[@]} ]; do
      while IFS=$'\t' read -r p n; do report "$p:$n" "${V_LABEL[$i]}"; done \
        < <(printf '%s\n' "$1" | grep -aF $(icase_flag $i) -f <(printf '%s\n' "${V_VAL[$i]}") | cut -f1,2)
      i=$((i + 1))
    done
  fi
  if printf '%s\n' "$1" | grep -qaE "${PATTERN_ARGS[@]}"; then
    i=0
    while [ $i -lt ${#P_RE[@]} ]; do
      while IFS=$'\t' read -r p n; do report "$p:$n" "${P_NAME[$i]}"; done \
        < <(printf '%s\n' "$1" | grep -aE -e "${P_RE[$i]}" | mask_test_keys | grep -aE -e "${P_RE[$i]}" | cut -f1,2)
      i=$((i + 1))
    done
  fi
}
scan_staged() {
  local p
  while IFS= read -r -d '' p; do
    check_name "$p"
    is_archive "$p" && scan_archive "$p" "$p" git cat-file blob ":$p"
  done < <(git diff --cached --name-only -z --diff-filter=ACMR)
  scan_lines "$(git diff --cached "${DIFF_OPTS[@]}" | added_lines)"
  return 0
}

# Commits being pushed. git writes "<local ref> <local sha> <remote ref> <remote sha>" per ref on stdin. Every commit
# no remote-tracking ref has yet is scanned patch by patch (a merge against its first parent), so a secret that was
# added and removed again inside the push is still caught — it would be in the pushed history.
commit_paths() { # sha — files the commit adds or changes (a merge: against its first parent), NUL-separated
  if git rev-parse -q --verify "$1^" >/dev/null; then git diff-tree -r --name-only -z --diff-filter=ACMR "$1^" "$1"
  else git diff-tree -r --root --no-commit-id --name-only -z --diff-filter=ACMR "$1"; fi
}
scan_pushed() {
  local refs lref lsha rref rsha c p
  refs=$(cat)
  while read -r lref lsha rref rsha; do
    case "$lsha" in *[!0]*) ;; *) continue ;; esac # a deleted ref pushes no commits
    git rev-parse -q --verify "$lsha^{commit}" >/dev/null || die "cannot read the pushed commit for $lref"
    set -- "$lsha" --not --remotes
    case "$rsha" in *[!0]*) git rev-parse -q --verify "$rsha^{commit}" >/dev/null && set -- "$@" "$rsha" ;; esac
    for c in $(git rev-list "$@"); do
      while IFS= read -r -d '' p; do
        check_name "$p"
        is_archive "$p" && scan_archive "$(git rev-parse --short "$c"):$p" "$p" git cat-file blob "$c:$p"
      done < <(commit_paths "$c")
    done
    scan_lines "$(git log -p --format='commit %h' --diff-merges=first-parent "${DIFF_OPTS[@]}" "$@" | added_lines)"
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
esac

if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
  echo "secret-scan: $(printf '%s\n' "$OUT" | wc -l | tr -d ' ') finding(s) in $WHAT — locations and names only, values are never printed." >&2
  echo "  Take the value out (keep it server-side or in an ignored env file) and rotate it if it was ever shared." >&2
  exit 1
fi
echo "secret-scan: clean — $WHAT (${#V_VAL[@]} secret value forms from ${SOURCES[*]:-no env files}, ${#P_RE[@]} patterns)." >&2
exit 0
