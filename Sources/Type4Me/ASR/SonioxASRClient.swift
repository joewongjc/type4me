import Foundation
import os

enum SonioxASRError: Error, LocalizedError, Equatable {
    case unsupportedProvider
    case serverRejected(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return L("Soniox 识别配置无效", "SonioxASRClient requires SonioxASRConfig")
        case .serverRejected(let code, let message):
            return L("Soniox 请求失败（\(code)）：\(message)", "Soniox request failed (\(code)): \(message)")
        }
    }
}

actor SonioxASRClient: SpeechRecognizer {

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "SonioxASRClient"
    )

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveGeneration = 0
    private var session: URLSession?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var accumulator = SonioxTranscriptAccumulator()
    private var lastTranscript: RecognitionTranscript = .empty
    private var audioPacketCount = 0
    private var totalAudioBytes = 0
    private var didRequestEnd = false
    private var sessionStartTime: ContinuousClock.Instant?
    private var lastTranscriptTime: ContinuousClock.Instant?

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events {
            return existing
        }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let sonioxConfig = config as? SonioxASRConfig else {
            throw SonioxASRError.unsupportedProvider
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        let url = try SonioxProtocol.buildWebSocketURL(override: options.cloudProxyURL)
        let message = try SonioxProtocol.buildStartMessage(
            config: sonioxConfig,
            options: options
        )
        let session = URLSession(configuration: options.urlSessionConfiguration)
        let task = session.webSocketTask(with: url)
        task.resume()
        NSLog("[Soniox] Sending start message")
        do {
            try await task.send(.string(message))
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw error
        }

        self.session = session
        webSocketTask = task
        accumulator = SonioxTranscriptAccumulator()
        lastTranscript = .empty
        audioPacketCount = 0
        totalAudioBytes = 0
        didRequestEnd = false
        sessionStartTime = ContinuousClock.now
        lastTranscriptTime = nil
        startReceiveLoop()
        NSLog("[Soniox] Start message sent OK")
    }

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        try await task.send(.data(data))
        audioPacketCount += 1
        totalAudioBytes += data.count
    }

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        didRequestEnd = true
        try await task.send(.string(""))
        NSLog("[Soniox] Sent end-of-stream (sent %d packets, %d bytes)", audioPacketCount, totalAudioBytes)
    }

    func disconnect() async {
        receiveGeneration &+= 1
        let socket = webSocketTask
        webSocketTask = nil
        socket?.cancel()
        session?.invalidateAndCancel()
        session = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        NSLog("[Soniox] Disconnected")
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveGeneration &+= 1
        guard let task = webSocketTask else { return }
        scheduleReceive(on: task, generation: receiveGeneration)
    }

    private func scheduleReceive(on task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            Task { await self.handleReceiveResult(result, task: task, generation: generation) }
        }
    }

    private func handleReceiveResult(
        _ result: Result<URLSessionWebSocketTask.Message, Error>,
        task: URLSessionWebSocketTask,
        generation: Int
    ) {
        guard generation == receiveGeneration, task === webSocketTask else { return }

        switch result {
        case .success(let message):
            switch handleMessage(message) {
            case .none:
                scheduleReceive(on: task, generation: generation)
            case .finished:
                emitEvent(.completed)
                finishReceiveLoop()
            case .fatal(let error):
                emitEvent(.error(error))
                emitEvent(.completed)
                finishReceiveLoop()
            }
        case .failure(let error):
            if didRequestEnd {
                NSLog("[Soniox] Treating socket close as normal end (sent %d packets)", audioPacketCount)
            } else if audioPacketCount == 0 {
                NSLog("[Soniox] Receive error before audio: %@", String(describing: error))
                emitEvent(.error(error))
            } else {
                NSLog("[Soniox] Unexpected close during audio (sent %d packets): %@", audioPacketCount, String(describing: error))
                emitEvent(.error(error))
            }
            emitEvent(.completed)
            finishReceiveLoop()
        }
    }

    private func finishReceiveLoop() {
        NSLog("[Soniox] Receive loop ended")
        eventContinuation?.finish()
    }

    private enum MessageAction {
        case none
        case finished
        case fatal(Error)
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) -> MessageAction {
        do {
            let data: Data
            switch message {
            case .data(let payload):
                data = payload
            case .string(let text):
                data = Data(text.utf8)
            @unknown default:
                return .none
            }

            let result = try SonioxProtocol.parseServerMessage(from: data)

            if let error = result.error {
                return .fatal(
                    SonioxASRError.serverRejected(
                        code: error.code,
                        message: error.message
                    )
                )
            }

            if let update = result.transcript {
                applyTranscriptUpdate(update)
            }

            if result.isFinished {
                NSLog("[Soniox] Session finished by server after %d packets", audioPacketCount)
                return .finished
            }

            return .none
        } catch {
            return .fatal(error)
        }
    }

    private func applyTranscriptUpdate(_ update: SonioxTranscriptUpdate) {
        accumulator.apply(update)
        let transcript = accumulator.transcript
        guard transcript != lastTranscript else { return }
        lastTranscript = transcript

        let now = ContinuousClock.now
        let sinceStart = sessionStartTime.map { now - $0 } ?? .zero
        let sinceLastUpdate = lastTranscriptTime.map { now - $0 } ?? .zero
        lastTranscriptTime = now

        let gapMs = Int(sinceLastUpdate.components.seconds * 1000
            + sinceLastUpdate.components.attoseconds / 1_000_000_000_000_000)

        DebugFileLogger.log("Soniox transcript +\(sinceStart) gap=\(gapMs)ms confirmed=\(transcript.confirmedSegments.count) partial=\(transcript.partialText.count) final=\(transcript.isFinal)")
        NSLog(
            "[Soniox] Transcript +%@ gap=%dms confirmed=%d partial=%d final=%@",
            String(describing: sinceStart),
            gapMs,
            transcript.confirmedSegments.count,
            transcript.partialText.count,
            transcript.isFinal ? "yes" : "no"
        )

        emitEvent(.transcript(transcript))

        if transcript.isFinal, !transcript.authoritativeText.isEmpty {
            NSLog("[Soniox] Final transcript received (%d chars)", transcript.authoritativeText.count)
        }
    }
}

struct SonioxTranscriptAccumulator: Sendable {

    private var confirmedText = ""
    private var partialText = ""

    mutating func apply(_ update: SonioxTranscriptUpdate) {
        if !update.finalizedText.isEmpty {
            confirmedText += update.finalizedText
        }
        partialText = update.partialText
    }

    var transcript: RecognitionTranscript {
        let authoritativeText = confirmedText + partialText
        return RecognitionTranscript(
            confirmedSegments: confirmedText.isEmpty ? [] : [confirmedText],
            partialText: partialText,
            authoritativeText: authoritativeText,
            isFinal: partialText.isEmpty
        )
    }
}

private extension SonioxASRClient {
    func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }
}
