import XCTest
import HimawariKit
@testable import Himawari

/// Beta 1.4: every era's layout keeps its controls on the panel and apart, at every size the
/// gear is shown at; and switching styles keeps the song where it was.
@MainActor
final class ThemeLayoutTests: XCTestCase {
    /// From the smallest panel the gear is drawn on (a 180-point gap, a 500-point video) up to a big screen.
    let sizes = [CGSize(width: 164, height: 484), CGSize(width: 220, height: 560), CGSize(width: 300, height: 760),
                 CGSize(width: 420, height: 1000), CGSize(width: 640, height: 1400)]

    private func check(_ face: PanelFace, _ size: CGSize, _ name: String) {
        let bounds = CGRect(origin: .zero, size: size)
        let controls = face.controls.sorted { "\($0.key)" < "\($1.key)" }
        for (control, rect) in controls {
            XCTAssertTrue(bounds.contains(rect), "\(name): \(control) \(rect) is off the panel")
            XCTAssertGreaterThan(rect.width, 8, "\(name): \(control) is too small to click")
        }
        for (i, a) in controls.enumerated() {
            for b in controls[(i + 1)...] {
                XCTAssertFalse(a.value.intersects(b.value), "\(name): \(a.key) and \(b.key) overlap")
            }
            for fixture in face.fixtures {
                XCTAssertFalse(a.value.intersects(fixture), "\(name): \(a.key) overlaps \(fixture)")
            }
        }
        for part in face.needles + face.bars.map(\.frame) + face.rotors.map(\.frame) + face.texts.map(\.frame) {
            XCTAssertTrue(bounds.contains(part), "\(name): \(part) is off the panel")
        }
    }

    func testControlsStayOnThePanelAndApart() {
        for skin in Skin.builtIn {
            let theme = Themes.make(skin)
            for size in sizes {
                check(theme.left(size: size), size, "\(skin.id) left \(size)")
                check(theme.right(size: size), size, "\(skin.id) right \(size)")
            }
        }
    }

    func testEveryEraHasEveryControl() {
        let player: Set<GearControl> = [.previous, .playPause, .next, .stop, .eject, .progress, .jog, .repeatMode, .shuffle]
        let amp: Set<GearControl> = [.volume, .bass, .treble]
        for skin in Skin.builtIn {
            let theme = Themes.make(skin)
            XCTAssertEqual(Set(theme.left(size: sizes[2]).controls.keys), player, skin.id)
            XCTAssertEqual(Set(theme.right(size: sizes[2]).controls.keys), amp, skin.id)
            XCTAssertEqual(theme.left(size: sizes[2]).rotors.filter(\.isJog).count, 1, "\(skin.id): one wheel to scrub with")
        }
    }

    func testClickingTheProgressLandsWhereItsPointerWouldBe() {
        // GearControls seeks to x / width across the click area: it must span what moves.
        for skin in Skin.builtIn {
            let face = Themes.make(skin).left(size: sizes[2])
            let click = face.controls[.progress]!
            if let track = face.dialPointer {
                XCTAssertEqual(click.minX, track.minX, accuracy: 0.01, skin.id)
                XCTAssertEqual(click.width, track.width, accuracy: 0.01, skin.id)
            } else {
                XCTAssertEqual(click.minX, face.ladder.first!.minX, accuracy: 0.01, skin.id)
                XCTAssertEqual(click.maxX, face.ladder.last!.maxX, accuracy: 0.01, skin.id)
            }
        }
    }

    func testKnobGrabAreasShrinkRatherThanOverlap() {
        let knobs: [(control: GearControl, rect: CGRect)] = [(.bass, CGRect(x: 0, y: 0, width: 40, height: 40)),
                                                              (.treble, CGRect(x: 52, y: 0, width: 40, height: 40))]
        let areas = GearLayout.grabAreas(knobs, within: CGRect(x: -100, y: -100, width: 400, height: 400))
        XCTAssertFalse(areas[.bass]!.intersects(areas[.treble]!))
        XCTAssertEqual(areas[.bass]!.width, 40 + 2 * 5.5, accuracy: 0.01)
    }

    func testSwitchingStylesKeepsTheSong() {
        let gear = NowPlayingSides(frame: NSRect(x: 0, y: 0, width: 1470, height: 956))
        gear.place(around: CGRect(x: 453, y: 160, width: 563, height: 563))
        gear.show(SongInfo(title: "Golden Hour", artist: "Someone", album: "Sunsets", duration: 215, position: 83, playing: true))
        let before = gear.currentPosition(), started = CACurrentMediaTime()
        let rackRects = gear.controlRects
        for skin in Skin.builtIn {
            gear.style = skin
            XCTAssertEqual(gear.song?.title, "Golden Hour", skin.id)
            XCTAssertEqual(gear.song?.playing, true, skin.id)
            // Still counting from where it was (rebuilding on a slow machine takes a while).
            XCTAssertEqual(gear.currentPosition(), before + (CACurrentMediaTime() - started), accuracy: 0.25, skin.id)
            XCTAssertEqual(Set(gear.controlRects.keys).count, 12, skin.id)
        }
        gear.style = .standard
        XCTAssertEqual(gear.controlRects, rackRects, "back to the rack: the controls are where they were")
    }
}

final class MediaMathTests: XCTestCase {
    func testTheTonearmTravelsFromTheLeadInToTheRunOut() {
        func reach(_ a: CGFloat) -> CGFloat {
            hypot(MusicScene.Record.pivot.x + MusicScene.Record.arm * cos(a), MusicScene.Record.pivot.y + MusicScene.Record.arm * sin(a))
        }
        XCTAssertEqual(reach(MusicScene.tonearmAngle(fraction: 0)), MusicScene.Record.leadIn, accuracy: 1e-4)
        XCTAssertEqual(reach(MusicScene.tonearmAngle(fraction: 1)), MusicScene.Record.runOut, accuracy: 1e-4)
        XCTAssertEqual(reach(MusicScene.tonearmAngle(fraction: 0.5)), (MusicScene.Record.leadIn + MusicScene.Record.runOut) / 2, accuracy: 1e-4)
        XCTAssertGreaterThan(reach(MusicScene.Record.rest), MusicScene.Record.vinyl, "parked, the arm is off the record")
        // The arm stays inside the square the record sits in.
        for f in stride(from: 0.0, through: 1, by: 0.1) {
            let a = MusicScene.tonearmAngle(fraction: f)
            let tip = CGPoint(x: MusicScene.Record.pivot.x + MusicScene.Record.arm * cos(a), y: MusicScene.Record.pivot.y + MusicScene.Record.arm * sin(a))
            XCTAssertLessThan(max(abs(tip.x), abs(tip.y)), 1, "at \(f)")
        }
    }

    func testTapePacksKeepTheTapesArea() {
        XCTAssertEqual(NowPlayingSides.tapeRadius(0, hub: 10, full: 30), 10)
        XCTAssertEqual(NowPlayingSides.tapeRadius(1, hub: 10, full: 30), 30)
        let half = NowPlayingSides.tapeRadius(0.5, hub: 10, full: 30)
        XCTAssertEqual(half * half - 100, (900 - 100) / 2, accuracy: 1e-6, "half the tape: half the area between hub and full")
        XCTAssertEqual(NowPlayingSides.tapeRadius(2, hub: 10, full: 30), 30, "clamped")
    }
}
