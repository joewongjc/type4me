import Foundation
import os

actor MetaMuseASRClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "MetaMuseASRClient")

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var session: URLSession?
    private var sessionDelegate: MetaMuseWebSocketDelegate?
    private var connectionGate: MetaMuseConnectionGate?
    private var closeTracker: MetaMuseCloseTracker?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var confirmedSegments: [String] = []
    private var currentPartial: String = ""
    private var lastTranscript: RecognitionTranscript = .empty
    private var didEndAudio = false
    private var didEmitFinal = false
    private var audioPacketCount = 0
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
        guard let museConfig = config as? MetaMuseASRConfig else {
            throw MetaMuseASRError.invalidConfig
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        let url = try MetaMuseASRProtocol.buildWebSocketURL(override: options.cloudProxyURL)
        logger.info("Connecting Meta Muse WebSocket: \(url.host ?? "", privacy: .public)")

        let gate = MetaMuseConnectionGate()
        let tracker = MetaMuseCloseTracker()
        let delegate = MetaMuseWebSocketDelegate(gate: gate, closeTracker: tracker)
        let session = URLSession(configuration: options.urlSessionConfiguration, delegate: delegate, delegateQueue: nil)
        let request = URLRequest(url: url)
        let task = session.webSocketTask(with: request)
        task.resume()

        self.connectionGate = gate
        self.closeTracker = tracker
        self.sessionDelegate = delegate
        self.session = session
        self.webSocketTask = task
        self.confirmedSegments = []
        self.currentPartial = ""
        self.lastTranscript = .empty
        self.didEndAudio = false
        self.didEmitFinal = false
        self.audioPacketCount = 0

        // 1. Wait for WebSocket upgrade
        try await gate.waitUntilOpen(timeout: .seconds(5))

        // 2. Start receive loop immediately so handshake ack / error frames can be processed
        startReceiveLoop()

        // 3. Send handshake message
        let handshakeMessage = try MetaMuseASRProtocol.buildHandshakeMessage(config: museConfig, options: options)
        try await task.send(.string(handshakeMessage))

        // 4. Wait for server session-ready acknowledgment
        try await gate.waitUntilReady(timeout: .seconds(5))
        logger.info("Meta Muse WebSocket ready")
        emitEvent(.ready)
    }

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask, !data.isEmpty else { return }
        let chunkSize = 6400
        if data.count <= chunkSize {
            try await task.send(.data(data))
            audioPacketCount += 1
        } else {
            var offset = 0
            var chunksSent = 0
            while offset < data.count {
                let length = min(chunkSize, data.count - offset)
                let chunk = data.subdata(in: offset..<(offset + length))
                try await task.send(.data(chunk))
                audioPacketCount += 1
                offset += length
                chunksSent += 1
                if chunksSent % 5 == 0 {
                    await Task.yield()
                }
            }
        }
    }

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        didEndAudio = true
        let endStream = MetaMuseASRProtocol.buildEndStreamMessage()
        try await task.send(.string(endStream))
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
        connectionGate = nil
        closeTracker = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        confirmedSegments = []
        currentPartial = ""
        lastTranscript = .empty
        didEndAudio = false
        didEmitFinal = false
        audioPacketCount = 0
        logger.info("Meta Muse disconnected")
    }

    private func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }

    private func handleServerMessage(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case .data(let d):
            data = d
        case .string(let s):
            guard let d = s.data(using: .utf8) else {
                logger.error("Meta Muse invalid UTF-8 string in message")
                return
            }
            data = d
        @unknown default:
            return
        }

        do {
            let event = try MetaMuseASRProtocol.parseServerEvent(from: data)
            switch event {
            case .sessionReady(let sessionId):
                logger.info("Meta Muse session ready: \(sessionId, privacy: .private(mask: .hash))")
                await connectionGate?.markReady(sessionId: sessionId)

            case .transcript(let text, let isFinal, _):
                handleTranscriptUpdate(text: text, isFinal: isFinal)

            case .error(let error):
                logger.error("Meta Muse server error: \(error.localizedDescription, privacy: .public)")
                await connectionGate?.markFailure(error)
                emitEvent(.error(error))
                emitEvent(.completed)

            case .ignored(let type):
                logger.debug("Meta Muse ignored event type: \(type, privacy: .public)")
            }
        } catch {
            logger.error("Meta Muse failed to parse server event: \(error.localizedDescription, privacy: .public)")
            emitEvent(.error(error))
        }
    }

    private func handleTranscriptUpdate(text: String, isFinal: Bool) {
        if isFinal {
            if !text.isEmpty {
                if confirmedSegments.last != text {
                    confirmedSegments.append(text)
                }
            }
            currentPartial = ""
            let transcript = RecognitionTranscript(
                confirmedSegments: confirmedSegments,
                partialText: "",
                authoritativeText: confirmedSegments.joined(),
                isFinal: true
            )
            lastTranscript = transcript
            emitEvent(.transcript(transcript))

            if didEndAudio {
                didEmitFinal = true
                emitEvent(.completed)
                eventContinuation?.finish()
            }
        } else {
            guard !text.isEmpty || !currentPartial.isEmpty else { return }
            currentPartial = text
            let transcript = RecognitionTranscript(
                confirmedSegments: confirmedSegments,
                partialText: currentPartial,
                authoritativeText: (confirmedSegments + (currentPartial.isEmpty ? [] : [currentPartial])).joined(),
                isFinal: false
            )
            if transcript != lastTranscript {
                lastTranscript = transcript
                emitEvent(.transcript(transcript))
            }
        }
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    await self.handleServerMessage(message)
                } catch {
                    if Task.isCancelled {
                        break
                    }
                    logger.info("Meta Muse receive loop ended: \(String(describing: error), privacy: .public)")
                    let didEndAudio = await self.didEndAudio
                    let didEmitFinal = await self.didEmitFinal
                    let audioPacketCount = await self.audioPacketCount
                    let gateReady = await self.connectionGate?.isReady ?? false
                    let closeError = await self.closeTracker?.consumeCloseError()

                    if didEmitFinal {
                        logger.info("Meta Muse socket closed normally after final transcript")
                        break
                    }

                    if !gateReady {
                        let failure = closeError ?? error
                        await self.connectionGate?.markFailure(failure)
                        await self.emitEvent(.error(failure))
                        await self.emitEvent(.completed)
                    } else if didEndAudio {
                        if let closeError, await self.hasNoText {
                            await self.emitEvent(.error(closeError))
                        } else {
                            await self.finalizeRemainingTranscriptIfNeeded()
                        }
                        await self.emitEvent(.completed)
                    } else if let closeError {
                        await self.emitEvent(.error(closeError))
                        await self.emitEvent(.completed)
                    } else if audioPacketCount > 0 {
                        await self.finalizeRemainingTranscriptIfNeeded()
                        await self.emitEvent(.completed)
                    } else {
                        await self.emitEvent(.error(error))
                        await self.emitEvent(.completed)
                    }
                    break
                }
            }
        }
    }

    private var hasNoText: Bool {
        confirmedSegments.isEmpty && currentPartial.isEmpty
    }

    private func finalizeRemainingTranscriptIfNeeded() {
        guard !didEmitFinal else { return }
        if !currentPartial.isEmpty {
            if confirmedSegments.last != currentPartial {
                confirmedSegments.append(currentPartial)
            }
            currentPartial = ""
        }
        if !confirmedSegments.isEmpty {
            let transcript = RecognitionTranscript(
                confirmedSegments: confirmedSegments,
                partialText: "",
                authoritativeText: confirmedSegments.joined(),
                isFinal: true
            )
            lastTranscript = transcript
            emitEvent(.transcript(transcript))
        }
        didEmitFinal = true
    }
}
