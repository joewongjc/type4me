import AppKit
import ApplicationServices
import os

/// Captures context variables available for LLM prompt template expansion.
/// Captured at recording start so `{selected}` reflects the user's selection
/// before any text injection occurs.
struct PromptContext: Sendable {
    let selectedText: String
    let clipboardText: String
    static let empty = PromptContext(selectedText: "", clipboardText: "")

    /// Capture the current selected text (via Accessibility) and clipboard content.
    /// Clipboard is read on MainActor (AppKit requirement).
    /// AX calls run on a detached task with a short timeout.
    static func capture() async -> PromptContext {
        let clipboard = await MainActor.run {
            NSPasteboard.general.string(forType: .string) ?? ""
        }
        let selected = await readSelectedTextAsync(timeoutMs: 200)
        return PromptContext(selectedText: selected, clipboardText: clipboard)
    }

    /// Expand context variables (`{selected}`, `{clipboard}`) in a prompt string.
    /// Uses single-pass replacement to prevent user content containing `{clipboard}`
    /// or `{text}` from being expanded as variables.
    func expandContextVariables(_ prompt: String) -> String {
        var result = ""
        var remaining = prompt[...]

        while let openRange = remaining.range(of: "{") {
            result += remaining[remaining.startIndex..<openRange.lowerBound]
            remaining = remaining[openRange.lowerBound...]

            if remaining.hasPrefix("{selected}") {
                result += selectedText
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 10)...]
            } else if remaining.hasPrefix("{clipboard}") {
                result += clipboardText
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 11)...]
            } else {
                result += "{"
                remaining = remaining[remaining.index(after: remaining.startIndex)...]
            }
        }
        result += remaining
        return result
    }

    static func referencesSensitiveVariables(in prompt: String) -> Bool {
        prompt.contains("{selected}") || prompt.contains("{clipboard}")
    }

    // MARK: - Private

    /// Read selected text with a hard timeout to prevent hangs.
    /// AXUIElementCopyAttributeValue is synchronous IPC — if the target app's
    /// accessibility implementation is slow or deadlocked, it blocks indefinitely.
    /// Uses two racing detached tasks (AX read vs timeout) with OSAllocatedUnfairLock
    /// to ensure the continuation is resumed exactly once.
    private static func readSelectedTextAsync(timeoutMs: Int) async -> String {
        guard AXIsProcessTrusted() else { return "" }
        return await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            Task.detached {
                let text = readSelectedText() ?? ""
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: text)
                }
            }
            Task.detached {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: "")
                }
            }
        }
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
