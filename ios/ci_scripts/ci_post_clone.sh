#!/bin/zsh
# Xcode Cloud runs this right after cloning, before it resolves packages or builds. It looks for ci_scripts/ next to
# the project it builds (ios/DyorHQ.xcodeproj). That project is generated from project.yml by XcodeGen and git-ignored,
# so a cloud checkout has none until this script creates it — without it every build stops at
# "Project DyorHQ.xcodeproj does not exist at ios/DyorHQ.xcodeproj". It also writes the git-ignored Secrets.xcconfig
# from the workflow's environment variables and installs the pinned Package.resolved, which Xcode Cloud needs because
# it builds with automatic package resolution disabled.
#
# Workflow environment variables (App Store Connect → Xcode Cloud → Manage Workflows → the workflow → Environment;
# tick Secret on each, enter plain values without quotes):
#   PRIVY_APP_ID, PRIVY_CLIENT_ID   sign-in and the embedded wallet — an archive fails without them, since sign-up
#                                   needs Privy and a build without it can't onboard anyone
#   AURORA_API_KEY                  the Bridge (without it the button explains why)
#   optional: MONAD_RPC_URL PASSKEY_RP_ID PERPL_BUILDER_ID AURORA_FEE_RECIPIENT SOCIAL_LOGINS_ENABLED PASSKEYS_ENABLED
# Any other missing value degrades its feature exactly as in a local build (see AppConfig).
set -euo pipefail
cd "$(dirname "$0")/.."

# XcodeGen, pinned to the release the project is generated with locally and checked against its published digest.
XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
TOOLS=${TMPDIR:-/tmp}/xcodegen-$XCODEGEN_VERSION
XCODEGEN=$TOOLS/xcodegen/bin/xcodegen
if [[ ! -x $XCODEGEN || ! -d $TOOLS/xcodegen/share/xcodegen/SettingPresets ]]; then
  rm -rf "$TOOLS" && mkdir -p "$TOOLS"
  curl -fsSL --retry 3 -o "$TOOLS/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
  echo "$XCODEGEN_SHA256  $TOOLS/xcodegen.zip" | shasum -a 256 -c - >/dev/null
  unzip -q "$TOOLS/xcodegen.zip" -d "$TOOLS"
fi

# Secrets.xcconfig from the environment. A local checkout keeps its own file. Values are never echoed.
SECRETS=DyorHQ/Config/Secrets.xcconfig
if [[ -f $SECRETS ]]; then
  echo "Keeping the existing $SECRETS."
else
  missing=()
  for key in PRIVY_APP_ID PRIVY_CLIENT_ID; do [[ -n ${(P)key:-} ]] || missing+=($key); done
  if (( ${#missing} )) && [[ ${CI_XCODE_CLOUD:-} == TRUE && ${CI_XCODEBUILD_ACTION:-archive} == archive ]]; then
    echo "error: ${missing[*]} not set in the workflow environment; an archive without Privy can't sign anyone up." >&2
    exit 1
  fi
  [[ -n ${AURORA_API_KEY:-} ]] || echo "warning: AURORA_API_KEY is not set in the workflow environment; the Bridge is off."
  : ${DEVELOPMENT_TEAM:=${CI_TEAM_ID:-}}
  {
    echo "// Written by ci_scripts/ci_post_clone.sh from the Xcode Cloud workflow's environment variables."
    echo "// xcconfig reads // as the start of a comment, so URLs spell it /\$(DYOR_SLASH)."
    echo "DYOR_SLASH = /"
    for key in PRIVY_APP_ID PRIVY_CLIENT_ID MONAD_RPC_URL PASSKEY_RP_ID PERPL_BUILDER_ID DEVELOPMENT_TEAM \
               AURORA_API_KEY AURORA_FEE_RECIPIENT SOCIAL_LOGINS_ENABLED PASSKEYS_ENABLED; do
      value=${(P)key:-}
      value=${value//[$'\r\n']/}   # a stray newline in a pasted value would start a new xcconfig line
      print -r -- "$key = $(print -r -- "$value" | sed 's#//#/$(DYOR_SLASH)#g')"
    done
  } > $SECRETS
fi

# XcodeGen refuses to run without USER ("Couldn't find current username"); keep it set in a stripped environment.
USER=${USER:-$(id -un)} "$XCODEGEN" generate --spec project.yml --quiet

# Xcode Cloud never resolves packages itself, so the pins have to be inside the generated project. Refresh
# ios/Package.resolved with scripts/pin-packages.sh whenever a package requirement changes.
RESOLVED=DyorHQ.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
mkdir -p ${RESOLVED:h}
cp Package.resolved $RESOLVED
echo "Generated DyorHQ.xcodeproj with XcodeGen $XCODEGEN_VERSION and pinned its packages."
