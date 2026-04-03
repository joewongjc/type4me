import Foundation
import os

actor DoubaoChatClient: LLMClient {

    private let logger = Logger(subsystem: "com.type4me.llm", category: "DoubaoChatClient")
    private let provider: LLMProvider

    init(provider: LLMProvider = .doubao) {
        self.provider = provider
    }

    private var session: URLSession {
        if ProxyBypassMode.current.bypassLLM {
            let config = URLSessionConfiguration.default
            config.connectionProxyDictionary = [:]
            return URLSession(configuration: config)
        }
        return URLSession.shared
    }

    /// Pre-establish TCP+TLS connection so the first real request skips handshake.
    func warmUp(baseURL: String) async {
        guard let url = URL(string: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        _ = try? await session.data(for: request)
        logger.info("LLM connection pre-warmed to \(baseURL)")
    }

    /// Process text through Doubao ARK API (OpenAI-compatible streaming).
    /// Returns the full LLM response as a single string.
    func process(text: String, prompt: String, config: LLMConfig) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return text }
        let finalPrompt = prompt.replacingOccurrences(of: "{text}", with: trimmedText)

        guard let url = URL(string: "\(config.baseURL)/chat/completions") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let disableField = provider.thinkingDisableField
        let body = ChatRequest(
            model: config.model,
            messages: [ChatMessage(role: "user", content: finalPrompt)],
            stream: true,
            thinking: disableField == .thinking ? ThinkingConfig(type: "disabled") : nil,
            enable_thinking: disableField == .enableThinking ? false : nil,
            reasoning_effort: disableField == .reasoningEffort ? "none" : nil,
            think: disableField == .think ? false : nil,
            reasoning_split: provider.needsReasoningSplit ? true : nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        logger.info("LLM request: \(text.count) chars, endpoint=\(config.model), stream=true")

        let result = try await processStreaming(request: request, model: config.model)

        logger.info("LLM result: \(result.count) chars")
        return result.strippingThinkTags()
    }

    // MARK: - Streaming (SSE)

    private func processStreaming(request: URLRequest, model: String) async throws -> String {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            logger.error("LLM HTTP \(http.statusCode)")
            DebugFileLogger.log("LLM[\(model)]: HTTP \(http.statusCode)")
            throw LLMError.requestFailed(http.statusCode)
        }

        var result = ""
        var lineCount = 0
        for try await line in bytes.lines {
            lineCount += 1
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: data),
                  let content = chunk.choices.first?.delta.content
            else { continue }
            result += content
        }

        if result.isEmpty && lineCount > 0 {
            DebugFileLogger.log("LLM[\(model)]: \(lineCount) lines but 0 content chars")
            throw LLMError.emptyResponse("stream contained no text")
        }
        if result.isEmpty {
            DebugFileLogger.log("LLM[\(model)]: 0 lines received (connection closed immediately)")
            throw LLMError.emptyResponse(nil)
        }
        return result
    }

    // MARK: - Non-streaming (single JSON response)

    private func processNonStreaming(request: URLRequest, model: String) async throws -> String {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            logger.error("LLM HTTP \(http.statusCode)")
            DebugFileLogger.log("LLM[\(model)]: HTTP \(http.statusCode)")
            throw LLMError.requestFailed(http.statusCode)
        }

        guard let json = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
              let content = json.choices.first?.message.content, !content.isEmpty
        else {
            DebugFileLogger.log("LLM[\(model)]: non-streaming empty response")
            throw LLMError.emptyResponse("empty response body")
        }
        return content
    }
}

// MARK: - Request/Response Types

struct ThinkingConfig: Encodable, Sendable {
    let type: String
}

struct ChatRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let thinking: ThinkingConfig?
    let enable_thinking: Bool?
    let reasoning_effort: String?
    let think: Bool?
    let reasoning_split: Bool?
}

struct ChatMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String
}

// Non-streaming response
struct ChatCompletionResponse: Decodable, Sendable {
    let choices: [CompletionChoice]
}

struct CompletionChoice: Decodable, Sendable {
    let message: CompletionMessage
}

struct CompletionMessage: Decodable, Sendable {
    let content: String?
}

// Streaming response (SSE chunks)
struct ChatStreamChunk: Decodable, Sendable {
    let choices: [ChunkChoice]
}

struct ChunkChoice: Decodable, Sendable {
    let delta: ChunkDelta
}

struct ChunkDelta: Decodable, Sendable {
    let content: String?
}

enum LLMError: Error, LocalizedError {
    case invalidURL
    case requestFailed(Int)
    case emptyResponse(String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L("LLM 地址无效", "Invalid LLM URL")
        case .requestFailed(let code):
            switch code {
            case 401: return L("LLM 鉴权失败，请检查 API Key", "LLM auth failed, check API Key")
            case 429: return L("LLM 请求超限或余额不足", "LLM rate limit or insufficient balance")
            case 500, 502, 503: return L("LLM 服务异常 (\(code))", "LLM service error (\(code))")
            default:  return L("LLM 请求失败 (\(code))", "LLM request failed (\(code))")
            }
        case .emptyResponse(let raw):
            if let raw {
                return L("LLM 未返回内容: \(raw)", "LLM returned no content: \(raw)")
            }
            return L("LLM 未返回内容", "LLM returned no content")
        }
    }
}
