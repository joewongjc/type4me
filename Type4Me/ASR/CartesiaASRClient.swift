import Foundation
import os

/// Cartesia Ink-2 manual realtime STT. The app owns voice activity detection,
/// so recording completion sends Cartesia's required `finalize` command.
actor CartesiaASRClient: SpeechRecognizer {
    private let logger = Logger(subsystem: "com.type4me.asr", category: "CartesiaASRClient")
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var stream: AsyncStream<RecognitionEvent>?
    private var confirmedSegments: [String] = []

    var events: AsyncStream<RecognitionEvent> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.stream = stream
        eventContinuation = continuation
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let config = config as? CartesiaASRConfig else {
            throw CartesiaProtocolError.invalidEndpoint
        }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.stream = stream
        eventContinuation = continuation
        confirmedSegments = []

        let url = try CartesiaProtocol.buildWebSocketURL(config: config, options: options)
        var request = URLRequest(url: url)
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        let task = URLSession(configuration: options.urlSessionConfiguration).webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        startReceiveLoop()
        logger.info("Cartesia Ink-2 WebSocket started")
    }

    func sendAudio(_ data: Data) async throws {
        guard let webSocketTask else { return }
        try await webSocketTask.send(.data(data))
    }

    func endAudio() async throws {
        guard let webSocketTask else { return }
        try await webSocketTask.send(.string("finalize"))
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        stream = nil
        confirmedSegments = []
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    await self.handle(message)
                } catch {
                    if !Task.isCancelled {
                        await self.eventContinuation?.yield(.error(error))
                        await self.eventContinuation?.yield(.completed)
                    }
                    break
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        do {
            let data: Data
            switch message {
            case .data(let value): data = value
            case .string(let value): data = Data(value.utf8)
            @unknown default: return
            }
            guard let update = try CartesiaProtocol.makeTranscriptUpdate(from: data, confirmedSegments: confirmedSegments) else { return }
            confirmedSegments = update.confirmedSegments
            eventContinuation?.yield(.transcript(update.transcript))
            if update.transcript.isFinal { eventContinuation?.yield(.completed) }
        } catch {
            eventContinuation?.yield(.error(error))
        }
    }
}
