#!/bin/bash
# Forbidden-path guard. Fails when a path that must never be in this repository is tracked, staged or pushed: env
# files, key and signing material, build products, local AI-session settings, and internal documents (audit reports,
# security reviews, runbooks, handoffs), which belong in the private DyorHQ/internal repository. Prints paths and the
# matching pattern only, never file contents.
#
#   scripts/dev/forbidden-paths.sh                    # every tracked path (CI)
#   scripts/dev/forbidden-paths.sh --staged           # paths a commit would add or change (pre-commit hook)
#   scripts/dev/forbidden-paths.sh --pre-push         # paths added or changed by the commits being pushed (pre-push)
#   scripts/dev/forbidden-paths.sh --history [REV…]   # paths added or changed by the commits `git log REV…` lists
#                                                     # (default: --all), e.g. origin/main..HEAD in CI
#   scripts/dev/forbidden-paths.sh --check PATH…      # the given paths (no git needed)
#   --config FILE                                     # patterns from FILE instead of <repo>/.leakguard
#   --repo DIR                                        # run in another repository
#
# Patterns: the built-in secret-material list below, then the repository's .leakguard (see its header). One glob per
# line; "!glob" exempts paths that a deny glob matched. A glob without "/" matches the file name at any depth, a glob
# with "/" matches the whole path from the repository root; "*" also matches "/", and matching ignores case. A path is
# forbidden when a deny glob matches it and no "!" glob does.
# Exit status: 0 clean, 1 forbidden paths, 2 usage or setup error. Runs on macOS /bin/bash 3.2.
set +x
export LC_ALL=C

# Secret material, forbidden in every repository whatever its .leakguard says (a .leakguard "!" line can still exempt
# one path, e.g. a public test certificate).
BUILTIN_DENY=(
  .env '.env.*' '*.env' .dev.vars '.dev.vars.*' Secrets.xcconfig
  '*.p8' '*.p12' '*.pfx' '*.pem' '*.key' '*.mobileprovision' '*.provisionprofile' '*.keystore' '*.jks' '*.kdbx'
  id_rsa id_dsa id_ecdsa id_ed25519 '.claude/settings.local.json' '*/.claude/settings.local.json' '.claude/*.local.*'
  '*.xcarchive/*' '*.ipa'
)
BUILTIN_ALLOW=(.env.example '*.env.example')

usage() { sed -n '7,15p' "$0" | sed 's/^# //' >&2; exit 2; }
die() { echo "forbidden-paths: $*" >&2; exit 2; }

MODE=tracked; CONFIG=; REPO=; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --tracked) MODE=tracked ;;
    --staged) MODE=staged ;;
    --pre-push) MODE=push; break ;; # git passes the remote's name and URL after it; the refs come on stdin
    --history) MODE=history; shift; ARGS=("$@"); break ;;
    --check) MODE=check; shift; ARGS=("$@"); break ;;
    --config) [ $# -ge 2 ] || usage; CONFIG=$2; shift ;;
    --repo) [ $# -ge 2 ] || usage; REPO=$2; shift ;;
    *) usage ;;
  esac
  shift
done
[ "$MODE" = history ] && [ ${#ARGS[@]} -eq 0 ] && ARGS=(--all)

TOP=
if [ "$MODE" != check ] || [ -z "$CONFIG" ]; then
  TOP=$(git -C "${REPO:-.}" rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  cd "$TOP" || die "cannot enter $TOP"
fi
[ -n "$CONFIG" ] || CONFIG="$TOP/.leakguard"

DENY=("${BUILTIN_DENY[@]}"); ALLOW=("${BUILTIN_ALLOW[@]}")
if [ -f "$CONFIG" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      ''|'#'*) ;;
      '!'*) line=${line#!}; ALLOW[${#ALLOW[@]}]=${line#/} ;;
      *) DENY[${#DENY[@]}]=${line#/} ;;
    esac
  done < "$CONFIG"
else
  echo "forbidden-paths: warning — no ${CONFIG##*/} found; only the built-in secret-file list is checked." >&2
fi

shopt -s nocasematch
matches() { # path glob — a glob with "/" matches the whole path, one without matches the file name
  case "$2" in
    */*) [[ $1 == $2 ]] ;;
    *) [[ ${1##*/} == $2 ]] ;;
  esac
}
check_path() { # path [label] — prints a finding when the path is forbidden
  local g hit=
  for g in "${DENY[@]}"; do
    if matches "$1" "$g"; then hit=$g; break; fi
  done
  [ -n "$hit" ] || return 0
  for g in "${ALLOW[@]}"; do matches "$1" "$g" && return 0; done
  echo "${2:-$1}: forbidden path (matches \"$hit\")"
}

commit_paths() { # sha — files the commit adds or changes (a merge: against its first parent), NUL-separated
  if git rev-parse -q --verify "$1^" >/dev/null; then git diff-tree -r --name-only -z --diff-filter=ACMR "$1^" "$1"
  else git diff-tree -r --root --no-commit-id --name-only -z --diff-filter=ACMR "$1"; fi
}
check_commits() { # git-log revision arguments
  local c s p
  for c in $(git rev-list "$@"); do
    s=$(git rev-parse --short "$c")
    while IFS= read -r -d '' p; do check_path "$p" "$s:$p"; done < <(commit_paths "$c")
  done
}
# The same refs protocol as scripts/dev/secret-scan.sh --pre-push: every commit no remote-tracking ref has yet.
check_pushed() {
  local refs lref lsha rref rsha
  refs=$(cat)
  while read -r lref lsha rref rsha; do
    case "$lsha" in *[!0]*) ;; *) continue ;; esac # a deleted ref pushes no commits
    git rev-parse -q --verify "$lsha^{commit}" >/dev/null || die "cannot read the pushed commit for $lref"
    set -- "$lsha" --not --remotes
    case "$rsha" in *[!0]*) git rev-parse -q --verify "$rsha^{commit}" >/dev/null && set -- "$@" "$rsha" ;; esac
    check_commits "$@"
  done <<REFS
$refs
REFS
}

case "$MODE" in
  tracked)
    WHAT="tracked paths"
    OUT=$(git ls-files -z | while IFS= read -r -d '' p; do check_path "$p"; done) ;;
  staged)
    WHAT="staged changes"
    OUT=$(git diff --cached --name-only -z --diff-filter=ACMR | while IFS= read -r -d '' p; do check_path "$p"; done) ;;
  push)
    WHAT="commits being pushed"
    OUT=$(check_pushed) || exit 2 ;;
  history)
    git rev-list -n 1 "${ARGS[@]}" >/dev/null 2>&1 || die "git log cannot read the revisions: ${ARGS[*]}"
    WHAT="commits of git log ${ARGS[*]}"
    OUT=$(check_commits "${ARGS[@]}") ;;
  check)
    WHAT="the given paths"
    OUT=$(for p in "${ARGS[@]}"; do check_path "$p"; done) ;;
esac

if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
  echo "forbidden-paths: $(printf '%s\n' "$OUT" | wc -l | tr -d ' ') forbidden path(s) in $WHAT." >&2
  echo "  Secrets stay in git-ignored files or a secret store; internal documents go to the private DyorHQ/internal" >&2
  echo "  repository. Unstage with: git rm --cached <path>. A path that is truly fine gets a \"!\" line in .leakguard." >&2
  exit 1
fi
echo "forbidden-paths: clean — $WHAT (${#DENY[@]} patterns, ${#ALLOW[@]} exceptions)." >&2
exit 0
