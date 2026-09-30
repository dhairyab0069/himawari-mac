import AppKit
import SwiftUI

/// Window layers on the desktop, counted up from the system wallpaper.
/// Finder's desktop icons live in a full-screen window at +20 that swallows
/// every desktop click, so anything clickable must sit above it. App windows
/// are far above all of these.
public enum DesktopLayer {
    public static let video = 1        // Himawari's video wallpaper
    public static let decorations = 2  // the clock (click-through, so below Finder is fine)
    public static let folders = 22     // folder dock: above Finder's icons so clicks reach it
    public static let overlay = 23     // an opened folder

    public static func level(_ offset: Int) -> NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + offset)
    }
}

/// A borderless, transparent window that lives on the desktop and stays put
/// on every Space. `interactive: false` lets every click pass straight through.
public final class DesktopWindow: NSWindow {
    public init(layer: Int, interactive: Bool) {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        level = DesktopLayer.level(layer)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = !interactive
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
    }

    // Borderless windows refuse keyboard focus by default; interactive ones
    // need it so Escape can close an open folder.
    override public var canBecomeKey: Bool { !ignoresMouseEvents }

    /// Put a SwiftUI view in the window and size the window to fit it.
    public func host<V: View>(_ view: V) {
        let hosting = FirstClickHostingView(rootView: view)
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }
}

/// Reacts to the very first click even though Himawari isn't the active app
/// (otherwise the first click would only activate it).
public final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Start a background service: no Dock icon, no menu-bar icon, just its windows.
/// `make` builds the service's controller, which is kept alive while it runs.
/// `onQuit` runs when the service is stopped (launchd sends SIGTERM, e.g. via
/// `desktopctl stop`), so it can undo what it changed, like hiding the Dock.
public func runBackgroundService(onQuit: @escaping @MainActor () -> Void = {},
                                 _ make: @escaping @MainActor () -> AnyObject) -> Never {
    onMainActor {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // no Dock icon, no menu bar (LSUIElement), but can take Esc
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            onMainActor { onQuit() }
            exit(0)
        }
        term.resume()
        let service = make()
        withExtendedLifetime((service, term)) { app.run() }
    }
    exit(0)
}
