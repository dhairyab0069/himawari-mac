import XCTest
import AppKit
@testable import HimawariKit

/// Which app is playing, what Himawari may do with it, and which ones it follows (Beta 1.2).
final class PlayerKindTests: XCTestCase {
    func testKnownPlayers() {
        XCTAssertEqual(PlayerKind(bundleID: "com.apple.Music"), .appleMusic)
        XCTAssertEqual(PlayerKind(bundleID: "com.spotify.client"), .spotify)
        XCTAssertEqual(PlayerKind(bundleID: "com.tidal.desktop"), .tidal)
        XCTAssertEqual(PlayerKind(bundleID: "com.amazon.music"), .amazonMusic)
        XCTAssertEqual(PlayerKind(bundleID: "com.deezer.deezer-desktop"), .deezer)
    }

    func testBrowsersAreWebPlayers() {
        for id in ["com.apple.Safari", "com.google.Chrome", "com.google.Chrome.beta", "org.mozilla.firefox",
                   "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser"] {
            XCTAssertEqual(PlayerKind(bundleID: id), .browser, id)
        }
    }

    func testEverythingElse() {
        XCTAssertEqual(PlayerKind(bundleID: "org.videolan.vlc"), .other)
        XCTAssertEqual(PlayerKind(bundleID: "com.apple.QuickTimePlayerX"), .other)
        XCTAssertEqual(PlayerKind(bundleID: nil), .other)
    }

    func testOnlyAppleMusicIsScriptable() {
        XCTAssertEqual(PlayerKind.appleMusic.capabilities, .all)
        for kind in PlayerKind.allCases where kind != .appleMusic && kind != .spotify {
            // VOLUME turns the Mac's volume for them; the EQ and repeat/shuffle need Music.
            XCTAssertEqual(kind.capabilities, [.transport, .seek, .volume], "\(kind)")
        }
    }

    func testRawValuesAreStable() {
        // Saved in the Players menu settings: renaming a case would forget people's choices.
        XCTAssertEqual(PlayerKind.allCases.map(\.rawValue),
                       ["appleMusic", "spotify", "tidal", "amazonMusic", "deezer", "browser", "other", "webContent"])
    }

    func testWebKitHelpersAreNeverPlayers() {
        // Himawari's own YouTube loop plays in a WebKit process: following it would loop forever.
        XCTAssertEqual(PlayerKind(bundleID: "com.apple.WebKit.WebContent"), .webContent)
        XCTAssertEqual(PlayerKind(bundleID: "com.apple.WebKit.GPU"), .webContent)
        XCTAssertFalse(PlayerChoice().follows(.webContent))
        XCTAssertFalse(PlayerChoice(pinned: .webContent).follows(.webContent))
        XCTAssertFalse(PlayerKind.menuCases.contains(.webContent))
    }
}

final class PlayerChoiceTests: XCTestCase {
    func testFollowsEverythingByDefault() {
        let choice = PlayerChoice()
        XCTAssertTrue(PlayerKind.menuCases.allSatisfy(choice.follows))
    }

    func testTurnedOffPlayersAreIgnored() {
        let choice = PlayerChoice(disabled: [.browser, .other])
        XCTAssertTrue(choice.follows(.spotify))
        XCTAssertFalse(choice.follows(.browser))
        XCTAssertFalse(choice.follows(.other))
    }

    func testPinnedFollowsOnlyThatOne() {
        let choice = PlayerChoice(disabled: [.spotify], pinned: .spotify)
        XCTAssertTrue(choice.follows(.spotify), "pinning wins over turning off")
        XCTAssertFalse(choice.follows(.appleMusic))
    }
}

final class SwitchingTests: XCTestCase {
    func testAPausedAppNeverTakesOverFromAPlayingOne() {
        // Seen live: a paused YouTube tab in Firefox and a playing app, reported alternately.
        XCTAssertFalse(PlayerChoice.switches(fromPlaying: true, toPlaying: false))
    }

    func testStartingToPlayTakesOver() {
        XCTAssertTrue(PlayerChoice.switches(fromPlaying: true, toPlaying: true))
        XCTAssertTrue(PlayerChoice.switches(fromPlaying: false, toPlaying: true))
    }

    func testNothingPlayingFollowsTheLatest() {
        XCTAssertTrue(PlayerChoice.switches(fromPlaying: false, toPlaying: false))
    }
}

final class PlayerCommandTests: XCTestCase {
    func testHelperLines() {
        XCTAssertEqual(PlayerCommand.togglePlayPause.helperLine, "toggle")
        XCTAssertEqual(PlayerCommand.next.helperLine, "next")
        XCTAssertEqual(PlayerCommand.previous.helperLine, "previous")
        XCTAssertEqual(PlayerCommand.seek(to: 83.456).helperLine, "seek 83.46")
        XCTAssertEqual(PlayerCommand.refresh.helperLine, "refresh")
    }

    func testSeekNeverNegativeAndAlwaysWithADot() {
        XCTAssertEqual(PlayerCommand.seek(to: -5).helperLine, "seek 0.00")
        XCTAssertFalse(PlayerCommand.seek(to: 1.5).helperLine.contains(","), "the helper parses a C-locale number")
    }
}

/// Web players that never report a position, and songs with no cover (found live with Firefox).
final class WebPlayerQuirkTests: XCTestCase {
    func testAZeroPositionMidSongIsIgnoredFromAPlayerThatNeverReportsOne() {
        XCTAssertFalse(MusicNowPlaying.trustsElapsed(0.001, estimate: 95, sameSong: true, reportsPosition: false))
    }

    func testZeroIsRealFromPlayersThatReportPositions() {
        // Repeat-one, a restart with ⏮, or dragging back to the start.
        XCTAssertTrue(MusicNowPlaying.trustsElapsed(0, estimate: 95, sameSong: true, reportsPosition: true))
    }

    func testOtherReadingsAreUsed() {
        XCTAssertTrue(MusicNowPlaying.trustsElapsed(42, estimate: 95, sameSong: true, reportsPosition: false), "a real reading")
        XCTAssertTrue(MusicNowPlaying.trustsElapsed(0, estimate: 95, sameSong: false, reportsPosition: false), "a new song")
        XCTAssertTrue(MusicNowPlaying.trustsElapsed(0, estimate: 1, sameSong: true, reportsPosition: false), "just started")
    }

    @MainActor func testPlaceholderCoverIsSquareAndStable() {
        let track = MusicNowPlaying.Track(name: "Big Pressure", artist: "TopSuperKicker", album: "", duration: 147)
        let a = MusicNowPlaying.placeholderCover(for: track), b = MusicNowPlaying.placeholderCover(for: track)
        XCTAssertEqual(a.size, NSSize(width: 600, height: 600))
        XCTAssertEqual(a.tiffRepresentation, b.tiffRepresentation, "same song, same label")
    }
}
