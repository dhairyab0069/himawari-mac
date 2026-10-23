import AppKit
import HimawariKit

/// Keeps Himawari up to date: looks for a newer release on GitHub (at launch, then once a day,
/// unless turned off), says so in the menu, and on your OK downloads the disk image, puts the new
/// Himawari in place of this one and opens it.
@MainActor
final class Updater {
    /// A newer release than this one, once found.
    private(set) var available: Release?
    /// "Checking…", "Up to date (Beta 1.5.1)", "Couldn't check": for the menu.
    private(set) var status = ""
    private(set) var installing = false
    var onChange: () -> Void = {}
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    nonisolated private static let latest = URL(string: "https://api.github.com/repos/dhairyab0069/himawari-io/releases/latest")!
    nonisolated static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// Look at launch (after a moment) and once a day after that.
    var automatic: Bool {
        get { defaults.object(forKey: "checkForUpdates") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "checkForUpdates"); schedule() }
    }

    func start() {
        schedule()
        guard automatic else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.check(announce: true) }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            onMainActor { self?.check(announce: true) }
        }
        timer?.tolerance = 600
    }

    /// Asks GitHub for the latest release. `announce`: on finding a version not yet mentioned,
    /// say so once (an automatic check). `interactive`: the menu asked, so always answer.
    func check(announce: Bool = false, interactive: Bool = false) {
        status = "Checking…"
        onChange()
        Task { [weak self] in
            var request = URLRequest(url: Self.latest, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Himawari/\(Self.current)", forHTTPHeaderField: "User-Agent")
            let found: Release? = await {
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return Release(json: json)
            }()
            guard let self else { return }
            guard let found else {
                self.status = "Couldn't check for updates"
                self.onChange()
                if interactive { self.alert("Couldn't check for updates", "GitHub didn't answer. Try again later.") }
                return
            }
            if Release.isNewer(found.version, than: Self.current) {
                self.available = found
                self.status = "\(found.name) is available"
                Log.write("updates: \(found.version) is available (this is \(Self.current))")
                self.onChange()
                if interactive || (announce && self.defaults.string(forKey: "announcedUpdate") != found.version) {
                    self.defaults.set(found.version, forKey: "announcedUpdate")
                    self.offer(found)
                }
            } else {
                self.available = nil
                self.status = "Up to date (Beta \(Self.current))"
                self.onChange()
                if interactive { self.alert("Himawari is up to date", "Beta \(Self.current) is the newest version.") }
            }
        }
    }

    /// "Beta 1.5.1 is out: …  [Update Now] [Later] [Release Notes]"
    func offer(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(release.name) is out"
        a.informativeText = "You have Beta \(Self.current).\n\n" + release.summary
        a.addButton(withTitle: "Update Now")
        a.addButton(withTitle: "Later")
        if release.page != nil { a.addButton(withTitle: "Release Notes") }
        switch a.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: release.page.map { _ = NSWorkspace.shared.open($0) }
        default: break
        }
    }

    // MARK: Installing

    /// Downloads the disk image, copies the new Himawari over this one, and opens it. If the copy
    /// can't be made (no permission to write where Himawari lives), opens the download instead.
    func install(_ release: Release) {
        guard !installing, let dmg = release.dmg else { release.page.map { _ = NSWorkspace.shared.open($0) }; return }
        installing = true
        status = "Downloading \(release.name)…"
        onChange()
        let target = Bundle.main.bundleURL
        Task { [weak self] in
            let result = await Self.download(dmg, into: target) // off the main thread (nonisolated)
            do {
                guard let self else { return }
                self.installing = false
                switch result {
                case .success:
                    Log.write("updates: installed \(release.version); reopening")
                    // Open the new copy once this one has quit (from a shell that outlives it).
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/sh")
                    p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(target.path)\""]
                    try? p.run()
                    NSApp.terminate(nil)
                case .failure(let error):
                    Log.write("updates: couldn't install \(release.version): \(error.message)")
                    self.status = "Couldn't install the update"
                    self.onChange()
                    self.alert("Couldn't install \(release.name)", error.message + "\n\nThe disk image will open so you can drag Himawari to Applications yourself.")
                    NSWorkspace.shared.open(dmg)
                }
            }
        }
    }

    struct Failure: Error { let message: String }

    /// `Himawari --try-update <some.app>`: installs the latest release over that app (not this one),
    /// to try the whole download, mount, copy and swap without touching the real Himawari.
    static func tryUpdate(_ arguments: [String]) -> Bool {
        guard let i = arguments.firstIndex(of: "--try-update"), i + 1 < arguments.count else { return false }
        let target = URL(fileURLWithPath: arguments[i + 1])
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            var request = URLRequest(url: latest)
            request.setValue("Himawari/\(current)", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let release = Release(json: json), let dmg = release.dmg else { print("no release"); done.signal(); return }
            print("latest: \(release.version) (\(dmg.lastPathComponent))")
            switch await download(dmg, into: target) {
            case .success: print("installed into \(target.path)")
            case .failure(let f): print("failed: \(f.message)")
            }
            done.signal()
        }
        done.wait()
        return true
    }

    /// Download → mount → copy the app next to the old one → swap them → unmount.
    nonisolated private static func download(_ dmg: URL, into target: URL) async -> Result<Void, Failure> {
        guard let (file, response) = try? await URLSession.shared.download(from: dmg),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .failure(Failure(message: "The download didn't finish.")) }
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appending(path: "himawari-update-\(UUID().uuidString)")
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"])
            try? fm.removeItem(at: file)
        }
        guard run("/usr/bin/hdiutil", ["attach", file.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) else {
            return .failure(Failure(message: "The disk image wouldn't open."))
        }
        guard let app = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }) else {
            return .failure(Failure(message: "There's no Himawari in the disk image."))
        }
        let staged = target.deletingLastPathComponent().appending(path: ".Himawari-update.app")
        let old = target.deletingLastPathComponent().appending(path: ".Himawari-old.app")
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: old)
        guard run("/usr/bin/ditto", [app.path, staged.path]) else {
            return .failure(Failure(message: "Himawari couldn't write to \(target.deletingLastPathComponent().path)."))
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        do {
            try fm.moveItem(at: target, to: old)
            try fm.moveItem(at: staged, to: target)
            try? fm.removeItem(at: old)
        } catch {
            if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: old, to: target) } // put the old one back
            return .failure(Failure(message: error.localizedDescription))
        }
        return .success(())
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
