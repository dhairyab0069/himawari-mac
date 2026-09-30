import AppKit
import CoreVideo

/// How bright the wallpaper is, as an 8×8 grid over the screen (0 = black,
/// 1 = white), so things drawn on the desktop (the clock) can pick text that
/// stands out. Himawari measures its own video and broadcasts the grid; without
/// Himawari, the regular macOS wallpaper image is measured instead. No screen
/// recording is involved.
public enum WallpaperTone {
    public static let size = 8

    /// Average brightness of the part of `screen` covered by `rect` (AppKit screen coordinates).
    public static func brightness(of grid: [Double], under rect: NSRect, on screen: NSScreen) -> Double {
        let f = screen.frame
        let x0 = Int(((rect.minX - f.minX) / f.width * Double(size)).rounded(.down)).clamped(0, size - 1)
        let x1 = Int(((rect.maxX - f.minX) / f.width * Double(size)).rounded(.up)).clamped(1, size)
        // Grid rows run top → bottom; AppKit y runs bottom → top.
        let y0 = Int(((f.maxY - rect.maxY) / f.height * Double(size)).rounded(.down)).clamped(0, size - 1)
        let y1 = Int(((f.maxY - rect.minY) / f.height * Double(size)).rounded(.up)).clamped(1, size)
        var total = 0.0, count = 0.0
        for y in y0..<max(y1, y0 + 1) {
            for x in x0..<max(x1, x0 + 1) { total += grid[y * size + x]; count += 1 }
        }
        return count > 0 ? total / count : 0
    }

    // MARK: Measuring

    /// Brightness grid of an image shown filling a `screenAspect` (width/height) screen, cropped like the wallpaper.
    public static func grid(of image: CGImage, screenAspect: Double) -> [Double]? {
        guard let frame = FrameSampler(image) else { return nil }
        let imageAspect = Double(image.width) / Double(max(image.height, 1))
        // Screen position → image position, with "aspect fill" cropping.
        return reading(of: { u, v in
            let x = imageAspect > screenAspect ? 0.5 + (u - 0.5) * screenAspect / imageAspect : u
            let y = imageAspect > screenAspect ? v : 0.5 + (v - 0.5) * imageAspect / screenAspect
            return frame.luma(x, y)
        }, region: nil).grid
    }

    /// The regular macOS wallpaper's brightness grid (used when Himawari isn't running).
    @MainActor
    public static func systemWallpaperGrid(for screen: NSScreen) -> [Double]? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return grid(of: image, screenAspect: screen.frame.width / screen.frame.height)
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}

// MARK: - Clock ⇄ Himawari

/// The clock tells Himawari where it sits; Himawari answers with a reading of exactly what's
/// behind it (the video, the bars around it, the CD scene or a YouTube thumbnail), and
/// again whenever that changes. Without Himawari, the clock falls back to the plain grid.
public struct ToneReading: Sendable {
    public var grid: [Double]
    /// Average brightness right behind the clock (0…1), when Himawari knows where it is.
    public var focus: Double?
    /// How busy the picture is there (standard deviation of brightness, 0…0.5).
    public var spread: Double?

    public init(grid: [Double], focus: Double? = nil, spread: Double? = nil) {
        self.grid = grid; self.focus = focus; self.spread = spread
    }
}

extension WallpaperTone {
    private static let readingName = Notification.Name("local.dhairyabhatia.wallpaperTone.reading")
    private static let requestName = Notification.Name("local.dhairyabhatia.wallpaperTone.request")

    public static func post(_ reading: ToneReading) {
        var info: [String: Any] = ["grid": reading.grid.map { NSNumber(value: $0) }]
        if let focus = reading.focus { info["focus"] = NSNumber(value: focus) }
        if let spread = reading.spread { info["spread"] = NSNumber(value: spread) }
        DistributedNotificationCenter.default().postNotificationName(readingName, object: nil, userInfo: info,
                                                                    deliverImmediately: true)
    }

