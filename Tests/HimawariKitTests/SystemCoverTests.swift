import XCTest
@testable import HimawariKit

/// Beta 1.5.1: the system sends a cover once per artwork; the next song on the album reuses it.
final class SystemCoverTests: XCTestCase {
    func testTheNextSongOnTheAlbumReusesTheCover() {
        let last = (id: "https://is1.mzstatic.com/a/600x600bb.jpg" as String?, album: "Views")
        XCTAssertTrue(MusicNowPlaying.reusesSystemCover(id: last.id, album: "Views", last: last))
        XCTAssertFalse(MusicNowPlaying.reusesSystemCover(id: last.id, album: "Scorpion", last: last), "the last song's cover, right after a skip")
        XCTAssertFalse(MusicNowPlaying.reusesSystemCover(id: nil, album: "Views", last: last), "no artwork named")
        XCTAssertFalse(MusicNowPlaying.reusesSystemCover(id: "other", album: "Views", last: last))
    }
}
