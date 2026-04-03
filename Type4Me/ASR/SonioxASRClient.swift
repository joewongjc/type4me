import Foundation
import os

enum SonioxASRError: Error, LocalizedError, Equatable {
    case unsupportedProvider
    case serverRejected(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "SonioxASRClient requires SonioxASRConfig"
        case .serverRejected(let code, let message):
            return "Soniox request failed (\(code)): \(message)"
        }
    }
}

actor SonioxASRClient: SpeechRecognizer {

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "SonioxASRClient"
    )

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var session: URLSession?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var accumulator = SonioxTranscriptAccumulator()
    private var lastTranscript: RecognitionTranscript = .empty
    private var audioPacketCount = 0
    private var totalAudioBytes = 0
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

        let url = try SonioxProtocol.buildWebSocketURL()
        let session = URLSession(configuration: options.urlSessionConfiguration)
        let task = session.webSocketTask(with: url)
        task.resume()

        self.session = session
        webSocketTask = task
        accumulator = SonioxTranscriptAccumulator()
        lastTranscript = .empty
        audioPacketCount = 0
        totalAudioBytes = 0
        sessionStartTime = ContinuousClock.now
        lastTranscriptTime = nil

        startReceiveLoop()

        let message = try SonioxProtocol.buildStartMessage(
            config: sonioxConfig,
            options: options
        )
        NSLog("[Soniox] Sending start message")
        try await task.send(.string(message))
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
        try await task.send(.string(""))
        NSLog("[Soniox] Sent end-of-stream (sent %d packets, %d bytes)", audioPacketCount, totalAudioBytes)
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        NSLog("[Soniox] Disconnected")
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    let action = await self.handleMessage(message)
                    switch action {
                    case .none:
                        break
                    case .finished:
                        await self.emitEvent(.completed)
                        return
                    case .fatal(let error):
                        await self.emitEvent(.error(error))
                        await self.emitEvent(.completed)
                        return
                    }
                } catch {
                    if Task.isCancelled { break }

                    if await self.audioPacketCount == 0 {
                        NSLog("[Soniox] Receive error before audio: %@", String(describing: error))
                        await self.emitEvent(.error(error))
                    } else {
                        NSLog("[Soniox] Treating socket close as normal end (sent %d packets)", await self.audioPacketCount)
                    }
                    await self.emitEvent(.completed)
                    break
                }
            }
            NSLog("[Soniox] Receive loop ended")
            await self.eventContinuation?.finish()
        }
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
