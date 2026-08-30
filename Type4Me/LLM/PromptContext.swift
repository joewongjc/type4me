import AppKit
import ApplicationServices
import os

/// Captures context variables available for LLM prompt template expansion.
/// Captured at recording start so `{selected}` reflects the user's selection
/// before any text injection occurs.
struct PromptContext: Sendable {
    struct CaptureRequirements: OptionSet, Sendable {
        let rawValue: UInt8

        static let selected = CaptureRequirements(rawValue: 1 << 0)
        static let clipboard = CaptureRequirements(rawValue: 1 << 1)

        var logDescription: String {
            var names: [String] = []
            if contains(.selected) { names.append("selected") }
            if contains(.clipboard) { names.append("clipboard") }
            return names.isEmpty ? "none" : names.joined(separator: ",")
        }
    }

    let selectedText: String
    let clipboardText: String

    static let empty = PromptContext(selectedText: "", clipboardText: "")

    /// Return only the context fields referenced by a prompt. Some modes use
    /// selection outside their prompt template and can request it explicitly.
    static func captureRequirements(
        for prompt: String,
        requiresSelection: Bool = false
    ) -> CaptureRequirements {
        var requirements: CaptureRequirements = []
        if requiresSelection || prompt.contains("{selected}") {
            requirements.insert(.selected)
        }
        if prompt.contains("{clipboard}") {
            requirements.insert(.clipboard)
        }
        return requirements
    }

    /// Capture only the requested fields. Clipboard is read before the
    /// selected-text fallback because that fallback temporarily replaces it.
    /// AX calls run on a detached task with a short timeout.
    static func capture(
        requirements: CaptureRequirements = [.selected, .clipboard]
    ) async -> PromptContext {
        guard !requirements.isEmpty else { return .empty }

        let clipboard: String
        if requirements.contains(.clipboard) {
            clipboard = await MainActor.run {
                NSPasteboard.general.string(forType: .string) ?? ""
            }
        } else {
            clipboard = ""
        }

        var selected = ""
        if requirements.contains(.selected) {
            let axSelectedText = await readSelectedTextAsync(timeoutMs: 500)
            selected = shouldUseTemporaryCopy(axSelectedText: axSelectedText)
                ? await readSelectedTextByTemporaryCopy(timeoutMs: 250)
                : (axSelectedText ?? "")
        }
        return PromptContext(selectedText: selected, clipboardText: clipboard)
    }

    func merging(_ other: PromptContext) -> PromptContext {
        PromptContext(
            selectedText: other.selectedText.isEmpty ? selectedText : other.selectedText,
            clipboardText: other.clipboardText.isEmpty ? clipboardText : other.clipboardText
        )
    }

    /// An empty string is a successful AX result meaning the focused control has
    /// no selection. Simulating Command+C in that case makes many apps play the
    /// macOS error beep. Only fall back to temporary copy when AX is unavailable,
    /// unsupported, or timed out (`nil`).
    internal static func shouldUseTemporaryCopy(axSelectedText: String?) -> Bool {
        axSelectedText == nil
    }

    /// Expand context variables (`{selected}`, `{clipboard}`, `{tools_json}`) in
    /// a prompt string. Uses single-pass replacement to prevent user content
    /// containing `{clipboard}` or `{text}` from being expanded as variables.
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
            } else if remaining.hasPrefix("{tools_json}") {
                result += ActionRegistry.toolsJSON()
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 12)...]
            } else {
                result += "{"
                remaining = remaining[remaining.index(after: remaining.startIndex)...]
            }
        }
        result += remaining
        return result
    }

    /// Expand only app-controlled prompt variables that are safe to keep in a
    /// system message. User-controlled selection and clipboard values remain
    /// as placeholders so the LLM layer can place them in user/data blocks.
    func expandTrustedContextVariables(_ prompt: String) -> String {
        prompt.replacingOccurrences(of: "{tools_json}", with: ActionRegistry.toolsJSON())
    }

    // MARK: - Private

    /// Read selected text with a hard timeout to prevent hangs.
    /// AXUIElementCopyAttributeValue is synchronous IPC — if the target app's
    /// accessibility implementation is slow or deadlocked, it blocks indefinitely.
    /// Uses two racing detached tasks (AX read vs timeout) with OSAllocatedUnfairLock
    /// to ensure the continuation is resumed exactly once.
    private static func readSelectedTextAsync(timeoutMs: Int) async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let finished = OSAllocatedUnfairLock(initialState: false)
            Task.detached {
                let text = readSelectedText()
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: text)
                }
            }
            Task.detached {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: nil)
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

    @MainActor
    private static func readSelectedTextByTemporaryCopy(timeoutMs: Int) async -> String {
        guard AXIsProcessTrusted() else { return "" }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let previousChangeCount = pasteboard.changeCount

        postCopyShortcut()

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
        var copiedText = ""
        var copiedChangeCount: Int?
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
            if pasteboard.changeCount != previousChangeCount {
                copiedText = pasteboard.string(forType: .string) ?? ""
                copiedChangeCount = pasteboard.changeCount
                break
            }
        }

        // Command+C is a no-op when there is no selection in many apps. Avoid
        // rewriting an unchanged pasteboard because clipboard-history apps treat
        // the restoration as a fresh user copy. The expected count also avoids
        // overwriting a clipboard change made by another app in the meantime.
        if let copiedChangeCount,
           PasteboardHistoryPolicy.shouldRestoreTemporaryCopy(
               previousChangeCount: previousChangeCount,
               currentChangeCount: copiedChangeCount
           ) {
            snapshot.restore(to: pasteboard, expectedChangeCount: copiedChangeCount)
        }
        return copiedText
    }

    @MainActor
    private static func postCopyShortcut() {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x08, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x08, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private struct PasteboardSnapshot {
        private let items: [[NSPasteboard.PasteboardType: Data]]

        @MainActor
        static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
            let items = pasteboard.pasteboardItems?.map { item in
                item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                    result[type] = item.data(forType: type)
                }
            } ?? []
            return PasteboardSnapshot(items: items)
        }

        @MainActor
        func restore(to pasteboard: NSPasteboard, expectedChangeCount: Int) {
            guard pasteboard.changeCount == expectedChangeCount else { return }
            pasteboard.clearContents()
            guard !items.isEmpty else { return }

            let restoredItems = items.map { storedItem in
                let item = NSPasteboardItem()
                for (type, data) in storedItem {
                    item.setData(data, forType: type)
                }
                PasteboardHistoryPolicy.markTransient(item)
                return item
            }
            pasteboard.writeObjects(restoredItems)
        }
    }
}
