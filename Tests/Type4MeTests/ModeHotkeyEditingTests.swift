import XCTest
@testable import Type4Me

/// Coverage for the shared Home/Settings mode-hotkey editing helpers and the
/// synchronous navigation hand-off that selects a mode without a notification
/// race. Layout and view wiring are exercised manually; these tests pin the
/// pure logic that both surfaces now depend on.
@MainActor
final class ModeHotkeyEditingTests: XCTestCase {

    private func target(
        modeId: UUID,
        editing: UUID? = nil
    ) -> RecordingTarget {
        RecordingTarget(
            modeId: modeId,
            modeName: "Mode",
            editingBindingId: editing,
            initialKeyCode: nil,
            initialModifiers: nil,
            initialStyle: .hold
        )
    }

    // MARK: - applyBinding: cross-mode uniqueness transfer

    func testApplyBindingTransfersConflictingBindingFromOtherMode() {
        let modeA = ProcessingMode(
            id: UUID(), name: "A", prompt: "{text}", isBuiltin: false,
            hotkeyBindings: [
                HotkeyBinding(keyCode: 20, modifiers: 524288, style: .toggle),
                HotkeyBinding(keyCode: 21, modifiers: 524288, style: .toggle),
            ]
        )
        let modeB = ProcessingMode(id: UUID(), name: "B", prompt: "{text}", isBuiltin: false)
        var modes = [modeA, modeB]

        ModeHotkeyEditing.applyBinding(
            keyCode: 20, modifiers: 524288, style: .hold,
            to: &modes, for: target(modeId: modeB.id)
        )

        // Only the single conflicting binding leaves A; its sibling stays.
        XCTAssertEqual(modes[0].hotkeyBindings.map(\.keyCode), [21])
        // B receives the transferred binding as a fresh append.
        XCTAssertEqual(modes[1].hotkeyBindings.count, 1)
        XCTAssertEqual(modes[1].hotkeyBindings.first?.keyCode, 20)
        XCTAssertEqual(modes[1].hotkeyBindings.first?.style, .hold)
    }

    // MARK: - applyBinding: append vs edit within a mode

    func testApplyBindingAppendsNewBindingWhenNotEditing() {
        let mode = ProcessingMode(
            id: UUID(), name: "A", prompt: "{text}", isBuiltin: false,
            hotkeyBindings: [HotkeyBinding(keyCode: 20, modifiers: 0, style: .toggle)]
        )
        var modes = [mode]

        ModeHotkeyEditing.applyBinding(
            keyCode: 21, modifiers: 0, style: .hold,
            to: &modes, for: target(modeId: mode.id)
        )

        XCTAssertEqual(modes[0].hotkeyBindings.map(\.keyCode), [20, 21])
    }

    func testApplyBindingEditsExistingBindingInPlace() {
        let editing = HotkeyBinding(keyCode: 20, modifiers: 0, style: .toggle)
        let sibling = HotkeyBinding(keyCode: 21, modifiers: 0, style: .hold)
        let mode = ProcessingMode(
            id: UUID(), name: "A", prompt: "{text}", isBuiltin: false,
            hotkeyBindings: [editing, sibling]
        )
        var modes = [mode]

        ModeHotkeyEditing.applyBinding(
            keyCode: 30, modifiers: 262144, style: .hold,
            to: &modes, for: target(modeId: mode.id, editing: editing.id)
        )

        // Same identity is retained; only key/modifiers/style change.
        XCTAssertEqual(modes[0].hotkeyBindings.count, 2)
        let updated = modes[0].hotkeyBindings.first { $0.id == editing.id }
        XCTAssertEqual(updated?.keyCode, 30)
        XCTAssertEqual(updated?.modifiers, 262144)
        XCTAssertEqual(updated?.style, .hold)
        // Sibling is untouched.
        XCTAssertEqual(modes[0].hotkeyBindings.first { $0.id == sibling.id }?.keyCode, 21)
    }

    // MARK: - Conflict / duplicate checks

