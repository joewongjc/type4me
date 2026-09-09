import Foundation
import os

enum VolcASRError: Error, LocalizedError {
    case unsupportedProvider
    case serverRejected(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider: return L("火山引擎识别配置无效", "VolcASRClient requires VolcanoASRConfig")
        case .serverRejected(let code, let message):
            return message ?? L("HTTP \(code)", "HTTP \(code)")
        }
    }

    static func isWebSocketUpgradeProbeMessage(_ message: String?) -> Bool {
        guard let message = message?.lowercased(), !message.isEmpty else {
            return false
        }
        return message.contains("cannot upgrade to websocket")
            || message.contains("client is not using the websocket protocol")
            || message.contains("upgrade token not found")
            || message.contains("'upgrade' token not found")
    }
}

enum VolcTranscriptTransition: String, Equatable {
    case snapshot
    case revision
    case blankHeld
    case final
}

struct VolcTranscriptAccumulation: Equatable {
    let transcript: RecognitionTranscript
    let transition: VolcTranscriptTransition
}

/// Converts each Volcano response into a complete canonical text snapshot.
/// Server revisions replace the previous hypothesis instead of being appended
/// as locally confirmed text.
struct VolcTranscriptAccumulator {
    private var lastCanonicalText = ""
    private var lastTranscript: RecognitionTranscript = .empty

    mutating func reset() {
        self = VolcTranscriptAccumulator()
    }

    mutating func apply(
        result: VolcASRResult,
        isFinal: Bool
    ) -> VolcTranscriptAccumulation {
        let resultText = nonBlank(result.text) ? result.text : ""
        let utteranceText = result.utterances
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined()

        let incomingText = !resultText.isEmpty ? resultText : utteranceText
        if incomingText.isEmpty, !isFinal, !lastCanonicalText.isEmpty {
            return VolcTranscriptAccumulation(
                transcript: lastTranscript,
                transition: .blankHeld
            )
        }

        let canonicalText = incomingText.isEmpty ? lastCanonicalText : incomingText
        let previousCanonicalText = lastCanonicalText
        let transcript = makeTranscript(
            canonicalText: canonicalText,
            utterances: result.utterances,
            isFinal: isFinal
        )

        if !canonicalText.isEmpty {
            lastCanonicalText = canonicalText
            lastTranscript = transcript
        }

        let transition: VolcTranscriptTransition
        if isFinal {
            transition = .final
        } else if !previousCanonicalText.isEmpty,
                  canonicalText != previousCanonicalText {
            transition = .revision
        } else {
            transition = .snapshot
        }

        return VolcTranscriptAccumulation(
            transcript: transcript,
            transition: transition
        )
    }

    private func makeTranscript(
        canonicalText: String,
        utterances: [VolcUtterance],
        isFinal: Bool
    ) -> RecognitionTranscript {
        if isFinal {
            return RecognitionTranscript(
                confirmedSegments: canonicalText.isEmpty ? [] : [canonicalText],
                partialText: "",
                authoritativeText: canonicalText,
                isFinal: true
            )
        }

        let serverConfirmed = utterances
            .filter(\.definite)
            .map(\.text)
            .filter { !$0.isEmpty }
        let confirmedText = serverConfirmed.joined()

        let confirmedSegments: [String]
        let partialText: String
        if !confirmedText.isEmpty, canonicalText.hasPrefix(confirmedText) {
            confirmedSegments = serverConfirmed
            partialText = String(canonicalText.dropFirst(confirmedText.count))
        } else {
            confirmedSegments = []
            partialText = canonicalText
        }

        return RecognitionTranscript(
            confirmedSegments: confirmedSegments,
            partialText: partialText,
            authoritativeText: canonicalText,
            isFinal: false
        )
    }

    private func nonBlank(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

actor VolcASRClient: SpeechRecognizer {

    private static let endpoint =
        URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "VolcASRClient"
    )

    // MARK: - State

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveGeneration = 0

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events {
            return existing
        }
        return installFreshEventStream()
    }

