import AppKit
import HanabiKit

// A menu-bar-only app: no Dock icon, no main window.
onMainActor {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() } // app.delegate is weak; keep ours alive
}
