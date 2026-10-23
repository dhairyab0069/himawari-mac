import AppKit
import HimawariKit

/// The 2000s pocket player, docked: on the left the dock's front (a pocket player's "Now
/// Playing" screen, flat buttons, a click wheel that scrubs), on the right its speaker (a
/// grille, a thin level display, touch knobs). In the middle, the player itself shows the cover
/// on its screen, and its wheel scrubs too (MusicScene).
struct PocketTheme: GearTheme {
    let skin: Skin
    var meters: StyleOptions.Meters = .era

    func left(size: CGSize) -> PanelFace {
        let column = GearLayout.column(size, skin)
        let colW = column.width
        let header = CGRect(x: column.minX, y: column.maxY - 30, width: colW, height: 30)
        let screen = CGRect(x: column.minX, y: header.minY - 10 - 150, width: colW, height: 150)
        let row = CGRect(x: column.minX, y: screen.minY - 22 - 34, width: colW, height: 34)
        let buttons = GearLayout.buttons(5, in: row, gap: CGFloat(skin.layout.gap))
        let lamp = CGRect(x: buttons[1].midX - 3, y: buttons[1].maxY + 5, width: 6, height: 6)
        let space = row.minY - 20 - column.minY
        let d = max(min(colW - 50, space - 20, 200), 70)
        let wheel = CGRect(x: column.midX - d / 2, y: column.minY + 8 + max((space - d) / 2, 0), width: d, height: d)

        let track = CGRect(x: screen.minX + 12, y: screen.minY + 32, width: screen.width - 24, height: 9)
        var face = PanelFace()
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin, screws: false)
            Self.header(header, skin, model: skin.leftModel)
            Self.screen(screen, skin)
            skin.colors.display.alpha(0.18).ns.setFill() // the progress line's groove
            NSBezierPath(roundedRect: CGRect(x: track.minX, y: track.midY - 1.5, width: track.width, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            let symbols = ["backward.end.fill", "playpause.fill", "forward.end.fill", "stop.fill", "eject.fill"]
            for (rect, name) in zip(buttons, symbols) { Self.flatButton(rect, symbol: name, skin) }
            Self.clickWheel(wheel, skin)
        }
        let inner = screen.insetBy(dx: 12, dy: 10)
        let (indicators, toggles) = GearLayout.indicators(at: CGPoint(x: inner.minX, y: inner.maxY - 11), width: inner.width,
                                                          skin: skin, offset: .zero)
        face.texts = indicators + [
            TextPart(role: .title, frame: CGRect(x: inner.minX, y: inner.maxY - 42, width: inner.width, height: 20), size: 15, weight: .bold, align: .center),
            TextPart(role: .artist, frame: CGRect(x: inner.minX, y: inner.maxY - 60, width: inner.width, height: 16),
                     size: 12, weight: .semibold, alpha: 0.8, align: .center),
            TextPart(role: .album, frame: CGRect(x: inner.minX, y: inner.maxY - 77, width: inner.width, height: 15),
                     size: 11, weight: .regular, alpha: 0.6, align: .center),
            TextPart(role: .time, frame: CGRect(x: inner.minX, y: inner.minY, width: inner.width * 0.5, height: 15),
                     size: 11, weight: .semibold, mono: true),
            TextPart(role: .total, frame: CGRect(x: inner.minX + inner.width * 0.5, y: inner.minY, width: inner.width * 0.5, height: 15),
                     size: 11, weight: .semibold, mono: true, align: .right),
        ]
        face.glow = (0, 0)
        face.uppercaseSong = false
        face.dialPointer = track
        face.dialDot = true
        face.lamp = lamp
        // The wheel itself doesn't turn: a dot where your finger is shows it.
        face.rotors = [RotorPart(frame: wheel, draw: { Self.touchDot(diameter: $0, skin) }, spin: nil, isJog: true)]
        face.controls = toggles
        for (control, rect) in zip([GearControl.previous, .playPause, .next, .stop, .eject], buttons) { face.controls[control] = rect }
        face.controls[.progress] = track.insetBy(dx: 0, dy: -6)
        face.controls[.jog] = wheel
        face.fixtures = []
        return face
    }

