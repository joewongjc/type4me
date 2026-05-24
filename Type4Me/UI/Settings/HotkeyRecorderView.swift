import SwiftUI
import Carbon.HIToolbox

struct HotkeyRecorderView: View {

    @Binding var keyCode: Int?
    @Binding var modifiers: UInt64?

    @State private var isRecording = false
    @State private var eventMonitor: Any?
    @State private var pendingModifierCode: Int?
    @State private var pendingModifierModifiers: UInt64 = 0
    @State private var modifierCaptureTask: Task<Void, Never>?
    @State private var recordingTimeoutTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            // Display current hotkey
            Text(displayText)
                .font(.system(size: 12))
                .foregroundStyle(isRecording ? TF.settingsAccentRed : TF.settingsTextSecondary)
                .frame(minWidth: 100, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isRecording
                                ? TF.settingsAccentRed.opacity(0.5)
                                : TF.settingsTextTertiary.opacity(0.2),
                            lineWidth: 1
                        )
                )

            if isRecording {
                Button(L("取消", "Cancel")) { stopRecording() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TF.settingsTextSecondary)
            } else {
                Button(L("录制", "Record")) { startRecording() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TF.settingsTextSecondary)

                if keyCode != nil {
                    Button(L("清除", "Clear")) {
                        keyCode = nil
                        modifiers = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    // MARK: - Display

    private var displayText: String {
        if isRecording { return L("按下快捷键、鼠标或耳机按键...", "Press a key, mouse or headphone button...") }
        guard let kc = keyCode else { return L("未设置", "Not set") }
        return Self.keyDisplayName(keyCode: kc, modifiers: modifiers)
    }

    // MARK: - Recording

    private func startRecording() {
        isRecording = true
        pendingModifierCode = nil
        modifierCaptureTask?.cancel()
        modifierCaptureTask = nil

        // Safety timeout: auto-stop recording after 10s (covers opacity-hidden tabs where onDisappear won't fire)
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await MainActor.run { stopRecording() }
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .otherMouseDown, .systemDefined]) { event in
            // Media key pressed (headphone buttons, keyboard media keys)
            if event.type == .systemDefined {
                guard event.subtype.rawValue == 8 else { return event }
                let keyType = Int((event.data1 >> 16) & 0xFFFF)
                let keyState = Int((event.data1 >> 8) & 0xFF)
                guard keyState == 0x0A else { return event }  // key down only
                guard Self.isKnownMediaKeyType(keyType) else { return event }

                modifierCaptureTask?.cancel()
                modifierCaptureTask = nil
                pendingModifierCode = nil

                keyCode = ModeBinding.mediaKeyCode(for: keyType)
                modifiers = 0
                stopRecording()
                return nil
            }

            // Mouse button pressed (middle click, side buttons)
            if event.type == .otherMouseDown {
                let buttonNumber = event.buttonNumber
                // Cancel any pending modifier-only capture
                modifierCaptureTask?.cancel()
                modifierCaptureTask = nil
                pendingModifierCode = nil

                keyCode = ModeBinding.mouseKeyCode(for: buttonNumber)
                modifiers = 0
                stopRecording()
                return nil  // Swallow the mouse event
            }

            if event.type == .flagsChanged {
                let kc = Int(event.keyCode)
                guard Self.modifierKeyCodes.contains(kc) else { return event }
                let pressed = isModifierPressed(keyCode: kc, flags: event.modifierFlags)

                if pressed {
                    // Modifier pressed: record co-modifiers, wait for possible combo key
                    pendingModifierCode = kc
                    pendingModifierModifiers = modifierComboModifiers(for: kc, flags: event.modifierFlags)
                    modifierCaptureTask?.cancel()
                    modifierCaptureTask = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard let pending = pendingModifierCode else { return }
                            captureModifierOnlyKey(pending, modifiers: pendingModifierModifiers)
                        }
                    }
                } else {
                    // Modifier released: capture with co-modifiers
                    if let pending = pendingModifierCode {
                        modifierCaptureTask?.cancel()
                        modifierCaptureTask = nil
                        keyCode = pending
                        modifiers = pendingModifierModifiers
                        pendingModifierCode = nil
                        pendingModifierModifiers = 0
                        stopRecording()
                    }
                }
                return event
            }

            if event.type == .keyDown {
                let kc = Int(event.keyCode)
                // Cancel any pending modifier-only capture
                modifierCaptureTask?.cancel()
                modifierCaptureTask = nil
                pendingModifierCode = nil

                // Escape cancels
                if kc == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty {
                    stopRecording()
                    return nil
                }
                keyCode = kc
                // Store modifier flags, stripping noise (capsLock, numericPad, function)
                let clean = event.modifierFlags.intersection([.command, .shift, .option, .control])
                modifiers = clean.isEmpty ? 0 : UInt64(clean.rawValue)
                stopRecording()
                return nil
            }

            return event
        }
    }

    @MainActor
    private func captureModifierOnlyKey(_ keyCode: Int, modifiers: UInt64 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        modifierCaptureTask?.cancel()
        modifierCaptureTask = nil
        pendingModifierCode = nil
        pendingModifierModifiers = 0
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Modifier Press Detection

    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    static func isKnownMediaKeyType(_ keyType: Int) -> Bool {
        [0, 1, 7, 16, 17, 18, 19, 20].contains(keyType)
    }

    private func isModifierPressed(keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.command)
        case 56, 60: return flags.contains(.shift)
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        case 63: return flags.contains(.function)
        default: return false
        }
    }

    // MARK: - Modifier Combo Helpers

    private func modifierFlag(for keyCode: Int) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        default: return nil
        }
    }

    private func modifierComboModifiers(for keyCode: Int, flags: NSEvent.ModifierFlags) -> UInt64 {
        var clean = flags.intersection([.command, .shift, .option, .control])
        if let own = modifierFlag(for: keyCode) {
            clean.remove(own)
        }
        return clean.isEmpty ? 0 : UInt64(clean.rawValue)
    }

    // MARK: - Key Display Name

    static func keyDisplayName(keyCode: Int, modifiers: UInt64?) -> String {
        // Mouse buttons and media keys: no modifier combos, just the name
        if ModeBinding.isMouseKeyCode(keyCode) || ModeBinding.isMediaKeyCode(keyCode) {
            return singleKeyName(keyCode)
        }

        let mods = modifiers ?? 0
        var parts: [String] = []
        if mods != 0 {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(mods))
            if flags.contains(.control) { parts.append("⌃") }
            if flags.contains(.option) { parts.append("⌥") }
            if flags.contains(.shift) { parts.append("⇧") }
            if flags.contains(.command) { parts.append("⌘") }
        }
        parts.append(singleKeyName(keyCode))
        return parts.joined(separator: "+")
    }

    static func singleKeyName(_ keyCode: Int) -> String {
        // Mouse buttons (high-bit keyCode convention: 0x8000 + buttonNumber)
        if ModeBinding.isMouseKeyCode(keyCode) {
            let btn = ModeBinding.mouseButtonNumber(from: keyCode)
            switch btn {
            case 2: return L("鼠标中键", "Mouse Middle")
            default: return L("鼠标 \(btn + 1)", "Mouse \(btn + 1)")  // button 3 → "Mouse 4", etc.
            }
        }

        // Media keys (high-bit keyCode convention: 0x9000 + NX_KEYTYPE)
        if ModeBinding.isMediaKeyCode(keyCode) {
            let keyType = ModeBinding.mediaKeyType(from: keyCode)
            switch keyType {
            case 0:  return L("音量↑", "Vol ↑")
            case 1:  return L("音量↓", "Vol ↓")
            case 7:  return L("静音", "Mute")
            case 16: return L("播放/暂停", "Play/Pause")
            case 17: return L("下一曲", "Next")
            case 18: return L("上一曲", "Prev")
            case 19: return L("快进", "Fast")
            case 20: return L("快退", "Rewind")
            default: return L("媒体键\(keyType)", "Media\(keyType)")
            }
        }

        switch keyCode {
        // Modifier keys
        case 54: return "Right Command"
        case 55: return "Left Command"
        case 56: return "Left Shift"
        case 58: return "Left Option"
        case 59: return "Left Control"
        case 60: return "Right Shift"
        case 61: return "Right Option"
        case 62: return "Right Control"
        case 63: return "fn"

        // Special keys
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 76: return "Enter"
        case 117: return "Forward Delete"

        // Arrows
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"

        // F-keys
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"

        default:
            return ucKeyTranslateName(keyCode) ?? "Key \(keyCode)"
        }
    }

    // MARK: - UCKeyTranslate Fallback

    private static func ucKeyTranslateName(_ keyCode: Int) -> String? {
        guard let source = (TISCopyCurrentASCIICapableKeyboardInputSource() ?? TISCopyCurrentKeyboardInputSource())?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = unsafeBitCast(layoutPtr, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var length: Int = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