    /// Bumped every time the stream is replaced. A handle taken at one
    /// generation stops receiving once a newer one exists, which is why
    /// `connect` must run before the caller reads `events`.
    private(set) var eventStreamGeneration = 0

    /// Replaces the event stream and returns the new one. `connect` calls this
    /// so each session starts clean; anything already holding the old handle is
    /// left on a stream that will never receive again.
    @discardableResult
    func installFreshEventStream() -> AsyncStream<RecognitionEvent> {
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        self.eventStreamGeneration += 1
        return stream
    }

    // MARK: - Connect

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let volcConfig = config as? VolcanoASRConfig else {
            throw VolcASRError.unsupportedProvider
        }

        // Ensure fresh event stream
        installFreshEventStream()

        let connectId = UUID().uuidString
        let isCloudProxy = options.cloudProxyURL != nil
        let targetURL: URL
        if let proxyURLString = options.cloudProxyURL, let proxyURL = URL(string: proxyURLString) {
            targetURL = proxyURL
        } else {
            targetURL = Self.endpoint
        }

        var request = URLRequest(url: targetURL)
        if !isCloudProxy {
            // Direct connection: inject vendor credentials
            let headers = VolcProtocol.authHeaders(
                authentication: volcConfig.authentication,
                resourceId: volcConfig.resourceId,
                connectId: connectId
            )
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }

        // Send full_client_request (no compression, plain JSON)
        let payload = VolcProtocol.buildClientRequest(uid: volcConfig.uid, options: options)

        let header = VolcHeader(
            messageType: .fullClientRequest,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: payload)

        let session = URLSession(configuration: options.urlSessionConfiguration)
        let task = session.webSocketTask(with: request)
        task.resume()

        lastTranscript = .empty
        audioPacketCount = 0
        totalAudioBytes = 0
        didRequestEnd = false
        sessionStartTime = ContinuousClock.now
        lastTranscriptTime = nil
        transcriptAccumulator.reset()
        NSLog("[ASR] Sending full_client_request (%d bytes), connectId=%@", message.count, connectId)
        do {
            try await task.send(.data(message))
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            NSLog("[ASR] WebSocket send failed: %@, probing for server error...", String(describing: error))
            if let serverError = await Self.probeServerError(request: request) {
                throw serverError
            }
            throw error
        }

        self.session = session
        self.webSocketTask = task

        NSLog("[ASR] full_client_request sent OK")

