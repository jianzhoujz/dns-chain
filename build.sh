#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="${APP_NAME:-DNSChain}"
PACKAGE_EXECUTABLE_NAME="DNSChain"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-Google Chrome}"
BUNDLE_ID="${BUNDLE_ID:-local.dns-chain}"
APP_VERSION="${APP_VERSION:-${VERSION:-0.1.0}}"
APP_BUILD="${APP_BUILD:-$APP_VERSION}"
APP_BUILD_TIME="${APP_BUILD_TIME:-$(date '+%Y-%m-%d %H:%M:%S %z')}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-14.0}"

APP="$ROOT/build/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$EXECUTABLE_NAME"
RESOURCES="$APP/Contents/Resources"
ICONSET="$ROOT/build/AppIcon.iconset"
ICON="$RESOURCES/AppIcon.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN_PATH="$ROOT/.build/apple/Products/Release"
else
  swift build -c release
  BIN_PATH="$(swift build -c release --show-bin-path)"
fi

if [[ ! -x "$BIN_PATH/$PACKAGE_EXECUTABLE_NAME" ]]; then
  echo "Missing built executable: $BIN_PATH/$PACKAGE_EXECUTABLE_NAME" >&2
  exit 1
fi

cp "$BIN_PATH/$PACKAGE_EXECUTABLE_NAME" "$BIN"
chmod +x "$BIN"

swift "$ROOT/tools/make_app_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICON"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>BuildTime</key>
  <string>$APP_BUILD_TIME</string>
  <key>LSMinimumSystemVersion</key>
  <string>$DEPLOYMENT_TARGET</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "$APP"
