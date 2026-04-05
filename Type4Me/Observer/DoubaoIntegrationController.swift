import AppKit
import ApplicationServices
import Foundation

extension Notification.Name {
    static let doubaoIntegrationDidChange = Notification.Name("Type4Me.doubaoIntegrationDidChange")
}

/// Coordinates DoubaoIme ASR observation with post-processing.
/// This is the main entry point for the豆包输入法 integration feature.
///
/// Usage in AppDelegate:
///   let doubaoController = DoubaoIntegrationController()
///   doubaoController.startIfEnabled()
///
/// LLM mode arming:
///   doubaoController.armLLMMode(mode)  // call from hotkey handler
@MainActor
final class DoubaoIntegrationController: DoubaoASRObserver.Delegate {

    private let observer = DoubaoASRObserver()
    private let postProcessor = PostProcessorSession()

    /// Set by AppDelegate so we can suppress the tap during simulated key events.
    weak var hotkeyManager: HotkeyManager?

    // MARK: - LLM Mode Arming

    /// The LLM mode armed for the next ASR session.
    /// Set by hotkey, cleared after one use.
    private(set) var armedMode: ProcessingMode?

    /// Callback when armed mode changes (for UI indicator).
    var onArmedModeChanged: ((ProcessingMode?) -> Void)?

    /// The key code for DoubaoIme's ASR trigger (Right Control = 0x3E = 62).
    /// Stored in UserDefaults so it can be changed in settings.
    static let doubaoHotkeyKey = "tf_doubaoASRKeyCode"
    private var doubaoASRKeyCode: CGKeyCode {
        let stored = UserDefaults.standard.integer(forKey: Self.doubaoHotkeyKey)
        return stored > 0 ? CGKeyCode(stored) : 62  // default: Right Control
    }

    /// Pre-captured cursor state, recorded when mode is armed (before DoubaoIme takes focus).
    private(set) var preArmedCursorPos: Int?
    private(set) var preArmedElement: AXUIElement?

    func armLLMMode(_ mode: ProcessingMode) {
        armedMode = mode
        onArmedModeChanged?(mode)

        // Capture cursor position NOW, before DoubaoIme's panel steals focus
        let snapshot = observer.readFocusedTextFieldState()
        preArmedCursorPos = snapshot.cursorPosition
        preArmedElement = snapshot.element
        // Pass to observer so onASRStart uses these instead of reading (possibly nil) live values
        observer.overrideStartElement = snapshot.element
        observer.overrideStartCursorPos = snapshot.cursorPosition
        DebugFileLogger.log("[DoubaoIntegration] Armed LLM mode: \(mode.name), preCursor=\(snapshot.cursorPosition.map(String.init) ?? "nil")")
    }

    /// Simulate a double-tap of the DoubaoIme ASR hotkey to enter toggle/continuous mode.
    /// Suppresses HotkeyManager during simulation to prevent self-interception.
    func triggerDoubaoASR() {
        let keyCode = doubaoASRKeyCode
        DebugFileLogger.log("[DoubaoIntegration] Triggering DoubaoIme double-tap: keyCode=\(keyCode)")

        hotkeyManager?.isSuppressed = true

        Task.detached { [weak self] in
            // Tap 1
            self?.postModifierKeyEvent(keyCode: keyCode, isPress: true)
            usleep(30_000)  // 30ms hold
            self?.postModifierKeyEvent(keyCode: keyCode, isPress: false)

            usleep(80_000)  // 80ms gap

            // Tap 2
            self?.postModifierKeyEvent(keyCode: keyCode, isPress: true)
            usleep(30_000)
            self?.postModifierKeyEvent(keyCode: keyCode, isPress: false)

            usleep(100_000) // wait for events to be processed

            await MainActor.run { [weak self] in
                self?.hotkeyManager?.isSuppressed = false
            }
        }
    }

