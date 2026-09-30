#!/bin/bash
# Installs (or updates) everything:
#   /Applications/Hanabi.app                               the live wallpaper (a normal app)
#   ~/Library/Application Support/Desktop Shell/*.app      the 5 background services
#   ~/Library/LaunchAgents/local.dhairyabhatia.desktop.*   start them at login, restart on crash
#
#   ./install.sh                    build + install/update everything
#   ./install.sh --uninstall-shell  remove the 5 services (gives back the Dock and Finder's icons)
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--uninstall-shell" ]; then
    scripts/shell.sh uninstall
    exit 0
fi

./build.sh

# One-time move of the desktop settings out of Hanabi's own preferences.
if ! defaults read local.dhairyabhatia.desktop migrated >/dev/null 2>&1; then
    python3 - <<'PY'
import plistlib, subprocess
old = plistlib.loads(subprocess.run(["defaults", "export", "local.dhairyabhatia.hanabi", "-"], capture_output=True).stdout or plistlib.dumps({}))
keys = ["showClock", "clockPosition", "clock24h", "clockSeconds", "showWidgets", "widgetsCollapsed", "widgetEdge",
        "showFolders", "foldersIncludeDownloads", "keepWindowsClear"]
for k in keys:
    if k in old:
        v = old[k]
        kind = "-bool" if isinstance(v, bool) else "-string"
        subprocess.run(["defaults", "write", "local.dhairyabhatia.desktop", k, kind, str(v).lower() if isinstance(v, bool) else str(v)])
for k in keys + [k for k in old if k.startswith("zone.") or k.startswith("dockBackup.") or k == "widgetsTopRight"]:
    subprocess.run(["defaults", "delete", "local.dhairyabhatia.hanabi", k], capture_output=True)
subprocess.run(["defaults", "write", "local.dhairyabhatia.desktop", "migrated", "-bool", "true"])
PY
fi

# --- Hanabi, the wallpaper: a normal app in /Applications ---
if pgrep -qf "/Applications/Hanabi.app/Contents/MacOS/Hanabi"; then
    osascript -e 'tell application id "local.dhairyabhatia.hanabi" to quit' || true
    sleep 2
    pkill -f "/Applications/Hanabi.app/Contents/MacOS/Hanabi" || true
fi
rm -rf /Applications/Hanabi.app
cp -R build/Hanabi.app /Applications/
open /Applications/Hanabi.app

# --- The Desktop Shell services: hidden apps started by launchd ---
scripts/shell.sh install "build/Desktop Shell"

echo "Installed: Hanabi (wallpaper) + Desktop Shell services: folders, clock, widgets, taskbar, hotkeys."
echo "Control them with:  desktopctl status | stop | start | restart | disable | enable  <service|all>"
