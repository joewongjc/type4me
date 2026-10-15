import Foundation
import os

enum BatchASRError: Error, LocalizedError, Equatable {
    case invalidConfig(provider: String)
    case recordingTooLong(provider: String, maxSeconds: Int)
    case requestFailed(provider: String, code: Int, message: String?)
    case invalidResponse(provider: String)
    case blocked(provider: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let provider):
            return L("\(provider) 非实时识别配置无效", "Invalid \(provider) batch recognition configuration")
        case .recordingTooLong(let provider, let maxSeconds):
            let minutes = max(1, maxSeconds / 60)
            return L(
                "录音超过 \(provider) 非实时识别的 \(minutes) 分钟上限，请切换为实时流式",
                "The recording exceeds the \(minutes)-minute limit of \(provider) batch recognition. Switch to real-time mode."
            )
        case .requestFailed(let provider, let code, let message):
            if let message, !message.isEmpty {
                return L("\(provider) 返回 HTTP \(code)：\(message)", "\(provider) returned HTTP \(code): \(message)")
            }
            return L("\(provider) 返回 HTTP \(code)", "\(provider) returned HTTP \(code)")
        case .invalidResponse(let provider):
            return L("无法解析 \(provider) 的识别结果", "Failed to parse the \(provider) transcription response")
        case .blocked(let provider, let reason):
            return L("\(provider) 未返回识别结果（\(reason)）", "\(provider) returned no transcript (\(reason))")
        }
    }
}

/// Provider-specific half of a synchronous batch request: build the upload and read the transcript.
protocol BatchASRTranscriber: Sendable {
    var providerName: String { get }
    /// Longest recording accepted in one request, or nil when the provider limit is far above dictation use.
    var maxDuration: TimeInterval? { get }
    func makeRequest(pcmData: Data, config: any ASRProviderConfig, options: ASRRequestOptions) throws -> URLRequest
    func parseTranscript(from data: Data, options: ASRRequestOptions) throws -> String
    /// Config-aware parsing for transcribers whose response shape is user-configured.
    func parseTranscript(from data: Data, config: any ASRProviderConfig, options: ASRRequestOptions) throws -> String
    /// True when a non-200 response only means "no speech found" and should yield an empty transcript.
    func isNoSpeechResponse(statusCode: Int, data: Data) -> Bool
}

extension BatchASRTranscriber {
    func parseTranscript(from data: Data, config: any ASRProviderConfig, options: ASRRequestOptions) throws -> String {
        try parseTranscript(from: data, options: options)
    }

    func isNoSpeechResponse(statusCode: Int, data: Data) -> Bool { false }
}

enum BatchASRHTTP {
    static let bytesPerSecond = 16_000 * 2
    /// Per-request timeout for batch uploads. The session waits slightly longer for endAudio()
    /// so the HTTP layer reports its own error first.
    static let requestTimeout: TimeInterval = 120

