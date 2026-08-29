#!/bin/bash
# Build binge and install it on the connected iPhone over Wi-Fi.
# Runs on the Mac build server: pull, regenerate project, build,
# then install + launch via devicectl (no cable needed after the
# one-time USB pairing).
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$REPO/build/DerivedData"

cd "$REPO"
git pull --ff-only

# After the pull, not before. Read from project.yml rather than
# hardcoded, so the install and the launch cannot disagree - they did
# once: the id changed to bingeios, the app installed correctly under
# the new one, and the launch still used the old one, reported as
# "invalid code signature", which sent the diagnosis somewhere it had
# no business going. Reading it before the pull reintroduces the same
# bug one run later, because the value would come from the previous
# commit's project.yml while the build uses this one's.
BUNDLE_ID="$(awk '/PRODUCT_BUNDLE_IDENTIFIER:/ {print $2; exit}' "$REPO/project.yml")"
[ -n "$BUNDLE_ID" ] || { echo "no PRODUCT_BUNDLE_IDENTIFIER in project.yml" >&2; exit 1; }
echo "bundle id: $BUNDLE_ID"
xcodegen generate

# Target the device SDK directly rather than -destination
# 'generic/platform=iOS'. Xcode 26.5 on this machine refuses to resolve
# ANY iOS device destination ("iOS 26.5 is not installed"), because the
# downloadable iOS platform component is missing even though the device
# SDK itself is present and builds fine. Naming the SDK skips destination
# resolution. It also avoids -downloadPlatform iOS, which would pull a
# simulator runtime we have no use for - binge only runs on the iPhone.
#
# The SDK must be named with its VERSION. Bare "-sdk iphoneos" still dies
# with "Found no destinations for the scheme", even though it resolves
# SDKROOT to the same iphoneos26.5; only the fully-qualified form builds.
# Resolve the newest installed one rather than hardcoding, so an Xcode
# update doesn't silently break this again.
IOS_SDK="$(xcodebuild -showsdks 2>/dev/null \
  | awk '/-sdk iphoneos[0-9]/ {sdk = $NF} END {print sdk}')"
if [ -z "$IOS_SDK" ]; then
  echo "No iphoneos SDK found in: xcodebuild -showsdks" >&2
  exit 1
fi
echo "Building against SDK $IOS_SDK"

xcodebuild \
  -project binge.xcodeproj \
  -scheme binge \
  -configuration Debug \
  -sdk "$IOS_SDK" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build

# First reachable iPhone; override with BINGE_DEVICE=<udid>.
#
# Wi-Fi devices report "available (paired)" rather than "connected", so take
# either; "unavailable" has to be filtered out first since it contains
# "available".
#
# The /iPhone/ term is load-bearing. Accepting "available" (fb22e6c) also
# made the paired iPad eligible, and devicectl lists it FIRST, so the
# picker silently switched targets: every deploy went at a locked iPad and
# failed with kAMDMobileImageMounterDeviceLocked while the iPhone sat
# unlocked and untouched. Matching on iPhone keeps this honest without
# hardcoding a UDID that a phone upgrade would invalidate.
DEVICE="${BINGE_DEVICE:-$(xcrun devicectl list devices --hide-headers 2>/dev/null \
  | awk '!/unavailable/ && /connected|available/ && /iPhone/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-Fa-f-]{36}$/) { print $i; exit }}')}"
if [ -z "$DEVICE" ]; then
  echo "No reachable iPhone found (is it awake and on the same network?)" >&2
  xcrun devicectl list devices >&2
  exit 1
fi
echo "Deploying to device $DEVICE"

APP="$DERIVED/Build/Products/Debug-iphoneos/binge.app"

# Two install failure modes must be told apart, because only one of them
# may ever reach the uninstall fallback:
#
#   LOCKED PHONE - iOS cannot mount the developer disk image on a locked
#   device, and reports kAMDMobileImageMounterDeviceLocked / 0xe80000e2
#   (older/other paths surface the same lock as 0xe8008012
#   ApplicationVerificationFailed, which reads like a signing problem but
#   is just the lock screen). Uninstall is NOT blocked by the lock, so
#   letting this fall through strands a locked phone with no app at all -
#   which is exactly what happened on 2026-07-26. Detect it and bail out
#   with the installed copy untouched.
#
#   STALE SIGNATURE - iOS sometimes refuses to install OVER an existing
#   copy once the profile generation has moved on. A clean install always
#   works, so uninstall and retry. Safe to automate: the Stash URL is
#   mirrored into the Keychain and the API key already lives there, so
#   both survive the wipe (KeychainStore). Other in-app settings
#   (lookback, genders, toggles) DO reset.
install_app() {
  set +e
  INSTALL_OUT="$(xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1)"
  INSTALL_RC=$?
  set -e
  printf '%s\n' "$INSTALL_OUT"
  return "$INSTALL_RC"
}

# Never destructive: call after every failed install, before any fallback.
abort_if_locked() {
  if printf '%s' "$INSTALL_OUT" \
    | grep -qiE 'DeviceLocked|0xe80000e2|0xe8008012|device is locked'; then
    echo "" >&2
    echo "The iPhone is LOCKED - iOS will not mount the developer disk image." >&2
    echo "binge is still installed and untouched on the device." >&2
    echo "Unlock the phone, keep it awake, then re-run this script." >&2
    exit 1
  fi
}

if ! install_app; then
  abort_if_locked
  echo "install failed - retrying in 15s" >&2
  sleep 15
  if ! install_app; then
    abort_if_locked
    echo "still failing; falling back to a clean install" >&2
    xcrun devicectl device uninstall app --device "$DEVICE" "$BUNDLE_ID" || true
    if ! install_app; then
      abort_if_locked
      echo "" >&2
      echo "DEPLOY FAILED - binge is now UNINSTALLED from the device." >&2
      echo "Unlock the iPhone and re-run this script to restore it." >&2
      exit 1
    fi
  fi
fi
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
echo "Deployed $BUNDLE_ID to $DEVICE"
