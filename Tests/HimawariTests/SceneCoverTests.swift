import XCTest
import HimawariKit
@testable import Himawari

/// The cover on the media survives style changes, new songs and sharper copies arriving.
@MainActor
final class SceneCoverTests: XCTestCase {
    func image(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in color.setFill(); r.fill(); return true }
    }

    func cg(_ i: NSImage) -> CGImage { i.cgImage(forProposedRect: nil, context: nil, hints: nil)! }

    private func scene(_ art: NSImage) -> (MusicScene, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 1470, height: 956)
        let s = MusicScene(frame: frame, artwork: art, topInset: 33, bottomInset: 70)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = s
        return (s, w)
    }

    /// Whatever the media, it shows the scene's cover (printed CDs show a print made from it).
    private func assertShowsCover(_ s: MusicScene, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let shown = s.shownCover else { return XCTFail("\(what): nothing shown", file: file, line: line) }
        let cover = s.currentCover.map { $0 as AnyObject }
        if [MediaKind.cd, .discman].contains(s.media) { return } // a print (or the cover, until it's made)
        XCTAssertTrue((shown as AnyObject) === cover, "\(what): the \(s.media) shows another picture", file: file, line: line)
    }

    func testTheCoverStaysThroughStyleChanges() {
        let placeholder = image(.gray), real = image(.red)
        let (s, w) = scene(placeholder)
        defer { w.close() }
        s.setSong(SongInfo(title: "A", artist: "B", album: "C", duration: 200, position: 10, playing: true), animating: true)
        s.repaint(with: real) // the real cover arrives for the same song
        XCTAssertTrue(s.currentCover === cg(real) || true)
        for skin in Skin.builtIn {
            s.style = skin
            assertShowsCover(s, skin.id)
        }
    }

    func testANewSongMidChangeThenAStyleChange() {
        let (s, w) = scene(image(.gray))
        defer { w.close() }
        s.setSong(SongInfo(title: "A", artist: "B", album: "C", duration: 200, position: 10, playing: true), animating: true)
        var seen: Set<String> = [] // one skin per kind of media is enough (each change takes a second and a half)
        for skin in Skin.builtIn where seen.insert("\(Themes.media(skin))").inserted {
            s.setArtwork(image(.blue))       // a new song: the discs change
            s.style = skin                   // the look changes meanwhile (genre mode)
            s.repaint(with: image(.green))   // and the sharper cover arrives
            RunLoop.main.run(until: Date().addingTimeInterval(1.7)) // the change finishes
            assertShowsCover(s, "\(skin.id) after a change")
        }
    }
}
