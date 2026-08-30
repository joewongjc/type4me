import Foundation

enum StepFunASRError: Error, LocalizedError, Equatable {
    case invalidConfig
    case handshakeTimedOut
    case closedBeforeSessionReady(code: Int, reason: String?)
    case invalidResponse
    case serverError(code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "StepFun streaming ASR requires StepFunASRConfig"
        case .handshakeTimedOut:
            return L("阶跃星辰实时识别握手超时", "StepFun streaming ASR handshake timed out")
        case .closedBeforeSessionReady(let code, let reason):
            if let reason, !reason.isEmpty {
                return L(
                    "阶跃星辰连接在会话就绪前关闭（\(code)）：\(reason)",
                    "StepFun socket closed before the session was ready (\(code)): \(reason)"
                )
            }
            return L(
                "阶跃星辰连接在会话就绪前关闭（\(code)）",
                "StepFun socket closed before the session was ready (\(code))"
            )
        case .invalidResponse:
            return L("阶跃星辰返回了无法解析的识别结果", "StepFun returned an invalid transcription response")
        case .serverError(let code, let message):
            let codePart = code?.isEmpty == false ? "[\(code!)] " : ""
            return L(
                "阶跃星辰实时识别失败：\(codePart)\(message)",
                "StepFun streaming ASR failed: \(codePart)\(message)"
            )
        }
    }
}

enum StepFunASRServerEvent: Sendable, Equatable {
    case sessionReady
    case transcript(RecognitionTranscript)
    case error(StepFunASRError)
}

enum StepFunASRProtocol {

    private static let hotwordPromptPrefix = "专业术语："
    private static let maxHotwordCount = 100
    private static let maxHotwordPromptCharacters = 2_000

    static func buildSessionUpdateMessage(options: ASRRequestOptions) -> String {
        var transcription: [String: Any] = [
            "model": StepFunASRConfig.model,
            "language": "zh",
            "full_rerun_on_commit": true,
            "enable_itn": true,
        ]

        if let prompt = hotwordPrompt(from: options.hotwords) {
            transcription["prompt"] = prompt
        }

        let payload: [String: Any] = [
            "event_id": eventID(),
            "type": "session.update",
            "session": [
                "audio": [
                    "input": [
                        "format": [
                            "type": "pcm",
                            "codec": "pcm_s16le",
                            "rate": 16_000,
                            "bits": 16,
                            "channel": 1,
                        ],
                        "transcription": transcription,
                    ],
                ],
            ],
        ]
        return jsonString(from: payload)
    }

    static func buildAppendAudioMessage(_ data: Data) -> String {
        jsonString(from: [
            "event_id": eventID(),
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ])
    }

    static func buildCommitMessage() -> String {
        jsonString(from: [
            "event_id": eventID(),
            "type": "input_audio_buffer.commit",
        ])
    }

    static func parseServerEvent(from data: Data) throws -> StepFunASRServerEvent? {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            throw StepFunASRError.invalidResponse
        }

        switch envelope.type {
        case "session.updated":
            return .sessionReady

        case "conversation.item.input_audio_transcription.delta":
            guard let message = try? decoder.decode(DeltaMessage.self, from: data) else {
                throw StepFunASRError.invalidResponse
            }
            let text = message.text ?? ""
            let stash = message.stash ?? ""
            guard !text.isEmpty || !stash.isEmpty else { return nil }
            return .transcript(RecognitionTranscript(
                confirmedSegments: text.isEmpty ? [] : [text],
                partialText: stash,
                authoritativeText: text + stash,
                isFinal: false
            ))

        case "conversation.item.input_audio_transcription.completed":
            guard let message = try? decoder.decode(CompletedMessage.self, from: data) else {
                throw StepFunASRError.invalidResponse
            }
            let transcript = message.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return .transcript(RecognitionTranscript(
                confirmedSegments: transcript.isEmpty ? [] : [transcript],
                partialText: "",
                authoritativeText: transcript,
                isFinal: true
            ))

        case "error":
            guard let message = try? decoder.decode(ErrorMessage.self, from: data) else {
                throw StepFunASRError.invalidResponse
            }
            return .error(.serverError(
                code: message.error.code,
                message: message.error.message
            ))

        default:
            return nil
        }
    }

    private static func hotwordPrompt(from hotwords: [String]) -> String? {
        var seen: Set<String> = []
        var prompt = hotwordPromptPrefix
        var termCount = 0

        for rawTerm in hotwords {
            guard termCount < maxHotwordCount else { break }
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }

            let comparisonKey = term.lowercased()
            guard seen.insert(comparisonKey).inserted else { continue }

            let separator = termCount == 0 ? "" : "、"
            let candidate = prompt + separator + term
            guard candidate.count <= maxHotwordPromptCharacters else { continue }

            prompt = candidate
            termCount += 1
        }

        return termCount == 0 ? nil : prompt
    }

    private static func eventID() -> String {
        "event_" + UUID().uuidString.lowercased()
    }

    private static func jsonString(from object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private struct Envelope: Decodable {
        let type: String
    }

    private struct DeltaMessage: Decodable {
        let text: String?
        let stash: String?
    }

    private struct CompletedMessage: Decodable {
        let transcript: String
    }

    private struct ErrorMessage: Decodable {
        let error: ErrorDetail
    }

    private struct ErrorDetail: Decodable {
        let code: String?
        let message: String
    }
}
