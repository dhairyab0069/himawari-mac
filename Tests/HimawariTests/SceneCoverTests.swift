import XCTest
import HimawariKit
@testable import Himawari

/// The cover on the media survives style changes, new songs and sharper copies arriving.
@MainActor
final class SceneCoverTests: XCTestCase {
    func image(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in color.setFill(); r.fill(); return true }
    }

    private func scene(_ art: NSImage) -> (MusicScene, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 1470, height: 956)
        MusicScene.printsInline = true // the CD's print is made at once, so it can be checked
        let s = MusicScene(frame: frame, artwork: art, topInset: 33, bottomInset: 70)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = s
        return (s, w)
    }

    override func tearDown() { MusicScene.printsInline = false }

    /// The colour of a picture at a point (fractions of its size; y down, as bitmaps are).
    private func colour(_ contents: Any?, at x: Double = 0.5, _ y: Double = 0.5) -> NSColor? {
        guard let anything = contents, CFGetTypeID(anything as CFTypeRef) == CGImage.typeID else { return nil }
        let image = anything as! CGImage
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.colorAt(x: Int(Double(rep.pixelsWide - 1) * x), y: Int(Double(rep.pixelsHigh - 1) * y))?.usingColorSpace(.sRGB)
    }

    /// The media shows a picture of this colour (a CD's print is sampled out on the disc, clear of the hole and the ring).
    private func assertShows(_ s: MusicScene, red: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let printed = [MediaKind.cd, .discman].contains(s.media)
        guard let c = colour(s.shownCover, at: printed ? 0.5 : 0.5, printed ? 0.08 : 0.5) else {
            return XCTFail("\(what): nothing shown on the \(s.media)", file: file, line: line)
        }
        if red {
            XCTAssertGreaterThan(c.redComponent, 0.8, "\(what): the \(s.media) isn't showing the newest cover", file: file, line: line)
            XCTAssertLessThan(c.blueComponent, 0.3, "\(what)", file: file, line: line)
        } else {
            XCTAssertGreaterThan(c.blueComponent, 0.8, "\(what): the \(s.media) isn't showing the newest cover", file: file, line: line)
        }
    }

    func testTheCoverStaysThroughStyleChanges() {
        let (s, w) = scene(image(.gray))
        defer { w.close() }
        s.setSong(SongInfo(title: "A", artist: "B", album: "C", duration: 200, position: 10, playing: true), animating: true)
        s.repaint(with: image(.red)) // the real cover arrives for the same song
        for skin in Skin.builtIn {
            s.style = skin
            assertShows(s, red: true, skin.id)
        }
    }

    func testANewSongMidChangeThenAStyleChange() {
        let (s, w) = scene(image(.gray))
        defer { w.close() }
        s.setSong(SongInfo(title: "A", artist: "B", album: "C", duration: 200, position: 10, playing: true), animating: true)
        var seen: Set<String> = [] // one skin per kind of media is enough (each change takes a second and a half)
        for skin in Skin.builtIn where seen.insert("\(Themes.media(skin))").inserted {
            s.setArtwork(image(.green))      // a new song: the discs change
            s.style = skin                   // the look changes meanwhile (genre mode)
            s.repaint(with: image(.blue))    // and the sharper cover arrives
            RunLoop.main.run(until: Date().addingTimeInterval(1.7)) // the change finishes
            assertShows(s, red: false, "\(skin.id) after a change")
        }
    }
}
