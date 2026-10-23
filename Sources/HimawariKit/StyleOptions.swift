import Foundation

/// How Himawari chooses and dresses the look (the Customise window): one style, or one that
/// follows the song's genre, or the chosen one coloured from the cover; how much it moves;
/// which meters it shows; the name on the faceplates.
public struct StyleOptions: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case pinned       // always the chosen style
        case genre        // the style the genre rules pick (the chosen one when none matches)
        case coverColours // the chosen style, its lit colours taken from the cover
    }

    /// How much the gear and the media move by themselves.
    public enum Animation: String, CaseIterable, Sendable {
        case full     // everything: idle spins, the title marquee, the characters, the light on the disc
        case reduced  // the media turns slowly; no characters, no idle wheels
        case still    // nothing moves by itself; live meters still follow the music
    }

    /// The level meters (left and right): the era's own, or one kind everywhere.
    public enum Meters: String, CaseIterable, Sendable {
        case era, needles, leds, spectrum
    }

    public var mode: Mode = .pinned
    public var rules: [GenreRule] = GenreRule.defaults
    public var animation: Animation = .full
    public var meters: Meters = .era
    /// The name on the faceplates instead of the skin's (nil: the skin's).
    public var brand: String?

    public init() {}

    // MARK: Saving (one dictionary in the preferences)

    public var dictionary: [String: Any] {
        var d: [String: Any] = ["mode": mode.rawValue, "animation": animation.rawValue, "meters": meters.rawValue,
                                "rules": rules.map { ["genre": $0.genre, "skin": $0.skin] }]
        if let brand { d["brand"] = brand }
        return d
    }

    /// Reads what `dictionary` wrote; anything missing or unreadable keeps its default.
    public init(dictionary d: [String: Any]?) {
        guard let d else { return }
        if let m = (d["mode"] as? String).flatMap(Mode.init(rawValue:)) { mode = m }
        if let a = (d["animation"] as? String).flatMap(Animation.init(rawValue:)) { animation = a }
        if let m = (d["meters"] as? String).flatMap(Meters.init(rawValue:)) { meters = m }
        if let list = d["rules"] as? [[String: String]] {
            rules = list.compactMap { r in
                guard let g = r["genre"], let s = r["skin"] else { return nil }
                return GenreRule(genre: g, skin: s)
            }
        }
        brand = Self.cleanBrand(d["brand"] as? String)
    }

    /// A faceplate name: trimmed, at most 20 characters, nil when empty.
    public static func cleanBrand(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(20))
    }
}

/// "Songs whose genre says jazz get the walnut hi-fi." The first rule that matches wins.
public struct GenreRule: Equatable, Hashable, Sendable {
    public var genre: String  // matched as words inside the song's genre ("rock" matches "Hard Rock")
    public var skin: String   // a skin's id

    public init(genre: String, skin: String) {
        self.genre = genre
        self.skin = skin
    }

    /// The roadmap's pairings: jazz and soul on a 70s receiver, synth-pop on an 80s tape deck,
    /// alternative on a 90s portable, hip-hop on the 2000s rack, pop on a pocket player,
    /// electronic on today's glass. (More specific words come before the ones they contain.)
    public static let defaults: [GenreRule] = [
        .init(genre: "r&b", skin: "rack-champagne"),   // before "soul": "R&B/Soul" is R&B
        .init(genre: "classical", skin: "hifi-walnut"),
        .init(genre: "jazz", skin: "hifi-walnut"),
        .init(genre: "soul", skin: "hifi-walnut"),
        .init(genre: "blues", skin: "hifi-walnut"),
        .init(genre: "funk", skin: "hifi-silver"),
        .init(genre: "rock", skin: "hifi-silver"),
        .init(genre: "folk", skin: "hifi-walnut"),
        .init(genre: "country", skin: "hifi-walnut"),
        .init(genre: "synth", skin: "cassette-metal"),
        .init(genre: "new wave", skin: "cassette-metal"),
        .init(genre: "disco", skin: "cassette-black"),
        .init(genre: "reggae", skin: "cassette-black"),
        .init(genre: "alternative", skin: "portable-clear"),
        .init(genre: "indie", skin: "portable-silver"),
        .init(genre: "hip-hop", skin: "rack-black"),
        .init(genre: "rap", skin: "rack-black"),
        .init(genre: "k-pop", skin: "pocket-blue"),
        .init(genre: "j-pop", skin: "pocket-blue"),
        .init(genre: "pop", skin: "pocket-white"),
        .init(genre: "latin", skin: "pocket-blue"),
        .init(genre: "electronic", skin: "minimal-dark"),
        .init(genre: "dance", skin: "minimal-dark"),
        .init(genre: "house", skin: "minimal-dark"),
        .init(genre: "techno", skin: "minimal-dark"),
        .init(genre: "ambient", skin: "minimal-frosted"),
        .init(genre: "soundtrack", skin: "minimal-frosted"),
    ]

