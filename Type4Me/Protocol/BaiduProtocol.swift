import Foundation

enum BaiduProtocolError: Error, LocalizedError, Equatable {
    case invalidMessage
    case serverError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidMessage:
            return "Invalid Baidu realtime ASR message"
        case .serverError(let code, let message):
            return "Baidu realtime ASR failed [\(code)]: \(message)"
        }
    }
}

struct BaiduTranscriptUpdate: Sendable, Equatable {
    let transcript: RecognitionTranscript
    let confirmedSegments: [String]
}

enum BaiduServerEvent: Sendable, Equatable {
    case transcript(BaiduTranscriptUpdate)
    case sentenceFailed(code: Int, message: String, transcript: BaiduTranscriptUpdate)
    case serverError(code: Int, message: String)
}

enum BaiduProtocol {

    static let endpoint = URL(string: "wss://vop.baidu.com/realtime_asr")!

    private static let punctuationDisabledDevPIDMap: [Int: Int] = [
        15372: 1537,
        17372: 1737,
    ]

    static func buildWebSocketURL(requestID: String) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "sn", value: requestID),
        ]
        return components.url!
    }

    static func buildStartMessage(
        config: BaiduASRConfig,
        options: ASRRequestOptions
    ) -> String {
        var data: [String: Any] = [
            "appid": config.appID,
            "appkey": config.apiKey,
            "dev_pid": effectiveDevPID(from: config.devPID, enablePunc: options.enablePunc),
            "cuid": config.cuid,
            "format": "pcm",
            "sample": 16000,
        ]

        if let lmID = sanitized(config.lmID) {
            data["lm_id"] = lmID
        }

        let payload: [String: Any] = [
            "type": "START",
            "data": data,
        ]
        return jsonString(from: payload)
    }

    static func buildFinishMessage() -> String {
        jsonString(from: [
            "type": "FINISH",
        ])
    }

    static func parseServerEvent(
        from data: Data,
        confirmedSegments: [String]
    ) throws -> BaiduServerEvent? {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)

        switch envelope.type.uppercased() {
        case "HEARTBEAT":
            return nil

        case "MID_TEXT":
            let message = try decoder.decode(ServerMessage.self, from: data)
            guard let update = makeTranscriptUpdate(
                result: message.result,
                isFinal: false,
                confirmedSegments: confirmedSegments
            ) else {
                return nil
            }
            return .transcript(update)

        case "FIN_TEXT":
            let message = try decoder.decode(ServerMessage.self, from: data)
            let clearingUpdate = makeTranscriptUpdate(
                result: "",
                isFinal: true,
                confirmedSegments: confirmedSegments
            )!

            if message.errNo != 0 {
                return .sentenceFailed(
                    code: message.errNo,
                    message: message.errMsg,
                    transcript: clearingUpdate
                )
            }

            let update = makeTranscriptUpdate(
                result: message.result,
                isFinal: true,
                confirmedSegments: confirmedSegments
            ) ?? clearingUpdate
            return .transcript(update)

        case "ERROR":
            let message = try decoder.decode(ServerMessage.self, from: data)
            return .serverError(code: message.errNo, message: message.errMsg)

        default:
            return nil
        }
    }

    static func effectiveDevPID(from configuredDevPID: Int, enablePunc: Bool) -> Int {
        guard !enablePunc else { return configuredDevPID }
        return punctuationDisabledDevPIDMap[configuredDevPID] ?? configuredDevPID
    }

    private static func makeTranscriptUpdate(
        result: String,
        isFinal: Bool,
        confirmedSegments: [String]
    ) -> BaiduTranscriptUpdate? {
        let trimmedText = result.trimmingCharacters(in: .whitespacesAndNewlines)

        var nextConfirmed = confirmedSegments
        var partialText = ""

        if !trimmedText.isEmpty {
            let normalized = normalize(segment: trimmedText, after: confirmedSegments.joined())
            if isFinal {
                nextConfirmed.append(normalized)
            } else {
                partialText = normalized
            }
        } else if !isFinal {
            return nil
        }

        let authoritativeText = (nextConfirmed + (partialText.isEmpty ? [] : [partialText])).joined()
        let transcript = RecognitionTranscript(
            confirmedSegments: nextConfirmed,
            partialText: partialText,
            authoritativeText: authoritativeText,
            isFinal: isFinal
        )
        return BaiduTranscriptUpdate(
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

    private struct Envelope: Decodable {
        let type: String
    }

    private struct ServerMessage: Decodable {
        let type: String
        let result: String
        let errNo: Int
        let errMsg: String

        enum CodingKeys: String, CodingKey {
            case type
            case result
            case errNo = "err_no"
            case errMsg = "err_msg"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            result = try container.decodeIfPresent(String.self, forKey: .result) ?? ""
            errNo = container.decodeLossyInt(forKey: .errNo) ?? 0
            errMsg = try container.decodeIfPresent(String.self, forKey: .errMsg) ?? ""
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyInt(forKey key: Key) -> Int? {
        if let intValue = try? decode(Int.self, forKey: key) {
            return intValue
        }

        if let stringValue = try? decode(String.self, forKey: key) {
            return Int(stringValue)
        }

        return nil
    }
}
