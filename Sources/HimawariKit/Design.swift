import Foundation

/// Your own era: the side gear's two panels as a stack of blocks (a header, a display, buttons, a
/// wheel, meters, knobs…) and what plays in the middle, from a JSON file in
/// `~/Library/Application Support/Himawari/Designs/`. A skin wears it by naming it ("design").
/// Where the parts go is worked out from the blocks; how they're drawn comes from the eras.
public struct Design: Equatable, Sendable {
    public enum Media: String, CaseIterable, Sendable { case cd, record, cassette, discman, player, card }

    public struct Block: Equatable, Sendable {
        public enum Kind: String, CaseIterable, Sendable {
            case header, display, buttons, wheel, meters, spectrum, knobs, grille, toggles, sliders, power, spacer
        }
        public var kind: Kind
        /// Points tall, or nil: share what's left with the other blocks that fill.
        public var height: Double?
        /// How it's drawn: a display "vfd", "lcd", "glass" or "dial"; buttons "rounded", "keys",
        /// "round", "flat" or "bare"; a wheel "knurled", "ring" or "clickwheel"; knobs "classic",
        /// "flat" or "touch"; meters "needles", "leds" or "spectrum".
        public var style: String
        /// A label printed under it (a wheel's "SEARCH").
        public var label: String?
    }

    public var id: String
    public var name: String
    public var media: Media
    public var left: [Block]
    public var right: [Block]

    /// The styles each kind of block can take (the first is the default).
    public static let styles: [Block.Kind: [String]] = [
        .display: ["vfd", "lcd", "glass", "dial"], .buttons: ["rounded", "keys", "round", "flat", "bare"],
        .wheel: ["knurled", "ring", "clickwheel"], .knobs: ["classic", "flat", "touch"], .meters: ["needles", "leds", "spectrum"],
    ]

    /// Each block's height when the file doesn't say (nil: it fills).
    static let defaultHeights: [Block.Kind: Double?] = [
        .header: 40, .display: 150, .buttons: 36, .wheel: nil, .meters: 120, .spectrum: nil, .knobs: 80,
        .grille: nil, .toggles: 64, .sliders: 90, .power: 44, .spacer: 12,
    ]
}

extension Design {
    /// Reads a design file, or says what's wrong with it (as a skin file does).
    public static func decode(_ data: Data) throws -> Design {
        guard let json = try? JSONSerialization.jsonObject(with: data), let d = json as? [String: Any] else { throw SkinError.notJSON }
        let keys: Set<String> = ["format", "id", "name", "media", "left", "right"]
        if let extra = d.keys.sorted().first(where: { !keys.contains($0) }) { throw SkinError.unknownKey(extra) }
        guard let format = d["format"] as? NSNumber, CFGetTypeID(format) != CFBooleanGetTypeID(), format.intValue == 1 else {
            throw d["format"] == nil ? SkinError.missing("format") : SkinError.unsupportedFormat
        }
        guard let id = d["id"] as? String else { throw SkinError.missing("id") }
        guard id.count <= 40, id.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
            throw SkinError.badValue("id", "use lowercase letters, digits and dashes")
        }
        guard let name = (d["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { throw SkinError.missing("name") }
        guard name.count <= 40 else { throw SkinError.badValue("name", "longer than 40 characters") }
        guard let mediaName = d["media"] as? String else { throw SkinError.missing("media") }
        guard let media = Media(rawValue: mediaName) else {
            throw SkinError.badValue("media", "one of " + Media.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let left = try blocks(d["left"], side: "left"), right = try blocks(d["right"], side: "right")
        // Every control has to be somewhere: the transport, the progress (a display shows it), the
        // wheel you turn to scrub, the knobs.
        let all = left + right
        for (kind, what) in [(Block.Kind.display, "a display (the song, the time and the progress)"), (.buttons, "buttons"),
                             (.wheel, "a wheel (for scrubbing)"), (.knobs, "knobs")] {
            let count = all.filter { $0.kind == kind }.count
            guard count == 1 else {
                throw SkinError.badValue(count == 0 ? "left/right" : kind.rawValue, count == 0 ? "needs \(what)" : "only one \(kind.rawValue) block, please")
            }
        }
        return Design(id: id, name: name, media: media, left: left, right: right)
    }

    private static func blocks(_ value: Any?, side: String) throws -> [Block] {
        guard let list = value as? [[String: Any]] else { throw SkinError.badValue(side, "expected a list of blocks") }
        guard (1...12).contains(list.count) else { throw SkinError.badValue(side, "between 1 and 12 blocks") }
        return try list.enumerated().map { i, b in
            let path = "\(side)[\(i)]"
            if let extra = b.keys.sorted().first(where: { !["block", "height", "style", "label"].contains($0) }) {
                throw SkinError.unknownKey("\(path).\(extra)")
            }
            guard let raw = b["block"] as? String, let kind = Block.Kind(rawValue: raw) else {
                throw SkinError.badValue("\(path).block", "one of " + Block.Kind.allCases.map(\.rawValue).joined(separator: ", "))
            }
            var height = defaultHeights[kind] ?? nil
            if let h = b["height"] {
                if let s = h as? String, s == "fill" {
                    height = nil
                } else if let n = h as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), (8...400).contains(n.doubleValue) {
                    height = n.doubleValue
                } else {
                    throw SkinError.badValue("\(path).height", "a number from 8 to 400, or \"fill\"")
                }
            }
            let styles = styles[kind] ?? []
            var style = styles.first ?? ""
            if let s = b["style"] {
                guard let s = s as? String, styles.contains(s) else {
                    throw SkinError.badValue("\(path).style", styles.isEmpty ? "this block has no styles" : "one of " + styles.joined(separator: ", "))
                }
                style = s
            }
            var label: String?
            if let l = b["label"] {
                guard let l = l as? String, l.count <= 20 else { throw SkinError.badValue("\(path).label", "text of up to 20 characters") }
                label = l
            }
            return Block(kind: kind, height: height, style: style, label: label)
        }
    }

    public func encoded() -> Data {
        func list(_ blocks: [Block]) -> [[String: Any]] {
            blocks.map { b in
                var d: [String: Any] = ["block": b.kind.rawValue, "height": b.height.map { NSDecimalNumber(string: String($0)) } ?? "fill" as Any]
                if !(Self.styles[b.kind] ?? []).isEmpty { d["style"] = b.style }
                if let label = b.label { d["label"] = label }
                return d
            }
        }
        let d: [String: Any] = ["format": 1, "id": id, "name": name, "media": media.rawValue, "left": list(left), "right": list(right)]
        return (try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// An example design that ships with Himawari: a 1980s boombox (and the proof that a design
    /// file is all a new era needs).
    public static let builtIn: [Design] = [
        Design(id: "boombox", name: "1980s Boombox", media: .cassette,
               left: [Block(kind: .header, height: 40, style: "", label: nil),
                      Block(kind: .grille, height: nil, style: "", label: nil),
                      Block(kind: .display, height: 140, style: "vfd", label: nil),
                      Block(kind: .buttons, height: 38, style: "keys", label: nil),
                      Block(kind: .power, height: 44, style: "", label: nil)],
               right: [Block(kind: .header, height: 40, style: "", label: nil),
                       Block(kind: .meters, height: 70, style: "leds", label: nil),
                       Block(kind: .grille, height: nil, style: "", label: nil),
                       Block(kind: .wheel, height: 96, style: "knurled", label: "TUNING"),
                       Block(kind: .knobs, height: 80, style: "classic", label: nil)]),
    ]
}
