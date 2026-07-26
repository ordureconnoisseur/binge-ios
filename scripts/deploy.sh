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

# Target the device SDK directly rather than -destination
# 'generic/platform=iOS'. Xcode 26.5 on this machine refuses to resolve
# ANY iOS device destination ("iOS 26.5 is not installed"), because the
# downloadable iOS platform component is missing even though the device
# SDK itself is present and builds fine. Naming the SDK skips destination
# resolution entirely. It also avoids installing a simulator runtime we
# have no use for - binge only ever runs on the physical iPhone.
xcodebuild \
  -project binge.xcodeproj \
  -scheme binge \
  -configuration Debug \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build

# First reachable physical device; override with BINGE_DEVICE=<udid>.
# Wi-Fi devices report "available (paired)" rather than "connected", so take
# either; "unavailable" has to be filtered out first since it contains
# "available".
DEVICE="${BINGE_DEVICE:-$(xcrun devicectl list devices --hide-headers 2>/dev/null \
  | awk '!/unavailable/ && /connected|available/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-Fa-f-]{36}$/) { print $i; exit }}')}"
if [ -z "$DEVICE" ]; then
  echo "No connected iPhone found (is it awake and on the same network?)" >&2
  xcrun devicectl list devices >&2
  exit 1
fi

APP="$DERIVED/Build/Products/Debug-iphoneos/binge.app"
# iOS sometimes refuses to install OVER an existing copy when the
# signature/profile generation has moved on (ApplicationVerificationFailed).
# A clean install always works, so fall back to uninstall-then-install.
# Safe to automate: the Stash URL is mirrored into the Keychain and the
# API key already lives there, so both survive the wipe (KeychainStore).
# Other in-app settings (lookback, genders, toggles) DO reset.
#
# IMPORTANT: the iPhone must be UNLOCKED. iOS refuses to install an
# app's embedded provisioning profile on a locked device and reports
# it as "0xe8008012 / ApplicationVerificationFailed / this provisioning
# profile cannot be installed on this device" — which reads like a
# signing problem but is just the lock screen. Uninstall is NOT
# blocked by the lock, so never uninstall before a plain install has
# been given a fair chance, or a locked phone ends up with no app.
if ! xcrun devicectl device install app --device "$DEVICE" "$APP"; then
  echo "install failed - is the iPhone unlocked? retrying in 15s" >&2
  sleep 15
  if ! xcrun devicectl device install app --device "$DEVICE" "$APP"; then
    echo "still failing; falling back to a clean install" >&2
    xcrun devicectl device uninstall app --device "$DEVICE" "$BUNDLE_ID" || true
    if ! xcrun devicectl device install app --device "$DEVICE" "$APP"; then
      echo "" >&2
      echo "DEPLOY FAILED - binge is now UNINSTALLED from the device." >&2
      echo "Unlock the iPhone and re-run this script to restore it." >&2
      exit 1
    fi
  fi
fi
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
echo "Deployed $BUNDLE_ID to $DEVICE"
