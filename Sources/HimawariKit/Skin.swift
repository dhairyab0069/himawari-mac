import Foundation

/// The kind of hardware the side gear is drawn as, and what plays in the middle.
public enum GearEra: String, CaseIterable, Sendable {
    case hifi      // 1970s: a walnut receiver and amplifier, a record on a turntable
    case cassette  // 1980s: a tape deck and a graphic equalizer, a cassette
    case portable  // 1990s: a portable CD player and its remote, a CD under a clear lid
    case rack      // 2000s: a CD deck and a stereo analyzer, a picture CD
    case pocket    // 2000s: a click-wheel pocket player and a speaker dock, the cover on its screen
    case minimal   // today: glass panels, a large cover, a thin waveform, a floating cover card

    /// The Style menu's heading for this era.
    public var title: String {
        switch self {
        case .hifi: "1970s Hi-Fi"
        case .cassette: "1980s Cassette Deck"
        case .portable: "1990s Portable"
        case .rack: "2000s Rack"
        case .pocket: "2000s Pocket Player"
        case .minimal: "Today, Minimal"
        }
    }
}

/// A colour in a skin file: "#RRGGBB" or "#RRGGBBAA".
public struct SkinColor: Equatable, Sendable {
    public var r, g, b, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }

    public init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit),
              let value = UInt64(digits, radix: 16) else { return nil }
        let v = digits.count == 6 ? value << 8 | 0xFF : value
        self.init(Double(v >> 24 & 0xFF) / 255, Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public var hex: String {
        let parts = [r, g, b] + (a < 1 ? [a] : [])
        return "#" + parts.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }

    /// Partway from this colour to `other` (0 = this, 1 = other).
    public func mixed(_ other: SkinColor, _ t: Double) -> SkinColor {
        SkinColor(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t)
    }

    public func alpha(_ a: Double) -> SkinColor { SkinColor(r, g, b, a) }
}

/// What a faceplate is made of: how it's textured.
public enum SkinMaterial: String, CaseIterable, Sendable {
    case brushed  // fine horizontal brushing (aluminium)
    case chrome   // brushing under a strong polished highlight
    case plastic  // a fine speckle
    case matte    // plain
    case neon     // plain, with a glowing edge in the accent colour (the cover's card glows too)
}

/// How one look of the side gear is coloured and lettered: what a skin file in
/// `~/Library/Application Support/Himawari/Skins/` holds. Where the controls go is the era's
/// (code); everything here can be changed without code.
public struct Skin: Equatable, Sendable {
    public var id: String
    public var name: String
    public var era: GearEra
    public var brand: String
    public var leftModel: String
    public var rightModel: String
    public var material: SkinMaterial
    /// How strong the brushing / speckle is, 0…0.2.
    public var grain: Double
    public var colors: Colors
    /// PostScript font names; nil: the system font.
    public var brandFont: String?
    public var displayFont: String?
    public var layout: Layout
    /// Your own era to wear (a design file's id), instead of the era's own layout. The era still
    /// says which built-in skin is the base and where the skin shows in the menus.
    public var design: String? = nil

    public struct Colors: Equatable, Sendable {
        public var plate: [SkinColor]   // 3: the faceplate's top, middle and bottom
        public var glass: [SkinColor]   // 2: the display windows, top and bottom
        public var display: SkinColor   // lit text and segments
        public var accent: SkinColor    // lamps and the upper segments
        public var peak: SkinColor      // the red zone and the top segments
        public var label: SkinColor     // printing on the faceplate
        public var ink: SkinColor       // printing on the meter faces, and the needles
        public var meter: [SkinColor]   // 2: the meter faces, top and bottom
        public var button: [SkinColor]  // 2: buttons, top and bottom
        public var knob: [SkinColor]    // 2: knobs, light and dark side
        public var cabinet: SkinColor   // the wooden case around the faceplate (when layout.caseWidth > 0)
        public var media: SkinColor     // the cassette's shell, the turntable's platter
    }

    public struct Layout: Equatable, Sendable {
        public var columnWidth: Double  // how wide the controls are, at most (200…360)
        public var corner: Double       // faceplate corner radius (0…30)
        public var gap: Double          // between buttons (4…16)
        public var caseWidth: Double    // the wooden case's sides (0 = none, up to 30)
    }
}

/// Why a skin file was turned down.
public enum SkinError: Error, Equatable, CustomStringConvertible {
    case notJSON
    case unsupportedFormat
    case missing(String)
    case unknownKey(String)
    case badValue(String, String)

    public var description: String {
        switch self {
        case .notJSON: "not a JSON object"
        case .unsupportedFormat: "\"format\" must be 1"
        case .missing(let key): "\"\(key)\" is missing"
        case .unknownKey(let key): "unknown setting \"\(key)\""
        case .badValue(let key, let why): "\"\(key)\": \(why)"
        }
    }
}

