import AppKit
import HimawariKit
import IOKit.ps

/// Decides whether the wallpaper should be playing right now, and why not.
///
/// Pauses when: you paused it by hand, the screen is locked, the displays
/// are asleep, you're on battery (optional), or every screen is covered by a
/// maximized / full-screen window (optional) — no point decoding video nobody sees.
@MainActor
final class PlaybackMonitor {
    /// Called with `true` (play) or `false` (pause) whenever the decision is re-made.
    var onChange: ((Bool) -> Void)?
    /// Human-readable state for the menu: "Playing", "On battery", …
    private(set) var reason = "Playing"
    /// Can anyone see the desktop right now (not locked, asleep, or covered by windows)?
    /// Unlike pausing, battery rules don't matter here.
    private(set) var desktopVisible = true

    private var screenLocked = false
    private var displaysAsleep = false
    private var timer: Timer?

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, .init("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(distributed, .init("com.apple.screenIsUnlocked")) { $0.screenLocked = false }

        // Window layout and power source change without notifications we can
        // rely on, so re-check every 2 seconds. It's a cheap call.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            onMainActor { self?.evaluate() }
        }
        evaluate()
    }

    func evaluate() {
        let s = Settings.shared
        let pauseReason: String? =
            s.userPaused ? "Paused" :
            screenLocked ? "Screen locked" :
            displaysAsleep ? "Display asleep" :
            (s.pauseOnBattery && Self.onBattery()) ? "Paused on battery" :
            (s.pauseWhenCovered && Self.allScreensCovered()) ? "Paused (desktop covered)" :
            // Battery Saver: if you can barely see the wallpaper, don't pay to animate it. Part of
            // "Pause When Desktop Is Covered": with that off, the wallpaper plays whatever's open.
            (s.pauseWhenCovered && PowerState.saving && Self.mainScreenCoveredFraction() > 0.6)
                ? "Paused (Battery Saver, mostly covered)" :
            nil
        reason = pauseReason ?? "Playing"
        desktopVisible = !(screenLocked || displaysAsleep || Self.allScreensCovered())
        onChange?(pauseReason == nil)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ update: @escaping (PlaybackMonitor) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            onMainActor {
                guard let self else { return }
                update(self)
                self.evaluate()
            }
        }
    }

    // MARK: - Checks

    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false } // desktop Macs have no battery info
        return (source as String) == kIOPMBatteryPowerKey
    }

    /// How much of the main screen's usable area is hidden behind app windows (0…1),
    /// sampled on a 12×8 grid (windows overlapping each other aren't double-counted).
    static func mainScreenCoveredFraction() -> Double {
        guard let screen = NSScreen.main,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return 0 }
        let me = ProcessInfo.processInfo.processIdentifier
        let windows: [CGRect] = list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dict)
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let v = screen.visibleFrame
        let area = CGRect(x: v.minX, y: mainHeight - v.maxY, width: v.width, height: v.height)
        var covered = 0, total = 0
        for gy in 0..<8 {
            for gx in 0..<12 {
                let point = CGPoint(x: area.minX + (Double(gx) + 0.5) * area.width / 12, y: area.minY + (Double(gy) + 0.5) * area.height / 8)
                total += 1
                if windows.contains(where: { $0.contains(point) }) { covered += 1 }
            }
        }
        return total > 0 ? Double(covered) / Double(total) : 0
    }

    /// True when every screen has a normal app window filling ≥ 95% of its usable area.
    /// Window *positions* don't need Screen Recording permission, only window titles do.
    static func allScreensCovered() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier

        let appWindows: [CGRect] = list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,          // normal app windows only
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,  // ignore invisible ones
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return rect
        }
        guard !appWindows.isEmpty else { return false }

        // CGWindow coordinates start at the TOP-left of the main screen; AppKit's
        // start at the BOTTOM-left. Flip each screen's usable area to compare.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.allSatisfy { screen in
            let v = screen.visibleFrame // minus menu bar and Dock
            let usable = CGRect(x: v.minX, y: mainHeight - v.maxY, width: v.width, height: v.height)
            return appWindows.contains { window in
                let overlap = window.intersection(usable)
                return !overlap.isNull && overlap.width * overlap.height >= 0.95 * usable.width * usable.height
            }
        }
    }
}
