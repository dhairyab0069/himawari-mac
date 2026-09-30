import AppKit
import HimawariKit

/// Runs the desktop clock while Himawari runs. The clock is its own small app
/// (Contents/Helpers/Desktop Clock.app), so a problem in one never takes down the other:
/// if the clock stops unexpectedly it's started again, and it quits by itself if Himawari
/// goes away (it's given Himawari's process id).
@MainActor
final class ClockHelper {
    private var process: Process?
    private var stopping = false
    private var restarts: [Date] = []

    private var executable: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/Desktop Clock.app/Contents/MacOS/HimawariClock")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func start() {
        retireOldService()
        guard process == nil, let executable else {
            if executable == nil { Log.write("clock: not included in this build") }
            return
        }
        stopping = false
        let p = Process()
        p.executableURL = executable
        p.arguments = ["--parent", String(ProcessInfo.processInfo.processIdentifier)]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { onMainActor { self?.ended() } }
        }
        do { try p.run(); process = p } catch { Log.write("clock: couldn't start (\(error.localizedDescription))") }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    private func ended() {
        process = nil
        guard !stopping else { return }
        // Start it again, but not in a loop: at most 3 times a minute.
        restarts = restarts.filter { Date().timeIntervalSince($0) < 60 } + [Date()]
        guard restarts.count <= 3 else { Log.write("clock: keeps stopping; leaving it off"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in onMainActor { self?.start() } }
    }

    /// Older versions installed the clock as a separate launchd service. Now that it lives
    /// here, that copy is removed once (nothing else in that folder is touched).
    private func retireOldService() {
        let label = "local.dhairyabhatia.desktop.clock"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appending(path: "Library/LaunchAgents/\(label).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        try? bootout.run()
        bootout.waitUntilExit()
        try? FileManager.default.removeItem(at: plist)
        try? FileManager.default.removeItem(at: home.appending(path: "Library/Application Support/Desktop Shell/Desktop Clock.app"))
        Log.write("clock: moved into Himawari (removed the old background service)")
    }
}