// MARK: - Reading and writing skin files

extension Skin {
    private static let topKeys: Set<String> = ["format", "id", "name", "era", "base", "brand", "models", "material",
                                               "grain", "colors", "fonts", "layout", "design"]
    private static let colorCounts: [String: Int] = ["plate": 3, "glass": 2, "display": 1, "accent": 1, "peak": 1,
                                                     "label": 1, "ink": 1, "meter": 2, "button": 2, "knob": 2,
                                                     "case": 1, "media": 1]

    /// Reads a skin file. Anything it leaves out comes from `base` (a built-in skin's id; by
    /// default the era's first one), so a file can be as small as an id, a name, an era and a colour.
    public static func decode(_ data: Data) throws -> Skin {
        guard let json = try? JSONSerialization.jsonObject(with: data), let d = json as? [String: Any] else { throw SkinError.notJSON }
        if let extra = d.keys.sorted().first(where: { !topKeys.contains($0) }) { throw SkinError.unknownKey(extra) }
        guard let format = d["format"] else { throw SkinError.missing("format") }
        guard let n = number(format), n == 1 else { throw SkinError.unsupportedFormat }

        let id = try text(d, "id", required: true, limit: 40)!
        guard id.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
            throw SkinError.badValue("id", "use lowercase letters, digits and dashes")
        }
        let name = try text(d, "name", required: true, limit: 40)!
        guard let eraName = try text(d, "era", required: true, limit: 20), let era = GearEra(rawValue: eraName) else {
            throw SkinError.badValue("era", "one of " + GearEra.allCases.map(\.rawValue).joined(separator: ", "))
        }
        var skin: Skin
        if let baseID = try text(d, "base", required: false, limit: 40) {
            guard let base = builtIn.first(where: { $0.id == baseID }) else { throw SkinError.badValue("base", "no built-in skin \"\(baseID)\"") }
            guard base.era == era else { throw SkinError.badValue("base", "\"\(baseID)\" is a \(base.era.rawValue) skin") }
            skin = base
        } else {
            skin = builtIn.first { $0.era == era }!
        }
        skin.id = id
        skin.name = name
        skin.era = era
        if let brand = try text(d, "brand", required: false, limit: 20) { skin.brand = brand }
        if d.keys.contains("design") {
            skin.design = try text(d, "design", required: false, limit: 40)
            if let design = skin.design, design.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) == nil {
                throw SkinError.badValue("design", "a design file's id: lowercase letters, digits and dashes")
            }
        }

        if let models = d["models"] {
            guard let m = models as? [String: Any] else { throw SkinError.badValue("models", "expected {\"left\": …, \"right\": …}") }
            if let extra = m.keys.sorted().first(where: { !["left", "right"].contains($0) }) { throw SkinError.unknownKey("models.\(extra)") }
            if let left = try text(m, "left", required: false, limit: 40, path: "models.left") { skin.leftModel = left }
            if let right = try text(m, "right", required: false, limit: 40, path: "models.right") { skin.rightModel = right }
        }
        if let raw = try text(d, "material", required: false, limit: 20) {
            guard let material = SkinMaterial(rawValue: raw) else {
                throw SkinError.badValue("material", "one of " + SkinMaterial.allCases.map(\.rawValue).joined(separator: ", "))
            }
            skin.material = material
        }
        if let grain = try range(d, "grain", 0...0.2) { skin.grain = grain }

        if let colors = d["colors"] {
            guard let c = colors as? [String: Any] else { throw SkinError.badValue("colors", "expected an object") }
            if let extra = c.keys.sorted().first(where: { colorCounts[$0] == nil }) { throw SkinError.unknownKey("colors.\(extra)") }
            func read(_ key: String) throws -> [SkinColor]? {
                guard let value = c[key] else { return nil }
                let count = colorCounts[key]!
                let strings: [Any] = count == 1 ? [value] : (value as? [Any] ?? [])
                guard strings.count == count else { throw SkinError.badValue("colors.\(key)", "expected a list of \(count) colours") }
                return try strings.map { s in
                    guard let s = s as? String, let color = SkinColor(hex: s) else {
                        throw SkinError.badValue("colors.\(key)", "colours are written #RRGGBB or #RRGGBBAA")
                    }
                    return color
                }
            }
            if let v = try read("plate") { skin.colors.plate = v }
            if let v = try read("glass") { skin.colors.glass = v }
            if let v = try read("display") { skin.colors.display = v[0] }
            if let v = try read("accent") { skin.colors.accent = v[0] }
            if let v = try read("peak") { skin.colors.peak = v[0] }
            if let v = try read("label") { skin.colors.label = v[0] }
            if let v = try read("ink") { skin.colors.ink = v[0] }
            if let v = try read("meter") { skin.colors.meter = v }
            if let v = try read("button") { skin.colors.button = v }
            if let v = try read("knob") { skin.colors.knob = v }
            if let v = try read("case") { skin.colors.cabinet = v[0] }
            if let v = try read("media") { skin.colors.media = v[0] }
        }

        if let fonts = d["fonts"] {
            guard let f = fonts as? [String: Any] else { throw SkinError.badValue("fonts", "expected an object") }
            if let extra = f.keys.sorted().first(where: { !["brand", "display"].contains($0) }) { throw SkinError.unknownKey("fonts.\(extra)") }
            // null: back to the system font.
            if f.keys.contains("brand") { skin.brandFont = try text(f, "brand", required: false, limit: 60, path: "fonts.brand") }
            if f.keys.contains("display") { skin.displayFont = try text(f, "display", required: false, limit: 60, path: "fonts.display") }
        }

        if let layout = d["layout"] {
            guard let l = layout as? [String: Any] else { throw SkinError.badValue("layout", "expected an object") }
            let keys = ["columnWidth", "corner", "gap", "caseWidth"]
            if let extra = l.keys.sorted().first(where: { !keys.contains($0) }) { throw SkinError.unknownKey("layout.\(extra)") }
            if let v = try range(l, "columnWidth", 200...360, path: "layout.columnWidth") { skin.layout.columnWidth = v }
            if let v = try range(l, "corner", 0...30, path: "layout.corner") { skin.layout.corner = v }
            if let v = try range(l, "gap", 4...16, path: "layout.gap") { skin.layout.gap = v }
            if let v = try range(l, "caseWidth", 0...30, path: "layout.caseWidth") { skin.layout.caseWidth = v }
        }
        return skin
    }

    /// The whole skin as a file (every setting written out, so it doubles as an example).
    public func encoded() -> Data {
        func one(_ c: SkinColor) -> String { c.hex }
        func n(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(v)) } // 0.035, not 0.03500000000000002
        func list(_ c: [SkinColor]) -> [String] { c.map(\.hex) }
        var d: [String: Any] = [
            "format": 1, "id": id, "name": name, "era": era.rawValue, "brand": brand,
            "models": ["left": leftModel, "right": rightModel],
            "material": material.rawValue, "grain": n(grain),
            "colors": ["plate": list(colors.plate), "glass": list(colors.glass), "display": one(colors.display),
                       "accent": one(colors.accent), "peak": one(colors.peak), "label": one(colors.label),
                       "ink": one(colors.ink), "meter": list(colors.meter), "button": list(colors.button),
                       "knob": list(colors.knob), "case": one(colors.cabinet), "media": one(colors.media)],
            "fonts": ["brand": brandFont as Any? ?? NSNull(), "display": displayFont as Any? ?? NSNull()],
            "layout": ["columnWidth": n(layout.columnWidth), "corner": n(layout.corner), "gap": n(layout.gap),
                       "caseWidth": n(layout.caseWidth)],
        ]
        if let design { d["design"] = design }
        return (try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// A JSON number (not true / false, which JSONSerialization also hands over as numbers).
    private static func number(_ value: Any) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    private static func text(_ d: [String: Any], _ key: String, required: Bool, limit: Int, path: String? = nil) throws -> String? {
        let path = path ?? key
        guard let value = d[key], !(value is NSNull) else {
            if required { throw SkinError.missing(path) }
            return nil
        }
        guard let s = value as? String else { throw SkinError.badValue(path, "expected text") }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw SkinError.badValue(path, "is empty") }
        guard trimmed.count <= limit else { throw SkinError.badValue(path, "longer than \(limit) characters") }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SkinError.badValue(path, "contains control characters")
        }
        return trimmed
    }

    private static func range(_ d: [String: Any], _ key: String, _ allowed: ClosedRange<Double>, path: String? = nil) throws -> Double? {
        guard let value = d[key] else { return nil }
        guard let n = number(value), n.isFinite else { throw SkinError.badValue(path ?? key, "expected a number") }
        guard allowed.contains(n) else {
            throw SkinError.badValue(path ?? key, "must be between \(allowed.lowerBound.formatted()) and \(allowed.upperBound.formatted())")
        }
        return n
    }
}

