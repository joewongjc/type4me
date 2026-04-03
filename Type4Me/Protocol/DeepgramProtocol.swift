import Foundation

enum DeepgramProtocolError: Error, LocalizedError {
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Failed to build Deepgram WebSocket URL"
        }
    }
}

struct DeepgramTranscriptUpdate: Sendable, Equatable {
    let transcript: RecognitionTranscript
    let confirmedSegments: [String]
}

enum DeepgramProtocol {

    private static let endpoint = "wss://api.deepgram.com/v1/listen"
    private static let keywordIntensity = 2
    private static let maxURLKeyterms = 30

    static func buildWebSocketURL(
        config: DeepgramASRConfig,
        options: ASRRequestOptions
    ) throws -> URL {
        guard var components = URLComponents(string: endpoint) else {
            throw DeepgramProtocolError.invalidEndpoint
        }

        var queryItems = [
            URLQueryItem(name: "model", value: config.model),
            URLQueryItem(name: "language", value: config.language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "punctuate", value: options.enablePunc ? "true" : "false"),
            URLQueryItem(name: "smart_format", value: "true"),
        ]

        if config.numerals {
            queryItems.append(URLQueryItem(name: "numerals", value: "true"))
        }

        let hotwords = options.hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxURLKeyterms)

        if config.model.lowercased().hasPrefix("nova-3") {
            queryItems.append(contentsOf: hotwords.map {
                URLQueryItem(name: "keyterm", value: $0)
            })
        } else {
            queryItems.append(contentsOf: hotwords.map {
                URLQueryItem(name: "keywords", value: "\($0):\(keywordIntensity)")
            })
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw DeepgramProtocolError.invalidEndpoint
        }
        return url
    }

    static func closeStreamMessage() -> String {
        #"{"type":"CloseStream"}"#
    }

    static func makeTranscriptUpdate(
        from data: Data,
        confirmedSegments: [String]
    ) throws -> DeepgramTranscriptUpdate? {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)

        guard envelope.type == "Results" else {
            return nil
        }

        let message = try decoder.decode(ResultsMessage.self, from: data)
        let transcriptText = message.channel?.alternatives.first?.transcript ?? ""
        let trimmedText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFinal = message.isFinal || message.speechFinal || message.fromFinalize

        var nextConfirmed = confirmedSegments
        var partialText = ""

        if !trimmedText.isEmpty {
            let normalized = normalize(segment: trimmedText, after: confirmedSegments.joined())
            if isFinal {
                nextConfirmed.append(normalized)
            } else {
                partialText = normalized
            }
        } else if !isFinal || confirmedSegments.isEmpty {
            return nil
        }

        let authoritativeText = (nextConfirmed + (partialText.isEmpty ? [] : [partialText])).joined()
        let transcript = RecognitionTranscript(
            confirmedSegments: nextConfirmed,
            partialText: partialText,
            authoritativeText: authoritativeText,
            isFinal: isFinal
        )
        return DeepgramTranscriptUpdate(
            transcript: transcript,
            confirmedSegments: nextConfirmed
        )
    }

    private static func normalize(segment: String, after existingText: String) -> String {
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

    private struct Envelope: Decodable {
        let type: String
    }

    private struct ResultsMessage: Decodable {
        let type: String
        let channel: Channel?
        let isFinal: Bool
        let speechFinal: Bool
        let fromFinalize: Bool

        enum CodingKeys: String, CodingKey {
            case type
            case channel
            case isFinal = "is_final"
            case speechFinal = "speech_final"
            case fromFinalize = "from_finalize"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            channel = try container.decodeIfPresent(Channel.self, forKey: .channel)
            isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
            speechFinal = try container.decodeIfPresent(Bool.self, forKey: .speechFinal) ?? false
            fromFinalize = try container.decodeIfPresent(Bool.self, forKey: .fromFinalize) ?? false
        }
    }

    private struct Channel: Decodable {
        let alternatives: [Alternative]
    }

    private struct Alternative: Decodable {
        let transcript: String
    }
}

// Character extensions moved to CharacterExtensions.swift
