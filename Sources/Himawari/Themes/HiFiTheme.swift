import AppKit
import HimawariKit

/// The 1970s hi-fi: on the left a stereo receiver (a backlit tuning dial whose red pointer
/// travels through the song, piano-key transport buttons, a big tuning knob that scrubs), on
/// the right its amplifier (two analog VU meters, selector switches, tone and volume knobs).
/// The record on the turntable is the music scene's (MusicScene).
struct HiFiTheme: GearTheme {
    let skin: Skin

    func left(size: CGSize) -> PanelFace {
        let column = GearLayout.column(size, skin)
        let colW = column.width
        let header = CGRect(x: column.minX, y: column.maxY - 40, width: colW, height: 40)
        let dial = CGRect(x: column.minX, y: header.minY - 14 - 184, width: colW, height: 184)
        let inner = dial.insetBy(dx: 14, dy: 12)
        let scale = CGRect(x: inner.minX, y: dial.minY + 10, width: inner.width, height: 40) // the printed FM scale
        let track = CGRect(x: scale.minX + 22, y: scale.minY + 2, width: scale.width - 30, height: scale.height - 4)
        let row = CGRect(x: column.minX, y: dial.minY - 30 - 38, width: colW, height: 38)
        let keys = GearLayout.buttons(5, in: row, gap: CGFloat(skin.layout.gap))
        let lamp = CGRect(x: keys[1].midX - 3, y: keys[1].maxY + 8, width: 6, height: 6)
        let space = row.minY - 70 - column.minY // above the power row
        let d = max(min(colW - 60, space - 34, 200), 56)
        let knob = CGRect(x: column.midX - d / 2, y: column.minY + 62 + (space - d) / 2, width: d, height: d)

        var face = PanelFace()
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin)
            Paint.header(header, brand: skin.brand, model: skin.leftModel, skin)
            Paint.glass(dial, skin, corner: 4)
            // The dial's backlight: warm in the middle, falling off to the ends.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: dial, xRadius: 4, yRadius: 4).addClip()
            NSGradient(colors: [skin.colors.display.alpha(0.2).ns, skin.colors.display.alpha(0).ns])?
                .draw(in: dial.insetBy(dx: -dial.width * 0.2, dy: -dial.height * 0.3), relativeCenterPosition: NSPoint(x: 0, y: -0.35))
            NSGraphicsContext.restoreGraphicsState()
            Self.fmScale(scale, track: track, skin)
            for (rect, name) in zip(keys, ["backward.end.fill", "playpause.fill", "forward.end.fill", "stop.fill", "eject.fill"]) {
                Self.pianoKey(rect, symbol: name, skin)
            }
            Paint.powerRow(column, skin)
            NSColor(white: 0, alpha: 0.45).setFill() // the knob's well
            NSBezierPath(ovalIn: knob.insetBy(dx: -6, dy: -6)).fill()
            Paint.label("TUNING", centeredAt: CGPoint(x: knob.midX, y: knob.minY - 16), skin)
        }
        let (indicators, toggles) = GearLayout.indicators(at: CGPoint(x: inner.minX, y: inner.maxY - 11), width: inner.width, skin: skin, offset: .zero)
        face.texts = indicators + [
            TextPart(role: .time, frame: CGRect(x: inner.minX - 1, y: inner.maxY - 50, width: inner.width * 0.6, height: 36),
                     size: 30, weight: .light, mono: true),
            TextPart(role: .total, frame: CGRect(x: inner.minX + inner.width * 0.6, y: inner.maxY - 44, width: inner.width * 0.4, height: 15),
                     size: 12, weight: .medium, alpha: 0.6, mono: true, align: .right),
            TextPart(role: .title, frame: CGRect(x: inner.minX, y: inner.maxY - 74, width: inner.width, height: 20), size: 15, weight: .bold),
            TextPart(role: .artist, frame: CGRect(x: inner.minX, y: inner.maxY - 91, width: inner.width, height: 16),
                     size: 11.5, weight: .semibold, alpha: 0.8),
            TextPart(role: .album, frame: CGRect(x: inner.minX, y: inner.maxY - 106, width: inner.width, height: 15),
                     size: 11, weight: .regular, alpha: 0.55),
        ]
        face.glow = (0.55, 4)
        face.dialPointer = track
        face.lamp = lamp
        face.rotors = [RotorPart(frame: knob, draw: { Paint.wheel(diameter: $0, skin) }, spin: nil, isJog: true)]
        face.controls = toggles
        for (control, rect) in zip([GearControl.previous, .playPause, .next, .stop, .eject], keys) { face.controls[control] = rect }
        // Along the pointer's track, so a click lands where the pointer would be.
        face.controls[.progress] = CGRect(x: track.minX, y: scale.minY - 2, width: track.width, height: scale.height + 4)
        face.controls[.jog] = knob
        return face
    }

    func right(size: CGSize) -> PanelFace {
        let column = GearLayout.column(size, skin)
        let colW = column.width
        let header = CGRect(x: column.minX, y: column.maxY - 40, width: colW, height: 40)
        let small = min(44, colW * 0.24), big = min(62, colW * 0.34) // smaller on a narrow panel
        let y = column.minY + 22
        let floor = y + big + 22 // the knobs and their labels are below this
        let switchesH: CGFloat = 64
        let meterH = max(min(colW * 0.5, 150, (header.minY - 14 - 12 - 28 - switchesH - floor) / 2), 50)
        let m1 = CGRect(x: column.minX, y: header.minY - 14 - meterH, width: colW, height: meterH)
        let m2 = CGRect(x: column.minX, y: m1.minY - 12 - meterH, width: colW, height: meterH)
        let gap = m2.minY - floor
        let switches = CGRect(x: column.minX, y: floor + max((gap - switchesH) / 2, 0), width: colW, height: min(switchesH, gap))
        let knobs: [(control: GearControl, rect: CGRect)] = [
            (.bass, CGRect(x: column.minX + colW * 0.17 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
            (.treble, CGRect(x: column.minX + colW * 0.45 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
            (.volume, CGRect(x: column.minX + colW * 0.79 - big / 2, y: y, width: big, height: big))]

        var face = PanelFace()
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin)
            Paint.header(header, brand: skin.brand, model: skin.rightModel, skin)
            for (i, m) in [m1, m2].enumerated() { Paint.vuFace(m, channel: i == 0 ? "L" : "R", skin) }
            if switches.height >= 40 { Self.toggles(switches, skin) }
            for k in knobs { Paint.knob(k.rect, label: k.control.knobName ?? "", skin, pointer: false) }
        }
        face.needles = [m1, m2]
        face.knobs = knobs
        face.controls = GearLayout.grabAreas(knobs, within: CGRect(origin: .zero, size: size))
        face.fixtures = [m1, m2]
        return face
    }

    // MARK: Drawing

    /// The FM scale printed on the dial glass: frequencies, ticks, the "FM" and "MHz".
    private static func fmScale(_ r: CGRect, track: CGRect, _ skin: Skin) {
        let ink = skin.colors.display.alpha(0.75).ns
        let faint = skin.colors.display.alpha(0.4).ns
        NSAttributedString(string: "FM", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .heavy), .foregroundColor: ink])
            .draw(at: NSPoint(x: r.minX, y: r.midY - 6))
        let numbers = [88, 92, 96, 100, 104, 108]
        for i in 0...40 { // ticks: long every 4 MHz, short every half
            let x = track.minX + track.width * CGFloat(i) / 40
            let long = i % 8 == 0
            (long ? ink : faint).setFill()
            NSRect(x: x - 0.5, y: track.minY, width: 1, height: long ? 9 : 5).fill()
        }
        for (i, n) in numbers.enumerated() {
            let s = NSAttributedString(string: "\(n)", attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .semibold), .foregroundColor: ink])
            let x = track.minX + track.width * CGFloat(i) / CGFloat(numbers.count - 1)
            s.draw(at: NSPoint(x: x - s.size().width / 2, y: track.minY + 11))
        }
        NSAttributedString(string: "MHz", attributes: [.font: NSFont.systemFont(ofSize: 7, weight: .bold), .foregroundColor: faint])
            .draw(at: NSPoint(x: track.maxX - 16, y: track.maxY - 8))
        faint.setFill()
        NSRect(x: track.minX, y: track.maxY - 1, width: track.width, height: 0.5).fill()
    }

    /// A long brushed key with a dark lip below it, like a receiver's function keys.
    private static func pianoKey(_ r: CGRect, symbol: String, _ skin: Skin) {
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: r.offsetBy(dx: 0, dy: -3), xRadius: 2, yRadius: 2).fill() // its shadow / lip
        let key = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
        NSGradient(colors: [skin.colors.button[0].ns, skin.colors.button[1].ns, skin.colors.button[0].mixed(skin.colors.button[1], 0.6).ns],
                   atLocations: [0, 0.7, 1], colorSpace: .sRGB)?.draw(in: key, angle: -90)
        NSColor(white: 0, alpha: 0.45).setStroke(); key.lineWidth = 0.8; key.stroke()
        NSColor(white: 1, alpha: 0.5).setFill()
        NSRect(x: r.minX + 2, y: r.maxY - 1.5, width: r.width - 4, height: 1).fill()
        Paint.symbol(symbol, in: r, color: Paint.markColor(on: skin.colors.button[0].mixed(skin.colors.button[1], 0.4)))
    }

    /// A row of bat-handle toggle switches (they're for show).
    private static func toggles(_ r: CGRect, _ skin: Skin) {
        let names = ["LOUDNESS", "MONO", "TAPE", "FILTER"]
        let up = [true, false, false, true]
        for (i, name) in names.enumerated() {
            let c = CGPoint(x: r.minX + r.width * (CGFloat(i) + 0.5) / CGFloat(names.count), y: r.midY + 6)
            NSGradient(colors: [skin.colors.knob[0].ns, skin.colors.knob[1].ns])?
                .draw(in: NSBezierPath(ovalIn: NSRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)), angle: -60) // the nut
            NSColor(white: 0, alpha: 0.6).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)).fill()
            // Seen from the front, the lever is foreshortened: short, tapering to its ball.
            let tip = CGPoint(x: c.x, y: c.y + (up[i] ? 12 : -12))
            let dir: CGFloat = up[i] ? 1 : -1
            let lever = NSBezierPath()
            lever.move(to: CGPoint(x: c.x - 2.2, y: c.y)); lever.line(to: CGPoint(x: c.x - 1.2, y: tip.y - dir * 2))
            lever.line(to: CGPoint(x: c.x + 1.2, y: tip.y - dir * 2)); lever.line(to: CGPoint(x: c.x + 2.2, y: c.y)); lever.close()
            NSColor(white: 0, alpha: 0.35).setFill()
            lever.transform(using: AffineTransform(translationByX: 1, byY: -1.5)); lever.fill() // its shadow
            lever.transform(using: AffineTransform(translationByX: -1, byY: 1.5))
            NSGradient(colors: [NSColor(white: 0.95, alpha: 1), NSColor(white: 0.62, alpha: 1)])?.draw(in: lever, angle: 0)
            NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: 0.6, alpha: 1)])?
                .draw(in: NSBezierPath(ovalIn: NSRect(x: tip.x - 3.5, y: tip.y - 3.5, width: 7, height: 7)), angle: -60)
            Paint.label(name, centeredAt: CGPoint(x: c.x, y: r.minY + 4), skin, size: 7)
        }
    }
}
