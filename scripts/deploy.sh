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

# First reachable iPhone; override with BINGE_DEVICE=<udid>.
#
# Resolved BEFORE the build, because the build needs it: see the
# -destination note below.
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

# Two different names for the same phone. devicectl speaks the CoreDevice
# identifier (a plain UUID); xcodebuild destinations and provisioning
# profiles speak the hardware UDID (00008130-...). Ask for the second.
UDID="$(xcrun devicectl device info details --device "$DEVICE" --timeout 20 2>/dev/null \
  | awk -F': ' '/udid:/ {gsub(/[^0-9A-Za-z-]/, "", $2); print $2; exit}')"
[ -n "$UDID" ] || { echo "could not read the phone's UDID" >&2; exit 1; }

# Build AGAINST THE PHONE, not just against the device SDK.
#
# This used to pass "-sdk iphoneos26.5" and no destination, because a
# generic 'generic/platform=iOS' destination does not resolve on this
# machine ("iOS 26.5 is not installed" - the downloadable iOS platform
# component is missing even though the device SDK builds fine). Naming a
# CONCRETE device resolves, and naming the SDK instead cost us the thing
# that actually matters: with no device in the build, -allowProvisioningUpdates
# has nothing to register, so it mints a profile covering whatever devices
# the team already had. When the phone fell off that list the profiles kept
# being made for the iPad alone, and iOS refused every install with
# 0xe8008012, which this script then misreported as a locked phone for a
# week. With the phone named, Xcode registers it and the profile contains
# it.
echo "Building for $UDID"
xcodebuild \
  -project binge.xcodeproj \
  -scheme binge \
  -configuration Debug \
  -destination "platform=iOS,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build

APP="$DERIVED/Build/Products/Debug-iphoneos/binge.app"

# Two install failure modes must be told apart, because only one of them
# may ever reach the uninstall fallback:
#
#   LOCKED PHONE - iOS cannot mount the developer disk image on a locked
#   device, and reports kAMDMobileImageMounterDeviceLocked / 0xe80000e2.
#   Uninstall is NOT blocked by the lock, so letting this fall through
#   strands a locked phone with no app at all - which is exactly what
#   happened on 2026-07-26. Detect it and bail out with the installed
#   copy untouched.
#
#   0xe8008012 (ApplicationVerificationFailed) is NOT on that list any
#   more. It is genuinely ambiguous: a locked phone can produce it, and so
#   can a profile that does not cover this device. Treating it as a lock
#   on sight meant a week of deploys reporting "the iPhone is LOCKED" at
#   an unlocked phone while the real fault, a profile built for the iPad,
#   went unread. When it appears, ask the phone whether it is locked
#   instead of assuming.
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
  locked=""
  if printf '%s' "$INSTALL_OUT" \
    | grep -qiE 'DeviceLocked|0xe80000e2|device is locked'; then
    locked=yes
  elif printf '%s' "$INSTALL_OUT" | grep -qi '0xe8008012'; then
    # Ambiguous. The phone knows which it is.
    if xcrun devicectl device info lockState --device "$DEVICE" --timeout 20 2>/dev/null \
      | grep -qi 'passcodeRequired: true'; then
      locked=yes
    else
      echo "" >&2
      echo "iOS refused the app (0xe8008012) and the phone is NOT locked." >&2
      echo "That leaves the provisioning profile: check the phone's UDID is" >&2
      echo "in it, with" >&2
      echo "  security cms -D -i <profile>.mobileprovision | grep -A5 ProvisionedDevices" >&2
      echo "This phone is $UDID." >&2
      echo "binge is still installed and untouched on the device." >&2
      exit 1
    fi
  fi
  if [ -n "$locked" ]; then
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
