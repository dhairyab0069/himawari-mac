import AppKit
import HimawariKit

/// The "hud" material and the tech blocks: a heads-up display's cut corners, grid, scan lines and
/// circuit traces; framed displays, outlined buttons, a turning reactor ring, segmented knobs and
/// lines of readout (Cyberpunk wears them).
@MainActor
extension Paint {
    /// A rectangle with its corners cut off at 45°.
    static func chamfer(_ r: CGRect, _ c: CGFloat) -> NSBezierPath {
        let c = min(c, r.width / 3, r.height / 3)
        let p = NSBezierPath()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.line(to: CGPoint(x: r.maxX - c, y: r.minY)); p.line(to: CGPoint(x: r.maxX, y: r.minY + c))
        p.line(to: CGPoint(x: r.maxX, y: r.maxY - c)); p.line(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.line(to: CGPoint(x: r.minX + c, y: r.maxY)); p.line(to: CGPoint(x: r.minX, y: r.maxY - c))
        p.line(to: CGPoint(x: r.minX, y: r.minY + c)); p.close()
        return p
    }

    /// Inside the faceplate: a faint grid, scan lines, and circuit traces running to the edges.
    static func hudTexture(_ r: CGRect, _ skin: Skin) {
        let grid = skin.colors.display.alpha(0.05).ns
        grid.setFill()
        for x in stride(from: r.minX, to: r.maxX, by: 18) { NSRect(x: x, y: r.minY, width: 0.6, height: r.height).fill() }
        for y in stride(from: r.minY, to: r.maxY, by: 18) { NSRect(x: r.minX, y: y, width: r.width, height: 0.6).fill() }
        NSColor(white: 0, alpha: 0.16).setFill()
        for y in stride(from: r.minY, to: r.maxY, by: 3) { NSRect(x: r.minX, y: y, width: r.width, height: 1).fill() }
        var rng = SeededRandom(seed: 2099)
        for _ in 0..<9 { // traces: right-angled runs ending in a pad
            var p = CGPoint(x: Bool.random(using: &rng) ? r.minX : r.maxX, y: .random(in: r.minY...r.maxY, using: &rng))
            let path = NSBezierPath()
            path.move(to: p)
            for step in 0..<3 {
                let len = CGFloat.random(in: 20...70, using: &rng)
                if step % 2 == 0 { p.x += p.x < r.midX ? len : -len } else { p.y += Bool.random(using: &rng) ? len : -len }
                path.line(to: p)
            }
            skin.colors.accent.alpha(0.16).ns.setStroke()
            path.lineWidth = 1
            path.stroke()
            skin.colors.accent.alpha(0.35).ns.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill()
        }
    }

    /// Over the faceplate: bracket marks at the corners, tick marks along the bottom, a serial number.
    static func hudTrim(_ r: CGRect, plate: NSBezierPath, _ skin: Skin) {
        let ink = skin.colors.display.alpha(0.55).ns
        ink.setStroke()
        let inset = r.insetBy(dx: 10, dy: 10), arm: CGFloat = 16
        for (corner, dx, dy) in [(CGPoint(x: inset.minX, y: inset.minY), 1.0, 1.0), (CGPoint(x: inset.maxX, y: inset.minY), -1.0, 1.0),
                                 (CGPoint(x: inset.minX, y: inset.maxY), 1.0, -1.0), (CGPoint(x: inset.maxX, y: inset.maxY), -1.0, -1.0)] {
            let b = NSBezierPath()
            b.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y)); b.line(to: corner); b.line(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            b.lineWidth = 1.4
            b.stroke()
        }
        for i in 0..<24 {
            let x = inset.minX + 26 + CGFloat(i) * (inset.width - 52) / 23
            NSRect(x: x, y: r.minY + 4, width: 1, height: i % 4 == 0 ? 5 : 2.5).fill()
        }
        NSAttributedString(string: "SYS//\(skin.id.uppercased().prefix(10))  ◢◤  REV 7.7", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 6.5, weight: .medium), .foregroundColor: skin.colors.label.alpha(0.45).ns])
            .draw(at: NSPoint(x: inset.minX + 22, y: inset.minY - 4))
    }

    /// A display framed like a HUD panel: cut corners, scan lines, brackets, a tab with its name.
    static func hudFrame(_ r: CGRect, _ skin: Skin, name: String = "AUDIO.SYS") {
        let shape = chamfer(r, 12)
        NSColor(white: 0, alpha: 0.55).setFill()
        chamfer(r.insetBy(dx: -2, dy: -2), 13).fill()
        NSGradient(colors: skin.colors.glass.map(\.ns))?.draw(in: shape, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(white: 0, alpha: 0.22).setFill()
        for y in stride(from: r.minY, to: r.maxY, by: 2.5) { NSRect(x: r.minX, y: y, width: r.width, height: 1).fill() }
        NSGradient(colors: [skin.colors.display.alpha(0.1).ns, skin.colors.display.alpha(0).ns])?
            .draw(in: r, relativeCenterPosition: NSPoint(x: -0.4, y: 0.5))
        NSGraphicsContext.restoreGraphicsState()
        skin.colors.display.alpha(0.6).ns.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        // The tab, top right, and a pulse of ticks bottom left.
        let tab = NSAttributedString(string: "◤ " + name, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .bold),
                                                                        .foregroundColor: skin.colors.accent.alpha(0.85).ns])
        let t = CGRect(x: r.maxX - tab.size().width - 18, y: r.maxY - 1, width: tab.size().width + 10, height: 10)
        skin.colors.accent.alpha(0.18).ns.setFill()
        chamfer(t.offsetBy(dx: -4, dy: -1), 3).fill()
        tab.draw(at: NSPoint(x: t.minX, y: t.minY))
        skin.colors.accent.alpha(0.7).ns.setFill()
        for i in 0..<6 { NSRect(x: r.minX + 14 + CGFloat(i) * 5, y: r.minY + 4, width: 3, height: CGFloat([3, 6, 4, 8, 5, 3][i])).fill() }
    }

    /// An outlined button with cut corners, its symbol lit.
    static func hudButton(_ r: CGRect, symbol: String, _ skin: Skin) {
        let shape = chamfer(r, min(8, r.height / 3))
        NSGradient(colors: skin.colors.button.map { $0.alpha(0.85).ns })?.draw(in: shape, angle: -90)
        skin.colors.display.alpha(0.55).ns.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        skin.colors.display.alpha(0.9).ns.setFill()
        NSRect(x: r.minX + 6, y: r.minY + 2, width: r.width * 0.3, height: 1.5).fill()
        Paint.symbol(symbol, in: r, color: skin.colors.display.ns, size: 12)
    }

    /// The reactor ring you turn to scrub: dashes round the rim, three arcs, a glowing core (the
    /// part that turns; it idles round slowly, like a radar).
    static func reactor(diameter d: CGFloat, _ skin: Skin) {
        let c = CGPoint(x: d / 2, y: d / 2)
        for i in 0..<60 { // the rim's dashes, every fifth one long
            let a = CGFloat(i) / 60 * 2 * .pi
            let r0 = d * (i % 5 == 0 ? 0.42 : 0.45), r1 = d * 0.49
            let t = NSBezierPath()
            t.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0)); t.line(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
            skin.colors.display.alpha(i % 5 == 0 ? 0.8 : 0.35).ns.setStroke()
            t.lineWidth = 1.2
            t.stroke()
        }
        for k in 0..<3 { // three arcs with gaps, and a marker on the first
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: d * 0.34, startAngle: CGFloat(k) * 120 + 10, endAngle: CGFloat(k) * 120 + 100)
            (k == 0 ? skin.colors.accent : skin.colors.display).alpha(0.75).ns.setStroke()
            arc.lineWidth = d * 0.035
            arc.stroke()
        }
        let inner = NSBezierPath()
        inner.appendArc(withCenter: c, radius: d * 0.24, startAngle: 200, endAngle: 520)
        skin.colors.display.alpha(0.4).ns.setStroke()
        inner.lineWidth = 1
        inner.stroke()
        NSGradient(colors: [skin.colors.display.alpha(0.9).ns, skin.colors.display.alpha(0.15).ns, skin.colors.display.alpha(0).ns],
                   atLocations: [0, 0.45, 1], colorSpace: .sRGB)?
            .draw(in: NSBezierPath(ovalIn: NSRect(x: c.x - d * 0.16, y: c.y - d * 0.16, width: d * 0.32, height: d * 0.32)), relativeCenterPosition: .zero)
        skin.colors.accent.ns.setFill() // the marker you can see turn
        NSBezierPath(ovalIn: NSRect(x: c.x + d * 0.34 - 3, y: c.y - 3, width: 6, height: 6)).fill()
    }

    /// A knob as a ring of lit segments around a dark core.
    static func hudKnob(_ r: CGRect, label name: String, _ skin: Skin) {
        let c = CGPoint(x: r.midX, y: r.midY)
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(ovalIn: r).fill()
        for i in 0..<20 {
            let a0 = 225 - CGFloat(i) * 13.5, a1 = a0 - 9
            let seg = NSBezierPath()
            seg.appendArc(withCenter: c, radius: r.width / 2 + 5, startAngle: a0, endAngle: a1, clockwise: true)
            skin.colors.display.alpha(i < 13 ? 0.75 : 0.2).ns.setStroke()
            seg.lineWidth = 3
            seg.stroke()
        }
        NSGradient(colors: skin.colors.knob.map(\.ns))?.draw(in: NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.1, dy: r.width * 0.1)), angle: -90)
        skin.colors.display.alpha(0.5).ns.setStroke()
        NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.1, dy: r.width * 0.1)).stroke()
        NSAttributedString(string: name, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .bold),
                                                      .foregroundColor: skin.colors.label.ns])
            .draw(at: NSPoint(x: r.midX - NSAttributedString(string: name, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .bold)]).size().width / 2,
                              y: r.minY - 18))
    }

    /// Lines of system readout and little bar graphs (for show).
    static func readout(_ r: CGRect, _ skin: Skin) {
        var rng = SeededRandom(seed: UInt64(abs(Int(r.minY * 7 + r.height))))
        let font = NSFont.monospacedSystemFont(ofSize: 7.5, weight: .medium)
        var y = r.maxY - 11
        let codes = ["SYNC", "BPM", "NEURAL", "BUFFER", "LINK", "DSP", "CRC", "LAT"]
        while y > r.minY + 2 {
            let key = codes.randomElement(using: &rng)!
            let hex = String(format: "0x%04X", Int.random(in: 0...0xFFFF, using: &rng))
            let level = Int.random(in: 2...9, using: &rng)
            let line = NSAttributedString(string: "\(key.padding(toLength: 7, withPad: " ", startingAt: 0)) \(hex)  ", attributes: [
                .font: font, .foregroundColor: skin.colors.display.alpha(0.55).ns])
            line.draw(at: NSPoint(x: r.minX + 2, y: y))
            let barX = r.minX + line.size().width + 4
            for i in 0..<10 {
                (i < level ? (i >= 8 ? skin.colors.accent : skin.colors.display).alpha(0.7) : skin.colors.display.alpha(0.12)).ns.setFill()
                NSRect(x: barX + CGFloat(i) * 6, y: y + 2, width: 4, height: 6).fill()
            }
            y -= 12
        }
    }
}
