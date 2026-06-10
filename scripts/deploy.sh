#!/bin/bash
# Build binge and install it on the connected iPhone over Wi-Fi.
# Runs on the Mac build server: pull, regenerate project, build,
# then install + launch via devicectl (no cable needed after the
# one-time USB pairing).
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.ordureconnoisseur.binge"
DERIVED="$REPO/build/DerivedData"

cd "$REPO"
git pull --ff-only
xcodegen generate

xcodebuild \
  -project binge.xcodeproj \
  -scheme binge \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build

# First connected physical device; override with BINGE_DEVICE=<udid>
DEVICE="${BINGE_DEVICE:-$(xcrun devicectl list devices --hide-headers 2>/dev/null \
  | awk '/connected/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-Fa-f-]{36}$/) { print $i; exit }}')}"
if [ -z "$DEVICE" ]; then
  echo "No connected iPhone found (is it awake and on the same network?)" >&2
  xcrun devicectl list devices >&2
  exit 1
fi

APP="$DERIVED/Build/Products/Debug-iphoneos/binge.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
echo "Deployed $BUNDLE_ID to $DEVICE"
