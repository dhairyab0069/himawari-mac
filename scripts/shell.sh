#!/bin/bash
# Installs / removes the Desktop Shell background services for the current user.
#   shell.sh install <folder with the 5 service .apps>
#   shell.sh uninstall
#   shell.sh installed        (exit 0 if installed)
# Used by ./install.sh (from a checkout) and by Hanabi's "Desktop Shell" menu (bundled copy).
set -euo pipefail

SHELL_HOME="$HOME/Library/Application Support/Desktop Shell"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/Desktop Shell"
GUI="gui/$(id -u)"
PREFIX="local.dhairyabhatia.desktop"
# name|App Name|executable
SERVICES=("folders|Desktop Folders|HanabiFolders" "clock|Desktop Clock|HanabiClock"
          "widgets|Desktop Widgets|HanabiWidgets" "taskbar|XP Taskbar|HanabiTaskbar"
          "hotkeys|Desktop Hotkeys|HanabiHotkeys")

stop_services() {
    for entry in "${SERVICES[@]}"; do
        IFS='|' read -r name _ _ <<<"$entry"
        launchctl bootout "$GUI/$PREFIX.$name" 2>/dev/null || true
    done
    sleep 1 # let them clean up (the taskbar gives the Dock back)
}

case "${1:-}" in
installed)
    [ -d "$SHELL_HOME/Desktop Clock.app" ]
    ;;
uninstall)
    stop_services
    for entry in "${SERVICES[@]}"; do
        IFS='|' read -r name app _ <<<"$entry"
        rm -f "$AGENTS/$PREFIX.$name.plist"
        rm -rf "$SHELL_HOME/$app.app"
    done
    rmdir "$SHELL_HOME" 2>/dev/null || true
    defaults write com.apple.finder CreateDesktop -bool true && killall Finder || true
    echo "Desktop Shell removed."
    ;;
install)
    SRC="${2:?folder with the service apps}"
    stop_services
    mkdir -p "$SHELL_HOME" "$AGENTS" "$LOGS"
    for entry in "${SERVICES[@]}"; do
        IFS='|' read -r name app exe <<<"$entry"
        rm -rf "$SHELL_HOME/$app.app"
        cp -R "$SRC/$app.app" "$SHELL_HOME/"
        xattr -dr com.apple.quarantine "$SHELL_HOME/$app.app" 2>/dev/null || true
        plist="$AGENTS/$PREFIX.$name.plist"
        cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>$PREFIX.$name</string>
    <key>ProgramArguments</key><array><string>$SHELL_HOME/$app.app/Contents/MacOS/$exe</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardOutPath</key><string>$LOGS/$name.log</string>
    <key>StandardErrorPath</key><string>$LOGS/$name.log</string>
</dict></plist>
PLIST
        # A service you turned off (desktopctl disable) stays off: update its files, don't start it.
        if launchctl print-disabled "$GUI" 2>/dev/null | grep -q "\"$PREFIX.$name\" => disabled"; then
            echo "  $name: updated, left off"
            continue
        fi
        launchctl bootstrap "$GUI" "$plist"
    done
    echo "Desktop Shell installed: folders, clock, widgets, taskbar, hotkeys."
    ;;
*)
    echo "usage: shell.sh install <dir> | uninstall | installed" >&2; exit 2
    ;;
esac
