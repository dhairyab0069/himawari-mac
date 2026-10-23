import QuartzCore
import AppKit
import AVFoundation
import SwiftUI
import WebKit

/// What's playing, in whichever player (Apple Music, Spotify, a browser…), plus Apple Music's
/// "motion artwork" (the looping cover videos the Music app shows) when the album has one.
///
/// • Any player: the system's Now Playing stream (SystemNowPlaying) gives the song, its timing
///   and the exact cover, and takes play/pause/skip/seek back to the player. `choice` decides
///   which players are followed (see PlayerSource.swift).
/// • Apple Music, in more depth: track changes come from the Music app's own announcements (no permission).
/// • Position, cover art and the ⏮ ⏯ ⏭ controls talk to Music via AppleScript
///   (macOS asks once: "… wants to control Music").
/// • Motion artwork: Apple's public iTunes Search API finds the album, and the
///   album's public Apple Music web page lists its motion-artwork video. That
///   page isn't an official API, so if Apple changes it, the loop quietly falls
///   back to the still cover. (Apple's official Apple Music API needs a paid
///   developer account.)
@MainActor
public final class MusicNowPlaying: ObservableObject {
    public struct Track: Equatable {
        public let name: String
        public let artist: String
        public let album: String
        public let duration: Double // seconds

        // Same song whichever source reports it (they round the duration differently).
        public static func == (a: Track, b: Track) -> Bool { a.name == b.name && a.artist == b.artist && a.album == b.album }
    }

    @Published public private(set) var track: Track?
    /// The player being followed (nil: none yet), and its process.
    @Published public private(set) var player: PlayerKind?
    @Published public private(set) var playerPID: pid_t?
    public private(set) var playerBundleID: String?
    /// What the gear can do with that player.
    public var capabilities: PlayerCapabilities { (player ?? .appleMusic).capabilities }
    /// Which players to follow (the Players menu). Turning off the one playing lets it go.
    public var choice = PlayerChoice() {
        didSet {
            if let player, !choice.follows(player) { leavePlayer() }
            // Look again for a player that's allowed now and already playing.
            refresh()
            system?.send(.refresh)
        }
    }
    /// When a song was last playing (a skip reads as "not playing" for a moment).
    private var lastPlayingAt = -Double.infinity
    private var playingRecently: Bool { isPlaying || CACurrentMediaTime() - lastPlayingAt < 3 }
    /// Apple's Music app is the one followed (or nothing else is): AppleScript may be used.
    private var onAppleMusic: Bool { player == nil || player == .appleMusic }
    @Published public private(set) var isPlaying = false
    @Published public private(set) var position: Double = 0
    /// Music's last actual reading of the position, and when it was taken (CACurrentMediaTime),
    /// for displays that keep their own steady clock between readings.
    public private(set) var measuredPosition: Double = 0
    public private(set) var measuredAt: Double = CACurrentMediaTime()
    @Published public private(set) var artwork: NSImage?
    @Published public private(set) var motionVideo: URL?
    /// The song's genre from Apple's catalog ("Hip-Hop/Rap"), once the lookup has found it.
    @Published public private(set) var genre: String?
    /// YouTube videos to loop when the album has no motion artwork (tried in order).
    @Published public private(set) var youtubeVideos: [String] = []
    /// Still looking for this song's motion artwork / YouTube video.
    @Published public private(set) var searching = false {
        didSet { if !searching { offerFallbackSoon() } }
    }
    /// A plain disc label with the title, for a song nobody has a cover for (a web player that
    /// shares none, say). Kept apart from `artwork`, so a real cover arriving late still wins.
    @Published public private(set) var fallbackArtwork: NSImage?
    /// What to print on the CD: the cover, or the plain label.
    public var displayArtwork: NSImage? { artwork ?? fallbackArtwork }
    /// The player has reported a real position for this song (Firefox, on many sites, never does).
    private var reportsPosition = false
    /// Look for a YouTube loop when there's no motion artwork.
    public var youtubeFallback = true
    /// Keep the song position up to date (the widget's progress bar). Himawari doesn't need it,
    /// and then no per-second timer runs at all.
    public var tracksPosition = true {
        didSet { if tracksPosition != oldValue { tracksPosition ? startTicking() : stopTicking() } }
    }

    private var timer: Timer?
    /// The system's Now Playing stream: instant play/pause/seek, exact position (see SystemNowPlaying).
    private var system: SystemNowPlaying?
    private var systemAt = -Double.infinity
    private var systemArtworkGeneration = -1 // the song whose cover came from the system (the exact one)
    /// Heard from the system stream about Music recently (it sends a heartbeat every 5 s).
    private var systemLive: Bool { CACurrentMediaTime() - systemAt < 12 }
    private var ticks = 0
    private var generation = 0
    private var shownArtwork: (id: String?, album: String)? // the system cover last used, and its album
    private let artworkFile = FileManager.default.temporaryDirectory
        .appending(path: "now-playing-\(ProcessInfo.processInfo.processIdentifier).img")
    private static var motionCache: [String: (result: MotionArtwork.Result, at: Date)] = [:]
    private static var youtubeCache: [String: (ids: [String], at: Date)] = [:]
    /// "Nothing found" may only mean the network was down (just after waking, say): look again after this long.
    private static let retryEmptyAfter: TimeInterval = 120
    private static func fresh(_ found: Bool, _ at: Date) -> Bool { found || Date().timeIntervalSince(at) < retryEmptyAfter }
    private static let music = "com.apple.Music"
    static let spotify = "com.spotify.client"

