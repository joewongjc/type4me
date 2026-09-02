import XCTest
@testable import Type4Me

@MainActor
final class KeychainNotificationTests: XCTestCase {
    func testCredentialsDidChangeNotificationName() {
        XCTAssertEqual(Notification.Name.credentialsDidChange.rawValue, "tf_credentialsDidChange")
    }

    func testSelectedLLMProviderChangePostsNotification() {
        var notificationFired = false
        let observer = NotificationCenter.default.addObserver(
            forName: .credentialsDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notificationFired = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let original = KeychainService.selectedLLMProvider
        let newProvider: LLMProvider = original == .doubao ? .deepseek : .doubao
        KeychainService.selectedLLMProvider = newProvider
        defer { KeychainService.selectedLLMProvider = original }

        XCTAssertTrue(notificationFired)
    }

    func testAppNavigationModelPendingCategory() {
        let model = AppNavigationModel()
        XCTAssertNil(model.pendingModelCategory)
        model.pendingModelCategory = .llm
        XCTAssertEqual(model.pendingModelCategory, .llm)
    }
}
