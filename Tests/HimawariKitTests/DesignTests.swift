import XCTest
@testable import HimawariKit

/// Beta 1.5: your own eras, as design files.
final class DesignFileTests: XCTestCase {
    private func decode(_ json: String) throws -> Design { try Design.decode(Data(json.utf8)) }

    private let minimal = """
    "left": [{"block": "display"}, {"block": "buttons"}, {"block": "wheel"}], "right": [{"block": "knobs"}]
    """

    func testTheExampleRoundTrips() throws {
        for design in Design.builtIn { XCTAssertEqual(try Design.decode(design.encoded()), design, design.id) }
    }

    func testDefaultsFillIn() throws {
        let d = try decode(#"{"format": 1, "id": "mine", "name": "Mine", "media": "card", "# + minimal + "}")
        XCTAssertEqual(d.left.map(\.kind), [.display, .buttons, .wheel])
        XCTAssertEqual(d.left[0].style, "vfd")
        XCTAssertEqual(d.left[0].height, 150)
        XCTAssertNil(d.left[2].height, "a wheel fills")
        XCTAssertEqual(d.media, .card)
    }

    func testEveryControlMustBeThere() {
        XCTAssertThrowsError(try decode(#"{"format": 1, "id": "x", "name": "X", "media": "cd", "left": [{"block": "display"}, {"block": "buttons"}], "right": [{"block": "knobs"}]}"#)) {
            XCTAssertEqual($0 as? SkinError, .badValue("left/right", "needs a wheel (for scrubbing)"))
        }
        XCTAssertThrowsError(try decode(#"{"format": 1, "id": "x", "name": "X", "media": "cd", "# + minimal.replacingOccurrences(of: #"[{"block": "knobs"}]"#, with: #"[{"block": "knobs"}, {"block": "knobs"}]"#) + "}")) {
            XCTAssertEqual($0 as? SkinError, .badValue("knobs", "only one knobs block, please"))
        }
    }

    func testBadBlocksAreNamed() {
        func rejects(_ left: String, _ error: SkinError) {
            let json = #"{"format": 1, "id": "x", "name": "X", "media": "cd", "left": "# + left + #", "right": [{"block": "knobs"}]}"#
            XCTAssertThrowsError(try decode(json)) { XCTAssertEqual($0 as? SkinError, error, left) }
        }
        rejects(#"[{"block": "jukebox"}]"#, .badValue("left[0].block", "one of " + Design.Block.Kind.allCases.map(\.rawValue).joined(separator: ", ")))
        rejects(#"[{"block": "display", "style": "neon"}]"#, .badValue("left[0].style", "one of vfd, lcd, glass, dial, hud"))
        rejects(#"[{"block": "grille", "style": "big"}]"#, .badValue("left[0].style", "this block has no styles"))
        rejects(#"[{"block": "display", "height": 900}]"#, .badValue("left[0].height", "a number from 8 to 400, or \"fill\""))
        rejects(#"[{"block": "display", "colour": "red"}]"#, .unknownKey("left[0].colour"))
        rejects(#"[]"#, .badValue("left", "between 1 and 12 blocks"))
        XCTAssertThrowsError(try decode(#"{"format": 1, "id": "x", "name": "X", "media": "8-track", "# + minimal + "}")) {
            XCTAssertEqual($0 as? SkinError, .badValue("media", "one of cd, record, cassette, discman, player, card, cartridge, hologram"))
        }
    }

    func testASkinWearsADesign() throws {
        let skin = try Skin.decode(Data(#"{"format": 1, "id": "mine", "name": "Mine", "era": "cassette", "design": "boombox"}"#.utf8))
        XCTAssertEqual(skin.design, "boombox")
        XCTAssertThrowsError(try Skin.decode(Data(#"{"format": 1, "id": "m", "name": "M", "era": "rack", "design": "Box!"}"#.utf8)))
        let library = SkinLibrary(folder: nil, designsFolder: nil)
        XCTAssertNotNil(library.design(id: "boombox"), "the example ships")
        XCTAssertEqual(library.skin(id: "boombox-black")?.design, "boombox")
    }
}
