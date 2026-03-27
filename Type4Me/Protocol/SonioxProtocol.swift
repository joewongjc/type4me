import Foundation

enum SonioxProtocolError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case invalidMessage
    case invalidStartMessage

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Failed to build Soniox WebSocket URL"
        case .invalidMessage:
            return "Invalid Soniox streaming message"
        case .invalidStartMessage:
            return "Invalid Soniox start message"
        }
    }
}

struct SonioxTranscriptUpdate: Sendable, Equatable {
    let finalizedText: String
    let partialText: String
}

enum SonioxServerEvent: Sendable, Equatable {
    case transcript(SonioxTranscriptUpdate)
    case finished
    case error(code: Int, message: String)
}

enum SonioxProtocol {

    private static let endpoint = "wss://stt-rt.soniox.com/transcribe-websocket"
    private static let ignoredMarkerTokens: Set<String> = ["<end>", "<fin>"]

    static func buildWebSocketURL() throws -> URL {
        guard let url = URL(string: endpoint) else {
            throw SonioxProtocolError.invalidEndpoint
        }
        return url
    }

    static func buildStartMessage(
        config: SonioxASRConfig,
        options: ASRRequestOptions
    ) throws -> String {
        var payload: [String: Any] = [
            "api_key": config.apiKey,
            "model": config.model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16000,
            "num_channels": 1,
            "enable_endpoint_detection": true,
        ]

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

    static func finalizeMessage(trailingSilenceMs: Int? = nil) -> String {
        var payload: [String: Any] = ["type": "finalize"]
        if let trailingSilenceMs {
            payload["trailing_silence_ms"] = trailingSilenceMs
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let message = String(data: data, encoding: .utf8)
        else {
            return #"{"type":"finalize"}"#
        }

        return message
    }

    static func parseServerEvent(from data: Data) throws -> SonioxServerEvent? {
        let decoder = JSONDecoder()
        let response = try decoder.decode(Response.self, from: data)

        if let code = response.errorCode {
            return .error(
                code: code,
                message: response.errorMessage ?? "Soniox request failed"
            )
        }

        let finalText = visibleText(from: response.tokens ?? [], isFinal: true)
        let partialText = visibleText(from: response.tokens ?? [], isFinal: false)
        if !finalText.isEmpty || !partialText.isEmpty {
            return .transcript(
                SonioxTranscriptUpdate(
                    finalizedText: finalText,
                    partialText: partialText
                )
            )
        }

        if response.finished == true {
            return .finished
        }

        return nil
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
