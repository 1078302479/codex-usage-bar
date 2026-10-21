#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/CodexUsageBar.app"
CACHE="$ROOT/.build/swift-module-cache"
ARCH="$(uname -m)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CACHE"
xcrun swiftc -swift-version 6 -parse-as-library -O \
  -target "$ARCH-apple-macosx14.0" -sdk "$SDK" -module-cache-path "$CACHE" \
  "$ROOT"/native/Sources/*.swift -o "$APP/Contents/MacOS/CodexUsageBar"
xcrun swift -module-cache-path "$CACHE" "$ROOT/native/Tools/MakeIcon.swift" "$ROOT/.build/CodexUsageBar.iconset" "$ROOT/native/Resources/CodexUsageBarAppIcon.png"
iconutil -c icns "$ROOT/.build/CodexUsageBar.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -f "$APP/Contents/Resources/CodexServiceIcon.png"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexUsageBar</string>
<key>CFBundleIdentifier</key><string>com.guoyuming.UsageBar</string>
<key>CFBundleName</key><string>CodexUsageBar</string>
<key>CFBundleDisplayName</key><string>CodexUsageBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