    public init() {
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil,
                                                            queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let name = info["Name"] as? String, artist = info["Artist"] as? String ?? "", album = info["Album"] as? String ?? ""
            let state = info["Player State"] as? String ?? ""
            let total = (info["Total Time"] as? Double ?? Double(info["Total Time"] as? Int ?? 0)) / 1000
            onMainActor {
                guard let self, self.choice.follows(.appleMusic) else { return }
                // Another player is followed: Music takes over only by starting to play.
                guard self.onAppleMusic || state == "Playing" else { return }
                if state == "Stopped" || name == nil {
                    if self.player == .appleMusic { self.leavePlayer() }
                } else if let name {
                    self.follow(.appleMusic, pid: NSRunningApplication.runningApplications(withBundleIdentifier: Self.music).first?.processIdentifier,
                                bundleID: Self.music)
                    self.set(track: Track(name: name, artist: artist, album: album, duration: total), playing: state == "Playing")
                    self.refresh()
                }
            }
        }
        refresh()
        startTicking()
        if let helper = Bundle.main.url(forResource: "NowPlayingHelper", withExtension: "dylib") {
            system = SystemNowPlaying(helper: helper) { [weak self] state in self?.apply(state) }
            system?.start()
        }
    }

    /// The exact cover Music is showing, from the system's Now Playing: better than asking Music
    /// (streamed songs have no artwork over AppleScript) or guessing via the iTunes Search API.
    /// For streamed songs it's also on Apple's image server, where a sharper copy can be had.
    private func useSystemArtwork(_ data: Data, id: String?) {
        guard let image = NSImage(data: data) else { return }
        artwork = image
        systemArtworkGeneration = generation
        guard let id, id.hasPrefix("https://"), id.contains("mzstatic.com"),
              let sharp = URL(string: id.replacingOccurrences(of: #"/\d+x\d+bb\.(jpg|png|webp)$"#, with: "/1200x1200bb.jpg",
                                                              options: .regularExpression)) else { return }
        let generation = generation
        Task { [weak self] in
            guard let (bytes, _) = try? await URLSession.shared.data(from: sharp), let big = NSImage(data: bytes),
                  let self, self.generation == generation else { return }
            self.artwork = big
        }
    }

    /// A disc label for a song with no cover: a soft gradient picked from the title, with the
    /// title and artist printed on it.
    static func placeholderCover(for track: Track) -> NSImage {
        let seed = track.name.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        let hue = CGFloat(seed % 360) / 360
        let size = NSSize(width: 600, height: 600)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(hue: hue, saturation: 0.55, brightness: 0.55, alpha: 1),
                                NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.25, alpha: 1)])?
                .draw(in: rect, angle: -60)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            let title = NSAttributedString(string: track.name, attributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: style])
            let artist = NSAttributedString(string: track.artist, attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.75), .paragraphStyle: style])
            // Above the hub, where the print stays readable.
            title.draw(in: NSRect(x: 50, y: 400, width: 500, height: 84))
            artist.draw(in: NSRect(x: 50, y: 365, width: 500, height: 32))
            return true
        }
    }

    /// A change pushed by the system's Now Playing: whichever app the system says is playing.
    private func apply(_ s: SystemNowPlaying.State) {
        // Never follow ourselves: the YouTube loop on the wallpaper plays in a web view, which can
        // report itself as Now Playing.
        guard s.pid != ProcessInfo.processInfo.processIdentifier else { return }
        let app = s.pid > 0 ? NSRunningApplication(processIdentifier: s.pid) : nil
        let kind = PlayerKind(bundleID: app?.bundleIdentifier)
        guard let title = s.title, !title.isEmpty, app != nil else {
            // Nothing playing any more (the player stopped or quit). Music says so itself.
            if player != nil, player != .appleMusic, s.pid == playerPID || app == nil { leavePlayer() }
            return
        }
        guard choice.follows(kind) else {
            // A player that's turned off (or not the pinned one) took the system's Now Playing
            // slot by playing: the followed app (not Music, which announces itself) can't be heard
            // from any more, so don't keep spinning its CD as if it still played.
            if s.rate > 0, let player, player != .appleMusic, isPlaying { isPlaying = false }
            return
        }
        if s.pid != playerPID, !PlayerChoice.switches(fromPlaying: playingRecently, toPlaying: s.rate > 0) { return }
        follow(kind, pid: s.pid, bundleID: app?.bundleIdentifier)
        systemAt = CACurrentMediaTime()
        let playing = s.rate > 0
        let newTrack = Track(name: title, artist: s.artist ?? "", album: s.album ?? "", duration: s.duration)
        let sameSong = newTrack == track
        let estimate = measuredPosition + (isPlaying ? CACurrentMediaTime() - measuredAt : 0)
        set(track: newTrack, playing: playing)
        // Right after a skip the system can still hand over the last song's cover: the same
        // artwork for a different album is that, not this song's.
        let album = s.album ?? ""
        let stale = s.artworkID != nil && s.artworkID == shownArtwork?.id && album != shownArtwork?.album
        if let data = s.artwork, !stale {
            shownArtwork = (s.artworkID, album)
            useSystemArtwork(data, id: s.artworkID)
        }
        let age = max(0, Date().timeIntervalSince1970 - s.timestamp) // how old the reading is
        // Some web players never report a position (Firefox on many sites says 0 every time):
        // keep counting ourselves instead of jumping back to the start.
        if s.elapsed > 0.5 { reportsPosition = true }
        guard Self.trustsElapsed(s.elapsed, estimate: estimate, sameSong: sameSong, reportsPosition: reportsPosition) else { return }
        measuredPosition = s.elapsed
        measuredAt = CACurrentMediaTime() - age
        position = playing ? s.elapsed + age * s.rate : s.elapsed
    }

    /// A reading of ~0 s for a song we've been counting is ignored only from a player that has
    /// never reported a real position for it (it just doesn't know its position). From any other
    /// player, 0 is real: a restart, repeat-one, or a seek back to the start.
    nonisolated static func trustsElapsed(_ elapsed: Double, estimate: Double, sameSong: Bool, reportsPosition: Bool) -> Bool {
        !(sameSong && !reportsPosition && elapsed < 0.5 && estimate > 3)
    }

    /// Done looking for a cover: if none turns up within a moment (Music's own AppleScript cover
    /// and the system's take a few hundred ms), offer the plain label.
    private func offerFallbackSoon() {
        guard artwork == nil, track != nil else { return }
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            onMainActor {
                guard let self, self.generation == generation, self.artwork == nil, let track = self.track else { return }
                self.fallbackArtwork = Self.placeholderCover(for: track)
            }
        }
    }

    /// Keep the progress bar moving: count the seconds ourselves, and only ask Music
    /// (a separate process each time) every 5 s to stay in sync.
    private func startTicking() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPlaying, tracksPosition else { return }
        if systemLive { // exact: from the last pushed reading, no need to ask Music
            position = min(measuredPosition + (CACurrentMediaTime() - measuredAt), track?.duration ?? .infinity)
            return
        }
        position = min(position + 1, track?.duration ?? .infinity)
        ticks += 1
        if ticks % 5 == 0, onAppleMusic { refresh() } // other players can't be asked: the stream will say
        // The followed app quit without a word: let it go.
        if let pid = playerPID, player != .appleMusic, NSRunningApplication(processIdentifier: pid) == nil { leavePlayer() }
    }

    // MARK: Which player

    private func follow(_ kind: PlayerKind, pid: pid_t?, bundleID: String?) {
        if player != kind { player = kind }
        playerPID = pid
        playerBundleID = bundleID
    }

    /// The followed player stopped, quit, or was turned off: nothing is playing.
    private func leavePlayer() {
        player = nil
        playerPID = nil
        playerBundleID = nil
        set(track: nil, playing: false)
    }

    // MARK: Controls

    // Apple Music by AppleScript (it works even when the system stream doesn't); any other
    // player through the system's remote commands, like Control Center.
    public func playPause() { onAppleMusic ? tell("playpause") : system?.send(.togglePlayPause) }

    /// Jump to a point in the song (seconds).
    public func seek(to seconds: Double) {
        position = seconds // move the bar right away; the player catches up
        measuredPosition = seconds
        measuredAt = CACurrentMediaTime()
        if onAppleMusic { tell("set player position to \(String(format: "%.1f", seconds))") }
        else { system?.send(.seek(to: seconds)) }
    }
    public func pause() { onAppleMusic ? tell("pause") : system?.send(.pause) }
    public func next() { onAppleMusic ? tell("next track") : system?.send(.next) }

    /// The VOLUME knob, 0…100: Apple Music's own volume, or the Mac's output volume for other
    /// players (they can't be asked for theirs). Neither needs a permission beyond Music's.
    public func setVolume(_ percent: Int) {
        let v = max(0, min(100, percent))
        if onAppleMusic { tell("set sound volume to \(v)") }
        else if player == .spotify { tellSpotify("set sound volume to \(v)") }
        // In-process on the one serial script queue: a quick drag's steps arrive in order.
        else { Self.timedScript("set volume output volume \(v)") { _, _ in } }
    }

    /// The words Music has for the song playing (plain text, as shown in Music's lyrics view);
    /// nil for other players, or when Music has none.
    public func fetchAppleMusicLyrics(_ done: @escaping @MainActor (String?) -> Void) {
        guard onAppleMusic else { return done(nil) }
        Self.osascript("tell application id \"\(Self.music)\" to return lyrics of current track") { out in
            done(out.flatMap { $0.isEmpty || $0 == "missing value" ? nil : $0 })
        }
    }

    /// nil when there's no answer (an output with no volume control, like HDMI, says "missing value").
    public func fetchVolume(_ done: @escaping @MainActor (Int?) -> Void) {
        if onAppleMusic {
            Self.osascript("tell application id \"\(Self.music)\" to return sound volume as text") { done($0.flatMap { Int($0) }) }
        } else if player == .spotify {
            guard spotifyRunning else { return done(nil) }
            Self.timedScript("tell application id \"\(Self.spotify)\" to return sound volume as text") { out, _ in done(out.flatMap { Int($0) }) }
        } else {
            Self.timedScript("return (output volume of (get volume settings)) as text") { out, _ in done(out.flatMap { Int($0) }) }
        }
    }
    public func previous() { onAppleMusic ? tell("previous track") : system?.send(.previous) }

    /// What the side gear shows besides the song: Music's volume, its repeat and shuffle
    /// settings, and the BASS / TREBLE of Himawari's equalizer preset.
    public struct Deck: Equatable, Sendable {
        public var volume: Double           // 0…1
        public var repeating: Bool          // repeat all or one
        public var shuffling: Bool
        public var bass: Double             // dB, −12…12 (0 unless Himawari's preset is the one on)
        public var treble: Double
        /// The equalizer as it was, so turning both knobs back to 0 can put it back.
        public var equalizerOn: Bool
        public var preset: String
    }

    /// The equalizer preset the BASS and TREBLE knobs shape (made in Music the first time).
    public static let tonePreset = "Himawari"

    public func fetchDeck(_ done: @escaping @MainActor (Deck?) -> Void) {
        let sep = "\u{1F}"
        if player == .spotify {
            guard spotifyRunning else { return done(nil) } // never relaunch Spotify after it's quit
            // Spotify's dictionary: its own volume (0…100), repeat and shuffle; no equalizer.
            Self.timedScript("""
            tell application id "\(Self.spotify)"
                return (sound volume as text) & "\(sep)" & (repeating as text) & "\(sep)" & (shuffling as text)
            end tell
            """) { output, _ in
                let parts = output?.components(separatedBy: sep) ?? []
                guard parts.count == 3, let volume = Double(parts[0]) else { return done(nil) }
                done(Deck(volume: volume / 100, repeating: parts[1] == "true", shuffling: parts[2] == "true",
                          bass: 0, treble: 0, equalizerOn: false, preset: ""))
            }
            return
        }
        Self.timedScript("""
        tell application id "\(Self.music)"
            set b to 0
            set t to 0
            set pname to ""
            try
                set pname to name of current EQ preset
                if EQ enabled and pname is "\(Self.tonePreset)" then
                    set b to band 1 of current EQ preset
                    set t to band 10 of current EQ preset
                end if
            end try
            return (sound volume as text) & "\(sep)" & (song repeat as text) & "\(sep)" & (shuffle enabled as text) \
        & "\(sep)" & (b as text) & "\(sep)" & (t as text) & "\(sep)" & (EQ enabled as text) & "\(sep)" & pname
        end tell
        """) { output, _ in
            let parts = output?.components(separatedBy: sep) ?? []
            guard parts.count == 7 else { return done(nil) }
            let number = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
            done(Deck(volume: number(parts[0]) / 100, repeating: parts[1] != "off", shuffling: parts[2] == "true",
                      bass: number(parts[3]), treble: number(parts[4]), equalizerOn: parts[5] == "true", preset: parts[6]))
        }
    }

    /// BASS / TREBLE (dB) as Music's ten EQ bands, plus a preamp cut for headroom.
    /// Shelves: the lowest (highest) two bands fully, the next one half; 250 Hz–2 kHz untouched.
    nonisolated static func toneBands(bass: Double, treble: Double) -> (bands: [Double], preamp: Double) {
        let b = min(max(bass, -12), 12), t = min(max(treble, -12), 12)
        return ([b, b, b / 2, 0, 0, 0, 0, t / 2, t, t], -max(b, t, 0) / 2)
    }

    public func setRepeat(_ on: Bool) {
        if player == .spotify { tellSpotify("set repeating to \(on)") } else { tell("set song repeat to \(on ? "all" : "off")") }
    }
    public func setShuffle(_ on: Bool) {
        if player == .spotify { tellSpotify("set shuffling to \(on)") } else { tell("set shuffle enabled to \(on)") }
    }

    /// BASS and TREBLE in dB (−12…12), as shelves on Himawari's equalizer preset, which becomes
    /// Music's current one. Both back at 0 puts back the equalizer as it was (`restore`).
    public func setTone(bass: Double, treble: Double, restore: (on: Bool, preset: String)) {
        let clamp = { (v: Double) in min(max(v, -12), 12) }
        let b = clamp(bass), t = clamp(treble)
        if abs(b) < 0.25 && abs(t) < 0.25 {
            let preset = restore.preset.isEmpty || restore.preset == Self.tonePreset ? "Flat" : restore.preset
            tell("""
            try
                set current EQ preset to EQ preset "\(PlaylistLibrary.escaped(preset))"
            end try
            set EQ enabled to \(restore.on && restore.preset != Self.tonePreset)
            """, block: true)
            return
        }
        let (bands, preamp) = Self.toneBands(bass: b, treble: t)
        let set = bands.enumerated().map { "set band \($0.offset + 1) of p to \(String(format: "%.1f", $0.element))" }
        tell("""
        if not (exists EQ preset "\(Self.tonePreset)") then make new EQ preset with properties {name:"\(Self.tonePreset)"}
        set p to EQ preset "\(Self.tonePreset)"
        \(set.joined(separator: "\n"))
        set preamp of p to \(String(format: "%.1f", preamp))
        set current EQ preset to p
        set EQ enabled to true
        """, block: true)
    }

    /// Brings the player that's playing to the front (Apple Music if none).
    public func openPlayer() {
        if let pid = playerPID, let app = NSRunningApplication(processIdentifier: pid), !onAppleMusic {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.music) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// Spotify, only while it's the player (so a script never launches it).
    private var spotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.spotify).isEmpty
    }

    private func tellSpotify(_ command: String) {
        guard player == .spotify, spotifyRunning else { return }
        Self.timedScript("tell application id \"\(Self.spotify)\" to \(command)") { _, _ in }
    }

    private func tell(_ command: String, block: Bool = false) {
        let source = block ? "tell application id \"\(Self.music)\"\n\(command)\nend tell"
                           : "tell application id \"\(Self.music)\" to \(command)"
        Self.osascript(source) { [weak self] _ in self?.refresh() }
    }

    // MARK: Reading Music's state

    private func refresh() {
        // Only Apple's Music app answers AppleScript like this; don't let it override another player.
        guard onAppleMusic, choice.follows(.appleMusic) else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.music).isEmpty else {
            if player == .appleMusic { leavePlayer() } else { set(track: nil, playing: false) }
            return
        }
        let sep = "\u{1F}"
        Self.timedScript("""
        tell application id "\(Self.music)"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as text) & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) \
        & "\(sep)" & (duration of t) & "\(sep)" & (player position)
        end tell
        """) { [weak self] output, readAt in
            guard let self, let output, self.onAppleMusic else { return }
            let parts = output.components(separatedBy: sep)
            guard parts.count == 6 else {
                if self.player == .appleMusic { self.leavePlayer() } else { self.set(track: nil, playing: false) }
                return
            }
            self.follow(.appleMusic, pid: NSRunningApplication.runningApplications(withBundleIdentifier: Self.music).first?.processIdentifier,
                        bundleID: Self.music)
            let number = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
            self.set(track: Track(name: parts[1], artist: parts[2], album: parts[3], duration: number(parts[4])),
                     playing: parts[0] == "playing")
            guard !self.systemLive else { return } // the system stream is more precise
            self.measuredPosition = number(parts[5])
            self.measuredAt = readAt
            self.position = self.measuredPosition
        }
    }

    private func set(track new: Track?, playing: Bool) {
        isPlaying = playing
        if playing { lastPlayingAt = CACurrentMediaTime() }
        guard new != track else { return }
        track = new
        position = 0
        measuredPosition = 0
        measuredAt = CACurrentMediaTime()
        generation += 1
        youtubeVideos = []
        fallbackArtwork = nil
        reportsPosition = false
        searching = new != nil
        artwork = nil // never show the last song's cover for this one
        guard let new else { artwork = nil; motionVideo = nil; genre = nil; return }
        loadArtwork(for: new, generation: generation)
    }

    private func loadArtwork(for track: Track, generation: Int) {
        // 1) The cover Music has (works for your own imported songs too). Other players' covers
        // come from the system stream (useSystemArtwork) or the catalog search below.
        let path = artworkFile.path
        if onAppleMusic { Self.osascript("""
        tell application id "\(Self.music)" to set d to raw data of artwork 1 of current track
        set f to open for access (POSIX file "\(path)") with write permission
        set eof f to 0
        write d to f
        close access f
        return "ok"
        """) { [weak self] ok in
            guard let self, self.generation == generation, ok == "ok",
                  self.systemArtworkGeneration != generation else { return } // the system's cover is exact
            self.artwork = NSImage(contentsOfFile: path)
        } }
        // 2) Apple Music's motion artwork (and a cover, if Music didn't have one).
        // No album name: key by the song too, or every album-less song by this artist would share one answer.
        let key = track.artist + "|" + (track.album.isEmpty ? "song:" + track.name : track.album)
        if let entry = Self.motionCache[key], Self.fresh(entry.result.video != nil, entry.at) {
            let cached = entry.result
            motionVideo = cached.video
            genre = cached.genre
            if artwork == nil, let cover = cached.cover { fetchImage(cover, generation: generation) }
            if cached.video == nil { findYouTube(for: track, generation: generation) } else { searching = false }
            return
        }
        motionVideo = nil
        // (The genre isn't cleared here: the last one stands until the lookup says, so a look that
        // follows the genre doesn't flip to the default and back with every song.)
        Task { [weak self] in
            // A web player's "song" is often a video title: search with the artist and song in it.
            let names = self?.player == .browser ? WebTitle.clean(title: track.name, artist: track.artist) : (title: track.name, artist: track.artist)
            let result = await MotionArtwork.find(artist: names.artist, album: track.album, song: names.title, duration: track.duration)
            guard let self else { return }
            Self.motionCache[key] = (result, Date())
            guard self.generation == generation else { return }
            self.motionVideo = result.video
            self.genre = result.genre
            if self.artwork == nil, let cover = result.cover { self.fetchImage(cover, generation: generation) }
            if result.video == nil { self.findYouTube(for: track, generation: generation) } else { self.searching = false }
        }
    }

    /// No motion artwork: loop the middle of the song's YouTube video instead.
    private func findYouTube(for track: Track, generation: Int) {
        guard youtubeFallback else { searching = false; return }
        let key = track.artist + "|" + track.name
        if let entry = Self.youtubeCache[key], Self.fresh(!entry.ids.isEmpty, entry.at) { youtubeVideos = entry.ids; searching = false; return }
        Task { [weak self] in
            let ids = await YouTubeLoop.findVideos(artist: track.artist, title: track.name)
            Self.youtubeCache[key] = (ids, Date())
            guard let self, self.generation == generation else { return }
            self.youtubeVideos = ids
            self.searching = false
        }
    }

    private func fetchImage(_ url: URL, generation: Int) {
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data),
                  let self, self.generation == generation, self.artwork == nil else { return }
            self.artwork = image
        }
    }

    /// Runs AppleScript in a separate process, so Music being slow never freezes anything.
    private static func osascript(_ source: String, completion: @escaping @MainActor (String?) -> Void) {
        let done = Completion(completion)
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var output: String?
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let result = output
            DispatchQueue.main.async { onMainActor { done.run(result) } }
        }
    }

    /// Runs AppleScript inside this app (no separate process): an Apple event to Music takes
    /// milliseconds, and timing it on both sides says exactly when Music read its position.
    /// One background queue, so Music being slow never freezes anything.
    private static let scriptQueue = DispatchQueue(label: "local.dhairyabhatia.nowplaying.script", qos: .userInitiated)
    nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:] // touched only on scriptQueue

    static func timedScript(_ source: String, completion: @escaping @MainActor (String?, Double) -> Void) {
        let done = TimedCompletion(completion)
        scriptQueue.async {
            let script = compiled[source] ?? NSAppleScript(source: source)
            // Scripts with ids in them (playlists, links) make new sources: keep the cache bounded.
            if compiled[source] == nil, compiled.count >= 64 { compiled.removeAll(keepingCapacity: true) }
            compiled[source] = script
            var error: NSDictionary?
            let before = CACurrentMediaTime()
            let result = script?.executeAndReturnError(&error).stringValue
            let after = CACurrentMediaTime()
            let output = error == nil ? result : nil
            DispatchQueue.main.async { onMainActor { done.run(output, (before + after) / 2) } }
        }
    }

    private final class TimedCompletion: @unchecked Sendable {
        let run: @MainActor (String?, Double) -> Void
        init(_ run: @escaping @MainActor (String?, Double) -> Void) { self.run = run }
    }

    private final class Completion: @unchecked Sendable {
        let run: @MainActor (String?) -> Void
        init(_ run: @escaping @MainActor (String?) -> Void) { self.run = run }
    }
}

