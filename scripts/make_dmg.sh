#!/bin/bash
# Builds build/Himawari-<version>.dmg to share: a universal (Apple Silicon + Intel) Himawari.app
# (with its desktop clock inside), an Applications shortcut to drag it onto, and a Read Me.
#
#   scripts/make_dmg.sh
#
# Not notarized (that needs a paid Apple Developer ID): the first time, people right-click
# Himawari ▸ Open, or allow it under System Settings ▸ Privacy & Security. The Read Me says so.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE=build/dmg
DMG="build/Himawari-$VERSION.dmg"
rm -rf "$STAGE" "$DMG" build/Himawari-rw.dmg
mkdir -p "$STAGE"
cp -R build/Himawari.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<TXT
Himawari $VERSION — a live video wallpaper for macOS (14.4 or newer)

INSTALL
  Drag Himawari onto Applications, then open it from Applications.

  The first time, macOS may say it can't check Himawari for malicious software
  (it isn't notarized by Apple). Either:
    • right-click (or Control-click) Himawari in Applications ▸ Open ▸ Open, or
    • System Settings ▸ Privacy & Security ▸ scroll down ▸ "Open Anyway".

USE
  Himawari lives in the menu bar (the sunflower icon):
    • Choose Video… picks any .mp4 / .mov as your wallpaper (it pauses when
      covered, on battery, or while the screen is locked).
    • Use Apple Music Artwork While Playing: the album's animated cover
      becomes the wallpaper, with retro hi-fi gear in the side bars (VU meters
      and a spectrum that follow the music), or a spinning CD of the cover
      when the album has no animation.
    • Click Desktop to Hide Files: click an empty spot on the desktop to see
      just the wallpaper; click again to bring the files back.

  macOS asks once for each thing Himawari uses: to control Music (what's
  playing), to control Finder (the desktop click), and to "record audio from
  other apps" (only to measure the music's loudness for the meters; nothing is
  recorded).

THE DESKTOP CLOCK
  A see-through clock on the desktop that runs with Himawari. Left-click it to
  change how it tells the time, right-click for options. Show or hide it from
  the Himawari menu, or with ⌃⌥⌘C from anywhere.

UNINSTALL
  Quit Himawari and move it to the Trash.
TXT

# A writable image first, to lay out the window (big icons, app next to Applications).
hdiutil create -quiet -volname "Himawari" -srcfolder "$STAGE" -ov -format UDRW build/Himawari-rw.dmg
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen build/Himawari-rw.dmg | awk -F'\t' '/\/Volumes\// {print $NF}')
osascript <<APPLESCRIPT || echo "(window layout skipped)"
tell application "Finder"
    tell disk "Himawari"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 760, 480}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set position of item "Himawari.app" of container window to {140, 150}
        set position of item "Applications" of container window to {420, 150}
        set position of item "Read Me First.txt" of container window to {280, 290}
        close
    end tell
end tell
APPLESCRIPT
sync
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet build/Himawari-rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f build/Himawari-rw.dmg
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
