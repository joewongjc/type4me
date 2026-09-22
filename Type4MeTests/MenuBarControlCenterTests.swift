import XCTest
@testable import Type4Me

@MainActor
final class MenuBarControlCenterTests: XCTestCase {

    func testApplicationMenuDestinationsUseDeterministicTabs() {
        XCTAssertEqual(MenuBarApplicationDestination.home.settingsTab, .general)
        XCTAssertEqual(MenuBarApplicationDestination.settings.settingsTab, .preferences)
        XCTAssertEqual(MenuBarApplicationDestination.models.settingsTab, .models)
    }

    func testRefreshNotificationsIncludeApplicationActivationForPermissionChanges() {
        XCTAssertTrue(
            MenuBarControlCenterModel.refreshNotificationNames.contains(
                NSApplication.didBecomeActiveNotification
            )
        )
    }

    func testReadyStatesAllowDictationStart() {
        XCTAssertTrue(MenuBarPresentation.canStartRecording(in: .hidden))
        XCTAssertTrue(MenuBarPresentation.canStartRecording(in: .done))
        XCTAssertTrue(MenuBarPresentation.canStartRecording(in: .error))
    }

    func testActiveAndProcessingStatesBlockDictationStart() {
        XCTAssertFalse(MenuBarPresentation.canStartRecording(in: .preparing))
        XCTAssertFalse(MenuBarPresentation.canStartRecording(in: .recording))
        XCTAssertFalse(MenuBarPresentation.canStartRecording(in: .processing))
        XCTAssertFalse(MenuBarPresentation.canStartRecording(in: .recovering))
    }

    func testOnlyCaptureStatesLockNextRecordingSettings() {
        XCTAssertTrue(MenuBarPresentation.locksRuntimeSettings(in: .preparing))
        XCTAssertTrue(MenuBarPresentation.locksRuntimeSettings(in: .recording))
        XCTAssertFalse(MenuBarPresentation.locksRuntimeSettings(in: .processing))
        XCTAssertFalse(MenuBarPresentation.locksRuntimeSettings(in: .recovering))
        XCTAssertFalse(MenuBarPresentation.locksRuntimeSettings(in: .done))
        XCTAssertFalse(MenuBarPresentation.locksRuntimeSettings(in: .error))
        XCTAssertFalse(MenuBarPresentation.locksRuntimeSettings(in: .hidden))
    }

    func testASRProviderItem_titlesShowBatchBadgeForNonRealtimeProviders() {
        let mimoItem = MenuBarASRProviderItem(provider: .mimo)
        XCTAssertEqual(mimoItem.title, "\(mimoItem.provider.displayName) (\(L("非实时", "Batch")))")

        let stepfunItem = MenuBarASRProviderItem(provider: .stepfunBatch)
        XCTAssertEqual(stepfunItem.title, "\(stepfunItem.provider.displayName) (\(L("非实时", "Batch")))")

        let openaiItem = MenuBarASRProviderItem(provider: .openai)
        XCTAssertEqual(openaiItem.title, "OpenAI (\(L("非实时", "Batch")))")

        let volcanoItem = MenuBarASRProviderItem(provider: .volcano)
        XCTAssertEqual(volcanoItem.title, volcanoItem.provider.displayName)
    }

    func testLLMProviderItemMarksUnconfiguredProviders() {
        let configured = MenuBarLLMProviderItem(provider: .doubao, isConfigured: true)
        XCTAssertEqual(configured.title, LLMProvider.doubao.displayName)

        let unconfigured = MenuBarLLMProviderItem(provider: .doubao, isConfigured: false)
        XCTAssertEqual(
            unconfigured.title,
            "\(LLMProvider.doubao.displayName) (\(L("未配置", "Not configured")))"
        )
    }

    func testLLMProviderListAlwaysContainsSelectedProvider() {
        let items = MenuBarLLMProviderAvailability.configuredItems()
        XCTAssertTrue(items.contains { $0.provider == KeychainService.selectedLLMProvider })
    }
}
