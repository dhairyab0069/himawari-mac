import AppKit
import HimawariKit

/// Today, minimal: two panes of glass. On the left the song in large, plain type, a thin
/// progress line with a dot, bare transport symbols and a thin ring to turn; on the right a
/// thin waveform of the music, two hairline levels and flat knobs. In the middle, the cover
/// floats on a card (MusicScene).
struct MinimalTheme: GearTheme {
    let skin: Skin
    var meters: StyleOptions.Meters = .era

    func left(size: CGSize) -> PanelFace {
        let column = GearLayout.column(size, skin).insetBy(dx: 4, dy: 4)
        let colW = column.width
        let top = column.maxY
        let row = CGRect(x: column.minX, y: top - 238, width: colW, height: 36)
        let buttons = GearLayout.buttons(5, in: row, gap: CGFloat(skin.layout.gap))
        let track = CGRect(x: column.minX, y: top - 180, width: colW, height: 12)
        let space = row.minY - 24 - column.minY
        let d = max(min(colW - 80, space - 10, 160), 60)
        let ring = CGRect(x: column.midX - d / 2, y: column.minY + max((space - d) / 2, 0), width: d, height: d)

        var face = PanelFace()
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin, screws: false)
            NSAttributedString(string: skin.leftModel, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .kern: 1.6,
                                                                    .foregroundColor: skin.colors.label.ns])
                .draw(at: NSPoint(x: column.minX, y: top - 12))
            skin.colors.display.alpha(0.15).ns.setFill() // the progress line's groove
            NSBezierPath(roundedRect: CGRect(x: track.minX, y: track.midY - 1.5, width: track.width, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            let symbols = ["backward.fill", "playpause.fill", "forward.fill", "stop.fill", "eject.fill"]
            for (rect, name) in zip(buttons, symbols) {
                Paint.symbol(name, in: rect, color: skin.colors.display.alpha(name == "playpause.fill" ? 0.95 : 0.7).ns, size: name == "playpause.fill" ? 20 : 15)
            }
            skin.colors.display.alpha(0.18).ns.setStroke()
            let groove = NSBezierPath(ovalIn: ring.insetBy(dx: 2, dy: 2))
            groove.lineWidth = 2
            groove.stroke()
        }
        let (indicators, toggles) = GearLayout.indicators(at: CGPoint(x: column.minX, y: top - 30), width: colW, skin: skin, offset: .zero)
        face.texts = indicators.map { var t = $0; t.alpha = 0.9; return t } + [
            TextPart(role: .title, frame: CGRect(x: column.minX, y: top - 64, width: colW, height: 28), size: 22, weight: .semibold),
            TextPart(role: .artist, frame: CGRect(x: column.minX, y: top - 86, width: colW, height: 20), size: 15, weight: .regular, alpha: 0.75),
            TextPart(role: .album, frame: CGRect(x: column.minX, y: top - 105, width: colW, height: 17), size: 12, weight: .regular, alpha: 0.5),
            TextPart(role: .time, frame: CGRect(x: column.minX - 1, y: top - 158, width: colW * 0.6, height: 40), size: 32, weight: .ultraLight, mono: true),
            TextPart(role: .total, frame: CGRect(x: column.minX + colW * 0.6, y: top - 150, width: colW * 0.4, height: 16),
                     size: 12, weight: .regular, alpha: 0.55, mono: true, align: .right),
        ]
        face.glow = (0, 0)
        face.uppercaseSong = false
        face.dialPointer = track
        face.dialDot = true
        face.rotors = [RotorPart(frame: ring, draw: { Self.ringDot(diameter: $0, skin) }, spin: nil, isJog: true)]
        face.controls = toggles
        for (control, rect) in zip([GearControl.previous, .playPause, .next, .stop, .eject], buttons) { face.controls[control] = rect }
        face.controls[.progress] = track
        face.controls[.jog] = ring
        return face
    }

    func right(size: CGSize) -> PanelFace {
        let column = GearLayout.column(size, skin).insetBy(dx: 4, dy: 4)
        let colW = column.width
        let top = column.maxY
        let small = min(38, colW * 0.22), big = min(52, colW * 0.32)
        let y = column.minY + 18
        let floor = y + big + 20
        let lines = CGRect(x: column.minX, y: top - 70, width: colW, height: 40)
        // The waveform fills what's left (below the needles, when there are needles up there).
        let waveTop = meters == .needles ? lines.minY - 68 : lines.minY - 24
        let wave = CGRect(x: column.minX, y: floor + 10, width: colW, height: max(min(waveTop - floor - 10, 240), 40))
        let knobs: [(control: GearControl, rect: CGRect)] = [
            (.bass, CGRect(x: column.minX + colW * 0.18 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
            (.treble, CGRect(x: column.minX + colW * 0.45 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
            (.volume, CGRect(x: column.minX + colW * 0.78 - big / 2, y: y, width: big, height: big))]
        let rows = [CGRect(x: lines.minX + 16, y: lines.maxY - 8, width: lines.width - 16, height: 3),
                    CGRect(x: lines.minX + 16, y: lines.minY + 5, width: lines.width - 16, height: 3)]
        let block = meters == .era ? nil : GearLayout.meters(meters, in: meters == .needles
            ? CGRect(x: lines.minX, y: lines.minY - 60, width: lines.width, height: lines.height + 60) : lines, skin)

        var face = PanelFace()
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin, screws: false)
            NSAttributedString(string: skin.rightModel, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .kern: 1.6,
                                                                     .foregroundColor: skin.colors.label.ns])
                .draw(at: NSPoint(x: column.minX, y: top - 12))
            if let block { block.draw() } else {
                for (row, ch) in zip(rows, ["L", "R"]) {
                    NSAttributedString(string: ch, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                                                               .foregroundColor: skin.colors.label.ns])
                        .draw(at: NSPoint(x: lines.minX, y: row.midY - 6))
                    skin.colors.display.alpha(0.12).ns.setFill()
                    NSBezierPath(roundedRect: row, xRadius: 1.5, yRadius: 1.5).fill()
                }
            }
            skin.colors.display.alpha(0.08).ns.setFill() // the waveform's baseline
            NSRect(x: wave.minX, y: wave.midY - 0.5, width: wave.width, height: 1).fill()
            for k in knobs { Self.flatKnob(k.rect, label: k.control.knobName ?? "", skin) }
        }
        face.bars = block?.bars ?? rows.enumerated().map { i, r in
            BarPart(source: .channel(i), frame: r, segments: 1, vertical: false, gap: 0, colors: [skin.colors.accent.cg])
        }
        face.needles = block?.needles ?? []
        // The waveform: thin rounded bars, mirrored about the middle (each grows up from its centre).
        let count = AudioLevels.bandCount, gap: CGFloat = max((wave.width - CGFloat(count) * 6) / CGFloat(count - 1), 4)
        let w = (wave.width - CGFloat(count - 1) * gap) / CGFloat(count)
        face.bars += (0..<count).map { i in
            BarPart(source: .band(i), frame: CGRect(x: wave.minX + CGFloat(i) * (w + gap), y: wave.minY, width: w, height: wave.height),
                    segments: 1, gap: 0, colors: [skin.colors.display.alpha(0.85).cg], centred: true)
        }
        face.glow = (0, 0)
        face.knobs = knobs
        face.controls = GearLayout.grabAreas(knobs, within: CGRect(origin: .zero, size: size))
        face.fixtures = [wave] + (block?.fixtures ?? [lines])
        return face
    }

    // MARK: Drawing

    /// The ring you turn: a dot on it shows where it's been turned to.
    private static func ringDot(diameter d: CGFloat, _ skin: Skin) {
        let p = CGPoint(x: d / 2, y: d - 2 - d * 0.04)
        skin.colors.accent.ns.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - d * 0.04, y: p.y - d * 0.04, width: d * 0.08, height: d * 0.08)).fill()
    }

    /// A flat knob: a filled circle with a hairline rim.
    private static func flatKnob(_ r: CGRect, label name: String, _ skin: Skin) {
        NSColor(white: 0, alpha: 0.18).setFill()
        NSBezierPath(ovalIn: r.offsetBy(dx: 0, dy: -1.5)).fill()
        skin.colors.knob[0].ns.setFill()
        NSBezierPath(ovalIn: r).fill()
        skin.colors.display.alpha(0.15).ns.setStroke()
        NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
        NSAttributedString(string: name.capitalized, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                                  .foregroundColor: skin.colors.label.ns])
            .draw(at: NSPoint(x: r.midX - NSAttributedString(string: name.capitalized, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).size().width / 2,
                              y: r.minY - 17))
    }
}
