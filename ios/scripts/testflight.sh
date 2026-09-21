#!/bin/zsh
# Archive DyorHQ for the App Store and upload the build to TestFlight from the command line.
#
# Needs: a paid Apple Developer Program membership, DEVELOPMENT_TEAM in DyorHQ/Config/Secrets.xcconfig, an app
# record for fun.dyorhq.app in App Store Connect, and either an App Store Connect API key (recommended, see below)
# or Xcode signed in to the account (Xcode → Settings → Accounts).
#
#   scripts/testflight.sh                 # archive + upload with the Xcode account
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=~/.private_keys/AuthKey_XXXX.p8 scripts/testflight.sh
#
# Create the API key at App Store Connect → Users and Access → Integrations → App Store Connect API (role: App
# Manager). The .p8 file downloads once; keep it outside the repo.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' DyorHQ/Config/Secrets.xcconfig | tr -d ' ')
if [[ -z "$TEAM" ]]; then echo "DEVELOPMENT_TEAM is not set in DyorHQ/Config/Secrets.xcconfig" >&2; exit 1; fi
if grep -q "127.0.0.1" DyorHQ/Config/Secrets.xcconfig; then echo "Secrets.xcconfig points at a local fork; restore the mainnet RPC first" >&2; exit 1; fi

# Bump the build number so every upload is unique — App Store Connect rejects a duplicate CFBundleVersion, which is
# the most common first-timer failure. Pin an exact number with BUILD=<n>; keep the current one with NO_BUMP=1.
VERSION=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
CURRENT_BUILD=$(sed -n 's/.*CFBundleVersion: "\(.*\)"/\1/p' project.yml)
if [[ -n "${BUILD:-}" ]]; then NEW_BUILD="$BUILD"
elif [[ -n "${NO_BUMP:-}" ]]; then NEW_BUILD="$CURRENT_BUILD"
else NEW_BUILD=$(( CURRENT_BUILD + 1 )); fi
if [[ "$NEW_BUILD" != "$CURRENT_BUILD" ]]; then
  sed -i '' "s/CFBundleVersion: \"$CURRENT_BUILD\"/CFBundleVersion: \"$NEW_BUILD\"/" project.yml
  echo "Build number: $CURRENT_BUILD → $NEW_BUILD (project.yml updated — commit it with the release)."
fi
BUILD="$NEW_BUILD"
echo "DyorHQ $VERSION ($BUILD) · team $TEAM"

xcodegen generate >/dev/null
ARCHIVE=build/DyorHQ-$VERSION-$BUILD.xcarchive
rm -rf "$ARCHIVE"
xcodebuild -project DyorHQ.xcodeproj -scheme DyorHQ -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -derivedDataPath DerivedDataDevice \
  -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

OPTIONS=build/ExportOptions-$BUILD.plist
sed "s/TEAM_ID/$TEAM/" ExportOptions.plist > "$OPTIONS"
AUTH=()
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "build/export-$BUILD" \
  -allowProvisioningUpdates "${AUTH[@]}" | grep -E "error:|EXPORT (SUCCEEDED|FAILED)|Upload"
echo "Uploaded. It appears under TestFlight in App Store Connect after processing (a few minutes); answer the export"
echo "compliance question there (standard encryption only) and add the build to a tester group."
echo "Next build: bump CFBundleVersion in project.yml before running this again."