/// Finds an album's Apple Music motion artwork (the square looping cover video).
public enum MotionArtwork {
    /// The sharpest single stream in an HLS playlist that still fits `maxSide`
    /// pixels (HEVC preferred). Players start streams small and a 20-second loop
    /// ends before they ever step up, so we pick the quality ourselves.
    public static func bestVariant(of master: URL, maxSide: Int) async -> URL {
        guard let (data, _) = try? await URLSession.shared.data(from: master),
              let text = String(data: data, encoding: .utf8) else { return master }
        return bestVariant(inPlaylist: text, master: master, maxSide: maxSide)
    }

    /// The choice itself, from the master playlist's text (separate so it can be tested).
    static func bestVariant(inPlaylist text: String, master: URL, maxSide: Int) -> URL {
        let lines = text.components(separatedBy: .newlines)
        var options: [(side: Int, hevc: Bool, bandwidth: Int, url: URL)] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") && i + 1 < lines.count {
            let resolution = line.range(of: #"RESOLUTION=(\d+)x(\d+)"#, options: .regularExpression)
                .map { String(line[$0].dropFirst("RESOLUTION=".count)).split(separator: "x").compactMap { Int($0) } } ?? []
            let bandwidth = line.range(of: #"(?<![-A-Z])BANDWIDTH=\d+"#, options: .regularExpression)
                .flatMap { Int(line[$0].dropFirst("BANDWIDTH=".count)) } ?? 0
            guard resolution.count == 2, let url = URL(string: lines[i + 1].trimmingCharacters(in: .whitespaces), relativeTo: master) else { continue }
            options.append((max(resolution[0], resolution[1]), line.contains("hvc1"), bandwidth, url.absoluteURL))
        }
        let fitting = options.filter { $0.side <= Int(Double(maxSide) * 1.15) }
        let pool = fitting.isEmpty ? options.sorted { $0.side < $1.side }.prefix(1).map { $0 } : fitting
        return pool.max { a, b in
            (a.side, a.hevc ? 1 : 0, a.bandwidth) < (b.side, b.hevc ? 1 : 0, b.bandwidth)
        }?.url ?? master
    }

    public struct Result: Sendable {
        public let video: URL?
        public let cover: URL? // 600×600 still, from the same lookup
        public var genre: String? = nil // the catalog's genre for the song (or its album): "Hip-Hop/Rap"
    }

    /// The animated cover of the album this song is on. Only a result that really is that album
    /// counts: the same artist's other albums (or a single, or another song with the same title,
    /// like the "Intro" of an earlier album) are not it, and no animation beats the wrong one.
    public static func find(artist: String, album: String, song: String = "", duration: Double = 0) async -> Result {
        // Best: search the catalog for the *song*: its result links to the exact album it's on.
        var genre: String?
        if !song.isEmpty, let hit = await songAlbum(artist: artist, song: song, album: album, duration: duration) {
            var result = await motion(onAlbumPage: hit.page, cover: hit.cover)
            result.genre = hit.genre
            genre = hit.genre
            if result.video != nil { return result }
        }
        guard !albumKey(album).isEmpty else { return Result(video: nil, cover: nil, genre: genre) }
        let artists = YouTubeLoop.artistNames(artist)
        for store in stores {
            var search = URLComponents(string: "https://itunes.apple.com/search")!
            search.queryItems = [.init(name: "term", value: "\(artists.first ?? artist) \(albumKey(album))"), .init(name: "entity", value: "album"),
                                 .init(name: "limit", value: "15"), .init(name: "country", value: store)]
            guard let results = await catalog(search) else { continue }
            let best = results.first { r in
                sameAlbum(r["collectionName"] as? String ?? "", album) && byArtist(r, artists)
            }
            guard let best else { continue }
            let cover = (best["artworkUrl100"] as? String).flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) }
            let albumGenre = genre ?? best["primaryGenreName"] as? String
            guard let pageURL = (best["collectionViewUrl"] as? String).flatMap(URL.init(string:)) else {
                return Result(video: nil, cover: cover, genre: albumGenre)
            }
            var result = await motion(onAlbumPage: pageURL, cover: cover)
            result.genre = albumGenre
            return result
        }
        return Result(video: nil, cover: nil, genre: genre)
    }

    /// Your region's store first, then the US one.
    private static var stores: [String] {
        var stores = ["US"]
        if let region = Locale.current.region?.identifier, region != "US" { stores.insert(region, at: 0) }
        return stores
    }

    private static func catalog(_ search: URLComponents) async -> [[String: Any]]? {
        guard let url = search.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["results"] as? [[String: Any]]
    }

    /// "Way Ahead - EP", "Views (Deluxe)", "Scorpion [Explicit]" → "way ahead", "views", "scorpion"
    static func albumKey(_ album: String) -> String {
        var a = album.replacingOccurrences(of: #"\s+-\s+(EP|Single)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        a = a.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(Single|EP|Deluxe|Remaster|Edition|Version|Expanded|Explicit|Clean|Bonus)[^\)\]]*[\)\]]"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        return YouTubeLoop.normalize(a)
    }

    /// The same album, allowing for edition words ("Views" and "Views (Deluxe)").
    static func sameAlbum(_ a: String, _ b: String) -> Bool {
        let x = albumKey(a), y = albumKey(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.hasPrefix(y + " ") || y.hasPrefix(x + " ")
    }

    private static func byArtist(_ r: [String: Any], _ artists: [String]) -> Bool {
        let by = YouTubeLoop.normalize(r["artistName"] as? String ?? "")
        return artists.contains { by.contains($0) }
    }

    /// The album a song is on, from Apple's catalog: the song by this artist *on this album*
    /// (or, when Music doesn't name the album, the one whose length matches).
    private static func songAlbum(artist: String, song: String, album: String, duration: Double) async -> (page: URL, cover: URL?, genre: String?)? {
        let wanted = YouTubeLoop.normalize(song), artists = YouTubeLoop.artistNames(artist)
        guard !wanted.isEmpty else { return nil }
        let knowAlbum = !albumKey(album).isEmpty
        for store in stores {
            var search = URLComponents(string: "https://itunes.apple.com/search")!
            search.queryItems = [.init(name: "term", value: "\(artists.first ?? artist) \(song)"), .init(name: "entity", value: "song"),
                                 .init(name: "limit", value: "25"), .init(name: "country", value: store)]
            guard let results = await catalog(search) else { continue }
            let seconds = { (r: [String: Any]) in (r["trackTimeMillis"] as? Double ?? 0) / 1000 }
            let candidates = results.filter { r in
                let name = YouTubeLoop.normalize(r["trackName"] as? String ?? "")
                guard name == wanted || name.hasPrefix(wanted + " "), byArtist(r, artists) else { return false }
                if knowAlbum { return sameAlbum(r["collectionName"] as? String ?? "", album) }
                return duration > 0 && abs(seconds(r) - duration) < 3
            }
            // The exact title first, then the closest length.
            let match = candidates.min { a, b in
                let an = YouTubeLoop.normalize(a["trackName"] as? String ?? "") == wanted ? 0 : 1
                let bn = YouTubeLoop.normalize(b["trackName"] as? String ?? "") == wanted ? 0 : 1
                return (an, abs(seconds(a) - duration)) < (bn, abs(seconds(b) - duration))
            }
            if let match, let page = (match["collectionViewUrl"] as? String).flatMap(URL.init(string:)) {
                let cover = (match["artworkUrl100"] as? String).flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) }
                return (page, cover, match["primaryGenreName"] as? String)
            }
        }
        return nil
    }

    private static func motion(onAlbumPage pageURL: URL, cover: URL?) async -> Result {
        var request = URLRequest(url: pageURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (pageData, _) = try? await URLSession.shared.data(for: request),
              let page = String(data: pageData, encoding: .utf8) else { return Result(video: nil, cover: cover) }
        let pattern = #"https://mvod\.itunes\.apple\.com/[^"\\\s]+?\.m3u8"#
        // The square loop, if the page labels one; otherwise the first motion video on the page.
        if let square = page.range(of: "\"motionDetailSquare\"") {
            let after = page[square.upperBound...].prefix(2000)
            if let match = after.range(of: pattern, options: .regularExpression) {
                return Result(video: URL(string: String(after[match])), cover: cover)
            }
        }
        let any = page.range(of: pattern, options: .regularExpression).map { String(page[$0]) }
        return Result(video: any.flatMap(URL.init(string:)), cover: cover)
    }
}

