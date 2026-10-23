import AppKit
import HimawariKit
import QuartzCore

/// One look of the side gear: an era's layout (where the hardware and each control go) drawn in
/// a skin's colours. `NowPlayingSides` builds the panels from the two faces a theme hands it and
/// keeps their moving parts up to date, the same way for every era.
@MainActor
protocol GearTheme {
    var skin: Skin { get }
    /// The level meters to draw: the era's own (`.era`), or needles, LEDs or a spectrum.
    var meters: StyleOptions.Meters { get }
    /// The left panel (the player) and the right one (meters and knobs), each `size` points.
    func left(size: CGSize) -> PanelFace
    func right(size: CGSize) -> PanelFace
}

/// What plays in the middle of the music scene.
enum MediaKind {
    case cd        // a picture CD
    case record    // a vinyl record on a turntable, with a tonearm
    case cassette  // a cassette whose reels turn
    case discman   // a CD in a portable player, under its clear lid
    case player    // a pocket player: the cover on its screen, a click wheel that scrubs
    case card      // the cover on a floating card
}

@MainActor
enum Themes {
    static func make(_ skin: Skin, meters: StyleOptions.Meters = .era) -> GearTheme {
        // Your own era, when the skin wears one that's there (otherwise its era's own layout).
        if let id = skin.design, let design = Styles.shared.library.design(id: id) {
            return CustomTheme(skin: skin, design: design, meters: meters)
        }
        return switch skin.era {
        case .rack: RackTheme(skin: skin, meters: meters)
        case .hifi: HiFiTheme(skin: skin, meters: meters)
        case .cassette: CassetteTheme(skin: skin, meters: meters)
        case .portable: PortableTheme(skin: skin, meters: meters)
        case .pocket: PocketTheme(skin: skin, meters: meters)
        case .minimal: MinimalTheme(skin: skin, meters: meters)
        }
    }

    /// What plays in the middle for this skin: its design's media, or its era's.
    static func media(_ skin: Skin) -> MediaKind {
        if let id = skin.design, let design = Styles.shared.library.design(id: id) {
            switch design.media {
            case .cd: return .cd
            case .record: return .record
            case .cassette: return .cassette
            case .discman: return .discman
            case .player: return .player
            case .card: return .card
            }
        }
        return media(skin.era)
    }

    static func media(_ era: GearEra) -> MediaKind {
        switch era {
        case .rack: .cd
        case .hifi: .record
        case .cassette: .cassette
        case .portable: .discman
        case .pocket: .player
        case .minimal: .card
        }
    }
}

// MARK: - Parts

/// One panel as a theme lays it out (faceplate coordinates, y up): the hardware, drawn once,
/// and where each part that moves or responds goes.
struct PanelFace {
    /// Draws the hardware into the current AppKit context (`size` points, y up).
    var draw: (CGSize) -> Void = { _ in }
    var texts: [TextPart] = []
    /// Progress shown as segments that light up in order…
    var ladder: [CGRect] = []
    var ladderGlow = true
    /// …and/or as a pointer that travels along this track (left to right) through the song…
    var dialPointer: CGRect?
    /// The pointer is a dot (on a thin line) rather than a needle across the dial.
    var dialDot = false
    /// …and/or as two tape packs: the left one empties as the right one fills.
    var tape: TapePart?
    var rotors: [RotorPart] = []
    var needles: [CGRect] = []          // analog meter faces, left channel first
    var bars: [BarPart] = []
    var knobs: [(control: GearControl, rect: CGRect)] = []
    var lamp: CGRect?                   // lit while playing
    var meshes: [CGRect] = []           // a fluorescent display's dot mesh
    /// Where each control takes clicks (knobs include their grab margin).
    var controls: [GearControl: CGRect] = [:]
    /// Title and artist in capitals, like a fluorescent or LCD display (today's glass: as written).
    var uppercaseSong = true
    /// The display text's glow.
    var glow: (opacity: Float, radius: CGFloat) = (0.7, 3.5)
    /// Things that show but aren't controls, which mustn't overlap the controls (for the tests).
    var fixtures: [CGRect] = []
}

