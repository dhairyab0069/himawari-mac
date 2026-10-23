import AppKit
import HimawariKit

/// The 2000s rack (Himawari's first look): on the left a CD deck (a fluorescent display with
/// the song, time and progress, a disc tray, transport buttons, a jog wheel), on the right a
/// stereo analyzer (two analog VU meters, a spectrum display, knobs).
struct RackTheme: GearTheme {
    let skin: Skin
    var meters: StyleOptions.Meters = .era

    func left(size: CGSize) -> PanelFace {
        let column = GearLayout.column(size, skin)
        let colW = column.width
        let header = CGRect(x: column.minX, y: column.maxY - 40, width: colW, height: 40)
        let display = CGRect(x: column.minX, y: header.minY - 14 - 164, width: colW, height: 164)
        let tray = CGRect(x: column.minX, y: display.minY - 26 - 16, width: colW, height: 16)
        let row = CGRect(x: column.minX, y: tray.minY - 24 - 34, width: colW, height: 34)
        let buttons = GearLayout.buttons(5, in: row, gap: CGFloat(skin.layout.gap))
        let playLED = CGRect(x: buttons[1].midX - 3, y: buttons[1].maxY + 5, width: 6, height: 6)
        let space = row.minY - 70 - column.minY // leave room for the power row
        let d = max(min(colW - 40, space - 30, 190), 60)
        let jog = CGRect(x: column.midX - d / 2, y: column.minY + 60 + (space - d) / 2, width: d, height: d)

        var face = PanelFace()
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin)
            Paint.header(header, brand: skin.brand, model: skin.leftModel, skin)
            Paint.glass(display, skin)
            // Disc tray: a slot with a bevel, an eject label and a lit "DISC" lamp.
            let slot = NSBezierPath(roundedRect: tray, xRadius: 3, yRadius: 3)
            NSColor(white: 0.03, alpha: 1).setFill(); slot.fill()
            NSColor(white: 1, alpha: 0.14).setStroke(); slot.stroke()
            Paint.label("DISC", centeredAt: CGPoint(x: tray.maxX - 22, y: tray.minY - 9), skin)
            Paint.lamp(CGPoint(x: tray.maxX - 42, y: tray.minY - 9), skin.colors.accent.ns)
            Paint.label("OPEN / CLOSE", centeredAt: CGPoint(x: tray.minX + 34, y: tray.minY - 9), skin)
            let symbols = ["backward.end.fill", "playpause.fill", "forward.end.fill", "stop.fill", "eject.fill"]
            for (rect, name) in zip(buttons, symbols) { Paint.button(rect, symbol: name, skin) }
            Paint.powerRow(column, skin)
            NSColor(white: 0, alpha: 0.5).setFill() // the jog wheel's well
            NSBezierPath(ovalIn: jog.insetBy(dx: -5, dy: -5)).fill()
            Paint.label("JOG", centeredAt: CGPoint(x: jog.midX, y: jog.minY - 14), skin)
        }

        // The display's contents, over the drawn glass.
        let inner = display.insetBy(dx: 14, dy: 12)
        let (indicators, toggles) = GearLayout.indicators(at: CGPoint(x: inner.minX, y: inner.maxY - 11), width: inner.width, skin: skin, offset: .zero)
        face.texts = indicators + [
            TextPart(role: .time, frame: CGRect(x: inner.minX - 2, y: inner.maxY - 64, width: inner.width * 0.62, height: 48),
                     size: 40, weight: .light, mono: true),
            TextPart(role: .total, frame: CGRect(x: inner.minX + inner.width * 0.6, y: inner.maxY - 58, width: inner.width * 0.4, height: 15),
                     size: 12, weight: .medium, alpha: 0.6, mono: true, align: .right),
            TextPart(role: .title, frame: CGRect(x: inner.minX, y: inner.maxY - 104, width: inner.width, height: 20), size: 16, weight: .bold),
            TextPart(role: .artist, frame: CGRect(x: inner.minX, y: inner.maxY - 122, width: inner.width, height: 16),
                     size: 12, weight: .semibold, alpha: 0.8),
            TextPart(role: .album, frame: CGRect(x: inner.minX, y: inner.maxY - 138, width: inner.width, height: 15),
                     size: 11, weight: .regular, alpha: 0.5),
        ]
        let segments = 32, gap: CGFloat = 2
        let segW = (inner.width - CGFloat(segments - 1) * gap) / CGFloat(segments)
        face.ladder = (0..<segments).map { CGRect(x: inner.minX + CGFloat($0) * (segW + gap), y: inner.maxY - 78, width: segW, height: 6) }
        face.meshes = [display.insetBy(dx: 4, dy: 4)]
        face.lamp = playLED
        face.rotors = [RotorPart(frame: jog, draw: { Paint.wheel(diameter: $0, skin) }, spin: 9, isJog: true)]
        face.controls = toggles
        for (control, rect) in zip([GearControl.previous, .playPause, .next, .stop, .eject], buttons) { face.controls[control] = rect }
        face.controls[.progress] = CGRect(x: inner.minX, y: inner.maxY - 88, width: inner.width, height: 26)
        face.controls[.jog] = jog
        face.fixtures = [tray]
        return face
    }

    func right(size: CGSize) -> PanelFace {
        let column = GearLayout.column(size, skin)
        let colW = column.width
        let header = CGRect(x: column.minX, y: column.maxY - 40, width: colW, height: 40)
        let knobRow: CGFloat = 78
        let floor = column.minY + knobRow + 20 // the knobs and their labels are below this
        // Two meters and at least a 90-point spectrum must fit between the header and the knobs:
        // on a short screen the meters give way (they used to push the spectrum into the knobs).
        let meterH = max(min(colW * 0.52, 150, (header.minY - 14 - 12 - 24 - 90 - floor) / 2), 50)
        let m1 = CGRect(x: column.minX, y: header.minY - 14 - meterH, width: colW, height: meterH)
        let m2 = CGRect(x: column.minX, y: m1.minY - 12 - meterH, width: colW, height: meterH)
        let available = m2.minY - 24 - floor
        let glassH = max(min(available, 200), 90)
        let spectrumGlass = CGRect(x: column.minX, y: m2.minY - 24 - glassH, width: colW, height: glassH)
        let labels = CGRect(x: spectrumGlass.minX + 12, y: spectrumGlass.minY + 8, width: colW - 24, height: 10)
        let spectrum = CGRect(x: spectrumGlass.minX + 12, y: labels.maxY + 6, width: colW - 24, height: glassH - 34)
        let small = min(40, colW * 0.24), big = min(56, colW * 0.34) // smaller on a narrow panel
        let y = column.minY + 22
        let knobs: [(control: GearControl, rect: CGRect)] = [
            (.bass, CGRect(x: column.minX + colW * 0.18 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
            (.treble, CGRect(x: column.minX + colW * 0.45 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
            (.volume, CGRect(x: column.minX + colW * 0.78 - big / 2, y: y, width: big, height: big))]

        // The level meters: the era's two VU meters, or the kind chosen in Customise.
        let block = meters == .era ? nil
            : GearLayout.meters(meters, in: CGRect(x: m2.minX, y: m2.minY, width: colW, height: m1.maxY - m2.minY), skin)
        var face = PanelFace()
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin)
            Paint.header(header, brand: skin.brand, model: skin.rightModel, skin)
            if let block { block.draw() } else { for (i, m) in [m1, m2].enumerated() { Paint.vuFace(m, channel: i == 0 ? "L" : "R", skin) } }
            Paint.glass(spectrumGlass, skin)
            Paint.bandLabels(labels, skin.colors.display.alpha(0.45).ns)
            for k in knobs { Paint.knob(k.rect, label: k.control.knobName ?? "", skin, pointer: false) }
        }
        face.needles = block?.needles ?? [m1, m2]
        // Spectrum: fluorescent segment columns.
        let count = 10, segments = 14, colGap: CGFloat = 5
        let barW = (spectrum.width - CGFloat(count - 1) * colGap) / CGFloat(count)
        let colors = (0..<segments).map { ($0 >= segments - 3 ? skin.colors.accent : skin.colors.display).cg }
        face.bars = (0..<count).map { i in
            BarPart(source: .band(i), frame: CGRect(x: spectrum.minX + CGFloat(i) * (barW + colGap), y: spectrum.minY, width: barW, height: spectrum.height),
                    segments: segments, colors: colors, glow: skin.colors.display.cg)
        }
        face.bars += block?.bars ?? []
        face.meshes = [spectrumGlass.insetBy(dx: 4, dy: 4)]
        face.knobs = knobs
        face.controls = GearLayout.grabAreas(knobs, within: CGRect(origin: .zero, size: size))
        face.fixtures = (block?.fixtures ?? [m1, m2]) + [spectrumGlass]
        return face
    }
}
