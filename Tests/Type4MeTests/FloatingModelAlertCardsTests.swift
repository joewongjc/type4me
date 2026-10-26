import XCTest
@testable import Type4Me

@MainActor
final class FloatingModelAlertCardsTests: XCTestCase {
    func testAppleASRHasConfiguredCredentials() {
        XCTAssertTrue(ModelSettingsHelpers.hasConfiguredCredentials(for: .apple))
    }

    func testCodexCLIHasConfiguredCredentials() {
        XCTAssertTrue(ModelSettingsHelpers.hasConfiguredCredentials(for: .codexCLI))
    }

    func testAppNavigationModelCategoryRouting() {
        let nav = AppNavigationModel()
        nav.selectedTab = .general
        XCTAssertEqual(nav.selectedTab, .general)
        XCTAssertNil(nav.pendingModelCategory)

        nav.selectedTab = .models
        nav.pendingModelCategory = .asr
        XCTAssertEqual(nav.selectedTab, .models)
        XCTAssertEqual(nav.pendingModelCategory, .asr)
    }
}
