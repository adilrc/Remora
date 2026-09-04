#!/usr/bin/env bash
# Builds a Developer ID-signed, notarized and stapled Remora.app, zips it into dist/, and
# signs the zip for Sparkle, adding it to appcast.xml at the repository root.
#
# Usage: scripts/release.sh <version> [build-number]
#
# Afterwards: create the GitHub Release with dist/Remora-<version>.zip attached first, then
# commit and push appcast.xml. Pushing the appcast before the asset exists breaks updates.
#
# Required environment:
#   DEVELOPMENT_TEAM   Apple team ID that owns the Developer ID Application certificate
#
# Notarization credentials, one of:
#   NOTARY_PROFILE     Name of a keychain profile saved with `xcrun notarytool store-credentials`
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH
#                      App Store Connect API key ID, issuer ID and path to the .p8 private key
#
# Sparkle signing key, one of:
#   (nothing)                  The EdDSA private key saved in the login keychain by Sparkle's generate_keys
#   SPARKLE_PRIVATE_KEY_FILE   Path to a file holding the private key (as exported by generate_keys -x)
#
# The Developer ID Application certificate must be in a keychain on this machine.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [build-number]}"
# Sparkle decides "is this newer?" by CFBundleVersion, so it must grow with every release. The
# commit count on the branch does that by itself; CI passes its run number instead.
BUILD="${2:-$(git -C "$(dirname "$0")/.." rev-list --count HEAD)}"
: "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM is required}"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
else
  : "${NOTARY_KEY_ID:?NOTARY_PROFILE or NOTARY_KEY_ID is required}"
  : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"
  : "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH is required}"
  NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
DERIVED="$DIST/DerivedData"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
ARCHIVE="$DIST/Remora.xcarchive"
APP="$ARCHIVE/Products/Applications/Remora.app"
ZIP="$DIST/Remora-$VERSION.zip"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Generating project"
xcodegen generate --spec "$ROOT/project.yml" --quiet

echo "==> Archiving Remora $VERSION ($BUILD)"
xcodebuild archive \
  -project "$ROOT/Remora.xcodeproj" \
  -scheme Remora \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  -destination "generic/platform=macOS" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

test -d "$APP" || { echo "archive did not produce $APP" >&2; exit 1; }

echo "==> Re-signing Sparkle helpers"
"$ROOT/scripts/resign-sparkle.sh" "$APP" "$DEVELOPMENT_TEAM"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarizing"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait

echo "==> Stapling"
xcrun stapler staple "$APP"
spctl --assess --type exec --verbose=2 "$APP"

echo "==> Packaging"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" | tee "$(basename "$ZIP").sha256")

echo "==> Updating appcast"
# generate_appcast reads every archive in the directory it is given, so it gets a folder with only
# this release's zip. It signs the zip with the EdDSA key and merges the item into the existing feed.
FEED_DIR="$DIST/appcast"
mkdir -p "$FEED_DIR"
ln "$ZIP" "$FEED_DIR/"
APPCAST_ARGS=(
  --download-url-prefix "https://github.com/adilrc/Remora/releases/download/v$VERSION/"
  --link "https://github.com/adilrc/Remora/releases/tag/v$VERSION"
  -o "$ROOT/appcast.xml"
)
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  APPCAST_ARGS+=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
fi
"$SPARKLE_BIN/generate_appcast" "${APPCAST_ARGS[@]}" "$FEED_DIR"

echo "==> Done: $ZIP"
echo "    appcast.xml updated; commit and push it after the GitHub Release is published."