    /// Simulate a double-tap to stop DoubaoIme's toggle/continuous recognition.
    func stopDoubaoASR() {
        let keyCode = doubaoASRKeyCode
        DebugFileLogger.log("[DoubaoIntegration] Stopping DoubaoIme double-tap: keyCode=\(keyCode)")

        hotkeyManager?.isSuppressed = true

        Task.detached { [weak self] in
            // Tap 1
            self?.postModifierKeyEvent(keyCode: keyCode, isPress: true)
            usleep(30_000)
            self?.postModifierKeyEvent(keyCode: keyCode, isPress: false)

            usleep(80_000)

            // Tap 2
            self?.postModifierKeyEvent(keyCode: keyCode, isPress: true)
            usleep(30_000)
            self?.postModifierKeyEvent(keyCode: keyCode, isPress: false)

            usleep(100_000)

            await MainActor.run { [weak self] in
                self?.hotkeyManager?.isSuppressed = false
            }
        }
    }

    nonisolated private func postModifierKeyEvent(keyCode: CGKeyCode, isPress: Bool) {
        guard let event = CGEvent(source: nil) else { return }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        event.flags = isPress ? flagsForModifierKey(keyCode) : []
        event.post(tap: .cghidEventTap)
    }

    nonisolated private func flagsForModifierKey(_ keyCode: CGKeyCode) -> CGEventFlags {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        default: return []
        }
    }

    func disarmLLMMode() {
        armedMode = nil
        onArmedModeChanged?(nil)
        DebugFileLogger.log("[DoubaoIntegration] Disarmed LLM mode")
    }

    // MARK: - Lifecycle

    /// UserDefaults key for enabling/disabling the integration.
    static let enabledKey = "tf_doubaoIntegrationEnabled"

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func startIfEnabled() {
        let enabled = isEnabled
        DebugFileLogger.log("DoubaoIntegration startIfEnabled: \(enabled)")
        guard enabled else { return }
        start()
    }

    func start() {
        observer.delegate = self
        observer.startObserving()
        registerForHookNotifications()
        NSLog("[DoubaoIntegration] Started")
    }

    // MARK: - Hook Notification (from DoubaoHook dylib)

    private var hookNotificationObserver: Any?

    /// Listen for NSDistributedNotification from the DoubaoHook dylib.
    /// When hook detects a snippet match, it sends the raw + processed text.
    /// We do backspace + paste to replace inline.
    private func registerForHookNotifications() {
        hookNotificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("Type4Me.DoubaoASRTextInserted"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let rawText = userInfo["rawText"] as? String,
                  let processedText = userInfo["processedText"] as? String,
                  let charCount = userInfo["charCount"] as? Int,
                  processedText != rawText
            else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }

                // Cooldown: skip if we just did a replacement
                let elapsed = Date().timeIntervalSince(self.lastReplacementTime)
                if elapsed < Self.cooldownSeconds {
                    DebugFileLogger.log("[DoubaoIntegration] Cooldown skip (\(String(format: "%.1f", elapsed))s)")
                    return
                }

                DebugFileLogger.log("[DoubaoIntegration] Hook notification: \(charCount) chars → '\(processedText.prefix(30))'")

                // Brief delay to ensure insertText has fully completed
                try? await Task.sleep(for: .milliseconds(100))

                let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                let isTerminal = Self.terminalBundleIDs.contains(bundleID)

                if isTerminal {
                    await self.replaceViaBackspace(charCount: charCount, replacement: processedText)
                } else {
                    await self.replaceViaUndo(charCount: charCount, replacement: processedText)
                }
                self.lastReplacementTime = Date()
            }
        }
    }

    /// Prevents concurrent replacement operations from interleaving clipboard state.
    private var isReplacing = false
    /// Cooldown: ignore notifications within 1s of last replacement
    private var lastReplacementTime: Date = .distantPast
    private static let cooldownSeconds: TimeInterval = 1.0

    /// Terminal bundle IDs where Cmd+Z doesn't undo text input
    private static let terminalBundleIDs: Set<String> = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "io.alacritty",
    ]

    /// Replace the just-committed ASR text using Cmd+Z (undo) + paste.
    /// Cmd+Z undoes the entire insertText in one shot, much more reliable
    /// than N individual backspaces for long text.
    private func replaceViaUndo(charCount: Int, replacement: String) async {
        // Wait for any in-flight replacement to finish
        while isReplacing {
            try? await Task.sleep(for: .milliseconds(50))
        }
        isReplacing = true
        defer { isReplacing = false }

        // Step 1: Write replacement to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(replacement, forType: .string)

        try? await Task.sleep(for: .milliseconds(30))

        // Step 2: Cmd+Z to undo the entire ASR insertText
        let zKeyCode: CGKeyCode = 6
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: zKeyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: zKeyCode, keyDown: false) {
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        try? await Task.sleep(for: .milliseconds(100))

        // Step 3: Cmd+V to paste replacement
        let vKeyCode: CGKeyCode = 9
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) {
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        try? await Task.sleep(for: .milliseconds(100))

        DebugFileLogger.log("[DoubaoIntegration] Replaced via undo: \(charCount) chars → '\(replacement.prefix(30))'")
    }

    /// Replace via backspace + paste (for terminals where Cmd+Z doesn't work).
    private func replaceViaBackspace(charCount: Int, replacement: String) async {
        while isReplacing {
            try? await Task.sleep(for: .milliseconds(50))
        }
        isReplacing = true
        defer { isReplacing = false }

        // Step 1: Write replacement to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(replacement, forType: .string)

        try? await Task.sleep(for: .milliseconds(30))

        // Step 2: Backspace to delete ASR text
        // Send in batches of 10 with longer pauses between batches
        // to ensure terminal processes them all before paste
        let backspaceKeyCode: CGKeyCode = 51
        let batchSize = 10
        for i in 0..<charCount {
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: false)
            else { continue }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(5_000)  // 5ms between keys
            if (i + 1) % batchSize == 0 {
                usleep(30_000)  // 30ms pause every 10 keys for terminal to catch up
            }
        }

        // Final wait to ensure all backspaces are fully processed
        let waitMs = max(200, charCount * 3)
        try? await Task.sleep(for: .milliseconds(waitMs))

        // Step 3: Cmd+V to paste replacement
        let vKeyCode: CGKeyCode = 9
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) {
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        try? await Task.sleep(for: .milliseconds(100))

        DebugFileLogger.log("[DoubaoIntegration] Replaced via backspace: \(charCount) chars → '\(replacement.prefix(30))'")
    }

    func stop() {
        observer.stopObserving()
        disarmLLMMode()
        NSLog("[DoubaoIntegration] Stopped")
    }

    // MARK: - ASR Observer Delegate

    /// Snapshot state saved at ASR start for use in doubaoASRDidEnd.
    private var pendingElement: AXUIElement?
    private var pendingStartPos: Int?

    nonisolated func doubaoASRDidStart(element: AXUIElement, cursorPosition: Int) {
        Task { @MainActor in
            self.pendingElement = element
            self.pendingStartPos = cursorPosition
        }
    }

    nonisolated func doubaoASRDidEnd(
        element: AXUIElement,
        startCursorPosition: Int,
        endCursorPosition: Int,
        asrText: String
    ) {
        Task { @MainActor in
            guard !asrText.isEmpty else { return }

            let mode = self.armedMode

            // Clear armed mode after use (one-shot)
            if mode != nil {
                self.disarmLLMMode()
            }

            let asr = PostProcessorSession.ASRResult(
                element: element,
                startPos: startCursorPosition,
                endPos: endCursorPosition,
                rawText: asrText
            )

            await self.postProcessor.process(asr: asr, armedMode: mode)
        }
    }
}
