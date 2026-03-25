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
    private var activeFlashTask: Task<String?, Never>?
    private var hasEmittedReadyForCurrentSession = false

    // MARK: - Prompt context (selected text + clipboard captured at recording start)

    private var promptContext: PromptContext = PromptContext(selectedText: "", clipboardText: "")

    // MARK: - Speculative LLM (fire during recording pauses)

    private var speculativeLLMTask: Task<String?, Never>?
    private var speculativeLLMText: String = ""
    private var speculativeDebounceTask: Task<Void, Never>?

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

        self.currentMode = mode
        self.recordingStartTime = nil
        hasEmittedReadyForCurrentSession = false
        state = .starting

        // Load credentials / config for selected provider
        let provider = KeychainService.selectedASRProvider
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
        let needsLLM = !mode.prompt.isEmpty
        let requestOptions = ASRRequestOptions(
            enablePunc: !needsLLM,
            hotwords: hotwords,
            boostingTableID: biasSettings.boostingTableID
        )

        // Capture prompt context (selected text + clipboard) before connect(),
        // because cloud ASR connect involves network round-trips that can take
        // hundreds of milliseconds, by which time the user's selection may be gone.
        promptContext = await PromptContext.capture()

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
            await client.disconnect()
            self.asrClient = nil
            state = .idle
            onASREvent?(.error(error))
            onASREvent?(.completed)
            return
        }

        // Reset text state
        currentTranscript = .empty

        // Start ASR event consumption
        let events = await client.events
        eventConsumptionTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                await self.handleASREvent(event)
                if case .completed = event { break }
            }
        }

        // Wire audio level → UI
        let levelHandler = self.onAudioLevel
        audioEngine.onAudioLevel = { level in
            levelHandler?(level)
        }

        // Wire audio callback → ASR
        var chunkCount = 0
        audioEngine.onAudioChunk = { [weak self] data in
            guard let self else { return }
            chunkCount += 1
            if chunkCount == 1 {
                NSLog("[Session] First audio chunk: %d bytes", data.count)
                DebugFileLogger.log("first audio chunk bytes=\(data.count)")
                Task {
                    await self.markReadyIfNeeded()
                }
            }
            Task {
                try? await self.sendAudioToASR(data)
            }
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
        DebugFileLogger.log("session entered recording state, waiting for first audio chunk")

        // Pre-warm LLM connection for modes with post-processing
        if !currentMode.prompt.isEmpty, let llmConfig = KeychainService.loadLLMConfig() {
            let client = currentLLMClient()
            Task { await client.warmUp(baseURL: llmConfig.baseURL) }
        }
    }

    /// Switch the processing mode before stopping. Used for cross-mode hotkey stops.
    func switchMode(to mode: ProcessingMode) {
        currentMode = mode
    }

    // MARK: - Stop

    func stopRecording() async {
        guard state == .recording else {
            logger.warning("stopRecording called but state is \(String(describing: self.state))")
            return
        }

        let stopT0 = ContinuousClock.now
        SoundFeedback.playStop()
        state = .finishing

        // Stop audio capture (nil callback BEFORE stop, because stop() calls flushRemaining)
        audioEngine.onAudioChunk = nil
        audioEngine.stop()
        DebugFileLogger.log("stop: audio stopped +\(ContinuousClock.now - stopT0)")

        // For LLM modes: reuse speculative LLM if text matches,
        // otherwise fire fresh LLM immediately.
        cancelSpeculativeLLM()
        let isPerformanceMode = currentMode.id == ProcessingMode.performanceId
        let needsLLM = !currentMode.prompt.isEmpty && !isPerformanceMode
        var earlyLLMTask: Task<String?, Never>?
        if needsLLM {
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
                    DebugFileLogger.log("stop: fresh LLM firing with \(earlyText.count) chars +\(ContinuousClock.now - stopT0)")
                    earlyLLMTask = Task {
                        do {
                            let result = try await client.process(
                                text: earlyText, prompt: prompt, config: llmConfig
                            )
                            DebugFileLogger.log("stop: fresh LLM done \(result.count) chars +\(ContinuousClock.now - stopT0)")
                            return result
                        } catch {
                            DebugFileLogger.log("stop: fresh LLM FAILED +\(ContinuousClock.now - stopT0) error=\(error)")
                            return nil
                        }
                    }
                }
            }
        }

        // Dual-channel: kick off offline ASR immediately — runs concurrently with streaming
        // ASR finalization below, so the round-trip overlaps the ≤1s streaming wait.
        // Provider-agnostic: uses registry's offlineRecognize if the provider supports it.
        activeFlashTask?.cancel()
        activeFlashTask = nil
        let provider = KeychainService.selectedASRProvider
        if isPerformanceMode,
           let entry = ASRProviderRegistry.entry(for: provider),
           entry.supportsDualChannel,
           let offlineRecognize = entry.offlineRecognize,
           let config = currentConfig {
            let pcmData = audioEngine.getRecordedAudio()
            if !pcmData.isEmpty {
                activeFlashTask = Task {
                    do {
                        let text = try await offlineRecognize(pcmData, config)
                        NSLog("[Session] Dual-channel offline ASR: %@", String(text.prefix(100)))
                        DebugFileLogger.log("dual-channel offline result: \(text)")
                        return text.isEmpty ? nil : text
                    } catch {
                        NSLog("[Session] Dual-channel offline ASR failed: %@, using streaming text", String(describing: error))
                        DebugFileLogger.log("dual-channel offline failed: \(String(describing: error))")
                        return nil
                    }
                }
            }
        }

        // ASR teardown: LLM modes skip endAudio/drain since we already
        // captured the streaming text and don't need server's final refinement.
        if let client = asrClient {
            if needsLLM && earlyLLMTask != nil {
                // Fast path: just disconnect, skip the 2-3s finalization.
                eventConsumptionTask?.cancel()
                await client.disconnect()
                DebugFileLogger.log("stop: ASR fast-disconnect +\(ContinuousClock.now - stopT0)")
            } else {
                // Full teardown for direct/dual-channel modes.
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await client.endAudio() }
                        group.addTask {
                            try await Task.sleep(for: .seconds(2))
                            throw CancellationError()
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                } catch {
                    NSLog("[Session] endAudio timed out or failed: %@", String(describing: error))
                    DebugFileLogger.log("endAudio timeout/error: \(error)")
                }
                if let task = eventConsumptionTask {
                    task.cancel()
                    _ = await Task.detached {
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask { await task.value }
                            group.addTask { try? await Task.sleep(for: .seconds(1)) }
                            await group.next()
                            group.cancelAll()
                        }
                    }.value
                }
                await client.disconnect()
            }
        }
        eventConsumptionTask = nil
        asrClient = nil
        hasEmittedReadyForCurrentSession = false

        // Combine confirmed segments + any trailing unconfirmed partial.
        let streamingText = currentTranscript.displayText

        // Dual-channel: await Flash ASR result (likely already in flight or done).
        var effectiveText = streamingText
        if let flash = activeFlashTask {
            state = .postProcessing
            if let flashText = await flash.value {
                effectiveText = flashText
            }
            activeFlashTask = nil
        }
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
                if let result = await earlyTask.value {
                    DebugFileLogger.log("stop: early LLM result received \(result.count) chars +\(ContinuousClock.now - stopT0)")
                    processedText = result
                    finalText = result
                    onASREvent?(.processingResult(text: result))
                } else {
                    DebugFileLogger.log("stop: early LLM returned nil, using raw +\(ContinuousClock.now - stopT0)")
                    onASREvent?(.processingResult(text: rawText))
                }
            } else if needsLLM {
                state = .postProcessing
                if let llmConfig = KeychainService.loadLLMConfig() {
                    do {
                        let client = currentLLMClient()
                        let result = try await client.process(
                            text: finalText, prompt: promptContext.expandContextVariables(currentMode.prompt), config: llmConfig
                        )
                        processedText = result
                        finalText = result
                        onASREvent?(.processingResult(text: result))
                    } catch {
                        logger.error("LLM failed: \(error), using raw text")
                        onASREvent?(.processingResult(text: rawText))
                    }
                } else {
                    logger.warning("No LLM credentials, skipping post-processing")
                    onASREvent?(.processingResult(text: rawText))
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
                status: "completed"
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
        logger.info("Session complete, injected \(effectiveText.count) chars")
    }

    // MARK: - ASR Events

    private func handleASREvent(_ event: RecognitionEvent) {
        // Notify UI layer
        onASREvent?(event)

        switch event {
        case .ready:
            break

        case .transcript(let transcript):
            currentTranscript = transcript
            logger.info("Transcript updated: \(transcript.displayText)")
            // Schedule speculative LLM during recording pauses
            if state == .recording && !currentMode.prompt.isEmpty {
                scheduleSpeculativeLLM()
            }

        case .error(let error):
            logger.error("ASR error: \(error)")

        case .completed:
            logger.info("ASR stream completed")
            // Server-initiated disconnect while still recording: tear down gracefully
            if state == .recording {
                NSLog("[Session] Server closed ASR while recording, initiating stop")
                DebugFileLogger.log("server-initiated stop from recording state")
                Task { await self.stopRecording() }
            }

        case .processingResult:
            break // Handled by UI layer via onASREvent callback

        case .finalized:
            break // Handled by UI layer via onASREvent callback
        }
    }

    // MARK: - Internal helpers

    private func sendAudioToASR(_ data: Data) async throws {
        guard let client = asrClient else { return }
        try await client.sendAudio(data)
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
        DebugFileLogger.log("speculative LLM: firing with \(text.count) chars")
        speculativeLLMTask = Task {
            do {
                let result = try await client.process(
                    text: text, prompt: prompt, config: llmConfig
                )
                DebugFileLogger.log("speculative LLM: done \(result.count) chars")
                return result
            } catch {
                DebugFileLogger.log("speculative LLM: failed \(error)")
                return nil
            }
        }
    }

    private func cancelSpeculativeLLM() {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = nil
        // Don't cancel speculativeLLMTask here — stopRecording may reuse it
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
        activeFlashTask?.cancel()
        activeFlashTask = nil
        resetSpeculativeLLM()

        audioEngine.onAudioChunk = nil
        audioEngine.stop()
        audioEngine.onAudioLevel = nil

        if let client = asrClient {
            await client.disconnect()
        }
        asrClient = nil

        state = .idle
        currentTranscript = .empty
        hasEmittedReadyForCurrentSession = false
        currentConfig = nil
    }

}
