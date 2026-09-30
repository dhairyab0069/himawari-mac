#!/bin/bash
# Builds build/Himawari.app: the live wallpaper, with its desktop clock inside
# (Contents/Helpers/Desktop Clock.app, which Himawari starts and stops).
# Run ./install.sh to install it (it calls this first).
set -euo pipefail
cd "$(dirname "$0")"

# UNIVERSAL=1 ./build.sh: one build for both Apple Silicon and Intel Macs (for the DMG).
if [ "${UNIVERSAL:-0}" = 1 ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=.build/apple/Products/Release
    ARCHS=(-arch arm64 -arch x86_64)
else
    swift build -c release
    BIN=.build/release
    ARCHS=()
fi

# App icon: render once from tools/make_icon.swift, then pack every size into an .icns
if [ ! -f Resources/AppIcon.icns ]; then
    ICONSET=build/AppIcon.iconset
    mkdir -p "$ICONSET"
    swift tools/make_icon.swift build/icon_1024.png
    for size in 16 32 128 256 512; do
        sips -z $size $size build/icon_1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) build/icon_1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

# Sign with the stable local identity (tools/make_signing_identity.sh) so macOS keeps
# the permissions you granted across rebuilds; fall back to ad-hoc if it's missing.
IDENTITY="Hanabi Local Code Signing"
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 || IDENTITY="-"

# make_app <bundle path> <executable> <display name> <bundle id>
make_app() {
    local app="$1" exe="$2" name="$3" id="$4"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BIN/$exe" "$app/Contents/MacOS/$exe"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundleIdentifier</key><string>$id</string>
    <key>CFBundleExecutable</key><string>$exe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>$name measures how loud the song Music is playing is, to move the VU meters and spectrum on the wallpaper. Nothing is recorded.</string>
    <key>NSAppleEventsUsageDescription</key><string>$name shows and controls what Music is playing.</string>
</dict></plist>
PLIST
    codesign --force --sign "$IDENTITY" "$app" 2>/dev/null
}

mkdir -p build
cp Resources/Info.plist build/Himawari.Info.plist.tmp
make_app build/Himawari.app Himawari "Himawari" local.dhairyabhatia.himawari
cp Resources/Info.plist build/Himawari.app/Contents/Info.plist      # Himawari's own plist (has the icon entry)
cp Resources/AppIcon.icns build/Himawari.app/Contents/Resources/AppIcon.icns
# The system Now Playing helper (runs inside /usr/bin/perl; see helpers/NowPlayingHelper.m).
clang -dynamiclib -fobjc-arc -O2 -mmacosx-version-min=14.4 ${ARCHS[@]+"${ARCHS[@]}"} -framework Foundation \
    helpers/NowPlayingHelper.m -o build/Himawari.app/Contents/Resources/NowPlayingHelper.dylib
codesign --force --sign "$IDENTITY" build/Himawari.app/Contents/Resources/NowPlayingHelper.dylib
codesign --force --sign "$IDENTITY" build/Himawari.app
rm build/Himawari.Info.plist.tmp

# The desktop clock, as a helper app inside Himawari.app.
make_app build/DesktopClock.tmp.app HimawariClock "Desktop Clock" local.dhairyabhatia.desktop.clock
mkdir -p build/Himawari.app/Contents/Helpers
rm -rf "build/Himawari.app/Contents/Helpers/Desktop Clock.app"
mv build/DesktopClock.tmp.app "build/Himawari.app/Contents/Helpers/Desktop Clock.app"
codesign --force --sign "$IDENTITY" build/Himawari.app

echo "Built build/Himawari.app (with its desktop clock). Install with ./install.sh"
