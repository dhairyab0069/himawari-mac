import XCTest
@testable import HimawariKit

/// Beta 1.4.5: looks that follow the genre, the cover's colours, and the Customise window's choices.
final class GenreRuleTests: XCTestCase {
    let all = Set(Skin.builtIn.map(\.id))
    func pick(_ genre: String?) -> String? { GenreRule.skin(for: genre, rules: GenreRule.defaults, available: all) }

    func testCatalogGenresFindTheirEra() {
        XCTAssertEqual(pick("Hip-Hop/Rap"), "rack-black")
        XCTAssertEqual(pick("R&B/Soul"), "rack-champagne", "R&B, not the soul rule")
        XCTAssertEqual(pick("Jazz"), "hifi-walnut")
        XCTAssertEqual(pick("Hard Rock"), "hifi-silver")
        XCTAssertEqual(pick("Synth-Pop"), "cassette-metal", "the synth rule comes before pop")
        XCTAssertEqual(pick("K-Pop"), "pocket-blue")
        XCTAssertEqual(pick("Pop"), "pocket-white")
        XCTAssertEqual(pick("Electronic"), "minimal-dark")
        XCTAssertEqual(pick("Alternative"), "portable-clear")
        XCTAssertEqual(pick("Soundtrack"), "minimal-frosted")
    }

    func testWordsNotLetters() {
        XCTAssertNil(pick("Trapeze Music"), "\"rap\" isn't a word in it")
        XCTAssertNil(pick("Comedy"))
        XCTAssertNil(pick(nil))
        XCTAssertNil(pick(""))
    }

    func testYourRulesComeFirstAndMissingSkinsAreSkipped() {
        let rules = [GenreRule(genre: "pop", skin: "my-gone"), GenreRule(genre: "pop", skin: "hifi-walnut")]
        XCTAssertEqual(GenreRule.skin(for: "Pop", rules: rules, available: all), "hifi-walnut")
        XCTAssertNil(GenreRule.skin(for: "Pop", rules: [GenreRule(genre: " ", skin: "rack-black")], available: all), "an empty rule matches nothing")
    }

    func testEveryDefaultRulePointsAtABuiltInSkin() {
        for rule in GenreRule.defaults { XCTAssertTrue(all.contains(rule.skin), rule.genre) }
    }
}

final class StyleOptionsTests: XCTestCase {
    func testChoicesRoundTrip() {
        var o = StyleOptions()
        o.mode = .genre
        o.animation = .still
        o.meters = .leds
        o.brand = "DHAIRYA"
        o.rules = [GenreRule(genre: "phonk", skin: "cassette-black")]
        XCTAssertEqual(StyleOptions(dictionary: o.dictionary), o)
        // Through the preferences' own format, as UserDefaults stores it.
        let plist = try! PropertyListSerialization.data(fromPropertyList: o.dictionary, format: .binary, options: 0)
        let back = try! PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        XCTAssertEqual(StyleOptions(dictionary: back), o)
    }

    func testNothingSavedOrNonsenseGivesTheDefaults() {
        XCTAssertEqual(StyleOptions(dictionary: nil), StyleOptions())
        let o = StyleOptions(dictionary: ["mode": "sideways", "animation": 3, "meters": "lasers", "rules": "no"])
        XCTAssertEqual(o, StyleOptions())
        XCTAssertEqual(StyleOptions().rules, GenreRule.defaults)
    }

    func testTheNameIsTidied() {
        XCTAssertNil(StyleOptions.cleanBrand("   "))
        XCTAssertEqual(StyleOptions.cleanBrand("  sunflower  "), "sunflower")
        XCTAssertEqual(StyleOptions.cleanBrand(String(repeating: "x", count: 40))?.count, 20)
    }
}

final class CoverTintTests: XCTestCase {
    func testGreysGiveNoTint() {
        XCTAssertNil(CoverTint.colors(from: [[0.1, 0.1, 0.1], [0.5, 0.5, 0.5], [0.9, 0.9, 0.9]]))
    }

    func testTheMostVividColourLightsTheDisplay() {
        let samples: [SIMD3<Double>] = [[0.5, 0.5, 0.5], [0.9, 0.1, 0.1], [0.6, 0.3, 0.3], [0.1, 0.2, 0.8]]
        let tint = CoverTint.colors(from: samples)!
        XCTAssertGreaterThan(tint.display.r, tint.display.b, "red")
        XCTAssertEqual(max(tint.display.r, tint.display.g, tint.display.b), 1, accuracy: 1e-9, "lit: full brightness")
        XCTAssertGreaterThan(tint.accent.b, tint.accent.r, "the accent is the other hue, blue")
    }

    func testOneHueStillGetsAContrastingAccent() {
        let tint = CoverTint.colors(from: [[0.1, 0.7, 0.2], [0.2, 0.8, 0.3]])!
        XCTAssertGreaterThan(tint.display.g, tint.display.r)
        XCTAssertGreaterThan(tint.accent.r + tint.accent.b, tint.accent.g, "the opposite hue")
    }
}
