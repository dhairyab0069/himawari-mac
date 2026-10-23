import AppKit
import HimawariKit

/// `Himawari --render-styles <folder>`: draws the music scene (the side gear and the media in
/// the middle) once per skin, as PNGs, without touching the desktop. For checking a skin by eye
/// and for the docs' pictures.
@MainActor
enum StylePreview {
    static func run(_ arguments: [String]) -> Bool {
        guard let i = arguments.firstIndex(of: "--render-styles") else { return false }
        let folder = URL(fileURLWithPath: i + 1 < arguments.count ? arguments[i + 1] : ".")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let only = i + 2 < arguments.count ? arguments[i + 2] : nil // one skin's id, or all of them
        for skin in Styles.shared.library.skins where only == nil || skin.id == only {
            let url = folder.appending(path: "\(skin.id).png")
            render(skin, to: url)
            print(url.path)
        }
        return true
    }

    /// A made-up album cover: a sunset and a sun.
    static let artwork: NSImage = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { r in
        NSGradient(colors: [NSColor(red: 0.98, green: 0.55, blue: 0.3, alpha: 1), NSColor(red: 0.45, green: 0.2, blue: 0.55, alpha: 1)])?
            .draw(in: r, angle: -90)
        NSColor(red: 1, green: 0.85, blue: 0.4, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 190, y: 220, width: 220, height: 220)).fill()
        NSColor(red: 0.15, green: 0.08, blue: 0.2, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 600, height: 170).fill()
        return true
    }

    static func render(_ skin: Skin, to url: URL) {
        let frame = NSRect(x: 0, y: 0, width: 1470, height: 956)
        let scene = MusicScene(frame: frame, artwork: artwork, topInset: 33, bottomInset: 70)
        scene.lively = false
        scene.style = skin
        // In a window that's never shown: the side gear's layers join the scene's only in a window.
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = scene
        scene.setSong(SongInfo(title: "Golden Hour", artist: "Sample Artist", album: "Sunsets", duration: 215,
                               position: 83, playing: true), animating: false)
        RunLoop.main.run(until: Date().addingTimeInterval(1)) // the disc's print is made in the background
        let scale: CGFloat = 2
        guard let layer = scene.layer,
              let ctx = CGContext(data: nil, width: Int(frame.width * scale), height: Int(frame.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        window.close()
    }
}