/// A line of text the gear keeps up to date.
struct TextPart {
    enum Role: Hashable { case indicator(Int), time, total, title, artist, album }
    var role: Role
    var frame: CGRect
    var size: CGFloat
    var weight: NSFont.Weight
    var alpha: CGFloat = 1
    var mono = false
    var align: CATextLayerAlignmentMode = .left
    /// Fixed text (the indicators: PLAY, PAUSE, REPEAT, SHUFFLE).
    var string: String?
}

/// Something round that turns: the jog wheel, a tuning knob, a cassette's reels.
struct RotorPart {
    var frame: CGRect
    var draw: (CGFloat) -> Void      // draws it, given its diameter
    var spin: Double?                // seconds per turn while playing (nil: only by hand)
    var isJog = false                // the control you turn to scrub
    var scrubRatio: CGFloat = 1      // how much it turns for each turn of your hand
}

/// A row or column of lit segments: a spectrum band, or one channel's level.
struct BarPart {
    enum Source: Equatable { case band(Int), channel(Int) }
    var source: Source
    var frame: CGRect
    var segments: Int
    var vertical = true
    var gap: CGFloat = 2
    var colors: [CGColor]            // one per segment, bottom (or left) first
    var glow: CGColor?
    /// Grows out from its middle both ways (a waveform), not up from the bottom.
    var centred = false
}

/// The tape on a cassette's two reels.
struct TapePart {
    var left: CGPoint, right: CGPoint   // the reels' centres
    var hub: CGFloat                    // radius of an empty reel
    var full: CGFloat                   // radius of a full one
    var color: CGColor
}

// MARK: - Shared layout helpers

@MainActor
enum GearLayout {
    /// A knob's click area reaches up to this far past the knob (easier to grab).
    static let knobGrab: CGFloat = 10

    /// The knobs' click areas: as generous as the space between them allows, never overlapping.
    static func grabAreas(_ knobs: [(control: GearControl, rect: CGRect)], within bounds: CGRect) -> [GearControl: CGRect] {
        var margin = knobGrab
        for (i, a) in knobs.enumerated() {
            for b in knobs[(i + 1)...] {
                let dx = max(b.rect.minX - a.rect.maxX, a.rect.minX - b.rect.maxX)
                let dy = max(b.rect.minY - a.rect.maxY, a.rect.minY - b.rect.maxY)
                let apart = max(dx, dy)
                margin = min(margin, max((apart - 1) / 2, 0))
            }
        }
        var areas: [GearControl: CGRect] = [:]
        for k in knobs { areas[k.control] = k.rect.insetBy(dx: -margin, dy: -margin).intersection(bounds) }
        return areas
    }

    /// The left and right level meters filling `area`, as `kind` (needles, LEDs or a spectrum): for
    /// a theme whose meters the Customise window has swapped for another kind.
    struct MeterBlock {
        var draw: () -> Void
        var needles: [CGRect] = []
        var bars: [BarPart] = []
        var fixtures: [CGRect] = []
    }

