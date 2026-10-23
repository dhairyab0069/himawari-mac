import XCTest
@testable import HimawariKit

/// Beta 1.5: synced lyrics.
final class LRCTests: XCTestCase {
    func testLinesAndTheirTimes() {
        let lrc = """
        [ar:Someone]
        [ti:A Song]
        [00:12.50]First line
        [00:15.00] Second line
        [01:02.345]Third
        """
        let l = Lyrics.parseLRC(lrc)!
        XCTAssertEqual(l.lines.map(\.text), ["First line", "Second line", "Third"])
        XCTAssertEqual(l.lines.map(\.time), [12.5, 15, 62.345])
        XCTAssertTrue(l.synced)
    }

    func testSeveralStampsOnOneLineAndOrder() {
        let l = Lyrics.parseLRC("[00:30.00][00:10.00]Chorus\n[00:20.00]Verse")!
        XCTAssertEqual(l.lines.map(\.text), ["Chorus", "Verse", "Chorus"])
        XCTAssertEqual(l.lines.map(\.time), [10, 20, 30])
    }

    func testOffsetTagMovesEverything() {
        let l = Lyrics.parseLRC("[offset:+500]\n[00:10.00]Line\n[00:00.20]Early")!
        XCTAssertEqual(l.lines.map(\.time), [0, 9.5], "earlier by half a second, never before the start")
    }

    func testOtherTimeSpellings() {
        XCTAssertEqual(Lyrics.time("1:05"), 65)
        XCTAssertEqual(Lyrics.time("01:05:50"), 65.5)
        XCTAssertNil(Lyrics.time("ar"))
        XCTAssertNil(Lyrics.time("00:75.00"))
    }

    func testWordTiming() {
        let l = Lyrics.parseLRC("[00:01.00]<00:01.00> Hello <00:01.60> bright <00:02.10> world")!
        XCTAssertEqual(l.lines[0].text, "Hello bright world")
        XCTAssertEqual(l.lines[0].words.map(\.text), ["Hello", "bright", "world"])
        XCTAssertEqual(l.lines[0].words.map(\.time), [1, 1.6, 2.1])
    }

    func testNothingTimedIsNotSynced() {
        XCTAssertNil(Lyrics.parseLRC("just words\nno times"))
        XCTAssertNil(Lyrics.parseLRC(""))
    }

    func testTheLineForAPosition() {
        let l = Lyrics.parseLRC("[00:10.00]a\n[00:20.00]b\n[00:30.00]c")!
        XCTAssertNil(l.lineIndex(at: 5), "before the first line")
        XCTAssertEqual(l.lineIndex(at: 10), 0)
        XCTAssertEqual(l.lineIndex(at: 19.99), 0)
        XCTAssertEqual(l.lineIndex(at: 25), 1)
        XCTAssertEqual(l.lineIndex(at: 300), 2)
        XCTAssertEqual(l.nextChange(after: 12), 20)
        XCTAssertNil(l.nextChange(after: 30))
    }

    func testPlainLyricsTurnInPages() {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let l = Lyrics.plain("\n" + text + "\n\n", duration: 100, source: .appleMusic)!
        XCTAssertFalse(l.synced)
        XCTAssertEqual(l.lines.count, 10)
        XCTAssertEqual(l.lines[5].time, 50, accuracy: 1e-9, "spread evenly over the song")
        XCTAssertEqual(l.page(at: 0, size: 4).map(\.text), ["line 1", "line 2", "line 3", "line 4"])
        XCTAssertEqual(l.page(at: 45, size: 4).map(\.text), ["line 5", "line 6", "line 7", "line 8"])
        XCTAssertEqual(l.page(at: 99, size: 4).map(\.text), ["line 9", "line 10"])
        XCTAssertNil(Lyrics.plain(" \n \n", duration: 100, source: .appleMusic))
    }
}

final class LyricsChoiceTests: XCTestCase {
    func record(_ album: String, _ duration: Double, synced: Bool = true, instrumental: Bool = false) -> LyricsSource.Record {
        LyricsSource.Record(trackName: "Song", artistName: "Artist", albumName: album, duration: duration, instrumental: instrumental,
                            syncedLyrics: synced ? "[00:01.00]x" : nil, plainLyrics: "x")
    }

    func testTheSameLengthOrNothing() {
        let live = record("Live at Somewhere", 260), studio = record("Studio", 201)
        XCTAssertEqual(LyricsSource.best([live, studio], duration: 200, album: "")?.albumName, "Studio")
        XCTAssertNil(LyricsSource.best([live], duration: 200, album: ""), "a different recording's words are worse than none")
    }

    func testSyncedThenTheSameAlbum() {
        let plainOnAlbum = record("The Album", 200, synced: false)
        let syncedElsewhere = record("Hits", 201)
        let syncedOnAlbum = record("The Album (Deluxe)", 202)
        XCTAssertEqual(LyricsSource.best([plainOnAlbum, syncedElsewhere], duration: 200, album: "The Album")?.albumName, "Hits", "synced first")
        XCTAssertEqual(LyricsSource.best([syncedElsewhere, record("The Album", 202)], duration: 200, album: "The Album")?.albumName, "The Album")
        _ = syncedOnAlbum
    }

    func testInstrumentalsHaveNoWords() {
        XCTAssertNil(LyricsSource.best([record("A", 200, instrumental: true)], duration: 200, album: "A"))
    }
}
