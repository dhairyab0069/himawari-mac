import AppKit
import HimawariKit
import QuartzCore

/// The colors along the video's edges, darkened: what the bars beside it glow with.
struct AmbientPalette: Equatable {
    /// Left top, left bottom, right top, right bottom: for bars at the sides.
    var sides: [SIMD3<Double>]
    /// Top left, top right, bottom left, bottom right: for bars above and below.
    var ends: [SIMD3<Double>]

    static let neutral = AmbientPalette(sides: Array(repeating: [0.12, 0.1, 0.14], count: 4),
                                        ends: Array(repeating: [0.12, 0.1, 0.14], count: 4))

    /// From the edges of a frame or an image.
    static func from(_ frame: FrameSampler) -> AmbientPalette {
        let e = 0.12
        func at(_ r: CGRect) -> SIMD3<Double> { mood(frame.average(r)) }
        return AmbientPalette(
            sides: [at(CGRect(x: 0, y: 0, width: e, height: 0.5)), at(CGRect(x: 0, y: 0.5, width: e, height: 0.5)),
                    at(CGRect(x: 1 - e, y: 0, width: e, height: 0.5)), at(CGRect(x: 1 - e, y: 0.5, width: e, height: 0.5))],
            ends: [at(CGRect(x: 0, y: 0, width: 0.5, height: e)), at(CGRect(x: 0.5, y: 0, width: 0.5, height: e)),
                   at(CGRect(x: 0, y: 1 - e, width: 0.5, height: e)), at(CGRect(x: 0.5, y: 1 - e, width: 0.5, height: e))])
    }

    /// Roughly how bright the glow looks, for the clock.
    var luma: Double {
        let all = sides + ends
        let mean = all.reduce(SIMD3<Double>(0, 0, 0), +) / Double(all.count)
        return FrameSampler.luma(mean) * 0.8
    }

    /// Keep the hue, a little richer, but dim, so the glow never competes with the video.
    private static func mood(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let color = NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let out = NSColor(hue: hue, saturation: min(1, saturation * 1.2),
                          brightness: 0.12 + min(brightness, 0.7) * 0.5, alpha: 1).usingColorSpace(.sRGB) ?? color
        return SIMD3(Double(out.redComponent), Double(out.greenComponent), Double(out.blueComponent))
    }

    func differs(from other: AmbientPalette) -> Bool {
        zip(sides + ends, other.sides + other.ends).contains { a, b in
            max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) > 0.04
        }
    }
}

/// Soft color blobs that drift very slowly in the bars beside the video, like the
/// background of Apple Music's full-screen player. Core Animation runs the drift in
/// the window server at a low frame rate, so it costs almost nothing.
final class AmbientLayer: CALayer {
    private let blobs: [CALayer] = (0..<4).map { _ in CALayer() }
    private let masks: [CALayer] = (0..<4).map { _ in CALayer() }

    /// A soft round falloff (opaque center → clear edge), drawn once; it shapes every blob.
    private static let softDot: CGImage? = {
        let side = 256
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                        colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0.5), CGColor(gray: 0, alpha: 0)] as CFArray,
                                        locations: [0, 0.45, 1]) else { return nil }
        let c = CGPoint(x: side / 2, y: side / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(side) / 2, options: [])
        return ctx.makeImage()
    }()
    private var palette = AmbientPalette.neutral
    private var sideways = true
    private var driftSize = CGSize.zero
    /// Off in Battery Saver: the colors stay, the motion stops.
    var animated = true { didSet { if animated != oldValue { restartDrift() } } }

    override init() {
        super.init()
        masksToBounds = true
        for (blob, mask) in zip(blobs, masks) {
            mask.contents = Self.softDot
            blob.mask = mask
            addSublayer(blob)
        }
        applyColors(animated: false)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// Places the blobs in the bars around `video` (both in this layer's coordinates, y up).
    func arrange(in bounds: CGRect, around video: CGRect) {
        frame = bounds
        let side = video.minX - bounds.minX > 1
        let leftX = (bounds.minX + video.minX) / 2, rightX = (video.maxX + bounds.maxX) / 2
        let topY = (video.maxY + bounds.maxY) / 2, bottomY = (bounds.minY + video.minY) / 2
        let centers: [CGPoint] = side
            ? [CGPoint(x: leftX, y: bounds.height * 0.72), CGPoint(x: leftX, y: bounds.height * 0.28),
               CGPoint(x: rightX, y: bounds.height * 0.72), CGPoint(x: rightX, y: bounds.height * 0.28)]
            : [CGPoint(x: bounds.width * 0.28, y: topY), CGPoint(x: bounds.width * 0.72, y: topY),
               CGPoint(x: bounds.width * 0.28, y: bottomY), CGPoint(x: bounds.width * 0.72, y: bottomY)]
        let diameter = side ? bounds.height * 0.95 : bounds.width * 0.55
        for (blob, center) in zip(blobs, centers) {
            blob.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            blob.mask?.frame = blob.bounds
            blob.position = center
        }
        let size = side ? CGSize(width: max(video.minX - bounds.minX, 40) * 0.35, height: bounds.height * 0.12)
                        : CGSize(width: bounds.width * 0.1, height: max(video.minY - bounds.minY, 20) * 0.6)
        if side != sideways || size != driftSize {
            sideways = side
            driftSize = size
            applyColors(animated: false)
            restartDrift()
        }
    }

    func show(_ palette: AmbientPalette) {
        guard palette.differs(from: self.palette) else { return }
        self.palette = palette
        applyColors(animated: true)
    }

    override var isHidden: Bool { didSet { if isHidden != oldValue { restartDrift() } } }

    private func applyColors(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 2.5 : 0)
        CATransaction.setDisableActions(!animated)
        let colors = sideways ? palette.sides : palette.ends
        for (blob, c) in zip(blobs, colors) {
            blob.backgroundColor = NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 0.95).cgColor
        }
        // Between and behind the blobs: the average, darker still. No pure black anywhere.
        let mean = colors.reduce(SIMD3<Double>(0, 0, 0), +) / Double(colors.count) * 0.55
        backgroundColor = NSColor(srgbRed: mean.x, green: mean.y, blue: mean.z, alpha: 1).cgColor
        CATransaction.commit()
    }

    private func restartDrift() {
        blobs.forEach { $0.removeAllAnimations() }
        guard animated, !isHidden, driftSize != .zero else { return }
        for (i, blob) in blobs.enumerated() {
            let sign: CGFloat = i % 2 == 0 ? 1 : -1
            let drift = CABasicAnimation(keyPath: "position")
            drift.byValue = NSValue(point: CGPoint(x: sign * driftSize.width, y: -sign * driftSize.height))
            drift.duration = 19 + Double(i) * 4.7 // unequal periods: the pattern never visibly repeats
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1
            breathe.toValue = 1.15 + 0.05 * Double(i % 2)
            breathe.duration = 23 + Double(i) * 3.1
            for animation in [drift, breathe] {
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animation.isRemovedOnCompletion = false
                // Moves this slow look the same at 12 fps as at 120, for a tenth of the work.
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
                blob.add(animation, forKey: animation.keyPath)
            }
        }
    }
}
