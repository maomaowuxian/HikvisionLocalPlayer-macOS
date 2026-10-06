#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOTNET="$HOME/.dotnet/dotnet"
PUBLISH_DIR="$ROOT_DIR/build/publish/osx-x64"
OUTPUT_DIR="$ROOT_DIR/outputs"
APP="$OUTPUT_DIR/海康威视播放器.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BACKEND_DIR="$RESOURCES/backend"
NATIVE_EXE="$MACOS/HikvisionLocalPlayerApp"
VERSION="1.3.0"

if [ ! -x "$DOTNET" ]; then
  echo "dotnet SDK not found: $DOTNET" >&2
  exit 1
fi

rm -rf "$PUBLISH_DIR" "$APP"
mkdir -p "$PUBLISH_DIR" "$MACOS" "$BACKEND_DIR"

echo "== Publish .NET backend =="
"$DOTNET" publish "$SCRIPT_DIR/HikvisionLocalPlayer.csproj" \
  -c Release \
  -r osx-x64 \
  --self-contained true \
  -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -o "$PUBLISH_DIR"

cp "$PUBLISH_DIR/HikvisionLocalPlayer" "$BACKEND_DIR/HikvisionLocalPlayer"
chmod 755 "$BACKEND_DIR/HikvisionLocalPlayer"

echo "== Build native AppKit/WKWebView shell =="
swiftc "$SCRIPT_DIR/NativeShell.swift" \
  -O \
  -framework AppKit \
  -framework WebKit \
  -o "$NATIVE_EXE"
chmod 755 "$NATIVE_EXE"

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
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
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
    <key>NSAllowsArbitraryLoadsInWebContent</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

echo "== Generate transparent AppIcon.icns =="
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICON_MASTER="$ICON_TMP/AppIcon-1024.png"
ICONSET="$ICON_TMP/AppIcon.iconset"

swift "$SCRIPT_DIR/generate-icon.swift" "$ICON_MASTER"
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

for image in "$ICONSET"/*.png; do
  sips -g hasAlpha "$image" | grep -q 'hasAlpha: yes' || {
    echo "Icon alpha verification failed: $image" >&2
    exit 1
  }
done

iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"

echo "== Sign bundle =="
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$BACKEND_DIR/HikvisionLocalPlayer"
codesign --force --sign - "$NATIVE_EXE"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Built: $APP"
file "$NATIVE_EXE"
file "$BACKEND_DIR/HikvisionLocalPlayer"
