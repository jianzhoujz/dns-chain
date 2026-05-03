#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-DNS Chain}"
EXECUTABLE_NAME="DNSChain"
DEST_APP="/Applications/$APP_NAME.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.dns-chain.launch.plist"

pgrep -x "$EXECUTABLE_NAME" | xargs -r kill
sleep 1
pgrep -x "$EXECUTABLE_NAME" | xargs -r kill -9
rm -f "$AGENT_PLIST"
rm -rf "$DEST_APP"

echo "Removed: $DEST_APP"
echo "Removed LaunchAgent: $AGENT_PLIST"
