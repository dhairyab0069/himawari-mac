import AppKit
import HimawariKit

// A menu-bar-only app: no Dock icon, no main window.
onMainActor {
    if StylePreview.run(CommandLine.arguments) || Updater.tryUpdate(CommandLine.arguments) { exit(0) }
    if CommandLine.arguments.contains("--voice-check") {
        let files = Array(CommandLine.arguments.drop(while: { $0 != "--voice-check" }).dropFirst())
        exit(VoiceCheck.run(files))
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() } // app.delegate is weak; keep ours alive
}
