import Foundation

enum ElevenLabsProtocolError: Error, LocalizedError {
    case invalidEndpoint
    case serverError(type: String, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return L("无法生成 ElevenLabs WebSocket URL", "Failed to build ElevenLabs WebSocket URL")
        case .serverError(let type, let message):
            if let message, !message.isEmpty {
                return L("ElevenLabs 错误（\(type)）：\(message)", "ElevenLabs error (\(type)): \(message)")
            }
            return L("ElevenLabs 错误：\(type)", "ElevenLabs error: \(type)")
        }
    }
}

struct ElevenLabsTermsError: Error, LocalizedError {
    var errorDescription: String? {
        L("ElevenLabs 条款尚未接受。请访问 elevenlabs.io/app/product-terms 启用 Speech-to-Text。", "ElevenLabs terms not accepted. Please visit elevenlabs.io/app/product-terms to enable Speech-to-Text.")
    }
}

struct ElevenLabsTranscriptUpdate: Sendable, Equatable {
    let transcript: RecognitionTranscript
    let confirmedSegments: [String]
}

enum ElevenLabsProtocol {

    private static let endpoint = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
    private static let sampleRate = 16000

    // MARK: - URL

    static func buildWebSocketURL(config: ElevenLabsASRConfig, options: ASRRequestOptions) throws -> URL {
        guard var components = URLComponents(string: endpoint) else {
            throw ElevenLabsProtocolError.invalidEndpoint
        }
        var queryItems = [
            URLQueryItem(name: "model_id", value: config.model),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "no_verbatim", value: "true"),
        ]
        if !config.language.isEmpty {
            queryItems.append(URLQueryItem(name: "language_code", value: config.language))
        }
        // Keyterm prompting: ElevenLabs supports up to 50 keyterms, each ≤20 characters
        let keyterms = options.hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 20 }
            .prefix(50)
        for term in keyterms {
            queryItems.append(URLQueryItem(name: "keyterm", value: term))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ElevenLabsProtocolError.invalidEndpoint
        }
        return url
    }

    // MARK: - Outbound messages

    /// Encode a PCM audio chunk as a JSON message with base64 audio.
    static func audioChunkMessage(_ pcmData: Data) -> String {
        let b64 = pcmData.base64EncodedString()
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": b64,
            "sample_rate": sampleRate,
        ]
        return jsonString(payload)
    }

    /// Final commit message — tells the server to finalize the current segment.
    static func commitMessage() -> String {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": "",
            "commit": true,
            "sample_rate": sampleRate,
        ]
        return jsonString(payload)
    }

    // MARK: - Inbound message parsing

    private struct InboundMessage: Decodable {
        let messageType: String
        let text: String?          // ElevenLabs uses "text" not "transcript"
        let message: String?       // Error detail message

        enum CodingKeys: String, CodingKey {
            case messageType = "message_type"
            case text
            case message
        }
    }

    static func makeTranscriptUpdate(
        from data: Data,
        confirmedSegments: [String],
        isFinalCommit: Bool = false,
        languageCode: String = ""
    ) throws -> ElevenLabsTranscriptUpdate? {
        guard data.first == UInt8(ascii: "{") else { return nil }
        let message = try JSONDecoder().decode(InboundMessage.self, from: data)

        switch message.messageType {
        case "partial_transcript":
            guard let text = message.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let confirmed = confirmedSegments.joined()
            // ElevenLabs sends cumulative text — strip the already-confirmed prefix to avoid duplication
            let partialOnly = stripConfirmedPrefix(from: text, confirmed: confirmed)
            guard !partialOnly.isEmpty else { return nil }
            let punctuated = ScriptPunctuationNormalizer.normalizeIfNeeded(
                languageCode: languageCode,
                text: partialOnly
            )
            let normalized = normalize(segment: punctuated, after: confirmed)
            let transcript = RecognitionTranscript(
                confirmedSegments: confirmedSegments,
                partialText: normalized,
                authoritativeText: (confirmedSegments + [normalized]).joined(),
                isFinal: false
            )
            return ElevenLabsTranscriptUpdate(transcript: transcript, confirmedSegments: confirmedSegments)

        case "committed_transcript":
            let trimmed = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let confirmed = confirmedSegments.joined()
            var next = confirmedSegments
            if !trimmed.isEmpty {
                let newOnly = stripConfirmedPrefix(from: trimmed, confirmed: confirmed)
                if !newOnly.isEmpty {
                    let punctuated = ScriptPunctuationNormalizer.normalizeIfNeeded(
                        languageCode: languageCode,
                        text: newOnly
                    )
                    next.append(normalize(segment: punctuated, after: confirmed))
                }
            }
            // Mid-stream auto-commits (VAD) use isFinal: false so the session keeps recording.
            // Only the explicit endAudio() commit uses isFinal: true to trigger injection.
            let transcript = RecognitionTranscript(
                confirmedSegments: next,
                partialText: "",
                authoritativeText: next.joined(),
                isFinal: isFinalCommit
            )
            return ElevenLabsTranscriptUpdate(transcript: transcript, confirmedSegments: next)

        case "commit_throttled":
            // VAD already committed all audio before our explicit commit — treat as final.
            if !confirmedSegments.isEmpty || isFinalCommit {
                let transcript = RecognitionTranscript(
                    confirmedSegments: confirmedSegments,
                    partialText: "",
                    authoritativeText: confirmedSegments.joined(),
                    isFinal: true
                )
                return ElevenLabsTranscriptUpdate(transcript: transcript, confirmedSegments: confirmedSegments)
            }
            return nil

        case "unaccepted_terms":
            // Surface this as a real error — user must accept terms at elevenlabs.io/app/product-terms
            throw ElevenLabsTermsError()

        case "session_time_limit_exceeded", "error":
            throw ElevenLabsProtocolError.serverError(type: message.messageType, message: message.message)

        case "insufficient_audio_activity", "chunk_size_exceeded":
            return nil

        default:
            return nil
        }
    }

    // MARK: - Helpers

    private static func jsonString(_ payload: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Strips the already-confirmed text prefix from `text` if ElevenLabs sends cumulative partials.
    private static func stripConfirmedPrefix(from text: String, confirmed: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmed.isEmpty else { return t }
        let c = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix(c) {
            return String(t.dropFirst(c.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    private static func normalize(segment: String, after existingText: String) -> String {
        guard !segment.isEmpty, let last = existingText.last, let first = segment.first else {
            return segment
        }
        if last.isWhitespace || first.isWhitespace { return segment }
        if first.isClosingPunctuation || last.isOpeningPunctuation { return segment }
        if last.isCJKUnifiedIdeograph || first.isCJKUnifiedIdeograph { return segment }
        return " " + segment
    }
}
