import Foundation
import os

actor ClaudeChatClient: LLMClient {

    private let logger = Logger(subsystem: "com.type4me.llm", category: "ClaudeChatClient")
    private let session: URLSession
    private let metricsDelegate: LLMURLSessionMetricsDelegate

    init(
        bypassProxy: Bool = ProxyBypassMode.current.bypassLLM,
        customSession: URLSession? = nil
    ) {
        if let customSession {
            session = customSession
            metricsDelegate = LLMURLSessionMetricsDelegate(providerID: LLMProvider.claude.rawValue)
        } else {
            let resources = LLMURLSessionFactory.make(
                providerID: LLMProvider.claude.rawValue,
                bypassProxy: bypassProxy
            )
            session = resources.session
            metricsDelegate = resources.metricsDelegate
        }
    }

    /// Pre-establish TCP+TLS connection so the first real request skips handshake.
    func warmUp(baseURL: String) async {
        guard let url = URL(string: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        _ = try? await session.data(for: request)
        logger.info("Claude connection pre-warmed to \(baseURL)")
    }

    func invalidate() async {
        session.invalidateAndCancel()
    }

    /// Process text through Anthropic Messages API (streaming).
    func process(
        text: String,
        prompt: String,
        config: LLMConfig,
        inputBoundary: LLMInputBoundary
    ) async throws -> String {
        try await process(
            text: text,
            prompt: prompt,
            config: config,
            inputBoundary: inputBoundary,
            invocationContext: nil
        )
    }

    func process(
        text: String,
        prompt: String,
        config: LLMConfig,
        inputBoundary: LLMInputBoundary,
        invocationContext: LLMInvocationContext?
    ) async throws -> String {
        return try await processStreaming(
            text: text,
            prompt: prompt,
            config: config,
            inputBoundary: inputBoundary,
            invocationContext: invocationContext
        ) { _ in }
    }

    func processStreaming(
        text: String,
        prompt: String,
        config: LLMConfig,
        inputBoundary: LLMInputBoundary,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        try await processStreaming(
            text: text,
            prompt: prompt,
            config: config,
            inputBoundary: inputBoundary,
            invocationContext: nil,
            onDelta: onDelta
        )
    }

    func processStreaming(
        text: String,
        prompt: String,
        config: LLMConfig,
        inputBoundary: LLMInputBoundary,
        invocationContext: LLMInvocationContext?,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return text }
        let requestStart = ContinuousClock.now
        let preparedPrompt = LLMPreparedPrompt.make(
            text: trimmedText,
            prompt: prompt,
            inputBoundary: inputBoundary
        )

        guard let url = URL(string: "\(config.baseURL)/messages") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body = ClaudeRequest(
            model: config.model,
            max_tokens: 4096,
            system: preparedPrompt.system,
            messages: [ClaudeMessage(role: "user", content: preparedPrompt.user)],
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)

        logger.info("Claude request: \(text.count) chars, model=\(config.model)")

        var recordedOutcome = false
        func recordOutcome(status: String, completionText: String, metrics: LLMExecutionMetrics?) {
            guard !recordedOutcome else { return }
            recordedOutcome = true
            let durationSec = Double((ContinuousClock.now - requestStart).components.seconds) +
                              Double((ContinuousClock.now - requestStart).components.attoseconds) / 1e18
            LLMUsageRecorder.record(
                featureSource: invocationContext?.featureSource ?? .dictationPolish,
                provider: LLMProvider.claude.rawValue,
                model: config.model,
                promptText: text,
                completionText: completionText,
                durationSeconds: durationSec,
                metrics: metrics,
                status: status,
                modeName: invocationContext?.modeName
            )
        }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            recordOutcome(status: "error", completionText: "", metrics: nil)
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            recordOutcome(status: "error", completionText: "", metrics: nil)
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            recordOutcome(status: "error", completionText: "", metrics: nil)
            logger.error("Claude HTTP \(http.statusCode)")
            throw LLMError.requestFailed(http.statusCode)
        }

        // Parse SSE stream (Anthropic format)
        var result = ""
        var promptTokens: Int?
        var completionTokens: Int?
        var receivedMessageStop = false

        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONDecoder().decode(ClaudeStreamEvent.self, from: data)
                else { continue }

                switch event.type {
                case "message_start":
                    if let inputTokens = event.message?.usage?.input_tokens {
                        promptTokens = inputTokens
                    }
                case "content_block_delta":
                    if let delta = event.delta, let text = delta.text {
                        result += text
                        await onDelta(text)
                    }
                case "message_stop":
                    receivedMessageStop = true
                    break
                case "error":
                    let detail = event.error?.message ?? "unknown"
                    logger.error("Claude SSE error event: \(detail)")
                    throw LLMError.requestFailed(-1)
                case "message_delta":
                    if let outputTokens = event.usage?.output_tokens {
                        completionTokens = outputTokens
                    }
                    if let stopReason = event.delta?.stop_reason, stopReason == "error" {
                        logger.error("Claude message_delta stop_reason=error")
                        throw LLMError.requestFailed(-1)
                    }
                default:
                    continue
                }
            }
            guard receivedMessageStop else {
                logger.error("Claude stream closed without message_stop marker (chars=\(result.count))")
                throw LLMError.streamIncomplete(L("未收到结束标记 message_stop", "missing message_stop terminal marker"))
            }
        } catch {
            let durationSec = Double((ContinuousClock.now - requestStart).components.seconds) +
                              Double((ContinuousClock.now - requestStart).components.attoseconds) / 1e18
            let metrics = LLMExecutionMetrics(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                durationSeconds: durationSec,
                isEstimated: promptTokens == nil || completionTokens == nil
            )
            recordOutcome(status: "error", completionText: result, metrics: metrics)
            throw error
        }

        let durationSec = Double((ContinuousClock.now - requestStart).components.seconds) +
                          Double((ContinuousClock.now - requestStart).components.attoseconds) / 1e18
        logger.info("Claude result: \(result.count) chars, promptTokens=\(promptTokens ?? -1), compTokens=\(completionTokens ?? -1)")

        let metrics = LLMExecutionMetrics(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            durationSeconds: durationSec,
            isEstimated: promptTokens == nil || completionTokens == nil
        )
        recordOutcome(status: "success", completionText: result, metrics: metrics)
        return result.strippingThinkTags()
    }
}
// MARK: - Request Types

private struct ClaudeRequest: Encodable, Sendable {
    let model: String
    let max_tokens: Int
    let system: String?
    let messages: [ClaudeMessage]
    let stream: Bool
}

private struct ClaudeMessage: Encodable, Sendable {
    let role: String
    let content: String
}

// MARK: - Stream Response Types

private struct ClaudeStreamEvent: Decodable, Sendable {
    let type: String
    let message: ClaudeMessageStart?
    let delta: ClaudeDelta?
    let usage: ClaudeUsage?
    let error: ClaudeErrorDetail?
}

private struct ClaudeMessageStart: Decodable, Sendable {
    let usage: ClaudeUsage?
}

private struct ClaudeUsage: Decodable, Sendable {
    let input_tokens: Int?
    let output_tokens: Int?
}

private struct ClaudeDelta: Decodable, Sendable {
    let text: String?
    let stop_reason: String?
}

private struct ClaudeErrorDetail: Decodable, Sendable {
    let message: String?
}
