import AppKit
import HimawariKit

/// The 1990s portable: on the left a portable CD player's face (a grey-green LCD with the song,
/// the time and a segment progress bar, round rubber buttons, a jog dial), on the right its LCD
/// remote (LCD level bars and spectrum, the MEGA BASS switch, knobs). In the middle, the CD turns
/// under the player's clear lid (MusicScene).
struct PortableTheme: GearTheme {
    let skin: Skin
    var meters: StyleOptions.Meters = .era

    func left(size: CGSize) -> PanelFace {
        let column = GearLayout.column(size, skin)
        let colW = column.width
        let header = CGRect(x: column.minX, y: column.maxY - 40, width: colW, height: 40)
        let lcd = CGRect(x: column.minX, y: header.minY - 14 - 156, width: colW, height: 156)
        let d = min(46, (colW - 4 * CGFloat(skin.layout.gap)) / 5) // the round buttons
        let rowY = lcd.minY - 30 - d
        let step = (colW - d) / 4
        let buttons = (0..<5).map { CGRect(x: column.minX + CGFloat($0) * step, y: rowY, width: d, height: d) }
        let lamp = CGRect(x: buttons[1].midX - 3, y: buttons[1].maxY + 6, width: 6, height: 6)
        let space = rowY - 18 - 70 - column.minY
        let jogD = max(min(colW - 70, space - 30, 170), 56)
        let jog = CGRect(x: column.midX - jogD / 2, y: column.minY + 70 + max((space - jogD) / 2, 0), width: jogD, height: jogD)

        var face = PanelFace()
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin)
            Paint.header(header, brand: skin.brand, model: skin.leftModel, skin)
            Self.lcd(lcd, skin)
            let symbols = ["backward.end.fill", "playpause.fill", "forward.end.fill", "stop.fill", "eject.fill"]
            let names = ["", "", "", "", "OPEN"]
            for (i, rect) in buttons.enumerated() {
                Self.rubberButton(rect, symbol: symbols[i], skin)
                if !names[i].isEmpty { Paint.label(names[i], centeredAt: CGPoint(x: rect.midX, y: rect.minY - 10), skin) }
            }
            Paint.powerRow(column, skin)
            NSColor(white: 0, alpha: 0.35).setFill()
            NSBezierPath(ovalIn: jog.insetBy(dx: -5, dy: -5)).fill()
            Paint.label("JOG DIAL", centeredAt: CGPoint(x: jog.midX, y: jog.minY - 14), skin)
        }
        let inner = lcd.insetBy(dx: 14, dy: 12)
        let (indicators, toggles) = GearLayout.indicators(at: CGPoint(x: inner.minX, y: inner.maxY - 11), width: inner.width - 22, skin: skin, offset: .zero)
        face.texts = indicators + [
            TextPart(role: .time, frame: CGRect(x: inner.minX - 1, y: inner.maxY - 56, width: inner.width * 0.62, height: 42),
                     size: 34, weight: .medium, mono: true),
            TextPart(role: .total, frame: CGRect(x: inner.minX + inner.width * 0.6, y: inner.maxY - 50, width: inner.width * 0.4, height: 15),
                     size: 12, weight: .semibold, alpha: 0.75, mono: true, align: .right),
            TextPart(role: .title, frame: CGRect(x: inner.minX, y: inner.maxY - 92, width: inner.width, height: 19), size: 15, weight: .heavy),
            TextPart(role: .artist, frame: CGRect(x: inner.minX, y: inner.maxY - 109, width: inner.width, height: 16),
                     size: 11.5, weight: .bold, alpha: 0.85),
            TextPart(role: .album, frame: CGRect(x: inner.minX, y: inner.maxY - 124, width: inner.width, height: 15),
                     size: 10.5, weight: .medium, alpha: 0.65),
        ]
        face.glow = (0, 0) // an LCD doesn't glow
        face.ladderGlow = false
        let segments = 20, gap: CGFloat = 3
        let segW = (inner.width - CGFloat(segments - 1) * gap) / CGFloat(segments)
        face.ladder = (0..<segments).map { CGRect(x: inner.minX + CGFloat($0) * (segW + gap), y: inner.maxY - 68, width: segW, height: 5) }
        face.lamp = lamp
        face.rotors = [RotorPart(frame: jog, draw: { Paint.wheel(diameter: $0, skin) }, spin: nil, isJog: true)]
        face.controls = toggles
        for (control, rect) in zip([GearControl.previous, .playPause, .next, .stop, .eject], buttons) { face.controls[control] = rect }
        face.controls[.progress] = CGRect(x: inner.minX, y: inner.maxY - 76, width: inner.width, height: 21)
        face.controls[.jog] = jog
        return face
    }

    func right(size: CGSize) -> PanelFace {
        let column = GearLayout.column(size, skin)
        let colW = column.width
        let header = CGRect(x: column.minX, y: column.maxY - 40, width: colW, height: 40)
        let small = min(40, colW * 0.24), big = min(56, colW * 0.34)
        let y = column.minY + 22
        let floor = y + big + 20
        let levels = CGRect(x: column.minX, y: header.minY - 14 - 74, width: colW, height: 74)
        let switchH: CGFloat = 44
        let spectrumH = max(min(levels.minY - 16 - floor - switchH - 14, 200), 60)
        let spectrumLCD = CGRect(x: column.minX, y: levels.minY - 16 - spectrumH, width: colW, height: spectrumH)
        let bassSwitch = CGRect(x: column.minX, y: spectrumLCD.minY - 12 - switchH, width: colW, height: switchH)
        let knobs: [(control: GearControl, rect: CGRect)] = [
            (.bass, CGRect(x: column.minX + colW * 0.18 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
            (.treble, CGRect(x: column.minX + colW * 0.45 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
            (.volume, CGRect(x: column.minX + colW * 0.78 - big / 2, y: y, width: big, height: big))]
        let rows = [CGRect(x: levels.minX + 26, y: levels.maxY - 24, width: levels.width - 38, height: 10),
                    CGRect(x: levels.minX + 26, y: levels.minY + 14, width: levels.width - 38, height: 10)]
        let labels = CGRect(x: spectrumLCD.minX + 12, y: spectrumLCD.minY + 7, width: colW - 24, height: 10)
        let spectrum = CGRect(x: spectrumLCD.minX + 12, y: labels.maxY + 5, width: colW - 24, height: spectrumH - 30)
        let block = meters == .era || meters == .leds ? nil : GearLayout.meters(meters, in: levels, skin)

        var face = PanelFace()
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin)
            Paint.header(header, brand: skin.brand, model: skin.rightModel, skin)
            if let block { block.draw() } else { Self.lcd(levels, skin); Paint.levelScale(rows, skin) }
            Self.lcd(spectrumLCD, skin)
            Paint.bandLabels(labels, skin.colors.display.alpha(0.55).ns)
            if bassSwitch.height >= 30 { Self.megaBass(bassSwitch, skin) }
            for k in knobs { Paint.knob(k.rect, label: k.control.knobName ?? "", skin, pointer: false) }
        }
        // An LCD's segments are all one colour.
        let ink = skin.colors.display.cg
        face.bars = block?.bars ?? rows.enumerated().map { i, r in
            BarPart(source: .channel(i), frame: r, segments: 20, vertical: false, gap: 2, colors: Array(repeating: ink, count: 20))
        }
        face.needles = block?.needles ?? []
        let count = AudioLevels.bandCount, gap: CGFloat = 6
        let w = (spectrum.width - CGFloat(count - 1) * gap) / CGFloat(count)
        let segments = max(Int(spectrum.height / 9), 4)
        face.bars += (0..<count).map { i in
            BarPart(source: .band(i), frame: CGRect(x: spectrum.minX + CGFloat(i) * (w + gap), y: spectrum.minY, width: w, height: spectrum.height),
                    segments: segments, gap: 3, colors: Array(repeating: ink, count: segments))
        }
        face.glow = (0, 0)
        face.knobs = knobs
        face.controls = GearLayout.grabAreas(knobs, within: CGRect(origin: .zero, size: size))
        face.fixtures = [levels, spectrumLCD]
        return face
    }

    // MARK: Drawing

    /// A grey-green LCD in a dark surround, with its faint unlit segments' ghost and a battery icon.
    static func lcd(_ r: CGRect, _ skin: Skin) {
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 7, yRadius: 7).fill()
        let glass = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        NSGradient(colors: skin.colors.glass.map(\.ns))?.draw(in: glass, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        glass.addClip()
        NSGradient(colors: [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0)])?
            .draw(in: CGRect(x: r.minX, y: r.maxY - r.height * 0.4, width: r.width, height: r.height * 0.4), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        // The battery, top right.
        let ink = skin.colors.display.alpha(0.75).ns
        let battery = CGRect(x: r.maxX - 30, y: r.maxY - 17, width: 16, height: 8)
        ink.setStroke()
        NSBezierPath(rect: battery).stroke()
        ink.setFill()
        NSRect(x: battery.maxX, y: battery.midY - 1.5, width: 2, height: 3).fill()
        for i in 0..<3 { NSRect(x: battery.minX + 2 + CGFloat(i) * 4.5, y: battery.minY + 2, width: 3, height: battery.height - 4).fill() }
    }

    /// A round, soft rubber button with its symbol moulded in.
    private static func rubberButton(_ r: CGRect, symbol: String, _ skin: Skin) {
        NSColor(white: 0, alpha: 0.4).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: -2, dy: -2).offsetBy(dx: 0, dy: -1.5)).fill()
        NSGradient(colors: skin.colors.button.map(\.ns))?.draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: NSPoint(x: -0.3, y: 0.4))
        NSColor(white: 1, alpha: 0.22).setStroke()
        NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).stroke()
        Paint.symbol(symbol, in: r, color: Paint.markColor(on: skin.colors.button[0].mixed(skin.colors.button[1], 0.5)), size: 12)
    }

    /// The MEGA BASS slide switch (for show), and the HOLD switch.
    private static func megaBass(_ r: CGRect, _ skin: Skin) {
        for (i, (name, on)) in [("MEGA BASS", true), ("HOLD", false)].enumerated() {
            let c = CGPoint(x: r.minX + r.width * (0.27 + 0.46 * CGFloat(i)), y: r.midY + 6)
            let track = NSRect(x: c.x - 22, y: c.y - 7, width: 44, height: 14)
            NSColor(white: 0, alpha: 0.5).setFill()
            NSBezierPath(roundedRect: track, xRadius: 7, yRadius: 7).fill()
            let knob = NSRect(x: on ? track.maxX - 22 : track.minX, y: track.minY, width: 22, height: 14)
            NSGradient(colors: skin.colors.knob.map(\.ns))?.draw(in: NSBezierPath(roundedRect: knob, xRadius: 7, yRadius: 7), angle: -90)
            if on { Paint.lamp(CGPoint(x: track.maxX + 10, y: c.y), skin.colors.accent.ns) }
            Paint.label(name, centeredAt: CGPoint(x: c.x, y: track.minY - 10), skin)
        }
    }
}
