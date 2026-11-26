import CoreGraphics
import Foundation

extension Notification.Name {
    static let pasteLastResultShortcutDidChange = Notification.Name("Type4Me.pasteLastResultShortcutDidChange")
}

enum PasteLastResultShortcut {
    static let storageKey = "tf_pasteLastResultHotkey"

    static var title: String { L("粘贴上一条结果", "Paste Last Result") }

    static func load(defaults: UserDefaults = .standard) -> HotkeyBinding? {
        guard let data = defaults.data(forKey: storageKey),
              let shortcut = try? JSONDecoder().decode(HotkeyBinding.self, from: data),
              accepts(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers ?? 0)
        else { return nil }
        return shortcut
    }

    static func save(_ shortcut: HotkeyBinding?) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) }
        UserDefaults.standard.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: .pasteLastResultShortcutDidChange, object: nil)
    }

    static func accepts(keyCode: Int, modifiers: UInt64) -> Bool {
        let flags = CGEventFlags(rawValue: modifiers).intersection(ModeBinding.standardModifierMask)
        guard (0...127).contains(keyCode), !ModeBinding.modifierKeyCodes.contains(keyCode),
              !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        else { return false }
        // Keep the system Paste shortcut available for normal clipboard use.
        return !(keyCode == 9 && flags == .maskCommand)
    }

    static func conflictsWithSavedShortcut(keyCode: Int, modifiers: UInt64?) -> Bool {
        guard let shortcut = load() else { return false }
        return conflicts(with: shortcut, keyCode: keyCode, modifiers: modifiers)
    }

    static func conflict(keyCode: Int, modifiers: UInt64?, modes: [ProcessingMode]) -> String? {
        if let manual = ManualInputSettings.load(modes: modes),
           conflicts(with: manual, keyCode: keyCode, modifiers: modifiers) {
            return L("手动输入", "Manual Input")
        }
        if let revise = ReviseSettingsStore.shared.load().hotkey,
           conflicts(with: revise, keyCode: keyCode, modifiers: modifiers) {
            return L("改口", "Revise")
        }
        return modes.first { mode in
            mode.allHotkeyBindings.contains { conflicts(with: $0, keyCode: keyCode, modifiers: modifiers) }
        }?.localizedDisplayName
    }

    static func conflicts(with binding: HotkeyBinding, keyCode: Int, modifiers: UInt64?) -> Bool {
        // Pressing another modifier can end an active modifier hold before
        // the regular key reaches the shortcut dispatcher.
        ModeBinding.hotkeysAreEquivalent(
            keyCode: keyCode, modifiers: modifiers,
            otherKeyCode: binding.keyCode, otherModifiers: binding.modifiers
        ) || ModeBinding.hasModifierPrefixConflict(
            keyCode: keyCode, modifiers: modifiers,
            otherKeyCode: binding.keyCode, otherModifiers: binding.modifiers
        ) || functionKeyConflictsWithHold(
            functionKeyCode: keyCode, functionModifiers: modifiers,
            modifierKeyCode: binding.keyCode, modifierFlags: binding.modifiers
        ) || functionKeyConflictsWithHold(
            functionKeyCode: binding.keyCode, functionModifiers: binding.modifiers,
            modifierKeyCode: keyCode, modifierFlags: modifiers
        )
    }

    private static func functionKeyConflictsWithHold(
        functionKeyCode: Int, functionModifiers: UInt64?,
        modifierKeyCode: Int, modifierFlags: UInt64?
    ) -> Bool {
        guard ModeBinding.isFunctionKeyCode(functionKeyCode),
              let held = ModeBinding.fullModifierFlags(keyCode: modifierKeyCode, modifiers: modifierFlags),
              held.contains(.maskSecondaryFn)
        else { return false }
        // F-key dispatch ignores Fn even when the key is held physically.
        let chord = ModeBinding.normalizedModifierFlags(
            CGEventFlags(rawValue: functionModifiers ?? 0), forKeyCode: functionKeyCode
        )
        return ModeBinding.normalizedModifierFlags(held, forKeyCode: functionKeyCode).isSubset(of: chord)
    }
}
