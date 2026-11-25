#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/preview/CodexUsageBar UI Preview.app"
CACHE="$ROOT/.build/swift-module-cache"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CACHE"
xcrun swiftc -swift-version 6 -parse-as-library -D STABILITY_TEST -O \
  -target "$(uname -m)-apple-macosx14.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$CACHE" \
  "$ROOT"/native/Sources/*.swift "$ROOT/native/Tools/OrbitPreview.swift" -o "$APP/Contents/MacOS/CodexUsageBarUIPreview"
rm -rf "$APP/Contents/Resources/TideIcons"
cp "$ROOT/native/Resources/TideIcons/rings-template.png" "$APP/Contents/Resources/TideMenuGlyph.png"
rm -f "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/native/Resources/TideIcons/rings.png" "$APP/Contents/Resources/TideRings.png"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexUsageBarUIPreview</string>
<key>CFBundleIdentifier</key><string>com.guoyuming.UsageBar.UIReview</string>
<key>CFBundleName</key><string>CodexUsageBar UI Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.12-local</string>
<key>CFBundleVersion</key><string>17</string>
<key>CFBundleIconFile</key><string>TideRings.png</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built local UI review app: %s\n' "$APP"