    /// The skin the rules pick for `genre` (nil: no genre, or no rule matches one of `available`).
    public static func skin(for genre: String?, rules: [GenreRule], available: Set<String>) -> String? {
        guard let genre else { return nil }
        let words = " " + normalize(genre) + " "
        for rule in rules where available.contains(rule.skin) {
            let key = normalize(rule.genre)
            if !key.isEmpty, words.contains(" " + key + " ") { return rule.skin }
        }
        return nil
    }

    /// "Hip-Hop/Rap" → "hip-hop rap"; "R&B/Soul" → "r&b soul"; "Synth-Pop" → "synth-pop synth pop".
    /// Lowercase; separators become spaces; a hyphenated word also counts as its parts.
    static func normalize(_ text: String) -> String {
        let lower = text.lowercased().replacingOccurrences(of: "rhythm and blues", with: "r&b")
        var words: [String] = []
        for word in lower.split(whereSeparator: { " /,;:()[]|+_.".contains($0) }) {
            words.append(String(word))
            if word.contains("-") { words += word.split(separator: "-").map(String.init) }
        }
        return words.joined(separator: " ")
    }
}

/// Colours for a skin from an album cover: its most vivid colour lights the display, and a
/// second, different hue the accents.
public enum CoverTint {
    /// From colour samples (sRGB, 0…1) of the cover. Nil when the cover is all greys.
    public static func colors(from samples: [SIMD3<Double>]) -> (display: SkinColor, accent: SkinColor)? {
        func hsv(_ c: SIMD3<Double>) -> (h: Double, s: Double, v: Double) {
            let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z), d = mx - mn
            var h = 0.0
            if d > 0 {
                if mx == c.x { h = ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
                else if mx == c.y { h = (c.z - c.x) / d + 2 }
                else { h = (c.x - c.y) / d + 4 }
                h = (h / 6 + 1).truncatingRemainder(dividingBy: 1)
            }
            return (h, mx > 0 ? d / mx : 0, mx)
        }
        let rated = samples.map { ($0, hsv($0)) }.filter { $0.1.s > 0.25 && $0.1.v > 0.25 }
        guard let best = rated.max(by: { $0.1.s * $0.1.v < $1.1.s * $1.1.v }) else { return nil }
        func hueGap(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, 1 - d) }
        let second = rated.filter { hueGap($0.1.h, best.1.h) > 0.12 }.max(by: { $0.1.s * $0.1.v < $1.1.s * $1.1.v })
        // Lit colours glow: full brightness, a touch less saturated than the print.
        func lit(_ c: (h: Double, s: Double, v: Double)) -> SkinColor {
            let s = min(c.s, 0.75), v = 1.0
            let i = Int(c.h * 6) % 6, f = c.h * 6 - Double(Int(c.h * 6))
            let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
            let (r, g, b): (Double, Double, Double) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
            return SkinColor(r, g, b)
        }
        let display = lit(best.1)
        let accent = second.map { lit($0.1) } ?? lit(((best.1.h + 0.5).truncatingRemainder(dividingBy: 1), best.1.s, best.1.v))
        return (display, accent)
    }
}
