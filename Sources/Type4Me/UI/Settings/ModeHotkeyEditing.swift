import SwiftUI

// MARK: - Recording Sheet Target

/// Identifies which mode (and optionally which existing binding) a hotkey
/// recording sheet is editing. Shared by the modes settings page and the Home
/// dashboard so both open the same `HotkeyRecordingSheet`.
struct RecordingTarget: Identifiable {
    /// Fresh identity per presentation so re-opening the sheet always re-presents.
    let id = UUID()
    let modeId: UUID
    let modeName: String
    /// Non-nil when editing an existing binding; nil when adding a new one.
    let editingBindingId: UUID?
    let initialKeyCode: Int?
    let initialModifiers: UInt64?
    let initialStyle: ProcessingMode.HotkeyStyle
    var isManualInput = false
}

/// Another binding shares keys with the recorded hotkey: one of them is the
/// other's modifiers plus more keys. Both keep working, so this is a heads-up.
struct HotkeyPrefixConflict {
    let mode: ProcessingMode
    let binding: HotkeyBinding
    /// True when the recorded hotkey is the shorter one.
    let recordedIsPrefix: Bool

    /// Names both hotkeys and says which press triggers which mode.
    func message(recordedKeyCode: Int, recordedModifiers: UInt64?, recordedOwner: String) -> String {
        let recordedKey = HotkeyRecorderView.keyDisplayName(keyCode: recordedKeyCode, modifiers: recordedModifiers)
        let otherKey = HotkeyRecorderView.keyDisplayName(keyCode: binding.keyCode, modifiers: binding.modifiers)
        let otherOwner = mode.localizedDisplayName
        let (shortKey, shortOwner, longKey, longOwner) = recordedIsPrefix
            ? (recordedKey, recordedOwner, otherKey, otherOwner)
            : (otherKey, otherOwner, recordedKey, recordedOwner)
        return L(
            "「\(longOwner)」的 \(longKey) 包含 \(shortKey)：单独按 \(shortKey) 触发「\(shortOwner)」，再加按其他键则触发「\(longOwner)」",
            "\(longKey) for \"\(longOwner)\" includes \(shortKey): press \(shortKey) alone for \"\(shortOwner)\", or add the other keys for \"\(longOwner)\""
        )
    }
}

// MARK: - Drop Delegate

/// Reorders modes as a dragged row passes over its neighbors, persisting via
/// `onReorder`. Shared by the modes settings list and the Home dashboard list.
struct ModeDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var modes: [ProcessingMode]
    @Binding var draggingId: UUID?
    let onReorder: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        onReorder()
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragId = draggingId,
              dragId != targetId,
              let fromIndex = modes.firstIndex(where: { $0.id == dragId }),
              let toIndex = modes.firstIndex(where: { $0.id == targetId })
        else { return }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            modes.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
        // `dropEntered` is the point where the visible order actually changes.
        // Persist here instead of relying only on `performDrop`: AppKit may end a
        // drag over row gaps or scroll-view edges without calling the row's
        // `performDrop`, which previously left a reordered UI backed by stale disk data.
        onReorder()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Shared hotkey editing + persistence

/// Pure, view-agnostic building blocks for editing per-mode hotkey bindings and
/// persisting the mode list. Extracted so the modes settings page and the Home
/// dashboard share one implementation of conflict detection, binding transfer,
/// and disk/state persistence instead of each maintaining its own copy.
enum ModeHotkeyEditing {

    /// Cross-mode conflict: returns the *other* mode that already owns an
    /// equivalent binding, or nil. Confirming will transfer the binding.
    static func makeConflictCheck(
        in modes: [ProcessingMode],
        target: RecordingTarget
    ) -> (Int?, UInt64?) -> ProcessingMode? {
        { code, mods in
            guard let code else { return nil }
            return modes.first { other in
                guard other.id != target.modeId else { return false }
                return other.allHotkeyBindings.contains { b in
                    ModeBinding.hotkeysAreEquivalent(
                        keyCode: code, modifiers: mods,
                        otherKeyCode: b.keyCode, otherModifiers: b.modifiers
                    )
                }
            }
        }
    }

    /// Whether an equivalent binding already exists inside the *same* mode,
    /// excluding the binding currently being edited.
    static func makeDuplicateCheck(
        in modes: [ProcessingMode],
        target: RecordingTarget
    ) -> (Int?, UInt64?) -> Bool {
        { code, mods in
            guard let code,
                  let mode = modes.first(where: { $0.id == target.modeId })
            else { return false }
            return mode.allHotkeyBindings.contains { b in
                b.id != target.editingBindingId
                    && ModeBinding.hotkeysAreEquivalent(
                        keyCode: code, modifiers: mods,
                        otherKeyCode: b.keyCode, otherModifiers: b.modifiers
                    )
            }
        }
    }

