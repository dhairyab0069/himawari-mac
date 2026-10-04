import XCTest
@testable import Himawari

/// Turning the jog wheel or the CD: how far a drag has gone round, in radians.
final class TurnTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100) // center (50, 50)

    func testQuarterTurnCounterclockwise() {
        var t = GearControls.Turn()
        t.begin(at: CGPoint(x: 100, y: 50), in: bounds)      // 3 o'clock
        _ = t.move(to: CGPoint(x: 50, y: 100))               // 12 o'clock (y up)
        XCTAssertEqual(t.total, .pi / 2, accuracy: 1e-9)
    }

    func testCrossingTheSeamAt180Degrees() {
        // From just above 9 o'clock to just below it: a tiny turn, not almost a full one.
        var t = GearControls.Turn()
        t.begin(at: CGPoint(x: 0, y: 51), in: bounds)
        let step = t.move(to: CGPoint(x: 0, y: 49))
        XCTAssertEqual(step, 0.04, accuracy: 0.001)
    }

    func testFullTurnsAccumulate() {
        var t = GearControls.Turn()
        t.begin(at: CGPoint(x: 100, y: 50), in: bounds)
        for i in 1...16 { // clockwise, in eighth turns: twice round
            let a = -Double(i) * .pi / 4
            _ = t.move(to: CGPoint(x: 50 + 50 * cos(a), y: 50 + 50 * sin(a)))
        }
        XCTAssertEqual(t.total, -4 * .pi, accuracy: 1e-9)
    }
}

final class ScrubClampTests: XCTestCase {
    func testStaysInsideTheSong() {
        XCTAssertEqual(GearControls.clamp(-30, position: 10, duration: 200), -10, "not before the start")
        XCTAssertEqual(GearControls.clamp(500, position: 150, duration: 200), 49, "a second before the end")
        XCTAssertEqual(GearControls.clamp(5, position: 150, duration: 200), 5)
    }

    func testAtTheVeryEnd() {
        XCTAssertEqual(GearControls.clamp(10, position: 199.5, duration: 200), 0)
    }
}

/// The VU needles: RMS level → place on the meter's scale (0 = −20 VU, 0.82 = 0 VU, 1 = +3).
final class VUScaleTests: XCTestCase {
    func testReferenceLevelSitsAtZeroVU() {
        // 0 VU is set at −14 dBFS.
        XCTAssertEqual(NowPlayingSides.vuFraction(Float(pow(10, -14.0 / 20))), 0.82, accuracy: 1e-3)
    }

    func testSilenceRestsAtTheLeft() {
        XCTAssertEqual(NowPlayingSides.vuFraction(0), 0)
    }

    func testFullScaleIsPinned() {
        XCTAssertEqual(NowPlayingSides.vuFraction(1), 1.03)
    }

    func testMonotonic() {
        let levels = stride(from: -40.0, through: 0, by: 0.5).map { NowPlayingSides.vuFraction(Float(pow(10, $0 / 20))) }
        XCTAssertEqual(levels, levels.sorted())
    }
}

/// Where a cover goes on the CD: the calm spot under the hub wins, but a calm cover stays put.
final class DiscPlacementTests: XCTestCase {
    func image(_ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        draw(ctx)
        return ctx.makeImage()!
    }

    func testCalmCoverStaysCentered() {
        let p = DiscPrint.placement(of: image { _ in }, inner: 0.22)
        XCTAssertEqual(p.center.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.center.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.zoom, 1)
    }

    func testBusyCenterMovesTheArt() {
        // A bold checkerboard (like lettering) just left of center, partly under the hub.
        let busy = image { ctx in
            for y in stride(from: 96, to: 160, by: 16) { for x in stride(from: 64, to: 128, by: 16) {
                ctx.setFillColor(gray: (x + y) / 16 % 2 == 0 ? 0 : 1, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 16, height: 16))
            } }
        }
        let p = DiscPrint.placement(of: busy, inner: 0.22)
        XCTAssertGreaterThan(p.zoom, 1, "a square cover can only move once it's enlarged")
        XCTAssertGreaterThan(p.center.x, 0.5, "the art shifts so the hub lands right of the detail")
    }
}