    func right(size: CGSize) -> PanelFace {
        let column = GearLayout.column(size, skin)
        let colW = column.width
        let header = CGRect(x: column.minX, y: column.maxY - 30, width: colW, height: 30)
        let small = min(40, colW * 0.24), big = min(56, colW * 0.34)
        let y = column.minY + 22
        let floor = y + big + 20
        let levels = CGRect(x: column.minX, y: header.minY - 10 - 64, width: colW, height: 64)
        let room = levels.minY - 16 - floor
        let grilleD = max(min(colW - 20, room), 40)
        let grille = CGRect(x: column.midX - grilleD / 2, y: floor + (room - grilleD) / 2, width: grilleD, height: grilleD)
        let knobs: [(control: GearControl, rect: CGRect)] = [
            (.bass, CGRect(x: column.minX + colW * 0.18 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
            (.treble, CGRect(x: column.minX + colW * 0.45 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
            (.volume, CGRect(x: column.minX + colW * 0.78 - big / 2, y: y, width: big, height: big))]
        let inner = levels.insetBy(dx: 12, dy: 10)
        let rows = [CGRect(x: inner.minX + 14, y: inner.maxY - 6, width: inner.width - 14, height: 4),
                    CGRect(x: inner.minX + 14, y: inner.minY + 2, width: inner.width - 14, height: 4)]
        let block = meters == .era ? nil : GearLayout.meters(meters, in: levels, skin)

        var face = PanelFace()
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin, screws: false)
            Self.header(header, skin, model: skin.rightModel)
            if let block { block.draw() } else {
                Self.screen(levels, skin)
                for (row, ch) in zip(rows, ["L", "R"]) {
                    NSAttributedString(string: ch, attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .bold),
                                                               .foregroundColor: skin.colors.display.alpha(0.6).ns])
                        .draw(at: NSPoint(x: inner.minX, y: row.midY - 5))
                    skin.colors.display.alpha(0.12).ns.setFill()
                    NSBezierPath(roundedRect: row, xRadius: 2, yRadius: 2).fill()
                }
            }
            Self.grille(grille, skin)
            for k in knobs { Self.touchKnob(k.rect, label: k.control.knobName ?? "", skin) }
        }
        face.bars = block?.bars ?? rows.enumerated().map { i, r in
            BarPart(source: .channel(i), frame: r, segments: 1, vertical: false, gap: 0, colors: [skin.colors.accent.cg])
        }
        face.needles = block?.needles ?? []
        face.glow = (0, 0)
        face.knobs = knobs
        face.controls = GearLayout.grabAreas(knobs, within: CGRect(origin: .zero, size: size))
        face.fixtures = [levels, grille]
        return face
    }

    // MARK: Drawing (shared with the player in the music scene)

    private static func header(_ r: CGRect, _ skin: Skin, model: String) {
        let brand = NSAttributedString(string: skin.brand, attributes: [.font: Paint.brandFont(skin, 12), .kern: 3,
                                                                        .foregroundColor: skin.colors.label.ns])
        brand.draw(at: NSPoint(x: r.midX - brand.size().width / 2, y: r.maxY - 16))
        let model = NSAttributedString(string: model, attributes: [.font: NSFont.systemFont(ofSize: 7.5, weight: .medium), .kern: 1.5,
                                                                            .foregroundColor: skin.colors.label.alpha(0.6).ns])
        model.draw(at: NSPoint(x: r.midX - model.size().width / 2, y: r.maxY - 28))
    }

    /// The player's screen: a pale backlit LCD behind a glossy face, with its "Now Playing" bar.
    static func screen(_ r: CGRect, _ skin: Skin) {
        NSColor(white: 0, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: -4, dy: -4), xRadius: 6, yRadius: 6).fill()
        let glass = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        NSGradient(colors: skin.colors.glass.map(\.ns))?.draw(in: glass, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        glass.addClip()
        let shine = NSBezierPath()
        shine.move(to: CGPoint(x: r.minX, y: r.maxY)); shine.line(to: CGPoint(x: r.maxX, y: r.maxY))
        shine.line(to: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.18)); shine.line(to: CGPoint(x: r.minX, y: r.maxY - r.height * 0.42)); shine.close()
        NSColor(white: 1, alpha: 0.18).setFill(); shine.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A flat, glossy button.
    private static func flatButton(_ r: CGRect, symbol: String, _ skin: Skin) {
        let b = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSGradient(colors: skin.colors.button.map(\.ns))?.draw(in: b, angle: -90)
        NSColor(white: 0, alpha: 0.18).setStroke(); b.lineWidth = 0.8; b.stroke()
        Paint.symbol(symbol, in: r, color: Paint.markColor(on: skin.colors.button[0].mixed(skin.colors.button[1], 0.5)).withAlphaComponent(0.7))
    }

