#!/bin/bash
# Builds Flight Studio.app without needing full Xcode — SPM + manual bundle assembly.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Flight Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/FlightStudio "$APP/Contents/MacOS/FlightStudio"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>FlightStudio</string>
    <key>CFBundleIdentifier</key><string>dev.flightstudio.app</string>
    <key>CFBundleName</key><string>Flight Studio</string>
    <key>CFBundleDisplayName</key><string>Flight Studio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>GPL v3</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built: $APP"
