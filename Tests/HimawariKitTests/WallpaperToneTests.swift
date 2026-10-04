import XCTest
@testable import HimawariKit

/// The clock's ink adapts to the brightness behind it; these readings drive that.
final class WallpaperToneTests: XCTestCase {
    func testLumaWeights() {
        XCTAssertEqual(FrameSampler.luma(SIMD3(1, 1, 1)), 1, accuracy: 1e-9)
        XCTAssertEqual(FrameSampler.luma(SIMD3(0, 1, 0)), 0.7152, accuracy: 1e-9, "green counts most")
    }

    func testReadingOfAFlatPicture() {
        let r = WallpaperTone.reading(of: { _, _ in 0.25 }, region: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        XCTAssertTrue(r.grid.allSatisfy { abs($0 - 0.25) < 1e-9 })
        XCTAssertEqual(r.focus ?? -1, 0.25, accuracy: 1e-6)
        XCTAssertEqual(r.spread ?? -1, 0, accuracy: 1e-6, "a flat picture isn't busy")
    }

    func testFocusFollowsTheRegion() {
        // Dark left half, bright right half.
        let luma: (Double, Double) -> Double = { u, _ in u < 0.5 ? 0 : 1 }
        let left = WallpaperTone.reading(of: luma, region: CGRect(x: 0.05, y: 0.1, width: 0.3, height: 0.2))
        let right = WallpaperTone.reading(of: luma, region: CGRect(x: 0.65, y: 0.1, width: 0.3, height: 0.2))
        XCTAssertLessThan(left.focus ?? 1, 0.1)
        XCTAssertGreaterThan(right.focus ?? 0, 0.9)
    }
}
