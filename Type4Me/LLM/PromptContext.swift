import AppKit
import ApplicationServices

/// Captures context variables available for LLM prompt template expansion.
/// Captured at recording start so `{selected}` reflects the user's selection
/// before any text injection occurs.
struct PromptContext: Sendable {
    let selectedText: String
    let clipboardText: String

    /// Capture the current selected text (via Accessibility) and clipboard content.
    /// Clipboard is read on MainActor (AppKit requirement).
    /// AX calls run on a background thread with a short timeout.
    @MainActor
    static func capture() -> PromptContext {
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let selected = readSelectedTextWithTimeout(ms: 200) ?? ""
        return PromptContext(selectedText: selected, clipboardText: clipboard)
    }

    /// Expand context variables (`{selected}`, `{clipboard}`) in a prompt string.
    /// Uses single-pass replacement to prevent user content containing `{clipboard}`
    /// or `{text}` from being expanded as variables.
    func expandContextVariables(_ prompt: String) -> String {
        var result = ""
        var remaining = prompt[...]

        while let openRange = remaining.range(of: "{") {
            // Append everything before the `{`
            result += remaining[remaining.startIndex..<openRange.lowerBound]
            remaining = remaining[openRange.lowerBound...]

            if remaining.hasPrefix("{selected}") {
                result += selectedText
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 10)...]
            } else if remaining.hasPrefix("{clipboard}") {
                result += clipboardText
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 11)...]
            } else {
                // Not a known variable, keep the `{` literal and advance past it
                result += "{"
                remaining = remaining[remaining.index(after: remaining.startIndex)...]
            }
        }
        result += remaining
        return result
    }

    // MARK: - Private

    /// Read selected text with a hard timeout to prevent UI hangs.
    /// AXUIElementCopyAttributeValue is synchronous IPC — if the target app's
    /// accessibility implementation is slow or deadlocked, it blocks indefinitely.
    /// Uses a heap-allocated box to avoid write-after-return on the stack.
    private static func readSelectedTextWithTimeout(ms: Int) -> String? {
        guard AXIsProcessTrusted() else { return nil }

        final class Box: @unchecked Sendable { var value: String?; init() {} }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            box.value = readSelectedText()
            semaphore.signal()
        }

        let timeout = DispatchTime.now() + .milliseconds(ms)
        if semaphore.wait(timeout: timeout) == .timedOut {
            return nil
        }
        return box.value
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
