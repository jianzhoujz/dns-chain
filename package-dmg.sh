#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="${APP_NAME:-DNS Chain}"
APP_VERSION="${APP_VERSION:-${VERSION:-0.1.0}}"
APP_PATH="$ROOT/build/$APP_NAME.app"
DIST_DIR="$ROOT/dist"
WORK_DIR="$ROOT/build/dmg"
STAGE_DIR="$WORK_DIR/stage"
RW_DMG="$WORK_DIR/DNSChain-rw.dmg"
FINAL_DMG="$DIST_DIR/DNSChain-$APP_VERSION.dmg"
VOLUME_NAME="DNS Chain"

"$ROOT/build.sh" >/dev/null

rm -rf "$WORK_DIR"
mkdir -p "$STAGE_DIR" "$DIST_DIR"

cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDRW \
  "$RW_DMG" >/dev/null

rm -f "$FINAL_DMG"
hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$FINAL_DMG" >/dev/null

rm -rf "$WORK_DIR"

echo "$FINAL_DMG"