        // Start receive loop
        startReceiveLoop()
    }

    /// How long a credential test stays on the line waiting for the server's
    /// verdict on the init request.
    private static let credentialProbeWindow = Duration.seconds(2)

    /// 0.2s of 16 kHz mono 16-bit silence — the same amount that made the server
    /// return the quota verdict in issue #290. The init request alone was never
    /// shown to be enough to make it decide.
    private static let credentialProbeSilenceBytes = 6400

    /// Opening the socket only proves the endpoint and handshake are healthy.
    /// Volcengine reports quota, billing and rate-limit problems in a frame it
    /// sends after the init request, so a test that connects and immediately
    /// disconnects reports "Connected" for an account that cannot transcribe a
    /// single word (issue #290). This stays connected long enough to hear that
    /// verdict, and treats silence as success.
    static func validateCredentials(
        config: any ASRProviderConfig,
        options: ASRRequestOptions
    ) async throws {
        let client = VolcASRClient()
        try await client.connect(config: config, options: options)
        // Read the stream only after connecting. `connect` installs a fresh
        // continuation, so a handle taken before it is one the receive loop has
        // already replaced — the verdict would be delivered to a stream nobody
        // is reading and the probe would time out reporting success. Events the
        // server sends before iteration begins are buffered by the stream, so
        // reading late loses nothing.
        let events = await client.events

        // Give the server something to judge. #290's quota error arrived only
        // after audio was sent, so an init-only probe may never draw a verdict.
        try? await client.sendAudio(Data(count: Self.credentialProbeSilenceBytes))

        let serverError = await firstServerError(in: events, within: Self.credentialProbeWindow)
        await client.disconnect()
        if let serverError { throw serverError }
    }

    /// Returns the first `.error` the stream produces, or nil if the stream ends
    /// or the window elapses first.
    ///
    /// Silence is treated as success: the server says nothing when the request
    /// is accepted, so waiting longer would only slow down a healthy test.
    static func firstServerError(
        in events: AsyncStream<RecognitionEvent>,
        within window: Duration
    ) async -> Error? {
        await withTaskGroup(of: Error?.self) { group in
            group.addTask {
                for await event in events {
                    if case .error(let error) = event { return error }
                    if case .completed = event { return nil }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: window)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// When WebSocket handshake is rejected, make a plain HTTPS request to get the actual error body.
    private static func probeServerError(request: URLRequest) async -> VolcASRError? {
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "https"
        guard let httpsURL = components.url else { return nil }

        var httpRequest = URLRequest(url: httpsURL, timeoutInterval: 5)
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            httpRequest.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: httpRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode != 200 else { return nil }

            // Try to parse JSON error body (e.g. {"code": 1001, "message": "..."})
            var message: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = json["message"] as? String ?? json["msg"] as? String
                if let code = json["code"] as? Int, let msg = message {
                    message = "\(msg) (\(code))"
                }
            } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                message = String(text.prefix(200))
            }

            if VolcASRError.isWebSocketUpgradeProbeMessage(message) {
                NSLog("[ASR] Ignoring misleading WebSocket upgrade probe response: %@", message ?? "")
                return nil
            }

            NSLog("[ASR] HTTP probe got %d: %@", httpResponse.statusCode, message ?? "(no body)")
            return .serverRejected(statusCode: httpResponse.statusCode, message: message)
        } catch {
            NSLog("[ASR] HTTP probe failed: %@", String(describing: error))
            return nil
        }
    }

    // MARK: - Send Audio

    private var audioPacketCount = 0
    private var totalAudioBytes = 0
    private var didRequestEnd = false
    private var lastTranscript: RecognitionTranscript = .empty
    private var lastTranscriptTime: ContinuousClock.Instant?
    private var sessionStartTime: ContinuousClock.Instant?
    private var transcriptAccumulator = VolcTranscriptAccumulator()

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        let packet = VolcProtocol.encodeAudioPacket(
            audioData: data,
            isLast: false
        )
        try await task.send(.data(packet))
        audioPacketCount += 1
        totalAudioBytes += data.count
    }

    // MARK: - End Audio

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        let packet = VolcProtocol.encodeAudioPacket(
            audioData: Data(),
            isLast: true
        )
        didRequestEnd = true
        try await task.send(.data(packet))
        NSLog("[ASR] Sent last audio packet (empty, isLast=true)")
    }

    // MARK: - Disconnect

    func disconnect() async {
        receiveGeneration &+= 1
        let socket = webSocketTask
        webSocketTask = nil
        // Use URLSessionTask.cancel() here instead of the graceful WebSocket
        // close overload. At teardown the transcript is already settled; a
        // pending close handshake would keep CFNetwork continuations alive.
        socket?.cancel()
        session?.invalidateAndCancel()
        session = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        NSLog("[ASR] Disconnected")
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveGeneration &+= 1
        guard let task = webSocketTask else { return }
        scheduleReceive(on: task, generation: receiveGeneration)
    }

    /// URLSessionWebSocketTask's async `receive()` leaves a Foundation
    /// continuation graph alive after cancellation on current macOS releases.
    /// Drive the socket with the callback API so each receive owns no suspended
    /// Swift task while preserving actor-isolated message handling.
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
            handleMessage(message)
            if generation == receiveGeneration, task === webSocketTask {
                scheduleReceive(on: task, generation: generation)
            } else {
                finishReceiveLoop()
            }
        case .failure(let error):
            NSLog("[ASR] Receive loop error: %@", String(describing: error))
            if didRequestEnd {
                NSLog("[ASR] Treating as normal session end (sent %d packets)", audioPacketCount)
            } else if audioPacketCount == 0 {
                emitEvent(.error(error))
            } else {
                NSLog("[ASR] Unexpected close during audio (sent %d packets)", audioPacketCount)
                emitEvent(.error(error))
            }
            emitEvent(.completed)
            finishReceiveLoop()
        }
    }

    private func finishReceiveLoop() {
        NSLog("[ASR] Receive loop ended")
        eventContinuation?.finish()
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            let headerByte1 = data.count > 1 ? data[1] : 0
            let msgType = (headerByte1 >> 4) & 0x0F

            // Server error (0xF): could be a real error or just
            // bigmodel_async's "session complete" signal.
            //
            // Whether the server is reporting a problem has nothing to do with
            // how much audio we happened to send, so the two are told apart by
            // what the frame actually carries. Gating on `audioPacketCount`
            // turned every mid-session error into a silent stop (issue #290:
            // an exhausted quota looked exactly like a normal short recording).
            if msgType == 0x0F {
                let extracted = VolcProtocol.extractServerError(data)
                if extracted.code != nil || extracted.message != nil {
                    let error = VolcProtocolError.serverError(
                        code: extracted.code,
                        message: extracted.message
                    )
                    NSLog(
                        "[ASR] Server error after %d audio packets: %@",
                        audioPacketCount,
                        String(describing: error)
                    )
                    emitEvent(.error(error))
                } else {
                    // Nothing readable in the frame, so this is taken as the
                    // async session-complete signal. Record it: if a report of
                    // a hidden error ever survives this change, the bytes here
                    // are what identify the real layout.
                    NSLog("[ASR] Session ended by server after %d audio packets", audioPacketCount)
                    DebugFileLogger.log(
                        "Volc 0x0F frame with no readable error, \(data.count)B: "
                            + data.prefix(64).map { String(format: "%02x", $0) }.joined()
                    )
                }
                emitEvent(.completed)
                // The server has already ended the logical session. A graceful
                // close here leaves CFNetwork's close-handshake graph retained;
                // force task cancellation so the completed WebSocket can detach.
                webSocketTask?.cancel()
                webSocketTask = nil
                session?.invalidateAndCancel()
                session = nil
                return
            }

            do {
                let response = try VolcProtocol.decodeServerResponse(data)
                let accumulation = transcriptAccumulator.apply(
                    result: response.result,
                    isFinal: response.header.flags == .asyncFinal
                )
                let transcript = accumulation.transcript
                if accumulation.transition == .blankHeld {
                    DebugFileLogger.log(
                        "ASR transcript transition=blankHeld canonical=\(transcript.authoritativeText.count)chars"
                    )
                }
                guard transcript != lastTranscript else { return }
                lastTranscript = transcript

                let now = ContinuousClock.now
                let sinceStart = sessionStartTime.map { now - $0 } ?? .zero
                let sinceLastUpdate = lastTranscriptTime.map { now - $0 } ?? .zero
                lastTranscriptTime = now

                let gapMs = Int(sinceLastUpdate.components.seconds * 1000 + sinceLastUpdate.components.attoseconds / 1_000_000_000_000_000)
                DebugFileLogger.log("ASR transcript +\(sinceStart) gap=\(gapMs)ms transition=\(accumulation.transition.rawValue) canonical=\(transcript.authoritativeText.count) confirmed=\(transcript.confirmedSegments.count) partial=\(transcript.partialText.count) final=\(transcript.isFinal)")

                NSLog(
                    "[ASR] Transcript update +%@ gap=%dms confirmed=%d partial=%d final=%@",
                    String(describing: sinceStart),
                    gapMs,
                    transcript.confirmedSegments.count,
                    transcript.partialText.count,
                    transcript.isFinal ? "yes" : "no"
                )
                emitEvent(.transcript(transcript))

                if transcript.isFinal, !transcript.authoritativeText.isEmpty {
                    NSLog("[ASR] Final transcript received (%d chars)", transcript.authoritativeText.count)
                }
            } catch {
                NSLog("[ASR] Decode error: %@", String(describing: error))
                emitEvent(.error(error))
            }

        case .string(let text):
            NSLog("[ASR] Unexpected text message: %@", text)

        @unknown default:
            break
        }
    }

    private func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }
}
