import XCTest
@testable import HimawariClock

final class ClockFaceTests: XCTestCase {
    /// A moment today at this local time (the clock works in local time).
    func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: h, minute: m, second: s, of: Date())!
    }

    func testTwelveAndTwentyFourHour() {
        XCTAssertEqual(ClockFace.parts(at(17, 5), format: .twelve, seconds: false).main, "5:05")
        XCTAssertEqual(ClockFace.parts(at(17, 5), format: .twelve, seconds: false).small, " PM")
        XCTAssertEqual(ClockFace.parts(at(17, 5, 9), format: .twentyFour, seconds: true).main, "17:05:09")
        XCTAssertEqual(ClockFace.parts(at(0, 30), format: .twelve, seconds: false).main, "12:30")
    }

    func testSwatchBeatsAreTheSameEverywhere() {
        // 00:00 UTC is 01:00 in Biel (UTC+1): 3600 s / 86.4 = 41.67 beats.
        let utcMidnight = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ClockFace.parts(utcMidnight, format: .beats, seconds: false).main, "@041")
        XCTAssertEqual(ClockFace.parts(utcMidnight, format: .beats, seconds: true).main, "@041.67")
        XCTAssertEqual(ClockFace.parts(Date(timeIntervalSince1970: 23 * 3600), format: .beats, seconds: false).main, "@000")
    }

    func testDecimalTime() {
        // Noon is exactly half the day: 5 decimal hours.
        XCTAssertEqual(ClockFace.parts(at(12, 0), format: .decimal, seconds: false).main, "5:00")
        // 18:00 is three quarters: 7.5 decimal hours = 7:50.
        XCTAssertEqual(ClockFace.parts(at(18, 0), format: .decimal, seconds: true).main, "7:50:00")
    }

    func testWords() {
        XCTAssertEqual(ClockFace.words(at(17, 20)), "twenty past five")
        XCTAssertEqual(ClockFace.words(at(17, 44)), "quarter to six")
        XCTAssertEqual(ClockFace.words(at(9, 1)), "nine o'clock")
        XCTAssertEqual(ClockFace.words(at(12, 2)), "noon")
        XCTAssertEqual(ClockFace.words(at(23, 58)), "midnight", "rounds up into the next day")
    }

    func testTicksMatchTheFormat() {
        XCTAssertEqual(ClockFace.ticks(format: .twentyFour, seconds: true).step, 1)
        XCTAssertEqual(ClockFace.ticks(format: .twelve, seconds: false).step, 60)
        XCTAssertEqual(ClockFace.ticks(format: .beats, seconds: false).step, 86.4)
        XCTAssertEqual(ClockFace.ticks(format: .decimal, seconds: true).step, 0.864)
    }
}
