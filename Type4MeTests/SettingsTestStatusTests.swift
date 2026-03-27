import XCTest
@testable import Type4Me

final class SettingsTestStatusTests: XCTestCase {

    func testSavedBadgeTextUsesSavedLabel() {
        XCTAssertEqual(SettingsTestStatus.saved.badgeText, L("已保存", "Saved"))
    }

    func testSuccessBadgeTextUsesConnectionSuccessLabel() {
        XCTAssertEqual(SettingsTestStatus.success.badgeText, L("连接成功", "Connected"))
    }

    func testFailedBadgeTextPassesThroughMessage() {
        XCTAssertEqual(SettingsTestStatus.failed("连接失败").badgeText, "连接失败")
    }
}