// MARK: - The built-in skins

extension Skin {
    private static func c(_ hex: String) -> SkinColor { SkinColor(hex: hex)! }

    /// Two skins per era, in the Style menu's order. The first of each era is what a skin file
    /// without a "base" starts from.
    public static let builtIn: [Skin] = [
        Skin(id: "hifi-walnut", name: "Walnut", era: .hifi, brand: "HIMAWARI",
             leftModel: "STEREO RECEIVER   HR-1975", rightModel: "STEREO AMPLIFIER   HA-1975",
             material: .brushed, grain: 0.035,
             colors: .init(plate: [c("#D6D5D0"), c("#AEADA8"), c("#C4C3BE")], glass: [c("#1C1408"), c("#0C0804")],
                           display: c("#FFC46B"), accent: c("#FFB24D"), peak: c("#D1201A"), label: c("#26231F"),
                           ink: c("#2E1F14"), meter: [c("#FFE7AE"), c("#EDB560")], button: [c("#EFEFEB"), c("#A2A29D")],
                           knob: [c("#F2F2EE"), c("#8C8C88")], cabinet: c("#5B3219"), media: c("#3A2414")),
             brandFont: "Futura-Medium", displayFont: nil,
             layout: .init(columnWidth: 300, corner: 6, gap: 8, caseWidth: 16)),
        Skin(id: "hifi-silver", name: "Brushed Silver", era: .hifi, brand: "HIMAWARI",
             leftModel: "STEREO RECEIVER   HR-1977", rightModel: "STEREO AMPLIFIER   HA-1977",
             material: .brushed, grain: 0.05,
             colors: .init(plate: [c("#E3E4E3"), c("#B4B6B6"), c("#CDCFCF")], glass: [c("#07131F"), c("#02070D")],
                           display: c("#A6E8FF"), accent: c("#FFB24D"), peak: c("#D1201A"), label: c("#1E2124"),
                           ink: c("#13222E"), meter: [c("#EAF4F8"), c("#B4CAD6")], button: [c("#F4F5F5"), c("#A5A8A9")],
                           knob: [c("#F6F7F7"), c("#8D9091")], cabinet: c("#8D9091"), media: c("#B9BCBD")),
             brandFont: "Futura-Medium", displayFont: nil,
             layout: .init(columnWidth: 300, corner: 6, gap: 8, caseWidth: 0)),
        Skin(id: "cassette-black", name: "Black Plastic", era: .cassette, brand: "HIMAWARI",
             leftModel: "STEREO CASSETTE DECK   TC-1985", rightModel: "GRAPHIC EQUALIZER   GE-1985",
             material: .plastic, grain: 0.05,
             colors: .init(plate: [c("#2C2C2E"), c("#1C1C1E"), c("#242426")], glass: [c("#061210"), c("#020806")],
                           display: c("#5CF2C4"), accent: c("#FFC23D"), peak: c("#FF3B30"), label: c("#C9C9CC"),
                           ink: c("#2E1F14"), meter: [c("#FFE6A8"), c("#EDB866")], button: [c("#4C4C50"), c("#1E1E21")],
                           knob: [c("#5A5A5E"), c("#141416")], cabinet: c("#1C1C1E"), media: c("#1D1D20")),
             brandFont: "AvenirNext-HeavyItalic", displayFont: nil,
             layout: .init(columnWidth: 300, corner: 4, gap: 6, caseWidth: 0)),
        Skin(id: "cassette-metal", name: "Chrome Metal", era: .cassette, brand: "HIMAWARI",
             leftModel: "METAL CASSETTE DECK   TC-1988", rightModel: "GRAPHIC EQUALIZER   GE-1988",
             material: .chrome, grain: 0.04,
             colors: .init(plate: [c("#ECEEF0"), c("#A3A8AD"), c("#D3D7DB")], glass: [c("#140C06"), c("#070402")],
                           display: c("#FF9A3C"), accent: c("#FFD23D"), peak: c("#FF3B30"), label: c("#1D2023"),
                           ink: c("#2E1F14"), meter: [c("#FFE6A8"), c("#EDB866")], button: [c("#F2F4F6"), c("#90959A")],
                           knob: [c("#F4F6F8"), c("#7E8389")], cabinet: c("#A3A8AD"), media: c("#9AA1A8")),
             brandFont: "AvenirNext-HeavyItalic", displayFont: nil,
             layout: .init(columnWidth: 300, corner: 4, gap: 6, caseWidth: 0)),
        Skin(id: "portable-silver", name: "Silver", era: .portable, brand: "HIMAWARI",
             leftModel: "DISCPLAYER   D-1994   ANTI-SKIP", rightModel: "LCD REMOTE   RM-94   MEGA BASS",
             material: .plastic, grain: 0.03,
             colors: .init(plate: [c("#D9DCDF"), c("#B3B7BB"), c("#C7CBCF")], glass: [c("#B9C6A6"), c("#9DAC88")],
                           display: c("#1C2618"), accent: c("#E8A33A"), peak: c("#D8342C"), label: c("#2A2D31"),
                           ink: c("#2E1F14"), meter: [c("#B9C6A6"), c("#9DAC88")], button: [c("#8E9398"), c("#5B6066")],
                           knob: [c("#EEF0F2"), c("#8F9499")], cabinet: c("#B3B7BB"), media: c("#C9CDD1")),
             brandFont: "AvenirNext-DemiBoldItalic", displayFont: nil,
             layout: .init(columnWidth: 300, corner: 18, gap: 10, caseWidth: 0)),
        Skin(id: "portable-clear", name: "Translucent Purple", era: .portable, brand: "HIMAWARI",
             leftModel: "DISCPLAYER   D-1998   ANTI-SKIP", rightModel: "LCD REMOTE   RM-98   MEGA BASS",
             material: .matte, grain: 0,
             colors: .init(plate: [c("#9B7BE0C0"), c("#6E4FC2B0"), c("#8463D4B8")], glass: [c("#B8D2C8"), c("#94B4A8")],
                           display: c("#142019"), accent: c("#FFD24D"), peak: c("#FF4D6A"), label: c("#F2ECFF"),
                           ink: c("#2E1F14"), meter: [c("#B8D2C8"), c("#94B4A8")], button: [c("#C9B6F5D0"), c("#7E5CD0D0")],
                           knob: [c("#E4DAFF"), c("#7253C6")], cabinet: c("#6E4FC2"), media: c("#8A6ADBC0")),
             brandFont: "AvenirNext-DemiBoldItalic", displayFont: nil,
             layout: .init(columnWidth: 300, corner: 18, gap: 10, caseWidth: 0)),
        // Today's look, exactly as before skins: the numbers are the old hard-coded ones.
        Skin(id: "rack-black", name: "Black", era: .rack, brand: "HIMAWARI",
             leftModel: "COMPACT DISC PLAYER   HD-2160", rightModel: "STEREO LEVEL ANALYZER   SA-10",
             material: .brushed, grain: 0.045,
             colors: .init(plate: [c("#3B3B3BF7"), c("#242424F7"), c("#2E2E2EF7")], glass: [c("#051214"), c("#03080A")],
                           display: c("#73F7FF"), accent: c("#FFB84D"), peak: c("#D11F1A"), label: c("#D9D9D9"),
                           ink: c("#2E1F14"), meter: [c("#FFE6A8"), c("#EDB866")], button: [c("#6B6B6B"), c("#333333")],
                           knob: [c("#9E9E9E"), c("#404040")], cabinet: c("#242424"), media: c("#242424")),
             brandFont: nil, displayFont: nil,
             layout: .init(columnWidth: 300, corner: 8, gap: 8, caseWidth: 0)),
        Skin(id: "rack-champagne", name: "Champagne Gold", era: .rack, brand: "HIMAWARI",
             leftModel: "COMPACT DISC PLAYER   HD-2160G", rightModel: "STEREO LEVEL ANALYZER   SA-10G",
             material: .brushed, grain: 0.035,
             colors: .init(plate: [c("#C9B58C"), c("#9C8760"), c("#B39E74")], glass: [c("#06101A"), c("#02070C")],
                           display: c("#9AD8FF"), accent: c("#FFB84D"), peak: c("#D11F1A"), label: c("#2A2116"),
                           ink: c("#2E1F14"), meter: [c("#FFE6A8"), c("#EDB866")], button: [c("#D9C79F"), c("#8C7852")],
                           knob: [c("#E2D2AC"), c("#7A6643")], cabinet: c("#9C8760"), media: c("#9C8760")),
             brandFont: nil, displayFont: nil,
             layout: .init(columnWidth: 300, corner: 8, gap: 8, caseWidth: 0)),
        Skin(id: "pocket-white", name: "White", era: .pocket, brand: "HIMAWARI",
             leftModel: "POCKET PLAYER   40 GB", rightModel: "SPEAKER DOCK   HI-FI",
             material: .matte, grain: 0,
             colors: .init(plate: [c("#FCFCFC"), c("#ECECEE"), c("#F5F5F7")], glass: [c("#E9EEF4"), c("#C9D3DE")],
                           display: c("#1F2933"), accent: c("#3D8BFF"), peak: c("#FF3B30"), label: c("#6E7378"),
                           ink: c("#2E1F14"), meter: [c("#FFE6A8"), c("#EDB866")], button: [c("#FFFFFF"), c("#E3E4E6")],
                           knob: [c("#FFFFFF"), c("#C7C9CC")], cabinet: c("#D9DADC"), media: c("#F7F7F8")),
             brandFont: "HelveticaNeue-Medium", displayFont: "HelveticaNeue-Bold",
             layout: .init(columnWidth: 300, corner: 20, gap: 8, caseWidth: 0)),
        Skin(id: "pocket-black", name: "Black", era: .pocket, brand: "HIMAWARI",
             leftModel: "POCKET PLAYER   80 GB", rightModel: "SPEAKER DOCK   HI-FI",
             material: .matte, grain: 0,
             colors: .init(plate: [c("#2B2C2F"), c("#151618"), c("#202124")], glass: [c("#E9EEF4"), c("#C9D3DE")],
                           display: c("#1F2933"), accent: c("#3D8BFF"), peak: c("#FF3B30"), label: c("#9A9EA3"),
                           ink: c("#2E1F14"), meter: [c("#FFE6A8"), c("#EDB866")], button: [c("#3A3B3F"), c("#1C1D20")],
                           knob: [c("#55575C"), c("#1E1F22")], cabinet: c("#151618"), media: c("#1D1E21")),
             brandFont: "HelveticaNeue-Medium", displayFont: "HelveticaNeue-Bold",
             layout: .init(columnWidth: 300, corner: 20, gap: 8, caseWidth: 0)),
        Skin(id: "pocket-blue", name: "Colours (Blue)", era: .pocket, brand: "HIMAWARI",
             leftModel: "POCKET PLAYER   MINI", rightModel: "SPEAKER DOCK   MINI",
             material: .brushed, grain: 0.03,
             colors: .init(plate: [c("#7FB8EE"), c("#4F92D8"), c("#68A6E4")], glass: [c("#E9EEF4"), c("#C9D3DE")],
                           display: c("#1F2933"), accent: c("#FF9F0A"), peak: c("#FF3B30"), label: c("#0E2A4A"),
                           ink: c("#2E1F14"), meter: [c("#FFE6A8"), c("#EDB866")], button: [c("#F4F7FA"), c("#D5DEE8")],
                           knob: [c("#F4F7FA"), c("#B8C6D6")], cabinet: c("#4F92D8"), media: c("#5E9FE0")),
             brandFont: "HelveticaNeue-Medium", displayFont: "HelveticaNeue-Bold",
             layout: .init(columnWidth: 300, corner: 20, gap: 8, caseWidth: 0)),
        Skin(id: "minimal-dark", name: "Dark", era: .minimal, brand: "HIMAWARI",
             leftModel: "NOW PLAYING", rightModel: "LEVELS",
             material: .matte, grain: 0,
             colors: .init(plate: [c("#1C1C1EB8"), c("#141416B8"), c("#18181AB8")], glass: [c("#00000000"), c("#00000000")],
                           display: c("#F5F5F7"), accent: c("#FF375F"), peak: c("#FF453A"), label: c("#A1A1A6"),
                           ink: c("#2E1F14"), meter: [c("#FFE6A8"), c("#EDB866")], button: [c("#FFFFFF14"), c("#FFFFFF0A")],
                           knob: [c("#3A3A3C"), c("#2C2C2E")], cabinet: c("#141416"), media: c("#1C1C1E")),
             brandFont: "HelveticaNeue-Medium", displayFont: nil,
             layout: .init(columnWidth: 300, corner: 22, gap: 8, caseWidth: 0)),
        Skin(id: "minimal-light", name: "Light", era: .minimal, brand: "HIMAWARI",
             leftModel: "NOW PLAYING", rightModel: "LEVELS",
             material: .matte, grain: 0,
             colors: .init(plate: [c("#FFFFFFD8"), c("#F2F2F7D8"), c("#F8F8FAD8")], glass: [c("#00000000"), c("#00000000")],
                           display: c("#1C1C1E"), accent: c("#0A84FF"), peak: c("#FF3B30"), label: c("#6E6E73"),
                           ink: c("#2E1F14"), meter: [c("#FFE6A8"), c("#EDB866")], button: [c("#0000000F"), c("#00000008")],
                           knob: [c("#FFFFFF"), c("#E5E5EA")], cabinet: c("#F2F2F7"), media: c("#FFFFFF")),
             brandFont: "HelveticaNeue-Medium", displayFont: nil,
             layout: .init(columnWidth: 300, corner: 22, gap: 8, caseWidth: 0)),
        Skin(id: "minimal-frosted", name: "Frosted", era: .minimal, brand: "HIMAWARI",
             leftModel: "NOW PLAYING", rightModel: "LEVELS",
             material: .matte, grain: 0,
             colors: .init(plate: [c("#FFFFFF40"), c("#FFFFFF26"), c("#FFFFFF33")], glass: [c("#00000000"), c("#00000000")],
                           display: c("#FFFFFF"), accent: c("#FFD60A"), peak: c("#FF453A"), label: c("#FFFFFFB0"),
                           ink: c("#2E1F14"), meter: [c("#FFE6A8"), c("#EDB866")], button: [c("#FFFFFF24"), c("#FFFFFF10")],
                           knob: [c("#FFFFFF60"), c("#FFFFFF30")], cabinet: c("#FFFFFF33"), media: c("#FFFFFF")),
             brandFont: "HelveticaNeue-Medium", displayFont: nil,
             layout: .init(columnWidth: 300, corner: 22, gap: 8, caseWidth: 0)),
        // The worked example in docs/make-your-own.md, wearing the Cyberpunk design.
        Skin(id: "cyberpunk-neon", name: "Neon", era: .minimal, brand: "NEO-TOKYO",
             leftModel: "SOUND SYSTEM   NT-2099", rightModel: "SIGNAL ANALYZER   NT-2099",
             material: .neon, grain: 0,
             colors: .init(plate: [c("#0E0A1CE6"), c("#07050FE6"), c("#0B0817E6")], glass: [c("#0A0018"), c("#030008")],
                           display: c("#00F0FF"), accent: c("#FF2BD6"), peak: c("#FFE600"), label: c("#FF2BD6"),
                           ink: c("#2E1F14"), meter: [c("#FFE6A8"), c("#EDB866")], button: [c("#1C1236"), c("#0A0618")],
                           knob: [c("#2A1A48"), c("#0A0618")], cabinet: c("#07050F"), media: c("#0B0B14")),
             brandFont: "Futura-CondensedExtraBold", displayFont: "Menlo-Bold",
             layout: .init(columnWidth: 300, corner: 4, gap: 8, caseWidth: 0), design: "cyberpunk"),
        // Wearing the example design (Design.builtIn): a boombox, in the black tape deck's colours.
        Skin(id: "boombox-black", name: "Boombox", era: .cassette, brand: "HIMAWARI",
             leftModel: "STEREO RADIO CASSETTE   RC-1986", rightModel: "4-BAND RECEIVER   SUPER WOOFER",
             material: .chrome, grain: 0.03,
             colors: .init(plate: [c("#D8DBDE"), c("#9DA2A7"), c("#C4C8CC")], glass: [c("#061210"), c("#020806")],
                           display: c("#5CF2C4"), accent: c("#FFC23D"), peak: c("#FF3B30"), label: c("#1D2023"),
                           ink: c("#2E1F14"), meter: [c("#FFE6A8"), c("#EDB866")], button: [c("#4C4C50"), c("#1E1E21")],
                           knob: [c("#5A5A5E"), c("#141416")], cabinet: c("#1C1C1E"), media: c("#1D1D20")),
             brandFont: "AvenirNext-HeavyItalic", displayFont: nil,
             layout: .init(columnWidth: 300, corner: 10, gap: 6, caseWidth: 0), design: "boombox"),
    ]

