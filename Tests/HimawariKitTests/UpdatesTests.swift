import XCTest
@testable import HimawariKit

/// Beta 1.5.1: updates from GitHub's releases.
final class UpdatesTests: XCTestCase {
    func testVersionsCompareByNumbers() {
        XCTAssertTrue(Release.isNewer("1.5.1", than: "1.5"))
        XCTAssertTrue(Release.isNewer("1.5", than: "1.4.5.1"))
        XCTAssertTrue(Release.isNewer("1.10", than: "1.9"), "not alphabetical")
        XCTAssertTrue(Release.isNewer("v3.0", than: "1.5.1"))
        XCTAssertFalse(Release.isNewer("1.5", than: "1.5.0"), "a missing part is 0")
        XCTAssertFalse(Release.isNewer("1.4.5", than: "1.5"))
        XCTAssertFalse(Release.isNewer("1.5", than: "1.5"))
    }

    func testReadingGitHubsAnswer() {
        let json: [String: Any] = [
            "tag_name": "v1.5.1", "name": "Himawari Beta 1.5.1", "html_url": "https://github.com/x/y/releases/tag/v1.5.1",
            "body": "## Fixes\n\n- **The real cover**, not the label.\n\n## Install\nOpen the DMG…",
            "assets": [["name": "Himawari-Code-Report.pdf", "browser_download_url": "https://x/report.pdf"],
                       ["name": "Himawari-1.5.1.dmg", "browser_download_url": "https://x/Himawari-1.5.1.dmg"]],
        ]
        let r = Release(json: json)!
        XCTAssertEqual(r.version, "1.5.1")
        XCTAssertEqual(r.dmg?.lastPathComponent, "Himawari-1.5.1.dmg", "the disk image, not the report")
        XCTAssertEqual(r.summary, "Fixes\n\n- The real cover, not the label.", "plain, without the install steps")
        XCTAssertNil(Release(json: ["name": "no tag"]))
    }
}