    static func meters(_ kind: StyleOptions.Meters, in area: CGRect, _ skin: Skin) -> MeterBlock {
        switch kind {
        case .era, .needles:
            let faces: [CGRect]
            if area.height >= 110 { // stacked
                let h = min((area.height - 12) / 2, area.width * 0.52)
                let top = area.midY + 6 + h
                faces = [CGRect(x: area.minX, y: top - h, width: area.width, height: h),
                         CGRect(x: area.minX, y: top - 2 * h - 12, width: area.width, height: h)]
            } else { // side by side
                let w = (area.width - 12) / 2
                faces = [CGRect(x: area.minX, y: area.minY, width: w, height: area.height),
                         CGRect(x: area.minX + w + 12, y: area.minY, width: w, height: area.height)]
            }
            return MeterBlock(draw: { for (i, f) in faces.enumerated() { Paint.vuFace(f, channel: i == 0 ? "L" : "R", skin) } },
                              needles: faces, fixtures: faces)
        case .leds:
            let glass = CGRect(x: area.minX, y: area.midY - min(area.height, 70) / 2, width: area.width, height: min(area.height, 70))
            let rows = [CGRect(x: glass.minX + 26, y: glass.maxY - 22, width: glass.width - 38, height: 9),
                        CGRect(x: glass.minX + 26, y: glass.minY + 13, width: glass.width - 38, height: 9)]
            let colors = ledColors(20, skin)
            return MeterBlock(draw: { Paint.glass(glass, skin, corner: 4); Paint.levelScale(rows, skin) },
                              bars: rows.enumerated().map { BarPart(source: .channel($0.offset), frame: $0.element, segments: 20, vertical: false, colors: colors) },
                              fixtures: [glass])
        case .spectrum:
            let glass = area
            let labels = CGRect(x: glass.minX + 12, y: glass.minY + 7, width: glass.width - 24, height: 10)
            let r = CGRect(x: glass.minX + 12, y: labels.maxY + 5, width: glass.width - 24, height: max(glass.height - 30, 10))
            let count = AudioLevels.bandCount, gap: CGFloat = 5
            let w = (r.width - CGFloat(count - 1) * gap) / CGFloat(count)
            let segments = max(Int(r.height / 8), 4)
            let colors = ledColors(segments, skin)
            return MeterBlock(draw: { Paint.glass(glass, skin, corner: 4); Paint.bandLabels(labels, skin.colors.display.alpha(0.45).ns) },
                              bars: (0..<count).map { i in
                                  BarPart(source: .band(i), frame: CGRect(x: r.minX + CGFloat(i) * (w + gap), y: r.minY, width: w, height: r.height),
                                          segments: segments, gap: 2, colors: colors, glow: skin.colors.display.cg)
                              },
                              fixtures: [glass])
        }
    }

    /// Segment colours, bottom (or left) first: the display colour, then the accent, then the peak.
    static func ledColors(_ n: Int, _ skin: Skin) -> [CGColor] {
        (0..<n).map { i -> CGColor in
            let f = Double(i) / Double(n)
            return (f >= 0.85 ? skin.colors.peak : f >= 0.7 ? skin.colors.accent : skin.colors.display).cg
        }
    }

    /// The faceplate inside the wooden case (all of it when there's no case).
    static func plate(_ size: CGSize, _ skin: Skin) -> CGRect {
        let c = CGFloat(skin.layout.caseWidth)
        return CGRect(origin: .zero, size: size).insetBy(dx: c, dy: c * 0.75)
    }

    /// The column the controls sit in, centred on the faceplate.
    static func column(_ size: CGSize, _ skin: Skin) -> CGRect {
        let p = plate(size, skin)
        let w = max(min(p.width - 32, CGFloat(skin.layout.columnWidth)), 40)
        return CGRect(x: p.midX - w / 2, y: p.minY + 18, width: w, height: p.height - 36)
    }

    /// `n` buttons side by side across `row`.
    static func buttons(_ n: Int, in row: CGRect, gap: CGFloat) -> [CGRect] {
        let w = (row.width - CGFloat(n - 1) * gap) / CGFloat(n)
        return (0..<n).map { CGRect(x: row.minX + CGFloat($0) * (w + gap), y: row.minY, width: w, height: row.height) }
    }

    /// The four indicator words in a row from `origin`, no wider than `width` (smaller and closer
    /// together on a narrow panel), as text parts, and the REPEAT and SHUFFLE click areas.
    static func indicators(at origin: CGPoint, width: CGFloat, height: CGFloat = 11, skin: Skin,
                           names: [String] = ["PLAY", "PAUSE", "REPEAT", "SHUFFLE"], offset: CGPoint) -> ([TextPart], [GearControl: CGRect]) {
        let fits: [(size: CGFloat, gap: CGFloat)] = [(9, 10), (8, 7), (7, 5), (6, 4)]
        func widths(_ size: CGFloat) -> [CGFloat] { names.map { Paint.width($0, Paint.displayFont(skin, size, .bold, mono: true)) + 2 } }
        let (size, gap) = fits.first { f in widths(f.size).reduce(0, +) + f.gap * CGFloat(names.count - 1) <= width } ?? fits.last!
        var x = origin.x
        var parts: [TextPart] = []
        var controls: [GearControl: CGRect] = [:]
        // The click areas reach a little past the words, but not into each other.
        let reach = min(4, gap / 2 - 0.5)
        for (i, (name, w)) in zip(names, widths(size)).enumerated() {
            let frame = CGRect(x: x, y: origin.y, width: w, height: height)
            parts.append(TextPart(role: .indicator(i), frame: frame, size: size, weight: .bold, mono: true, string: name))
            if i == 2 { controls[.repeatMode] = frame.insetBy(dx: -reach, dy: -5).offsetBy(dx: offset.x, dy: offset.y) }
            if i == 3 { controls[.shuffle] = frame.insetBy(dx: -reach, dy: -5).offsetBy(dx: offset.x, dy: offset.y) }
            x += w + gap
        }
        return (parts, controls)
    }
}

