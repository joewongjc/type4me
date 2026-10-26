import XCTest
@testable import Type4Me

final class AppBuildInfoTests: XCTestCase {
    func testCompactLabelUsesVersionAndBuildNumber() {
        let info = AppBuildInfo(version: "2.3.0", buildNumber: "136")

        XCTAssertEqual(info.compactLabel, "v2.3.0(136)")
        XCTAssertEqual(info.debugLabel, "2.3.0 (136)")
    }

    func testMissingBundleValuesUseDisplaySafeFallbacks() {
        let info = AppBuildInfo(infoDictionary: ["CFBundleVersion": ""])

        XCTAssertEqual(info.version, "—")
        XCTAssertEqual(info.buildNumber, "—")
        XCTAssertEqual(info.compactLabel, "v—(—)")
    }
}
