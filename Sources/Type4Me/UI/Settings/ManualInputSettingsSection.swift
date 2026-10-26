import SwiftUI

struct ManualInputSettingsSection: View, SettingsCardHelpers {
    @Environment(AppState.self) private var appState
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault
    @State private var hotkey = ManualInputSettings.load(modes: ModeStorage().load())
    @State private var recordingTarget: RecordingTarget?
    @State private var saveFailed = false

    var body: some View {
        settingsGroupCard(L("手动输入", "Manual Input"), icon: "keyboard") {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("输入文字，再选模式。", "Type, then choose a mode."))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
                HotkeySectionView(
                    bindings: hotkey.map { [$0] } ?? [],
                    onEdit: { beginRecording($0) },
                    onDelete: { _ in
                        ManualInputSettings.save(nil)
                        hotkey = nil
                    },
                    onAdd: { beginRecording(nil) },
                    showsHeader: false,
                    showsAddButton: hotkey == nil
                )
                .padding(.vertical, 2)
            }
            .padding(.vertical, 4)
        }
        .sheet(item: $recordingTarget) { target in
            let modes = ModeStorage().load()
            HotkeyRecordingSheet(
                target: target,
                checkConflict: ModeHotkeyEditing.makeConflictCheck(in: modes, target: target),
                checkDuplicateInMode: ModeHotkeyEditing.makeDuplicateCheck(in: modes, target: target),
                checkPrefixConflict: ModeHotkeyEditing.makePrefixConflictCheck(in: modes, target: target),
                onConfirm: { code, mods, _ in
                    guard ModeHotkeyEditing.makeReservedConflictCheck(for: target)(code, mods) == nil else { return }
                    var updatedModes = ModeStorage().load()
                    let transferred = ModeHotkeyEditing.removeConflictingBindings(
                        keyCode: code, modifiers: mods, from: &updatedModes)
                    // Keep the existing shortcut if persisting the transfer fails.
                    if transferred && !ModeHotkeyEditing.persistModes(updatedModes, appState: appState) {
                        saveFailed = true
                        return
                    }
                    hotkey = HotkeyBinding(id: ManualInputSettings.bindingID, keyCode: code, modifiers: mods, style: .toggle)
                    ManualInputSettings.save(hotkey)
                    recordingTarget = nil
                },
                onCancel: { recordingTarget = nil })
            .alert(L("未能保存快捷键", "Couldn't Save Shortcut"), isPresented: $saveFailed) {
                Button(L("好", "OK"), role: .cancel) { }
            } message: {
                Text(L("请重试，原快捷键仍然保留。", "Please try again. Your previous shortcut is still saved."))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .manualInputSettingsDidChange)) { _ in
            hotkey = ManualInputSettings.load(modes: ModeStorage().load())
        }
    }

    private func beginRecording(_ binding: HotkeyBinding?) {
        recordingTarget = RecordingTarget(
            modeId: ManualInputSettings.bindingID, modeName: L("手动输入", "Manual Input"),
            editingBindingId: binding?.id, initialKeyCode: binding?.keyCode,
            initialModifiers: binding?.modifiers, initialStyle: .toggle, isManualInput: true)
    }
}
