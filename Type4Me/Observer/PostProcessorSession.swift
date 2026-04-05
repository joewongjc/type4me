import AppKit
import ApplicationServices
import Foundation

/// Handles post-processing of DoubaoIme ASR output:
/// 1. Snippet replacement (instant, always runs)
/// 2. LLM processing (async, only when a mode is armed)
/// 3. History recording (always)
actor PostProcessorSession {

    let historyStore = HistoryStore()
    private let injectionEngine = TextInjectionEngine()

    // MARK: - Process ASR Output

    struct ASRResult {
        let element: AXUIElement
        let startPos: Int
        let endPos: Int
        let rawText: String
    }

    /// Full post-processing pipeline: snippet → optional LLM → history.
    /// Called from the main actor after ASR ends.
    func process(asr: ASRResult, armedMode: ProcessingMode?) async {
        let rawText = asr.rawText
        guard !rawText.isEmpty else { return }

        let startTime = Date()
        var finalText = rawText

        // Phase 1: Snippet replacement (always, instant)
        let snippetResult = SnippetStorage.applyEffective(to: rawText)
        let snippetChanged = snippetResult != rawText

        DebugFileLogger.log("[PostProcessor] Snippet: changed=\(snippetChanged), \(rawText.count)→\(snippetResult.count) chars")
        if snippetChanged {
            DebugFileLogger.log("[PostProcessor] Snippet diff: '\(rawText.prefix(80))' → '\(snippetResult.prefix(80))'")
            await selectAndReplace(
                element: asr.element,
                startPos: asr.startPos,
                length: rawText.count,
                replacement: snippetResult
            )
            finalText = snippetResult
        }

        // Phase 2: LLM processing (only if mode is armed and has a prompt)
        var processedText: String? = nil
        if let mode = armedMode, !mode.prompt.isEmpty {
            let llmResult = await runLLM(
                text: finalText,
                mode: mode,
                element: asr.element,
                startPos: asr.startPos,
                expectedText: finalText
            )
            if let llmResult {
                processedText = llmResult
                finalText = llmResult
            }
        }

        DebugFileLogger.log("[PostProcessor] Done: rawText=\(rawText.count), finalText=\(finalText.count), mode=\(armedMode?.name ?? "none")")

        // Phase 3: Record history
        let duration = Date().timeIntervalSince(startTime)
        let record = HistoryRecord(
            id: UUID().uuidString,
            createdAt: startTime,
            durationSeconds: duration,
            rawText: rawText,
            processingMode: armedMode?.name,
            processedText: processedText,
            finalText: finalText,
            status: "completed",
            characterCount: finalText.count,
            asrProvider: "DoubaoIme"
        )
        await historyStore.insert(record)
        NSLog("[PostProcessor] Recorded history: %d chars, mode=%@",
              finalText.count, armedMode?.name ?? "snippet-only")
    }

    // MARK: - LLM

    private func runLLM(
        text: String,
        mode: ProcessingMode,
        element: AXUIElement,
        startPos: Int,
        expectedText: String
    ) async -> String? {
        guard let llmConfig = loadLLMConfig() else {
            NSLog("[PostProcessor] LLM skipped: no config")
            return nil
        }

        let client = createLLMClient()
        let context = await PromptContext.capture()
        let prompt = context.expandContextVariables(mode.prompt)

        NSLog("[PostProcessor] LLM starting: mode=%@, model=%@, %d chars",
              mode.name, llmConfig.model, text.count)

        do {
            let result = try await withTimeout(seconds: 15) {
                try await client.process(text: text, prompt: prompt, config: llmConfig)
            }

            guard !result.isEmpty else { return nil }

            // Safety check: verify the text at the original position hasn't been edited
            let currentText = await readTextAtPosition(
                element: element, startPos: startPos, length: expectedText.count
            )

            DebugFileLogger.log("[PostProcessor] LLM safety check: expected='\(expectedText.prefix(30))' (\(expectedText.count)ch), got='\(currentText?.prefix(30) ?? "nil")'")
            if currentText == expectedText {
                await selectAndReplace(
                    element: element,
                    startPos: startPos,
                    length: expectedText.count,
                    replacement: result
                )
                DebugFileLogger.log("[PostProcessor] LLM replaced: \(text.count) → \(result.count) chars")
                return result
            } else {
                DebugFileLogger.log("[PostProcessor] LLM skipped: text changed by user")
                return result
            }
        } catch {
            NSLog("[PostProcessor] LLM failed: %@", error.localizedDescription)
            return nil
        }
    }

    private func loadLLMConfig() -> LLMConfig? {
        KeychainService.loadLLMConfig()
    }

    private func createLLMClient() -> any LLMClient {
        let provider = KeychainService.selectedLLMProvider
        if provider == .claude {
            return ClaudeChatClient()
        }
        return DoubaoChatClient(provider: provider)
    }

    // MARK: - Text Replacement via AX

    private func selectAndReplace(
        element: AXUIElement,
        startPos: Int,
        length: Int,
        replacement: String
    ) async {
        DebugFileLogger.log("[PostProcessor] selectAndReplace: pos=\(startPos), len=\(length), replacement=\(replacement.count) chars")

        // Strategy 1: Try AX selection (works in Notes, TextEdit, etc.)
        var axSuccess = false
        var range = CFRange(location: startPos, length: length)
        if let rangeValue = AXValueCreate(.cfRange, &range) {
            let status = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
            axSuccess = (status == .success)
        }

        if axSuccess {
            DebugFileLogger.log("[PostProcessor] AX selection OK, pasting...")
            try? await Task.sleep(for: .milliseconds(50))
        } else {
            // Strategy 2: Backspace to delete ASR text (universal fallback for WeChat, Terminal, etc.)
            DebugFileLogger.log("[PostProcessor] AX selection failed, using backspace fallback (\(length) chars)")
            simulateBackspace(count: length)
            try? await Task.sleep(for: .milliseconds(50))
        }

        // Paste replacement
        let outcome = injectionEngine.inject(replacement)
        DebugFileLogger.log("[PostProcessor] Injection outcome: \(outcome)")

        try? await Task.sleep(for: .milliseconds(100))
        injectionEngine.finishClipboardRestore()
    }

    /// Simulate pressing Backspace N times to delete text backwards from cursor.
    /// Works universally in all apps (WeChat, Terminal, browsers, etc.)
    private func simulateBackspace(count: Int) {
        let backspaceKeyCode: CGKeyCode = 51
        for _ in 0..<count {
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: false)
            else { continue }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(5_000)  // 5ms between keystrokes
        }
    }

    private func readTextAtPosition(element: AXUIElement, startPos: Int, length: Int) async -> String? {
        guard length > 0 else { return nil }

        var cfRange = CFRange(location: startPos, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }

        var textValue: AnyObject?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &textValue
        )

        if status == .success, let text = textValue as? String {
            return text
        }

        // Fallback: read full value
        var fullValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &fullValue
        ) == .success, let fullText = fullValue as? String else { return nil }

        let start = fullText.index(fullText.startIndex, offsetBy: startPos, limitedBy: fullText.endIndex)
        let end = fullText.index(fullText.startIndex, offsetBy: startPos + length, limitedBy: fullText.endIndex)
        guard let start, let end else { return nil }
        return String(fullText[start..<end])
    }

    // MARK: - Timeout Helper

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
