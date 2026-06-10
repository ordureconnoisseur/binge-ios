#!/bin/bash
# Trigger a build + install-to-iPhone on the mini build server and wait
# for the result. The build runs via the com.binge.deploy LaunchAgent
# (GUI session) because codesign needs the unlocked login keychain;
# see scripts/com.binge.deploy.plist.
#
# Usage: scripts/deploy-from-pc.sh   (after committing + pushing changes)
set -euo pipefail

ssh mini '
LOG=~/Projects/binge-ios/build/deploy.log
rm -f "$LOG"
launchctl kickstart "gui/$(id -u)/com.binge.deploy" || {
  echo "agent not loaded; bootstrapping" >&2
  cp ~/Projects/binge-ios/scripts/com.binge.deploy.plist ~/Library/LaunchAgents/
  launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.binge.deploy.plist
  launchctl kickstart "gui/$(id -u)/com.binge.deploy"
}
n=0
until grep -q DEPLOY_EXIT "$LOG" 2>/dev/null; do
  sleep 2
  n=$((n + 2))
  if [ "$n" -ge 900 ]; then echo "deploy timed out after ${n}s" >&2; exit 124; fi
done
tail -6 "$LOG"
code=$(grep -o "DEPLOY_EXIT:[0-9]*" "$LOG" | cut -d: -f2)
exit "$code"'
