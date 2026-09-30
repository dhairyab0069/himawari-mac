// Draws the Himawari app icon (a sunflower, ひまわり, against a summer sky) and writes a 1024×1024 PNG.
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

// macOS icon grid: 824×824 body, 100 px margin, rounded corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0, 0, 0, 0.4))
ctx.addPath(shape); ctx.setFillColor(rgb(40, 110, 200)); ctx.fillPath()
ctx.restoreGState()

// Summer sky: deep blue at the top to a warm pale blue at the horizon.
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let sky = CGGradient(colorsSpace: space, colors: [rgb(38, 104, 206), rgb(92, 170, 236), rgb(186, 226, 250)] as CFArray,
                     locations: [0, 0.6, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// A soft sun-glow behind the flower.
let glow = CGGradient(colorsSpace: space, colors: [rgb(255, 244, 200, 0.75), rgb(255, 244, 200, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 530), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 530), endRadius: 430, options: [])

let center = CGPoint(x: 512, y: 530)

// Petals: two rings, the back ring deeper orange and offset half a petal.
func petal(angle: CGFloat, length: CGFloat, width: CGFloat, base: CGFloat, colors: [CGColor]) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: base))
    p.addQuadCurve(to: CGPoint(x: 0, y: base + length), control: CGPoint(x: width, y: base + length * 0.55))
    p.addQuadCurve(to: CGPoint(x: 0, y: base), control: CGPoint(x: -width, y: base + length * 0.55))
    ctx.addPath(p)
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: base), end: CGPoint(x: 0, y: base + length), options: [])
    ctx.restoreGState()
}
let petals = 18
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(90, 50, 0, 0.35))
for i in 0..<petals {
    let a = CGFloat(i) / CGFloat(petals) * 2 * .pi + .pi / CGFloat(petals)
    petal(angle: a, length: 250, width: 70, base: 110, colors: [rgb(236, 150, 20), rgb(250, 190, 40)])
}
for i in 0..<petals {
    let a = CGFloat(i) / CGFloat(petals) * 2 * .pi
    petal(angle: a, length: 235, width: 64, base: 110, colors: [rgb(248, 180, 30), rgb(255, 222, 70)])
}
ctx.restoreGState()

// The seed disc: dark brown, with seeds on the golden-angle spiral real sunflowers grow.
let discR: CGFloat = 150
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: rgb(40, 20, 0, 0.5))
let disc = CGGradient(colorsSpace: space, colors: [rgb(120, 70, 25), rgb(70, 38, 12), rgb(45, 24, 8)] as CFArray,
                      locations: [0, 0.6, 1])!
ctx.addEllipse(in: CGRect(x: center.x - discR, y: center.y - discR, width: 2 * discR, height: 2 * discR))
ctx.clip()
ctx.drawRadialGradient(disc, startCenter: CGPoint(x: center.x - 30, y: center.y + 40), startRadius: 0,
                       endCenter: center, endRadius: discR, options: [.drawsAfterEndLocation])
ctx.restoreGState()
let golden = CGFloat.pi * (3 - sqrt(5))
for n in 0..<260 {
    let r = discR * 0.93 * sqrt(CGFloat(n) / 260)
    let a = CGFloat(n) * golden
    let p = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    let s = 3.5 + 4.5 * r / discR
    ctx.setFillColor(n % 3 == 0 ? rgb(150, 95, 35, 0.9) : rgb(30, 15, 5, 0.85))
    ctx.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
}

// Gloss across the top of the tile.
let gloss = CGGradient(colorsSpace: space, colors: [rgb(255, 255, 255, 0.28), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 620), options: [])
ctx.restoreGState()

// A thin light edge on the tile.
ctx.addPath(shape); ctx.setStrokeColor(rgb(255, 255, 255, 0.25)); ctx.setLineWidth(3); ctx.strokePath()

NSGraphicsContext.current = nil
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
