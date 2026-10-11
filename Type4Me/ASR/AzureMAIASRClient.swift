import Foundation
import os

/// MAI-Transcribe-2-Streaming over the Microsoft Foundry Realtime API. The service has no
/// turn detection, so the client commits once when recording ends and finishes on `completed`.
actor AzureMAIASRClient: SpeechRecognizer {
    /// Commits with less audio than this (0.1s) are skipped; the session gets what is already shown.
    private static let minimumCommitBytes = AzureMAIProtocol.sampleRate * 2 / 10

    private let logger = Logger(subsystem: "com.type4me.asr", category: "AzureMAIASRClient")
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var stream: AsyncStream<RecognitionEvent>?
    private var confirmedText = ""
    private var intermediateText = ""
    private var sentAudioBytes = 0
    private var awaitingCompletion = false

    var events: AsyncStream<RecognitionEvent> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.stream = stream
        eventContinuation = continuation
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let config = config as? AzureASRConfig else {
            throw AzureMAIProtocolError.invalidConfig
        }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.stream = stream
        eventContinuation = continuation
        confirmedText = ""
        intermediateText = ""
        sentAudioBytes = 0
        awaitingCompletion = false

        let request = try AzureMAIProtocol.makeRequest(config: config)
        let session = URLSession(configuration: options.urlSessionConfiguration)
        let task = session.webSocketTask(with: request)
        self.session = session
        webSocketTask = task
        task.resume()
        do {
            try await task.send(.string(AzureMAIProtocol.sessionUpdateMessage(config: config)))
        } catch {
            throw Self.connectionError(error, task: task)
        }
        startReceiveLoop()
        logger.info("Azure MAI realtime WebSocket started")
    }

    func sendAudio(_ data: Data) async throws {
        guard let webSocketTask, !data.isEmpty else { return }
        try await webSocketTask.send(.string(AzureMAIProtocol.appendMessage(pcmData: data)))
        sentAudioBytes += data.count
    }

    func endAudio() async throws {
        guard let webSocketTask else { return }
        guard sentAudioBytes >= Self.minimumCommitBytes else {
            finish(with: confirmedText + intermediateText)
            return
        }
        awaitingCompletion = true
        try await webSocketTask.send(.string(AzureMAIProtocol.commitMessage))
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
        stream = nil
        confirmedText = ""
        intermediateText = ""
        sentAudioBytes = 0
        awaitingCompletion = false
    }

    // MARK: - Receiving

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = await self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    await self.handle(message)
                } catch {
                    if !Task.isCancelled {
                        await self.fail(Self.connectionError(error, task: task))
                    }
                    break
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }

        let event: AzureMAIRealtimeEvent
        do {
            event = try AzureMAIProtocol.parseEvent(data)
        } catch {
            fail(error)
            return
        }

        switch event {
        case .delta(let text):
            confirmedText += text
            intermediateText = ""
            emitTranscript(isFinal: false)
        case .intermediate(let text):
            intermediateText = text
            emitTranscript(isFinal: false)
        case .completed(let transcript):
            guard awaitingCompletion else { return }
            finish(with: transcript.isEmpty ? confirmedText : transcript)
        case .sessionCreated, .sessionUpdated, .committed, .ignored:
            break
        }
    }

    private func emitTranscript(isFinal: Bool) {
        let transcript = RecognitionTranscript(
            confirmedSegments: confirmedText.isEmpty ? [] : [confirmedText],
            partialText: intermediateText,
            authoritativeText: confirmedText + intermediateText,
            isFinal: isFinal
        )
        eventContinuation?.yield(.transcript(transcript))
    }

    private func finish(with text: String) {
        awaitingCompletion = false
        confirmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        intermediateText = ""
        emitTranscript(isFinal: true)
        eventContinuation?.yield(.completed)
        eventContinuation?.finish()
    }

    private func fail(_ error: Error) {
        logger.error("Azure MAI realtime error: \(error.localizedDescription, privacy: .public)")
        eventContinuation?.yield(.error(error))
        if awaitingCompletion {
            awaitingCompletion = false
            eventContinuation?.yield(.completed)
        }
    }

    /// Replaces the generic socket error of a rejected handshake with its HTTP status.
    private static func connectionError(_ error: Error, task: URLSessionWebSocketTask) -> Error {
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            return AzureMAIProtocolError.handshakeFailed(statusCode: http.statusCode)
        }
        return error
    }

    // MARK: - Credential test

    /// Opens a session and waits for the service to accept the configuration, which checks
    /// the key, the resource, and the deployment name without sending audio.
    static func validateCredentials(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        guard let config = config as? AzureASRConfig else {
            throw AzureMAIProtocolError.invalidConfig
        }
        let session = URLSession(configuration: options.urlSessionConfiguration)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: try AzureMAIProtocol.makeRequest(config: config))
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await task.send(.string(AzureMAIProtocol.sessionUpdateMessage(config: config)))
                } catch {
                    throw connectionError(error, task: task)
                }
                while true {
                    let message: URLSessionWebSocketTask.Message
                    do {
                        message = try await task.receive()
                    } catch {
                        throw connectionError(error, task: task)
                    }
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    if try AzureMAIProtocol.parseEvent(data) == .sessionUpdated { return }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw AzureMAIProtocolError.validationTimedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
