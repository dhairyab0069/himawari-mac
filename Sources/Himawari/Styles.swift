import AppKit
import HimawariKit

/// The skins Himawari knows (built in, and from the skins folder), the one chosen, and how the
/// look in use follows from it (Customise: a style for each genre, or the cover's colours).
@MainActor
final class Styles {
    static let shared = Styles()
    private(set) var library = SkinLibrary()
    private let defaults = UserDefaults.standard

    /// The style picked in the Style menu or the Customise window.
    /// (A skin file with a built-in's id replaces it here too, chosen or not.)
    var chosen: Skin {
        library.skin(id: defaults.string(forKey: "gearSkin") ?? Skin.standard.id) ?? library.skin(id: Skin.standard.id) ?? .standard
    }

    /// How the look follows the music, how much it moves, which meters it shows, its name.
    var options: StyleOptions {
        get { StyleOptions(dictionary: defaults.dictionary(forKey: "styleOptions")) }
        set { defaults.set(newValue.dictionary, forKey: "styleOptions") }
    }

    /// What's playing, as far as the look cares: its genre and its cover's colours.
    private(set) var genre: String?
    private(set) var tint: (display: SkinColor, accent: SkinColor)?

    /// The look the side gear and the music scene use now.
    var current: Skin { resolve(chosen, options: options) }

    /// `skin` as `options` dress it for the song playing: swapped for the genre's style, lit in
    /// the cover's colours, carrying your own name.
    func resolve(_ skin: Skin, options: StyleOptions) -> Skin {
        var skin = skin
        switch options.mode {
        case .pinned:
            break
        case .genre:
            let ids = Set(library.skins.map(\.id))
            if let id = GenreRule.skin(for: genre, rules: options.rules, available: ids), let picked = library.skin(id: id) { skin = picked }
        case .coverColours:
            if let tint {
                // Lit text on a dark display takes the cover's colour; a pale LCD or a glass pane keeps
                // its dark (or white) type, and only its accents change.
                let litDisplay = [.hifi, .cassette, .rack].contains(skin.era)
                if litDisplay { skin.colors.display = tint.display }
                skin.colors.accent = tint.accent
            }
        }
        if let brand = options.brand { skin.brand = brand }
        return skin
    }

    func select(_ id: String) {
        guard library.skin(id: id) != nil else { return }
        defaults.set(id, forKey: "gearSkin")
    }

    /// A new song (or its genre or cover arrived). True when the look changes.
    func follow(genre: String?, cover: NSImage?) -> Bool {
        let before = current
        self.genre = genre
        tint = cover.flatMap(Self.tint(of:))
        return current != before
    }

    /// Reads the skins folder again (Style ▸ Reload Skins), and refreshes its examples.
    func reload() {
        do { try SkinLibrary.writeExamples() } catch { Log.write("skins: couldn't write the examples: \(error.localizedDescription)") }
        library = SkinLibrary()
        for problem in library.problems { Log.write("skins: \(problem)") }
    }

    /// Saves a copy of `skin` as a new file in the skins folder for you to change, and returns it
    /// ("my-walnut", "my-walnut-2"…).
    func makeCopy(of skin: Skin) throws -> URL {
        var copy = skin
        let base = "my-" + skin.id.replacingOccurrences(of: "my-", with: "")
        var id = base, n = 2
        while library.skin(id: id) != nil || FileManager.default.fileExists(atPath: SkinLibrary.folder.appending(path: "\(id).json").path) {
            id = "\(base)-\(n)"; n += 1
        }
        copy.id = id
        copy.name = "My " + skin.name
        try FileManager.default.createDirectory(at: SkinLibrary.folder, withIntermediateDirectories: true)
        let url = SkinLibrary.folder.appending(path: "\(id).json")
        try copy.encoded().write(to: url, options: .atomic)
        reload()
        return url
    }

    /// Copies a skin file someone shared into the skins folder, if it loads. Returns its name, or
    /// throws what's wrong with it.
    func importSkin(from url: URL) throws -> Skin {
        let data = try Data(contentsOf: url)
        let skin = try Skin.decode(data)
        try FileManager.default.createDirectory(at: SkinLibrary.folder, withIntermediateDirectories: true)
        try data.write(to: SkinLibrary.folder.appending(path: "\(skin.id).json"), options: .atomic)
        reload()
        return skin
    }

    /// The cover's colours, from a small copy of it.
    private static func tint(of image: NSImage) -> (display: SkinColor, accent: SkinColor)? {
        let side = 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var samples: [SIMD3<Double>] = []
        for y in 0..<side {
            for x in 0..<side {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                samples.append([Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)])
            }
        }
        return CoverTint.colors(from: samples)
    }
}
