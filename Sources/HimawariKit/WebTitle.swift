import Foundation

/// A web player's "song" is often a video: "DRV - Har Har Mahadev 4L ft. ILLAH (Official Video)"
/// by the channel "DRV Music". This pulls out the artist and song so the catalog search can find
/// the real cover (and, if the album has one, its animated cover). YouTube Music itself reports
/// clean names, which pass through unchanged.
public enum WebTitle {
    /// Words that mark a bracketed part as video packaging, not part of the song's name.
    private static let packaging = ["official", "video", "audio", "lyric", "lyrics", "visualizer", "visualiser",
                                    "music video", "mv", "m/v", "hd", "4k", "hq", "remastered", "live", "color coded"]

    /// Whether the text before a title's dash names the artist: it matches the channel (ignoring
    /// "VEVO", "- Topic", "Official", "Music"), or there's no channel name to go by.
    static func isArtist(_ left: String, channel: String) -> Bool {
        let tidy = { (s: String) in YouTubeLoop.normalize(s.replacingOccurrences(of: #"(?i)\s*-\s*topic$|vevo$|\s+(official|music|records)$"#, with: "", options: .regularExpression)) }
        let a = tidy(left), c = tidy(channel)
        guard !c.isEmpty else { return true }
        return a == c || c.hasPrefix(a + " ") || a.hasPrefix(c + " ") || c.replacingOccurrences(of: " ", with: "") == a.replacingOccurrences(of: " ", with: "")
    }

    public static func clean(title: String, artist: String) -> (title: String, artist: String) {
        var song = title
        var by = artist
        // Drop "(Official Video)", "[Lyrics]", "【MV】" and the like.
        song = song.replacingOccurrences(of: #"\s*[\(\[【][^\)\]】]*[\)\]】]"#, with: "") { inner in
            let lower = inner.lowercased()
            return packaging.contains { word in lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", options: .regularExpression) != nil }
        }
        // "Artist - Song": the part before the first dash is the artist, but only when it is the
        // artist (the channel's name, or close to it). "Bohemian Rhapsody - Remastered 2011" by
        // Queen is a song with a subtitle, not a song by "Bohemian Rhapsody".
        for dash in [" - ", " – ", " — "] {
            if let range = song.range(of: dash) {
                let left = song[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = song[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !left.isEmpty, !right.isEmpty, Self.isArtist(left, channel: artist) { by = left; song = right }
                break
            }
        }
        // "Song ft. Someone": the featured artist isn't part of the song's name in the catalog.
        song = song.replacingOccurrences(of: #"\s+(ft\.?|feat\.?|featuring)\s+.*$"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        // Channel names like "DRV Music", "KSI - Topic", "TaylorSwiftVEVO".
        by = by.replacingOccurrences(of: #"\s*-\s*Topic$|VEVO$|\s+(Official|Music)$"#, with: "",
                                     options: [.regularExpression, .caseInsensitive])
        return (song.trimmingCharacters(in: .whitespaces), by.trimmingCharacters(in: .whitespaces))
    }
}

private extension String {
    /// Like replacingOccurrences(of:with:options:), but only where `keep` says to.
    func replacingOccurrences(of pattern: String, with replacement: String, keep: (String) -> Bool) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        var result = self
        for match in regex.matches(in: self, range: NSRange(startIndex..., in: self)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            if keep(String(result[range])) { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}
