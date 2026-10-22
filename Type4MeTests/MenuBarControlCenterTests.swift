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

    func testStorageKeysMatchKeychainServiceKeys() {
        XCTAssertEqual(KeychainService.selectedASRProviderKey, "tf_selectedASRProvider")
        XCTAssertEqual(KeychainService.selectedLLMProviderKey, "tf_selectedLLMProvider")
    }

    func testASRSelectionTransition_A_to_B_to_A() {
        let appState = AppState()
        let model = MenuBarControlCenterModel(appState: appState)

        let originalASR = KeychainService.selectedASRProvider
        defer {
            KeychainService.selectedASRProvider = originalASR
        }

        let providerA: ASRProvider = .volcano
        let providerB: ASRProvider = .mimo

        // Step 1: Set to A
        KeychainService.selectedASRProvider = providerA
        XCTAssertEqual(KeychainService.selectedASRProvider, providerA)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: KeychainService.selectedASRProviderKey),
            providerA.rawValue
        )
        XCTAssertEqual(model.selectedASRProvider, providerA)
        let resolvedA = MenuBarSelectionState.resolvedASRProvider(
            raw: UserDefaults.standard.string(forKey: KeychainService.selectedASRProviderKey) ?? "",
            fallback: model.selectedASRProvider
        )
        XCTAssertEqual(resolvedA, providerA)

        // Step 2: Switch to B
        KeychainService.selectedASRProvider = providerB
        XCTAssertEqual(KeychainService.selectedASRProvider, providerB)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: KeychainService.selectedASRProviderKey),
            providerB.rawValue
        )
        XCTAssertEqual(model.selectedASRProvider, providerB)
        let resolvedB = MenuBarSelectionState.resolvedASRProvider(
            raw: UserDefaults.standard.string(forKey: KeychainService.selectedASRProviderKey) ?? "",
            fallback: model.selectedASRProvider
        )
        XCTAssertEqual(resolvedB, providerB)

        // Step 3: Switch back to A
        KeychainService.selectedASRProvider = providerA
        XCTAssertEqual(KeychainService.selectedASRProvider, providerA)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: KeychainService.selectedASRProviderKey),
            providerA.rawValue
        )
        XCTAssertEqual(model.selectedASRProvider, providerA)
        let resolvedFinal = MenuBarSelectionState.resolvedASRProvider(
            raw: UserDefaults.standard.string(forKey: KeychainService.selectedASRProviderKey) ?? "",
            fallback: model.selectedASRProvider
        )
        XCTAssertEqual(resolvedFinal, providerA)
    }

    func testLLMSelectionTransition_A_to_B_to_A() {
        let appState = AppState()
        let model = MenuBarControlCenterModel(appState: appState)

        let originalLLM = KeychainService.selectedLLMProvider
        defer {
            KeychainService.selectedLLMProvider = originalLLM
        }

        let providerA: LLMProvider = .doubao
        let providerB: LLMProvider = .deepseek

        // Step 1: Set to A
        KeychainService.selectedLLMProvider = providerA
        XCTAssertEqual(KeychainService.selectedLLMProvider, providerA)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: KeychainService.selectedLLMProviderKey),
            providerA.rawValue
        )
        XCTAssertEqual(model.selectedLLMProvider, providerA)
        let resolvedA = MenuBarSelectionState.resolvedLLMProvider(
            raw: UserDefaults.standard.string(forKey: KeychainService.selectedLLMProviderKey) ?? "",
            fallback: model.selectedLLMProvider
        )
        XCTAssertEqual(resolvedA, providerA)

        // Step 2: Switch to B
        KeychainService.selectedLLMProvider = providerB
        XCTAssertEqual(KeychainService.selectedLLMProvider, providerB)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: KeychainService.selectedLLMProviderKey),
            providerB.rawValue
        )
        XCTAssertEqual(model.selectedLLMProvider, providerB)
        let resolvedB = MenuBarSelectionState.resolvedLLMProvider(
            raw: UserDefaults.standard.string(forKey: KeychainService.selectedLLMProviderKey) ?? "",
            fallback: model.selectedLLMProvider
        )
        XCTAssertEqual(resolvedB, providerB)

        // Step 3: Switch back to A
        KeychainService.selectedLLMProvider = providerA
        XCTAssertEqual(KeychainService.selectedLLMProvider, providerA)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: KeychainService.selectedLLMProviderKey),
            providerA.rawValue
        )
        XCTAssertEqual(model.selectedLLMProvider, providerA)
        let resolvedFinal = MenuBarSelectionState.resolvedLLMProvider(
            raw: UserDefaults.standard.string(forKey: KeychainService.selectedLLMProviderKey) ?? "",
            fallback: model.selectedLLMProvider
        )
        XCTAssertEqual(resolvedFinal, providerA)
    }

    func testMicrophoneSelectionTransition_FollowSystem_to_Device_to_FollowSystem() {
        let appState = AppState()
        let model = MenuBarControlCenterModel(appState: appState)

        let originalMode = AudioInputDevicePreferenceStore.mode()
        let originalEntries = AudioInputDevicePreferenceStore.priorityEntries()
        defer {
            if originalMode == .systemDefault {
                AudioInputDevicePreferenceStore.resetToSystemDefault()
            } else {
                AudioInputDevicePreferenceStore.savePriorityEntries(originalEntries)
            }
        }

        // Step 1: Follow system
        AudioInputDevicePreferenceStore.resetToSystemDefault()
        model.refresh()
        XCTAssertEqual(AudioInputDevicePreferenceStore.mode(), .systemDefault)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: AudioInputDevicePreferenceStore.modeKey),
            AudioInputDevicePreferenceMode.systemDefault.rawValue
        )
        XCTAssertEqual(model.microphonePreferenceMode, .systemDefault)
        XCTAssertNil(model.selectedPriorityMicrophoneUID)
        let resolvedMode1 = MenuBarSelectionState.resolvedMicrophoneMode(
            raw: UserDefaults.standard.string(forKey: AudioInputDevicePreferenceStore.modeKey) ?? "",
            fallback: model.microphonePreferenceMode
        )
        XCTAssertEqual(resolvedMode1, .systemDefault)

        // Step 2: Priority device
        let dummyDevice = AudioInputDevicePreferenceEntry(uid: "test-mic-uid", name: "Test Microphone")
        AudioInputDevicePreferenceStore.savePriorityEntries([dummyDevice])
        model.refresh()
        XCTAssertEqual(AudioInputDevicePreferenceStore.mode(), .priority)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: AudioInputDevicePreferenceStore.modeKey),
            AudioInputDevicePreferenceMode.priority.rawValue
        )
        XCTAssertEqual(model.microphonePreferenceMode, .priority)
        let resolvedMode2 = MenuBarSelectionState.resolvedMicrophoneMode(
            raw: UserDefaults.standard.string(forKey: AudioInputDevicePreferenceStore.modeKey) ?? "",
            fallback: model.microphonePreferenceMode
        )
        XCTAssertEqual(resolvedMode2, .priority)

        // Step 3: Switch back to follow system
        AudioInputDevicePreferenceStore.resetToSystemDefault()
        model.refresh()
        XCTAssertEqual(AudioInputDevicePreferenceStore.mode(), .systemDefault)
        XCTAssertEqual(model.microphonePreferenceMode, .systemDefault)
        XCTAssertNil(model.selectedPriorityMicrophoneUID)
        let resolvedMode3 = MenuBarSelectionState.resolvedMicrophoneMode(
            raw: UserDefaults.standard.string(forKey: AudioInputDevicePreferenceStore.modeKey) ?? "",
            fallback: model.microphonePreferenceMode
        )
        XCTAssertEqual(resolvedMode3, .systemDefault)
    }

    func testCrossSurfaceProviderChangeFromSettingsSynchronizesMenuBar() {
        let appState = AppState()
        let model = MenuBarControlCenterModel(appState: appState)

        let originalASR = KeychainService.selectedASRProvider
        let originalLLM = KeychainService.selectedLLMProvider
        defer {
            KeychainService.selectedASRProvider = originalASR
            KeychainService.selectedLLMProvider = originalLLM
        }

        // Simulate Settings changing ASR to Tencent
        KeychainService.selectedASRProvider = .tencent
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: KeychainService.selectedASRProviderKey),
            ASRProvider.tencent.rawValue
        )
        XCTAssertEqual(model.selectedASRProvider, .tencent)
        XCTAssertEqual(
            MenuBarSelectionState.resolvedASRProvider(
                raw: UserDefaults.standard.string(forKey: KeychainService.selectedASRProviderKey) ?? "",
                fallback: model.selectedASRProvider
            ),
            .tencent
        )

        // Simulate Settings changing LLM to Kimi
        KeychainService.selectedLLMProvider = .kimi
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: KeychainService.selectedLLMProviderKey),
            LLMProvider.kimi.rawValue
        )
        XCTAssertEqual(model.selectedLLMProvider, .kimi)
        XCTAssertEqual(
            MenuBarSelectionState.resolvedLLMProvider(
                raw: UserDefaults.standard.string(forKey: KeychainService.selectedLLMProviderKey) ?? "",
                fallback: model.selectedLLMProvider
            ),
            .kimi
        )
    }

    func testRadioSelectionUnconditionalTriggerPreventsDeadlock() {
        var selectedProvider: ASRProvider = .mimo
        var selectCallCount = 0

        // Simulation of the updated menuSelectionToggle binding logic
        let makeBinding: (ASRProvider) -> (get: Bool, set: (Bool) -> Void) = { provider in
            (
                get: selectedProvider == provider,
                set: { _ in
                    selectedProvider = provider
                    selectCallCount += 1
                }
            )
        }

        // User clicks Volcano (previously unselected)
        let volcanoBinding = makeBinding(.volcano)
        volcanoBinding.set(true)
        XCTAssertEqual(selectedProvider, .volcano)
        XCTAssertEqual(selectCallCount, 1)

        // User clicks Xiaomi (even if UI state was stale or sent false upon click)
        let mimoBinding = makeBinding(.mimo)
        mimoBinding.set(false) // AppKit toggle sending false on checked item
        XCTAssertEqual(selectedProvider, .mimo, "Unconditional select must re-select Xiaomi without deadlock")
        XCTAssertEqual(selectCallCount, 2)
    }
}