// MARK: - Drawing

extension SkinColor {
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cg: CGColor { ns.cgColor }
    /// Perceived brightness, 0…1.
    var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
}

/// The drawing shared by every era: faceplates, glass, knobs, buttons, meters, lettering.
/// All of it draws into the current AppKit context, y up.
@MainActor
enum Paint {
    static let needleRest: CGFloat = 0.82              // radians, far left (at rest)
    static func needleAngle(_ level: Double) -> CGFloat { CGFloat(0.72 - level * 1.44) } // 0 = −20 dB … 1 = +3 dB
    static let green = NSColor(red: 0.3, green: 1, blue: 0.45, alpha: 1)

    /// The fine dot mesh in front of a fluorescent display.
    static let meshColor: CGColor = {
        let tile = NSImage(size: NSSize(width: 3, height: 3), flipped: false) { _ in
            NSColor(white: 0, alpha: 0.35).setFill()
            NSRect(x: 0, y: 0, width: 3, height: 1).fill()
            NSRect(x: 0, y: 0, width: 1, height: 3).fill()
            return true
        }
        return NSColor(patternImage: tile).cgColor
    }()

    static func image(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: Fonts

    static func displayFont(_ skin: Skin, _ size: CGFloat, _ weight: NSFont.Weight, mono: Bool) -> NSFont {
        if let name = skin.displayFont, let font = NSFont(name: name, size: size) {
            guard mono else { return font }
            // Digits of equal width, so the time doesn't jiggle as it counts.
            let digits = font.fontDescriptor.addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
            return NSFont(descriptor: digits, size: size) ?? font
        }
        return mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }

    static func brandFont(_ skin: Skin, _ size: CGFloat) -> NSFont {
        skin.brandFont.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size, weight: .heavy)
    }

    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width) + 2
    }

    // MARK: Faceplates

    /// The panel: a wooden case if the skin has one, then the faceplate in its material, bevelled,
    /// with screws in the corners.
    static func faceplate(_ size: CGSize, _ skin: Skin, screws: Bool = true) {
        let full = NSRect(origin: .zero, size: size)
        let corner = CGFloat(skin.layout.corner)
        if skin.layout.caseWidth > 0 { cabinet(full, skin) }
        let r = GearLayout.plate(size, skin)
        let plateCorner = skin.layout.caseWidth > 0 ? min(corner, 3) : corner
        let plate = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: plateCorner, yRadius: plateCorner)
        NSGradient(colors: skin.colors.plate.map(\.ns), atLocations: [0, 0.5, 1], colorSpace: .sRGB)?.draw(in: plate, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        plate.addClip()
        texture(r, skin)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.18).setStroke()
        plate.lineWidth = 1
        plate.stroke()
        for p in [CGPoint(x: r.minX + 12, y: r.minY + 12), CGPoint(x: r.maxX - 12, y: r.minY + 12),
                  CGPoint(x: r.minX + 12, y: r.maxY - 12), CGPoint(x: r.maxX - 12, y: r.maxY - 12)] where screws {
            screw(p)
        }
    }

    private static func texture(_ r: CGRect, _ skin: Skin) {
        let g = skin.grain
        var rng = SystemRandomNumberGenerator()
        switch skin.material {
        case .brushed, .chrome:
            for y in stride(from: r.minY, to: r.maxY, by: 1) { // brushing
                NSColor(white: Bool.random(using: &rng) ? 1 : 0, alpha: Double.random(in: (g * 0.22)...max(g, g * 0.22 + 0.001), using: &rng)).setFill()
                NSRect(x: r.minX, y: y, width: r.width, height: 1).fill()
            }
            if skin.material == .chrome { // a polished band where the light catches it
                NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 0.38), NSColor(white: 1, alpha: 0),
                                    NSColor(white: 0, alpha: 0.12), NSColor(white: 1, alpha: 0)],
                           atLocations: [0, 0.18, 0.34, 0.62, 1], colorSpace: .sRGB)?.draw(in: r, angle: -90)
            }
        case .plastic:
            for _ in 0..<Int(r.width * r.height / 6) { // speckle
                NSColor(white: Bool.random(using: &rng) ? 1 : 0, alpha: Double.random(in: 0...max(g, 0.001), using: &rng)).setFill()
                NSRect(x: r.minX + .random(in: 0..<r.width, using: &rng), y: r.minY + .random(in: 0..<r.height, using: &rng), width: 1, height: 1).fill()
            }
            NSGradient(colors: [NSColor(white: 1, alpha: 0.06), NSColor(white: 1, alpha: 0)])?.draw(in: r, angle: -90)
        case .matte:
            break
        }
    }

    /// A varnished walnut case: grain running down the panel, darker at the edges.
    private static func cabinet(_ r: CGRect, _ skin: Skin) {
        let wood = skin.colors.cabinet
        let shape = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: CGFloat(skin.layout.corner) + 4,
                                 yRadius: CGFloat(skin.layout.corner) + 4)
        wood.ns.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        var rng = SeededRandom(seed: 1975)
        for _ in 0..<Int(r.width / 2.2) {
            let x0 = CGFloat.random(in: r.minX...r.maxX, using: &rng)
            let amp = CGFloat.random(in: 1...5, using: &rng), freq = CGFloat.random(in: 0.006...0.02, using: &rng)
            let phase = CGFloat.random(in: 0...6, using: &rng)
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x0, y: r.minY))
            for y in stride(from: r.minY, through: r.maxY, by: 6) {
                line.line(to: CGPoint(x: x0 + sin(y * freq + phase) * amp + sin(y * freq * 3.1) * amp * 0.3, y: y))
            }
            line.lineWidth = .random(in: 0.5...2.2, using: &rng)
            let dark = Bool.random(using: &rng)
            (dark ? NSColor(white: 0, alpha: .random(in: 0.08...0.3, using: &rng))
                  : wood.mixed(SkinColor(1, 0.85, 0.6), 0.35).ns.withAlphaComponent(.random(in: 0.06...0.2, using: &rng))).setStroke()
            line.stroke()
        }
        // Varnish: a soft sheen down the middle, shade at the sides.
        NSGradient(colors: [NSColor(white: 0, alpha: 0.35), NSColor(white: 1, alpha: 0.08), NSColor(white: 0, alpha: 0.35)],
                   atLocations: [0, 0.5, 1], colorSpace: .sRGB)?.draw(in: r, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0, alpha: 0.5).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        // The faceplate sits a little inside the wood.
        let inner = GearLayout.plate(r.size, skin)
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: inner.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4).fill()
    }

    static func screw(_ p: CGPoint) {
        let screw = NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
        NSGradient(starting: NSColor(white: 0.7, alpha: 1), ending: NSColor(white: 0.3, alpha: 1))?
            .draw(in: NSBezierPath(ovalIn: screw), angle: -60)
        NSColor(white: 0.12, alpha: 0.9).setStroke()
        let slot = NSBezierPath()
        slot.move(to: NSPoint(x: p.x - 3, y: p.y + 1.5)); slot.line(to: NSPoint(x: p.x + 3, y: p.y - 1.5))
        slot.lineWidth = 1.2
        slot.stroke()
    }

    static func header(_ r: CGRect, brand: String, model: String, _ skin: Skin) {
        let brandText = NSAttributedString(string: brand, attributes: [
            .font: brandFont(skin, 15), .kern: 4, .foregroundColor: skin.colors.label.mixed(SkinColor(1, 1, 1), 0.07).ns])
        brandText.draw(at: NSPoint(x: r.minX, y: r.maxY - 18))
        NSAttributedString(string: model, attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold), .kern: 1.6, .foregroundColor: skin.colors.label.alpha(0.68).ns])
            .draw(at: NSPoint(x: r.minX, y: r.maxY - 32))
        NSColor(white: 1, alpha: 0.12).setFill()
        NSRect(x: r.minX, y: r.minY + 2, width: r.width, height: 1).fill()
        NSColor(white: 0, alpha: 0.4).setFill()
        NSRect(x: r.minX, y: r.minY + 1, width: r.width, height: 1).fill()
    }

    static func glass(_ r: CGRect, _ skin: Skin, corner: CGFloat = 8) {
        let path = NSBezierPath(roundedRect: r, xRadius: corner, yRadius: corner)
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: corner + 2, yRadius: corner + 2).fill() // bezel
        NSGradient(colors: skin.colors.glass.map(\.ns))?.draw(in: path, angle: -90)
        NSColor(white: 1, alpha: 0.08).setStroke()
        path.stroke()
    }

    static func label(_ text: String, centeredAt p: CGPoint, _ skin: Skin, size: CGFloat = 7.5, alpha: CGFloat = 0.62) {
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold), .kern: 1.2, .foregroundColor: skin.colors.label.alpha(alpha).ns])
        let w = s.size()
        s.draw(at: NSPoint(x: p.x - w.width / 2, y: p.y - w.height / 2))
    }

    /// Light buttons and knobs get dark marks; dark ones light marks.
    static func markColor(on surface: SkinColor) -> NSColor {
        surface.luminance > 0.55 ? NSColor(white: 0.12, alpha: 0.85) : NSColor(white: 0.9, alpha: 0.85)
    }

    static func button(_ rect: CGRect, symbol name: String, _ skin: Skin, corner: CGFloat = 5) {
        let b = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        NSGradient(colors: skin.colors.button.map(\.ns))?.draw(in: b, angle: -90)
        NSColor(white: 0, alpha: 0.7).setStroke(); b.stroke()
        NSColor(white: 1, alpha: 0.18).setFill()
        NSRect(x: rect.minX + 3, y: rect.maxY - 2, width: rect.width - 6, height: 1).fill()
        symbol(name, in: rect, color: markColor(on: skin.colors.button[0].mixed(skin.colors.button[1], 0.5)))
    }

    static func symbol(_ name: String, in rect: CGRect, color: NSColor, size: CGFloat = 11) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = image.size
        image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }

    /// The colour of a knob's live pointer.
    static func pointerColor(_ skin: Skin) -> CGColor {
        skin.colors.knob[0].luminance > 0.75 ? NSColor(white: 0.1, alpha: 0.9).cgColor : NSColor(white: 0.95, alpha: 0.9).cgColor
    }

    static func knob(_ r: CGRect, label name: String, _ skin: Skin, pointer drawPointer: Bool = true) {
        let (light, dark) = (skin.colors.knob[0], skin.colors.knob[1])
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -4).offsetBy(dx: 0, dy: -1)).fill() // shadow
        NSGradient(colors: [light.ns, dark.ns])?.draw(in: NSBezierPath(ovalIn: r), angle: -70)
        NSGradient(colors: [dark.mixed(light, 0.3).ns, dark.mixed(light, 0.68).ns])?
            .draw(in: NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.14, dy: r.width * 0.14)), angle: -70)
        let c = CGPoint(x: r.midX, y: r.midY), a = CGFloat.pi * 0.25
        if drawPointer { // knobs that set something (VOLUME, BASS, TREBLE) get a live pointer layer instead
            let pointer = NSBezierPath()
            pointer.move(to: CGPoint(x: c.x - sin(a) * r.width * 0.12, y: c.y + cos(a) * r.width * 0.12))
            pointer.line(to: CGPoint(x: c.x - sin(a) * r.width * 0.36, y: c.y + cos(a) * r.width * 0.36))
            NSColor(cgColor: pointerColor(skin))?.setStroke(); pointer.lineWidth = 2; pointer.stroke()
        }
        for i in 0...10 { // scale dots
            let t = -0.75 * CGFloat.pi + CGFloat(i) * 0.15 * CGFloat.pi
            let p = CGPoint(x: c.x - sin(t) * (r.width / 2 + 6), y: c.y + cos(t) * (r.width / 2 + 6))
            skin.colors.label.mixed(SkinColor(0.5, 0.5, 0.5), 0.1).alpha(0.5).ns.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)).fill()
        }
        label(name, centeredAt: CGPoint(x: r.midX, y: r.minY - 12), skin)
    }

    static func lamp(_ p: CGPoint, _ color: NSColor) {
        color.withAlphaComponent(0.3).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
    }

    /// The power switch with its lamp, and the headphone jack, along the bottom of a column.
    static func powerRow(_ column: CGRect, _ skin: Skin) {
        let powerY = column.minY + 22
        let power = NSRect(x: column.minX, y: powerY - 10, width: 44, height: 20)
        NSGradient(colors: [skin.colors.button[0].mixed(SkinColor(0.4, 0.4, 0.4), 0.5).ns, skin.colors.button[1].mixed(SkinColor(0.18, 0.18, 0.18), 0.5).ns])?
            .draw(in: NSBezierPath(roundedRect: power, xRadius: 4, yRadius: 4), angle: -90)
        label("POWER", centeredAt: CGPoint(x: power.midX, y: power.maxY + 9), skin)
        lamp(CGPoint(x: power.maxX + 12, y: power.midY), green)
        let jack = CGPoint(x: column.maxX - 14, y: powerY)
        NSColor(white: 0.55, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: jack.x - 9, y: jack.y - 9, width: 18, height: 18)).fill()
        NSColor(white: 0.02, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: jack.x - 4.5, y: jack.y - 4.5, width: 9, height: 9)).fill()
        label("PHONES", centeredAt: CGPoint(x: jack.x, y: jack.y + 17), skin)
    }

    /// The VU scale: each printed mark (dB) and where it sits across the meter (0…1). The needle
    /// maths and the printed face both read this, so they can't drift apart.
    nonisolated static let vuMarks: [(dB: Double, fraction: Double)] = [
        (-20, 0), (-10, 0.28), (-7, 0.42), (-5, 0.53), (-3, 0.64), (-2, 0.7),
        (-1, 0.76), (0, 0.82), (1, 0.88), (2, 0.94), (3, 1)]
    /// Where 0 VU sits; above it is the red zone.
    nonisolated static let zeroVU = 0.82

    /// A backlit analog VU meter face (the needle is a separate layer).
    static func vuFace(_ r: CGRect, channel: String, _ skin: Skin) {
        NSColor(white: 0, alpha: 0.65).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8).fill()
        let face = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSGradient(colors: skin.colors.meter.map(\.ns))?.draw(in: face, relativeCenterPosition: NSPoint(x: 0, y: -0.2))
        NSGraphicsContext.saveGraphicsState()
        face.addClip()
        let pivot = CGPoint(x: r.midX, y: r.minY - r.height * 0.28)
        let radius = r.height * 0.98
        let ink = skin.colors.ink.alpha(0.9).ns
        let red = skin.colors.peak.mixed(SkinColor(0, 0, 0), 0.1).ns
        // Scale arc, the red zone above 0 dB, tick marks and numbers.
        func point(_ angle: CGFloat, _ rad: CGFloat) -> CGPoint {
            CGPoint(x: pivot.x - sin(angle) * rad, y: pivot.y + cos(angle) * rad)
        }
        let marks = vuMarks.map { ($0.fraction, String(Int(abs($0.dB)))) } // printed without signs
        let arc = NSBezierPath()
        arc.appendArc(withCenter: pivot, radius: radius, startAngle: 90 + 0.72 * 180 / .pi, endAngle: 90 - 0.72 * 180 / .pi, clockwise: true)
        ink.setStroke(); arc.lineWidth = 1.2; arc.stroke()
        let zone = NSBezierPath()
        zone.appendArc(withCenter: pivot, radius: radius + 2.5, startAngle: 90 + needleAngle(zeroVU) * 180 / .pi,
                       endAngle: 90 + needleAngle(1) * 180 / .pi, clockwise: true)
        skin.colors.peak.alpha(0.9).ns.setStroke(); zone.lineWidth = 4.5; zone.stroke()
        for (level, text) in marks {
            let a = needleAngle(level)
            let t = NSBezierPath()
            t.move(to: point(a, radius)); t.line(to: point(a, radius + 7))
            (level > zeroVU ? red : ink).setStroke()
            t.lineWidth = 1.2; t.stroke()
            let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .semibold),
                                                                  .foregroundColor: level > zeroVU ? red : ink])
            let p = point(a, radius + 14), w = s.size()
            s.draw(at: NSPoint(x: p.x - w.width / 2, y: p.y - w.height / 2))
        }
        let vu = NSAttributedString(string: "VU", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: ink])
        vu.draw(at: NSPoint(x: r.midX - vu.size().width / 2, y: r.minY + r.height * 0.2))
        let ch = NSAttributedString(string: channel, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: ink])
        ch.draw(at: NSPoint(x: r.minX + 10, y: r.minY + 8))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A knurled wheel with a brushed face and a finger dimple (so you can see it turn).
    static func wheel(diameter d: CGFloat, _ skin: Skin) {
        let (light, dark) = (skin.colors.knob[0], skin.colors.knob[1])
        let r = NSRect(x: 0, y: 0, width: d, height: d)
        NSGradient(colors: [dark.mixed(light, 0.676).ns, dark.mixed(SkinColor(0, 0, 0), 0.36).ns])?.draw(in: NSBezierPath(ovalIn: r), angle: -60)
        let c = CGPoint(x: d / 2, y: d / 2)
        for i in 0..<90 { // knurling
            let a = CGFloat(i) / 90 * 2 * .pi
            let k = NSBezierPath()
            k.move(to: CGPoint(x: c.x + cos(a) * d * 0.44, y: c.y + sin(a) * d * 0.44))
            k.line(to: CGPoint(x: c.x + cos(a) * d * 0.5, y: c.y + sin(a) * d * 0.5))
            NSColor(white: i % 2 == 0 ? 0.08 : 0.6, alpha: 0.5).setStroke()
            k.lineWidth = 1; k.stroke()
        }
        let face = r.insetBy(dx: d * 0.08, dy: d * 0.08)
        NSGradient(colors: [dark.mixed(light, 0.08).ns, dark.mixed(light, 0.51).ns, dark.mixed(light, 0.03).ns],
                   atLocations: [0, 0.5, 1], colorSpace: .sRGB)?.draw(in: NSBezierPath(ovalIn: face), angle: -45)
        for ring in stride(from: d * 0.08, to: d * 0.42, by: 2.5) { // concentric brushing
            NSColor(white: 1, alpha: 0.035).setStroke()
            NSBezierPath(ovalIn: NSRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)).stroke()
        }
        let dimple = NSRect(x: c.x + d * 0.2 - d * 0.07, y: c.y + d * 0.12 - d * 0.07, width: d * 0.14, height: d * 0.14)
        NSGradient(colors: [dark.mixed(SkinColor(0, 0, 0), 0.52).ns, dark.mixed(light, 0.4).ns])?.draw(in: NSBezierPath(ovalIn: dimple), angle: -60)
    }

    /// The dB marks under each LED row and the L / R labels.
    static func levelScale(_ rows: [CGRect], _ skin: Skin) {
        let ink = skin.colors.display.alpha(0.55).ns
        for (row, ch) in zip(rows, ["L", "R"]) {
            NSAttributedString(string: ch, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .heavy), .foregroundColor: ink])
                .draw(at: NSPoint(x: row.minX - 16, y: row.midY - 6))
        }
        let marks: [(String, Double)] = [("-20", 0), ("-10", 0.28), ("-5", 0.53), ("-3", 0.64), ("0", 0.82), ("+3", 1)]
        let row = rows[0]
        let y = (rows[0].minY + rows[1].maxY) / 2 - 5
        for (text, f) in marks {
            let s = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .medium), .foregroundColor: ink])
            let x = row.minX + row.width * CGFloat(f)
            s.draw(at: NSPoint(x: min(max(x - s.size().width / 2, row.minX), row.maxX - s.size().width), y: y))
        }
    }

    /// Spectrum band labels along the bottom of a display.
    static func bandLabels(_ r: CGRect, _ color: NSColor) {
        let bands = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
        let step = r.width / CGFloat(bands.count)
        for (i, b) in bands.enumerated() {
            let s = NSAttributedString(string: b, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .medium),
                                                              .foregroundColor: color])
            s.draw(at: NSPoint(x: r.minX + step * (CGFloat(i) + 0.5) - s.size().width / 2, y: r.minY))
        }
    }
}

/// Repeatable random numbers (the wood grain looks the same every time it's drawn).
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
