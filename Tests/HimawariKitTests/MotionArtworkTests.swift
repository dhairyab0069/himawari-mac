import XCTest
@testable import HimawariKit

/// Album matching decides which animated cover a song gets: a wrong match shows another
/// album's art (the bug fixed in Beta 1.1.1), a missed match shows the CD instead.
final class AlbumMatchingTests: XCTestCase {
    func testAlbumKeyDropsEditionWords() {
        XCTAssertEqual(MotionArtwork.albumKey("Way Ahead - EP"), "way ahead")
        XCTAssertEqual(MotionArtwork.albumKey("Views (Deluxe)"), "views")
        XCTAssertEqual(MotionArtwork.albumKey("Scorpion [Explicit]"), "scorpion")
        XCTAssertEqual(MotionArtwork.albumKey("Thriller (25th Anniversary Edition)"), "thriller")
        XCTAssertEqual(MotionArtwork.albumKey("Hello - Single"), "hello")
    }

    func testAlbumKeyKeepsMeaningfulParentheses() {
        // Not an edition word: part of the title.
        XCTAssertEqual(MotionArtwork.albumKey("(What's the Story) Morning Glory?"), "what s the story morning glory")
    }

    func testAlbumKeyFoldsCaseAndAccents() {
        XCTAssertEqual(MotionArtwork.albumKey("BEYONCÉ"), "beyonce")
    }

    func testSameAlbumAllowsEditions() {
        XCTAssertTrue(MotionArtwork.sameAlbum("Views", "Views (Deluxe)"))
        XCTAssertTrue(MotionArtwork.sameAlbum("Way Ahead - EP", "Way Ahead"))
    }

    func testSameAlbumRejectsOtherAlbums() {
        // The original bug: the "Intro" on B.T.F.U was taken for the one on Way Ahead.
        XCTAssertFalse(MotionArtwork.sameAlbum("B.T.F.U", "Way Ahead - EP"))
        XCTAssertFalse(MotionArtwork.sameAlbum("Views", "Viewsfinder"), "a prefix that isn't a whole word")
        XCTAssertFalse(MotionArtwork.sameAlbum("", ""), "no album name matches nothing")
    }
}

final class NameMatchingTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(YouTubeLoop.normalize("  Señorita!! (Remix) "), "senorita remix")
    }

    func testArtistNamesSplitsCollaborations() {
        XCTAssertEqual(YouTubeLoop.artistNames("Raga, DG IMMORTALS & X feat. Y"), ["raga", "dg immortals"])
        XCTAssertEqual(YouTubeLoop.artistNames("Drake featuring Rihanna"), ["drake", "rihanna"])
    }
}

/// Picking the sharpest stream of an animated cover that still fits the screen.
final class VariantChoiceTests: XCTestCase {
    let master = URL(string: "https://mvod.itunes.apple.com/a/b/master.m3u8")!
    let playlist = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=720x720,CODECS="avc1.640028"
    720_avc.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=720x720,CODECS="hvc1.2.4.L123"
    720_hevc.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1080x1080,CODECS="hvc1.2.4.L123"
    1080_hevc.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=2160x2160,CODECS="hvc1.2.4.L153"
    https://cdn.example/2160.m3u8
    """

    func pick(_ side: Int) -> String {
        MotionArtwork.bestVariant(inPlaylist: playlist, master: master, maxSide: side).absoluteString
    }

    func testLargestThatFits() {
        XCTAssertEqual(pick(1100), "https://mvod.itunes.apple.com/a/b/1080_hevc.m3u8")
        XCTAssertEqual(pick(4000), "https://cdn.example/2160.m3u8")
    }

    func testPrefersHEVCAtTheSameSize() {
        XCTAssertEqual(pick(800), "https://mvod.itunes.apple.com/a/b/720_hevc.m3u8")
    }

    func testSmallestWhenNothingFits() {
        XCTAssertTrue(pick(100).hasPrefix("https://mvod.itunes.apple.com/a/b/720_"))
    }

    func testFallsBackToTheMasterWithNoVariants() {
        XCTAssertEqual(MotionArtwork.bestVariant(inPlaylist: "#EXTM3U\n", master: master, maxSide: 1000), master)
    }
}

final class ToneBandsTests: XCTestCase {
    func testShelves() {
        let (bands, preamp) = MusicNowPlaying.toneBands(bass: 6, treble: -4)
        XCTAssertEqual(bands, [6, 6, 3, 0, 0, 0, 0, -2, -4, -4])
        XCTAssertEqual(preamp, -3, "half the largest boost, for headroom")
    }

    func testClampedTo12dB() {
        let (bands, preamp) = MusicNowPlaying.toneBands(bass: 30, treble: -30)
        XCTAssertEqual(bands.first, 12)
        XCTAssertEqual(bands.last, -12)
        XCTAssertEqual(preamp, -6)
    }

    func testCutsNeedNoHeadroom() {
        XCTAssertEqual(MusicNowPlaying.toneBands(bass: -6, treble: -6).preamp, 0)
    }
}
