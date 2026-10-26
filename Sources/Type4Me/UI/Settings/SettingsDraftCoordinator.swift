import AppKit
import Foundation

@MainActor
final class SettingsDraftCoordinator {
    enum ParticipantID: Hashable {
        case modes
        case asrCredentials
        case llmCredentials
    }

    struct Participant {
        let isDirty: () -> Bool
        let save: () -> Bool
        let discard: () -> Void
    }

    private var participants: [ParticipantID: Participant] = [:]

    var hasUnsavedChanges: Bool {
        participants.values.contains { $0.isDirty() }
    }

    func register(
        _ id: ParticipantID,
        isDirty: @escaping () -> Bool,
        save: @escaping () -> Bool,
        discard: @escaping () -> Void
    ) {
        participants[id] = Participant(
            isDirty: isDirty,
            save: save,
            discard: discard
        )
    }

    func unregister(_ id: ParticipantID) {
        participants.removeValue(forKey: id)
    }

    @discardableResult
    func saveAll() -> Bool {
        for participant in participants.values where participant.isDirty() {
            guard participant.save() else { return false }
        }
        return true
    }

    func discardAll() {
        for participant in participants.values where participant.isDirty() {
            participant.discard()
        }
    }

    enum ConfirmationResult {
        case saved
        case discarded
        case cancelled
    }

    func confirmUnsavedChanges(
        on window: NSWindow? = nil,
        title: String = L("是否保存所做的更改？", "Do you want to save the changes?"),
        message: String = L("如果不保存，您所做的更改将会丢失。", "Your changes will be lost if you don't save them."),
        completion: @escaping (ConfirmationResult) -> Void
    ) {
        guard hasUnsavedChanges else {
            completion(.saved)
            return
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning

        // Button 1 (Default / Return): Save
        let saveButton = alert.addButton(withTitle: L("保存", "Save"))
        saveButton.keyEquivalent = "\r"

        // Button 2 (Cancel / Esc): Cancel
        let cancelButton = alert.addButton(withTitle: L("取消", "Cancel"))
        cancelButton.keyEquivalent = "\u{1b}"

        // Button 3 (Destructive / ⌘D): Don't Save
        let discardButton = alert.addButton(withTitle: L("不保存", "Don't Save"))
        discardButton.keyEquivalent = "d"
        discardButton.keyEquivalentModifierMask = .command

        let effectiveWindow = window ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && !$0.isMiniaturized }

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else {
                completion(.cancelled)
                return
            }
            switch response {
            case .alertFirstButtonReturn:
                if self.saveAll() {
                    completion(.saved)
                } else {
                    completion(.cancelled)
                }
            case .alertThirdButtonReturn:
                self.discardAll()
                completion(.discarded)
            default:
                completion(.cancelled)
            }
        }

        if let win = effectiveWindow {
            alert.beginSheetModal(for: win, completionHandler: handleResponse)
        } else {
            let response = alert.runModal()
            handleResponse(response)
        }
    }
}

@MainActor
final class WeakSettingsWindowBox {
    weak var window: NSWindow?
}
