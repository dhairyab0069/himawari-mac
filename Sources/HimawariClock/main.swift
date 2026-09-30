import AppKit
import HimawariKit

// The desktop clock: a small helper app inside Himawari.app. Himawari starts it and stops it;
// if Himawari ever goes away without saying so (a crash), the clock notices and quits too.
runBackgroundService {
    let clock = DesktopClock()
    clock.refresh()
    Settings.onChange { clock.refresh() }
    NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in
        onMainActor { clock.refresh() }
    }
    if let i = CommandLine.arguments.firstIndex(of: "--parent"), i + 1 < CommandLine.arguments.count,
       let parent = pid_t(CommandLine.arguments[i + 1]) {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            if kill(parent, 0) != 0 { exit(0) }
        }.tolerance = 1
    }
    return clock
}