    /// Today's look: what Himawari shows until you pick another.
    public static let standard = builtIn.first { $0.id == "rack-black" }!
}

// MARK: - The skins on this Mac

/// The built-in skins plus the ones in the skins folder. A file whose id is a built-in one's
/// replaces it; a file that doesn't load is skipped, with the reason in `problems`.
public struct SkinLibrary: Sendable {
    public private(set) var skins: [Skin]
    public private(set) var problems: [String]
    /// Your own eras (and the built-in example).
    public private(set) var designs: [Design]

    public static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Himawari/Skins")
    public static let designsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Himawari/Designs")

    public init(folder: URL? = SkinLibrary.folder, designsFolder: URL? = SkinLibrary.designsFolder) {
        skins = Skin.builtIn
        problems = []
        designs = Design.builtIn
        if let designsFolder, let names = try? FileManager.default.contentsOfDirectory(atPath: designsFolder.path) {
            for name in names.sorted() where name.lowercased().hasSuffix(".json") {
                do {
                    guard let data = try? Data(contentsOf: designsFolder.appending(path: name)), data.count < 64 * 1024 else {
                        throw SkinError.badValue(name, "can't be read")
                    }
                    let design = try Design.decode(data)
                    if let i = designs.firstIndex(where: { $0.id == design.id }) { designs[i] = design } else { designs.append(design) }
                } catch {
                    problems.append("Designs/\(name): \(error)")
                }
            }
        }
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        var seen: Set<String> = []
        for name in names.sorted() where name.lowercased().hasSuffix(".json") {
            let url = folder.appending(path: name)
            do {
                guard let data = try? Data(contentsOf: url), data.count < 64 * 1024 else { throw SkinError.badValue(name, "can't be read") }
                let skin = try Skin.decode(data)
                guard !seen.contains(skin.id) else { throw SkinError.badValue("id", "\"\(skin.id)\" is used by another file") }
                seen.insert(skin.id)
                if let i = skins.firstIndex(where: { $0.id == skin.id }) { skins[i] = skin } else { skins.append(skin) }
            } catch {
                problems.append("\(name): \(error)")
            }
        }
    }

