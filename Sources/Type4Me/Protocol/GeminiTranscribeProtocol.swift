import Foundation

enum GeminiProtocolError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case invalidJSON
    case serverError(code: Int?, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return L("Gemini WebSocket 地址无效", "Invalid Gemini WebSocket URL")
        case .invalidJSON:
            return L("Gemini 消息格式错误", "Invalid Gemini JSON message")
        case .serverError(let code, let message):
            let msg = message ?? L("未知错误", "Unknown error")
            if let code {
                return L("Gemini 服务端错误（\(code)）：\(msg)", "Gemini server error (\(code)): \(msg)")
            }
            return L("Gemini 服务端错误：\(msg)", "Gemini server error: \(msg)")
        }
    }
}

struct GeminiTranscriptUpdate: Sendable, Equatable {
    let transcript: RecognitionTranscript
    let confirmedSegments: [String]
    let isSetupComplete: Bool
}

enum GeminiTranscribeProtocol {

    static let defaultEndpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    static let sampleRate = 16000
    static let targetFramesPerPayload = 1600
    static let bytesPerSample = 2
    static let targetPayloadBytes = 3200 // 1600 frames * 2 bytes = 3200 bytes (~100ms)
    static let maxCustomVocabularyCount = 1000

    // MARK: - URL Construction

    static func buildWebSocketURL(config: GeminiASRConfig, options: ASRRequestOptions = ASRRequestOptions()) throws -> URL {
        let baseURLString = GeminiASRConfig.webSocketBaseURL
        guard var components = URLComponents(string: baseURLString) else {
            throw GeminiProtocolError.invalidEndpoint
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: config.apiKey)
        ]

