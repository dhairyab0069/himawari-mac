import AppKit
import HimawariKit

/// The skins Himawari knows (built in, and from the skins folder) and the one in use.
@MainActor
final class Styles {
    static let shared = Styles()
    private(set) var library = SkinLibrary()
    private let defaults = UserDefaults.standard

    /// The look the side gear and the music scene use (Himawari menu ▸ Style).
    var current: Skin { library.skin(id: defaults.string(forKey: "gearSkin")) ?? .standard }

    func select(_ id: String) {
        guard library.skin(id: id) != nil else { return }
        defaults.set(id, forKey: "gearSkin")
    }

    /// Reads the skins folder again (Style ▸ Reload Skins), and refreshes its examples.
    func reload() {
        do { try SkinLibrary.writeExamples() } catch { Log.write("skins: couldn't write the examples: \(error.localizedDescription)") }
        library = SkinLibrary()
        for problem in library.problems { Log.write("skins: \(problem)") }
    }
}
