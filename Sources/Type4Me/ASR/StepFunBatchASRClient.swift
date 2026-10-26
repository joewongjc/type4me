import Foundation
import os

/// StepFun batch ASR using a complete PCM upload and an SSE text response.
/// Audio is buffered during recording and submitted when endAudio() is called.
actor StepFunBatchASRClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "StepFunBatchASRClient")

    private var config: StepFunASRConfig?
    private var options = ASRRequestOptions()
    private var session: URLSession?
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
        guard let stepFunConfig = config as? StepFunASRConfig else {
            throw StepFunBatchASRError.invalidConfig
        }

        self.config = stepFunConfig
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
                throw StepFunBatchASRError.invalidConfig
            }
            guard !audioBuffer.isEmpty else {
                throw StepFunBatchASRError.emptyAudio
            }

            let request = try StepFunBatchASRProtocol.buildRequest(
                pcmData: audioBuffer,
                config: config,
                options: options
            )
            logger.info(
                "Sending \(self.audioBuffer.count) bytes PCM to StepFun batch ASR via \(config.accessMode.rawValue, privacy: .public)"
            )

            try await transcribe(request: request, session: session)
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

    private func transcribe(request: URLRequest, session: URLSession) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StepFunBatchASRError.requestFailed(code: 0, message: nil)
        }

        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 500 { break }
            }
            let message = String(data: body, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw StepFunBatchASRError.requestFailed(code: http.statusCode, message: message)
        }

        var accumulatedText = ""
        var didReceiveDone = false

        for try await line in bytes.lines {
            guard let event = try StepFunBatchASRProtocol.parseSSELine(line) else {
                continue
            }

            switch event {
            case .delta(let delta):
                accumulatedText += delta
                eventContinuation?.yield(.transcript(RecognitionTranscript(
                    confirmedSegments: [],
                    partialText: accumulatedText,
                    authoritativeText: accumulatedText,
                    isFinal: false
                )))

            case .done(let text):
                let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                eventContinuation?.yield(.transcript(RecognitionTranscript(
                    confirmedSegments: finalText.isEmpty ? [] : [finalText],
                    partialText: "",
                    authoritativeText: finalText,
                    isFinal: true
                )))
                didReceiveDone = true

            case .error(let message):
                throw StepFunBatchASRError.serverError(message)
            }

            if didReceiveDone { break }
        }

        guard didReceiveDone else {
            throw StepFunBatchASRError.invalidResponse
        }
        logger.info("StepFun batch ASR completed")
    }
}
