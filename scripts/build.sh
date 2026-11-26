#!/bin/bash
# Builds Vule.app (release, ad-hoc signed). Usage: scripts/build.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app=build/Vule.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Vule "$app/Contents/MacOS/Vule"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.vule.notch</string>
  <key>CFBundleName</key><string>Vule</string>
  <key>CFBundleExecutable</key><string>Vule</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Vule reads your Ghostty terminals to know which agent session you're in, and types your replies into them.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"
[ "${1:-}" = --open ] && open "$app"
exit 0
