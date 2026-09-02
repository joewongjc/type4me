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

    func testCredentialsDidChangeObserverSynchronousReadDoesNotDeadlock() {
        var synchronousReadSucceeded = false
        let observer = NotificationCenter.default.addObserver(
            forName: .credentialsDidChange,
            object: nil,
            queue: nil
        ) { _ in
            // Synchronously read credentials during notification delivery
            _ = KeychainService.loadSelectedASRConfig()
            _ = KeychainService.loadSelectedLLMConfig()
            synchronousReadSucceeded = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let original = KeychainService.selectedASRProvider
        let newProvider: ASRProvider = original == .volcano ? .apple : .volcano
        KeychainService.selectedASRProvider = newProvider
        defer { KeychainService.selectedASRProvider = original }

        XCTAssertTrue(synchronousReadSucceeded, "Synchronous read inside credentialsDidChange observer must complete without deadlocking")
    }

    func testSaveASRCredentialsObserverSynchronousReadDoesNotDeadlock() throws {
        guard KeychainService.isUsingTestStorage else {
            throw XCTSkip("Keychain tests require isolated test storage")
        }
        var readCompleted = false
        let observer = NotificationCenter.default.addObserver(
            forName: .credentialsDidChange,
            object: nil,
            queue: nil
        ) { _ in
            _ = KeychainService.loadASRCredentials(for: .volcano)
            _ = KeychainService.loadSelectedASRConfig()
            readCompleted = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try KeychainService.saveASRCredentials(for: .volcano, values: ["appKey": "test_app_key"])
        XCTAssertTrue(readCompleted, "Synchronous read inside saveASRCredentials notification must not deadlock")
    }

    func testSaveLLMCredentialsObserverSynchronousReadDoesNotDeadlock() throws {
        guard KeychainService.isUsingTestStorage else {
            throw XCTSkip("Keychain tests require isolated test storage")
        }
        var readCompleted = false
        let observer = NotificationCenter.default.addObserver(
            forName: .credentialsDidChange,
            object: nil,
            queue: nil
        ) { _ in
            _ = KeychainService.loadLLMCredentials(for: .doubao)
            _ = KeychainService.loadSelectedLLMConfig()
            readCompleted = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try KeychainService.saveLLMCredentials(for: .doubao, values: ["model": "doubao-pro"])
        XCTAssertTrue(readCompleted, "Synchronous read inside saveLLMCredentials notification must not deadlock")
    }

    func testAppNavigationModelPendingCategory() {
        let model = AppNavigationModel()
        XCTAssertNil(model.pendingModelCategory)
        model.pendingModelCategory = .llm
        XCTAssertEqual(model.pendingModelCategory, .llm)
    }
}
