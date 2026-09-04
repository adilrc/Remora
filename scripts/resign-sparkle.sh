#!/usr/bin/env bash
# Re-signs the helpers inside the embedded Sparkle framework, then the app, with a Developer ID
# identity, hardened runtime and a secure timestamp.
#
# Sparkle's binary distribution ships these helpers signed by the Sparkle project. Xcode re-signs
# the framework itself when embedding it but leaves the nested code alone, and notarization
# rejects anything not signed by the submitting team.
#
# Usage: scripts/resign-sparkle.sh <path/to/App.app> <team-id>
set -euo pipefail

APP="${1:?usage: scripts/resign-sparkle.sh <App.app> <team-id>}"
TEAM="${2:?usage: scripts/resign-sparkle.sh <App.app> <team-id>}"

IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM)" | head -1 | awk '{print $2}')"
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application certificate for team $TEAM in the keychain" >&2; exit 1; }

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo "no Sparkle.framework inside $APP" >&2; exit 1; }
VERSIONED="$SPARKLE/Versions/B"

# Apple's timestamp service occasionally fails to answer; a retry is cheaper than a failed release.
sign() {
  local attempt
  for attempt in 1 2 3; do
    if codesign --force --sign "$IDENTITY" --options runtime --timestamp --preserve-metadata=entitlements "$@"; then
      return 0
    fi
    echo "codesign failed for $1 (attempt $attempt of 3), retrying" >&2
    sleep 5
  done
  return 1
}

# Innermost first: the XPC services keep their sandbox entitlements, then the helpers, then the
# framework, then the app that seals them all.
sign "$VERSIONED/XPCServices/Installer.xpc"
sign "$VERSIONED/XPCServices/Downloader.xpc"
sign "$VERSIONED/Autoupdate"
sign "$VERSIONED/Updater.app"
sign "$SPARKLE"
sign "$APP"

codesign --verify --deep --strict --verbose=1 "$APP"
