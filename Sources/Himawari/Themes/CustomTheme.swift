import AppKit
import HimawariKit

/// Your own era (a design file): each panel is its blocks stacked from the top, every block
/// drawn the way one of the eras draws it. Blocks with a height get it (squeezed a little on a
/// short screen); the ones that fill share what's left.
struct CustomTheme: GearTheme {
    let skin: Skin
    let design: Design
    var meters: StyleOptions.Meters = .era

    func left(size: CGSize) -> PanelFace { face(design.left, size: size, model: skin.leftModel) }
    func right(size: CGSize) -> PanelFace { face(design.right, size: size, model: skin.rightModel) }

    private static let gap: CGFloat = 14
    /// The least a filling block gets, before the others are squeezed to make room.
    private static let leastFill: CGFloat = 40

    /// Where each block goes in the column, top to bottom (internal for the tests).
    static func frames(_ blocks: [Design.Block], in column: CGRect) -> [CGRect] {
        let fixed = blocks.compactMap(\.height).map { CGFloat($0) }.reduce(0, +)
        let fillers = CGFloat(blocks.filter { $0.height == nil }.count)
        let gaps = gap * CGFloat(max(blocks.count - 1, 0))
        let room = column.height - gaps - fillers * leastFill
        let squeeze = fixed > 0 ? min(1, max(room, 0) / fixed) : 1
        let fill = fillers > 0 ? max(column.height - gaps - fixed * squeeze, 0) / fillers : 0
        var y = column.maxY
        return blocks.map { b in
            let h = b.height.map { CGFloat($0) * squeeze } ?? fill
            defer { y -= h + gap }
            return CGRect(x: column.minX, y: y - h, width: column.width, height: h)
        }
    }

    private func face(_ blocks: [Design.Block], size: CGSize, model: String) -> PanelFace {
        let column = GearLayout.column(size, skin)
        var face = PanelFace()
        face.glow = (0, 0)
        var draws: [() -> Void] = []
        for (block, r) in zip(blocks, Self.frames(blocks, in: column)) where r.height >= 4 {
            add(block, in: r, column: column, model: model, to: &face, draws: &draws)
        }
        let skin = skin
        face.draw = { size in
            Paint.faceplate(size, skin)
            draws.forEach { $0() }
        }
        return face
    }

    // MARK: The blocks