    @MainActor
    public static func observeReadings(_ block: @escaping @MainActor (ToneReading) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: readingName, object: nil, queue: .main) { note in
            let grid = (note.userInfo?["grid"] as? [NSNumber])?.map(\.doubleValue) ?? []
            let focus = (note.userInfo?["focus"] as? NSNumber)?.doubleValue
            let spread = (note.userInfo?["spread"] as? NSNumber)?.doubleValue
            onMainActor {
                if grid.count == size * size { block(ToneReading(grid: grid, focus: focus, spread: spread)) }
            }
        }
    }

    /// Clock → Himawari: "I'm here (fractions of the main screen, y down); what's behind me?"
    public static func requestReading(for region: CGRect) {
        DistributedNotificationCenter.default().postNotificationName(
            requestName, object: nil,
            userInfo: ["region": [region.minX, region.minY, region.width, region.height].map { NSNumber(value: $0) }],
            deliverImmediately: true)
    }

    @MainActor
    public static func onReadingRequest(_ block: @escaping @MainActor (CGRect) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: requestName, object: nil, queue: .main) { note in
            let v = (note.userInfo?["region"] as? [NSNumber])?.map(\.doubleValue) ?? []
            onMainActor { if v.count == 4 { block(CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) } }
        }
    }

    /// `rect` (AppKit screen coordinates) as fractions of `screen`, y running down.
    public static func fraction(of rect: NSRect, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: (rect.minX - f.minX) / f.width, y: (f.maxY - rect.maxY) / f.height,
                      width: rect.width / f.width, height: rect.height / f.height)
    }

    /// Brightness grid + the reading behind `region`, from a screen-space brightness function
    /// (u, v in 0…1 across and down the screen).
    public static func reading(of luma: (Double, Double) -> Double, region: CGRect?) -> ToneReading {
        var grid = [Double](repeating: 0, count: size * size)
        for cy in 0..<size {
            for cx in 0..<size {
                var sum = 0.0
                for sy in 0..<3 { for sx in 0..<3 {
                    sum += luma((Double(cx) + (Double(sx) + 0.5) / 3) / Double(size),
                                (Double(cy) + (Double(sy) + 0.5) / 3) / Double(size))
                } }
                grid[cy * size + cx] = sum / 9
            }
        }
        guard let region else { return ToneReading(grid: grid) }
        var values: [Double] = []
        for sy in 0..<10 { for sx in 0..<20 {
            values.append(luma(region.minX + (Double(sx) + 0.5) / 20 * region.width,
                               region.minY + (Double(sy) + 0.5) / 10 * region.height))
        } }
        let mean = values.reduce(0, +) / Double(values.count)
        let spread = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        return ToneReading(grid: grid, focus: mean, spread: spread)
    }
}

/// A small copy of a picture (a video frame or an image) to measure colors in.
public struct FrameSampler: Sendable {
    private let pixels: [UInt8] // BGRA, row 0 at the top
    public let width: Int, height: Int
    private let row: Int

    public init?(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        width = CVPixelBufferGetWidth(buffer); height = CVPixelBufferGetHeight(buffer); row = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return nil }
        pixels = [UInt8](UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: row * height))
    }

    public init?(_ image: CGImage, side: Int = 64) {
        width = side; height = side; row = side * 4
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side)) // memory row 0 = the image's top
            return true
        }
        guard drawn else { return nil }
        pixels = bytes
    }

    /// Color at (u, v), both 0…1, v running down.
    public func rgb(_ u: Double, _ v: Double) -> SIMD3<Double> {
        let x = min(max(Int(u * Double(width)), 0), width - 1), y = min(max(Int(v * Double(height)), 0), height - 1)
        let i = y * row + x * 4
        return SIMD3(Double(pixels[i + 2]), Double(pixels[i + 1]), Double(pixels[i])) / 255
    }

    public func luma(_ u: Double, _ v: Double) -> Double { Self.luma(rgb(u, v)) }

    /// Perceived brightness of a color (Rec. 709 weights), 0…1.
    public static func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// Average color over a region (fractions, v down), from an 8×8 set of samples.
    public func average(_ r: CGRect) -> SIMD3<Double> {
        var sum = SIMD3<Double>(0, 0, 0)
        for sy in 0..<8 { for sx in 0..<8 {
            sum += rgb(r.minX + (Double(sx) + 0.5) / 8 * r.width, r.minY + (Double(sy) + 0.5) / 8 * r.height)
        } }
        return sum / 64
    }
}
