import AppKit
import HimawariKit

/// `Himawari --render-styles <folder> [skin id | all] [era | needles | leds | spectrum]`: draws the music scene (the side gear and the media in
/// the middle) once per skin, as PNGs, without touching the desktop. For checking a skin by eye
/// and for the docs' pictures.
@MainActor
enum StylePreview {
    static func run(_ arguments: [String]) -> Bool {
        if let i = arguments.firstIndex(of: "--render-customise"), i + 1 < arguments.count {
            _ = NSApplication.shared
            Styles.shared.reload()
            let customiser = StyleCustomiser()
            withExtendedLifetime(customiser) { customiser.snapshot(to: URL(fileURLWithPath: arguments[i + 1])) }
            return true
        }
        guard let i = arguments.firstIndex(of: "--render-styles") else { return false }
        if arguments.contains("--with-lyrics") { // the sample song's words, big on the desktop too
            NowPlayingSides.words = (Lyrics.parseLRC("[01:20.00]<01:20.00> Golden <01:21.50> hour, <01:23.00> slow <01:24.00> and <01:25.00> warm\n[01:27.00]The sky is ours tonight"), 0, .desktop)
        }
        let folder = URL(fileURLWithPath: i + 1 < arguments.count ? arguments[i + 1] : ".")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A skin (and a design) straight from files, not the folders: for the docs' step-by-step pictures.
        if let f = arguments.firstIndex(of: "--skin-file"), f + 1 < arguments.count {
            var library = Styles.shared.library
            if let d = arguments.firstIndex(of: "--design-file"), d + 1 < arguments.count,
               let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[d + 1])) {
                do { library.add(try Design.decode(data)) } catch { print("design: \(error)"); return true }
            }
            Styles.shared.use(library)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[f + 1])) else { print("can't read the skin"); return true }
            do {
                let skin = try Skin.decode(data)
                let url = folder.appending(path: "\(skin.id).png")
                render(skin, to: url)
                print(url.path)
            } catch { print("skin: \(error)") }
            return true
        }
        let only = i + 2 < arguments.count ? arguments[i + 2] : nil // one skin's id ("all": every one)…
        let meters = (i + 3 < arguments.count ? StyleOptions.Meters(rawValue: arguments[i + 3]) : nil) ?? .era // …with these meters
        for skin in Styles.shared.library.skins where only == nil || only == "all" || skin.id == only {
            let url = folder.appending(path: "\(skin.id)\(meters == .era ? "" : "-" + meters.rawValue).png")
            render(skin, meters: meters, to: url)
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

    static func render(_ skin: Skin, meters: StyleOptions.Meters = .era, to url: URL) {
        guard let image = image(skin, meters: meters, scale: 2),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// The music scene in `skin`, a sample song playing, its meters at a typical level: a
    /// 1470 × 956 point screen drawn at `scale` pixels a point.
    static func image(_ skin: Skin, meters: StyleOptions.Meters = .era, animation: StyleOptions.Animation = .reduced,
                      cover: NSImage? = nil, scale: CGFloat) -> CGImage? {
        let frame = NSRect(x: 0, y: 0, width: 1470, height: 956)
        MusicScene.printsInline = true
        Log.muted = true
        defer { MusicScene.printsInline = false; Log.muted = false }
        let scene = MusicScene(frame: frame, artwork: cover ?? artwork, topInset: 33, bottomInset: 70)
        scene.lively = false
        scene.animation = animation
        scene.meters = meters
        scene.style = skin
        // In a window that's never shown: the side gear's layers join the scene's only in a window.
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // ARC owns it (closing must not release it a second time)
        window.contentView = scene
        defer { window.close() }
        scene.setSong(SongInfo(title: "Golden Hour", artist: "Sample Artist", album: "Sunsets", duration: 215,
                               position: 83, playing: true), animating: false)
        // One pass of the window's display cycle: that's when the side gear's layers join the scene's.
        window.displayIfNeeded()
        CATransaction.flush()
        scene.showSampleLevels()
        guard let layer = scene.layer,
              let ctx = CGContext(data: nil, width: Int(frame.width * scale), height: Int(frame.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }
}
