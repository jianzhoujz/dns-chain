#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-DNSChain}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-Google Chrome}"
DEST_APP="/Applications/$APP_NAME.app"
BUILD_APP="$(cd "$(dirname "$0")" && pwd)/build/$APP_NAME.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.dns-chain.launch.plist"

pgrep -f "$DEST_APP/Contents/MacOS/$EXECUTABLE_NAME" | xargs -r kill
pgrep -f "$BUILD_APP/Contents/MacOS/$EXECUTABLE_NAME" | xargs -r kill
pgrep -f "$DEST_APP/Contents/MacOS/Chromium" | xargs -r kill
pgrep -f "$BUILD_APP/Contents/MacOS/Chromium" | xargs -r kill
sleep 1
pgrep -f "$DEST_APP/Contents/MacOS/$EXECUTABLE_NAME" | xargs -r kill -9
pgrep -f "$BUILD_APP/Contents/MacOS/$EXECUTABLE_NAME" | xargs -r kill -9
pgrep -f "$DEST_APP/Contents/MacOS/Chromium" | xargs -r kill -9
pgrep -f "$BUILD_APP/Contents/MacOS/Chromium" | xargs -r kill -9
rm -f "$AGENT_PLIST"
rm -rf "$DEST_APP"

echo "Removed: $DEST_APP"
echo "Removed LaunchAgent: $AGENT_PLIST"
