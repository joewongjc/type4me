import Foundation

enum BailianProtocolError: Error, LocalizedError, Equatable {
    case invalidMessage
    case taskFailed(code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidMessage:
            return "Invalid Alibaba Cloud Bailian ASR message"
        case .taskFailed(let code, let message):
            let codePart = code?.isEmpty == false ? "[\(code!)] " : ""
            let messagePart = message?.isEmpty == false ? message! : "Task failed"
            return "Alibaba Cloud Bailian ASR failed: \(codePart)\(messagePart)"
        }
    }
}

struct BailianTranscriptUpdate: Sendable, Equatable {
    let transcript: RecognitionTranscript
    let confirmedSegments: [String]
}

enum BailianServerEvent: Sendable, Equatable {
    case taskStarted(taskID: String?)
    case transcript(BailianTranscriptUpdate)
    case taskFinished(taskID: String?)
    case taskFailed(code: String?, message: String?)
}

enum BailianProtocol {

    static let endpoint = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!

    static func buildRunTaskMessage(
        config: BailianASRConfig,
        options: ASRRequestOptions,
        taskID: String
    ) -> String {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16000,
            "semantic_punctuation_enabled": false,
            "max_sentence_silence": 800,
            "multi_threshold_mode_enabled": false,
            "heartbeat": false,
        ]

        if let vocabularyID = sanitized(options.boostingTableID) ?? sanitized(config.vocabularyId) {
            parameters["vocabulary_id"] = vocabularyID
        }

        if let languageHint = sanitized(config.languageHint) {
            parameters["language_hints"] = [languageHint]
        }

        let payload: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": config.model,
                "parameters": parameters,
                "input": [:],
            ],
        ]

        return jsonString(from: payload)
    }

    static func buildFinishTaskMessage(taskID: String) -> String {
        let payload: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": [
                "input": [:],
            ],
        ]

        return jsonString(from: payload)
    }

    static func parseServerEvent(
        from data: Data,
        confirmedSegments: [String]
    ) throws -> BailianServerEvent? {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)

        switch envelope.header.event {
        case "task-started":
            return .taskStarted(taskID: envelope.header.taskID)

        case "result-generated":
            let message = try decoder.decode(ResultMessage.self, from: data)
            guard let update = makeTranscriptUpdate(
                sentence: message.payload.output?.sentence,
                confirmedSegments: confirmedSegments
            ) else {
                return nil
            }
            return .transcript(update)

        case "task-finished":
            return .taskFinished(taskID: envelope.header.taskID)

        case "task-failed":
            return .taskFailed(
                code: envelope.header.errorCode,
                message: envelope.header.errorMessage
            )

        default:
            return nil
        }
    }

    static func makeTranscriptUpdate(
        sentence: BailianSentence?,
        confirmedSegments: [String]
    ) -> BailianTranscriptUpdate? {
        guard let sentence else { return nil }
        if sentence.heartbeat == true { return nil }

        let trimmedText = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFinal = sentence.sentenceEnd

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
        return BailianTranscriptUpdate(
            transcript: transcript,
            confirmedSegments: nextConfirmed
        )
    }

    private static func jsonString(from object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
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
        let header: Header
    }

    private struct Header: Decodable {
        let event: String
        let taskID: String?
        let errorCode: String?
        let errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case event
            case taskID = "task_id"
            case errorCode = "error_code"
            case errorMessage = "error_message"
        }
    }

    private struct ResultMessage: Decodable {
        let payload: ResultPayload
    }

    private struct ResultPayload: Decodable {
        let output: ResultOutput?
    }

    private struct ResultOutput: Decodable {
        let sentence: BailianSentence?
    }
}

struct BailianSentence: Decodable, Sendable, Equatable {
    let text: String
    let heartbeat: Bool?
    let sentenceEnd: Bool

    enum CodingKeys: String, CodingKey {
        case text
        case heartbeat
        case sentenceEnd = "sentence_end"
    }
}

private extension Character {
    var isClosingPunctuation: Bool {
        ",.!?;:)]}\"'".contains(self)
    }

    var isOpeningPunctuation: Bool {
        "([{/\"'".contains(self)
    }

    var isCJKUnifiedIdeograph: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }
}
