import Foundation

enum MiMoASRError: Error, LocalizedError, Equatable {
    case invalidConfig
    case emptyAudio
    case invalidEndpoint
    case audioTooLarge(encodedBytes: Int)
    case requestFailed(code: Int, message: String?)
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return L("小米 MiMo 识别配置无效", "Xiaomi MiMo ASR requires valid MiMoASRConfig")
        case .emptyAudio:
            return L("没有录到音频", "No audio data recorded")
        case .invalidEndpoint:
            return L("无效的 MiMo 端点", "Invalid MiMo ASR endpoint")
        case .audioTooLarge:
            return L(
                "录音过长，超过 MiMo 单次音频大小限制，请缩短后重试。",
                "The recording exceeds MiMo's per-request audio limit. Please record a shorter segment and try again."
            )
        case .requestFailed(let code, let message):
            if let message, !message.isEmpty {
                return "MiMo API HTTP \(code): \(message)"
            }
            return "MiMo API HTTP \(code)"
        case .invalidResponse:
            return L("小米 MiMo 返回了无法解析的识别结果", "Xiaomi MiMo returned an invalid transcription response")
        case .serverError(let message):
            return message
        }
    }
}

enum MiMoSSEEvent: Equatable {
    case delta(String)
    case done
    case error(String)
}

enum MiMoASRProtocol {

    static let maxEncodedAudioBytes = 10 * 1024 * 1024

    static func buildRequest(
        wavData: Data,
        config: MiMoASRConfig,
        options: ASRRequestOptions = ASRRequestOptions()
    ) throws -> URLRequest {
        guard let url = URL(string: MiMoASRConfig.endpoint) else {
            throw MiMoASRError.invalidEndpoint
        }

        let base64 = wavData.base64EncodedString()
        let dataURL = "data:audio/wav;base64,\(base64)"
        guard let dataURLBytes = dataURL.data(using: .utf8),
              dataURLBytes.count <= maxEncodedAudioBytes
        else {
            throw MiMoASRError.audioTooLarge(encodedBytes: dataURL.utf8.count)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120

        let body = RequestBody(
            model: MiMoASRConfig.defaultModel,
            messages: [
                Message(
                    role: "user",
                    content: [
                        MessageContent(
                            type: "input_audio",
                            inputAudio: InputAudio(data: dataURL)
                        )
                    ]
                )
            ],
            asrOptions: ASROptions(language: config.language.rawValue),
            stream: true
        )

        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func parseSSELine(_ line: String) throws -> MiMoSSEEvent? {
        guard line.hasPrefix("data:") else { return nil }

        var payload = line.dropFirst(5)
        if payload.first == " " {
            payload = payload.dropFirst()
        }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // [DONE] is SSE stream framing; terminal completion is strictly governed by finish_reason
        if trimmed == "[DONE]" {
            return nil
        }

        guard let data = trimmed.data(using: .utf8) else { return nil }

        // Check if server returned an error structure
        if let errObj = try? JSONDecoder().decode(ServerErrorResponse.self, from: data),
           let err = errObj.error {
            let message = err.message ?? L("MiMo 识别失败", "MiMo recognition failed")
            return .error(message)
        }

        guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
            throw MiMoASRError.invalidResponse
        }

        if let firstChoice = chunk.choices.first {
            if let finishReason = firstChoice.finishReason {
                switch finishReason {
                case "stop":
                    return .done
                case "length":
                    return .error(L("识别结果超出最大生成长度", "Recognition output exceeded maximum token length"))
                case "content_filter":
                    return .error(L("识别内容已被安全策略过滤", "Recognition content was filtered by safety policy"))
                default:
                    return .error(L("识别异常终止: \(finishReason)", "Recognition terminated abnormally: \(finishReason)"))
                }
            }

            if let content = firstChoice.delta.content, !content.isEmpty {
                return .delta(content)
            }
        }

        return nil
    }

    static func validateCredentials(
        config: MiMoASRConfig,
        options: ASRRequestOptions
    ) async throws {
        // Minimal 0.1s silence PCM (1600 samples of 16-bit mono = 3200 bytes)
        let silencePCM = Data(repeating: 0, count: 3200)
        let wavData = WAVEncoder.encode(pcmData: silencePCM)
        let request = try buildRequest(wavData: wavData, config: config, options: options)

        let session = URLSession(configuration: options.urlSessionConfiguration)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiMoASRError.requestFailed(code: 0, message: nil)
        }

        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 1024 { break }
            }
            let message = extractErrorMessage(from: body)
            throw MiMoASRError.requestFailed(code: http.statusCode, message: message)
        }
    }

    static func extractErrorMessage(from data: Data) -> String? {
        if let errObj = try? JSONDecoder().decode(ServerErrorResponse.self, from: data),
           let message = errObj.error?.message, !message.isEmpty {
            return message
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return nil
    }
}

// MARK: - Internal Models

private extension MiMoASRProtocol {
    struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let asrOptions: ASROptions
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case asrOptions = "asr_options"
            case stream
        }
    }

    struct Message: Encodable {
        let role: String
        let content: [MessageContent]
    }

    struct MessageContent: Encodable {
        let type: String
        let inputAudio: InputAudio

        enum CodingKeys: String, CodingKey {
            case type
            case inputAudio = "input_audio"
        }
    }

    struct InputAudio: Encodable {
        let data: String
    }

    struct ASROptions: Encodable {
        let language: String
    }

    struct StreamChunk: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let delta: Delta
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }

        struct Delta: Decodable {
            let content: String?
        }
    }

    struct ServerErrorResponse: Decodable {
        let error: ErrorDetail?

        struct ErrorDetail: Decodable {
            let message: String?
            let type: String?
            let code: String?
        }
    }
}
