#!/bin/zsh
# Xcode Cloud runs this after each xcodebuild action. For an archive it is the SECURITY GATE of scripts/testflight.sh:
# a cloud archive goes to TestFlight without ever running that script, so the same checks run here, and a non-zero
# exit fails the archive action before its TestFlight post-action can distribute the build. The values come from the
# Secrets.xcconfig that ci_post_clone.sh writes from the workflow's environment variables (a cloud clone has no .env).
# Checked anywhere in the .xcarchive and the App Store export: every non-public Secrets.xcconfig value, keyed
# RPC-provider URLs and private-key patterns (scripts/dev/secret-scan.sh, which prints names only, never values).
# Before that, the v2 wiring gate: an archive is refused while DyorKit's v2 launchpad or Moments addresses are still
# PENDING (scripts/dev/check-launchpad-addresses.py --release), so no build ships with Launch and Publish "not live yet".
set -euo pipefail
set +x # never trace: the scanner holds secret values in variables
[[ ${CI_XCODEBUILD_ACTION:-} == archive ]] || exit 0
cd "$(dirname "$0")/.."

WIRING=../scripts/dev/check-launchpad-addresses.py
if [[ ! -f $WIRING ]] || ! command -v python3 >/dev/null; then
  echo "error: $WIRING (or python3) is missing, so the v2 contract wiring cannot be checked; refusing to ship." >&2
  exit 1
fi
if ! python3 "$WIRING" --release >&2; then
  echo "error: REFUSING TO SHIP — the v2 contract addresses are not wired or do not match contracts/deployments (above)." >&2
  exit 1
fi

ARCHIVE=${CI_ARCHIVE_PATH:-}
if [[ -z $ARCHIVE || ! -d $ARCHIVE ]]; then
  echo "error: CI_ARCHIVE_PATH does not name an archive, so it cannot be checked for secrets; refusing to ship it." >&2
  exit 1
fi
SCANNER=../scripts/dev/secret-scan.sh
[[ -f $SCANNER ]] || { echo "error: $SCANNER is missing; refusing to ship an unchecked archive." >&2; exit 1; }

LEAKS=()
if grep -rqE 'alchemy\.com/v2/[A-Za-z0-9_-]|infura\.io/v3/[0-9a-f]|quiknode\.pro/[0-9a-f]' "$ARCHIVE"; then LEAKS+=("keyed RPC provider URL"); fi
# The .ipa of the App Store export, when this action exported one, is unpacked and checked too.
for target in "$ARCHIVE" ${CI_APP_STORE_SIGNED_APP_PATH:-}; do
  [[ -e $target ]] || continue
  if ! env -u SECRET_SCAN_ENV -u SECRET_SCAN_XCCONFIG -u BASH_ENV -u SHELLOPTS /bin/bash "$SCANNER" --path "$target" >&2; then
    LEAKS+=("secret values or key patterns listed above by secret-scan (${target:t})")
  fi
done
if (( ${#LEAKS[@]} )); then
  echo "error: REFUSING TO SHIP — the archive contains: ${LEAKS[*]}" >&2
  echo "Keep secrets server-side (see the notes in project.yml); do not add secret values to the Xcode Cloud workflow." >&2
  exit 1
fi
echo "Security gate: no secrets found in the archive ✓"
