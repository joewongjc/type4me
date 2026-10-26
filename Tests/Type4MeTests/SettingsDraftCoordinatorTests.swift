import XCTest
@testable import Type4Me

@MainActor
final class SettingsDraftCoordinatorTests: XCTestCase {
    func testCleanParticipantsDoNotBlockNavigation() {
        let coordinator = SettingsDraftCoordinator()
        coordinator.register(.modes, isDirty: { false }, save: { false }, discard: {})

        XCTAssertFalse(coordinator.hasUnsavedChanges)
        XCTAssertTrue(coordinator.saveAll())
    }

    func testSaveOnlyRunsDirtyParticipants() {
        let coordinator = SettingsDraftCoordinator()
        var saveCount = 0
        coordinator.register(
            .modes,
            isDirty: { true },
            save: {
                saveCount += 1
                return true
            },
            discard: {}
        )
        coordinator.register(
            .asrCredentials,
            isDirty: { false },
            save: {
                XCTFail("Clean participant should not be saved")
                return false
            },
            discard: {}
        )

        XCTAssertTrue(coordinator.hasUnsavedChanges)
        XCTAssertTrue(coordinator.saveAll())
        XCTAssertEqual(saveCount, 1)
    }

    func testSaveFailureKeepsTransitionBlocked() {
        let coordinator = SettingsDraftCoordinator()
        coordinator.register(.llmCredentials, isDirty: { true }, save: { false }, discard: {})

        XCTAssertFalse(coordinator.saveAll())
        XCTAssertTrue(coordinator.hasUnsavedChanges)
    }

    func testDiscardRunsDirtyParticipantsAndUnregisterRemovesThem() {
        let coordinator = SettingsDraftCoordinator()
        var dirty = true
        var discardCount = 0
        coordinator.register(
            .modes,
            isDirty: { dirty },
            save: { true },
            discard: {
                dirty = false
                discardCount += 1
            }
        )

        coordinator.discardAll()

        XCTAssertEqual(discardCount, 1)
        XCTAssertFalse(coordinator.hasUnsavedChanges)
        coordinator.unregister(.modes)
        XCTAssertTrue(coordinator.saveAll())
    }

    func testReRegisterParticipantOverridesPreviousClosures() {
        let coordinator = SettingsDraftCoordinator()
        var savedProvider: String?

        // Initial registration for OpenAI
        coordinator.register(
            .llmCredentials,
            isDirty: { true },
            save: {
                savedProvider = "openai"
                return true
            },
            discard: {}
        )

        // Re-registration when switching to Gemini
        coordinator.register(
            .llmCredentials,
            isDirty: { true },
            save: {
                savedProvider = "gemini"
                return true
            },
            discard: {}
        )

        XCTAssertTrue(coordinator.hasUnsavedChanges)
        XCTAssertTrue(coordinator.saveAll())
        XCTAssertEqual(savedProvider, "gemini", "Re-registering participant must override the previous save closure")
    }
}
