#!/usr/bin/env bash
# Builds a Developer ID-signed, notarized and stapled Remora.app and zips it into dist/.
#
# Usage: scripts/release.sh <version> [build-number]
#
# Required environment:
#   DEVELOPMENT_TEAM   Apple team ID that owns the Developer ID Application certificate
#
# Notarization credentials, one of:
#   NOTARY_PROFILE     Name of a keychain profile saved with `xcrun notarytool store-credentials`
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH
#                      App Store Connect API key ID, issuer ID and path to the .p8 private key
#
# The Developer ID Application certificate must be in a keychain on this machine.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [build-number]}"
BUILD="${2:-1}"
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
  -destination "generic/platform=macOS" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

test -d "$APP" || { echo "archive did not produce $APP" >&2; exit 1; }

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
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo "==> Done: $ZIP"
