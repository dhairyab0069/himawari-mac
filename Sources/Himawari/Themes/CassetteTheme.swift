import AppKit
import HimawariKit

/// The 1980s cassette deck: on the left the tape deck (a fluorescent display, the door with a
/// cassette whose reels turn and whose tape winds from one reel to the other through the song,
/// piano keys, a search dial that scrubs), on the right a graphic equalizer (LED level meters,
/// a segment spectrum, sliders, knobs). The big cassette in the middle is the music scene's.
struct CassetteTheme: GearTheme {
    let skin: Skin

    func left(size: CGSize) -> PanelFace {
        let column = GearLayout.column(size, skin)
        let colW = column.width
        let header = CGRect(x: column.minX, y: column.maxY - 40, width: colW, height: 40)
        let display = CGRect(x: column.minX, y: header.minY - 12 - 132, width: colW, height: 132)
        // Below the display: the door, the keys, the search dial and the power row share what's left.
        let avail = display.minY - column.minY - 166
        var jogD = min(max(avail * 0.4, 56), 120, colW - 80)
        var doorH = min(avail - jogD, 210)
        if doorH < 50 { doorH = 0; jogD = max(min(avail, 120, colW - 80), 40) }
        let door = CGRect(x: column.minX, y: display.minY - 14 - doorH, width: colW, height: doorH)
        let row = CGRect(x: column.minX, y: (doorH > 0 ? door.minY : display.minY) - 14 - 36, width: colW, height: 36)
        let keys = GearLayout.buttons(5, in: row, gap: CGFloat(skin.layout.gap))
        let lamp = CGRect(x: keys[1].midX - 3, y: keys[1].maxY + 4, width: 6, height: 6)
        let jogSpace = row.minY - 18 - (column.minY + 60)
        let jog = CGRect(x: column.midX - jogD / 2, y: column.minY + 60 + 14 + max((jogSpace - 14 - jogD) / 2, 0), width: jogD, height: jogD)

        // The cassette behind the door.
        let tape = Self.cassetteRect(in: door.insetBy(dx: 14, dy: 10))
        let reelY = tape.minY + tape.height * 0.46
        let reels = [CGPoint(x: tape.midX - tape.width * 0.22, y: reelY), CGPoint(x: tape.midX + tape.width * 0.22, y: reelY)]
        let hub = tape.height * 0.1, full = min(tape.height * 0.24, tape.width * 0.2)

        var face = PanelFace()
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin)
            Paint.header(header, brand: skin.brand, model: skin.leftModel, skin)
            Paint.glass(display, skin, corner: 4)
            if doorH > 0 {
                Self.door(door, skin)
                Self.cassette(tape, reels: reels, full: full, skin, small: true)
            }
            if doorH > 0 { Self.window(reels: reels, full: full) }
            for (rect, name) in zip(keys, ["backward.end.fill", "playpause.fill", "forward.end.fill", "stop.fill", "eject.fill"]) {
                Self.key(rect, symbol: name, skin)
            }
            Paint.powerRow(column, skin)
            NSColor(white: 0, alpha: 0.5).setFill()
            NSBezierPath(ovalIn: jog.insetBy(dx: -4, dy: -4)).fill()
            Paint.label("SEARCH", centeredAt: CGPoint(x: jog.midX, y: jog.minY - 12), skin)
        }
        let inner = display.insetBy(dx: 12, dy: 10)
        let (indicators, toggles) = GearLayout.indicators(at: CGPoint(x: inner.minX, y: inner.maxY - 11), width: inner.width, skin: skin, offset: .zero)
        face.texts = indicators + [
            TextPart(role: .time, frame: CGRect(x: inner.minX - 1, y: inner.maxY - 48, width: inner.width * 0.6, height: 34),
                     size: 28, weight: .regular, mono: true),
            TextPart(role: .total, frame: CGRect(x: inner.minX + inner.width * 0.6, y: inner.maxY - 42, width: inner.width * 0.4, height: 15),
                     size: 12, weight: .medium, alpha: 0.6, mono: true, align: .right),
            TextPart(role: .title, frame: CGRect(x: inner.minX, y: inner.maxY - 82, width: inner.width, height: 18), size: 14, weight: .bold),
            TextPart(role: .artist, frame: CGRect(x: inner.minX, y: inner.maxY - 97, width: inner.width, height: 15),
                     size: 11, weight: .semibold, alpha: 0.8),
            TextPart(role: .album, frame: CGRect(x: inner.minX, y: inner.maxY - 111, width: inner.width, height: 14),
                     size: 10, weight: .regular, alpha: 0.5),
        ]
        let segments = 24, gap: CGFloat = 2
        let segW = (inner.width - CGFloat(segments - 1) * gap) / CGFloat(segments)
        face.ladder = (0..<segments).map { CGRect(x: inner.minX + CGFloat($0) * (segW + gap), y: inner.maxY - 59, width: segW, height: 5) }
        face.meshes = [display.insetBy(dx: 3, dy: 3)]
        face.lamp = lamp
        if doorH > 0 {
            face.tape = TapePart(left: reels[0], right: reels[1], hub: hub, full: full,
                                 color: NSColor(red: 0.3, green: 0.17, blue: 0.1, alpha: 1).cgColor)
            face.rotors = reels.map { c in
                let d = hub * 2.2
                return RotorPart(frame: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d), draw: { Self.hub(diameter: $0) },
                                 spin: 2.6, scrubRatio: 3)
            }
        }
        face.rotors.append(RotorPart(frame: jog, draw: { Paint.wheel(diameter: $0, skin) }, spin: nil, isJog: true))
        face.controls = toggles
        for (control, rect) in zip([GearControl.previous, .playPause, .next, .stop, .eject], keys) { face.controls[control] = rect }
        face.controls[.progress] = CGRect(x: inner.minX, y: inner.maxY - 66, width: inner.width, height: 18)
        face.controls[.jog] = jog
        if doorH > 0 { face.fixtures = [door] }
        return face
    }

    func right(size: CGSize) -> PanelFace {
        let column = GearLayout.column(size, skin)
        let colW = column.width
        let header = CGRect(x: column.minX, y: column.maxY - 40, width: colW, height: 40)
        let levels = CGRect(x: column.minX, y: header.minY - 14 - 70, width: colW, height: 70)
        let small = min(40, colW * 0.24), big = min(56, colW * 0.34) // smaller on a narrow panel
        let y = column.minY + 22
        let floor = y + big + 20
        let rest = levels.minY - 16 - floor
        var slidersH: CGFloat = 0
        if rest >= 90 + 14 + 70 { slidersH = min(rest - 90 - 14, 110) }
        let spectrumH = max(min(rest - (slidersH > 0 ? slidersH + 14 : 0), 200), 60)
        let spectrumGlass = CGRect(x: column.minX, y: levels.minY - 16 - spectrumH, width: colW, height: spectrumH)
        let sliders = CGRect(x: column.minX, y: spectrumGlass.minY - 14 - slidersH, width: colW, height: slidersH)
        let labels = CGRect(x: spectrumGlass.minX + 12, y: spectrumGlass.minY + 7, width: colW - 24, height: 10)
        let spectrum = CGRect(x: spectrumGlass.minX + 12, y: labels.maxY + 5, width: colW - 24, height: spectrumH - 30)
        let knobs: [(control: GearControl, rect: CGRect)] = [
            (.bass, CGRect(x: column.minX + colW * 0.18 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
            (.treble, CGRect(x: column.minX + colW * 0.45 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
            (.volume, CGRect(x: column.minX + colW * 0.78 - big / 2, y: y, width: big, height: big))]
        // The level meters: two rows of LEDs, L above R.
        let barX = levels.minX + 26, barW = levels.width - 38
        let rows = [CGRect(x: barX, y: levels.maxY - 22, width: barW, height: 9), CGRect(x: barX, y: levels.minY + 13, width: barW, height: 9)]

        var face = PanelFace()
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin)
            Paint.header(header, brand: skin.brand, model: skin.rightModel, skin)
            Paint.glass(levels, skin, corner: 4)
            Self.levelScale(rows, skin)
            Paint.glass(spectrumGlass, skin, corner: 4)
            Paint.bandLabels(labels, skin.colors.display.alpha(0.45).ns)
            if slidersH > 0 { Self.sliders(sliders, count: 10, inset: 12, skin) }
            for k in knobs { Paint.knob(k.rect, label: k.control.knobName ?? "", skin, pointer: false) }
        }
        let ledColors = { (n: Int) in (0..<n).map { i -> CGColor in
            let f = Double(i) / Double(n)
            return (f >= 0.85 ? skin.colors.peak : f >= 0.7 ? skin.colors.accent : skin.colors.display).cg
        } }
        face.bars = rows.enumerated().map { i, r in
            BarPart(source: .channel(i), frame: r, segments: 20, vertical: false, gap: 2, colors: ledColors(20), glow: nil)
        }
        let count = 10, segments = 12, colGap: CGFloat = 6
        let barW2 = (spectrum.width - CGFloat(count - 1) * colGap) / CGFloat(count)
        face.bars += (0..<count).map { i in
            BarPart(source: .band(i), frame: CGRect(x: spectrum.minX + CGFloat(i) * (barW2 + colGap), y: spectrum.minY, width: barW2, height: spectrum.height),
                    segments: segments, gap: 3, colors: ledColors(segments), glow: nil)
        }
        face.knobs = knobs
        face.controls = GearLayout.grabAreas(knobs, within: CGRect(origin: .zero, size: size))
        face.fixtures = [levels, spectrumGlass] + (slidersH > 0 ? [sliders] : [])
        return face
    }

    // MARK: Drawing (shared with the big cassette in the music scene)

    /// The largest cassette (100 × 63, the real thing's shape) that fits in `r`, centred.
    static func cassetteRect(in r: CGRect) -> CGRect {
        let aspect: CGFloat = 100 / 63
        let w = min(r.width, r.height * aspect), h = w / aspect
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    /// The deck's door: smoked plastic with a chrome rim.
    private static func door(_ r: CGRect, _ skin: Skin) {
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6).fill()
        NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.05, alpha: 1)])?
            .draw(in: NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4), angle: -90)
        NSColor(white: 1, alpha: 0.25).setStroke()
        NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
    }

    /// A cassette: the shell, its label strip, the window over the reels, screws. The tape and the
    /// reels' hubs are separate layers (they move). `small`: drawn behind the deck's smoked door.
    static func cassette(_ r: CGRect, reels: [CGPoint], full: CGFloat, _ skin: Skin, small: Bool) {
        let corner = r.height * 0.06
        let shell = NSBezierPath(roundedRect: r, xRadius: corner, yRadius: corner)
        let body = skin.colors.media
        NSGradient(colors: [body.mixed(SkinColor(1, 1, 1, body.a), 0.12).ns, body.ns, body.mixed(SkinColor(0, 0, 0, body.a), 0.25).ns],
                   atLocations: [0, 0.5, 1], colorSpace: .sRGB)?.draw(in: shell, angle: -90)
        NSColor(white: 1, alpha: 0.18).setStroke(); shell.lineWidth = 1; shell.stroke()
        // The label strip, with the cover on it (or the skin's brand).
        let strip = labelStrip(r)
        let labelPath = NSBezierPath(roundedRect: strip, xRadius: corner * 0.6, yRadius: corner * 0.6)
        NSColor(white: 0.94, alpha: small ? 0.85 : 1).setFill(); labelPath.fill()
        NSColor(red: 0.85, green: 0.3, blue: 0.2, alpha: 0.9).setFill() // a printed stripe (the cover goes below it)
        NSRect(x: strip.minX, y: labelArea(r).maxY + 1, width: strip.width, height: max(r.height * 0.012, 1)).fill()
        // The tape running across the bottom, past the head, and the shell's head opening.
        let mouth = CGRect(x: r.midX - r.width * 0.3, y: r.minY, width: r.width * 0.6, height: r.height * 0.13)
        let trapezoid = NSBezierPath()
        trapezoid.move(to: CGPoint(x: mouth.minX, y: mouth.minY)); trapezoid.line(to: CGPoint(x: mouth.minX + mouth.width * 0.1, y: mouth.maxY))
        trapezoid.line(to: CGPoint(x: mouth.maxX - mouth.width * 0.1, y: mouth.maxY)); trapezoid.line(to: CGPoint(x: mouth.maxX, y: mouth.minY))
        trapezoid.close()
        body.mixed(SkinColor(0, 0, 0, 1), 0.35).ns.setFill(); trapezoid.fill()
        NSColor(red: 0.3, green: 0.17, blue: 0.1, alpha: 1).setFill()
        NSRect(x: mouth.minX + 2, y: mouth.minY + 1.5, width: mouth.width - 4, height: max(r.height * 0.012, 1)).fill()
        for x in [mouth.minX + mouth.width * 0.22, mouth.maxX - mouth.width * 0.22] { // the guide holes
            NSColor(white: 0, alpha: 0.7).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - r.height * 0.025, y: mouth.midY - r.height * 0.025, width: r.height * 0.05, height: r.height * 0.05)).fill()
        }
        if !small {
            for p in [CGPoint(x: r.minX + r.width * 0.04, y: r.maxY - r.height * 0.06), CGPoint(x: r.maxX - r.width * 0.04, y: r.maxY - r.height * 0.06),
                      CGPoint(x: r.minX + r.width * 0.04, y: r.minY + r.height * 0.06), CGPoint(x: r.maxX - r.width * 0.04, y: r.minY + r.height * 0.06),
                      CGPoint(x: r.midX, y: r.minY + r.height * 0.2)] {
                Paint.screw(p)
            }
            let side = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: r.height * 0.09, weight: .heavy),
                                                                     .foregroundColor: NSColor(white: 0.1, alpha: 0.85)])
            side.draw(at: NSPoint(x: strip.minX + r.width * 0.025, y: strip.maxY - r.height * 0.13))
            let type = NSAttributedString(string: skin.material == .chrome ? "METAL" : "C-90", attributes: [
                .font: NSFont.systemFont(ofSize: r.height * 0.05, weight: .heavy), .kern: 1.5, .foregroundColor: NSColor(white: 0.1, alpha: 0.8)])
            type.draw(at: NSPoint(x: strip.maxX - type.size().width - r.width * 0.025, y: strip.maxY - r.height * 0.11))
        }
    }

    /// The cassette's paper label…
    static func labelStrip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX + r.width * 0.07, y: r.minY + r.height * 0.27, width: r.width * 0.86, height: r.height * 0.63)
    }

    /// …and the part of it under the printed top band, where the cover goes.
    static func labelArea(_ r: CGRect) -> CGRect {
        let strip = labelStrip(r)
        return CGRect(x: strip.minX, y: strip.minY, width: strip.width, height: strip.height * 0.78)
    }

    /// The clear window over the reels, showing the tape (drawn over the label).
    static func window(reels: [CGPoint], full: CGFloat, tall: CGFloat = 1.05) {
        let window = windowRect(reels: reels, full: full, tall: tall)
        let win = NSBezierPath(roundedRect: window, xRadius: window.height * 0.5, yRadius: window.height * 0.5)
        NSColor(white: 0.06, alpha: 0.97).setFill(); win.fill()
        NSColor(white: 1, alpha: 0.3).setStroke(); win.lineWidth = 1; win.stroke()
    }

    /// The window's frame: round-ended, as wide as both reels, `tall` × a full reel's radius above
    /// and below their centres.
    static func windowRect(reels: [CGPoint], full: CGFloat, tall: CGFloat) -> CGRect {
        CGRect(x: reels[0].x - full * 1.05, y: reels[0].y - full * tall, width: reels[1].x - reels[0].x + full * 2.1, height: full * tall * 2)
    }

    /// The big cassette in the music scene, laid out like the real thing (100 × 63.8 mm, hubs
    /// 42.4 mm apart): the cover fills the label, and the tape shows through a window between the
    /// hubs and through the round holes around them.
    @MainActor
    struct Big {
        let bounds: CGRect
        let reels: [CGPoint]
        let spool: CGFloat    // an empty reel's radius
        let full: CGFloat     // a full reel's radius
        let hole: CGFloat     // the round openings around the hubs
        let hubD: CGFloat     // the hubs' diameter
        let window: CGRect    // the clear window between them

        init(size: CGSize) {
            bounds = CGRect(origin: .zero, size: size)
            let (w, h) = (size.width, size.height)
            let y = labelArea(bounds).midY
            reels = [CGPoint(x: w * (0.5 - 0.212), y: y), CGPoint(x: w * (0.5 + 0.212), y: y)]
            spool = w * 0.075
            full = w * 0.17
            hole = h * 0.12
            hubD = h * 0.17
            let gap = h * 0.035
            window = CGRect(x: reels[0].x + hole + gap, y: y - h * 0.1, width: reels[1].x - reels[0].x - 2 * (hole + gap), height: h * 0.2)
        }

        /// Where the label is cut away: the window and the two hub holes.
        var openings: CGPath {
            let p = CGMutablePath()
            p.addRoundedRect(in: window, cornerWidth: window.height * 0.18, cornerHeight: window.height * 0.18)
            for c in reels { p.addEllipse(in: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2)) }
            return p
        }
    }

    /// Behind the openings: the dark inside of the shell (the tape and hubs go over it).
    static func inside(_ g: Big) {
        let path = NSBezierPath(cgPath: g.openings)
        NSColor(white: 0.05, alpha: 1).setFill(); path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [NSColor(white: 0.14, alpha: 1), NSColor(white: 0.03, alpha: 1)])?.draw(in: g.window.insetBy(dx: -g.hole * 3, dy: -g.hole), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Over the openings: their edges, the window's clear plastic catching the light, and the
    /// tape-length marks printed beside the window.
    static func glass(_ g: Big) {
        let path = NSBezierPath(cgPath: g.openings)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        // A soft shade just inside every edge: the label's thickness.
        for (width, alpha) in [(8.0, 0.18), (4.0, 0.25)] {
            let edge = NSBezierPath(cgPath: g.openings)
            edge.lineWidth = width
            NSColor(white: 0, alpha: alpha).setStroke(); edge.stroke()
        }
        // The window's plastic: a diagonal sheen.
        let sheen = NSBezierPath()
        let w = g.window
        sheen.move(to: CGPoint(x: w.minX + w.width * 0.15, y: w.maxY)); sheen.line(to: CGPoint(x: w.minX + w.width * 0.42, y: w.maxY))
        sheen.line(to: CGPoint(x: w.minX + w.width * 0.27, y: w.minY)); sheen.line(to: CGPoint(x: w.minX, y: w.minY)); sheen.close()
        NSColor(white: 1, alpha: 0.07).setFill(); sheen.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0, alpha: 0.6).setStroke(); path.lineWidth = 1.5; path.stroke()
        NSColor(white: 1, alpha: 0.18).setStroke()
        let rim = NSBezierPath(cgPath: g.openings)
        rim.transform(using: AffineTransform(translationByX: 0, byY: -1))
        rim.lineWidth = 0.8; rim.stroke()
        // Tape-length marks above and below the window, printed on the label.
        NSColor(white: 0.2, alpha: 0.55).setFill()
        for i in 0...8 {
            let x = w.minX + w.width * (0.1 + 0.8 * CGFloat(i) / 8)
            let long = i % 4 == 0
            NSRect(x: x - 0.6, y: w.maxY + 2, width: 1.2, height: long ? w.height * 0.12 : w.height * 0.07).fill()
            NSRect(x: x - 0.6, y: w.minY - 2 - (long ? w.height * 0.12 : w.height * 0.07), width: 1.2, height: long ? w.height * 0.12 : w.height * 0.07).fill()
        }
    }

    /// Ruled lines across the label, for writing on (the cassette in the music scene).
    static func ruledLabel(_ r: CGRect) {
        let area = labelArea(r)
        NSColor(white: 0.94, alpha: 1).setFill()
        NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height).fill()
        NSColor(red: 0.45, green: 0.6, blue: 0.85, alpha: 0.35).setFill()
        for y in stride(from: area.minY + area.height * 0.08, to: area.maxY - 2, by: area.height * 0.13) {
            NSRect(x: area.minX + area.width * 0.03, y: y, width: area.width * 0.94, height: 0.8).fill()
        }
    }

    /// The case behind the card: smoked clear plastic with its hinge along the top.
    static func caseBack(_ r: CGRect, card: CGFloat) {
        let shell = NSBezierPath(roundedRect: r, xRadius: card * 0.8, yRadius: card * 0.8)
        NSColor(white: 0.08, alpha: 0.75).setFill(); shell.fill()
        NSColor(white: 1, alpha: 0.25).setStroke(); shell.lineWidth = 1; shell.stroke()
    }

    /// Over the card: the case's lid, catching the light, its hinge, and the card's fold (the spine).
    static func caseFront(_ r: CGRect, card: CGFloat) {
        let inner = r.insetBy(dx: card, dy: card)
        NSColor(white: 0, alpha: 0.12).setFill() // the J-card's fold near its left edge
        NSRect(x: inner.minX + inner.width * 0.075, y: inner.minY, width: 1.2, height: inner.height).fill()
        NSColor(white: 1, alpha: 0.1).setFill()
        NSRect(x: inner.minX + inner.width * 0.075 + 1.2, y: inner.minY, width: 0.8, height: inner.height).fill()
        let gloss = NSBezierPath()
        gloss.move(to: CGPoint(x: r.minX, y: r.maxY)); gloss.line(to: CGPoint(x: r.minX + r.width * 0.55, y: r.maxY))
        gloss.line(to: CGPoint(x: r.minX, y: r.maxY - r.height * 0.6)); gloss.close()
        NSGradient(colors: [NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0.02)])?.draw(in: gloss, angle: -45)
        for x in [r.minX + r.width * 0.12, r.maxX - r.width * 0.12] { // the hinge's pins along the top
            NSColor(white: 1, alpha: 0.3).setFill()
            NSRect(x: x - r.width * 0.05, y: r.maxY - card * 0.55, width: r.width * 0.1, height: card * 0.3).fill()
        }
        NSColor(white: 1, alpha: 0.35).setStroke()
        let rim = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: card * 0.7, yRadius: card * 0.7)
        rim.lineWidth = 1; rim.stroke()
    }

    /// A pack of tape seen edge-on through the window: brown, with the faint rings of its turns.
    static func pack(radius r: CGFloat) {
        let c = CGPoint(x: r, y: r)
        NSGradient(colors: [NSColor(red: 0.36, green: 0.21, blue: 0.12, alpha: 1), NSColor(red: 0.24, green: 0.13, blue: 0.07, alpha: 1)])?
            .draw(in: NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 2 * r, height: 2 * r)), relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))
        var rng = SeededRandom(seed: 90)
        for rad in stride(from: r * 0.3, to: r, by: 1.6) {
            NSColor(white: Bool.random(using: &rng) ? 1 : 0, alpha: .random(in: 0.02...0.07, using: &rng)).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
            ring.lineWidth = 0.8
            ring.stroke()
        }
        NSColor(white: 1, alpha: 0.12).setStroke()
        NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: 2 * r - 1, height: 2 * r - 1)).stroke()
    }

    /// A reel's hub: a white ring with six teeth (so you can see it turn).
    static func hub(diameter d: CGFloat) {
        let c = CGPoint(x: d / 2, y: d / 2)
        NSColor(white: 0.93, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: d, height: d)).fill()
        NSColor(white: 0.08, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: d * 0.24, y: d * 0.24, width: d * 0.52, height: d * 0.52)).fill()
        NSColor(white: 0.93, alpha: 1).setFill()
        for i in 0..<6 {
            let a = CGFloat(i) / 6 * 2 * .pi
            let tooth = NSBezierPath()
            let w: CGFloat = 0.11
            tooth.move(to: CGPoint(x: c.x + cos(a - w) * d * 0.27, y: c.y + sin(a - w) * d * 0.27))
            tooth.line(to: CGPoint(x: c.x + cos(a) * d * 0.17, y: c.y + sin(a) * d * 0.17))
            tooth.line(to: CGPoint(x: c.x + cos(a + w) * d * 0.27, y: c.y + sin(a + w) * d * 0.27))
            tooth.close()
            tooth.fill()
        }
        NSColor(white: 0, alpha: 0.35).setStroke()
        NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: d - 1, height: d - 1)).stroke()
    }

    /// Piano keys: chunky, squared, with a lit stripe along the top edge.
    private static func key(_ r: CGRect, symbol: String, _ skin: Skin) {
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1).offsetBy(dx: 0, dy: -2), xRadius: 2, yRadius: 2).fill()
        let key = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
        NSGradient(colors: skin.colors.button.map(\.ns))?.draw(in: key, angle: -90)
        NSColor(white: 1, alpha: 0.28).setFill()
        NSRect(x: r.minX + 1, y: r.maxY - 3, width: r.width - 2, height: 2).fill()
        Paint.symbol(symbol, in: r.offsetBy(dx: 0, dy: -1), color: Paint.markColor(on: skin.colors.button[0].mixed(skin.colors.button[1], 0.5)))
    }

    /// The dB marks under each LED row and the L / R labels.
    private static func levelScale(_ rows: [CGRect], _ skin: Skin) {
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

    /// The equalizer's sliders (for show): a groove each, with a cap set to a gentle smile.
    private static func sliders(_ r: CGRect, count: Int, inset: CGFloat, _ skin: Skin) {
        let inner = r.insetBy(dx: inset, dy: 6)
        let step = inner.width / CGFloat(count)
        NSColor(white: 1, alpha: 0.12).setFill()
        NSRect(x: inner.minX, y: inner.midY, width: inner.width, height: 0.5).fill() // the 0 dB line
        for i in 0..<count {
            let x = inner.minX + step * (CGFloat(i) + 0.5)
            NSColor(white: 0, alpha: 0.75).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: inner.minY + 8, width: 3, height: inner.height - 16), xRadius: 1.5, yRadius: 1.5).fill()
            let t = (CGFloat(i) - CGFloat(count - 1) / 2) / CGFloat(count - 1) * 2 // -1…1
            let capY = inner.midY + (t * t - 0.35) * (inner.height - 24) * 0.4
            let cap = NSRect(x: x - min(step * 0.35, 9), y: capY - 5, width: min(step * 0.7, 18), height: 10)
            NSGradient(colors: skin.colors.button.map(\.ns))?.draw(in: NSBezierPath(roundedRect: cap, xRadius: 1.5, yRadius: 1.5), angle: -90)
            NSColor(white: 1, alpha: 0.7).setFill()
            NSRect(x: cap.minX + 1, y: cap.midY - 0.5, width: cap.width - 2, height: 1).fill()
        }
    }
}