    private func add(_ block: Design.Block, in r: CGRect, column: CGRect, model: String, to face: inout PanelFace, draws: inout [() -> Void]) {
        let skin = skin
        switch block.kind {
        case .header:
            draws.append { Paint.header(CGRect(x: r.minX, y: r.maxY - 40, width: r.width, height: 40), brand: skin.brand, model: model, skin) }
        case .display:
            display(block.style, in: r, to: &face, draws: &draws)
        case .buttons:
            buttons(block.style, in: r, to: &face, draws: &draws)
        case .wheel:
            let labelRoom: CGFloat = block.label == nil ? 0 : 22
            let d = max(min(r.width - 40, r.height - labelRoom, 220), 30)
            let wheel = CGRect(x: r.midX - d / 2, y: r.minY + labelRoom + (r.height - labelRoom - d) / 2, width: d, height: d)
            switch block.style {
            case "ring":
                draws.append {
                    skin.colors.display.alpha(0.18).ns.setStroke()
                    let groove = NSBezierPath(ovalIn: wheel.insetBy(dx: 2, dy: 2))
                    groove.lineWidth = 2
                    groove.stroke()
                }
                face.rotors.append(RotorPart(frame: wheel, draw: { MinimalTheme.ringDot(diameter: $0, skin) }, spin: nil, isJog: true))
            case "clickwheel":
                draws.append { PocketTheme.clickWheel(wheel, skin) }
                face.rotors.append(RotorPart(frame: wheel, draw: { PocketTheme.touchDot(diameter: $0, skin) }, spin: nil, isJog: true))
            default:
                draws.append {
                    NSColor(white: 0, alpha: 0.45).setFill()
                    NSBezierPath(ovalIn: wheel.insetBy(dx: -5, dy: -5)).fill()
                }
                face.rotors.append(RotorPart(frame: wheel, draw: { Paint.wheel(diameter: $0, skin) }, spin: 9, isJog: true))
            }
            if let label = block.label {
                draws.append { Paint.label(label, centeredAt: CGPoint(x: wheel.midX, y: wheel.minY - 13), skin) }
            }
            face.controls[.jog] = wheel
        case .meters:
            let kind = meters != .era ? meters : StyleOptions.Meters(rawValue: block.style) ?? .needles
            let m = GearLayout.meters(kind, in: r, skin)
            draws.append(m.draw)
            face.needles += m.needles
            face.bars += m.bars
            face.fixtures += m.fixtures
        case .spectrum:
            let m = GearLayout.meters(.spectrum, in: r, skin)
            draws.append(m.draw)
            face.bars += m.bars
            face.fixtures += m.fixtures
        case .knobs:
            let big = max(min(56, r.width * 0.34, r.height - 24), 20), small = min(40, r.width * 0.24, big * 0.75)
            let y = r.minY + 20
            let knobs: [(control: GearControl, rect: CGRect)] = [
                (.bass, CGRect(x: r.minX + r.width * 0.18 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
                (.treble, CGRect(x: r.minX + r.width * 0.45 - small / 2, y: y + (big - small) / 2, width: small, height: small)),
                (.volume, CGRect(x: r.minX + r.width * 0.78 - big / 2, y: y, width: big, height: big))]
            let style = block.style
            draws.append {
                for k in knobs {
                    let name = k.control.knobName ?? ""
                    switch style {
                    case "flat": MinimalTheme.flatKnob(k.rect, label: name, skin)
                    case "touch": PocketTheme.touchKnob(k.rect, label: name, skin)
                    default: Paint.knob(k.rect, label: name, skin, pointer: false)
                    }
                }
            }
            face.knobs += knobs
            for (control, area) in GearLayout.grabAreas(knobs, within: r.insetBy(dx: -6, dy: -6)) { face.controls[control] = area }
        case .grille:
            let d = min(r.width - 10, r.height)
            let grille = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
            draws.append { PocketTheme.grille(grille, skin) }
            face.fixtures.append(grille)
        case .toggles:
            draws.append { if r.height >= 40 { HiFiTheme.toggles(r, skin) } }
        case .sliders:
            draws.append { CassetteTheme.sliders(r, count: 10, inset: 12, skin) }
            face.fixtures.append(r)
        case .power:
            draws.append { Paint.powerRow(CGRect(x: column.minX, y: r.minY - 4, width: column.width, height: r.height), skin) }
        case .spacer:
            break
        case .gamepad:
            draws.append { Self.gamepad(r, skin) }
            face.fixtures.append(r)
        }
    }

    /// The song, the time and the progress: a fluorescent display, an LCD, plain type on glass, or a
    /// receiver's tuning dial whose pointer travels through the song.
    private func display(_ style: String, in r: CGRect, to face: inout PanelFace, draws: inout [() -> Void]) {
        let skin = skin
        let inner = r.insetBy(dx: 14, dy: min(12, r.height * 0.08))
        let k = min(max(r.height / 164, 0.55), 1.2) // the type grows and shrinks with the display
        switch style {
        case "lcd": draws.append { PortableTheme.lcd(r, skin) }
        case "glass": break
        case "dial":
            draws.append {
                Paint.glass(r, skin, corner: 4)
            }
        default:
            draws.append { Paint.glass(r, skin) }
            face.meshes.append(r.insetBy(dx: 4, dy: 4))
            face.glow = (0.7, 3.5)
        }
        let (indicators, toggles) = GearLayout.indicators(at: CGPoint(x: inner.minX, y: inner.maxY - 11), width: inner.width, skin: skin, offset: .zero)
        var y = inner.maxY - 14
        func row(_ h: CGFloat) -> CGFloat { y -= h; return y }
        let timeH = 40 * k
        let time = CGRect(x: inner.minX - 2, y: row(timeH + 4), width: inner.width * 0.62, height: timeH + 6)
        face.texts += indicators + [
            TextPart(role: .time, frame: time, size: 34 * k, weight: .light, mono: true),
            TextPart(role: .total, frame: CGRect(x: inner.minX + inner.width * 0.6, y: time.minY + 6 * k, width: inner.width * 0.4, height: 15),
                     size: 12, weight: .medium, alpha: 0.6, mono: true, align: .right),
        ]
        face.controls.merge(toggles) { a, _ in a }
        // The progress: a pointer on a dial, a dot on a line, or segments lighting up.
        if style == "dial" {
            let scale = CGRect(x: inner.minX, y: r.minY + 8, width: inner.width, height: min(40, r.height * 0.26))
            let track = CGRect(x: scale.minX + 22, y: scale.minY + 2, width: scale.width - 30, height: scale.height - 4)
            draws.append { HiFiTheme.fmScale(scale, track: track, skin) }
            face.dialPointer = track
            face.controls[.progress] = CGRect(x: track.minX, y: scale.minY - 2, width: track.width, height: scale.height + 4)
            y = min(y, scale.maxY + 4 + 3 * 16 * k)
        } else {
            let line = CGRect(x: inner.minX, y: row(10 * k), width: inner.width, height: max(5 * k, 4))
            if style == "glass" {
                let track = line.insetBy(dx: 0, dy: -3)
                draws.append {
                    skin.colors.display.alpha(0.15).ns.setFill()
                    NSBezierPath(roundedRect: CGRect(x: track.minX, y: track.midY - 1.5, width: track.width, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
                }
                face.dialPointer = track
                face.dialDot = true
            } else {
                let segments = style == "lcd" ? 20 : 32, gap: CGFloat = style == "lcd" ? 3 : 2
                let w = (line.width - CGFloat(segments - 1) * gap) / CGFloat(segments)
                face.ladder = (0..<segments).map { CGRect(x: line.minX + CGFloat($0) * (w + gap), y: line.minY, width: w, height: line.height) }
                face.ladderGlow = style != "lcd"
            }
            face.controls[.progress] = line.insetBy(dx: 0, dy: -8)
            y -= 8
        }
        // Then the song, as far as there's room.
        for (role, size, weight, alpha) in [(TextPart.Role.title, 16.0, NSFont.Weight.bold, 1.0), (.artist, 12, .semibold, 0.8), (.album, 11, .regular, 0.5)] {
            let h = CGFloat(size) * k + 5
            guard y - h >= r.minY + (style == "dial" ? min(40, r.height * 0.26) + 10 : 4) else { break }
            face.texts.append(TextPart(role: role, frame: CGRect(x: inner.minX, y: row(h), width: inner.width, height: h),
                                       size: CGFloat(size) * k, weight: weight, alpha: CGFloat(alpha)))
            y -= 1
        }
        face.uppercaseSong = style != "glass"
    }

    /// A handheld's D-pad on the left and its two face buttons on the right (they're for show).
    static func gamepad(_ r: CGRect, _ skin: Skin) {
        let s = min(r.height - 8, r.width * 0.36)
        let pad = CGRect(x: r.minX + r.width * 0.06, y: r.midY - s / 2, width: s, height: s)
        let arm = s * 0.34
        let cross = NSBezierPath()
        cross.append(NSBezierPath(roundedRect: CGRect(x: pad.midX - arm / 2, y: pad.minY, width: arm, height: s), xRadius: 3, yRadius: 3))
        cross.append(NSBezierPath(roundedRect: CGRect(x: pad.minX, y: pad.midY - arm / 2, width: s, height: arm), xRadius: 3, yRadius: 3))
        NSColor(white: 0, alpha: 0.35).setFill()
        let shadow = cross.copy() as! NSBezierPath
        shadow.transform(using: AffineTransform(translationByX: 0, byY: -2)); shadow.fill()
        NSGradient(colors: skin.colors.button.map(\.ns))?.draw(in: cross, angle: -90)
        NSColor(white: 0, alpha: 0.25).setFill()
        NSBezierPath(ovalIn: CGRect(x: pad.midX - arm * 0.3, y: pad.midY - arm * 0.3, width: arm * 0.6, height: arm * 0.6)).fill()
        let d = min(s * 0.42, r.width * 0.16)
        for (i, name) in ["B", "A"].enumerated() { // A up and to the right of B, as on the real thing
            let c = CGPoint(x: r.maxX - r.width * 0.3 + CGFloat(i) * d * 1.25, y: r.midY - d * 0.35 + CGFloat(i) * d * 0.7)
            let b = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            NSColor(white: 0, alpha: 0.35).setFill()
            NSBezierPath(ovalIn: b.offsetBy(dx: 0, dy: -2)).fill()
            NSGradient(colors: skin.colors.button.map(\.ns))?.draw(in: NSBezierPath(ovalIn: b), relativeCenterPosition: NSPoint(x: -0.3, y: 0.4))
            Paint.label(name, centeredAt: CGPoint(x: c.x + d * 0.62, y: c.y - d * 0.62), skin, size: 8)
        }
    }

    /// The five transport buttons, in one of the eras' styles, with the play lamp above.
    private func buttons(_ style: String, in r: CGRect, to face: inout PanelFace, draws: inout [() -> Void]) {
        let skin = skin
        let h = min(r.height - 10, style == "round" ? 46 : 44)
        let row = CGRect(x: r.minX, y: r.minY, width: r.width, height: max(h, 16))
        let rects: [CGRect]
        if style == "round" {
            let d = min(row.height, (row.width - 4 * CGFloat(skin.layout.gap)) / 5)
            let step = (row.width - d) / 4
            rects = (0..<5).map { CGRect(x: row.minX + CGFloat($0) * step, y: row.minY, width: d, height: d) }
        } else {
            rects = GearLayout.buttons(5, in: row, gap: CGFloat(skin.layout.gap))
        }
        let symbols = ["backward.end.fill", "playpause.fill", "forward.end.fill", "stop.fill", "eject.fill"]
        draws.append {
            for (rect, name) in zip(rects, symbols) {
                switch style {
                case "keys": CassetteTheme.key(rect, symbol: name, skin)
                case "round": PortableTheme.rubberButton(rect, symbol: name, skin)
                case "flat": PocketTheme.flatButton(rect, symbol: name, skin)
                case "bare": Paint.symbol(name, in: rect, color: skin.colors.display.alpha(0.8).ns, size: 16)
                default: Paint.button(rect, symbol: name, skin)
                }
            }
        }
        if r.height >= rects[1].height + 10 {
            face.lamp = CGRect(x: rects[1].midX - 3, y: rects[1].maxY + 3, width: 6, height: 6)
        }
        for (control, rect) in zip([GearControl.previous, .playPause, .next, .stop, .eject], rects) { face.controls[control] = rect }
    }
}