    func testConflictCheckFindsOtherModeOwningEquivalentBinding() {
        let owner = ProcessingMode(
            id: UUID(), name: "Owner", prompt: "{text}", isBuiltin: false,
            hotkeyBindings: [HotkeyBinding(keyCode: 20, modifiers: 524288, style: .toggle)]
        )
        let editingMode = ProcessingMode(id: UUID(), name: "Editing", prompt: "{text}", isBuiltin: false)
        let modes = [owner, editingMode]

        let check = ModeHotkeyEditing.makeConflictCheck(
            in: modes, target: target(modeId: editingMode.id)
        )
        XCTAssertEqual(check(20, 524288)?.id, owner.id)
        XCTAssertNil(check(99, 0))
    }

    func testDuplicateCheckExcludesBindingBeingEdited() {
        let editing = HotkeyBinding(keyCode: 20, modifiers: 524288, style: .toggle)
        let sibling = HotkeyBinding(keyCode: 21, modifiers: 524288, style: .hold)
        let mode = ProcessingMode(
            id: UUID(), name: "A", prompt: "{text}", isBuiltin: false,
            hotkeyBindings: [editing, sibling]
        )
        let modes = [mode]

        let check = ModeHotkeyEditing.makeDuplicateCheck(
            in: modes, target: target(modeId: mode.id, editing: editing.id)
        )
        // Recording the sibling's combo is a duplicate.
        XCTAssertTrue(check(21, 524288))
        // Recording the edited binding's own combo is not a duplicate of itself.
        XCTAssertFalse(check(20, 524288))
    }

    // MARK: - persistModes

    func testPersistModesWritesReorderedListAndSyncsAppState() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-persist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let storage = ModeStorage(fileURL: url)
        let suite = "ModeHotkeyEditingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try storage.save(ProcessingMode.defaults)
        let appState = AppState(modeStorage: storage, userDefaults: defaults)

        let reordered = Array(appState.availableModes.reversed())
        let ok = ModeHotkeyEditing.persistModes(reordered, appState: appState, storage: storage)

        XCTAssertTrue(ok)
        XCTAssertEqual(appState.availableModes.map(\.id), reordered.map(\.id))
        // The persisted file reflects the new order across a reload.
        XCTAssertEqual(storage.load().map(\.id), reordered.map(\.id))
    }

    func testPersistModesFallsBackCurrentModeWhenRemoved() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-persist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let storage = ModeStorage(fileURL: url)
        let suite = "ModeHotkeyEditingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let custom = ProcessingMode(id: UUID(), name: "Custom", prompt: "{text}", isBuiltin: false)
        try storage.save([ProcessingMode.direct, custom])
        let appState = AppState(modeStorage: storage, userDefaults: defaults)
        appState.currentMode = custom

        // Persist a list without the custom mode; current mode must fall back.
        ModeHotkeyEditing.persistModes([ProcessingMode.direct], appState: appState, storage: storage)

        XCTAssertEqual(appState.currentMode.id, ProcessingMode.directId)
    }

    // MARK: - AppNavigationModel pending selection

    func testPendingModeSelectionIDCanBeConsumedOnce() {
        let model = AppNavigationModel()
        let id = UUID()
        model.pendingModeSelectionID = id

        // Simulate the consumer: read, then clear.
        let consumed = model.pendingModeSelectionID
        model.pendingModeSelectionID = nil

        XCTAssertEqual(consumed, id)
        XCTAssertNil(model.pendingModeSelectionID)
    }

    // MARK: - Home mode-row localization

    /// The Home card renders each row through `mode.localizedDisplayName`, which
    /// reads the live `tf_language`. System modes must follow the setting while
    /// custom names stay verbatim.
    func testHomeRowNameFollowsLiveLanguageForSystemModesOnly() {
        let previous = UserDefaults.standard.string(forKey: "tf_language")
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "tf_language")
            } else {
                UserDefaults.standard.removeObject(forKey: "tf_language")
            }
        }

        let system = ProcessingMode.direct
        let custom = ProcessingMode(id: UUID(), name: "会议记录", prompt: "{text}", isBuiltin: false)

        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(system.localizedDisplayName, "快速模式")
        XCTAssertEqual(custom.localizedDisplayName, "会议记录")

        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(system.localizedDisplayName, "Quick Mode")
        XCTAssertEqual(custom.localizedDisplayName, "会议记录")
    }
}
