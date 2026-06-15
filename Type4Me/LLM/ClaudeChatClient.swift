import Foundation
import os

actor ClaudeChatClient: LLMClient {

    private let logger = Logger(subsystem: "com.type4me.llm", category: "ClaudeChatClient")
    private let session: URLSession
    private let metricsDelegate: LLMURLSessionMetricsDelegate

    init(bypassProxy: Bool = ProxyBypassMode.current.bypassLLM) {
        let resources = LLMURLSessionFactory.make(
            providerID: LLMProvider.claude.rawValue,
            bypassProxy: bypassProxy
        )
        session = resources.session
        metricsDelegate = resources.metricsDelegate
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
    func process(text: String, prompt: String, config: LLMConfig) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return text }
        let finalPrompt = prompt.replacingOccurrences(of: "{text}", with: trimmedText)

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
            system: nil,
            messages: [ClaudeMessage(role: "user", content: finalPrompt)],
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)

        logger.info("Claude request: \(text.count) chars, model=\(config.model)")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            logger.error("Claude HTTP \(http.statusCode)")
            throw LLMError.requestFailed(http.statusCode)
        }

        // Parse SSE stream (Anthropic format)
        var result = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(ClaudeStreamEvent.self, from: data)
            else { continue }

            switch event.type {
            case "content_block_delta":
                if let delta = event.delta, let text = delta.text {
                    result += text
                }
            case "message_stop":
                break
            case "error":
                let detail = event.error?.message ?? "unknown"
                logger.error("Claude SSE error event: \(detail)")
                throw LLMError.requestFailed(-1)
            case "message_delta":
                if let stopReason = event.delta?.stop_reason, stopReason == "error" {
                    logger.error("Claude message_delta stop_reason=error")
                    throw LLMError.requestFailed(-1)
                }
            default:
                continue
            }
        }

        logger.info("Claude result: \(result.count) chars")

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
    let delta: ClaudeDelta?
    let error: ClaudeErrorDetail?
}

private struct ClaudeDelta: Decodable, Sendable {
    let text: String?
    let stop_reason: String?
}

private struct ClaudeErrorDetail: Decodable, Sendable {
    let type: String?
    let message: String?
}
