import AppKit
import HanabiKit

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
    private var downAt: NSPoint?

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled {
                monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                    let point = NSEvent.mouseLocation
                    let type = event.type, clicks = event.clickCount
                    onMainActor { self?.handle(type, at: point, clicks: clicks) }
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }

    private func handle(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int) {
        if type == .leftMouseDown {
            downAt = clicks == 1 && Self.desktopIsUnder(point) ? point : nil
            return
        }
        // A plain click: not a drag (a selection rectangle), not a double-click.
        guard let start = downAt, hypot(point.x - start.x, point.y - start.y) < 5 else { downAt = nil; return }
        downAt = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            Self.finderSelectionIsEmpty { empty in if empty { self?.onChange?(true) } }
        }
    }

    /// Is the frontmost window under the pointer Finder's desktop-icons window?
    private static func desktopIsUnder(_ point: NSPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let p = CGPoint(x: point.x, y: mainHeight - point.y) // window bounds are top-left based
        let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
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
                if owner.hasPrefix("Hanabi") { continue }
                return false
            }
            return (info[kCGWindowOwnerName as String] as? String) == "Finder" && level == desktopLevel
        }
        return false
    }

    private static func finderSelectionIsEmpty(_ done: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"Finder\" to return (count of (get selection)) as text"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { onMainActor { done(out == "0") } }
        }
    }
}
