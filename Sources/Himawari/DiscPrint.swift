import CoreGraphics
import Foundation
import HimawariKit

/// The album cover printed on a CD the way real printed discs are made: the artwork is laid
/// flat across the disc (not warped), cut to the disc's circle, and stops at the silver ring
/// around the hole. The pressed data tracks show faintly through the ink as fine concentric
/// rings, which is what makes it read as a disc rather than a round picture.
///
/// Like a disc designer would, it places the art so the center hole and silver ring land on
/// a calm part of the cover rather than on the title or a face: it measures where the detail
/// is and slides / slightly enlarges the art to keep the center clear.
///
/// Pure and thread-safe: made once per cover (and size) on a background queue, in about
/// 10 ms for a full-resolution disc.
enum DiscPrint {
    /// `side`: output size in pixels; `inner`: where the print stops, as a fraction of the radius.
    static func make(from cover: CGImage, side: Int, inner: Double) -> CGImage? {
        guard side > 8, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        // The cover, filling the disc, placed so the center stays clear of the busy parts.
        let place = placement(of: cover, inner: inner)
        var out = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = out.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space, bitmapInfo: bitmapInfo) else { return false }
            ctx.interpolationQuality = .high
            let scale = Double(side) / Double(min(cover.width, cover.height)) * place.zoom
            let w = Double(cover.width) * scale, h = Double(cover.height) * scale
            // `place.center` (a point on the cover, y down) lands on the disc's center.
            ctx.draw(cover, in: CGRect(x: Double(side) / 2 - place.center.x * w,
                                       y: Double(side) / 2 - (1 - place.center.y) * h, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // Cut to the ring (rim → silver ring) with soft edges, and press in the tracks.
        let c = Double(side) / 2
        let feather = 1.2 / c                    // about a pixel of antialiasing at each edge
        let trackPitch = Double(side) / 260      // ~130 visible tracks across the print
        out.withUnsafeMutableBufferPointer { o in
            DispatchQueue.concurrentPerform(iterations: side) { y in
                let dy = (Double(y) + 0.5) - c
                for x in 0..<side {
                    let dx = (Double(x) + 0.5) - c
                    let r = (dx * dx + dy * dy).squareRoot() / c
                    let i = (y * side + x) * 4
                    let coverage = min(max((1 - r) / feather, 0), 1) * min(max((r - inner) / feather, 0), 1)
                    if coverage == 0 {
                        o[i] = 0; o[i + 1] = 0; o[i + 2] = 0; o[i + 3] = 0
                        continue
                    }
                    // Tracks: a gentle ripple in brightness, a few percent deep.
                    let ripple = 1 - 0.035 * (0.5 + 0.5 * sin(r * c / trackPitch * 2 * .pi))
                    let k = coverage * ripple
                    for ch in 0..<3 { o[i + ch] = UInt8(Double(o[i + ch]) * k) }
                    o[i + 3] = UInt8(Double(o[i + 3]) * coverage) // premultiplied: color already scaled
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Where the art goes: which point of the cover (0…1, y down) sits under the disc's center,
    /// and how much it's enlarged (1 = the cover just fills the disc). Tries a range of spots
    /// and picks the one with the least detail (edges: text, faces) under the center ring,
    /// preferring to stay near the middle and not to enlarge.
    static func placement(of cover: CGImage, inner: Double) -> (center: CGPoint, zoom: Double) {
        guard let sample = FrameSampler(cover, side: 64) else { return (CGPoint(x: 0.5, y: 0.5), 1) }
        // Detail map: brightness gradient on a 48×48 grid.
        let n = 48
        var luma = [Double](repeating: 0, count: n * n)
        for y in 0..<n { for x in 0..<n { luma[y * n + x] = sample.luma((Double(x) + 0.5) / Double(n), (Double(y) + 0.5) / Double(n)) } }
        var edges = [Double](repeating: 0, count: n * n)
        for y in 1..<(n - 1) { for x in 1..<(n - 1) {
            let gx = luma[y * n + x + 1] - luma[y * n + x - 1], gy = luma[(y + 1) * n + x] - luma[(y - 1) * n + x]
            edges[y * n + x] = (gx * gx + gy * gy).squareRoot()
        } }
        let aspect = Double(cover.width) / Double(cover.height)
        var best = (center: CGPoint(x: 0.5, y: 0.5), zoom: 1.0, cost: Double.infinity)
        for zoom in stride(from: 1.0, through: 1.3, by: 0.05) {
            // The part of the cover the disc shows, in cover fractions.
            let shownW = min(1, 1 / aspect) / zoom, shownH = min(1, aspect) / zoom
            // The ring the hub covers (a little margin past the silver ring), in cover fractions.
            let hubX = inner * shownW / 2 * 1.15, hubY = inner * shownH / 2 * 1.15
            for gy in 0...10 { for gx in 0...10 {
                let cx = shownW / 2 + (1 - shownW) * Double(gx) / 10
                let cy = shownH / 2 + (1 - shownH) * Double(gy) / 10
                var covered = 0.0, cells = 0.0
                for y in 0..<n { for x in 0..<n {
                    let dx = ((Double(x) + 0.5) / Double(n) - cx) / hubX, dy = ((Double(y) + 0.5) / Double(n) - cy) / hubY
                    if dx * dx + dy * dy <= 1 { covered += edges[y * n + x]; cells += 1 }
                } }
                // Average detail under the ring, plus a price for moving and enlarging the art
                // (so a calm cover stays exactly as it is).
                let moved = hypot(cx - 0.5, cy - 0.5)
                let cost = covered / max(cells, 1) + 0.25 * moved + 0.3 * (zoom - 1)
                if cost < best.cost { best = (CGPoint(x: cx, y: cy), zoom, cost) }
            } }
        }
        return (best.center, best.zoom)
    }
}
