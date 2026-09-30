import Foundation

/// The system's Now Playing state (what Control Center shows), pushed the moment it changes:
/// play, pause, seek, skip. macOS only lets Apple's own programs read it, so the bundled
/// helper (helpers/NowPlayingHelper.m) runs inside Apple's /usr/bin/perl, which may, and
/// prints one JSON line per change. If it can't run (a future macOS closes the door), this
/// simply reports nothing and callers keep asking Music over AppleScript.
public final class SystemNowPlaying: @unchecked Sendable {
    public struct State: Sendable {
        public let pid: Int32
        public let title: String?, artist: String?, album: String?
        public let duration: Double
        /// `elapsed` seconds were true at `timestamp` (Unix time), moving at `rate` (0 = paused).
        public let elapsed: Double, rate: Double, timestamp: Double
        /// The cover Music shows: its identifier (a URL for streamed songs), and its image
        /// (only in the first message after the cover changes).
        public let artworkID: String?
        public let artwork: Data?
    }

    private static let glue = """
    require DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0]) or die DynaLoader::dl_error(); \
    my $s = DynaLoader::dl_find_symbol($l, "himawari_now_playing") or die "no symbol"; \
    DynaLoader::dl_install_xsub("main::run", $s); run();
    """

    private let helper: URL
    private let onState: @MainActor (State) -> Void
    private var process: Process?
    private var input: Pipe?
    private var pending = Data()                 // touched only on `queue`
    private let queue = DispatchQueue(label: "local.dhairyabhatia.nowplaying.system")
    private var failures = 0
    private var stopped = false

    public init(helper: URL, onState: @escaping @MainActor (State) -> Void) {
        self.helper = helper
        self.onState = onState
    }

    public func start() {
        stopped = false
        // Downloaded copies are quarantined; /usr/bin/perl won't load a quarantined helper.
        removexattr(helper.path, "com.apple.quarantine", 0)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.glue, helper.path]
        let output = Pipe(), input = Pipe()
        p.standardOutput = output
        p.standardInput = input   // kept open: the helper exits when it closes (when we go)
        p.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // End of file (the helper exited): stop reading, or this handler fires nonstop.
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.helperEnded() }
        }
        do {
            try p.run()
            process = p
            self.input = input
        } catch {
            failures += 1
        }
    }

    /// Crashed or refused: try again a few times, slower each time, then give up (AppleScript remains).
    private func helperEnded() {
        process = nil
        input = nil
        guard !stopped else { return }
        failures += 1
        guard failures <= 5 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(failures) * 2) { [weak self] in
            guard let self, !self.stopped, self.process == nil else { return }
            self.start()
        }
    }

    public func stop() {
        stopped = true
        process?.terminate()
        process = nil
        input = nil
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let state = State(pid: (json["pid"] as? NSNumber)?.int32Value ?? 0,
                              title: json["title"] as? String, artist: json["artist"] as? String,
                              album: json["album"] as? String,
                              duration: (json["duration"] as? NSNumber)?.doubleValue ?? 0,
                              elapsed: (json["elapsed"] as? NSNumber)?.doubleValue ?? 0,
                              rate: (json["rate"] as? NSNumber)?.doubleValue ?? 0,
                              timestamp: (json["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970,
                              artworkID: json["artworkID"] as? String,
                              artwork: (json["artwork"] as? String).flatMap { Data(base64Encoded: $0) })
            let deliver = onState
            DispatchQueue.main.async { [weak self] in
                self?.failures = 0 // it works: a later failure starts the retries over
                onMainActor { deliver(state) }
            }
        }
    }
}
