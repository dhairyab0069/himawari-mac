import AppKit
import HimawariKit

/// Click an empty spot on the desktop: the files and folders disappear and it's just
/// the live wallpaper. Click again (anywhere on it) and they're back.
///
/// Finder draws the desktop icons in one full-screen window, so a click that lands on
/// that window is a desktop click. To tell an empty spot from a click on a file, Finder
/// is asked afterwards whether anything got selected (clicking empty space selects
/// nothing). Watching clicks needs no permission; asking Finder needs a one-time OK.
@MainActor
final class DesktopPeek {
    /// Called when the desktop should be cleared (true) or its icons come back (false).
    var onChange: ((Bool) -> Void)?
    private var monitor: Any?
    private var localMonitor: Any?
    /// Called on a click on the wallpaper itself while the files are hidden (bring them back).
    var onWallpaperClick: (() -> Void)?
    private var downAt: NSPoint?

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled {
                // Clicks on our own windows never reach a global monitor: while the files are
                // hidden, the wallpaper window takes the click, and this one sees it.
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                    if event.window?.level.rawValue ?? 0 < NSWindow.Level.normal.rawValue {
                        onMainActor { self?.onWallpaperClick?() }
                    }
                    return event
                }
                monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                    let point = NSEvent.mouseLocation
                    let type = event.type, clicks = event.clickCount
                    onMainActor { self?.handle(type, at: point, clicks: clicks) }
                }
            } else {
                if let monitor { NSEvent.removeMonitor(monitor) }
                if let localMonitor { NSEvent.removeMonitor(localMonitor) }
                monitor = nil
                localMonitor = nil
            }
        }
    }

    private func handle(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int) {
        if type == .leftMouseDown {
            downAt = clicks == 1 && Self.windowUnder(point).0 ? point : nil
            return
        }
        // A plain click: not a drag (a selection rectangle), not a double-click.
        guard let start = downAt, hypot(point.x - start.x, point.y - start.y) < 5 else { downAt = nil; return }
        downAt = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            Self.finderSelectionIsEmpty { answer in
                if answer == nil { Log.write("desktop click: Finder didn't answer (is Himawari allowed to control Finder?)") }
                if answer == "0" { self?.onChange?(true) }
            }
        }
    }

    /// Is the frontmost window under the pointer Finder's desktop-icons window? (and what it was, for the log)
    private static func windowUnder(_ point: NSPoint) -> (Bool, String) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return (false, "?") }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let p = CGPoint(x: point.x, y: mainHeight - point.y) // window bounds are top-left based
        let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let screenSize = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.frame.size ?? .zero
        let me = ProcessInfo.processInfo.processIdentifier
        // The list runs front to back: the first window containing the point is the one clicked.
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.contains(p) else { continue }
            let level = info[kCGWindowLayer as String] as? Int ?? 0
            if level > desktopLevel, (info[kCGWindowOwnerName as String] as? String) != "Finder" || level != desktopLevel {
                // Something above the desktop (an app window, the Dock, the menu bar) took the click…
                // …unless it's a click-through overlay of ours, like the desktop clock.
                let owner = info[kCGWindowOwnerName as String] as? String ?? ""
                if owner.hasPrefix("Himawari") { continue }
                // Notification Center's desktop-widget canvas: one transparent window over the
                // whole desktop. A click on empty desktop lands on it first; look past it.
                if owner == "Notification Center", bounds.width >= screenSize.width * 0.95, bounds.height >= screenSize.height * 0.95 {
                    continue
                }
                return (false, "\(owner) (layer \(level))")
            }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            return (owner == "Finder" && level == desktopLevel, "\(owner) (layer \(level - desktopLevel) above the icons)")
        }
        return (false, "nothing")
    }

    private static func finderSelectionIsEmpty(_ done: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"Finder\" to return (count of (get selection)) as text"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var answer: String?
            if (try? p.run()) != nil { // never ask a process that didn't start for its status: that throws
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    answer = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let result = answer
            DispatchQueue.main.async { onMainActor { done(result) } }
        }
    }
}
