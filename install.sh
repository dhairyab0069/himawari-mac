#!/bin/bash
# Builds and installs (or updates) /Applications/Himawari.app, the live wallpaper and its
# desktop clock. (The XP taskbar, desktop folders, widgets and hotkeys are the separate
# Desktop Shell project: https://github.com/dhairyab0069/desktop-shell-mac)
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

# One-time move of the desktop settings out of Himawari's own preferences.
if ! defaults read local.dhairyabhatia.desktop migrated >/dev/null 2>&1; then
    python3 - <<'PY'
import plistlib, subprocess
old = plistlib.loads(subprocess.run(["defaults", "export", "local.dhairyabhatia.himawari", "-"], capture_output=True).stdout or plistlib.dumps({}))
keys = ["showClock", "clockPosition", "clock24h", "clockSeconds", "showWidgets", "widgetsCollapsed", "widgetEdge",
        "showFolders", "foldersIncludeDownloads", "keepWindowsClear"]
for k in keys:
    if k in old:
        v = old[k]
        kind = "-bool" if isinstance(v, bool) else "-string"
        subprocess.run(["defaults", "write", "local.dhairyabhatia.desktop", k, kind, str(v).lower() if isinstance(v, bool) else str(v)])
for k in keys + [k for k in old if k.startswith("zone.") or k.startswith("dockBackup.") or k == "widgetsTopRight"]:
    subprocess.run(["defaults", "delete", "local.dhairyabhatia.himawari", k], capture_output=True)
subprocess.run(["defaults", "write", "local.dhairyabhatia.desktop", "migrated", "-bool", "true"])
PY
fi

# --- One-time move from the app's old name (Hanabi): quit it, keep its settings, remove it ---
if [ -d /Applications/Hanabi.app ]; then
    osascript -e 'tell application id "local.dhairyabhatia.hanabi" to quit' 2>/dev/null || true
    sleep 2
    pkill -f "/Applications/Hanabi.app/Contents/MacOS/Hanabi" 2>/dev/null || true
    rm -rf /Applications/Hanabi.app
fi
if ! defaults read local.dhairyabhatia.himawari >/dev/null 2>&1 && defaults read local.dhairyabhatia.hanabi >/dev/null 2>&1; then
    defaults export local.dhairyabhatia.hanabi - | defaults import local.dhairyabhatia.himawari -
    echo "  Settings carried over from Hanabi."
fi

# --- Himawari, the wallpaper: a normal app in /Applications ---
if pgrep -qf "/Applications/Himawari.app/Contents/MacOS/Himawari"; then
    osascript -e 'tell application id "local.dhairyabhatia.himawari" to quit' || true
    sleep 2
    pkill -f "/Applications/Himawari.app/Contents/MacOS/Himawari" || true
fi
rm -rf /Applications/Himawari.app
cp -R build/Himawari.app /Applications/
open /Applications/Himawari.app

echo "Installed: Himawari (with its desktop clock)."