// MARK: - YouTube loops (fallback when an album has no motion artwork)

/// Finds a song's video on YouTube and plays it muted (the whole video, starting
/// over when it ends), using YouTube's own embedded player (so nothing is downloaded,
/// which YouTube's terms don't allow). Finding the video reads YouTube's
/// public search page, which isn't an official API; some videos don't allow
/// embedding, so several candidates are tried in turn.
public enum YouTubeLoop {
    public static func findVideos(artist: String, title: String) async -> [String] {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [.init(name: "search_query", value: "\(artist) \(title) official video")]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let page = String(data: data, encoding: .utf8),
              let start = page.range(of: "var ytInitialData = "),
              let end = page.range(of: ";</script>", range: start.upperBound..<page.endIndex),
              let json = try? JSONSerialization.jsonObject(with: Data(page[start.upperBound..<end.lowerBound].utf8)) else { return [] }

        var found: [(id: String, title: String, channel: String)] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let v = dict["videoRenderer"] as? [String: Any], let id = v["videoId"] as? String {
                    found.append((id, runs(v["title"]), runs(v["ownerText"])))
                }
                dict.values.forEach(walk)
            } else if let list = node as? [Any] {
                list.forEach(walk)
            }
        }
        walk(json)

        let song = normalize(title)
        let artists = artistNames(artist)
        let rejected = ["reaction", "tutorial", "cover", "karaoke", "slowed", "reverb", "8d", "nightcore", "instrumental", "how to"]
        let scored: [(String, Int)] = found.compactMap { video in
            let t = normalize(video.title), c = normalize(video.channel)
            guard !song.isEmpty, t.contains(song) else { return nil }                                    // it's this song…
            guard artists.contains(where: { t.contains($0) || c.contains($0) }) else { return nil }      // …by this artist
            guard !rejected.contains(where: { t.contains($0) }) else { return nil }
            var score = 0
            if t.contains("official video") || t.contains("official music video") || t.contains("music video") { score += 3 }
            if artists.contains(where: { c.contains($0) }) || c.contains("vevo") || c.contains("records") || c.contains("def jam") { score += 2 }
            if t.contains("lyric") { score -= 2 }      // lyric videos are mostly text
            if t.contains("live") { score -= 1 }
            return (video.id, score)
        }
        var seen = Set<String>()
        return scored.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0).inserted }.prefix(4).map { $0 }
    }

    private static func runs(_ node: Any?) -> String {
        ((node as? [String: Any])?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
    }

    /// Lowercased, accents removed, only letters/digits/spaces: "Kheench Maari!" → "kheench maari".
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// "Raga, DG IMMORTALS & X feat. Y" → ["raga", "dg immortals", "x", "y"]
    static func artistNames(_ artist: String) -> [String] {
        artist.replacingOccurrences(of: #"(?i)\s+(feat\.?|ft\.?|featuring|x|&|and)\s+"#, with: ",", options: .regularExpression)
            .split(separator: ",").map { normalize(String($0)) }.filter { $0.count >= 2 }
    }
}

/// A muted YouTube embed that plays the whole video on repeat and fills its
/// frame (cropping, like a cover) or spans its width. Clicks pass through it.
public final class YouTubeLoopView: NSView {
    private let web: WKWebView
    private var ids: [String] = []
    private let fill: Bool

    /// `fill`: crop to cover the frame (covers); false: show the full width (wallpaper "Fit Width").
    public init(ids: [String], fill: Bool = true) {
        self.fill = fill
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = [] // muted autoplay
        web = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        addSubview(web)
        show(ids)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        web.frame = bounds
        // YouTube won't play embeds smaller than ~200×200, so on small frames (the
        // widget's 72-pt cover) render the page bigger and zoom it down to fit.
        let shortSide = min(bounds.width, bounds.height)
        web.pageZoom = shortSide > 0 ? min(1, shortSide / 220) : 1
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil } // purely visual

    public func show(_ ids: [String]) {
        // They go into JavaScript: accept only real YouTube video ids (11 of A–Z a–z 0–9 - _).
        let ids = ids.filter { $0.count == 11 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
        guard ids != self.ids, !ids.isEmpty else { return }
        self.ids = ids
        let list = ids.map { "'\($0)'" }.joined(separator: ",")
        let html = """
        <html><head><style>
          html,body{margin:0;background:#000;overflow:hidden;height:100%}
          #wrap{position:fixed;inset:0;overflow:hidden}
          #wrap iframe{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);pointer-events:none;border:0;
                       \(fill ? "width:max(100vw,177.78vh)!important;height:max(100vh,56.25vw)!important"
                               : "width:100vw!important;height:56.25vw!important")}
        </style></head><body><div id="wrap"><div id="p"></div></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
          var ids=[\(list)], i=0, player, start=0, wantPlay=true, target=null;
          function onYouTubeIframeAPIReady(){ make(); }
          function make(){ player=new YT.Player('p',{videoId:ids[i],
            playerVars:{autoplay:1,mute:1,controls:0,disablekb:1,fs:0,iv_load_policy:3,playsinline:1,rel:0},
            events:{onReady:ready,onError:next}}); }
          function ready(){ player.mute(); if(target!==null){player.seekTo(target,true);}
            if(wantPlay){player.playVideo();} else {player.pauseVideo();}
            // The whole video, muted. Not following a song: start over when it ends.
            setInterval(function(){ if(wantPlay&&target===null&&player.getPlayerState()==0){player.seekTo(0,true);player.playVideo();} },1000); }
          // Follow the song: jump when we drift more than 1.5 s, play/pause with it.
          function sync(t,p){ target=t; wantPlay=p; if(!player||!player.getCurrentTime){return;}
            if(Math.abs(player.getCurrentTime()-t)>1.5){player.seekTo(t,true);}
            if(p){player.playVideo();} else {player.pauseVideo();} }
          function next(){ i++; if(i<ids.length){ player.destroy(); var d=document.createElement('div'); d.id='p';
            document.getElementById('wrap').appendChild(d); make(); } }
          function setPlaying(p){ wantPlay=p; if(!player||!player.playVideo){return;} if(p){player.playVideo();} else {player.pauseVideo();} }
        </script></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://localhost/")) // the embed wants a page origin
    }

    public func setPlaying(_ playing: Bool) {
        web.evaluateJavaScript("setPlaying(\(playing))")
    }

    /// Keep the video at the song's position (seconds); pauses/plays with the song.
    public func sync(to seconds: Double, playing: Bool) {
        web.evaluateJavaScript(String(format: "sync(%.2f,%@)", seconds, playing ? "true" : "false"))
    }
}