    /// The click wheel: a ring around a centre button, with its four words.
    static func clickWheel(_ r: CGRect, _ skin: Skin) {
        let ring = skin.colors.button[0].mixed(skin.colors.button[1], 0.35)
        NSColor(white: 0, alpha: 0.12).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: -1.5, dy: -1.5).offsetBy(dx: 0, dy: -1)).fill()
        NSGradient(colors: [ring.mixed(SkinColor(1, 1, 1), 0.3).ns, ring.ns])?.draw(in: NSBezierPath(ovalIn: r), angle: -90)
        let centre = r.insetBy(dx: r.width * 0.31, dy: r.width * 0.31)
        NSColor(white: 0, alpha: 0.12).setStroke()
        NSBezierPath(ovalIn: centre).stroke()
        NSGradient(colors: skin.colors.button.map(\.ns))?.draw(in: NSBezierPath(ovalIn: centre.insetBy(dx: 1, dy: 1)), angle: -90)
        let ink = skin.colors.label.mixed(SkinColor(0.5, 0.5, 0.5), 0.2).alpha(0.85).ns
        let c = CGPoint(x: r.midX, y: r.midY), rad = r.width * 0.4
        let menu = NSAttributedString(string: "MENU", attributes: [.font: NSFont.systemFont(ofSize: max(r.width * 0.055, 8), weight: .bold),
                                                                   .foregroundColor: ink])
        menu.draw(at: NSPoint(x: c.x - menu.size().width / 2, y: c.y + rad - menu.size().height / 2))
        Paint.symbol("backward.end.alt.fill", in: CGRect(x: c.x - rad - 8, y: c.y - 8, width: 16, height: 16), color: ink, size: 9)
        Paint.symbol("forward.end.alt.fill", in: CGRect(x: c.x + rad - 8, y: c.y - 8, width: 16, height: 16), color: ink, size: 9)
        Paint.symbol("playpause.fill", in: CGRect(x: c.x - 8, y: c.y - rad - 8, width: 16, height: 16), color: ink, size: 9)
    }

    /// Where your finger is on the wheel: a soft dot on the ring.
    static func touchDot(diameter d: CGFloat, _ skin: Skin) {
        let a = -CGFloat.pi / 4 // at half past four, clear of the words
        let p = CGPoint(x: d / 2 + cos(a) * d * 0.4, y: d / 2 + sin(a) * d * 0.4)
        skin.colors.accent.alpha(0.35).ns.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - d * 0.06, y: p.y - d * 0.06, width: d * 0.12, height: d * 0.12)).fill()
    }

    /// The speaker: a perforated grille over a dark cone.
    private static func grille(_ r: CGRect, _ skin: Skin) {
        NSColor(white: 0, alpha: 0.2).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -3)).fill()
        NSGradient(colors: [NSColor(white: 0.22, alpha: 1), NSColor(white: 0.06, alpha: 1)])?
            .draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: NSPoint(x: 0, y: 0.2))
        let c = CGPoint(x: r.midX, y: r.midY), step = max(r.width / 26, 4)
        NSColor(white: 0, alpha: 0.55).setFill()
        let mesh = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
        NSGraphicsContext.saveGraphicsState()
        mesh.addClip()
        skin.colors.plate[1].mixed(SkinColor(0.5, 0.5, 0.5), 0.3).alpha(0.9).ns.setFill()
        mesh.fill()
        NSColor(white: 0, alpha: 0.75).setFill()
        var y = r.minY
        var odd = false
        while y < r.maxY {
            var x = r.minX + (odd ? step / 2 : 0)
            while x < r.maxX {
                NSBezierPath(ovalIn: NSRect(x: x - step * 0.28, y: y - step * 0.28, width: step * 0.56, height: step * 0.56)).fill()
                x += step
            }
            y += step * 0.87
            odd.toggle()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.25).setStroke()
        NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).stroke()
        _ = c
    }

    /// A flat touch knob: a disc with a fine ring and its scale.
    static func touchKnob(_ r: CGRect, label name: String, _ skin: Skin) {
        NSColor(white: 0, alpha: 0.15).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: -2, dy: -2).offsetBy(dx: 0, dy: -1)).fill()
        NSGradient(colors: skin.colors.knob.map(\.ns))?.draw(in: NSBezierPath(ovalIn: r), angle: -90)
        NSColor(white: 0, alpha: 0.15).setStroke()
        NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.12, dy: r.width * 0.12)).stroke()
        let c = CGPoint(x: r.midX, y: r.midY)
        for i in 0...10 {
            let t = -0.75 * CGFloat.pi + CGFloat(i) * 0.15 * CGFloat.pi
            let p = CGPoint(x: c.x - sin(t) * (r.width / 2 + 6), y: c.y + cos(t) * (r.width / 2 + 6))
            skin.colors.label.alpha(0.5).ns.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)).fill()
        }
        Paint.label(name, centeredAt: CGPoint(x: r.midX, y: r.minY - 12), skin)
    }
}