    public func skin(id: String?) -> Skin? { skins.first { $0.id == id } }
    public func design(id: String?) -> Design? { designs.first { $0.id == id } }

    /// Adds (or replaces) a design, as if its file were in the folder.
    public mutating func add(_ design: Design) {
        if let i = designs.firstIndex(where: { $0.id == design.id }) { designs[i] = design } else { designs.append(design) }
    }

    /// The skins of one era, in menu order (built-ins first, then yours by name).
    public func skins(of era: GearEra) -> [Skin] {
        let builtInIDs = Skin.builtIn.map(\.id)
        return skins.filter { $0.era == era }.sorted { a, b in
            let ia = builtInIDs.firstIndex(of: a.id) ?? .max, ib = builtInIDs.firstIndex(of: b.id) ?? .max
            return ia != ib ? ia < ib : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Writes the built-in skins to `Skins/Examples/` (refreshed each launch, never loaded:
    /// copy one up into `Skins/` and change it) and a short read-me.
    public static func writeExamples(to folder: URL = SkinLibrary.folder) throws {
        let examples = folder.appending(path: "Examples")
        try FileManager.default.createDirectory(at: examples, withIntermediateDirectories: true)
        for skin in Skin.builtIn {
            try skin.encoded().write(to: examples.appending(path: "\(skin.id).json"), options: .atomic)
        }
        try readMe.write(to: folder.appending(path: "README.txt"), atomically: true, encoding: .utf8)
        let designs = designsFolder.appending(path: "Examples")
        try FileManager.default.createDirectory(at: designs, withIntermediateDirectories: true)
        for design in Design.builtIn { try design.encoded().write(to: designs.appending(path: "\(design.id).json"), options: .atomic) }
        try designReadMe.write(to: designsFolder.appending(path: "README.txt"), atomically: true, encoding: .utf8)
    }

    static let designReadMe = """
    Himawari designs: your own eras
    ===============================

    A design is the side gear's layout: each panel as a stack of blocks, top to bottom, and what
    plays in the middle. A skin wears it with "design": "<the design's id>" (and still sets the
    colours, fonts and so on; its "era" picks the built-in skin it starts from).

        {
          "format": 1, "id": "boombox", "name": "1980s Boombox", "media": "cassette",
          "left":  [ { "block": "header" }, { "block": "grille" },
                     { "block": "display", "style": "vfd", "height": 140 },
                     { "block": "buttons", "style": "keys" }, { "block": "power" } ],
          "right": [ { "block": "header" }, { "block": "meters", "style": "leds", "height": 70 },
                     { "block": "grille" }, { "block": "wheel", "label": "TUNING", "height": 96 },
                     { "block": "knobs" } ]
        }

    media:   cd, record, cassette, discman, player, card, cartridge
    blocks:  header, display, buttons, wheel, meters, spectrum, knobs, grille, toggles, sliders,
             power, spacer, gamepad (a D-pad and two face buttons, for show)
    styles:  display vfd | lcd | glass | dial;  buttons rounded | keys | round | flat | bare;
             wheel knurled | ring | clickwheel;  knobs classic | flat | touch;
             meters needles | leds | spectrum
    height:  points (8-400), or "fill" to share what's left (grille, wheel and spectrum fill
             unless told otherwise)
    label:   text under a wheel

    A design needs exactly one display, one row of buttons, one wheel and one row of knobs, on
    either side. The built-in example is in Examples/ (rewritten each launch). Save a design
    here, then a skin with its id in ../Skins/, and pick the skin in Style; both reload as you save.
    """

    static let readMe = """
    Himawari skins
    ==============

    Each .json file in this folder is one skin for the side gear: its colours, materials,
    lettering and a few layout numbers. Pick it in Himawari's menu > Style. After editing
    a file, choose Style > Reload Skins.

    The built-in skins are in Examples/ (rewritten each time Himawari starts, and not loaded
    from there). Copy one up into this folder, give it a new "id" and "name", and change what
    you like. Anything you leave out comes from "base", a built-in skin of the same era:

        {
          "format": 1,
          "id": "red-rack",
          "name": "Red Display",
          "era": "rack",
          "base": "rack-black",
          "colors": { "display": "#FF4A3D" }
        }

    era:      hifi (1970s), cassette (1980s), portable (1990s), rack (2000s),
              pocket (2000s), minimal (today)
    material: brushed, chrome, plastic, matte, neon;  grain: 0 to 0.2
    colours:  "#RRGGBB" or "#RRGGBBAA"; plate is 3 colours (top, middle, bottom), glass, meter,
              button and knob are 2, the rest are 1
    fonts:    PostScript names (as Font Book shows them), or null for the system font
    layout:   columnWidth 200-360, corner 0-30, gap 4-16, caseWidth 0-30 (a wooden case)

    A file with the same id as a built-in skin replaces it. If a file has a mistake, Style
    shows which file and what's wrong, and the others still load.
    """
}
