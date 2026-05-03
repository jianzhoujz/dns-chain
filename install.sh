#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="${APP_NAME:-DNS Chain}"
EXECUTABLE_NAME="DNSChain"
DEST_APP="/Applications/$APP_NAME.app"
BUILD_APP="$ROOT/build/$APP_NAME.app"

stop_running_app() {
  pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
  pkill -f "$DEST_APP/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null 2>&1 || true
  pkill -f "$BUILD_APP/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null 2>&1 || true
  pkill -f "$ROOT/.build/.*/$EXECUTABLE_NAME" >/dev/null 2>&1 || true
}

stop_running_app
"$ROOT/build.sh" >/dev/null
stop_running_app

rm -rf "$DEST_APP"
cp -R "$BUILD_APP" "$DEST_APP"
open "$DEST_APP"

echo "Installed: $DEST_APP"
