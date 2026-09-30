import AppKit
import HimawariKit

// Background service: the iOS-style desktop folders. Started at login by launchd
// (and restarted if it ever crashes), independent of the wallpaper app.
runBackgroundService(onQuit: { DesktopLayout.setZone(.folders, nil) }) {
    let folders = FileFolders()
    folders.refresh()
    Settings.onChange { folders.refresh() }
    PowerState.onChange { folders.rebuild() }
    NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in
        onMainActor { folders.refresh() }
    }
    return folders
}
