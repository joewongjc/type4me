import XCTest
import SwiftUI
@testable import Type4Me

final class ThemeStoreTests: XCTestCase {

    func test_appTheme_warm_hasWarmInstance() {
        XCTAssertEqual(AppTheme.warm.instance.id, "warm")
    }

    func test_appTheme_allCases_instancesHaveMatchingIds() {
        for t in AppTheme.allCases {
            XCTAssertEqual(t.instance.id, t.rawValue,
                           "AppTheme.\(t.rawValue) instance id mismatch")
        }
    }

    func test_warmTheme_settingsBg_isUnchangedLiteral() {
        let warm = WarmTheme()
        let expected = Color(red: 0.95, green: 0.92, blue: 0.88)
        XCTAssertEqual(warm.settingsBg.description, expected.description)
    }

    func test_warmTheme_cornerRadii_areUnchanged() {
        let warm = WarmTheme()
        XCTAssertEqual(warm.cornerSM, 6)
        XCTAssertEqual(warm.cornerMD, 10)
        XCTAssertEqual(warm.cornerLG, 16)
    }
}
