import AppKit
import HanabiKit

// MARK: - The real Dock under the taskbar

/// While the XP taskbar is on, the macOS Dock stays *visible but tiny* at the
/// bottom (smallest icons, no magnification, no auto-hide), and the taskbar is
/// drawn exactly over it. Why not just hide the Dock: macOS keeps app windows
/// clear of the Dock's strip, and only of the Dock's. With the Dock hidden,
/// maximized windows would slide under the taskbar; this way they stop above
/// it, with no Accessibility tricks needed.
///
/// Your own Dock settings are saved first and put back exactly when the
/// taskbar is turned off (or its service is stopped).
@MainActor
enum DockHider {
    private static let domain = "com.apple.dock" as CFString
    private static let keys = ["autohide", "autohide-delay", "tilesize", "magnification", "orientation"]
    private static let underTaskbar: [String: Any] = ["autohide": false, "tilesize": 16, "magnification": false,
                                                      "orientation": "bottom"]

    static func apply(taskbarOn: Bool) {
        migrateOldBackup()
        let s = Settings.shared
        if taskbarOn {
            if isUnderTaskbar { return }
            if s.string("dockBackup2.saved") == nil { saveBackup() }
            for (key, value) in underTaskbar { write(key, value) }
            write("autohide-delay", nil)
            restartDock()
        } else if s.string("dockBackup2.saved") != nil {
            for key in keys {
                write(key, s.string("dockBackup2.unset." + key) == "1" ? nil : backupValue(key))
            }
            for key in keys { s.set(nil, for: "dockBackup2." + key); s.set(nil, for: "dockBackup2.unset." + key) }
            s.set(nil, for: "dockBackup2.saved")
            restartDock()
        }
    }

    private static var isUnderTaskbar: Bool {
        (read("autohide") as? Bool) == false && (read("tilesize") as? Int) == 16
            && (read("magnification") as? Bool) == false && (read("orientation") as? String) == "bottom"
    }

    private static func saveBackup() {
        let s = Settings.shared
        for key in keys {
            if let value = read(key) { s.set(value, for: "dockBackup2." + key) } else { s.set("1", for: "dockBackup2.unset." + key) }
        }
        s.set("1", for: "dockBackup2.saved")
    }

    /// The first version only hid the Dock and saved auto-hide / delay. Turn that into a full backup:
    /// those two from the old backup, everything else is still your own current setting.
    private static func migrateOldBackup() {
        let s = Settings.shared
        guard s.string("dockBackup.saved") != nil, s.string("dockBackup2.saved") == nil else { return }
        for key in ["tilesize", "magnification", "orientation"] {
            if let value = read(key) { s.set(value, for: "dockBackup2." + key) } else { s.set("1", for: "dockBackup2.unset." + key) }
        }
        s.set(s.string("dockBackup.autohide") == "1", for: "dockBackup2.autohide")
        if let delay = s.string("dockBackup.delay"), let d = Double(delay) {
            s.set(d, for: "dockBackup2.autohide-delay")
        } else {
            s.set("1", for: "dockBackup2.unset.autohide-delay")
        }
        s.set("1", for: "dockBackup2.saved")
        for key in ["dockBackup.saved", "dockBackup.autohide", "dockBackup.delay"] { s.set(nil, for: key) }
    }

    private static func backupValue(_ key: String) -> Any? {
        UserDefaults(suiteName: Settings.domain)?.object(forKey: "dockBackup2." + key)
    }

    private static func read(_ key: String) -> Any? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    private static func write(_ key: String, _ value: Any?) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
        CFPreferencesAppSynchronize(domain)
    }

    private static func restartDock() { Power.run("/usr/bin/killall", ["Dock"]) }
}

// MARK: - Desktop Settings (Start menu ▸ Desktop Settings)

/// One menu for every desktop service: folders, clock, widgets, taskbar,
/// shortcuts, window tiling, shown as an XP cascading menu. Each change is
/// saved to the shared settings and broadcast, so the service it belongs to
/// reacts immediately, whichever process it's in.
@MainActor
enum DesktopSettingsMenu {
    private static var s: Settings { Settings.shared }

    static func items() -> [XPMenuItem] {
        var items: [XPMenuItem] = [
            toggle("Windows XP Taskbar (replaces the Dock)", \.showTaskbar, symbol: "menubar.dock.rectangle"),
            toggle("⌘⌃T Opens Ghostty", \.ghosttyHotkey, symbol: "terminal"),
            toggle("Tap ⌥ Option Opens Start", \.optionOpensStart, symbol: "option"),
            .separator,
            toggle("Desktop Folders", \.showFolders, symbol: "folder"),
            toggle("Include Downloads in Folders", \.foldersIncludeDownloads, enabled: s.showFolders),
            XPMenuItem(title: "Hide Finder Desktop Icons", checked: !finderShowsIcons, action: toggleFinderIcons),
            .separator,
            toggle("Desktop Clock", \.showClock, symbol: "clock"),
            XPMenuItem(title: "Clock Position", enabled: s.showClock, submenu: XPSubmenu {
                ClockPosition.allCases.map { position in
                    XPMenuItem(title: position.rawValue, checked: s.clockPosition == position) {
                        s.clockPosition = position
                        Settings.broadcastChange()
                    }
                }
            }),
            toggle("24-Hour Clock", \.clock24h, enabled: s.showClock),
            toggle("Show Seconds", \.clockSeconds, enabled: s.showClock),
            .separator,
            toggle("Desktop Widgets", \.showWidgets, symbol: "square.grid.2x2"),
            toggle("Now Playing Widget (Apple Music)", \.showNowPlaying, symbol: "music.note", enabled: s.showWidgets),
            toggle("YouTube Loop When No Motion Artwork", \.youtubeLoops, symbol: "play.rectangle", enabled: s.showWidgets && s.showNowPlaying),
            XPMenuItem(title: "Dock Widgets To", enabled: s.showWidgets, submenu: XPSubmenu {
                WidgetEdge.allCases.map { edge in
                    XPMenuItem(title: edge.rawValue + (edge.isVertical ? " (column)" : " (strip)"),
                               checked: s.widgetEdge == edge) {
                        s.widgetEdge = edge
                        Settings.broadcastChange()
                    }
                }
            }),
            .separator,
        ]
        let trusted = AXIsProcessTrusted()
        items.append(toggle(trusted || !s.keepWindowsClear ? "Keep Windows Clear (tiling)" : "Keep Windows Clear (needs Accessibility)",
                            \.keepWindowsClear, symbol: "rectangle.split.3x1"))
        if s.keepWindowsClear && !trusted {
            items.append(XPMenuItem(title: "Open Accessibility Settings…", symbol: "lock.open") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            })
        }
        return items
    }

    private static func toggle(_ title: String, _ key: ReferenceWritableKeyPath<Settings, Bool>,
                               symbol: String? = nil, enabled: Bool = true) -> XPMenuItem {
        XPMenuItem(title: title, symbol: symbol, checked: s[keyPath: key], enabled: enabled) {
            s[keyPath: key].toggle()
            Settings.broadcastChange()
        }
    }

    /// Finder's own desktop icons would sit on top of the folders. This flips Finder's
    /// `CreateDesktop` setting and restarts Finder (files stay put in ~/Desktop).
    private static var finderShowsIcons: Bool {
        CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString) as? Bool ?? true
    }

    private static func toggleFinderIcons() {
        Power.run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", finderShowsIcons ? "false" : "true"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Power.run("/usr/bin/killall", ["Finder"]) }
    }
}
