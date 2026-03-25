import AppKit
import ApplicationServices

/// Captures context variables available for LLM prompt template expansion.
/// Captured at recording start so `{selected}` reflects the user's selection
/// before any text injection occurs.
struct PromptContext: Sendable {
    let selectedText: String
    let clipboardText: String

    /// Capture the current selected text (via Accessibility) and clipboard content.
    /// AX calls are synchronous IPC and can hang if the target app is unresponsive,
    /// so we run them on a background thread with a short timeout.
    static func capture() -> PromptContext {
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let selected = readSelectedTextWithTimeout(ms: 200) ?? ""
        return PromptContext(selectedText: selected, clipboardText: clipboard)
    }

    /// Expand context variables (`{selected}`, `{clipboard}`) in a prompt string.
    /// Note: `{text}` is expanded separately by the LLM client with the ASR output.
    func expandContextVariables(_ prompt: String) -> String {
        prompt
            .replacingOccurrences(of: "{selected}", with: selectedText)
            .replacingOccurrences(of: "{clipboard}", with: clipboardText)
    }

    // MARK: - Private

    /// Read selected text with a hard timeout to prevent UI hangs.
    /// AXUIElementCopyAttributeValue is synchronous IPC — if the target app's
    /// accessibility implementation is slow or deadlocked, it blocks indefinitely.
    private static func readSelectedTextWithTimeout(ms: Int) -> String? {
        guard AXIsProcessTrusted() else { return nil }

        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            result = readSelectedText()
            semaphore.signal()
        }

        let timeout = DispatchTime.now() + .milliseconds(ms)
        if semaphore.wait(timeout: timeout) == .timedOut {
            return nil
        }
        return result
    }

    private static func readSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return nil
        }

        let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedRef
        ) == .success else {
            return nil
        }

        return selectedRef as? String
    }
}
