import AppKit
import os

/// Thread-safe flag for the detached sender to signal upload failure.
private final class UploadFailureFlag: Sendable {
    private let _value = OSAllocatedUnfairLock(initialState: false)
    var failed: Bool {
        get { _value.withLock { $0 } }
        set { _value.withLock { $0 = newValue } }
    }
}

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
    /// The ASR provider for the current session, captured at start time.
    /// stopRecording reads this, not the global setting.
    private var activeProvider: ASRProvider = .volcano

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

    // MARK: - Session generation (prevents zombie tasks after forceReset)

    private var sessionGeneration: Int = 0

    // MARK: - Accumulated text

    private var currentTranscript: RecognitionTranscript = .empty
    private var eventConsumptionTask: Task<Void, Never>?
    private var hasEmittedReadyForCurrentSession = false
    private var audioChunkContinuation: AsyncStream<Data>.Continuation?
    private var audioChunkSenderTask: Task<Void, Never>?
    private var uploadFailureFlag: UploadFailureFlag?

    // MARK: - Prompt context (selected text + clipboard captured at recording start)

    private var promptContext: PromptContext = PromptContext(selectedText: "", clipboardText: "")

    // MARK: - Speculative LLM (fire during recording pauses)

    private var speculativeLLMTask: Task<String?, Never>?
    private var speculativeLLMText: String = ""
    private var speculativeDebounceTask: Task<Void, Never>?
    /// Stores the last LLM error from the early/fresh LLM task, consumed once by stopRecording().
    private var pendingLLMError: Error?
    /// When true, skip text injection (paste) but still save to clipboard & history.
    private var injectionAborted = false

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
        activeProvider = provider
        let effectiveMode = ASRProviderRegistry.resolvedMode(for: mode, provider: provider)
        sessionGeneration &+= 1
        let myGeneration = sessionGeneration

        self.currentMode = effectiveMode
        self.recordingStartTime = nil
        hasEmittedReadyForCurrentSession = false
        injectionAborted = false
        pendingLLMError = nil
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
            let resourceId = ProcessInfo.processInfo.environment["VOLC_RESOURCE_ID"] ?? VolcanoASRConfig.resourceIdSeedASR
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
        let hotwords = HotwordStorage.loadEffective()
        let biasSettings = ASRBiasSettingsStorage.load()
        let needsLLM = !effectiveMode.prompt.isEmpty
        let requestOptions = ASRRequestOptions(
            enablePunc: !needsLLM,
            hotwords: hotwords,
            boostingTableID: biasSettings.boostingTableID,
            bypassProxy: ProxyBypassMode.current.bypassASR
        )

        // Capture prompt context only when the current prompt actually needs it.
        let llmProvider = needsLLM ? KeychainService.selectedLLMProvider : nil
        if PrivacyPreferences.shouldCapturePromptContext(for: effectiveMode.prompt, llmProvider: llmProvider) {
            promptContext = await PromptContext.capture()
        } else {
            promptContext = .empty
        }
        guard sessionGeneration == myGeneration else {
            DebugFileLogger.log("startRecording: zombie detected after capture, bailing")
            return
        }

        // Reset text state and clean up previous pipeline
        currentTranscript = .empty
        await finishAudioChunkPipeline(timeout: .milliseconds(100))
        guard sessionGeneration == myGeneration else {
            DebugFileLogger.log("startRecording: zombie detected after pipeline cleanup, bailing")
            return
        }

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
            onASREvent?(.completed)
            return
        }

        state = .recording
        markReadyIfNeeded()
        DebugFileLogger.log("session entered recording state (buffering, ASR connecting)")

        // Volume is lowered after start sound plays (handled in Type4MeApp)

        // ── Phase 2: Connect ASR (audio is already recording) ──

        do {
            DebugFileLogger.log("ASR connecting provider=\(provider.rawValue)")
            try await client.connect(config: config, options: requestOptions)
            NSLog(
                "[Session] ASR connected OK (streaming, hotwords=%d, history=%d)",
                hotwords.count,
                requestOptions.contextHistoryLength
            )
            DebugFileLogger.log("ASR connected OK provider=\(provider.rawValue)")
        } catch {
            NSLog("[Session] ASR connect FAILED provider=%@ error=%@", provider.rawValue, String(describing: error))
            DebugFileLogger.log("ASR connect failed provider=\(provider.rawValue): \(String(describing: error))")
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

        // Bail out if session was superseded or user stopped while we were connecting
        guard sessionGeneration == myGeneration, state == .recording else {
            DebugFileLogger.log("startRecording: zombie or state change after connect (gen=\(myGeneration) current=\(sessionGeneration) state=\(state)), bailing")
            await client.disconnect()
            self.asrClient = nil
            return
        }

        // ── Phase 3: Flush buffer → switch to live pipeline ──

        let events = await client.events
        let expectedGeneration = sessionGeneration
        eventConsumptionTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                await self.handleASREvent(event, expectedGeneration: expectedGeneration)
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
        let failureFlag = self.uploadFailureFlag
        audioEngine.onAudioChunk = { [weak self] data in
            guard self != nil else { return }
            if failureFlag?.failed == true { return }
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
        currentMode = ASRProviderRegistry.resolvedMode(for: mode, provider: activeProvider)
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

    /// Mark that injection should be skipped. Recognition, clipboard, and history still proceed.
    func abortInjection() {
        injectionAborted = true
        DebugFileLogger.log("abortInjection: injection will be skipped")
    }

    func stopRecording() async {
        let myGeneration = sessionGeneration
        guard state == .recording else {
            logger.warning("stopRecording called but state is \(String(describing: self.state))")
            return
        }

        // Set state BEFORE any await to prevent a second stop from
        // slipping through the guard during the suspension point.
        state = .finishing

        let stopT0 = ContinuousClock.now
        SystemVolumeManager.restore()
        SoundFeedback.playStop()

        // Stop capture first so flushRemaining() can emit the tail audio chunk.
        audioEngine.stop()
        audioEngine.onAudioChunk = nil
        await finishAudioChunkPipeline()
        DebugFileLogger.log("stop: audio stopped +\(ContinuousClock.now - stopT0)")
        guard sessionGeneration == myGeneration else {
            DebugFileLogger.log("stopRecording: zombie after audio pipeline, bailing")
            return
        }

        // Keep speculative LLM task alive — we'll compare its input text
        // against the final ASR transcript after full teardown.
        cancelSpeculativeLLM()
        let needsLLM = !currentMode.prompt.isEmpty
        let provider = activeProvider

        // Kick off Soniox async calibration EARLY, in parallel with RT teardown.
        // Grab audio now before audioEngine.stop() clears it.
        let sonioxAsyncEnabled = provider == .soniox
            && PrivacyPreferences.sonioxAsyncCalibrationEnabled
        var sonioxAsyncTask: Task<SonioxAsyncClient.TranscriptionResult?, Never>?
        if sonioxAsyncEnabled, let sonioxConfig = currentConfig as? SonioxASRConfig {
            let fullAudio = audioEngine.getRecordedAudio()
            if !fullAudio.isEmpty {
                let hotwords = HotwordStorage.loadEffective()
                let bypass = ProxyBypassMode.current.bypassASR
                let apiKey = sonioxConfig.apiKey
                DebugFileLogger.log("stop: Soniox async kicked off early (\(fullAudio.count) bytes)")
                sonioxAsyncTask = Task.detached {
                    await SonioxAsyncClient.transcribe(
                        audioData: fullAudio,
                        apiKey: apiKey,
                        hotwords: hotwords,
                        bypassProxy: bypass
                    )
                }
            }
        }

        // ASR teardown: send endAudio and drain event stream with hard deadlines.
        // Uses detached tasks + continuation so a stuck client can't block stopRecording.
        let providerIsStreaming = ASRProviderRegistry.capabilities(for: provider).isStreaming
        var asrTeardownClean = true
        if let client = asrClient {
            let endAudioTimeout: Duration = providerIsStreaming ? .seconds(3) : .seconds(60)
            let endAudioOK = await withTimeout(endAudioTimeout) {
                try await client.endAudio()
            }
            if !endAudioOK {
                DebugFileLogger.log("endAudio timeout or failed")
                asrTeardownClean = false
            }

            // Always try to drain events — even if endAudio failed, the server
            // may have already queued transcript events before the connection broke.
            if let evtTask = eventConsumptionTask {
                let drainTimeout: Duration = providerIsStreaming ? .seconds(2) : .seconds(5)
                let drained = await withTimeout(drainTimeout) {
                    await evtTask.value
                }
                if !drained {
                    DebugFileLogger.log("event stream drain timeout")
                    asrTeardownClean = false
                }
            }

            await client.disconnect()
            eventConsumptionTask?.cancel()
            DebugFileLogger.log("stop: ASR teardown complete (clean=\(asrTeardownClean)) +\(ContinuousClock.now - stopT0)")
        }

        // Now that we have the final transcript, decide whether to reuse
        // the speculative LLM result or fire a fresh request.
        let canEarlyLLM = providerIsStreaming
        var earlyLLMTask: Task<String?, Never>?
        if needsLLM && canEarlyLLM {
            var finalASRText = currentTranscript.composedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            finalASRText = SnippetStorage.applyEffective(to: finalASRText)
            DebugFileLogger.log("stop: needsLLM=true mode=\(currentMode.name) text=\(finalASRText.count)chars specMatch=\(finalASRText == speculativeLLMText)")
            if !finalASRText.isEmpty {
                if finalASRText == speculativeLLMText, let specTask = speculativeLLMTask {
                    // Final transcript matches speculative input — reuse (may already be done!)
                    earlyLLMTask = specTask
                    state = .postProcessing
                    DebugFileLogger.log("stop: reusing speculative LLM +\(ContinuousClock.now - stopT0)")
                } else if let llmConfig = KeychainService.loadLLMConfig() {
                    // Final transcript differs from speculative input (tail words arrived),
                    // discard stale result and fire fresh LLM with complete text.
                    speculativeLLMTask?.cancel()
                    let prompt = promptContext.expandContextVariables(currentMode.prompt)
                    let client = currentLLMClient()
                    state = .postProcessing
                    if finalASRText != speculativeLLMText {
                        DebugFileLogger.log("stop: final transcript changed (spec=\(speculativeLLMText.count)chars final=\(finalASRText.count)chars), firing fresh LLM")
                    }
                    DebugFileLogger.log("stop: fresh LLM firing mode=\(currentMode.name) model=\(llmConfig.model) with \(finalASRText.count) chars +\(ContinuousClock.now - stopT0)")
                    earlyLLMTask = Task {
                        do {
                            let result = try await client.process(
                                text: finalASRText, prompt: prompt, config: llmConfig
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
        eventConsumptionTask = nil
        asrClient = nil
        hasEmittedReadyForCurrentSession = false
        guard sessionGeneration == myGeneration else {
            DebugFileLogger.log("stopRecording: zombie after ASR teardown, bailing")
            return
        }

        // Batch fallback: if streaming broke mid-session, always retry with
        // the full local recording to get complete text, even if we have partial.
        let streamingFailed = uploadFailureFlag?.failed == true || !asrTeardownClean
        if streamingFailed {
            let partialText = currentTranscript.composedText
            DebugFileLogger.log("stop: streaming failed (partial=\(partialText.count) chars), attempting batch fallback")
            let fullAudio = audioEngine.getRecordedAudio()
            if !fullAudio.isEmpty, let config = currentConfig {
                onASREvent?(.processingResult(text: partialText.isEmpty ? "重新识别中..." : partialText))
                if let batchText = await attemptBatchFallback(audio: fullAudio, config: config) {
                    currentTranscript = RecognitionTranscript(
                        confirmedSegments: [batchText],
                        partialText: "",
                        authoritativeText: batchText,
                        isFinal: true
                    )
                    DebugFileLogger.log("stop: batch fallback succeeded, \(batchText.count) chars")
                } else {
                    DebugFileLogger.log("stop: batch fallback failed, using partial text")
                }
            }
        }
        uploadFailureFlag = nil

        // Await Soniox async calibration result (kicked off earlier, in parallel with RT teardown).
        if let asyncTask = sonioxAsyncTask {
            let rtText = currentTranscript.composedText
            onASREvent?(.processingResult(text: rtText))
            if let result = await asyncTask.value, !result.text.isEmpty {
                let changed = result.text != rtText
                DebugFileLogger.log("stop: Soniox async done, \(result.text.count) chars, changed=\(changed)")
                if changed {
                    NSLog("[Session] Soniox async calibration changed result")
                }
                currentTranscript = RecognitionTranscript(
                    confirmedSegments: [result.text],
                    partialText: "",
                    authoritativeText: result.text,
                    isFinal: true
                )
            } else {
                DebugFileLogger.log("stop: Soniox async failed, using RT result")
            }
        }

        // Combine confirmed segments + any trailing unconfirmed partial.
        let effectiveText = currentTranscript.displayText
        currentConfig = nil

        if !effectiveText.isEmpty {
            let rawText = effectiveText
            var finalText = effectiveText
            var processedText: String? = nil
            var llmFailed = false

            // Apply snippet replacements before LLM (e.g. "我的邮箱" → actual email)
            finalText = SnippetStorage.applyEffective(to: finalText)

            // LLM post-processing: prefer early result (fired at stop time),
            // fall back to synchronous call for very short recordings where
            // no streaming text was available yet.
            if let earlyTask = earlyLLMTask {
                state = .postProcessing
                DebugFileLogger.log("stop: awaiting early LLM result +\(ContinuousClock.now - stopT0)")

                // Timeout: don't wait more than 15s for LLM
                let earlyResult: String? = await withCheckedContinuation { continuation in
                    let finished = OSAllocatedUnfairLock(initialState: false)
                    Task {
                        let result = await earlyTask.value
                        if finished.withLock({ let old = $0; $0 = true; return !old }) {
                            continuation.resume(returning: result)
                        }
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(15))
                        if finished.withLock({ let old = $0; $0 = true; return !old }) {
                            earlyTask.cancel()
                            DebugFileLogger.log("stop: early LLM timeout after 15s, falling back to raw text")
                            continuation.resume(returning: nil)
                        }
                    }
                }

                if let result = earlyResult, !result.isEmpty {
                    DebugFileLogger.log("stop: early LLM result received \(result.count) chars +\(ContinuousClock.now - stopT0)")
                    processedText = result
                    finalText = result
                    onASREvent?(.processingResult(text: result))
                } else {
                    let err = pendingLLMError ?? LLMError.emptyResponse(nil)
                    DebugFileLogger.log("stop: early LLM failed, falling back to raw text: \(err)")
                    pendingLLMError = nil
                    llmFailed = true
                    onASREvent?(.processingResult(text: rawText))
                }
            } else if needsLLM {
                state = .postProcessing
                if let llmConfig = KeychainService.loadLLMConfig() {
                    DebugFileLogger.log("stop: sync LLM firing mode=\(currentMode.name) model=\(llmConfig.model) with \(finalText.count) chars")
                    let client = currentLLMClient()
                    let prompt = promptContext.expandContextVariables(currentMode.prompt)
                    let textForLLM = finalText

                    let llmResult: String? = await withCheckedContinuation { continuation in
                        let finished = OSAllocatedUnfairLock(initialState: false)
                        let llmTask = Task {
                            do {
                                let result = try await client.process(
                                    text: textForLLM, prompt: prompt, config: llmConfig
                                )
                                return result.isEmpty ? nil : result
                            } catch {
                                DebugFileLogger.log("stop: sync LLM FAILED: \(error)")
                                return nil as String?
                            }
                        }
                        Task {
                            let result = await llmTask.value
                            if finished.withLock({ let old = $0; $0 = true; return !old }) {
                                continuation.resume(returning: result)
                            }
                        }
                        Task {
                            try? await Task.sleep(for: .seconds(15))
                            if finished.withLock({ let old = $0; $0 = true; return !old }) {
                                llmTask.cancel()
                                DebugFileLogger.log("stop: sync LLM timeout after 15s, falling back to raw text")
                                continuation.resume(returning: nil)
                            }
                        }
                    }

                    if let result = llmResult {
                        processedText = result
                        finalText = result
                        onASREvent?(.processingResult(text: result))
                    } else {
                        llmFailed = true
                        onASREvent?(.processingResult(text: rawText))
                    }
                } else {
                    DebugFileLogger.log("stop: no LLM credentials, falling back to raw text")
                    llmFailed = true
                    onASREvent?(.processingResult(text: rawText))
                }
            }

            state = .injecting
            let defaults = UserDefaults.standard
            injectionEngine.preserveClipboard = defaults.object(forKey: "tf_preserveClipboard") != nil
                ? defaults.bool(forKey: "tf_preserveClipboard")
                : true

            // Run injection on a detached task to avoid blocking the actor with usleep().
            // The actor yields cooperatively via withCheckedContinuation; .finalized is
            // still emitted only after injection completes, preserving ordering.
            let engine = injectionEngine
            let aborted = injectionAborted
            let injectLog = "stop: injecting method=clipboard len=\(finalText.count) +\(ContinuousClock.now - stopT0)"
            let injectionOutcome: InjectionOutcome = await withCheckedContinuation { continuation in
                Task.detached {
                    let outcome: InjectionOutcome
                    if aborted {
                        engine.copyToClipboard(finalText)
                        DebugFileLogger.log("stop: injection aborted by ESC, text saved to clipboard & history")
                        outcome = .copiedToClipboard
                    } else {
                        DebugFileLogger.log(injectLog)
                        outcome = engine.inject(finalText)
                    }
                    continuation.resume(returning: outcome)
                }
            }
            onASREvent?(.finalized(text: finalText, injection: injectionOutcome))

            // Save to history
            let recordId = UUID().uuidString
            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            let status: String
            if injectionAborted { status = "aborted" }
            else if llmFailed { status = "llm_error" }
            else if streamingFailed { status = "stream_recovered" }
            else { status = "completed" }
            await historyStore.insert(HistoryRecord(
                id: recordId,
                createdAt: Date(),
                durationSeconds: duration,
                rawText: rawText,
                processingMode: currentMode == .direct ? nil : currentMode.name,
                processedText: processedText,
                finalText: finalText,
                status: status,
                characterCount: finalText.count
            ))

            // Note: injectionAborted and llmFailed info is already conveyed
            // through the .finalized event's InjectionOutcome / completionMessage.
            // No separate .error emission here to avoid green→red UI flash.

        } else {
            // No text recognized: save to history as failed, then exit.
            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            if duration > 1.0 {
                // Only save if recording lasted more than 1 second (skip accidental taps)
                let status = streamingFailed ? "stream_failed" : "empty"
                await historyStore.insert(HistoryRecord(
                    id: UUID().uuidString,
                    createdAt: Date(),
                    durationSeconds: duration,
                    rawText: "",
                    processingMode: currentMode == .direct ? nil : currentMode.name,
                    processedText: nil,
                    finalText: "",
                    status: status,
                    characterCount: 0
                ))
                DebugFileLogger.log("stop: no text recognized, saved to history as \(status)")
            }
            onASREvent?(.processingResult(text: ""))
            onASREvent?(.completed)
        }

        // Only reset to idle if this is still the active session.
        if sessionGeneration == myGeneration, state != .idle {
            state = .idle
            hasEmittedReadyForCurrentSession = false
            currentTranscript = .empty
        }
        resetSpeculativeLLM()
        SystemVolumeManager.restore()
        logger.info("Session complete, injected \(effectiveText.count) chars")
    }

    // MARK: - ASR Events

    private func handleASREvent(_ event: RecognitionEvent, expectedGeneration: Int) {
        guard expectedGeneration == sessionGeneration else {
            DebugFileLogger.log("ignoring stale ASR event for gen=\(expectedGeneration), active=\(sessionGeneration)")
            return
        }
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

    // MARK: - Soniox punctuation helpers

    private static let sonioxPunctuationPrompt = """
    为以下语音识别文本添加标点符号并修正空格。规则:
    1. 根据语义添加合适的标点
    2. 去掉中文之间不必要的空格，中英文之间保留一个空格
    3. 不改任何文字内容
    4. 直接返回结果
    {text}
    """

    private static let chinesePunctuationSet: Set<Character> = [
        "\u{3002}", "\u{FF0C}", "\u{3001}", "\u{FF1B}", "\u{FF1A}",  // 。，、；：
        "\u{FF01}", "\u{FF1F}", "\u{2026}", "\u{2014}", "\u{00B7}",  // ！？…—·
        "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",              // ""''
        "\u{FF08}", "\u{FF09}", "\u{3010}", "\u{3011}",              // （）【】
        "\u{300A}", "\u{300B}",                                       // 《》
    ]

    private static func stripChinesePunctuation(_ text: String) -> String {
        var result = ""
        var skipSpaces = false
        for char in text {
            if chinesePunctuationSet.contains(char) {
                skipSpaces = true
                continue
            }
            if skipSpaces && char == " " {
                continue
            }
            skipSpaces = false
            result.append(char)
        }
        return result
    }

    // MARK: - Internal helpers

    private func setupAudioChunkPipeline() -> AsyncStream<Data>.Continuation {
        audioChunkContinuation?.finish()
        audioChunkSenderTask?.cancel()

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        audioChunkContinuation = continuation

        // Capture everything needed for sending so the Task body
        // does NOT hop back to the actor.  This prevents a blocking
        // WebSocket send from starving stopRecording().
        let client = asrClient
        let audioInput = ASRProviderRegistry.capabilities(for: activeProvider).audioInput

        let failureFlag = UploadFailureFlag()
        self.uploadFailureFlag = failureFlag

        audioChunkSenderTask = Task.detached { [weak self] in
            var chunkCount = 0
            var lastLogTime: ContinuousClock.Instant?
            for await data in stream {
                guard let client else { break }
                let t0 = ContinuousClock.now
                do {
                    switch audioInput {
                    case .pcmData:
                        try await client.sendAudio(data)
                    case .pcmBuffer:
                        guard let buffer = AudioCaptureEngine.makePCMBuffer(from: data) else { continue }
                        try await client.sendAudioBuffer(buffer)
                    }
                } catch {
                    DebugFileLogger.log("audio chunk send failed: \(error)")
                    failureFlag.failed = true
                    // If send fails, stop pumping — connection is dead.
                    break
                }
                let elapsed = ContinuousClock.now - t0
                chunkCount += 1
                let shouldLog = chunkCount % 50 == 0
                    || elapsed > .milliseconds(200)
                    || lastLogTime == nil
                if shouldLog {
                    DebugFileLogger.log("audio chunk #\(chunkCount) sent \(data.count)B in \(elapsed)")
                    lastLogTime = ContinuousClock.now
                }
            }
        }
        return continuation
    }

    private func finishAudioChunkPipeline(timeout: Duration = .seconds(1)) async {
        audioChunkContinuation?.finish()
        audioChunkContinuation = nil

        // Give the detached sender a brief window to drain remaining chunks
        // (especially the tail audio from flushRemaining). Since it's detached,
        // this wait does NOT block the actor.
        guard let senderTask = audioChunkSenderTask else { return }
        let drained = await withTimeout(timeout) {
            await senderTask.value
        }
        if !drained {
            senderTask.cancel()
            DebugFileLogger.log("audio chunk pipeline drain timeout; sender cancelled")
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
        text = SnippetStorage.applyEffective(to: text)
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

    private func resetSpeculativeLLM() {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = nil
        speculativeLLMTask?.cancel()
        speculativeLLMTask = nil
        speculativeLLMText = ""
    }

    // MARK: - Timeout Helper

    /// Run a @Sendable closure off-actor with a hard deadline.
    /// Returns true if completed in time. On timeout the operation task is cancelled.
    /// Uses detached tasks + continuation so withTaskGroup can't deadlock.
    private func withTimeout(
        _ duration: Duration,
        operation: @Sendable @escaping () async throws -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            let operationTask = Task.detached {
                let ok: Bool
                do {
                    try await operation()
                    ok = true
                } catch {
                    ok = false
                }
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: ok)
                }
            }
            Task.detached {
                try? await Task.sleep(for: duration)
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    operationTask.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Batch Fallback

    /// Try to transcribe full audio via the same provider in a fresh connection.
    private func attemptBatchFallback(audio: Data, config: any ASRProviderConfig) async -> String? {
        let provider = activeProvider
        let resultTask = Task.detached { () -> String? in
            guard let client = ASRProviderRegistry.createClient(for: provider) else { return nil }
            do {
                let options = ASRRequestOptions(enablePunc: true)
                try await client.connect(config: config, options: options)
                // Send all audio at once, then signal end
                try await client.sendAudio(audio)
                try await client.endAudio()

                // Wait for final transcript
                let events = await client.events
                for await event in events {
                    switch event {
                    case .transcript(let transcript) where transcript.isFinal:
                        await client.disconnect()
                        let text = transcript.authoritativeText.isEmpty
                            ? transcript.composedText : transcript.authoritativeText
                        return text.isEmpty ? nil : text
                    case .error:
                        await client.disconnect()
                        return nil
                    case .completed:
                        await client.disconnect()
                        return nil
                    default:
                        continue
                    }
                }
                await client.disconnect()
                return nil
            } catch {
                DebugFileLogger.log("batch fallback error: \(error)")
                await client.disconnect()
                return nil
            }
        }
        // Hard timeout via withCheckedContinuation (same pattern as withTimeout).
        // If resultTask is stuck in a non-cooperative await, we return nil after 30s.
        return await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            Task.detached {
                let result = await resultTask.value
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: result)
                }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(30))
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    resultTask.cancel()
                    DebugFileLogger.log("batch fallback timeout after 30s")
                    continuation.resume(returning: nil)
                }
            }
        }
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
            Task.detached { await client.disconnect() }  // fire-and-forget: detached to avoid blocking actor
        }
        asrClient = nil

        sessionGeneration &+= 1
        state = .idle
        currentTranscript = .empty
        hasEmittedReadyForCurrentSession = false
        currentConfig = nil
        SystemVolumeManager.restore()
    }

}
