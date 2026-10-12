import XCTest
@testable import HimawariKit

/// Beta 1.3: playlists for the disc changer, Spotify's extra controls, and web-player titles.
final class PlaylistParsingTests: XCTestCase {
    let u = "\u{1F}", r = "\u{1E}"

    func testPlaylistsFromAppleScript() {
        let out = "9C7C5586DF77F318\(u)DHH\(u)41\(r)A1B2\(u)90’s gangsta\(u)35\(r)"
        let list = PlaylistLibrary.parsePlaylists(out)
        XCTAssertEqual(list.map(\.name), ["DHH", "90’s gangsta"])
        XCTAssertEqual(list.first?.source, .appleMusic(persistentID: "9C7C5586DF77F318"))
        XCTAssertEqual(list.first?.count, 41)
        XCTAssertEqual(list.first?.id, "am:9C7C5586DF77F318")
    }

    func testBrokenLinesAreSkipped() {
        XCTAssertEqual(PlaylistLibrary.parsePlaylists("\(u)\(u)\(r)ID\(u)Name\(r)").count, 0)
        XCTAssertEqual(PlaylistLibrary.parsePlaylists("").count, 0)
    }

    func testPositionAndUpNext() {
        // Seen live: DHH playing its first song.
        let out = "DHH\(u)none\(u)1\(u)41\(r)2\(u)Astaghfirullah\(u)MC Stan\(r)3\(u)Baap Se\(u)Fotty Seven & KR$NA\(r)"
        let p = PlaylistLibrary.parsePosition(out)
        XCTAssertEqual(p?.label, "DHH · 1 / 41")
        XCTAssertEqual(p?.upNext.map(\.index), [2, 3])
        XCTAssertEqual(p?.upNext.first?.artist, "MC Stan")
    }

    func testTheWholeLibraryIsntAPlaylist() {
        XCTAssertNil(PlaylistLibrary.parsePosition("Music\(u)Music\(u)812\(u)936\(r)"))
        XCTAssertNil(PlaylistLibrary.parsePosition(""), "stopped")
    }
}

final class SpotifyLinkTests: XCTestCase {
    func testShareLinks() {
        XCTAssertEqual(PlaylistLibrary.spotifyURI(fromLink: "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc123"),
                       "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")
        XCTAssertEqual(PlaylistLibrary.spotifyURI(fromLink: "  https://open.spotify.com/intl-de/playlist/37i9dQZF1DXcBWIGoYBM5M \n"),
                       "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")
        XCTAssertEqual(PlaylistLibrary.spotifyURI(fromLink: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"),
                       "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")
    }

    func testOnlyPlaylistsAndOnlySpotify() {
        XCTAssertNil(PlaylistLibrary.spotifyURI(fromLink: "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"))
        XCTAssertNil(PlaylistLibrary.spotifyURI(fromLink: "https://evil.example/playlist/37i9dQZF1DXcBWIGoYBM5M"))
        XCTAssertNil(PlaylistLibrary.spotifyURI(fromLink: "spotify:playlist:abc\" to do shell script \"x"), "no script injection")
        XCTAssertNil(PlaylistLibrary.spotifyURI(fromLink: "hello"))
    }

    func testSpotifyGetsItsOwnControls() {
        let spotify = PlayerKind.spotify.capabilities
        XCTAssertTrue(spotify.contains([.volume, .repeatShuffle, .playlists]))
        XCTAssertFalse(spotify.contains(.equalizer))
        XCTAssertFalse(spotify.contains(.upNext), "Spotify's AppleScript can't read what's next")
    }

    func testAppleScriptStringsAreEscaped() {
        XCTAssertEqual(PlaylistLibrary.escaped(#"a"b\c"#), #"a\"b\\c"#)
    }
}

final class WebTitleTests: XCTestCase {
    func testVideoTitlesBecomeArtistAndSong() {
        let c = WebTitle.clean(title: "DRV - Har Har Mahadev 4L ft. ILLAH (Official Video)", artist: "DRV")
        XCTAssertEqual(c.artist, "DRV")
        XCTAssertEqual(c.title, "Har Har Mahadev 4L")
    }

    func testPackagingIsDropped() {
        XCTAssertEqual(WebTitle.clean(title: "Blinding Lights [Official Audio]", artist: "The Weeknd").title, "Blinding Lights")
        XCTAssertEqual(WebTitle.clean(title: "Song (Lyrics)", artist: "Someone").title, "Song")
    }

    func testMeaningfulBracketsStay() {
        XCTAssertEqual(WebTitle.clean(title: "Hey Jude (Remix by Someone)", artist: "The Beatles").title, "Hey Jude (Remix by Someone)")
    }

    func testChannelNamesAreTidied() {
        XCTAssertEqual(WebTitle.clean(title: "Starboy", artist: "The Weeknd - Topic").artist, "The Weeknd")
        XCTAssertEqual(WebTitle.clean(title: "Shake It Off", artist: "TaylorSwiftVEVO").artist, "TaylorSwift")
    }

    func testCleanNamesPassThrough() {
        // YouTube Music already reports them like this.
        let c = WebTitle.clean(title: "It Lives, It Breathes", artist: "Lil Uzi Vert")
        XCTAssertEqual(c.title, "It Lives, It Breathes")
        XCTAssertEqual(c.artist, "Lil Uzi Vert")
    }
}
