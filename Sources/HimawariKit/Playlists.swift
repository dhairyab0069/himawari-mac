import AppKit

/// Your playlists, for the deck's disc changer: what's playing and what comes next (Apple Music),
/// your playlists to browse and play (Apple Music), and Spotify playlists pinned by their link.
///
/// Apple Music's AppleScript can read and play all of it. Spotify's can only play a playlist by
/// its link (listing your playlists needs its Web API and a sign-in), so those are pinned by
/// hand; their name and cover come from Spotify's public oEmbed page (no account).
public struct Playlist: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case appleMusic(persistentID: String)
        case spotify(uri: String)
    }
    public let source: Source
    public let name: String
    public let count: Int?            // songs, when known
    public var id: String {
        switch source {
        case .appleMusic(let id): "am:" + id
        case .spotify(let uri): uri
        }
    }

    public init(source: Source, name: String, count: Int?) {
        self.source = source
        self.name = name
        self.count = count
    }
}

/// Where the song is in the playlist that's playing, and what's next.
public struct PlaylistPosition: Equatable, Sendable {
    public let playlist: String
    public let index: Int, count: Int
    public let upNext: [UpNext]

    public struct UpNext: Equatable, Sendable, Identifiable {
        public let index: Int
        public let title: String, artist: String
        public var id: Int { index }
    }

    /// For the deck's display: "DHH · 7 / 41".
    public var label: String { "\(playlist) · \(index) / \(count)" }
}

@MainActor
public final class PlaylistLibrary: ObservableObject {
    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var position: PlaylistPosition?
    @Published public private(set) var covers: [String: NSImage] = [:]
    @Published public private(set) var loading = false

