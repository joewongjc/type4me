import Foundation

enum AssemblyAIProtocolError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case invalidMessage

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return L("无法生成 AssemblyAI WebSocket URL", "Failed to build AssemblyAI WebSocket URL")
        case .invalidMessage:
            return L("AssemblyAI 流式消息无效", "Invalid AssemblyAI streaming message")
        }
    }
}

struct AssemblyAITurnUpdate: Sendable, Equatable {
    let turnOrder: Int
    let finalizedText: String
    let displayText: String
    let authoritativeText: String
    let isFinal: Bool
    let isFormatted: Bool
}

enum AssemblyAIServerEvent: Sendable, Equatable {
    case begin(id: String, expiresAt: Int?)
    case turn(AssemblyAITurnUpdate)
    case termination(audioDurationSeconds: Double?)
    case speechStarted
}

enum AssemblyAIProtocol {

    private static let endpoint = "wss://streaming.assemblyai.com/v3/ws"
    private static let maxKeytermCount = 100
    private static let maxKeytermLength = 50

    static func buildWebSocketURL(
        config: AssemblyAIASRConfig,
        options: ASRRequestOptions
    ) throws -> URL {
        guard var components = URLComponents(string: endpoint) else {
            throw AssemblyAIProtocolError.invalidEndpoint
        }

        var queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "speech_model", value: config.model),
        ]

        if usesFormatTurns(model: config.model) {
            queryItems.append(
                URLQueryItem(name: "format_turns", value: options.enablePunc ? "true" : "false")
            )
        }

        // Keyterms are sent via UpdateConfiguration message after connection
        // to avoid URL length limits that cause connection failures.

        components.queryItems = queryItems

        guard let url = components.url else {
            throw AssemblyAIProtocolError.invalidEndpoint
        }
        return url
    }

    static func terminateMessage() -> String {
        #"{"type":"Terminate"}"#
    }

    static func updateConfigurationMessage(hotwords: [String]) -> String? {
        let keyterms = sanitizedKeyterms(from: hotwords)
        guard !keyterms.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "type": "UpdateConfiguration",
            "keyterms_prompt": keyterms,
        ] as [String: Any], options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parseServerEvent(from data: Data) throws -> AssemblyAIServerEvent? {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)

        switch envelope.type {
        case "Begin":
            let begin = try decoder.decode(BeginMessage.self, from: data)
            return .begin(id: begin.id, expiresAt: begin.expiresAt)

        case "Turn":
            let turn = try decoder.decode(TurnMessage.self, from: data)
            guard let update = makeTurnUpdate(from: turn) else {
                return nil
            }
            return .turn(update)

        case "Termination":
            let termination = try decoder.decode(TerminationMessage.self, from: data)
            return .termination(audioDurationSeconds: termination.audioDurationSeconds)

        case "SpeechStarted":
            return .speechStarted

        default:
            return nil
        }
    }

    static func makeTurnUpdate(from message: TurnMessage) -> AssemblyAITurnUpdate? {
        let transcript = sanitized(message.transcript) ?? ""
        let words = message.words ?? []
        let displayText = transcriptText(from: message, transcript: transcript)
        let finalizedText = message.endOfTurn ? displayText : finalizedPrefix(from: words)

        guard !displayText.isEmpty || !finalizedText.isEmpty || message.endOfTurn else {
            return nil
        }

        let authoritativeText = message.endOfTurn ? displayText : finalizedText

        return AssemblyAITurnUpdate(
            turnOrder: message.turnOrder,
            finalizedText: finalizedText,
            displayText: displayText,
            authoritativeText: authoritativeText,
            isFinal: message.endOfTurn,
            isFormatted: message.turnIsFormatted
        )
    }

    static func makeCloseError(code: Int, reason: String?) -> AssemblyAIASRError {
        let cleanReason = sanitized(reason)
        switch code {
        case 1008:
            return AssemblyAIASRError.unauthorized(reason: cleanReason)
        case 3005:
            return AssemblyAIASRError.serverCancelled(reason: cleanReason)
        default:
            return AssemblyAIASRError.closed(code: code, reason: cleanReason)
        }
    }

    private static func usesFormatTurns(model: String) -> Bool {
        model.hasPrefix("universal-streaming-")
    }

    private static func sanitizedKeyterms(from hotwords: [String]) -> [String] {
        hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(maxKeytermLength)) }
            .prefix(maxKeytermCount)
            .map { $0 }
    }

    private static func encodedKeytermsPrompt(from hotwords: [String]) -> String? {
        let keyterms = sanitizedKeyterms(from: hotwords)
        guard !keyterms.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: keyterms, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func transcriptText(from message: TurnMessage, transcript: String) -> String {
        if message.endOfTurn {
            return !transcript.isEmpty ? transcript : joinWords(message.words ?? [])
        }

        let joinedWords = joinWords(message.words ?? [])
        if joinedWords.isEmpty {
            return transcript
        }

        if transcript.isEmpty {
            return joinedWords
        }

        return joinedWords.count >= transcript.count ? joinedWords : transcript
    }

    private static func finalizedPrefix(from words: [TurnWord]) -> String {
        let finalizedWords = words.prefix { $0.wordIsFinal }
        return joinWords(Array(finalizedWords))
    }

    private static func joinWords(_ words: [TurnWord]) -> String {
        var text = ""
        for word in words {
            let token = sanitized(word.text) ?? ""
            guard !token.isEmpty else { continue }
            text += normalized(segment: token, after: text)
        }
        return text
    }

    private static func normalized(segment: String, after existingText: String) -> String {
        guard !segment.isEmpty else { return "" }
        guard let last = existingText.last else { return segment }
        guard let first = segment.first else { return segment }

        if last.isWhitespace || first.isWhitespace {
            return segment
        }

        if first.isClosingPunctuation || last.isOpeningPunctuation {
            return segment
        }

        if last.isCJKUnifiedIdeograph || first.isCJKUnifiedIdeograph {
            return segment
        }

        return " " + segment
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private struct Envelope: Decodable {
        let type: String
    }

    private struct BeginMessage: Decodable {
        let type: String
        let id: String
        let expiresAt: Int?

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case expiresAt = "expires_at"
        }
    }

    struct TurnMessage: Decodable, Sendable {
        let type: String
        let turnOrder: Int
        let turnIsFormatted: Bool
        let endOfTurn: Bool
        let transcript: String
        let words: [TurnWord]?

        enum CodingKeys: String, CodingKey {
            case type
            case turnOrder = "turn_order"
            case turnIsFormatted = "turn_is_formatted"
            case endOfTurn = "end_of_turn"
            case transcript
            case words
        }
    }

    struct TurnWord: Decodable, Sendable, Equatable {
        let text: String
        let wordIsFinal: Bool

        enum CodingKeys: String, CodingKey {
            case text
            case wordIsFinal = "word_is_final"
        }
    }

    private struct TerminationMessage: Decodable {
        let type: String
        let audioDurationSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case type
            case audioDurationSeconds = "audio_duration_seconds"
        }
    }
}

// Character extensions moved to CharacterExtensions.swift
