import Foundation

/// A song's words, timed to it (or not): what the gear shows line by line.
public struct Lyrics: Equatable, Sendable {
    public struct Word: Equatable, Sendable {
        public var time: Double   // seconds into the song
        public var text: String
    }

    public struct Line: Equatable, Sendable {
        public var time: Double   // when it's sung (seconds); for plain lyrics, an even share of the song
        public var text: String
        public var words: [Word]  // per-word timing, when the file has it (enhanced LRC)
    }

    public enum Source: String, Sendable { case lrclib = "LRCLIB", appleMusic = "Apple Music" }

    public var lines: [Line]
    /// Timed line by line. Plain lyrics are spread evenly over the song and shown a page at a time.
    public var synced: Bool
    public var source: Source

    public init(lines: [Line], synced: Bool, source: Source) {
        self.lines = lines
        self.synced = synced
        self.source = source
    }

    // MARK: Reading LRC

    /// Reads an LRC file: "[01:23.45] words", several stamps on one line ("[00:12.00][01:40.00]
    /// chorus"), an "[offset:+250]" tag (milliseconds; positive means earlier), and word stamps
    /// ("<01:23.45> word"). Other tags ([ar:], [ti:]…) are skipped. Nil when nothing is timed.
    public static func parseLRC(_ text: String, source: Source = .lrclib) -> Lyrics? {
        var offset = 0.0
        var lines: [Line] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = time(tag) {
                    stamps.append(t)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }
            let (plain, words) = wordTimes(String(rest))
            for t in stamps { lines.append(Line(time: t, text: plain, words: words)) }
        }
        guard !lines.isEmpty else { return nil }
        // The offset moves everything (and nothing sings before the start).
        lines = lines.map { l in
            Line(time: max(l.time - offset, 0), text: l.text, words: l.words.map { Word(time: max($0.time - offset, 0), text: $0.text) })
        }
        lines.sort { $0.time < $1.time }
        return Lyrics(lines: lines, synced: true, source: source)
    }

    /// Plain lyrics (no times): one line per line of text, empty lines kept as breaks between
    /// verses, spread over the song so a page turns at about the right time.
    public static func plain(_ text: String, duration: Double, source: Source) -> Lyrics? {
        var rows = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while rows.first?.isEmpty == true { rows.removeFirst() }
        while rows.last?.isEmpty == true { rows.removeLast() }
        guard rows.contains(where: { !$0.isEmpty }) else { return nil }
        let step = duration > 0 ? duration / Double(rows.count) : 4
        return Lyrics(lines: rows.enumerated().map { Line(time: Double($0.offset) * step, text: $0.element, words: []) },
                      synced: false, source: source)
    }

    /// "01:23.45", "1:23", "01:23:45" (hundredths after a colon, as some files write) → seconds.
    static func time(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let m = Int(parts[0]), m >= 0, m < 1000 else { return nil }
        if parts.count == 3 {
            guard let sec = Int(parts[1]), let frac = Int(parts[2]), sec < 60 else { return nil }
            return Double(m * 60 + sec) + Double(frac) / pow(10, Double(parts[2].count))
        }
        guard let sec = Double(parts[1]), sec >= 0, sec < 60 else { return nil }
        return Double(m * 60) + sec
    }

    /// "<00:01.00> Hello <00:01.50> world" → ("Hello world", the two words with their times).
    private static func wordTimes(_ text: String) -> (String, [Word]) {
        guard text.contains("<") else { return (text.trimmingCharacters(in: .whitespaces), []) }
        var words: [Word] = []
        var plain = ""
        var rest = Substring(text)
        var pending: Double?
        while let open = rest.firstIndex(of: "<") {
            let before = rest[..<open]
            if let t = pending, !before.trimmingCharacters(in: .whitespaces).isEmpty {
                words.append(Word(time: t, text: before.trimmingCharacters(in: .whitespaces)))
            }
            plain += before
            guard let close = rest[open...].firstIndex(of: ">") else { rest = rest[open...]; break }
            pending = time(rest[rest.index(after: open)..<close])
            rest = rest[rest.index(after: close)...]
        }
        if let t = pending, !rest.trimmingCharacters(in: .whitespaces).isEmpty {
            words.append(Word(time: t, text: rest.trimmingCharacters(in: .whitespaces)))
        }
        plain += rest
        let squeezed = plain.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return (squeezed, words)
    }

    // MARK: Following the song

    /// The line being sung at `position` (nil: before the first line).
    public func lineIndex(at position: Double) -> Int? {
        guard let first = lines.first, position >= first.time else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi { // the last line that has started
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= position { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// When the next line starts after `position` (nil: none).
    public func nextChange(after position: Double) -> Double? {
        lines.first { $0.time > position }?.time
    }

    /// Plain lyrics, a page of `size` lines at a time: the page for `position`.
    public func page(at position: Double, size: Int = 4) -> [Line] {
        guard let i = lineIndex(at: position) ?? (lines.isEmpty ? nil : 0) else { return [] }
        let start = i / size * size
        return Array(lines[start..<min(start + size, lines.count)])
    }
}

/// Where lyrics come from: LRCLIB (lrclib.net, free and open, no account), cached on the Mac.
public enum LyricsSource {
    /// One LRCLIB record (the fields Himawari uses).
    public struct Record: Equatable, Sendable {
        public var trackName: String
        public var artistName: String
        public var albumName: String
        public var duration: Double
        public var instrumental: Bool
        public var syncedLyrics: String?
        public var plainLyrics: String?

        init?(_ d: [String: Any]) {
            guard let track = d["trackName"] as? String else { return nil }
            trackName = track
            artistName = d["artistName"] as? String ?? ""
            albumName = d["albumName"] as? String ?? ""
            duration = (d["duration"] as? NSNumber)?.doubleValue ?? 0
            instrumental = d["instrumental"] as? Bool ?? false
            syncedLyrics = (d["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            plainLyrics = (d["plainLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        public init(trackName: String, artistName: String, albumName: String, duration: Double, instrumental: Bool = false,
                    syncedLyrics: String?, plainLyrics: String?) {
            (self.trackName, self.artistName, self.albumName, self.duration) = (trackName, artistName, albumName, duration)
            (self.instrumental, self.syncedLyrics, self.plainLyrics) = (instrumental, syncedLyrics, plainLyrics)
        }
    }

    /// The record for this recording among search results: the same length (within 3 seconds, so a
    /// remix or live take doesn't get the studio words), synced ones first, then the same album.
    public static func best(_ records: [Record], duration: Double, album: String) -> Record? {
        let key = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let candidates = records.filter { r in
            !r.instrumental && (r.syncedLyrics != nil || r.plainLyrics != nil) && (duration <= 0 || abs(r.duration - duration) <= 3)
        }
        return candidates.min { a, b in
            let rank = { (r: Record) -> (Int, Int, Double) in
                (r.syncedLyrics != nil ? 0 : 1, !album.isEmpty && key(r.albumName) == key(album) ? 0 : 1, abs(r.duration - duration))
            }
            return rank(a) < rank(b)
        }
    }

    /// The lyrics for a song, from LRCLIB: the exact lookup first (title, artist, album, length),
    /// then a search. Only these four facts are sent.
    public static func lrclib(title: String, artist: String, album: String, duration: Double) async -> Lyrics? {
        func request(_ path: String, _ query: [URLQueryItem]) async -> Any? {
            var c = URLComponents(string: "https://lrclib.net/api/\(path)")!
            c.queryItems = query
            guard let url = c.url else { return nil }
            var r = URLRequest(url: url, timeoutInterval: 10)
            // LRCLIB asks apps to say who they are.
            r.setValue("Himawari (https://github.com/dhairyab0069/himawari-mac)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: r),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        var candidates: [Record] = []
        if duration > 0 {
            let exact = await request("get", [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist),
                                              .init(name: "album_name", value: album), .init(name: "duration", value: String(Int(duration.rounded())))])
            if let d = exact as? [String: Any], let r = Record(d) { candidates.append(r) }
        }
        if candidates.first?.syncedLyrics == nil {
            let found = await request("search", [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)])
            candidates += (found as? [[String: Any]] ?? []).compactMap(Record.init)
        }
        guard let pick = best(candidates, duration: duration, album: album) else { return nil }
        if let synced = pick.syncedLyrics, let lyrics = Lyrics.parseLRC(synced) { return lyrics }
        return pick.plainLyrics.flatMap { Lyrics.plain($0, duration: duration, source: .lrclib) }
    }
}
