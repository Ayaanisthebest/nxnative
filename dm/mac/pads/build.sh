#!/bin/sh
# Builds "NX Pads.app" (NXPads.swift) into the folder given, ./build by default: swiftc, an Info.plist, the icon the app renders itself, an ad-hoc signature.
set -e
cd "$(dirname "$0")"
OUT_DIR="${1:-build}"
APP="$OUT_DIR/NX Pads.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 NXPads.swift -o "$APP/Contents/MacOS/NXPads"
# nxpadlobby: the phone server with no game (dm/host/phonepad_lobby.m); dm.h wants a game profile, any one builds it
make -C ../../host GAME="${PADS_GAME:-0100152000022000}" nxpadlobby
cp ../../host/nxpadlobby "$APP/Contents/MacOS/nxpadlobby"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.nxnative.pads</string>
<key>CFBundleName</key><string>NX Pads</string>
<key>CFBundleDisplayName</key><string>NX Pads</string>
<key>CFBundleExecutable</key><string>NXPads</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
"$APP/Contents/MacOS/NXPads" --render-icon "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP/Contents/MacOS/nxpadlobby"
codesign --force --sign - "$APP"
echo "$APP"
