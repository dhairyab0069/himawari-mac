import AppKit
import ApplicationServices
import HimawariKit

/// Keeps other apps' windows out of the strips reserved for the widgets,
/// folders and taskbar, the way a Linux tiling window manager respects panels.
///
/// Once a second it looks for normal app windows that overlap the widgets or
/// folders strip and moves / shrinks them into the free area using the
/// Accessibility API. (The taskbar strip is left alone: maximize already stops
/// above it, and you may drag windows down behind it on purpose.) After
/// every move it checks where the window really landed (apps with a minimum
/// size may refuse to shrink) and always keeps it fully on screen. We never fight you:
/// nothing happens while a mouse button is held (e.g. while you drag a window);
/// the window is fitted when you let go.
///
/// Needs: System Settings → Privacy & Security → Accessibility → Himawari.
@MainActor
final class WindowTiler {
    private var timer: Timer?
    private let me = ProcessInfo.processInfo.processIdentifier
    private var prompted = false

    /// True once the user has granted Accessibility access.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    func refresh() {
        guard Settings.shared.keepWindowsClear else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return } // already running; it re-reads the zones every tick
        print(Self.isTrusted ? "window tiler on" : "window tiler waiting for Accessibility access (XP Taskbar)")
        fflush(stdout)
        if !Self.isTrusted && !prompted {
            prompted = true
            // Shows the system prompt (once); we keep checking until it's granted.
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        startTimer()
        PowerState.onChange { [weak self] in self?.startTimer() } // Battery Saver: check half as often
        tick()
    }

    private func startTimer() {
        guard Settings.shared.keepWindowsClear else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: PowerState.saving ? 2.0 : 1.0, repeats: true) { [weak self] _ in
            onMainActor { self?.tick() }
        }
    }

    private func tick() {
        guard Self.isTrusted, NSEvent.pressedMouseButtons == 0, let screen = NSScreen.main else { return }
        // Only the widgets / folders strips are kept clear. The taskbar's strip isn't:
        // maximize/zoom already stop above it (the tiny Dock under it reserves the
        // space), and you're free to drag a window down behind it on purpose.
        let zones = DesktopLayout.Zone.allCases.filter { $0 != .taskbar }.compactMap(DesktopLayout.zone).map(DesktopLayout.toTopLeft)
        // Where windows pushed out of a strip go: between the menu bar and the top of
        // the taskbar, minus the widgets / folders strips.
        let usable = DesktopLayout.toTopLeft(screen.visibleFrame)   // menu bar → top of the taskbar
        let free = DesktopLayout.toTopLeft(DesktopLayout.freeArea(of: screen)).intersection(usable)
        guard !free.isNull, free.width > 200, free.height > 150 else { return } // a broken layout: don't touch anything
        let screenRect = DesktopLayout.toTopLeft(screen.frame)

        // Cheap first pass with CGWindowList: which windows break the rules?
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return }
        var offenders: [pid_t: [CGRect]] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width > 80, bounds.height > 80, // skip tooltips, popovers
                  screenRect.contains(CGPoint(x: bounds.midX, y: bounds.midY))
            else { continue }
            if zones.contains(where: { $0.intersects(bounds) }) { offenders[pid, default: []].append(bounds) }
        }

        // Second pass with Accessibility: find those exact windows and fit them.
        for (pid, frames) in offenders {
            let app = AXUIElementCreateApplication(pid)
            guard let windows: [AXUIElement] = Self.attribute(app, kAXWindowsAttribute) else { continue }
            for window in windows {
                guard let frame = Self.frame(of: window),
                      frames.contains(where: { abs($0.minX - frame.minX) < 3 && abs($0.minY - frame.minY) < 3 }),
                      (Self.attribute(window, kAXSubroleAttribute) as String?) == (kAXStandardWindowSubrole as String),
                      (Self.attribute(window, "AXFullScreen") as Bool?) != true
                else { continue }
                let target = Self.fit(frame, into: free)
                guard target != frame else { continue }
                Self.setFrame(target, of: window)

                // Apps with a minimum size may refuse to shrink. Check where the window we just
                // moved really ended up, and keep it fully on screen (above the taskbar).
                if let actual = Self.frame(of: window) {
                    let onScreen = Self.fit(actual, into: usable, allowShrink: false)
                    if onScreen != actual { Self.setPosition(onScreen.origin, of: window) }
                }
            }
        }
    }

    /// Slide (and, if allowed, shrink) `frame` so it lies inside `area`. If it's
    /// still too big, keep its top-left corner visible (title bar reachable).
    private static func fit(_ frame: CGRect, into area: CGRect, allowShrink: Bool = true) -> CGRect {
        var f = frame
        if allowShrink {
            f.size.width = min(f.width, area.width)
            f.size.height = min(f.height, area.height)
        }
        f.origin.x = f.width >= area.width ? area.minX : min(max(f.minX, area.minX), area.maxX - f.width)
        f.origin.y = f.height >= area.height ? area.minY : min(max(f.minY, area.minY), area.maxY - f.height)
        return f.integral
    }

    // MARK: - Accessibility helpers

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private static func setPosition(_ origin: CGPoint, of window: AXUIElement) {
        var pos = origin
        guard let value = AXValueCreate(.cgPoint, &pos) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var pos = frame.origin, size = frame.size
        guard let posValue = AXValueCreate(.cgPoint, &pos), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        // Move, resize, move again: some apps clamp the size against their old position.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
    }
}
