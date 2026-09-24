#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=ScreenBlur.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -module-cache-path "${TMPDIR:-/tmp}/screenblur-mc" main.swift -o "$APP/Contents/MacOS/ScreenBlur"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ScreenBlur</string>
  <key>CFBundleIdentifier</key><string>local.macscreenblur</string>
  <key>CFBundleName</key><string>ScreenBlur</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSMotionUsageDescription</key><string>Uses AirPods head tracking to blur the half of the screen you look away from.</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP — run: open $APP"
