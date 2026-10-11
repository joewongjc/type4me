import Foundation

enum AzureMAIProtocolError: Error, LocalizedError, Equatable {
    case invalidConfig
    case handshakeFailed(statusCode: Int)
    case serverError(code: String?, message: String)
    case validationTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return L("Microsoft Azure 资源名称或 API Key 无效", "Invalid Microsoft Azure resource or API key")
        case .handshakeFailed(let statusCode):
            switch statusCode {
            case 401, 403:
                return L(
                    "Microsoft Azure 鉴权失败（HTTP \(statusCode)），请检查 API Key 与资源名称是否匹配",
                    "Microsoft Azure authentication failed (HTTP \(statusCode)). Check that the API key matches the resource."
                )
            case 404:
                return L(
                    "Microsoft Azure 未找到实时识别接口（HTTP 404），请检查资源名称与所在区域",
                    "Microsoft Azure realtime endpoint not found (HTTP 404). Check the resource name and region."
                )
            default:
                return L(
                    "Microsoft Azure 实时识别连接失败（HTTP \(statusCode)）",
                    "Microsoft Azure realtime connection failed (HTTP \(statusCode))"
                )
            }
        case .serverError(let code, let message):
            if let code, !code.isEmpty {
                return "Microsoft Azure [\(code)]: \(message)"
            }
            return "Microsoft Azure: \(message)"
        case .validationTimedOut:
            return L("Microsoft Azure 未在规定时间内确认会话配置", "Microsoft Azure did not confirm the session configuration in time")
        }
    }
}

/// Rejected credentials, a missing deployment, quota or a bad session configuration
/// will fail again on retry, so the session surfaces them instead of recovering.
extension AzureMAIProtocolError: TerminalASRError {
    var isTerminalServerError: Bool {
        switch self {
        case .handshakeFailed(let statusCode):
            return [400, 401, 403, 404, 429].contains(statusCode)
        case .serverError(let code, _):
            // OpenAI Realtime-style `server_error` is a transient service fault.
            return code?.lowercased() != "server_error"
        case .invalidConfig:
            return true
        case .validationTimedOut:
            return false
        }
    }
}

enum AzureMAIRealtimeEvent: Equatable {
    case sessionCreated
    case sessionUpdated
    /// Newly finalized text, appended verbatim to what came before.
    case delta(String)
    /// The whole provisional suffix after the latest delta; replaces the previous one.
    case intermediate(String)
    case committed
    /// Full final transcript for the audio since the previous commit.
    case completed(String)
    case ignored
}

/// Wire format for MAI-Transcribe-2-Streaming over the OpenAI Realtime-like WebSocket API.
enum AzureMAIProtocol {
    static let realtimePath = "/mai/v1/realtime"
    static let sampleRate = 16_000
    private static let transcriptionEventPrefix = "conversation.item.input_audio_transcription."

    static func realtimeURL(config: AzureASRConfig) throws -> URL {
        guard let host = config.foundryHost else { throw AzureMAIProtocolError.invalidConfig }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = realtimePath
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        guard let url = components.url else { throw AzureMAIProtocolError.invalidConfig }
        return url
    }

    static func makeRequest(config: AzureASRConfig) throws -> URLRequest {
        var request = URLRequest(url: try realtimeURL(config: config))
        request.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        return request
    }

    /// Must be sent before the first audio append; settings are fixed afterwards.
    /// The service has no server-side turn detection, so the client commits when recording ends.
    static func sessionUpdateMessage(config: AzureASRConfig) -> String {
        var transcription: [String: Any] = ["model": config.deployment]
        transcription["language"] = config.language.isEmpty ? NSNull() : config.language
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": sampleRate],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                        "noise_reduction": NSNull(),
                    ] as [String: Any],
                ],
            ] as [String: Any],
        ]
        return jsonString(payload)
    }

    static func appendMessage(pcmData: Data) -> String {
        jsonString([
            "type": "input_audio_buffer.append",
            "audio": pcmData.base64EncodedString(),
        ])
    }

    static let commitMessage = #"{"type":"input_audio_buffer.commit"}"#

    static func parseEvent(_ data: Data) throws -> AzureMAIRealtimeEvent {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return .ignored }

        switch type {
        case "session.created":
            return .sessionCreated
        case "session.updated":
            return .sessionUpdated
        case "input_audio_buffer.committed":
            return .committed
        case "error", transcriptionEventPrefix + "failed":
            throw serverError(from: json)
        case transcriptionEventPrefix + "delta":
            return .delta(json["delta"] as? String ?? "")
        case transcriptionEventPrefix + "intermediate":
            return .intermediate(json["intermediate"] as? String ?? "")
        case transcriptionEventPrefix + "completed":
            return .completed(json["transcript"] as? String ?? "")
        default:
            return .ignored
        }
    }

    private static func serverError(from json: [String: Any]) -> AzureMAIProtocolError {
        let error = json["error"] as? [String: Any]
        let code = (error?["code"] as? String) ?? (error?["type"] as? String)
        let message = (error?["message"] as? String)
            ?? (json["error"] as? String)
            ?? (json["message"] as? String)
            ?? L("未知错误", "Unknown error")
        return .serverError(code: code, message: message)
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
