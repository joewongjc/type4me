import Foundation

enum MetaMuseASRError: Error, LocalizedError, Equatable {
    case invalidConfig
    case invalidEndpoint
    case handshakeTimedOut
    case authenticationFailed(String?)
    case sessionRejected(String?)
    case invalidServerEvent
    case noFinalTranscript
    case rateLimited(String?)
    case sessionLimitReached
    case closedBeforeReady(code: Int, reason: String?)
    case closed(code: Int, reason: String?)
    case serverError(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "Meta Muse streaming ASR requires MetaMuseASRConfig"
        case .invalidEndpoint:
            return L("无法生成 Meta Muse WebSocket URL", "Failed to build Meta Muse WebSocket URL")
        case .handshakeTimedOut:
            return L("Meta Muse 握手超时", "Meta Muse handshake timed out")
        case .authenticationFailed(let reason):
            if let reason, !reason.isEmpty {
                return L("Meta Muse 鉴权失败：\(reason)", "Meta Muse authentication failed: \(reason)")
            }
            return L("Meta Muse API Key 无效或鉴权失败", "Meta Muse API Key is invalid or authentication failed")
        case .sessionRejected(let reason):
            if let reason, !reason.isEmpty {
                return L("Meta Muse 会话被拒绝：\(reason)", "Meta Muse session rejected: \(reason)")
            }
            return L("Meta Muse 会话被拒绝", "Meta Muse session was rejected")
        case .invalidServerEvent:
            return L("Meta Muse 返回了无法解析的事件", "Meta Muse returned an unparseable event")
        case .noFinalTranscript:
            return L("未识别到有效语音", "No speech detected")
        case .rateLimited(let reason):
            if let reason, !reason.isEmpty {
                return L("Meta Muse 速率超限：\(reason)", "Meta Muse rate limit exceeded: \(reason)")
            }
            return L("Meta Muse 达到速率或并发限制", "Meta Muse rate or concurrency limit exceeded")
        case .sessionLimitReached:
            return L("Meta Muse 会话已达到时长或音频限制", "Meta Muse session reached duration or audio limit")
        case .closedBeforeReady(let code, let reason):
            if let reason, !reason.isEmpty {
                return L(
                    "Meta Muse 在会话就绪前关闭（\(code)）：\(reason)",
                    "Meta Muse closed before session ready (\(code)): \(reason)"
                )
            }
            return L(
                "Meta Muse 在会话就绪前关闭（\(code)）",
                "Meta Muse closed before session ready (\(code))"
            )
        case .closed(let code, let reason):
            if let reason, !reason.isEmpty {
                return L(
                    "Meta Muse 连接关闭（\(code)）：\(reason)",
                    "Meta Muse connection closed (\(code)): \(reason)"
                )
            }
            return L(
                "Meta Muse 连接已关闭（\(code)）",
                "Meta Muse connection closed (\(code))"
            )
        case .serverError(let message):
            return L("Meta Muse 错误：\(message)", "Meta Muse error: \(message)")
        }
    }
}

enum MetaMuseASRServerEvent: Sendable, Equatable {
    case sessionReady(sessionId: String)
    case transcript(text: String, isFinal: Bool, audioProcessedMs: Int?)
    case error(MetaMuseASRError)
    case ignored(type: String)
}

enum MetaMuseASRProtocol {

    static let defaultEndpoint = "wss://api.meta.ai/v1/asr/realtime"
    static let maxKeywordsCount = 100
    static let maxKeywordLength = 20

    static func buildWebSocketURL(override: String? = nil, sessionId: String? = nil) throws -> URL {
        let base = override ?? defaultEndpoint
        guard var components = URLComponents(string: base) else {
            throw MetaMuseASRError.invalidEndpoint
        }
        if let sessionId, !sessionId.isEmpty {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "sessionId", value: sessionId))
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw MetaMuseASRError.invalidEndpoint
        }
        return url
    }

    static func sanitizedKeywords(
        from hotwords: [String],
        maxCount: Int = maxKeywordsCount,
        maxLength: Int = maxKeywordLength
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for word in hotwords {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            let capped = String(trimmed.prefix(maxLength))
            result.append(capped)
            if result.count >= maxCount {
                break
            }
        }
        return result
    }

    static func buildHandshakeMessage(
        config: MetaMuseASRConfig,
        options: ASRRequestOptions
    ) throws -> String {
        guard !config.apiKey.isEmpty else {
            throw MetaMuseASRError.invalidConfig
        }

        var payload: [String: Any] = [
            "authorization": [
                "accessToken": "Bearer \(config.apiKey)"
            ],
            "audioEncoding": "PCM_16KHZ",
            "model": MetaMuseASRConfig.defaultModel,
            "mode": "PUSH_TO_TALK",
        ]

        let keywords = sanitizedKeywords(from: options.hotwords)
        if !keywords.isEmpty {
            payload["keywords"] = keywords
        }

        let languageBias = config.languageBias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !languageBias.isEmpty {
            payload["languageBias"] = [languageBias]
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            throw MetaMuseASRError.invalidConfig
        }
        return string
    }

    static func buildEndStreamMessage() -> String {
        #"{"type":"endStream"}"#
    }

    static func parseServerEvent(from data: Data) throws -> MetaMuseASRServerEvent {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetaMuseASRError.invalidServerEvent
        }

        // Handshake response: The only server frame with no "type" field, returning sessionId.
        if json["type"] == nil {
            if let sessionId = json["sessionId"] as? String {
                return .sessionReady(sessionId: sessionId)
            }
            if let sessionId = json["session_id"] as? String {
                return .sessionReady(sessionId: sessionId)
            }
            throw MetaMuseASRError.invalidServerEvent
        }

        guard let type = json["type"] as? String else {
            throw MetaMuseASRError.invalidServerEvent
        }

        switch type {
        case "handshake", "session_ready", "session.ready":
            let sessionId = (json["sessionId"] as? String) ?? (json["session_id"] as? String) ?? ""
            return .sessionReady(sessionId: sessionId)

        case "transcript":
            guard let text = (json["transcript"] as? String) ?? (json["text"] as? String) else {
                throw MetaMuseASRError.invalidServerEvent
            }
            let isFinal = (json["final"] as? Bool) ?? false
            let audioProcessedMs = (json["audioProcessedMs"] as? Int) ?? (json["audio_processed_ms"] as? Int)
            return .transcript(text: text, isFinal: isFinal, audioProcessedMs: audioProcessedMs)

        case "error":
            let message = (json["message"] as? String) ?? "Unknown error"
            let lower = message.lowercased()
            if lower.contains("unauthorized") || lower.contains("auth") || lower.contains("api key") || lower.contains("forbidden") {
                return .error(.authenticationFailed(message))
            } else if lower.contains("rate limit") || lower.contains("too many requests") || lower.contains("429") {
                return .error(.rateLimited(message))
            } else if lower.contains("quota") || lower.contains("limit reached") {
                return .error(.sessionLimitReached)
            } else {
                return .error(.serverError(message: message))
            }

        default:
            return .ignored(type: type)
        }
    }
}
