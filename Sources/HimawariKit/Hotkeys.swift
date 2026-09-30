import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - ⌘⌃T and other system-wide shortcuts

/// A system-wide keyboard shortcut, via Carbon hot keys (needs no permissions).
@MainActor
public final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    /// Returns nil if macOS refuses the shortcut (e.g. another app already owns it).
    public init?(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping () -> Void) {
        self.id = id
        Self.actions[id] = action
        Self.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x484E_4249), id: id) // 'HNBI'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Self.actions[id] = nil
            return nil
        }
    }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async { onMainActor { HotKey.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Ghostty

@MainActor
public enum Ghostty {
    public static let bundleID = "com.mitchellh.ghostty"

    /// Like Ubuntu's Ctrl+Alt+T: every press gives you a NEW terminal right where
    /// you are, and never jumps to another Space.
    ///
    /// Why this is fiddly on a Mac: when an app is brought forward, macOS jumps
    /// to a Space where that app already has windows. Asking the running Ghostty
    /// for a window (or for its Quick Terminal via one of its windows) brings it
    /// forward first, so you'd be thrown back to the Space its other windows are on.
    ///
    /// • Normal desktop: start a fresh Ghostty instance for the window. It has no
    ///   windows anywhere else, so there's nowhere to jump to; it opens here and
    ///   quits by itself when you close that window.
    /// • Over a full-screen app: macOS never lets a normal window into another
    ///   app's full-screen Space, so press Ghostty's own "Quick Terminal" menu
    ///   item (via Accessibility, without touching any existing window); it drops
    ///   down over the full-screen app. Press again to hide it.
    public static func newWindow() {
        if currentSpaceIsFullScreen() {
            log("⌘⌃T over a full-screen app → Quick Terminal" + (AXIsProcessTrusted() ? "" : " (needs Accessibility)"))
            quickTerminalHere()
        } else {
            log("⌘⌃T → new Ghostty window on this Space")
            freshInstance(["--quit-after-last-window-closed=true"])
        }
    }

    private static func log(_ message: String) {
        print(message)
        fflush(stdout)
    }

    private static var askedForAccessibility = false

    private static var appPath: String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }

    private static func freshInstance(_ settings: [String]) {
        guard let appPath else { return }
        run("/usr/bin/open", ["-na", appPath, "--args"] + settings)
    }

    private static func quickTerminalHere() {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        if let main = instances.first, AXIsProcessTrusted(), pressMenuItem("Quick Terminal", in: main.processIdentifier) {
            return
        }
        if instances.isEmpty {
            // Start Ghostty without a window (a window would pull you out of the full-screen app),
            // then ask for the Quick Terminal once it's up.
            freshInstance(["--initial-window=false"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let main = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    _ = pressMenuItem("Quick Terminal", in: main.processIdentifier)
                }
            }
            return
        }
        // No Accessibility access: the only other way in would switch Spaces (the thing
        // we're avoiding), so say what's missing instead of jumping.
        run("/usr/bin/osascript", ["-e", "display notification \"Allow Desktop Hotkeys in Privacy & Security → Accessibility so ⌘⌃T can open a terminal over full-screen apps.\" with title \"⌘⌃T needs Accessibility\""])
        if !askedForAccessibility {
            askedForAccessibility = true
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Press an item in an app's menu bar by its title, without bringing the app forward.
    private static func pressMenuItem(_ title: String, in pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let bar: AXUIElement = element(app, kAXMenuBarAttribute),
              let menus: [AXUIElement] = attribute(bar, kAXChildrenAttribute) else { return false }
        for menuBarItem in menus {
            for menu in (attribute(menuBarItem, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for item in (attribute(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                    if (attribute(item, kAXTitleAttribute) as String?) == title {
                        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                    }
                }
            }
        }
        return false
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
    }

    /// Is the frontmost app full screen? Its window then covers the entire
    /// display, menu-bar area included (a merely maximized window doesn't).
    /// Reads window positions only, which needs no permission.
    public static func currentSpaceIsFullScreen() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID else { return false }
        return FullScreen.frontAppIsFullScreen()
    }
}

/// Is the frontmost app full screen? Its window then covers the entire display,
/// menu-bar area included (a merely maximized window doesn't). Reads window
/// positions only, which needs no permission.
@MainActor
public enum FullScreen {
    /// Is the frontmost app in full screen? Its window then spans the whole width
    /// and reaches the very bottom of the display. (On a MacBook with a notch it
    /// stops *below* the menu-bar strip at the top, so "covers the whole display"
    /// isn't the test.) Normal windows never reach the bottom edge: the Dock's
    /// strip under the taskbar keeps them above it. Reads window positions only,
    /// which needs no permission.
    public static func frontAppIsFullScreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let screen = NSScreen.main,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let full = CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        let notch = screen.safeAreaInsets.top
        let menuBar = max(notch, NSStatusBar.system.thickness)
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict) else { return false }
            return abs(b.minX - full.minX) < 2 && abs(b.width - full.width) < 2   // full width
                && b.minY <= full.minY + menuBar + 1                               // starts at the top (or just below the notch)
                && b.maxY >= full.maxY - 1                                         // and reaches the very bottom
        }
    }
}

@MainActor
public enum Keys {
    public static func press(_ key: Int, flags: CGEventFlags, to pid: pid_t? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
            event.flags = flags
            if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
        }
    }

    /// ⌘Space opens Spotlight (needs Accessibility access to send keys).
    public static func spotlight() {
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { press(kVK_Space, flags: .maskCommand) }
    }
}
