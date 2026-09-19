import Foundation

enum GrokProtocolError: Error, LocalizedError {
    case invalidEndpoint
    case serverError(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Failed to build Grok WebSocket URL"
        case .serverError(let message):
            return message.isEmpty ? "Grok STT error" : "Grok STT error: \(message)"
        }
    }
}

/// Mirrors xAI streaming STT: committed utterances (speech_final) + in-flight chunk finals.
struct GrokTranscriptState: Sendable, Equatable {
    var utterances: [String]
    var chunks: [String]

    static let empty = GrokTranscriptState(utterances: [], chunks: [])

    var confirmedSegments: [String] {
        if chunks.isEmpty { return utterances }
        if utterances.isEmpty { return chunks }
        var stitched = chunks
        stitched[0] = GrokProtocol.normalize(segment: stitched[0], after: utterances.joined())
        return utterances + stitched
    }

    var joinedConfirmed: String {
        confirmedSegments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct GrokTranscriptUpdate: Sendable, Equatable {
    let transcript: RecognitionTranscript
    let state: GrokTranscriptState
    let serverReady: Bool

    var confirmedSegments: [String] { state.confirmedSegments }
}

enum GrokProtocol {

    private static let endpoint = "wss://api.x.ai/v1/stt"
    private static let sampleRate = 16000

    static func buildWebSocketURL(config: GrokASRConfig, options: ASRRequestOptions) throws -> URL {
        guard var components = URLComponents(string: endpoint) else {
            throw GrokProtocolError.invalidEndpoint
        }

        // See https://docs.x.ai/developers/model-capabilities/audio/speech-to-text#streaming-speech-to-text-websocket
        var queryItems = [
            URLQueryItem(name: "model", value: GrokASRConfig.model),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "filler_words", value: "false"),
            // PTT/dictation: reduce false speech_final on brief pauses (default endpointing is 10ms).
            URLQueryItem(name: "smart_turn", value: "0.7"),
            URLQueryItem(name: "smart_turn_timeout", value: "3000"),
        ]

        if !config.language.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: config.language))
        }

        let keyterms = options.hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 50 }
            .prefix(100)
        for term in keyterms {
            queryItems.append(URLQueryItem(name: "keyterm", value: term))
        }

        components.queryItems = queryItems
        guard let url = components.url else {
            throw GrokProtocolError.invalidEndpoint
        }
        return url
    }

    static func finalizeMessage() -> String {
        jsonString(["type": "finalize"])
    }

    static func audioDoneMessage() -> String {
        jsonString(["type": "audio.done"])
    }

    private struct InboundMessage: Decodable {
        let type: String
        let text: String?
        let isFinal: Bool?
        let speechFinal: Bool?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case type, text, message
            case isFinal = "is_final"
            case speechFinal = "speech_final"
        }
    }

    static func makeTranscriptUpdate(
        from data: Data,
        state: GrokTranscriptState,
        isFinalCommit: Bool = false
    ) throws -> GrokTranscriptUpdate? {
        guard data.first == UInt8(ascii: "{") else { return nil }
        let message = try JSONDecoder().decode(InboundMessage.self, from: data)

        switch message.type {
        case "transcript.created":
            return GrokTranscriptUpdate(
                transcript: .empty,
                state: state,
                serverReady: true
            )

        case "transcript.partial":
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isFinal = message.isFinal ?? false
            let speechFinal = message.speechFinal ?? false

            if !isFinal {
                guard !text.isEmpty else { return nil }
                return interimUpdate(text: text, state: state)
            }

            if speechFinal {
                let next = applySpeechFinal(text, to: state)
                return transcriptUpdate(from: next, isFinalCommit: isFinalCommit)
            }

            let next = applyChunkFinal(text, to: state)
            return transcriptUpdate(from: next, isFinalCommit: false)

        case "transcript.done":
            let next = applyTranscriptDone(message.text, to: state)
            return transcriptUpdate(from: next, isFinalCommit: isFinalCommit)

        case "error":
            throw GrokProtocolError.serverError(message: message.message ?? "")

        default:
            return nil
        }
    }

    // MARK: - Event handlers (xAI semantics)

    private static func interimUpdate(text: String, state: GrokTranscriptState) -> GrokTranscriptUpdate? {
        let confirmed = state.joinedConfirmed
        let partialOnly = stripConfirmedPrefix(from: text, confirmed: confirmed)
        guard !partialOnly.isEmpty else { return nil }

        let normalized = normalize(segment: partialOnly, after: confirmed)
        let transcript = RecognitionTranscript(
            confirmedSegments: state.confirmedSegments,
            partialText: normalized,
            authoritativeText: confirmed + normalized,
            isFinal: false
        )
        return GrokTranscriptUpdate(transcript: transcript, state: state, serverReady: false)
    }

    /// Chunk final: incremental ~3s segment; append unless duplicate of tail.
    private static func applyChunkFinal(_ text: String, to state: GrokTranscriptState) -> GrokTranscriptState {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return state }

        var chunks = state.chunks
        let joined = chunks.joined()
        if joined.isEmpty {
            chunks = [trimmed]
        } else if joined == trimmed || joined.hasSuffix(trimmed) {
            // duplicate chunk — ignore
        } else {
            chunks.append(normalize(segment: trimmed, after: state.utterances.joined() + joined))
        }
        return GrokTranscriptState(utterances: state.utterances, chunks: chunks)
    }

    /// Utterance final: server sends the complete stitched utterance for this pause.
    /// Revisions replace the previous utterance; genuinely new pauses append.
    private static func applySpeechFinal(_ text: String, to state: GrokTranscriptState) -> GrokTranscriptState {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return GrokTranscriptState(utterances: state.utterances, chunks: [])
        }

        let utterance = stitchChunks(withSpeechFinal: trimmed, chunks: state.chunks)
        var utterances = state.utterances
        commitUtterance(utterance, into: &utterances)
        return GrokTranscriptState(utterances: utterances, chunks: [])
    }

    /// Session final after audio.done — prefer the server's full transcript.
    private static func applyTranscriptDone(_ text: String?, to state: GrokTranscriptState) -> GrokTranscriptState {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let joined = state.joinedConfirmed.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return state
        }
        if joined.isEmpty {
            return GrokTranscriptState(utterances: [trimmed], chunks: [])
        }

        let resolved = preferAuthoritativeText(server: trimmed, accumulated: joined)
        return GrokTranscriptState(utterances: [resolved], chunks: [])
    }

    private static func transcriptUpdate(
        from state: GrokTranscriptState,
        isFinalCommit: Bool
    ) -> GrokTranscriptUpdate? {
        let text = state.joinedConfirmed
        guard !text.isEmpty else { return nil }
        let transcript = RecognitionTranscript(
            confirmedSegments: state.confirmedSegments,
            partialText: "",
            authoritativeText: text,
            isFinal: isFinalCommit
        )
        return GrokTranscriptUpdate(transcript: transcript, state: state, serverReady: false)
    }

    // MARK: - Stitching & commit

    private static func stitchChunks(withSpeechFinal final: String, chunks: [String]) -> String {
        let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
        let chunkText = chunks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunkText.isEmpty else { return trimmed }

        // speech_final is the stitched utterance when it covers pending chunks.
        if trimmed.hasPrefix(chunkText) || chunkText.hasPrefix(trimmed) {
            return preferLonger(trimmed, over: chunkText)
        }

        // Tail-only speech_final: keep chunk finals that xAI omitted from the event.
        if wordOverlapRatio(normalizedWords(trimmed), normalizedWords(chunkText)) < 0.2 {
            return chunkText + normalize(segment: trimmed, after: chunkText)
        }
        return trimmed
    }

    private static func commitUtterance(_ text: String, into utterances: inout [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let last = utterances.last, revisesSamePause(trimmed, last) {
            utterances[utterances.count - 1] = trimmed
            return
        }

        if utterances.isEmpty {
            utterances = [trimmed]
        } else {
            utterances.append(normalize(segment: trimmed, after: utterances.joined()))
        }
    }

    /// Same pause revision: extension, shared long opening + overlap, or near-duplicate wording.
    private static func revisesSamePause(_ candidate: String, _ previous: String) -> Bool {
        let candWords = normalizedWords(candidate)
        let prevWords = normalizedWords(previous)
        guard !candWords.isEmpty, !prevWords.isEmpty else { return false }

        let cand = candWords.joined(separator: " ")
        let prev = prevWords.joined(separator: " ")
        if cand.hasPrefix(prev) || prev.hasPrefix(cand) { return true }

        let opening = min(3, candWords.count, prevWords.count)
        if opening >= 3 {
            let sameOpening = zip(candWords.prefix(opening), prevWords.prefix(opening)).allSatisfy({ $0 == $1 })
            if sameOpening {
                if min(candWords.count, prevWords.count) >= 10 { return true }
                if wordOverlapRatio(candWords, prevWords) >= 0.72 { return true }
            }
        }

        return wordOverlapRatio(candWords, prevWords) >= 0.72
    }

    private static func wordOverlapRatio(_ a: [String], _ b: [String]) -> Double {
        let union = Set(a).union(Set(b))
        guard !union.isEmpty else { return 0 }
        return Double(Set(a).intersection(Set(b)).count) / Double(union.count)
    }

    private static func preferAuthoritativeText(server: String, accumulated: String) -> String {
        if server == accumulated { return server }
        if revisesSamePause(server, accumulated) || revisesSamePause(accumulated, server) {
            return preferLonger(server, over: accumulated)
        }
        if server.contains(accumulated) { return server }
        if accumulated.contains(server) { return accumulated }
        return preferLonger(server, over: accumulated)
    }

    private static func preferLonger(_ a: String, over b: String) -> String {
        normalizedWords(a).count >= normalizedWords(b).count ? a : b
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "n't", with: " not")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    // MARK: - Utilities

    private static func jsonString(_ payload: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    fileprivate static func normalize(segment: String, after existingText: String) -> String {
        guard !segment.isEmpty, let last = existingText.last, let first = segment.first else {
            return segment
        }
        if last.isWhitespace || first.isWhitespace { return segment }
        if first.isClosingPunctuation || last.isOpeningPunctuation { return segment }
        if last.isCJKUnifiedIdeograph || first.isCJKUnifiedIdeograph { return segment }
        return " " + segment
    }

    private static func stripConfirmedPrefix(from text: String, confirmed: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmed.isEmpty else { return trimmed }
        let prefix = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
