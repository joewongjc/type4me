import Foundation
import os

enum CloudASRError: Error, LocalizedError {
    case unsupportedProvider
    case authenticationFailed(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "CloudASRClient requires CloudASRConfig"
        case .authenticationFailed(let reason):
            return L("认证失败: \(reason)", "Authentication failed: \(reason)")
        case .connectionFailed(let reason):
            return L("连接失败: \(reason)", "Connection failed: \(reason)")
        }
    }
}

actor CloudASRClient: SpeechRecognizer {

    private let logger = Logger(
        subsystem: "com.type4me",
        category: "CloudASR"
    )

    // MARK: - Region

    private enum Region: Sendable {
        case cn   // Volcengine binary protocol
        case intl // Soniox JSON protocol
    }

    private static var detectedRegion: Region {
        Locale.current.region?.identifier == "CN" ? .cn : .intl
    }

    // MARK: - State

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var region: Region = .intl

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var audioPacketCount = 0
    private var totalAudioBytes = 0
    private var sessionStartTime: ContinuousClock.Instant?
    private var lastTranscriptTime: ContinuousClock.Instant?

    // Volcengine state
    private var lastVolcTranscript: RecognitionTranscript = .empty

    // Soniox state
    private var sonioxAccumulator = SonioxTranscriptAccumulator()
    private var lastSonioxTranscript: RecognitionTranscript = .empty

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events {
            return existing
        }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        return stream
    }

    // MARK: - Connect

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let cloudConfig = config as? CloudASRConfig else {
            throw CloudASRError.unsupportedProvider
        }

        // Fresh event stream
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream

        // Get JWT
        let jwt: String
        do {
            jwt = try await CloudAuthManager.shared.accessToken()
        } catch {
            throw CloudASRError.authenticationFailed(String(describing: error))
        }

        guard let url = URL(string: cloudConfig.proxyEndpoint) else {
            throw CloudASRError.connectionFailed("Invalid proxy URL: \(cloudConfig.proxyEndpoint)")
        }

        self.region = Self.detectedRegion

        var request = URLRequest(url: url)
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: options.urlSessionConfiguration)
        let task = session.webSocketTask(with: request)
        task.resume()
        self.session = session
        self.webSocketTask = task

        // Reset counters
        audioPacketCount = 0
        totalAudioBytes = 0
        sessionStartTime = ContinuousClock.now
        lastTranscriptTime = nil

        switch region {
        case .cn:
            try await connectVolcengine(task: task, options: options)
        case .intl:
            try await connectSoniox(task: task, options: options)
        }

        startReceiveLoop()
    }

    // MARK: - Volcengine Connect (CN)

    private func connectVolcengine(task: URLSessionWebSocketTask, options: ASRRequestOptions) async throws {
        lastVolcTranscript = .empty

        let uid = ASRIdentityStore.loadOrCreateUID()
        let payload = VolcProtocol.buildClientRequest(uid: uid, options: options)

        let header = VolcHeader(
            messageType: .fullClientRequest,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: payload)

        NSLog("[CloudASR/CN] Sending full_client_request (%d bytes)", message.count)
        do {
            try await task.send(.data(message))
        } catch {
            NSLog("[CloudASR/CN] WebSocket send failed: %@", String(describing: error))
            throw error
        }
        NSLog("[CloudASR/CN] full_client_request sent OK")
    }

    // MARK: - Soniox Connect (Intl)

    private func connectSoniox(task: URLSessionWebSocketTask, options: ASRRequestOptions) async throws {
        sonioxAccumulator = SonioxTranscriptAccumulator()
        lastSonioxTranscript = .empty

        // Build start message WITHOUT api_key (proxy injects it)
        let message = try buildSonioxStartMessage(options: options)

        NSLog("[CloudASR/Intl] Sending start message")
        try await task.send(.string(message))
        NSLog("[CloudASR/Intl] Start message sent OK")
    }

    private func buildSonioxStartMessage(options: ASRRequestOptions) throws -> String {
        var payload: [String: Any] = [
            "model": "stt-rt-v4",
            "audio_format": "pcm_s16le",
            "sample_rate": 16000,
            "num_channels": 1,
            "enable_endpoint_detection": true,
            "max_endpoint_delay_ms": 3000,
            "language_hints": ["zh", "en"],
            "language_hints_strict": true,
        ]

        let terms = options.hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !terms.isEmpty {
            payload["context"] = ["terms": terms]
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let message = String(data: data, encoding: .utf8)
        else {
            throw CloudASRError.connectionFailed("Failed to build Soniox start message")
        }

        return message
    }

    // MARK: - Send Audio

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }

        switch region {
        case .cn:
            let packet = VolcProtocol.encodeAudioPacket(audioData: data, isLast: false)
            try await task.send(.data(packet))
        case .intl:
            try await task.send(.data(data))
        }

        audioPacketCount += 1
        totalAudioBytes += data.count
    }

    // MARK: - End Audio

    func endAudio() async throws {
        guard let task = webSocketTask else { return }

        switch region {
        case .cn:
            let packet = VolcProtocol.encodeAudioPacket(audioData: Data(), isLast: true)
            try await task.send(.data(packet))
            NSLog("[CloudASR/CN] Sent last audio packet (empty, isLast=true)")
        case .intl:
            try await task.send(.string(""))
            NSLog("[CloudASR/Intl] Sent end-of-stream (sent %d packets, %d bytes)", audioPacketCount, totalAudioBytes)
        }
    }

    // MARK: - Disconnect

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
        NSLog("[CloudASR] Disconnected")
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    let shouldBreak = await self.handleMessage(message)
                    if shouldBreak { break }
                } catch {
                    if Task.isCancelled { break }

                    let region = await self.region
                    let packets = await self.audioPacketCount
                    let tag = region == .cn ? "CN" : "Intl"

                    if packets == 0 {
                        NSLog("[CloudASR/%@] Receive error before audio: %@", tag, String(describing: error))
                        await self.emitEvent(.error(error))
                    } else {
                        NSLog("[CloudASR/%@] Treating socket close as normal end (sent %d packets)", tag, packets)
                    }
                    await self.emitEvent(.completed)
                    break
                }
            }
            NSLog("[CloudASR] Receive loop ended")
            await self.eventContinuation?.finish()
        }
    }

    /// Returns true if the loop should break.
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) -> Bool {
        switch region {
        case .cn:
            return handleVolcMessage(message)
        case .intl:
            return handleSonioxMessage(message)
        }
    }

    // MARK: - Volcengine Message Handling

    private func handleVolcMessage(_ message: URLSessionWebSocketTask.Message) -> Bool {
        switch message {
        case .data(let data):
            let headerByte1 = data.count > 1 ? data[1] : 0
            let msgType = (headerByte1 >> 4) & 0x0F

            // Server error (0xF)
            if msgType == 0x0F {
                if audioPacketCount == 0 {
                    do {
                        _ = try VolcProtocol.decodeServerResponse(data)
                    } catch {
                        NSLog("[CloudASR/CN] Server error: %@", String(describing: error))
                        emitEvent(.error(error))
                    }
                } else {
                    NSLog("[CloudASR/CN] Session ended by server after %d audio packets", audioPacketCount)
                }
                emitEvent(.completed)
                webSocketTask?.cancel(with: .normalClosure, reason: nil)
                webSocketTask = nil
                return true
            }

            do {
                let response = try VolcProtocol.decodeServerResponse(data)
                let transcript = makeVolcTranscript(
                    from: response.result,
                    isFinal: response.header.flags == .asyncFinal
                )
                guard transcript != lastVolcTranscript else { return false }
                lastVolcTranscript = transcript

                logTranscript(transcript, tag: "CN")
                emitEvent(.transcript(transcript))

                if transcript.isFinal, !transcript.authoritativeText.isEmpty {
                    NSLog("[CloudASR/CN] Final transcript: '%@'", transcript.authoritativeText)
                }
            } catch {
                NSLog("[CloudASR/CN] Decode error: %@", String(describing: error))
                emitEvent(.error(error))
            }

        case .string(let text):
            NSLog("[CloudASR/CN] Unexpected text message: %@", text)

        @unknown default:
            break
        }
        return false
    }

    private func makeVolcTranscript(from result: VolcASRResult, isFinal: Bool) -> RecognitionTranscript {
        let confirmedSegments = result.utterances
            .filter(\.definite)
            .map(\.text)
            .filter { !$0.isEmpty }
        let partialText = result.utterances.last(where: { !$0.definite && !$0.text.isEmpty })?.text ?? ""
        let composedText = (confirmedSegments + (partialText.isEmpty ? [] : [partialText])).joined()
        let authoritativeText = result.text.isEmpty ? composedText : result.text
        return RecognitionTranscript(
            confirmedSegments: confirmedSegments,
            partialText: partialText,
            authoritativeText: authoritativeText,
            isFinal: isFinal
        )
    }

    // MARK: - Soniox Message Handling

    private func handleSonioxMessage(_ message: URLSessionWebSocketTask.Message) -> Bool {
        do {
            let data: Data
            switch message {
            case .data(let payload):
                data = payload
            case .string(let text):
                data = Data(text.utf8)
            @unknown default:
                return false
            }

            let result = try SonioxProtocol.parseServerMessage(from: data)

            if let error = result.error {
                let asrError = SonioxASRError.serverRejected(
                    code: error.code,
                    message: error.message
                )
                emitEvent(.error(asrError))
                emitEvent(.completed)
                return true
            }

            if let update = result.transcript {
                applySonioxTranscriptUpdate(update)
            }

            if result.isFinished {
                NSLog("[CloudASR/Intl] Session finished by server after %d packets", audioPacketCount)
                emitEvent(.completed)
                return true
            }

            return false
        } catch {
            emitEvent(.error(error))
            emitEvent(.completed)
            return true
        }
    }

    private func applySonioxTranscriptUpdate(_ update: SonioxTranscriptUpdate) {
        sonioxAccumulator.apply(update)
        let transcript = sonioxAccumulator.transcript
        guard transcript != lastSonioxTranscript else { return }
        lastSonioxTranscript = transcript

        logTranscript(transcript, tag: "Intl")
        emitEvent(.transcript(transcript))

        if transcript.isFinal, !transcript.authoritativeText.isEmpty {
            NSLog("[CloudASR/Intl] Final transcript: '%@'", transcript.authoritativeText)
        }
    }

    // MARK: - Helpers

    private func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }

    private func logTranscript(_ transcript: RecognitionTranscript, tag: String) {
        let now = ContinuousClock.now
        let sinceStart = sessionStartTime.map { now - $0 } ?? .zero
        let sinceLastUpdate = lastTranscriptTime.map { now - $0 } ?? .zero
        lastTranscriptTime = now

        let gapMs = Int(sinceLastUpdate.components.seconds * 1000
            + sinceLastUpdate.components.attoseconds / 1_000_000_000_000_000)

        DebugFileLogger.log("CloudASR/\(tag) transcript +\(sinceStart) gap=\(gapMs)ms confirmed=\(transcript.confirmedSegments.count) partial=\(transcript.partialText.count) final=\(transcript.isFinal)")

        NSLog(
            "[CloudASR/%@] Transcript +%@ gap=%dms confirmed=%d partial=%d final=%@",
            tag,
            String(describing: sinceStart),
            gapMs,
            transcript.confirmedSegments.count,
            transcript.partialText.count,
            transcript.isFinal ? "yes" : "no"
        )
    }
}