        guard let url = components.url else {
            throw GeminiProtocolError.invalidEndpoint
        }
        return url
    }

    /// Returns a redacted URL string safe for logging (without the API key).
    static func redactedURLString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "wss://generativelanguage.googleapis.com/... (redacted)"
        }
        if components.queryItems?.contains(where: { $0.name == "key" }) == true {
            components.queryItems = [URLQueryItem(name: "key", value: "REDACTED")]
        }
        return components.string ?? "wss://generativelanguage.googleapis.com/... (redacted)"
    }

    // MARK: - Outbound Messages

    /// Gemini expects a fully qualified `models/<id>` name. Users may paste
    /// either form when entering a custom model id, so normalize here.
    static func qualifiedModelName(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.hasPrefix("models/")
            ? String(trimmed.dropFirst("models/".count))
            : trimmed
        let resolved = bare.isEmpty ? GeminiASRConfig.defaultModel : bare
        return "models/\(resolved)"
    }

    static func setupMessage(config: GeminiASRConfig, options: ASRRequestOptions) throws -> String {
        var languageCodes: [String] = []
        let lang = config.languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lang.isEmpty && lang.lowercased() != "auto" {
            languageCodes.append(lang)
        }

        let customVocabulary = sanitizeHotwords(options.hotwords)

        var inputAudioTranscription: [String: Any] = [
            "mode": config.mode.rawValue,
            "languageCodes": languageCodes
        ]
        if !customVocabulary.isEmpty {
            inputAudioTranscription["customVocabulary"] = customVocabulary
        }

        let setupPayload: [String: Any] = [
            "setup": [
                "model": qualifiedModelName(config.model),
                "generationConfig": [
                    "responseModalities": ["TEXT"]
                ],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": true
                    ]
                ],
                "inputAudioTranscription": inputAudioTranscription
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: setupPayload, options: [])
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw GeminiProtocolError.invalidJSON
        }
        return jsonString
    }

    static func activityStartMessage() -> String {
        jsonString([
            "realtimeInput": [
                "activityStart": [:]
            ]
        ])
    }

    static func activityEndMessage() -> String {
        jsonString([
            "realtimeInput": [
                "activityEnd": [:]
            ]
        ])
    }

    static func audioChunkMessage(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        return jsonString([
            "realtimeInput": [
                "audio": [
                    "data": base64,
                    "mimeType": "audio/pcm;rate=\(sampleRate)"
                ]
            ]
        ])
    }

    // MARK: - Inbound Message Models & Parsing

    private struct InboundError: Decodable {
        let code: Int?
        let message: String?
        let status: String?
    }

    private struct TranscriptionContent: Decodable {
        let text: String?
    }

    private struct ServerContent: Decodable {
        let interimInputTranscription: TranscriptionContent?
        let inputTranscription: TranscriptionContent?
        let turnComplete: Bool?
        let interrupted: Bool?
    }

    private struct InboundEnvelope: Decodable {
        let setupComplete: [String: String]?
        let serverContent: ServerContent?
        let error: InboundError?
    }

    static func makeTranscriptUpdate(
        from data: Data,
        confirmedSegments: [String],
        didEndAudio: Bool,
        hotwords: [String] = []
    ) throws -> GeminiTranscriptUpdate? {
        guard data.first == UInt8(ascii: "{") else { return nil }

        // Attempt decoding raw dictionary or structure to check setupComplete / error / serverContent
        let decoder = JSONDecoder()
        let envelope: InboundEnvelope
        do {
            envelope = try decoder.decode(InboundEnvelope.self, from: data)
        } catch {
            // Also check for dynamic setupComplete representation (e.g. empty object `{}`)
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if root["setupComplete"] != nil {
                    return GeminiTranscriptUpdate(
                        transcript: .empty,
                        confirmedSegments: confirmedSegments,
                        isSetupComplete: true
                    )
                }
                if let errDict = root["error"] as? [String: Any] {
                    let code = errDict["code"] as? Int
                    let msg = errDict["message"] as? String
                    let status = errDict["status"] as? String
                    if code == 429 || status == "RESOURCE_EXHAUSTED" {
                        throw GeminiASRError.quotaExceeded(msg)
                    }
                    throw GeminiASRError.serverError(code: code, message: msg)
                }
            }
            return nil
        }

        if let error = envelope.error {
            if error.code == 429 || error.status == "RESOURCE_EXHAUSTED" {
                throw GeminiASRError.quotaExceeded(error.message)
            }
            throw GeminiASRError.serverError(code: error.code, message: error.message)
        }

        if envelope.setupComplete != nil {
            return GeminiTranscriptUpdate(
                transcript: .empty,
                confirmedSegments: confirmedSegments,
                isSetupComplete: true
            )
        }

        guard let serverContent = envelope.serverContent else {
            return nil
        }

        // 1. Finalized input transcription (authoritative segment)
        if let finalText = serverContent.inputTranscription?.text {
            let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = ASRHotwordLeakSanitizer.sanitize(trimmed, hotwords: hotwords)
            guard !sanitized.isEmpty else {
                guard didEndAudio else { return nil }
                let authoritative = confirmedSegments.joined()
                return GeminiTranscriptUpdate(
                    transcript: RecognitionTranscript(
                        confirmedSegments: confirmedSegments,
                        partialText: "",
                        authoritativeText: authoritative,
                        isFinal: true
                    ),
                    confirmedSegments: confirmedSegments,
                    isSetupComplete: false
                )
            }

            let normalized = normalize(segment: sanitized, after: confirmedSegments.joined())
            var updatedConfirmed = confirmedSegments
            updatedConfirmed.append(normalized)

            let fullAuthoritative = updatedConfirmed.joined()
            let transcript = RecognitionTranscript(
                confirmedSegments: updatedConfirmed,
                partialText: "",
                authoritativeText: fullAuthoritative,
                isFinal: didEndAudio
            )
            return GeminiTranscriptUpdate(
                transcript: transcript,
                confirmedSegments: updatedConfirmed,
                isSetupComplete: false
            )
        }

        // 2. Interim input transcription (streaming partial)
        if let interimText = serverContent.interimInputTranscription?.text {
            let trimmed = interimText.trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = ASRHotwordLeakSanitizer.sanitize(trimmed, hotwords: hotwords)
            guard !sanitized.isEmpty else { return nil }

            let confirmedJoined = confirmedSegments.joined()
            let normalizedInterim = normalize(segment: sanitized, after: confirmedJoined)

            let transcript = RecognitionTranscript(
                confirmedSegments: confirmedSegments,
                partialText: normalizedInterim,
                authoritativeText: confirmedJoined + normalizedInterim,
                isFinal: false
            )
            return GeminiTranscriptUpdate(
                transcript: transcript,
                confirmedSegments: confirmedSegments,
                isSetupComplete: false
            )
        }

        return nil
    }

    // MARK: - Hotwords & Normalization

    static func sanitizeHotwords(_ hotwords: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for word in hotwords {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                result.append(trimmed)
                if result.count >= maxCustomVocabularyCount {
                    break
                }
            }
        }
        return result
    }

    static func normalize(segment: String, after existingText: String) -> String {
        guard !segment.isEmpty, let last = existingText.last, let first = segment.first else {
            return segment
        }
        if last.isWhitespace || first.isWhitespace { return segment }
        if first.isClosingPunctuation || last.isOpeningPunctuation { return segment }
        if last.isCJKUnifiedIdeograph || first.isCJKUnifiedIdeograph { return segment }
        return " " + segment
    }

    // MARK: - Rechunking Helper

    /// Slices incoming audio data accumulated in `residual` into ~100ms (3,200 bytes) payloads.
    /// Remaining bytes (< 3,200) stay in `residual`.
    static func sliceAudioPayloads(from residual: inout Data) -> [Data] {
        var payloads: [Data] = []
        while residual.count >= targetPayloadBytes {
            let chunk = residual.prefix(targetPayloadBytes)
            payloads.append(chunk)
            residual.removeFirst(targetPayloadBytes)
        }
        return payloads
    }

    /// Flushes any residual audio data remaining in the buffer.
    static func flushResidualAudio(from residual: inout Data) -> Data? {
        guard !residual.isEmpty else { return nil }
        let chunk = residual
        residual.removeAll()
        return chunk
    }

    // MARK: - Utilities

    private static func jsonString(_ payload: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
