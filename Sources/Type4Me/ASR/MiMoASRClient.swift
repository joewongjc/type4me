import Foundation
import os

/// Xiaomi MiMo-V2.5-ASR batch client using a complete WAV upload and an SSE text response.
/// Audio is buffered as PCM during recording and submitted when endAudio() is called.
actor MiMoASRClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "MiMoASRClient")

    private var config: MiMoASRConfig?
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
        guard let mimoConfig = config as? MiMoASRConfig else {
            throw MiMoASRError.invalidConfig
        }

        self.config = mimoConfig
        self.options = options
        session = URLSession(configuration: options.urlSessionConfiguration)
        audioBuffer = Data()

        if eventContinuation == nil {
            let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
            eventContinuation = continuation
            _events = stream
        }

        eventContinuation?.yield(.ready)
        eventContinuation?.yield(.transcript(RecognitionTranscript(
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
                throw MiMoASRError.invalidConfig
            }
            guard !audioBuffer.isEmpty else {
                throw MiMoASRError.emptyAudio
            }

            let wavData = WAVEncoder.encode(pcmData: audioBuffer)
            logger.info("Sending \(self.audioBuffer.count) bytes PCM (\(wavData.count) bytes WAV) to MiMo ASR")

            let request = try MiMoASRProtocol.buildRequest(
                wavData: wavData,
                config: config,
                options: options
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
            throw MiMoASRError.requestFailed(code: 0, message: nil)
        }

        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 1024 { break }
            }
            let message = MiMoASRProtocol.extractErrorMessage(from: body)
            throw MiMoASRError.requestFailed(code: http.statusCode, message: message)
        }

        var accumulatedText = ""
        var didReceiveDone = false

        for try await line in bytes.lines {
            guard let event = try MiMoASRProtocol.parseSSELine(line) else {
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

            case .done:
                didReceiveDone = true

            case .error(let message):
                throw MiMoASRError.serverError(message)
            }

            if didReceiveDone { break }
        }

        let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard didReceiveDone, !finalText.isEmpty else {
            throw MiMoASRError.invalidResponse
        }

        eventContinuation?.yield(.transcript(RecognitionTranscript(
            confirmedSegments: [finalText],
            partialText: "",
            authoritativeText: finalText,
            isFinal: true
        )))

        logger.info("MiMo ASR completed: \(accumulatedText.count) chars")
    }
}
