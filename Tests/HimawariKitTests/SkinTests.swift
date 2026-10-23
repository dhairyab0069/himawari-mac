import XCTest
@testable import HimawariKit

/// Beta 1.4: skin files (colours, materials, lettering, layout numbers) load, and bad ones are turned down.
final class SkinFileTests: XCTestCase {
    private func decode(_ json: String) throws -> Skin { try Skin.decode(Data(json.utf8)) }

    private func XCTAssertRejects(_ json: String, _ expected: SkinError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(json), file: file, line: line) { error in
            XCTAssertEqual(error as? SkinError, expected, file: file, line: line)
        }
    }

    func testBuiltInSkinsRoundTrip() throws {
        for skin in Skin.builtIn {
            XCTAssertEqual(try Skin.decode(skin.encoded()), skin, skin.id)
        }
    }

    func testEveryEraHasBuiltInSkinsAndIDsAreUnique() {
        for era in GearEra.allCases { XCTAssertGreaterThanOrEqual(Skin.builtIn.filter { $0.era == era }.count, 2, era.rawValue) }
        XCTAssertEqual(Set(Skin.builtIn.map(\.id)).count, Skin.builtIn.count)
        XCTAssertEqual(Skin.standard.id, "rack-black", "today's look stays the default")
    }

    func testASmallFileTakesTheRestFromItsBase() throws {
        let skin = try decode(##"{"format": 1, "id": "red-rack", "name": "Red Display", "era": "rack", "base": "rack-champagne", "colors": {"display": "#FF4A3D"}}"##)
        let base = Skin.builtIn.first { $0.id == "rack-champagne" }!
        XCTAssertEqual(skin.colors.display, SkinColor(hex: "#FF4A3D"))
        XCTAssertEqual(skin.colors.plate, base.colors.plate)
        XCTAssertEqual(skin.leftModel, base.leftModel)
        XCTAssertEqual(skin.id, "red-rack")
        XCTAssertEqual(skin.name, "Red Display")
    }

    func testWithoutABaseTheErasFirstSkinIsUsed() throws {
        let skin = try decode(##"{"format": 1, "id": "mine", "name": "Mine", "era": "cassette"}"##)
        XCTAssertEqual(skin.colors, Skin.builtIn.first { $0.era == .cassette }!.colors)
    }

    func testFontsCanGoBackToTheSystemFont() throws {
        let skin = try decode(##"{"format": 1, "id": "plain", "name": "Plain", "era": "hifi", "fonts": {"brand": null}}"##)
        XCTAssertNil(skin.brandFont)
    }

    func testBadFilesAreTurnedDown() {
        XCTAssertRejects("[1, 2]", .notJSON)
        XCTAssertRejects("{", .notJSON)
        XCTAssertRejects(##"{"id": "a", "name": "A", "era": "rack"}"##, .missing("format"))
        XCTAssertRejects(##"{"format": 2, "id": "a", "name": "A", "era": "rack"}"##, .unsupportedFormat)
        XCTAssertRejects(##"{"format": true, "id": "a", "name": "A", "era": "rack"}"##, .unsupportedFormat)
        XCTAssertRejects(##"{"format": 1, "name": "A", "era": "rack"}"##, .missing("id"))
        XCTAssertRejects(##"{"format": 1, "id": "Big Name", "name": "A", "era": "rack"}"##,
                         .badValue("id", "use lowercase letters, digits and dashes"))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "  ", "era": "rack"}"##, .badValue("name", "is empty"))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "A", "era": "1990s"}"##, .badValue("era", "one of hifi, cassette, portable, rack, pocket, minimal"))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "A", "era": "rack", "colour": {}}"##, .unknownKey("colour"))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "A", "era": "rack", "colors": {"dispaly": "#FFFFFF"}}"##, .unknownKey("colors.dispaly"))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "A", "era": "rack", "colors": {"display": "cyan"}}"##,
                         .badValue("colors.display", "colours are written #RRGGBB or #RRGGBBAA"))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "A", "era": "rack", "colors": {"plate": ["#000000", "#111111"]}}"##,
                         .badValue("colors.plate", "expected a list of 3 colours"))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "A", "era": "rack", "grain": 0.5}"##, .badValue("grain", "must be between 0 and 0.2"))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "A", "era": "rack", "layout": {"columnWidth": 900}}"##,
                         .badValue("layout.columnWidth", "must be between 200 and 360"))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "A", "era": "rack", "layout": {"corner": "8"}}"##,
                         .badValue("layout.corner", "expected a number"))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "A", "era": "rack", "base": "hifi-walnut"}"##,
                         .badValue("base", "\"hifi-walnut\" is a hifi skin"))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "A", "era": "rack", "base": "nope"}"##, .badValue("base", "no built-in skin \"nope\""))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "A", "era": "rack", "material": "velvet"}"##,
                         .badValue("material", "one of brushed, chrome, plastic, matte, neon, hud"))
        XCTAssertRejects(##"{"format": 1, "id": "a", "name": "A", "era": "rack", "brand": "AN EXTREMELY LONG BRAND NAME"}"##,
                         .badValue("brand", "longer than 20 characters"))
    }

    func testColours() {
        XCTAssertEqual(SkinColor(hex: "#FF8000"), SkinColor(1, 128 / 255, 0))
        XCTAssertEqual(SkinColor(hex: "#00000080")?.a ?? 0, 128 / 255, accuracy: 1e-9)
        XCTAssertNil(SkinColor(hex: "FF8000"))
        XCTAssertNil(SkinColor(hex: "#FF80"))
        XCTAssertNil(SkinColor(hex: "#GG8000"))
        XCTAssertEqual(SkinColor(hex: "#3B3B3BF7")?.hex, "#3B3B3BF7")
        XCTAssertEqual(SkinColor(hex: "#73F7FF")?.hex, "#73F7FF")
    }
}