    private static let music = "com.apple.Music"
    nonisolated private static let unit = "\u{1F}", record = "\u{1E}"
    private let coverFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "Himawari/Playlist Covers")

    public init() {}

    // MARK: Apple Music

    /// Reads your Apple Music playlists (not the library or folders).
    public func reloadAppleMusic() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.music).isEmpty else { playlists = []; return }
        loading = true
        MusicNowPlaying.timedScript("""
        tell application id "\(Self.music)"
            set out to ""
            repeat with p in user playlists
                if special kind of p is none then
                    set out to out & (persistent ID of p) & "\(Self.unit)" & (name of p) & "\(Self.unit)" & ((count of tracks of p) as text) & "\(Self.record)"
                end if
            end repeat
            return out
        end tell
        """) { [weak self] output, _ in
            guard let self else { return }
            self.loading = false
            self.playlists = Self.parsePlaylists(output ?? "")
            for p in self.playlists { self.loadCover(p) }
        }
    }

    /// The playlist that's playing in Apple Music, the song's place in it, and the next few
    /// songs (nil while shuffling: the order isn't the playlist's then, so "next" would be wrong).
    public func refreshPosition(shuffling: Bool) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.music).isEmpty else { position = nil; return }
        MusicNowPlaying.timedScript("""
        tell application id "\(Self.music)"
            if player state is stopped then return ""
            set p to current playlist
            set i to index of current track
            set n to count of tracks of p
            set out to (name of p) & "\(Self.unit)" & (special kind of p as text) & "\(Self.unit)" & i & "\(Self.unit)" & n & "\(Self.record)"
            repeat with k from (i + 1) to (i + 5)
                if k > n then exit repeat
                set t to track k of p
                set out to out & k & "\(Self.unit)" & (name of t) & "\(Self.unit)" & (artist of t) & "\(Self.record)"
            end repeat
            return out
        end tell
        """) { [weak self] output, _ in
            guard let self else { return }
            var p = Self.parsePosition(output ?? "")
            if shuffling, let current = p { p = PlaylistPosition(playlist: current.playlist, index: current.index, count: current.count, upNext: []) }
            self.position = p
        }
    }

    public func clearPosition() { if position != nil { position = nil } }

    public func play(_ playlist: Playlist) {
        switch playlist.source {
        case .appleMusic(let id):
            MusicNowPlaying.timedScript("tell application id \"\(Self.music)\" to play (first user playlist whose persistent ID is \"\(Self.escaped(id))\")") { _, _ in }
        case .spotify(let uri):
            MusicNowPlaying.timedScript("tell application id \"\(MusicNowPlaying.spotify)\" to play track \"\(Self.escaped(uri))\"") { _, _ in }
        }
    }

    /// Jumps to a song further down the playing Apple Music playlist (the next few only).
    public func play(upNext item: PlaylistPosition.UpNext) {
        // Skip forward rather than "play track k of current playlist", which plays the song on its
        // own and loses the playlist (and with it, everything after the song).
        MusicNowPlaying.timedScript("""
        tell application id "\(Self.music)"
            repeat 12 times
                if (index of current track) ≥ \(item.index) then exit repeat
                next track
                delay 0.15
            end repeat
        end tell
        """) { [weak self] _, _ in
            self?.refreshPosition(shuffling: false)
        }
    }

    /// The first song's cover, cached on disk (Music has no playlist artwork of its own to ask for).
    private func loadCover(_ playlist: Playlist) {
        guard case .appleMusic(let id) = playlist.source, covers[playlist.id] == nil else { return }
        let file = coverFolder.appending(path: Self.safeFileName(id) + ".img")
        if let image = NSImage(contentsOf: file) { covers[playlist.id] = image; return }
        try? FileManager.default.createDirectory(at: coverFolder, withIntermediateDirectories: true)
        MusicNowPlaying.timedScript("""
        tell application id "\(Self.music)"
            set p to (first user playlist whose persistent ID is "\(Self.escaped(id))")
            if (count of tracks of p) is 0 then return "none"
            if (count of artworks of track 1 of p) is 0 then return "none"
            set d to raw data of artwork 1 of track 1 of p
        end tell
        set f to open for access (POSIX file "\(file.path)") with write permission
        set eof f to 0
        write d to f
        close access f
        return "ok"
        """) { [weak self] ok, _ in
            guard ok == "ok", let image = NSImage(contentsOf: file) else { return }
            self?.covers[playlist.id] = image
        }
    }

    // MARK: Spotify, by link

    /// A pinned Spotify playlist from its share link: its name and cover from Spotify's public
    /// oEmbed endpoint (no sign-in). nil if the link isn't a Spotify playlist.
    public func spotifyPlaylist(fromLink link: String) async -> (Playlist, NSImage?)? {
        guard let uri = Self.spotifyURI(fromLink: link), let id = uri.split(separator: ":").last else { return nil }
        let page = "https://open.spotify.com/playlist/\(id)"
        var name = "Spotify playlist", cover: NSImage?
        var request = URLComponents(string: "https://open.spotify.com/oembed")!
        request.queryItems = [.init(name: "url", value: page)]
        if let url = request.url, let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let title = json["title"] as? String, !title.isEmpty { name = title }
            if let thumb = (json["thumbnail_url"] as? String).flatMap(URL.init(string:)),
               let (bytes, _) = try? await URLSession.shared.data(from: thumb) { cover = NSImage(data: bytes) }
        }
        return (Playlist(source: .spotify(uri: uri), name: name, count: nil), cover)
    }

    public func setCover(_ image: NSImage?, for playlist: Playlist) {
        if let image { covers[playlist.id] = image }
    }

    // MARK: Parsing (pure, tested)

    nonisolated static func parsePlaylists(_ output: String) -> [Playlist] {
        output.components(separatedBy: record).compactMap { line in
            let f = line.components(separatedBy: unit)
            guard f.count == 3, !f[0].isEmpty, !f[1].isEmpty else { return nil }
            return Playlist(source: .appleMusic(persistentID: f[0]), name: f[1], count: Int(f[2]))
        }
    }

    nonisolated static func parsePosition(_ output: String) -> PlaylistPosition? {
        let records = output.components(separatedBy: record).filter { !$0.isEmpty }
        guard let head = records.first?.components(separatedBy: unit), head.count == 4,
              let index = Int(head[2]), let count = Int(head[3]), count > 0 else { return nil }
        // The whole library ("Music") isn't a playlist anyone picked: don't show "Music · 812 / 936".
        guard head[1] == "none" else { return nil }
        let next = records.dropFirst().compactMap { line -> PlaylistPosition.UpNext? in
            let f = line.components(separatedBy: unit)
            guard f.count == 3, let k = Int(f[0]) else { return nil }
            return .init(index: k, title: f[1], artist: f[2])
        }
        return PlaylistPosition(playlist: head[0], index: index, count: count, upNext: Array(next))
    }

    /// "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=…", "spotify:playlist:37i9…"
    /// → "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M". Only playlists; ids are base-62.
    nonisolated public static func spotifyURI(fromLink link: String) -> String? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        var id: Substring?
        if text.hasPrefix("spotify:playlist:") {
            id = text.dropFirst("spotify:playlist:".count)
        } else if let url = URL(string: text), let host = url.host?.lowercased(),
                  host == "open.spotify.com" || host == "play.spotify.com" {
            let parts = url.path.split(separator: "/")
            // Allow a locale prefix, e.g. /intl-de/playlist/<id>.
            if let i = parts.firstIndex(of: "playlist"), i + 1 < parts.count { id = parts[i + 1] }
        }
        guard let id, (16...32).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "spotify:playlist:" + id
    }

    nonisolated static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated static func safeFileName(_ s: String) -> String {
        String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
    }
}
