import Foundation
import Type4MeTransferCore

/// OpenAI-compatible `/chat/completions`, which covers every text provider the
/// Mac exporter hands over (Doubao, DeepSeek, Bailian, Kimi, OpenAI, …),
/// plus Anthropic's `/messages` for Claude.
struct LLMEndpointConfig: Sendable, Equatable {
    let provider: String
    let apiKey: String
    let model: String
    let baseURL: String
    let reasoningEffort: String?
    let thinkingOff: String?
    let reasoningSplit: Bool

    init?(endpoint: Type4MeTransferPayload.Endpoint) {
        let fields = endpoint.fields
        func value(_ key: String) -> String? {
            let trimmed = fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let baseURL = value("baseURL"), let model = value("model") else { return nil }
        provider = endpoint.provider
        apiKey = value("apiKey") ?? ""
        self.model = model
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        reasoningEffort = value("reasoningEffort")
        thinkingOff = value(Type4MeTransferSupport.LLMHint.thinkingOff)
        reasoningSplit = value(Type4MeTransferSupport.LLMHint.reasoningSplit) == "1"
    }
}

enum ChatClientError: LocalizedError {
    case invalidURL
    case http(Int, String?)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return L("处理模型的地址无效", "The text model's URL is invalid")
        case .http(let code, let detail):
            return detail.map { L("处理模型返回 \(code)：\($0)", "The text model returned \(code): \($0)") }
                ?? L("处理模型返回 \(code)", "The text model returned \(code)")
        case .emptyResponse: return L("处理模型没有返回内容", "The text model returned nothing")
        }
    }
}

struct ChatClient: Sendable {
    let config: LLMEndpointConfig

    struct Message: Encodable {
        let role: String
        let content: String
    }

    func complete(system: String?, user: String, timeout: TimeInterval = 20) async throws -> String {
        if LLMProvider(rawValue: config.provider) == .claude {
            return try await completeMessages(system: system, user: user, timeout: timeout)
        }
        guard let url = URL(string: config.baseURL + "/chat/completions") else {
            throw ChatClientError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: String]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])

        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": false,
        ]
        var effort = config.reasoningEffort
        switch config.thinkingOff {
        case "thinking": body["thinking"] = ["type": "disabled"]
        case "enableThinking": body["enable_thinking"] = false
        case "reasoning": body["reasoning"] = ["effort": "none"]
        case "reasoningEffort": effort = "none"
        default: break
        }
        if let effort { body["reasoning_effort"] = effort }
        if config.reasoningSplit { body["reasoning_split"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ChatClientError.http(status, Self.errorDetail(data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw ChatClientError.emptyResponse }
        let cleaned = Self.stripThinking(content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ChatClientError.emptyResponse }
        return cleaned
    }

    /// Anthropic Messages API, same request as the Mac `ClaudeChatClient`
    /// without streaming.
    private func completeMessages(system: String?, user: String, timeout: TimeInterval) async throws -> String {
        guard let url = URL(string: config.baseURL + "/messages") else {
            throw ChatClientError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": 4096,
            "messages": [["role": "user", "content": user]],
        ]
        if let system { body["system"] = system }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ChatClientError.http(status, Self.errorDetail(data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]]
        else { throw ChatClientError.emptyResponse }
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ChatClientError.emptyResponse }
        return cleaned
    }

    /// Some models still wrap reasoning in `<think>` even when asked not to.
    static func stripThinking(_ text: String) -> String {
        guard let close = text.range(of: "</think>") else { return text }
        if let open = text.range(of: "<think>"), open.lowerBound < close.lowerBound {
            return String(text[..<open.lowerBound]) + String(text[close.upperBound...])
        }
        return String(text[close.upperBound...])
    }

    static func errorDetail(_ data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return String(message.prefix(160))
            }
            if let message = json["message"] as? String { return String(message.prefix(160)) }
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return String(text.prefix(160))
    }
}