    static func transcribe(
        pcmData: Data,
        with transcriber: any BatchASRTranscriber,
        config: any ASRProviderConfig,
        options: ASRRequestOptions,
        session: URLSession
    ) async throws -> String {
        if let maxDuration = transcriber.maxDuration,
           Double(pcmData.count) / Double(bytesPerSecond) > maxDuration {
            throw BatchASRError.recordingTooLong(
                provider: transcriber.providerName,
                maxSeconds: Int(maxDuration)
            )
        }

        let request = try transcriber.makeRequest(pcmData: pcmData, config: config, options: options)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BatchASRError.requestFailed(provider: transcriber.providerName, code: 0, message: nil)
        }
        guard http.statusCode == 200 else {
            if transcriber.isNoSpeechResponse(statusCode: http.statusCode, data: data) {
                return ""
            }
            throw BatchASRError.requestFailed(
                provider: transcriber.providerName,
                code: http.statusCode,
                message: errorMessage(from: data)
            )
        }
        return try transcriber.parseTranscript(from: data, config: config, options: options)
    }

    /// Credential test: transcribe one second of silence through the real endpoint.
    static func validate(
        with transcriber: any BatchASRTranscriber,
        config: any ASRProviderConfig,
        options: ASRRequestOptions
    ) async throws {
        let session = URLSession(configuration: options.urlSessionConfiguration)
        defer { session.finishTasksAndInvalidate() }
        _ = try await transcribe(
            pcmData: Data(count: bytesPerSecond),
            with: transcriber,
            config: config,
            options: options,
            session: session
        )
    }

    /// Pulls a human-readable message out of the common JSON error shapes.
    static func errorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let detail = json["detail"] as? [String: Any], let message = detail["message"] as? String {
                return message
            }
            if let details = json["detail"] as? [[String: Any]],
               let message = details.compactMap({ $0["msg"] as? String }).first {
                return message
            }
            for key in ["message", "error", "detail"] {
                if let message = json[key] as? String, !message.isEmpty {
                    return message
                }
            }
        }
        let raw = String(data: data.prefix(300), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }
}

/// Buffers the recording and submits it in one request when the hotkey is released.
actor BufferedBatchASRClient: SpeechRecognizer {

    /// Below this length (0.3s) no request is sent; the session gets an empty result.
    private static let minimumAudioBytes = Int(0.3 * Double(BatchASRHTTP.bytesPerSecond))

    private let transcriber: any BatchASRTranscriber
    private let logger = Logger(subsystem: "com.type4me.asr", category: "BufferedBatchASRClient")

    private var config: (any ASRProviderConfig)?
    private var options = ASRRequestOptions()
    private var session: URLSession?
    private var audioBuffer = Data()
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    init(transcriber: any BatchASRTranscriber) {
        self.transcriber = transcriber
    }

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        self.config = config
        self.options = options
        session = URLSession(configuration: options.urlSessionConfiguration)
        audioBuffer = Data()

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        continuation.yield(.ready)
        continuation.yield(.transcript(RecognitionTranscript(
            confirmedSegments: [],
            partialText: ASRRecognitionMode.batchRecordingPlaceholder,
            authoritativeText: "",
            isFinal: false
        )))
    }

    func sendAudio(_ data: Data) async throws {
        audioBuffer.append(data)
    }

    func endAudio() async throws {
        do {
            guard let config, let session else {
                throw BatchASRError.invalidConfig(provider: transcriber.providerName)
            }

            var text = ""
            if audioBuffer.count >= Self.minimumAudioBytes {
                logger.info(
                    "Sending \(self.audioBuffer.count) bytes PCM to \(self.transcriber.providerName, privacy: .public) batch ASR"
                )
                text = try await BatchASRHTTP.transcribe(
                    pcmData: audioBuffer,
                    with: transcriber,
                    config: config,
                    options: options,
                    session: session
                )
            }

            eventContinuation?.yield(.transcript(RecognitionTranscript(
                confirmedSegments: text.isEmpty ? [] : [text],
                partialText: "",
                authoritativeText: text,
                isFinal: true
            )))
            eventContinuation?.yield(.completed)
            eventContinuation?.finish()
        } catch {
            eventContinuation?.yield(.error(error))
            eventContinuation?.yield(.completed)
            eventContinuation?.finish()
            throw error
        }
    }

    func disconnect() async {
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        audioBuffer = Data()
        session?.invalidateAndCancel()
        session = nil
        config = nil
    }
}

// MARK: - Multipart form data

struct MultipartFormBody {
    let boundary = "Type4Me-\(UUID().uuidString)"
    private(set) var data = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func append(name: String, value: String) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        data.append(Data("\(value)\r\n".utf8))
    }

    mutating func append(name: String, filename: String, mimeType: String, fileData: Data) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        data.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
    }

    func finalized() -> Data {
        data + Data("--\(boundary)--\r\n".utf8)
    }
}
