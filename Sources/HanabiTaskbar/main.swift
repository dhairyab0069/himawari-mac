import AppKit
import HanabiKit

/// Background service "XP Taskbar": the taskbar + Start menu (replacing the
/// Dock), the Downloads window, Start ▸ Desktop Settings, and the window tiler.
/// (⌘⌃T → Ghostty is its own service, Desktop Hotkeys.)
/// No Dock icon and no menu-bar icon: control it with `desktopctl`.
/// Started at login by launchd (restarted if it ever crashes), independent of
/// the wallpaper app.
@MainActor
final class TaskbarService {
    private let taskbar = Taskbar()
    private let tiler = WindowTiler()

    init() {
        refresh()
        Settings.onChange { [weak self] in self?.refresh() }
        Settings.onStartMenuRequest { [weak self] in self?.taskbar.toggleStartMenu() } // ⌥ tap
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            onMainActor { self?.refresh() }
        }
    }

    func refresh() {
        let s = Settings.shared
        DockHider.apply(taskbarOn: s.showTaskbar)
        taskbar.refresh()
        tiler.refresh()
    }
}

runBackgroundService(onQuit: {
    DockHider.apply(taskbarOn: false)   // your real Dock comes back
    DesktopLayout.setZone(.taskbar, nil) // and windows may use the bottom strip again
}) { TaskbarService() }
