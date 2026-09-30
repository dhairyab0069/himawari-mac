// Draws the Hanabi app icon (a firework over a night sky) and writes a 1024×1024 PNG.
// Usage: swift tools/make_icon.swift out.png      (build.sh turns it into AppIcon.icns)
import AppKit

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r/255, green: g/255, blue: b/255, alpha: a) }

// Deterministic "random" so the icon is identical on every build.
var seed: UInt64 = 0x48414E414249
func rand() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }

// macOS icon grid: 824×824 body, 100 px margin, rounded corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0, 0, 0, 0.45))
ctx.addPath(shape); ctx.setFillColor(rgb(10, 10, 30)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// Night sky: indigo at the top fading to near-black.
let sky = CGGradient(colorsSpace: space, colors: [rgb(38, 28, 96), rgb(14, 12, 44), rgb(4, 5, 16)] as CFArray,
                     locations: [0, 0.55, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Stars.
for _ in 0..<70 {
    let p = CGPoint(x: 100 + rand() * 824, y: 100 + rand() * 824)
    let r = 1.2 + rand() * 2.4
    ctx.setFillColor(rgb(255, 255, 255, 0.25 + rand() * 0.5))
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
}

let center = CGPoint(x: 512, y: 572)

// Warm glow behind the burst.
let glow = CGGradient(colorsSpace: space, colors: [rgb(255, 170, 90, 0.55), rgb(255, 80, 140, 0.18), rgb(255, 80, 140, 0)] as CFArray,
                      locations: [0, 0.45, 1])!
ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 360, options: [])

// Launch trail rising from the bottom.
ctx.setLineCap(.round)
for i in 0..<14 {
    let t = CGFloat(i) / 14
    let y = 170 + t * (center.y - 250)
    ctx.setFillColor(rgb(255, 210, 150, 0.12 + 0.5 * t))
    let r = 3 + 5 * t
    ctx.fillEllipse(in: CGRect(x: 512 - r + sin(t * 9) * 3, y: y - r, width: 2 * r, height: 2 * r))
}

/// One ring of the burst: `count` sparks flying out to `radius`, each a fading trail plus a glowing head.
func ring(count: Int, radius: CGFloat, width: CGFloat, color: (CGFloat, CGFloat, CGFloat), twist: CGFloat) {
    for i in 0..<count {
        let a = twist + CGFloat(i) / CGFloat(count) * 2 * .pi + (rand() - 0.5) * 0.08
        let dir = CGPoint(x: cos(a), y: sin(a))
        let radius = radius * (0.88 + rand() * 0.2) // uneven lengths look like a real burst
        let droop = radius * 0.08 // gravity pulls the ends down a little
        let head = CGPoint(x: center.x + dir.x * radius, y: center.y + dir.y * radius - droop)
        // Trail: segments getting brighter towards the head.
        let steps = 12
        for s in 0..<steps {
            let t0 = 0.28 + 0.72 * CGFloat(s) / CGFloat(steps), t1 = 0.28 + 0.72 * CGFloat(s + 1) / CGFloat(steps)
            ctx.setStrokeColor(rgb(color.0, color.1, color.2, 0.15 + 0.85 * t1))
            ctx.setLineWidth(width * (0.35 + 0.65 * t1))
            ctx.move(to: CGPoint(x: center.x + dir.x * radius * t0, y: center.y + dir.y * radius * t0 - droop * t0 * t0))
            ctx.addLine(to: CGPoint(x: center.x + dir.x * radius * t1, y: center.y + dir.y * radius * t1 - droop * t1 * t1))
            ctx.strokePath()
        }
        // Glowing head.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: width * 2.2, color: rgb(color.0, color.1, color.2, 1))
        ctx.setFillColor(rgb((255 + color.0) / 2, (255 + color.1) / 2, (255 + color.2) / 2)) // pale tint of the ray
        let r = width * 0.6
        ctx.fillEllipse(in: CGRect(x: head.x - r, y: head.y - r, width: 2 * r, height: 2 * r))
        ctx.restoreGState()
    }
}
ring(count: 18, radius: 300, width: 13, color: (255, 196, 84), twist: 0)            // gold, outer
ring(count: 14, radius: 205, width: 12, color: (255, 92, 150), twist: .pi / 14)     // pink
ring(count: 10, radius: 115, width: 11, color: (255, 140, 70), twist: .pi / 10)     // orange, inner

// Bright core.
let core = CGGradient(colorsSpace: space, colors: [rgb(255, 255, 245), rgb(255, 220, 160, 0.8), rgb(255, 180, 120, 0)] as CFArray,
                      locations: [0, 0.4, 1])!
ctx.drawRadialGradient(core, startCenter: center, startRadius: 0, endCenter: center, endRadius: 62, options: [])

// Scattered sparkles.
for _ in 0..<26 {
    let a = rand() * 2 * .pi, d = 120 + rand() * 250
    let p = CGPoint(x: center.x + cos(a) * d, y: center.y + sin(a) * d)
    let r = 2 + rand() * 3
    ctx.setFillColor(rgb(255, 235, 200, 0.4 + rand() * 0.5))
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
}

// Subtle top highlight for depth.
let shine = CGGradient(colorsSpace: space, colors: [rgb(255, 255, 255, 0.10), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 620), options: [])
ctx.restoreGState()

// Thin inner border.
ctx.addPath(shape); ctx.setStrokeColor(rgb(255, 255, 255, 0.12)); ctx.setLineWidth(3); ctx.strokePath()

NSGraphicsContext.current = nil
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