    /// Returns the first binding that shares a modifier prefix with the recorded combo.
    /// Prefix conflict is per-binding: exclude only the binding being edited.
    static func makePrefixConflictCheck(
        in modes: [ProcessingMode],
        target: RecordingTarget
    ) -> (Int?, UInt64?) -> HotkeyPrefixConflict? {
        { code, mods in
            guard let code else { return nil }
            for other in modes {
                for b in other.allHotkeyBindings
                where !(other.id == target.modeId && b.id == target.editingBindingId)
                    && ModeBinding.hasModifierPrefixConflict(
                        keyCode: code, modifiers: mods,
                        otherKeyCode: b.keyCode, otherModifiers: b.modifiers
                    ) {
                    let recordedIsPrefix = ModeBinding.modifierBindingIsPrefix(
                        modifierKeyCode: code, modifierModifiers: mods,
                        otherKeyCode: b.keyCode, otherModifiers: b.modifiers
                    )
                    return HotkeyPrefixConflict(mode: other, binding: b, recordedIsPrefix: recordedIsPrefix)
                }
            }
            return nil
        }
    }

    /// Global actions remain reserved, except for the action being edited.
    static func makeReservedConflictCheck(
        for target: RecordingTarget
    ) -> (Int?, UInt64?) -> String? {
        { code, mods in
            guard let code else { return nil }
            if !target.isManualInput,
               ManualInputSettings.matches(keyCode: code, modifiers: mods, modes: ModeStorage().load()) {
                return L("手动输入", "Manual Input")
            }
            let revise = ReviseSettingsStore.shared.load()
            if revise.enabled, let key = revise.hotkey,
               ModeBinding.hotkeysAreEquivalent(keyCode: code, modifiers: mods,
                                               otherKeyCode: key.keyCode, otherModifiers: key.modifiers) {
                return L("改口", "Revise")
            }
            return nil
        }
    }

    /// Shared transfer step for a mode or the global manual-input shortcut.
    /// Preserve sibling bindings and modifier-prefix bindings; remove exact matches only.
    @discardableResult
    static func removeConflictingBindings(
        keyCode code: Int,
        modifiers mods: UInt64?,
        from modes: inout [ProcessingMode],
        excludingModeID: UUID? = nil
    ) -> Bool {
        var changed = false
        for i in modes.indices where modes[i].id != excludingModeID {
            let oldCount = modes[i].hotkeyBindings.count
            modes[i].hotkeyBindings.removeAll { b in
                ModeBinding.hotkeysAreEquivalent(
                    keyCode: code, modifiers: mods,
                    otherKeyCode: b.keyCode, otherModifiers: b.modifiers
                )
            }
            changed = changed || modes[i].hotkeyBindings.count != oldCount
        }
        return changed
    }

    /// Applies a recorded binding to `modes` for the sheet's target: first
    /// enforcing global uniqueness by removing the single conflicting binding
    /// from every other mode, then editing the existing binding in place (when
    /// editing) or appending a new one.
    static func applyBinding(
        keyCode code: Int,
        modifiers mods: UInt64?,
        style: ProcessingMode.HotkeyStyle,
        to modes: inout [ProcessingMode],
        for target: RecordingTarget
    ) {
        let style = ProcessingMode.HotkeyStyle.isAvailable(style, forKeyCode: code, modifiers: mods) ? style : .toggle
        removeConflictingBindings(
            keyCode: code, modifiers: mods, from: &modes, excludingModeID: target.modeId
        )
        if let idx = modes.firstIndex(where: { $0.id == target.modeId }) {
            if let editId = target.editingBindingId,
               let bIdx = modes[idx].hotkeyBindings.firstIndex(where: { $0.id == editId }) {
                modes[idx].hotkeyBindings[bIdx].keyCode = code
                modes[idx].hotkeyBindings[bIdx].modifiers = mods
                modes[idx].hotkeyBindings[bIdx].style = style
            } else {
                modes[idx].hotkeyBindings.append(
                    HotkeyBinding(keyCode: code, modifiers: mods, style: style)
                )
            }
        }
    }

    /// Shared persistence for the mode list: writes to disk, mirrors into
    /// `AppState`, broadcasts `.modesDidChange`, and keeps `currentMode` valid.
    /// Returns whether the disk write succeeded. `storage` is injectable for
    /// tests; production callers use the default application-support location.
    @MainActor
    @discardableResult
    static func persistModes(
        _ modes: [ProcessingMode],
        appState: AppState,
        storage: ModeStorage = ModeStorage()
    ) -> Bool {
        do {
            try storage.save(modes)
        } catch {
            NSLog("[Type4Me] Failed to persist mode order/settings: %@", error.localizedDescription)
            DebugFileLogger.log("failed to persist mode order/settings: \(error)")
            return false
        }
        appState.availableModes = modes
        NotificationCenter.default.post(name: .modesDidChange, object: nil)
        if let updatedCurrentMode = modes.first(where: { $0.id == appState.currentMode.id }) {
            appState.currentMode = updatedCurrentMode
        } else if let fallback = modes.first {
            appState.currentMode = fallback
        }
        return true
    }
}
