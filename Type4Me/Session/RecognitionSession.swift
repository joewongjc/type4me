import AppKit
import os

actor RecognitionSession {

    // MARK: - State

    enum SessionState: Equatable, Sendable {
        case idle
        case starting
        case recording
        case finishing
        case injecting
        case postProcessing  // Phase 3
    }

    private(set) var state: SessionState = .idle

    var canStartRecording: Bool { state == .idle }

    /// Exposed for testing; production code should use startRecording / stopRecording.
    func setState(_ newState: SessionState) {
        state = newState
    }

    /// Exposed for testing; production code should resolve modes through startRecording / switchMode.
    func currentModeForTesting() -> ProcessingMode {
        currentMode
    }

    // MARK: - Dependencies

    private let audioEngine = AudioCaptureEngine()
    private let injectionEngine = TextInjectionEngine()
    let historyStore = HistoryStore()
    private var asrClient: (any SpeechRecognizer)?

    private let logger = Logger(
        subsystem: "com.type4me.session",
        category: "RecognitionSession"
    )

    /// Return the appropriate LLM client for the currently selected provider.
    private func currentLLMClient() -> any LLMClient {
        let provider = KeychainService.selectedLLMProvider
        if provider == .claude {
            return ClaudeChatClient()
        }
        return DoubaoChatClient(provider: provider)
    }

    /// Pre-initialize audio subsystem so the first recording starts instantly.
    func warmUp() { audioEngine.warmUp() }

    // MARK: - Mode & Timing

    private var currentMode: ProcessingMode = .direct
    private var recordingStartTime: Date?
    private var currentConfig: (any ASRProviderConfig)?

    // MARK: - UI Callback

    /// Called on every ASR event so the UI layer can update.
    /// Set by AppDelegate to bridge actor → @MainActor.
    private var onASREvent: (@Sendable (RecognitionEvent) -> Void)?

    func setOnASREvent(_ handler: @escaping @Sendable (RecognitionEvent) -> Void) {
        onASREvent = handler
    }

    /// Called with normalized audio level (0..1) for UI visualization.
    private var onAudioLevel: (@Sendable (Float) -> Void)?

    func setOnAudioLevel(_ handler: @escaping @Sendable (Float) -> Void) {
        onAudioLevel = handler
    }

    // MARK: - Accumulated text

    private var currentTranscript: RecognitionTranscript = .empty
    private var eventConsumptionTask: Task<Void, Never>?
    private var hasEmittedReadyForCurrentSession = false
    private var audioChunkContinuation: AsyncStream<Data>.Continuation?
    private var audioChunkSenderTask: Task<Void, Never>?

    // MARK: - Prompt context (selected text + clipboard captured at recording start)

    private var promptContext: PromptContext = PromptContext(selectedText: "", clipboardText: "")

    // MARK: - Speculative LLM (fire during recording pauses)

    private var speculativeLLMTask: Task<String?, Never>?
    private var speculativeLLMText: String = ""
    private var speculativeDebounceTask: Task<Void, Never>?
    /// Stores the last LLM error from the early/fresh LLM task, consumed once by stopRecording().
    private var pendingLLMError: Error?

    // MARK: - Toggle

    func toggleRecording() async {
        switch state {
        case .idle:
            await startRecording()
        case .recording:
            await stopRecording()
        default:
            logger.warning("toggleRecording ignored in state: \(String(describing: self.state))")
        }
    }

    // MARK: - Start

    func startRecording(mode: ProcessingMode = .direct) async {
        if state != .idle {
            NSLog("[Session] startRecording: forcing reset from state=%@", String(describing: state))
            DebugFileLogger.log("session forcing reset from state=\(state)")
            await forceReset()
        }

        let provider = KeychainService.selectedASRProvider
        let effectiveMode = ASRProviderRegistry.resolvedMode(for: mode, provider: provider)
        self.currentMode = effectiveMode
        self.recordingStartTime = nil
        hasEmittedReadyForCurrentSession = false
        state = .starting

        // Load credentials for selected provider
        let config: any ASRProviderConfig

        if provider.isLocal {
            // Local providers: use default model directory if no saved config
            if let savedConfig = KeychainService.loadASRConfig(for: provider) {
                config = savedConfig
                NSLog("[Session] Loaded %@ config from file store", provider.rawValue)
            } else if let defaultConfig = SherpaASRConfig(credentials: ["modelDir": ModelManager.defaultModelsDir]) {
                config = defaultConfig
                NSLog("[Session] Using default model directory for %@", provider.rawValue)
            } else {
                NSLog("[Session] Failed to create default config for %@!", provider.rawValue)
                SoundFeedback.playError()
                state = .idle
                onASREvent?(.error(NSError(domain: "Type4Me", code: -1, userInfo: [NSLocalizedDescriptionKey: L("本地模型未配置", "Local model not configured")])))
                onASREvent?(.completed)
                return
            }
            // Verify required models are downloaded
            if !ModelManager.shared.areRequiredModelsAvailable() {
                NSLog("[Session] Required local models not downloaded for %@", provider.rawValue)
                SoundFeedback.playError()
                state = .idle
                onASREvent?(.error(NSError(domain: "Type4Me", code: -3, userInfo: [NSLocalizedDescriptionKey: L("请先下载识别模型", "Please download ASR models first")])))
                onASREvent?(.completed)
                return
            }
        } else if let savedConfig = KeychainService.loadASRConfig(for: provider) {
            config = savedConfig
            NSLog("[Session] Loaded %@ credentials from file store", provider.rawValue)
        } else if provider == .volcano,
                  let appKey = ProcessInfo.processInfo.environment["VOLC_APP_KEY"],
                  let accessKey = ProcessInfo.processInfo.environment["VOLC_ACCESS_KEY"] {
            // Env var fallback (volcano only, for dev convenience)
            let resourceId = ProcessInfo.processInfo.environment["VOLC_RESOURCE_ID"] ?? "volc.bigasr.sauc.duration"
            let volcConfig = VolcanoASRConfig(credentials: [
                "appKey": appKey, "accessKey": accessKey, "resourceId": resourceId,
            ])!
            try? KeychainService.saveASRCredentials(appKey: appKey, accessKey: accessKey, resourceId: resourceId)
            config = volcConfig
            NSLog("[Session] Loaded credentials from env vars and persisted to file")
        } else {
            NSLog("[Session] No ASR credentials found for provider=%@!", provider.rawValue)
            SoundFeedback.playError()
            state = .idle
            onASREvent?(.error(NSError(domain: "Type4Me", code: -1, userInfo: [NSLocalizedDescriptionKey: L("未配置 API 凭证", "API credentials not configured")])))
            onASREvent?(.completed)
            return
        }

        self.currentConfig = config

        guard let client = ASRProviderRegistry.createClient(for: provider) else {
            NSLog("[Session] No client implementation for provider=%@", provider.rawValue)
            SoundFeedback.playError()
            state = .idle
            onASREvent?(.error(NSError(domain: "Type4Me", code: -2, userInfo: [NSLocalizedDescriptionKey: L("\(provider.displayName) 暂不支持", "\(provider.displayName) not yet supported")])))
            onASREvent?(.completed)
            return
        }
        self.asrClient = client

        // Load hotwords
        let hotwords = HotwordStorage.load()
        let biasSettings = ASRBiasSettingsStorage.load()
        let needsLLM = !effectiveMode.prompt.isEmpty
        let requestOptions = ASRRequestOptions(
            enablePunc: !needsLLM,
            hotwords: hotwords,
            boostingTableID: biasSettings.boostingTableID
        )

        // Capture prompt context while the user's selection is still active.
        promptContext = await PromptContext.capture()

        // Reset text state and clean up previous pipeline
        currentTranscript = .empty
        await finishAudioChunkPipeline(timeout: .milliseconds(100))

        // ── Phase 1: Start recording immediately (before ASR connects) ──
        // Audio chunks are buffered while WebSocket handshake is in progress.
        // This eliminates the ~1s perceived latency from connect().

        let audioBuffer = AudioChunkBuffer()

        let levelHandler = self.onAudioLevel
        audioEngine.onAudioLevel = { level in
            levelHandler?(level)
        }

        audioEngine.onAudioChunk = { [weak self] data in
            guard self != nil else { return }
            audioBuffer.append(data)
        }

        do {
            try audioEngine.start()
            NSLog("[Session] Audio engine started OK")
            DebugFileLogger.log("audio engine started OK")
        } catch {
            NSLog("[Session] Audio engine start FAILED: %@", String(describing: error))
            DebugFileLogger.log("audio engine start failed: \(String(describing: error))")
            SoundFeedback.playError()
            await client.disconnect()
            self.asrClient = nil
            state = .idle
            onASREvent?(.error(error))
            return
        }

        state = .recording
        markReadyIfNeeded()
        DebugFileLogger.log("session entered recording state (buffering, ASR connecting)")

        // Volume is lowered after start sound plays (handled in Type4MeApp)

        // ── Phase 2: Connect ASR (audio is already recording) ──

        do {
            try await client.connect(config: config, options: requestOptions)
            NSLog(
                "[Session] ASR connected OK (streaming, hotwords=%d, history=%d)",
                hotwords.count,
                requestOptions.contextHistoryLength
            )
            DebugFileLogger.log("ASR connected OK")
        } catch {
            NSLog("[Session] ASR connect FAILED: %@", String(describing: error))
            DebugFileLogger.log("ASR connect failed: \(String(describing: error))")
            SoundFeedback.playError()
            audioEngine.stop()
            audioEngine.onAudioChunk = nil
            audioEngine.onAudioLevel = nil
            await client.disconnect()
            self.asrClient = nil
            state = .idle
            hasEmittedReadyForCurrentSession = false
            onASREvent?(.error(error))
            onASREvent?(.completed)
            SystemVolumeManager.restore()
            return
        }

        // Bail out if user already stopped while we were connecting
        guard state == .recording else {
            DebugFileLogger.log("session state changed during connect, aborting")
            await client.disconnect()
            self.asrClient = nil
            return
        }

        // ── Phase 3: Flush buffer → switch to live pipeline ──

        let events = await client.events
        eventConsumptionTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                await self.handleASREvent(event)
                if case .completed = event { break }
            }
        }

        let chunkContinuation = setupAudioChunkPipeline()

        // Flush all chunks buffered during connect
        let bufferedChunks = audioBuffer.drain()
        for chunk in bufferedChunks {
            chunkContinuation.yield(chunk)
        }

        // Switch callback from buffer to live pipeline
        var chunkCount = bufferedChunks.count
        audioEngine.onAudioChunk = { [weak self] data in
            guard let self else { return }
            chunkCount += 1
            chunkContinuation.yield(data)
        }

        // Catch any chunks that arrived between drain and callback switch
        for chunk in audioBuffer.drain() {
            chunkContinuation.yield(chunk)
        }

        DebugFileLogger.log("ASR pipeline live, flushed \(bufferedChunks.count) buffered chunks")

        // Pre-warm LLM connection for modes with post-processing
        if !currentMode.prompt.isEmpty, let llmConfig = KeychainService.loadLLMConfig() {
            let client = currentLLMClient()
            Task { await client.warmUp(baseURL: llmConfig.baseURL) }
        }
    }

    /// Switch the processing mode before stopping. Used for cross-mode hotkey stops.
    func switchMode(to mode: ProcessingMode) {
        currentMode = ASRProviderRegistry.resolvedMode(for: mode, provider: KeychainService.selectedASRProvider)
    }

    // MARK: - Stop

    /// Cancel an in-progress recording: tear down all resources without injecting any text.
    func cancelRecording() async {
        guard state == .recording || state == .starting else {
            logger.warning("cancelRecording called but state is \(String(describing: self.state))")
            return
        }
        DebugFileLogger.log("cancelRecording: discarding session from state=\(state)")
        SystemVolumeManager.restore()
        await forceReset()
    }

    func stopRecording() async {
        guard state == .recording else {
            logger.warning("stopRecording called but state is \(String(describing: self.state))")
            return
        }

        let stopT0 = ContinuousClock.now
        SystemVolumeManager.restore()  // Restore before stop sound plays
        try? await Task.sleep(for: .milliseconds(50))  // Let OS apply volume change
        SoundFeedback.playStop()
        state = .finishing

        // Stop capture first so flushRemaining() can emit the tail audio chunk.
        audioEngine.stop()
        audioEngine.onAudioChunk = nil
        await finishAudioChunkPipeline()
        DebugFileLogger.log("stop: audio stopped +\(ContinuousClock.now - stopT0)")

        // For LLM modes: reuse speculative LLM if text matches,
        // otherwise fire fresh LLM immediately.
        // Batch (non-streaming) providers skip early LLM — no real text available yet.
        cancelSpeculativeLLM()
        let needsLLM = !currentMode.prompt.isEmpty
        let provider = KeychainService.selectedASRProvider
        let canEarlyLLM = ASRProviderRegistry.capabilities(for: provider).isStreaming
        var earlyLLMTask: Task<String?, Never>?
        if needsLLM && canEarlyLLM {
            var earlyText = currentTranscript.composedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            earlyText = SnippetStorage.apply(to: earlyText)
            DebugFileLogger.log("stop: needsLLM=true mode=\(currentMode.name) text=\(earlyText.count)chars specMatch=\(earlyText == speculativeLLMText)")
            if !earlyText.isEmpty {
                if earlyText == speculativeLLMText, let specTask = speculativeLLMTask {
                    // Speculative LLM matches — reuse (may already be done!)
                    earlyLLMTask = specTask
                    state = .postProcessing
                    DebugFileLogger.log("stop: reusing speculative LLM +\(ContinuousClock.now - stopT0)")
                } else if let llmConfig = KeychainService.loadLLMConfig() {
                    // Text changed since last speculative call, fire fresh
                    speculativeLLMTask?.cancel()
                    let prompt = promptContext.expandContextVariables(currentMode.prompt)
                    let client = currentLLMClient()
                    state = .postProcessing
                    DebugFileLogger.log("stop: fresh LLM firing mode=\(currentMode.name) model=\(llmConfig.model) with \(earlyText.count) chars +\(ContinuousClock.now - stopT0)")
                    earlyLLMTask = Task {
                        do {
                            let result = try await client.process(
                                text: earlyText, prompt: prompt, config: llmConfig
                            )
                            DebugFileLogger.log("stop: fresh LLM done \(result.count) chars +\(ContinuousClock.now - stopT0)")
                            return result
                        } catch {
                            DebugFileLogger.log("stop: fresh LLM FAILED +\(ContinuousClock.now - stopT0) error=\(error)")
                            await self.setPendingLLMError(error)
                            return nil
                        }
                    }
                }
            }
        }

        // ASR teardown: streaming providers can skip endAudio in LLM modes since
        // we already have text. Batch providers (e.g. OpenAI REST) MUST await endAudio
        // because that's where the actual recognition happens.
        let providerIsStreaming = ASRProviderRegistry.capabilities(for: provider).isStreaming
        if let client = asrClient {
            if needsLLM && earlyLLMTask != nil && providerIsStreaming {
                // Fast path (streaming only): just disconnect, skip the 2-3s finalization.
                eventConsumptionTask?.cancel()
                await client.disconnect()
                DebugFileLogger.log("stop: ASR fast-disconnect +\(ContinuousClock.now - stopT0)")
            } else {
                // Full teardown: batch providers get a longer timeout for the HTTP round-trip.
                let endAudioTimeout: Duration = providerIsStreaming ? .seconds(3) : .seconds(60)
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await client.endAudio() }
                        group.addTask {
                            try await Task.sleep(for: endAudioTimeout)
                            throw CancellationError()
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                } catch {
                    NSLog("[Session] endAudio timed out or failed: %@", String(describing: error))
                    DebugFileLogger.log("endAudio timeout/error: \(error)")
                }
                let drainTimeout: Duration = providerIsStreaming ? .seconds(2) : .seconds(5)
                if let task = eventConsumptionTask {
                    let streamDrained = await withTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            await task.value
                            return true
                        }
                        group.addTask {
                            try? await Task.sleep(for: drainTimeout)
                            return false
                        }
                        let first = await group.next() ?? true
                        group.cancelAll()
                        return first
                    }
                    if !streamDrained {
                        task.cancel()
                        DebugFileLogger.log("event stream drain timeout; eventConsumptionTask cancelled")
                    }
                }
                await client.disconnect()
            }
        }
        eventConsumptionTask = nil
        asrClient = nil
        hasEmittedReadyForCurrentSession = false

        // Combine confirmed segments + any trailing unconfirmed partial.
        let effectiveText = currentTranscript.displayText
        currentConfig = nil

        if !effectiveText.isEmpty {
            let rawText = effectiveText
            var finalText = effectiveText
            var processedText: String? = nil

            // Apply snippet replacements before LLM (e.g. "我的邮箱" → actual email)
            finalText = SnippetStorage.apply(to: finalText)

            // LLM post-processing: prefer early result (fired at stop time),
            // fall back to synchronous call for very short recordings where
            // no streaming text was available yet.
            if let earlyTask = earlyLLMTask {
                state = .postProcessing
                DebugFileLogger.log("stop: awaiting early LLM result +\(ContinuousClock.now - stopT0)")
                let earlyResult = await earlyTask.value
                if let result = earlyResult, !result.isEmpty {
                    DebugFileLogger.log("stop: early LLM result received \(result.count) chars +\(ContinuousClock.now - stopT0)")
                    processedText = result
                    finalText = result
                    onASREvent?(.processingResult(text: result))
                } else {
                    let err = pendingLLMError ?? LLMError.emptyResponse(nil)
                    DebugFileLogger.log("stop: early LLM nil/empty/error, showing to user: \(err)")
                    finishWithLLMError(err)
                    return
                }
            } else if needsLLM {
                state = .postProcessing
                if let llmConfig = KeychainService.loadLLMConfig() {
                    DebugFileLogger.log("stop: sync LLM firing mode=\(currentMode.name) model=\(llmConfig.model) with \(finalText.count) chars")
                    do {
                        let client = currentLLMClient()
                        let result = try await client.process(
                            text: finalText, prompt: promptContext.expandContextVariables(currentMode.prompt), config: llmConfig
                        )
                        if result.isEmpty {
                            // Shouldn't reach here since DoubaoChatClient throws emptyResponse,
                            // but guard defensively for other LLM client implementations.
                            DebugFileLogger.log("stop: sync LLM empty result")
                            finishWithLLMError(LLMError.emptyResponse(nil))
                            return
                        } else {
                            processedText = result
                            finalText = result
                            onASREvent?(.processingResult(text: result))
                        }
                    } catch {
                        logger.error("LLM failed: \(error)")
                        DebugFileLogger.log("stop: sync LLM FAILED error=\(error)")
                        finishWithLLMError(error)
                        return
                    }
                } else {
                    DebugFileLogger.log("stop: no LLM credentials")
                    finishWithLLMError(NSError(domain: "Type4Me", code: -10, userInfo: [
                        NSLocalizedDescriptionKey: L("未配置 LLM 凭证", "LLM credentials not configured")
                    ]))
                    return
                }
            }

            DebugFileLogger.log("stop: injecting +\(ContinuousClock.now - stopT0)")
            state = .injecting
            let injectionOutcome = injectionEngine.inject(finalText)
            injectionEngine.copyToClipboard(finalText)
            onASREvent?(.finalized(text: finalText, injection: injectionOutcome))

            // Save to history
            let recordId = UUID().uuidString
            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            await historyStore.insert(HistoryRecord(
                id: recordId,
                createdAt: Date(),
                durationSeconds: duration,
                rawText: rawText,
                processingMode: currentMode == .direct ? nil : currentMode.name,
                processedText: processedText,
                finalText: finalText,
                status: "completed",
                characterCount: finalText.count
            ))

        } else {
            // No text recognized: tell UI to exit processing state
            onASREvent?(.processingResult(text: ""))
        }

        // Only reset to idle if we're still in the finishing state.
        // If forceReset() already moved us to .starting/.recording for a new session,
        // this zombie tail must not clobber it.
        if state == .finishing {
            state = .idle
            hasEmittedReadyForCurrentSession = false
            currentTranscript = .empty
        }
        resetSpeculativeLLM()
        SystemVolumeManager.restore()
        logger.info("Session complete, injected \(effectiveText.count) chars")
    }

    // MARK: - ASR Events

    private func handleASREvent(_ event: RecognitionEvent) {
        switch event {
        case .ready:
            // Deduplicate: ASR clients may emit .ready, but we also emit it
            // on first audio chunk via markReadyIfNeeded(). Route both through
            // the same guard to avoid double-firing the start sound.
            markReadyIfNeeded()
            return  // markReadyIfNeeded calls onASREvent(.ready) internally

        default:
            break
        }

        // Notify UI layer for all non-ready events
        onASREvent?(event)

        switch event {
        case .ready:
            break  // handled above

        case .transcript(let transcript):
            currentTranscript = transcript
            logger.info("Transcript updated: \(transcript.displayText)")
            if state == .recording && !currentMode.prompt.isEmpty {
                scheduleSpeculativeLLM()
            }

        case .error(let error):
            logger.error("ASR error: \(error)")

        case .completed:
            logger.info("ASR stream completed")
            if state == .recording {
                NSLog("[Session] Server closed ASR while recording, initiating stop")
                DebugFileLogger.log("server-initiated stop from recording state")
                Task { await self.stopRecording() }
            }

        case .processingResult, .finalized:
            break
        }
    }

    // MARK: - Internal helpers

    private func sendAudioToASR(_ data: Data) async throws {
        guard let client = asrClient else { return }
        try await client.sendAudio(data)
    }

    private func setupAudioChunkPipeline() -> AsyncStream<Data>.Continuation {
        audioChunkContinuation?.finish()
        audioChunkSenderTask?.cancel()

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        audioChunkContinuation = continuation
        audioChunkSenderTask = Task { [weak self] in
            for await data in stream {
                guard let self else { break }
                do {
                    try await self.sendAudioToASR(data)
                } catch {
                    DebugFileLogger.log("audio chunk send failed: \(error)")
                }
            }
        }
        return continuation
    }

    private func finishAudioChunkPipeline(timeout: Duration = .seconds(1)) async {
        audioChunkContinuation?.finish()
        audioChunkContinuation = nil

        guard let senderTask = audioChunkSenderTask else { return }
        let drained = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await senderTask.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }

        if !drained {
            senderTask.cancel()
            DebugFileLogger.log("audio chunk pipeline drain timeout; sender task cancelled")
        }
        audioChunkSenderTask = nil
    }

    private func markReadyIfNeeded() {
        guard !hasEmittedReadyForCurrentSession else { return }
        hasEmittedReadyForCurrentSession = true
        recordingStartTime = Date()
        DebugFileLogger.log("session emitting ready")
        onASREvent?(.ready)
        logger.info("Recording started")
    }

    // MARK: - Speculative LLM

    /// Debounce: after each transcript update, wait 800ms of silence before
    /// speculatively sending current text to LLM. If the user is still
    /// speaking, the timer resets.
    private func scheduleSpeculativeLLM() {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, state == .recording else { return }
            await fireSpeculativeLLM()
        }
    }

    private func fireSpeculativeLLM() async {
        var text = currentTranscript.composedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = SnippetStorage.apply(to: text)
        guard !text.isEmpty, text != speculativeLLMText else { return }
        guard let llmConfig = KeychainService.loadLLMConfig() else { return }

        // Cancel previous speculative call if text changed
        speculativeLLMTask?.cancel()
        speculativeLLMText = text
        let prompt = promptContext.expandContextVariables(currentMode.prompt)

        let client = currentLLMClient()
        DebugFileLogger.log("speculative LLM: firing mode=\(currentMode.name) model=\(llmConfig.model) with \(text.count) chars")
        speculativeLLMTask = Task {
            do {
                let result = try await client.process(
                    text: text, prompt: prompt, config: llmConfig
                )
                DebugFileLogger.log("speculative LLM: done \(result.count) chars")
                return result
            } catch {
                DebugFileLogger.log("speculative LLM: failed \(error)")
                await self.setPendingLLMError(error)
                return nil
            }
        }
    }

    private func cancelSpeculativeLLM() {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = nil
        // Don't cancel speculativeLLMTask here — stopRecording may reuse it
    }

    private func setPendingLLMError(_ error: Error) {
        pendingLLMError = error
    }

    /// Emit an LLM error event and reset session state.
    /// Call this from stopRecording() whenever LLM post-processing fails.
    private func finishWithLLMError(_ error: Error) {
        pendingLLMError = nil
        onASREvent?(.error(error))
        onASREvent?(.completed)
        state = .idle
        hasEmittedReadyForCurrentSession = false
        currentTranscript = .empty
        resetSpeculativeLLM()
        SystemVolumeManager.restore()
    }

    private func resetSpeculativeLLM() {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = nil
        speculativeLLMTask?.cancel()
        speculativeLLMTask = nil
        speculativeLLMText = ""
    }

    // MARK: - Force Reset

    /// Aggressively tear down all resources and return to idle.
    /// Used when a new recording is requested but the session is stuck
    /// (e.g. stopRecording hung on a WebSocket timeout).
    private func forceReset() async {
        NSLog("[Session] forceReset from state=%@", String(describing: state))
        DebugFileLogger.log("forceReset from state=\(state)")

        eventConsumptionTask?.cancel()
        eventConsumptionTask = nil
        resetSpeculativeLLM()

        audioEngine.stop()
        audioEngine.onAudioChunk = nil
        audioEngine.onAudioLevel = nil
        await finishAudioChunkPipeline(timeout: .milliseconds(100))

        if let client = asrClient {
            Task { await client.disconnect() }  // fire-and-forget: don't block reset on WebSocket teardown
        }
        asrClient = nil

        state = .idle
        currentTranscript = .empty
        hasEmittedReadyForCurrentSession = false
        currentConfig = nil
        SystemVolumeManager.restore()
    }

}
