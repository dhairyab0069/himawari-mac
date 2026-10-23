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
        // Between songs there's a moment with no cover: keep the last colours rather than flash uncoloured.
        if let cover { tint = Self.tint(of: cover) ?? tint }
        return current != before
    }

    // MARK: Watching the skins folder

    private var watchTimer: Timer?
    private var fingerprint = ""

    /// Calls `changed` (after reloading) whenever a skin file is added, removed or saved: edit a
    /// skin in any editor and the desktop follows within a couple of seconds, no Reload needed.
    func watch(_ changed: @escaping @MainActor () -> Void) {
        fingerprint = Self.fingerprint()
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            onMainActor {
                guard let self else { return }
                let now = Self.fingerprint()
                guard now != self.fingerprint else { return }
                self.fingerprint = now
                self.reload()
                Log.write("skins: the folder changed; reloaded (\(self.library.skins.count) skins)")
                changed()
            }
        }
        watchTimer?.tolerance = 1
    }

    /// The skin and design files and when each was last saved (Examples/ aside: Himawari writes those itself).
    private static func fingerprint() -> String {
        [SkinLibrary.folder, SkinLibrary.designsFolder].map { folder in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.lowercased().hasSuffix(".json") }.sorted().map { name in
                let date = (try? folder.appending(path: name).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return "\(name)@\(date.timeIntervalSince1970)"
            }.joined(separator: "|")
        }.joined(separator: "||")
    }

    /// Makes the folders and their examples, without reading them (the watcher picks up changes).
    func prepareFolders() {
        do { try SkinLibrary.writeExamples() } catch { Log.write("skins: couldn't write the examples: \(error.localizedDescription)") }
    }

    /// Reads the skins folder again (Style ▸ Reload Skins), and refreshes its examples.
    func reload() {
        do { try SkinLibrary.writeExamples() } catch { Log.write("skins: couldn't write the examples: \(error.localizedDescription)") }
        library = SkinLibrary()
        fingerprint = Self.fingerprint() // what's read now isn't a change to watch for
        for problem in library.problems { Log.write("skins: \(problem)") }
    }

    /// Saves a copy of `skin` as a new file in the skins folder for you to change, and returns it
    /// ("my-walnut", "my-walnut-2"…).
    func makeCopy(of skin: Skin) throws -> URL {
        var copy = skin
        let id = freeID("my-" + skin.id.replacingOccurrences(of: "my-", with: ""))
        copy.id = id
        copy.name = String(("My " + skin.name).prefix(40))
        try FileManager.default.createDirectory(at: SkinLibrary.folder, withIntermediateDirectories: true)
        let url = SkinLibrary.folder.appending(path: "\(id).json")
        try copy.encoded().write(to: url, options: .atomic)
        reload()
        return url
    }

    /// Starts your own era: a copy of the example design in the Designs folder, and a skin that
    /// wears it (in `skin`'s colours). Returns the design file, to open.
    func makeDesign(from skin: Skin) throws -> (design: URL, skin: String) {
        var design = Design.builtIn[0]
        let taken = { (id: String) in
            self.library.design(id: id) != nil || FileManager.default.fileExists(atPath: SkinLibrary.designsFolder.appending(path: "\(id).json").path)
        }
        design.id = Self.freeID("my-era", taken: taken)
        design.name = "My Era"
        try FileManager.default.createDirectory(at: SkinLibrary.designsFolder, withIntermediateDirectories: true)
        let file = SkinLibrary.designsFolder.appending(path: "\(design.id).json")
        try design.encoded().write(to: file, options: .atomic)
        var wearer = skin
        wearer.id = freeID(design.id)
        wearer.name = "My Era"
        wearer.design = design.id
        try FileManager.default.createDirectory(at: SkinLibrary.folder, withIntermediateDirectories: true)
        try wearer.encoded().write(to: SkinLibrary.folder.appending(path: "\(wearer.id).json"), options: .atomic)
        reload()
        return (file, wearer.id)
    }

    /// Copies a skin file someone shared into the skins folder, if it loads. Returns its name, or
    /// throws what's wrong with it.
    func importSkin(from url: URL) throws -> Skin {
        let data = try Data(contentsOf: url)
        guard data.count < 64 * 1024 else { throw SkinError.badValue(url.lastPathComponent, "is too big for a skin file") }
        var skin = try Skin.decode(data)
        // Never overwrite: a skin of yours, or a built-in one, with the same id keeps it; this one
        // gets a new id ("red-rack-2").
        let id = freeID(skin.id)
        let file = SkinLibrary.folder.appending(path: "\(id).json")
        try FileManager.default.createDirectory(at: SkinLibrary.folder, withIntermediateDirectories: true)
        if id == skin.id {
            try data.write(to: file, options: .atomic)
        } else {
            skin.id = id
            try skin.encoded().write(to: file, options: .atomic)
        }
        reload()
        guard let loaded = library.skin(id: id) else { throw SkinError.badValue(url.lastPathComponent, "didn't load") }
        return loaded
    }

    /// `id`, or `id-2`, `id-3`… : one no skin (built in, loaded or on disk) has, at most 40 characters.
    private func freeID(_ id: String) -> String {
        func taken(_ candidate: String) -> Bool {
            library.skin(id: candidate) != nil || Skin.builtIn.contains { $0.id == candidate }
                || FileManager.default.fileExists(atPath: SkinLibrary.folder.appending(path: "\(candidate).json").path)
        }
        return Self.freeID(id, taken: taken)
    }

    /// The first of `id`, `id-2`, `id-3`… not `taken`, kept to 40 characters (internal for the tests).
    nonisolated static func freeID(_ id: String, taken: (String) -> Bool) -> String {
        var candidate = String(id.prefix(40)), n = 2
        while taken(candidate) {
            let suffix = "-\(n)"
            candidate = String(id.prefix(40 - suffix.count)) + suffix
            n += 1
        }
        return candidate
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
