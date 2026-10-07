#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEGACY_DIR="$ROOT_DIR/src/HikvisionLocalPlayer"
OUTPUT_DIR="$ROOT_DIR/outputs-v2"
APP="$OUTPUT_DIR/海康威视播放器.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
NATIVE_EXE="$MACOS/HikvisionLocalPlayerApp"
VERSION="2.0.8"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

echo "== Build pure native Swift/AppKit app =="
swiftc \
  "$SCRIPT_DIR/PlayerTheme.swift" \
  "$SCRIPT_DIR/Models.swift" \
  "$SCRIPT_DIR/KeychainSettings.swift" \
  "$SCRIPT_DIR/DeviceClient.swift" \
  "$SCRIPT_DIR/LocalNetworkProbe.swift" \
  "$SCRIPT_DIR/Go2RtcController.swift" \
  "$SCRIPT_DIR/RTSPH264Client.swift" \
  "$SCRIPT_DIR/VideoGridView.swift" \
  "$SCRIPT_DIR/MainViewController.swift" \
  "$SCRIPT_DIR/main.swift" \
  -O -whole-module-optimization \
  -framework AppKit \
  -framework AVFoundation \
  -framework QuartzCore \
  -framework Network \
  -framework Security \
  -o "$NATIVE_EXE"
chmod 755 "$NATIVE_EXE"

echo "== Bundle go2rtc =="
cp "$LEGACY_DIR/Resources/go2rtc" "$RESOURCES/go2rtc"
cp "$LEGACY_DIR/Resources/go2rtc-LICENSE" "$RESOURCES/go2rtc-LICENSE"
chmod 755 "$RESOURCES/go2rtc"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>海康威视播放器</string>
  <key>CFBundleExecutable</key>
  <string>HikvisionLocalPlayerApp</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.maomaowuxian.hikvisionlocalplayer</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>海康威视播放器</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>用于连接局域网内的海康威视录像机并获取实时视频流。</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

echo "== Generate AppIcon.icns =="
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICON_MASTER="$ICON_TMP/AppIcon-1024.png"
ICONSET="$ICON_TMP/AppIcon.iconset"

swift "$LEGACY_DIR/generate-icon.swift" "$ICON_MASTER"
mkdir -p "$ICONSET"

sips -z 16 16 "$ICON_MASTER" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_MASTER" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_MASTER" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_MASTER" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_MASTER" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_MASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_MASTER" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_MASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_MASTER" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$ICON_MASTER" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"

echo "== Sign native app =="
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$RESOURCES/go2rtc"
codesign --force --sign - "$NATIVE_EXE"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Built: $APP"
file "$NATIVE_EXE"
file "$RESOURCES/go2rtc"
