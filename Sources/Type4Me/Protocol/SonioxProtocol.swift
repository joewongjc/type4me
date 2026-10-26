import Foundation

enum SonioxProtocolError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case invalidMessage
    case invalidStartMessage

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return L("无法生成 Soniox WebSocket URL", "Failed to build Soniox WebSocket URL")
        case .invalidMessage:
            return L("Soniox 流式消息无效", "Invalid Soniox streaming message")
        case .invalidStartMessage:
            return L("Soniox 启动消息无效", "Invalid Soniox start message")
        }
    }
}

struct SonioxTranscriptUpdate: Sendable, Equatable {
    let finalizedText: String
    let partialText: String
}

struct SonioxServerError: Sendable, Equatable {
    let code: Int
    let message: String
}

/// Combined result from a single Soniox server message.
/// A message can carry tokens AND finished simultaneously.
struct SonioxServerMessage: Sendable, Equatable {
    let transcript: SonioxTranscriptUpdate?
    let isFinished: Bool
    let error: SonioxServerError?
}

enum SonioxProtocol {

    private static let endpoint = "wss://stt-rt.soniox.com/transcribe-websocket"
    private static let ignoredMarkerTokens: Set<String> = ["<end>", "<fin>"]
    private static let maxEndpointDelayMs = 2000

    static func buildWebSocketURL(override: String? = nil) throws -> URL {
        let urlString = override ?? endpoint
        guard let url = URL(string: urlString) else {
            throw SonioxProtocolError.invalidEndpoint
        }
        return url
    }

    static func buildStartMessage(
        config: SonioxASRConfig,
        options: ASRRequestOptions
    ) throws -> String {
        let isCloudProxy = options.cloudProxyURL != nil
        var payload: [String: Any] = [
            "model": config.model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16000,
            "num_channels": 1,
            "enable_endpoint_detection": true,
            "endpoint_sensitivity": config.endpointSensitivity,
            "max_endpoint_delay_ms": maxEndpointDelayMs,
            "language_hints": ["zh", "en"],
            "language_hints_strict": true,
        ]
        // Only include api_key for direct connections, not cloud proxy
        if !isCloudProxy {
            payload["api_key"] = config.apiKey
        }

        let terms = sanitizedTerms(from: options.hotwords)
        if !terms.isEmpty {
            payload["context"] = ["terms": terms]
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let message = String(data: data, encoding: .utf8)
        else {
            throw SonioxProtocolError.invalidStartMessage
        }

        return message
    }

    static func endOfStreamFrame() -> Data {
        Data()
    }

    static func finalizeMessage() -> String {
        #"{"type":"finalize"}"#
    }

    /// Parse a server message, returning all present information at once.
    /// A single message can carry tokens AND `finished: true` simultaneously.
    static func parseServerMessage(from data: Data) throws -> SonioxServerMessage {
        let decoder = JSONDecoder()
        let response = try decoder.decode(Response.self, from: data)

        let serverError: SonioxServerError?
        if let code = response.errorCode {
            serverError = SonioxServerError(
                code: code,
                message: response.errorMessage ?? "Soniox request failed"
            )
        } else {
            serverError = nil
        }

        let finalText = visibleText(from: response.tokens ?? [], isFinal: true)
        let partialText = visibleText(from: response.tokens ?? [], isFinal: false)
        let transcript: SonioxTranscriptUpdate?
        if !finalText.isEmpty || !partialText.isEmpty {
            transcript = SonioxTranscriptUpdate(
                finalizedText: finalText,
                partialText: partialText
            )
        } else {
            transcript = nil
        }

        return SonioxServerMessage(
            transcript: transcript,
            isFinished: response.finished == true,
            error: serverError
        )
    }

    private static func sanitizedTerms(from hotwords: [String]) -> [String] {
        hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func visibleText(from tokens: [Token], isFinal: Bool) -> String {
        tokens
            .filter { ($0.isFinal ?? false) == isFinal }
            .compactMap { token -> String? in
                guard let text = token.text, !ignoredMarkerTokens.contains(text) else {
                    return nil
                }
                return text
            }
            .joined()
    }

    private struct Response: Decodable {
        let tokens: [Token]?
        let finished: Bool?
        let errorCode: Int?
        let errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case tokens
            case finished
            case errorCode = "error_code"
            case errorMessage = "error_message"
        }
    }

    private struct Token: Decodable {
        let text: String?
        let isFinal: Bool?

        enum CodingKeys: String, CodingKey {
            case text
            case isFinal = "is_final"
        }
    }
}
