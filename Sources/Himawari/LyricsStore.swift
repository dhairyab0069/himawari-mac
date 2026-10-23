import AppKit
import CryptoKit
import HimawariKit

/// Finds a song's lyrics (LRCLIB, then Apple Music's own), keeps them in a cache on the Mac, and
/// remembers a timing correction per song.
@MainActor
final class LyricsStore {
    /// What was found for the song playing, for the menu: "Synced (LRCLIB)", "Plain (Apple Music)"…
    private(set) var status = "Off"
    private var generation = 0
    private let defaults = UserDefaults.standard
    private static let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Himawari/Lyrics")

    /// Looks up `track`'s lyrics, and hands them over (nil: none) unless another song came meanwhile.
    /// `appleMusic` asks Music for its own words, for when LRCLIB has none.
    func load(_ track: MusicNowPlaying.Track, appleMusic: @escaping (@escaping @MainActor (String?) -> Void) -> Void,
              done: @escaping @MainActor (Lyrics?) -> Void) {
        generation += 1
        let mine = generation
        status = "Looking…"
        let key = Self.key(track)
        if let cached = Self.cached(key) {
            status = cached.lyrics.map(Self.describe) ?? "None found"
            if cached.lyrics != nil || !cached.stale { return done(cached.lyrics) }
        }
        Task { [weak self] in
            let found = await LyricsSource.lrclib(title: track.name, artist: track.artist, album: track.album, duration: track.duration)
            guard let self, self.generation == mine else { return }
            if let found {
                Self.save(key, found.synced ? Self.lrc(found) : found.lines.map(\.text).joined(separator: "\n"), synced: found.synced,
                          source: found.source, duration: track.duration)
                self.status = Self.describe(found)
                return done(found)
            }
            appleMusic { [weak self] text in
                guard let self, self.generation == mine else { return }
                let plain = text.flatMap { Lyrics.plain($0, duration: track.duration, source: .appleMusic) }
                Self.save(key, plain == nil ? nil : text, synced: false, source: .appleMusic, duration: track.duration)
                self.status = plain.map(Self.describe) ?? "None found"
                done(plain)
            }
        }
    }

    /// No song, or lyrics turned off.
    func clear(_ why: String) {
        generation += 1
        status = why
    }

    // MARK: Timing

    /// Seconds to shift this song's lyrics by (positive: later), saved per song.
    func offset(for track: MusicNowPlaying.Track) -> Double {
        (defaults.dictionary(forKey: "lyricsOffsets") as? [String: Double])?[Self.key(track)] ?? 0
    }

    func setOffset(_ seconds: Double, for track: MusicNowPlaying.Track) {
        var all = defaults.dictionary(forKey: "lyricsOffsets") as? [String: Double] ?? [:]
        all[Self.key(track)] = abs(seconds) < 0.01 ? nil : (seconds * 2).rounded() / 2
        defaults.set(all, forKey: "lyricsOffsets")
    }

    // MARK: The cache (one small file per song; "none found" is kept for a week, then asked again)

    private static func key(_ t: MusicNowPlaying.Track) -> String {
        let text = [t.artist, t.name, t.album, String(Int(t.duration.rounded()))].joined(separator: "|").lowercased()
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func cached(_ key: String) -> (lyrics: Lyrics?, stale: Bool)? {
        let url = folder.appending(path: "\(key).json")
        guard let data = try? Data(contentsOf: url), let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let saved = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        guard let text = d["text"] as? String else { return (nil, Date().timeIntervalSince(saved) > 7 * 86400) }
        let source = Lyrics.Source(rawValue: d["source"] as? String ?? "") ?? .lrclib
        let duration = d["duration"] as? Double ?? 0
        let lyrics = (d["synced"] as? Bool ?? false) ? Lyrics.parseLRC(text, source: source) : Lyrics.plain(text, duration: duration, source: source)
        return (lyrics, false)
    }

    private static func save(_ key: String, _ text: String?, synced: Bool, source: Lyrics.Source, duration: Double) {
        var d: [String: Any] = ["synced": synced, "source": source.rawValue, "duration": duration]
        if let text { d["text"] = text }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: d) { try? data.write(to: folder.appending(path: "\(key).json"), options: .atomic) }
    }

    /// Lyrics back to LRC (for the cache), word times and all.
    private static func lrc(_ l: Lyrics) -> String {
        func stamp(_ t: Double) -> String { String(format: "%02d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
        return l.lines.map { line in
            let words = line.words.isEmpty ? line.text : line.words.map { "<\(stamp($0.time))> \($0.text)" }.joined(separator: " ")
            return "[\(stamp(line.time))]\(words)"
        }.joined(separator: "\n")
    }

    private static func describe(_ l: Lyrics) -> String { "\(l.synced ? "Synced" : "Plain") (\(l.source.rawValue))" }
}
