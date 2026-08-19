import XCTest
@testable import ClipFlow

final class VideoAspectRatioPresetTests: XCTestCase {

    func testMenuOrderAndTitles() {
        XCTAssertEqual(
            VideoAspectRatioPreset.allCases.map(\.title),
            ["原始", "1:1", "4:3", "3:2", "16:9", "9:16"]
        )
    }

    func testMPVValues() {
        XCTAssertEqual(
            VideoAspectRatioPreset.allCases.map(\.mpvValue),
            ["no", "1:1", "4:3", "3:2", "16:9", "9:16"]
        )
    }
}
