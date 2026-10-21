#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/CodexUsageBar.app"
STAGE="$ROOT/.build/dmg-stage"
MOUNT="$ROOT/.build/dmg-mount"
RW="$ROOT/.build/CodexUsageBar-install-rw.dmg"
OUTPUT="$ROOT/build/CodexUsageBar-0.1.1-mac-arm64.dmg"
[[ -d "$APP" ]] || { printf 'Build the app first: bash scripts/build-native.sh\n'; exit 1; }
export PYTHONPATH="$ROOT/.build/dmg-python${PYTHONPATH:+:$PYTHONPATH}"
python3 -c 'import ds_store, mac_alias' || {
  printf 'Install packaging dependencies: python3 -m pip install --target .build/dmg-python ds-store==1.3.1 mac-alias==2.2.2\n'
  exit 1
}
codesign --verify --deep --strict "$APP"
# Recreate only project-owned, disposable packaging directories.
rm -rf "$STAGE"
mkdir -p "$STAGE/.background" "$MOUNT"
ditto "$APP" "$STAGE/CodexUsageBar.app"
ln -s /Applications "$STAGE/Applications"
xcrun swift -module-cache-path "$ROOT/.build/swift-module-cache" "$ROOT/native/Tools/DMGBackground.swift" "$STAGE/.background/install.png"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
rm -f "$RW"
hdiutil create -quiet -size 64m -fs HFS+ -volname 'CodexUsageBar Installer' -format UDRW -srcfolder "$STAGE" "$RW"
ATTACHED=0
cleanup() {
  if [[ "$ATTACHED" == 1 ]]; then hdiutil detach -quiet "$MOUNT" || true; fi
}
trap cleanup EXIT
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$RW"
ATTACHED=1
python3 "$ROOT/scripts/dmg-layout.py" "$MOUNT"
SetFile -a C "$MOUNT"
hdiutil detach -quiet "$MOUNT"
ATTACHED=0
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$OUTPUT"
hdiutil verify "$OUTPUT"
printf 'Built %s\n' "$OUTPUT"
