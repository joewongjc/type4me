import Foundation
import CoreGraphics

extension Notification.Name {
    static let manualInputSettingsDidChange = Notification.Name("Type4Me.manualInputSettingsDidChange")
}

/// One launcher binding. Legacy per-mode bindings are read only for migration.
enum ManualInputSettings {
    static let storageKey = "tf_manualInputHotkeyV2"
    static let bindingID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private struct Stored: Codable { var hotkey: HotkeyBinding? }

    static func load(modes: [ProcessingMode], defaults: UserDefaults = .standard) -> HotkeyBinding? {
        if let data = defaults.data(forKey: storageKey) {
            return (try? JSONDecoder().decode(Stored.self, from: data))?.hotkey
        }
        let fallback = HotkeyBinding(id: bindingID, keyCode: 49,
                             modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue, style: .toggle)
        let candidate = (modes.compactMap(\.manualInputHotkey) + [fallback]).first {
            conflict(keyCode: $0.keyCode, modifiers: $0.modifiers, modes: modes) == nil
        }
        let binding = candidate.map {
            HotkeyBinding(id: bindingID, keyCode: $0.keyCode, modifiers: $0.modifiers, style: .toggle)
        }
        save(binding, defaults: defaults, notify: false)
        return binding
    }

    static func save(_ binding: HotkeyBinding?, defaults: UserDefaults = .standard, notify: Bool = true) {
        let normalized = binding.map {
            HotkeyBinding(id: bindingID, keyCode: $0.keyCode, modifiers: $0.modifiers, style: .toggle)
        }
        guard let data = try? JSONEncoder().encode(Stored(hotkey: normalized)) else { return }
        defaults.set(data, forKey: storageKey)
        if notify { NotificationCenter.default.post(name: .manualInputSettingsDidChange, object: nil) }
    }

    static func conflict(keyCode: Int, modifiers: UInt64?, modes: [ProcessingMode]) -> String? {
        if let mode = modes.first(where: { mode in
            mode.hotkeyBindings.contains {
                ModeBinding.hotkeysAreEquivalent(keyCode: keyCode, modifiers: modifiers,
                                                 otherKeyCode: $0.keyCode, otherModifiers: $0.modifiers)
            }
        }) { return mode.localizedDisplayName }
        let revise = ReviseSettingsStore.shared.load()
        if revise.enabled, let key = revise.hotkey,
           ModeBinding.hotkeysAreEquivalent(keyCode: keyCode, modifiers: modifiers,
                                            otherKeyCode: key.keyCode, otherModifiers: key.modifiers) {
            return L("改口", "Revise")
        }
        return nil
    }

    static func matches(keyCode: Int, modifiers: UInt64?, modes: [ProcessingMode]) -> Bool {
        guard let key = load(modes: modes) else { return false }
        return ModeBinding.hotkeysAreEquivalent(keyCode: keyCode, modifiers: modifiers,
                                               otherKeyCode: key.keyCode, otherModifiers: key.modifiers)
    }
}
