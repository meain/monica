#!/usr/bin/env bash
# Builds a release binary and wraps it in monica.app so it can be launched
# at login, from Spotlight, or symlinked into /Applications.
set -euo pipefail

cd "$(dirname "$0")"

echo "Building release…"
swift build -c release

APP="monica.app"
BIN=".build/release/monica"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/monica"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Monica</string>
    <key>CFBundleDisplayName</key>     <string>Monica</string>
    <key>CFBundleIdentifier</key>      <string>com.meain.monica</string>
    <key>CFBundleExecutable</key>      <string>monica</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "Built $APP"
echo "Run it:   open $APP"
echo "Install:  make link   (symlinks into /Applications)"
