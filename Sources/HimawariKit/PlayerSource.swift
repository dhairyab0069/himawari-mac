import Foundation

/// Which app is playing, and what Himawari can do with it.
///
/// Everything about a song (title, artist, album, timing, the exact cover) comes from the
/// system's Now Playing stream, which every player that shows up in Control Center feeds: so
/// any of them can drive the wallpaper, the CD and the gear. Play/pause, skipping and seeking
/// go back through the same system channel (the remote commands Control Center sends). Only
/// Apple's Music app can also be scripted for its volume, equalizer, repeat and shuffle.
public enum PlayerKind: String, CaseIterable, Sendable, Codable {
    case appleMusic, spotify, tidal, amazonMusic, deezer, browser, other
    /// A WebKit helper process (not an app): never followed. Not in the Players menu.
    case webContent

    /// The players the Players menu lists.
    public static var menuCases: [PlayerKind] { allCases.filter { $0 != .webContent } }

    /// Bundle id → player. Browsers cover web players (YouTube Music, SoundCloud, Spotify's web player…).
    public init(bundleID: String?) {
        guard let id = bundleID?.lowercased() else { self = .other; return }
        // WebKit's own processes play for whatever web view they serve (Himawari's YouTube loop
        // included): never a player by themselves.
        if id.hasPrefix("com.apple.webkit") { self = .webContent; return }
        if let kind = Self.known[id] { self = kind; return }
        if Self.browserPrefixes.contains(where: { id.hasPrefix($0) }) { self = .browser; return }
        self = .other
    }

    private static let known: [String: PlayerKind] = [
        "com.apple.music": .appleMusic,
        "com.spotify.client": .spotify,
        "com.tidal.desktop": .tidal,
        "com.amazon.music": .amazonMusic,
        "com.deezer.deezer-desktop": .deezer,
        "com.deezer.deezer": .deezer,
    ]
    private static let browserPrefixes = [
        "com.apple.safari", "com.google.chrome", "org.mozilla.firefox",
        "company.thebrowser.browser", "com.microsoft.edgemac", "com.brave.browser", "com.operasoftware.opera",
        "com.vivaldi.vivaldi", "app.zen-browser.zen",
    ]

    /// As the menu shows it.
    public var title: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .tidal: "TIDAL"
        case .amazonMusic: "Amazon Music"
        case .deezer: "Deezer"
        case .browser: "Web Players (YouTube Music, SoundCloud…)"
        case .other: "Other Apps (VLC, IINA, QuickTime…)"
        case .webContent: "Web Content"
        }
    }

    /// What the gear can do with this player.
    public var capabilities: PlayerCapabilities {
        switch self {
        case .appleMusic: .all
        // Spotify's AppleScript: its own volume, repeat and shuffle, and playing a playlist by link.
        case .spotify: [.transport, .seek, .volume, .repeatShuffle, .playlists]
        // The system's remote commands (what Control Center can do with any player), and the
        // VOLUME knob turns the Mac's own volume (no other player can be asked for its own).
        default: [.transport, .seek, .volume]
        }
    }
}

/// What Himawari can do with the player that's playing.
public struct PlayerCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Play/pause, next, previous.
    public static let transport = PlayerCapabilities(rawValue: 1 << 0)
    /// Jump to a point in the song (the progress ladder, the jog wheel, turning the CD).
    public static let seek = PlayerCapabilities(rawValue: 1 << 1)
    /// The VOLUME knob: Apple Music's own volume, or the Mac's for other players.
    public static let volume = PlayerCapabilities(rawValue: 1 << 2)
    /// Repeat and shuffle (the words on the deck's display).
    public static let repeatShuffle = PlayerCapabilities(rawValue: 1 << 3)
    /// An equalizer Himawari can shape (BASS and TREBLE).
    public static let equalizer = PlayerCapabilities(rawValue: 1 << 4)

    /// Playing a playlist (Apple Music: any of yours; Spotify: one you've pinned by its link).
    public static let playlists = PlayerCapabilities(rawValue: 1 << 5)
    /// Reading the playlist that's playing, the song's place in it and what comes next.
    public static let upNext = PlayerCapabilities(rawValue: 1 << 6)

    public static let all: PlayerCapabilities = [.transport, .seek, .volume, .repeatShuffle, .equalizer, .playlists, .upNext]
}

/// Which player the wallpaper follows.
///
/// The system already picks one "now playing" app (the one that last started playing), and
/// that's the default. You can turn players off, or pin one: then only it is followed, whatever
/// else plays.
public struct PlayerChoice: Sendable, Equatable {
    public var disabled: Set<PlayerKind>
    public var pinned: PlayerKind?

    public init(disabled: Set<PlayerKind> = [], pinned: PlayerKind? = nil) {
        self.disabled = disabled
        self.pinned = pinned
    }

    /// Should an update from this player be followed?
    public func follows(_ kind: PlayerKind) -> Bool {
        if kind == .webContent { return false }
        if let pinned { return kind == pinned }
        return !disabled.contains(kind)
    }

    /// Two apps report Now Playing at once (one playing, one paused in another tab, say) and the
    /// system can flip between them: never leave a player that's playing for one that's paused.
    public static func switches(fromPlaying current: Bool, toPlaying new: Bool) -> Bool {
        new || !current
    }
}

/// A command for whichever app is playing, through the system's remote-command channel.
public enum PlayerCommand: Equatable, Sendable {
    case play, pause, togglePlayPause, next, previous
    case seek(to: Double)
    /// No command: just report the current state again.
    case refresh

    /// The line the Now Playing helper reads on its standard input.
    public var helperLine: String {
        switch self {
        case .play: "play"
        case .pause: "pause"
        case .togglePlayPause: "toggle"
        case .next: "next"
        case .previous: "previous"
        case .refresh: "refresh"
        case .seek(let seconds): "seek " + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
        }
    }
}
