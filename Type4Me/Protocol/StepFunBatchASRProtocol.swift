import Foundation

enum StepFunBatchASRError: Error, LocalizedError, Equatable {
    case invalidConfig
    case emptyAudio
    case invalidEndpoint
    case requestFailed(code: Int, message: String?)
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "StepFun batch ASR requires StepFunASRConfig"
        case .emptyAudio:
            return L("没有录到音频", "No audio data recorded")
        case .invalidEndpoint:
            return "Invalid StepFun batch ASR endpoint"
        case .requestFailed(let code, let message):
            if let message, !message.isEmpty {
                return "StepFun API returned HTTP \(code): \(message)"
            }
            return "StepFun API returned HTTP \(code)"
        case .invalidResponse:
            return L("阶跃星辰返回了无法解析的识别结果", "StepFun returned an invalid transcription response")
        case .serverError(let message):
            return message
        }
    }
}

enum StepFunBatchSSEEvent: Equatable {
    case delta(String)
    case done(String)
    case error(String)
}

enum StepFunBatchASRProtocol {

    static func buildRequest(
        pcmData: Data,
        config: StepFunASRConfig,
        options: ASRRequestOptions
    ) throws -> URLRequest {
        guard let url = URL(string: config.accessMode.endpoint) else {
            throw StepFunBatchASRError.invalidEndpoint
        }

        let transcription = Transcription(
            hotwords: options.hotwords.isEmpty ? nil : options.hotwords,
            model: StepFunASRConfig.batchModel,
            enableITN: true
        )
        let body = RequestBody(
            audio: Audio(
                data: pcmData.base64EncodedString(),
                input: Input(
                    transcription: transcription,
                    format: AudioFormat(
                        type: "pcm",
                        codec: "pcm_s16le",
                        rate: 16_000,
                        bits: 16,
                        channel: 1
                    )
                )
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.batchAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func parseSSELine(_ line: String) throws -> StepFunBatchSSEEvent? {
        guard line.hasPrefix("data:") else { return nil }

        var payload = line.dropFirst(5)
        if payload.first == " " {
            payload = payload.dropFirst()
        }
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }

        guard let data = String(payload).data(using: .utf8),
              let message = try? JSONDecoder().decode(SSEMessage.self, from: data)
        else {
            throw StepFunBatchASRError.invalidResponse
        }

        switch message.type {
        case "transcript.text.delta":
            guard let delta = message.delta else {
                throw StepFunBatchASRError.invalidResponse
            }
            return .delta(delta)

        case "transcript.text.done":
            guard let text = message.text else {
                throw StepFunBatchASRError.invalidResponse
            }
            return .done(text)

        case "error":
            let detail = message.message ?? message.error?.message
            if let detail, !detail.isEmpty {
                return .error(detail)
            }
            return .error(L("阶跃星辰识别失败", "StepFun transcription failed"))

        default:
            return nil
        }
    }
}

private extension StepFunBatchASRProtocol {
    struct RequestBody: Encodable {
        let audio: Audio
    }

    struct Audio: Encodable {
        let data: String
        let input: Input
    }

    struct Input: Encodable {
        let transcription: Transcription
        let format: AudioFormat
    }

    struct Transcription: Encodable {
        let hotwords: [String]?
        let model: String
        let enableITN: Bool

        enum CodingKeys: String, CodingKey {
            case hotwords
            case model
            case enableITN = "enable_itn"
        }
    }

    struct AudioFormat: Encodable {
        let type: String
        let codec: String
        let rate: Int
        let bits: Int
        let channel: Int
    }

    struct SSEMessage: Decodable {
        let type: String
        let delta: String?
        let text: String?
        let message: String?
        let error: ErrorDetail?
    }

    struct ErrorDetail: Decodable {
        let message: String?
    }
}
