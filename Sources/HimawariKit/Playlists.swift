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
            guard let output else { return } // a failed read keeps the list we had
            self.playlists = Self.parsePlaylists(output)
            for p in self.playlists { self.loadCover(p) }
        }
    }

    /// The playlist that's playing in Apple Music, the song's place in it, and the next few
    /// songs (nil while shuffling: the order isn't the playlist's then, so "next" would be wrong).
    public func refreshPosition() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.music).isEmpty else { clearPosition(); return }
        let asked = positionGeneration
        MusicNowPlaying.timedScript("""
        tell application id "\(Self.music)"
            if player state is stopped then return ""
            set p to current playlist
            set i to index of current track
            set n to count of tracks of p
            set out to (name of p) & "\(Self.unit)" & (special kind of p as text) & "\(Self.unit)" & i & "\(Self.unit)" & n & "\(Self.unit)" & (shuffle enabled as text) & "\(Self.record)"
            repeat with k from (i + 1) to (i + 5)
                if k > n then exit repeat
                set t to track k of p
                set out to out & k & "\(Self.unit)" & (name of t) & "\(Self.unit)" & (artist of t) & "\(Self.record)"
            end repeat
            return out
        end tell
        """) { [weak self] output, _ in
            // Asked for Apple Music, but the player changed meanwhile: this answer is stale.
            guard let self, self.positionGeneration == asked else { return }
            self.position = Self.parsePosition(output ?? "")
        }
    }

    /// Another player took over: forget Apple Music's position (and any answer still on its way).
    public func clearPosition() {
        positionGeneration += 1
        if position != nil { position = nil }
    }
    private var positionGeneration = 0
    private var coversAsked: Set<String> = []

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
            self?.refreshPosition()
        }
    }

    /// The first song's cover, cached on disk (Music has no playlist artwork of its own to ask for).
    private func loadCover(_ playlist: Playlist) {
        guard covers[playlist.id] == nil else { return }
        let file = coverFile(playlist)
        switch Self.coverAction(imageAge: Self.age(of: file), noCoverAge: Self.age(of: file.appendingPathExtension("none"))) {
        case .useSaved:
            if let image = NSImage(contentsOf: file) { covers[playlist.id] = image; return }
        case .skip:
            return
        case .fetch:
            break
        }
        guard case .appleMusic(let id) = playlist.source, !coversAsked.contains(playlist.id) else { return }
        coversAsked.insert(playlist.id)
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
            if ok == "none" { FileManager.default.createFile(atPath: file.path + ".none", contents: nil) }
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

    /// A cover from elsewhere (Spotify's page), saved so it's there after a relaunch too.
    public func setCover(_ image: NSImage?, for playlist: Playlist) {
        guard let image else { return }
        covers[playlist.id] = image
        try? FileManager.default.createDirectory(at: coverFolder, withIntermediateDirectories: true)
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: coverFile(playlist))
        }
    }

    /// Covers for playlists that aren't from Apple Music (pinned Spotify links), from disk.
    public func loadSavedCovers(for playlists: [Playlist]) {
        for p in playlists where covers[p.id] == nil {
            if let image = NSImage(contentsOf: coverFile(p)) { covers[p.id] = image }
        }
    }

    private func coverFile(_ playlist: Playlist) -> URL {
        coverFolder.appending(path: Self.safeFileName(playlist.id) + ".img")
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
        guard let head = records.first?.components(separatedBy: unit), head.count >= 4,
              let index = Int(head[2]), let count = Int(head[3]), count > 0 else { return nil }
        // The whole library ("Music") isn't a playlist anyone picked: don't show "Music · 812 / 936".
        guard head[1] == "none" else { return nil }
        // Shuffling: the playlist's order isn't the play order, so "next" would be wrong.
        let shuffling = head.count > 4 && head[4] == "true"
        let next = shuffling ? [] : records.dropFirst().compactMap { line -> PlaylistPosition.UpNext? in
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

    /// Saved covers last a week (a playlist's first song can change). A playlist with no cover is
    /// remembered for a week too, so it isn't asked for on every open, but is asked again after.
    nonisolated static let coverMaxAge: TimeInterval = 7 * 86400

    enum CoverAction: Equatable { case useSaved, skip, fetch }

    /// What to do for a playlist's cover, given how old the saved cover and the no-cover marker are.
    nonisolated static func coverAction(imageAge: TimeInterval?, noCoverAge: TimeInterval?) -> CoverAction {
        if let imageAge, imageAge < coverMaxAge { return .useSaved }
        if let noCoverAge, noCoverAge < coverMaxAge { return .skip }
        return .fetch
    }

    /// Seconds since `file` was last written, nil if it doesn't exist.
    nonisolated private static func age(of file: URL) -> TimeInterval? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow }
    }

    nonisolated static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated static func safeFileName(_ s: String) -> String {
        String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
    }
}
