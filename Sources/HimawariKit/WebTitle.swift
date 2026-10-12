import Foundation

/// A web player's "song" is often a video: "DRV - Har Har Mahadev 4L ft. ILLAH (Official Video)"
/// by the channel "DRV Music". This pulls out the artist and song so the catalog search can find
/// the real cover (and, if the album has one, its animated cover). YouTube Music itself reports
/// clean names, which pass through unchanged.
public enum WebTitle {
    /// Words that mark a bracketed part as video packaging, not part of the song's name.
    private static let packaging = ["official", "video", "audio", "lyric", "lyrics", "visualizer", "visualiser",
                                    "music video", "mv", "m/v", "hd", "4k", "hq", "remastered", "live", "color coded"]

    public static func clean(title: String, artist: String) -> (title: String, artist: String) {
        var song = title
        var by = artist
        // Drop "(Official Video)", "[Lyrics]", "【MV】" and the like.
        song = song.replacingOccurrences(of: #"\s*[\(\[【][^\)\]】]*[\)\]】]"#, with: "", options: .regularExpression) { inner in
            let lower = inner.lowercased()
            return packaging.contains { word in lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", options: .regularExpression) != nil }
        }
        // "Artist - Song": the part before the first dash is the artist.
        for dash in [" - ", " – ", " — ", " | "] {
            if let range = song.range(of: dash) {
                let left = song[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = song[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !left.isEmpty, !right.isEmpty { by = left; song = right }
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
    func replacingOccurrences(of pattern: String, with replacement: String, options: String.CompareOptions,
                              keep: (String) -> Bool) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        var result = self
        for match in regex.matches(in: self, range: NSRange(startIndex..., in: self)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            if keep(String(result[range])) { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}
