#!/bin/bash
# Builds everything into build/:
#   build/Hanabi.app                         the live wallpaper (only that)
#   build/Desktop Shell/Desktop Folders.app  iOS-style desktop folders   ┐
#   build/Desktop Shell/Desktop Clock.app    the desktop clock           │ background services,
#   build/Desktop Shell/Desktop Widgets.app  floating widget panel       │ independent of Hanabi
#   build/Desktop Shell/XP Taskbar.app       taskbar, Start, Downloads   │
#   build/Desktop Shell/Desktop Hotkeys.app  ⌘⌃T → Ghostty, anywhere     ┘
# Run ./install.sh to install them (it calls this first).
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
    <key>NSAppleEventsUsageDescription</key><string>$name opens Ghostty windows for you (⌘⌃T) and shows / controls what Music is playing.</string>
</dict></plist>
PLIST
    codesign --force --sign "$IDENTITY" "$app" 2>/dev/null
}

mkdir -p build
cp Resources/Info.plist build/Hanabi.Info.plist.tmp
make_app build/Hanabi.app Hanabi "Hanabi" local.dhairyabhatia.hanabi
cp Resources/Info.plist build/Hanabi.app/Contents/Info.plist      # Hanabi's own plist (has the icon entry)
cp Resources/AppIcon.icns build/Hanabi.app/Contents/Resources/AppIcon.icns
# The system Now Playing helper (runs inside /usr/bin/perl; see helpers/NowPlayingHelper.m).
clang -dynamiclib -fobjc-arc -O2 -mmacosx-version-min=14.4 ${ARCHS[@]+"${ARCHS[@]}"} -framework Foundation \
    helpers/NowPlayingHelper.m -o build/Hanabi.app/Contents/Resources/NowPlayingHelper.dylib
codesign --force --sign "$IDENTITY" build/Hanabi.app/Contents/Resources/NowPlayingHelper.dylib
codesign --force --sign "$IDENTITY" build/Hanabi.app
rm build/Hanabi.Info.plist.tmp

SHELL_DIR="build/Desktop Shell"
mkdir -p "$SHELL_DIR"
make_app "$SHELL_DIR/Desktop Folders.app" HanabiFolders "Desktop Folders" local.dhairyabhatia.desktop.folders
make_app "$SHELL_DIR/Desktop Clock.app"   HanabiClock   "Desktop Clock"   local.dhairyabhatia.desktop.clock
make_app "$SHELL_DIR/Desktop Widgets.app" HanabiWidgets "Desktop Widgets" local.dhairyabhatia.desktop.widgets
make_app "$SHELL_DIR/XP Taskbar.app"      HanabiTaskbar "XP Taskbar"      local.dhairyabhatia.desktop.taskbar
make_app "$SHELL_DIR/Desktop Hotkeys.app" HanabiHotkeys "Desktop Hotkeys" local.dhairyabhatia.desktop.hotkeys

# Hanabi carries the services and their installer, so its "Desktop Shell" menu can set them up
# on any Mac (this is how the DMG version installs them).
mkdir -p "build/Hanabi.app/Contents/Resources/Desktop Shell"
cp -R "$SHELL_DIR"/*.app "build/Hanabi.app/Contents/Resources/Desktop Shell/"
cp scripts/shell.sh build/Hanabi.app/Contents/Resources/shell.sh
codesign --force --sign "$IDENTITY" build/Hanabi.app

echo "Built build/Hanabi.app and build/Desktop Shell/ (5 services). Install with ./install.sh"
