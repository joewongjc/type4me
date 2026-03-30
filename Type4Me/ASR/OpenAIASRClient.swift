import Foundation
import os

enum OpenAIASRError: Error, LocalizedError {
    case invalidConfig
    case emptyAudio
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfig:     return "OpenAI ASR requires OpenAIASRConfig"
        case .emptyAudio:        return "No audio data recorded"
        case .requestFailed(let code): return "OpenAI API returned HTTP \(code)"
        case .invalidResponse:   return "Failed to parse OpenAI transcription response"
        }
    }
}

/// Non-streaming ASR using OpenAI's /audio/transcriptions REST endpoint.
/// Accumulates audio during recording, then transcribes in one shot on endAudio().
actor OpenAIASRClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "OpenAIASRClient")

    private var config: OpenAIASRConfig?
    private var audioBuffer = Data()
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        guard let openAIConfig = config as? OpenAIASRConfig else {
            throw OpenAIASRError.invalidConfig
        }
        self.config = openAIConfig
        audioBuffer = Data()

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        continuation.yield(.ready)

        // Non-streaming: show "录音中" as placeholder during recording
        let placeholder = RecognitionTranscript(
            confirmedSegments: [],
            partialText: L("录音中…", "Recording…"),
            authoritativeText: "",
            isFinal: false
        )
        continuation.yield(.transcript(placeholder))
    }

    func sendAudio(_ data: Data) async throws {
        audioBuffer.append(data)
    }

    func endAudio() async throws {
        guard let config else { return }
        guard !audioBuffer.isEmpty else {
            eventContinuation?.yield(.error(OpenAIASRError.emptyAudio))
            eventContinuation?.yield(.completed)
            eventContinuation?.finish()
            return
        }

        let wavData = Self.wavFromPCM(audioBuffer)
        logger.info("Sending \(wavData.count) bytes WAV to OpenAI transcription")

        let text = try await transcribe(wavData: wavData, config: config)

        if !text.isEmpty {
            let transcript = RecognitionTranscript(
                confirmedSegments: [text],
                partialText: "",
                authoritativeText: text,
                isFinal: true
            )
            eventContinuation?.yield(.transcript(transcript))
        }

        eventContinuation?.yield(.completed)
        eventContinuation?.finish()
    }

    func disconnect() {
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        audioBuffer = Data()
        config = nil
    }

    // MARK: - Transcription API

    private func transcribe(wavData: Data, config: OpenAIASRConfig) async throws -> String {
        guard let url = URL(string: "\(config.baseURL)/audio/transcriptions") else {
            throw OpenAIASRError.invalidConfig
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        // Build multipart form data
        var body = Data()
        body.appendMultipart(boundary: boundary, name: "file", filename: "audio.wav", mimeType: "audio/wav", data: wavData)
        body.appendMultipart(boundary: boundary, name: "model", value: config.model)
        body.appendMultipart(boundary: boundary, name: "response_format", value: "json")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIASRError.requestFailed(0)
        }

        guard http.statusCode == 200 else {
            if let raw = String(data: data.prefix(500), encoding: .utf8) {
                logger.error("OpenAI ASR HTTP \(http.statusCode): \(raw)")
            }
            throw OpenAIASRError.requestFailed(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else {
            if let raw = String(data: data.prefix(500), encoding: .utf8) {
                logger.error("OpenAI ASR unexpected response: \(raw)")
            }
            throw OpenAIASRError.invalidResponse
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("OpenAI ASR result: \(trimmed.count) chars")
        return trimmed
    }

    // MARK: - WAV Encoding

    private static func wavFromPCM(_ pcmData: Data) -> Data {
        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize

        var wav = Data(capacity: 44 + pcmData.count)

        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // "RIFF"
        appendUInt32(&wav, fileSize)
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // "WAVE"

        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // "fmt "
        appendUInt32(&wav, 16)
        appendUInt16(&wav, 1)        // PCM format
        appendUInt16(&wav, 1)        // mono
        appendUInt32(&wav, 16000)    // sample rate
        appendUInt32(&wav, 32000)    // byte rate
        appendUInt16(&wav, 2)        // block align
        appendUInt16(&wav, 16)       // bits per sample

        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // "data"
        appendUInt32(&wav, dataSize)
        wav.append(pcmData)

        return wav
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 2))
    }
}

// MARK: - Multipart Helpers

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
