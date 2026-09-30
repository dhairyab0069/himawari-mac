#!/bin/bash
# Builds build/Hanabi-<version>.dmg to share: a universal (Apple Silicon + Intel) Hanabi.app,
# with the Desktop Shell inside it (Hanabi menu ▸ Desktop Shell ▸ Install), an Applications
# shortcut to drag it onto, and a Read Me.
#
#   scripts/make_dmg.sh
#
# Not notarized (that needs a paid Apple Developer ID): the first time, people right-click
# Hanabi ▸ Open, or allow it under System Settings ▸ Privacy & Security. The Read Me says so.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE=build/dmg
DMG="build/Hanabi-$VERSION.dmg"
rm -rf "$STAGE" "$DMG" build/Hanabi-rw.dmg
mkdir -p "$STAGE"
cp -R build/Hanabi.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<TXT
Hanabi $VERSION — a live video wallpaper for macOS (14.4 or newer)

INSTALL
  Drag Hanabi onto Applications, then open it from Applications.

  The first time, macOS may say it can't check Hanabi for malicious software
  (it isn't notarized by Apple). Either:
    • right-click (or Control-click) Hanabi in Applications ▸ Open ▸ Open, or
    • System Settings ▸ Privacy & Security ▸ scroll down ▸ "Open Anyway".

USE
  Hanabi lives in the menu bar (the firework icon):
    • Choose Video… picks any .mp4 / .mov as your wallpaper (it pauses when
      covered, on battery, or while the screen is locked).
    • Use Apple Music Artwork While Playing: the album's animated cover
      becomes the wallpaper, with retro hi-fi gear in the side bars (VU meters
      and a spectrum that follow the music), or a spinning CD of the cover
      when the album has no animation.
    • Click Desktop to Hide Files: click an empty spot on the desktop to see
      just the wallpaper; click again to bring the files back.

  macOS asks once for each thing Hanabi uses: to control Music (what's
  playing), to control Finder (the desktop click), and to "record audio from
  other apps" (only to measure the music's loudness for the meters; nothing is
  recorded).

OPTIONAL: THE DESKTOP SHELL
  Hanabi menu ▸ Desktop Shell ▸ Install… adds background services that
  restyle the desktop: an XP taskbar and Start menu in place of the Dock,
  iOS-style desktop folders, a big desktop clock, a widget panel, and ⌘⌃T for
  a Ghostty terminal. Remove it from the same menu any time.

UNINSTALL
  Remove the Desktop Shell first (if installed), quit Hanabi, and move it to
  the Trash.
TXT

# A writable image first, to lay out the window (big icons, app next to Applications).
hdiutil create -quiet -volname "Hanabi" -srcfolder "$STAGE" -ov -format UDRW build/Hanabi-rw.dmg
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen build/Hanabi-rw.dmg | awk -F'\t' '/\/Volumes\// {print $NF}')
osascript <<APPLESCRIPT || echo "(window layout skipped)"
tell application "Finder"
    tell disk "Hanabi"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 760, 480}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set position of item "Hanabi.app" of container window to {140, 150}
        set position of item "Applications" of container window to {420, 150}
        set position of item "Read Me First.txt" of container window to {280, 290}
        close
    end tell
end tell
APPLESCRIPT
sync
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet build/Hanabi-rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f build/Hanabi-rw.dmg
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
