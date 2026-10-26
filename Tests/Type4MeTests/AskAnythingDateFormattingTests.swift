import Foundation
import XCTest
@testable import Type4Me

final class AskAnythingDateFormattingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_786_331_040)

    func testChineseDetailDateUsesChineseDateComponents() {
        let result = AskAnythingDateFormatting.dateDescription(date, language: .zh)

        XCTAssertTrue(result.contains("年"))
        XCTAssertTrue(result.contains("月"))
        XCTAssertTrue(result.contains("日"))
        XCTAssertFalse(result.localizedCaseInsensitiveContains("Aug"))
    }

    func testEnglishDetailDateDoesNotUseChineseDateComponents() {
        let result = AskAnythingDateFormatting.dateDescription(date, language: .en)

        XCTAssertFalse(result.contains("年"))
        XCTAssertFalse(result.contains("月"))
        XCTAssertFalse(result.contains("日"))
    }

    func testChineseShortTimeDoesNotUseEnglishMeridiem() {
        let result = AskAnythingDateFormatting.shortTime(date, language: .zh)

        XCTAssertFalse(result.localizedCaseInsensitiveContains("AM"))
        XCTAssertFalse(result.localizedCaseInsensitiveContains("PM"))
    }
}
