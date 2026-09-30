import AppKit
import HimawariKit

// Background service: the desktop clock. Started at login by launchd (and
// restarted if it ever crashes), independent of the wallpaper app.
runBackgroundService {
    let clock = DesktopClock()
    clock.refresh()
    Settings.onChange { clock.refresh() }
    NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in
        onMainActor { clock.refresh() }
    }
    return clock
}