final class SkinLibraryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "himawari-skins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func write(_ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: folder.appending(path: name))
    }

    func testTheFolderAddsReplacesAndReportsProblems() throws {
        try write("b-mine.json", ##"{"format": 1, "id": "zebra", "name": "Zebra", "era": "rack"}"##)
        try write("a-override.json", ##"{"format": 1, "id": "rack-black", "name": "My Black", "era": "rack"}"##)
        try write("broken.json", ##"{"format": 1, "id": "x", "name": "X", "era": "rack", "colors": {"display": "red"}}"##)
        try write("twin.json", ##"{"format": 1, "id": "zebra", "name": "Zebra 2", "era": "rack"}"##)
        try write("notes.txt", "not a skin")
        let library = SkinLibrary(folder: folder)
        XCTAssertEqual(library.skin(id: "rack-black")?.name, "My Black", "a file replaces the built-in skin with its id")
        XCTAssertEqual(library.skins(of: .rack).map(\.id), ["rack-black", "rack-champagne", "zebra"])
        XCTAssertEqual(library.skins.count, Skin.builtIn.count + 1)
        XCTAssertEqual(library.problems.count, 2)
        XCTAssertTrue(library.problems.contains { $0.hasPrefix("broken.json: \"colors.display\"") }, "\(library.problems)")
        XCTAssertTrue(library.problems.contains { $0.hasPrefix("twin.json:") }, "\(library.problems)")
    }

    func testNoFolderMeansTheBuiltInSkins() {
        let library = SkinLibrary(folder: folder.appending(path: "missing"))
        XCTAssertEqual(library.skins, Skin.builtIn)
        XCTAssertEqual(library.problems, [])
    }

    func testTheExamplesLoadBackButAreNotLoadedFromExamples() throws {
        try SkinLibrary.writeExamples(to: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "README.txt").path))
        for skin in Skin.builtIn {
            let data = try Data(contentsOf: folder.appending(path: "Examples/\(skin.id).json"))
            XCTAssertEqual(try Skin.decode(data), skin)
        }
        XCTAssertEqual(SkinLibrary(folder: folder).skins, Skin.builtIn, "Examples/ isn't read as skins")
    }
}
