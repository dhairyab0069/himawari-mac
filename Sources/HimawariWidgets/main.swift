import AppKit
import HimawariKit

// Background service "Desktop Widgets": calendar, battery, CPU & memory, storage
// in a floating panel. Started at login by launchd (restarted if it ever
// crashes), independent of the wallpaper app.
runBackgroundService(onQuit: { DesktopLayout.setZone(.widgets, nil) }) {
    let widgets = SideWidgets()
    widgets.refresh()
    Settings.onChange { widgets.refresh() }
    PowerState.onChange { widgets.rebuild() } // Battery Saver on/off: redraw with / without live blur
    NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in
        onMainActor { widgets.refresh() }
    }
    return widgets
}
