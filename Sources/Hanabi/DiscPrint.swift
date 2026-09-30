import CoreGraphics
import Foundation

/// The album cover printed onto a CD as a rosette: a log-polar (conformal) projection, which
/// keeps the art's proportions at every point, so text and faces stay readable instead of
/// smearing around the rim. The image's top sits at the rim, its bottom at the silver ring.
/// Keeping proportions over a whole ring takes a few copies around the disc (about six for
/// a square cover), each mirrored against its neighbours so there's no seam as it turns.
///
/// Pure and thread-safe: made once per cover (and size) on a background queue, a few tens
/// of milliseconds for a full-resolution disc.
enum DiscPrint {
    /// `side`: output size in pixels; `inner`: where the print stops, as a fraction of the radius.
    static func make(from cover: CGImage, side: Int, inner: Double) -> CGImage? {
        guard side > 8, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // The source, at a size that has enough detail for the disc (no need for more).
        let srcW = min(cover.width, side), srcH = min(cover.height, side)
        var src = [UInt8](repeating: 0, count: srcW * srcH * 4)
        let drawn = src.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: srcW, height: srcH, bitsPerComponent: 8,
                                      bytesPerRow: srcW * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cover, in: CGRect(x: 0, y: 0, width: srcW, height: srcH)) // memory row 0 = the image's top
            return true
        }
        guard drawn else { return nil }

        var out = [UInt8](repeating: 0, count: side * side * 4)
        let c = Double(side) / 2
        // Conformal: a copy spanning angle 2π/n covers radii rim → ring when
        // (2π/n) / ln(1/inner) = width / height. Round n to an even number for seamless mirroring.
        let logSpan = log(1 / inner)
        let ideal = 2 * Double.pi * Double(cover.height) / (Double(cover.width) * logSpan)
        let copies = max(2, Int((ideal / 2).rounded()) * 2)
        let maxX = Double(srcW - 1), maxY = Double(srcH - 1)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                // Rows are independent: spread them over the cores.
                DispatchQueue.concurrentPerform(iterations: side) { y in
                    let dy = c - (Double(y) + 0.5)
                    for x in 0..<side {
                        let dx = (Double(x) + 0.5) - c
                        let r = (dx * dx + dy * dy).squareRoot() / c
                        guard r >= inner - 0.004, r <= 1.004 else { continue } // outside the print: clear
                        // Which copy, and where across it (every other copy mirrored); radius on a log scale.
                        let t = (atan2(dx, dy) + .pi) / (2 * .pi) * Double(copies)
                        let k = min(Int(t), copies - 1)
                        let across = t - Double(k)
                        let u = k % 2 == 0 ? across : 1 - across
                        let v = min(max(log(1 / max(r, 1e-6)) / logSpan, 0), 1)
                        // Bilinear sample.
                        let fx = u * maxX, fy = v * maxY
                        let x0 = Int(fx), y0 = Int(fy)
                        let x1 = min(x0 + 1, srcW - 1), y1 = min(y0 + 1, srcH - 1)
                        let ax = fx - Double(x0), ay = fy - Double(y0)
                        let i00 = (y0 * srcW + x0) * 4, i10 = (y0 * srcW + x1) * 4
                        let i01 = (y1 * srcW + x0) * 4, i11 = (y1 * srcW + x1) * 4
                        let o0 = (y * side + x) * 4
                        for ch in 0..<4 {
                            let top = Double(s[i00 + ch]) * (1 - ax) + Double(s[i10 + ch]) * ax
                            let bottom = Double(s[i01 + ch]) * (1 - ax) + Double(s[i11 + ch]) * ax
                            o[o0 + ch] = UInt8(top * (1 - ay) + bottom * ay)
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
