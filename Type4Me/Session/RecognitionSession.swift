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

    /// Wait until the session reaches idle state, with a timeout.
    /// Returns true if idle was reached, false on timeout.
    func awaitIdle(timeout: Duration = .seconds(3)) async -> Bool {
        if state == .idle { return true }
        let deadline = ContinuousClock.now + timeout
        while state != .idle {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return state == .idle
    }

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

    #if HAS_CLOUD_SUBSCRIPTION
    private var isCloudMode: Bool { activeProvider == .cloud }
    #endif

    private var llmClientCache = LLMClientCache()

    /// Return the appropriate LLM client for the currently selected provider.
    private func currentLLMClient(config: LLMConfig) async -> any LLMClient {
        let bypassProxy = ProxyBypassMode.current.bypassLLM
        let providerID: String
        #if HAS_CLOUD_SUBSCRIPTION
        providerID = isCloudMode ? "cloud" : KeychainService.selectedLLMProvider.rawValue
        #else
        providerID = KeychainService.selectedLLMProvider.rawValue
        #endif
        let provider = KeychainService.selectedLLMProvider
        let key = LLMClientCacheKey(
            providerID: providerID,
            apiKey: config.apiKey,
            model: config.model,
            baseURL: config.baseURL,
            bypassProxy: bypassProxy
        )
        let resolution = llmClientCache.resolve(key: key) {
            #if HAS_CLOUD_SUBSCRIPTION
            if isCloudMode {
                return CloudLLMClient(bypassProxy: bypassProxy)
            }
            #endif
            if provider == .claude {
                return ClaudeChatClient(bypassProxy: bypassProxy)
            }
            return DoubaoChatClient(provider: provider, bypassProxy: bypassProxy)
        }

        if resolution.reused {
            DebugFileLogger.log("llm client reused provider=\(providerID)")
        } else {
            if let invalidated = resolution.invalidated {
                let reason = resolution.reasons.isEmpty
                    ? "cacheReset"
                    : resolution.reasons.joined(separator: ",")
                DebugFileLogger.log("llm client invalidated provider=\(providerID) reason=\(reason)")
                await invalidated.invalidate()
            }
            DebugFileLogger.log("llm client created provider=\(providerID)")
        }
        return resolution.client
    }

    /// Load LLM credentials from KeychainService.
    private func loadEffectiveLLMConfig() -> LLMConfig? {
        #if HAS_CLOUD_SUBSCRIPTION
        if isCloudMode { return LLMConfig(apiKey: "", model: "cloud") }
        #endif
        return KeychainService.loadLLMConfig()
    }

    private func currentASRModelLabel(for provider: ASRProvider) -> String? {
        let providerName = provider.displayName

        if provider == .sherpa {
            return "\(providerName) · \(ModelManager.selectedStreamingModel.displayName)"
        }

        guard let credentials = KeychainService.loadASRConfig(for: provider)?.toCredentials() else {
            return providerName
        }

        let modelKeys = ["model", "resourceId", "devPid", "lmId"]
        let model = modelKeys
            .compactMap { credentials[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let model else { return providerName }
        return "\(providerName) · \(model)"
    }

    /// Pre-initialize audio subsystem so the first recording starts instantly.
    func warmUp() { audioEngine.warmUp() }

    /// Pre-warm TCP connection to the ASR endpoint so the next WebSocket
    /// connect skips the handshake. Called on app launch and after each recording.
    nonisolated func warmUpASRConnection() {
        Task.detached(priority: .utility) {
            await self.pingASREndpoint()
        }
    }

    private func pingASREndpoint() async {
        let endpoint: String
        #if HAS_CLOUD_SUBSCRIPTION
        if KeychainService.selectedASRProvider == .cloud {
            endpoint = CloudConfig.apiEndpoint + "/health"
        } else {
            endpoint = currentASREndpoint()
        }
        #else
        endpoint = currentASREndpoint()
        #endif
        guard let url = URL(string: endpoint) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        _ = try? await ASRRequestOptions.sharedSession.data(for: req)
    }

    private func currentASREndpoint() -> String {
        let provider = KeychainService.selectedASRProvider
        switch provider {
        case .volcano:
            return "https://openspeech.bytedance.com"
        case .soniox:
            return "https://stt-rt.soniox.com"
        case .deepgram:
            return "https://api.deepgram.com"
        default:
            return ""
        }
    }

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

    private let maxRecordingDuration: TimeInterval = 600  // 10 minutes

    private var currentTranscript: RecognitionTranscript = .empty
    private var eventConsumptionTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var asrCleanupTask: Task<Void, Never>?
    private var asrCleanupGeneration: Int?
    private var finalTranscriptTimeoutTask: Task<Void, Never>?
    private var firstStreamingTextTimeoutTask: Task<Void, Never>?
    private var hasEmittedReadyForCurrentSession = false
    private var audioChunkContinuation: AsyncStream<Data>.Continuation?
    private var audioChunkSenderTask: Task<Void, Never>?
    private var uploadFailureFlag: UploadFailureFlag?
    private var lastStreamingError: Error?

    /// Flipped to true when mic level exceeds threshold during recording.
    /// When false at stop time, we skip the full ASR teardown (no speech = nothing to finalize).
    private var speechDetected = false
    private static let speechLevelThreshold: Float = 0.15

    private func markSpeechDetected() {
        if !speechDetected {
            speechDetected = true
        }
    }

    // MARK: - Prompt context (selected text + clipboard captured at recording start)

    private var promptContext: PromptContext = PromptContext(selectedText: "", clipboardText: "")

    /// Bundle identifier of the frontmost app when recording started.
    /// Used to select app-specific snippet rules.
    private var targetBundleId: String?

    // MARK: - Speculative LLM (fire during recording pauses)

    private var speculativeLLMTask: Task<String?, Never>?
    private var speculativeLLMText: String = ""
    private var speculativeLLMGeneration: Int?
    private var speculativeDebounceTask: Task<Void, Never>?
    private var speculativeThrottle = SpeculativeLLMThrottle()
    private var finalInjectionGuard = FinalInjectionGuard()
    /// Stores the last LLM error from the early/fresh LLM task, consumed once by stopRecording().
    private var pendingLLMError: Error?
    /// When true, skip text injection (paste) but still save to clipboard & history.
    private var injectionAborted = false
    /// Continuation resumed when a final (isFinal) transcript arrives during stop.
    private var finalTranscriptCont: CheckedContinuation<String?, Never>?
    /// Continuation resumed when first non-empty streaming text arrives (for short-recording wait).
    private var firstStreamingTextCont: CheckedContinuation<Bool, Never>?

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
        if state == .finishing || state == .injecting || state == .postProcessing {
            NSLog("[Session] startRecording: blocked, current session still processing (state=%@)", String(describing: state))
            DebugFileLogger.log("startRecording blocked: still processing state=\(state)")
            return
        }
        if state != .idle {
            NSLog("[Session] startRecording: forcing reset from state=%@", String(describing: state))
            DebugFileLogger.log("session forcing reset from state=\(state)")
            await forceReset()
        }

        stoppedByMaxDuration = false
        targetBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let provider = KeychainService.selectedASRProvider
        activeProvider = provider

        #if HAS_CLOUD_SUBSCRIPTION
        if provider == .cloud {
            let canUse = await CloudQuotaManager.shared.canUse()
            if !canUse {
                SoundFeedback.playError()
                state = .idle
                onASREvent?(.error(NSError(
                    domain: "Type4Me", code: -10,
                    userInfo: [NSLocalizedDescriptionKey: L("免费额度已用完", "Free quota exhausted")]
                )))
                onASREvent?(.completed)
                return
            }
        }
        #endif

        let effectiveMode = ASRProviderRegistry.resolvedMode(for: mode, provider: provider)
        sessionGeneration &+= 1
        let myGeneration = sessionGeneration

        self.currentMode = effectiveMode
        self.recordingStartTime = nil
        hasEmittedReadyForCurrentSession = false
        injectionAborted = false
        finalInjectionGuard.reset()
        pendingLLMError = nil
        lastStreamingError = nil
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
            do {
                try KeychainService.saveASRCredentials(appKey: appKey, accessKey: accessKey, resourceId: resourceId)
                NSLog("[Session] Loaded credentials from env vars and persisted to file")
            } catch {
                NSLog("[Session] WARNING: env var credentials loaded but failed to persist: %@", String(describing: error))
            }
            config = volcConfig
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
        let requestOptions = ASRRequestOptions(
            enablePunc: true,
            hotwords: hotwords,
            boostingTableID: biasSettings.boostingTableID,
            bypassProxy: ProxyBypassMode.current.bypassASR
        )

        // Capture prompt context while the user's selection is still active.
        promptContext = await PromptContext.capture()
        guard SessionGenerationGuard.isCurrent(
            expected: myGeneration,
            active: sessionGeneration
        ) else {
            DebugFileLogger.log("startRecording: zombie detected after capture, bailing")
            return
        }

        // Reset text state and clean up previous pipeline
        currentTranscript = .empty
        await finishAudioChunkPipeline(timeout: .milliseconds(100))
        guard SessionGenerationGuard.isCurrent(
            expected: myGeneration,
            active: sessionGeneration
        ) else {
            DebugFileLogger.log("startRecording: zombie detected after pipeline cleanup, bailing")
            return
        }

        // ── Phase 1: Start recording immediately (before ASR connects) ──
        // Audio chunks are buffered while WebSocket handshake is in progress.
        // This eliminates the ~1s perceived latency from connect().

        let audioBuffer = AudioChunkBuffer()

        speechDetected = false
        let levelHandler = self.onAudioLevel
        let speechGraceMs = SoundFeedback.startSoundDurationMs()
        let speechGraceEnd = ContinuousClock.now + .milliseconds(speechGraceMs)
        audioEngine.onAudioLevel = { [weak self] level in
            if level > RecognitionSession.speechLevelThreshold,
               ContinuousClock.now >= speechGraceEnd {
                Task { await self?.markSpeechDetected() }
            }
            levelHandler?(level)
        }

        audioEngine.onAudioChunk = { [weak self] data in
            guard self != nil else { return }
            audioBuffer.append(data)
        }

        do {
            audioEngine.selectedDeviceUID = UserDefaults.standard.string(forKey: "tf_selectedMicrophoneUID")
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

        // Volume lowered in Type4MeApp .ready handler

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
        if !currentMode.prompt.isEmpty, let llmConfig = loadEffectiveLLMConfig() {
            let client = await currentLLMClient(config: llmConfig)
            Task { await client.warmUp(baseURL: llmConfig.baseURL) }
        }

        // Safety: auto-stop after maxRecordingDuration to prevent unbounded memory use
        maxDurationTask?.cancel()
        asrCleanupTask?.cancel()
        asrCleanupTask = nil
        asrCleanupGeneration = nil
        maxDurationTask = Task { [weak self, maxRecordingDuration] in
            try? await Task.sleep(for: .seconds(maxRecordingDuration))
            guard let self, !Task.isCancelled else { return }
            await self.autoStopIfRecording()
        }
    }

    /// Auto-stop triggered by max recording duration timer.
    private func autoStopIfRecording() async {
        guard state == .recording else { return }
        DebugFileLogger.log("max recording duration reached (\(maxRecordingDuration)s), auto-stopping")
        stoppedByMaxDuration = true
        await stopRecording()
    }

    private func clearASRCleanupTask(generation: Int) {
        if asrCleanupGeneration == generation {
            asrCleanupTask = nil
            asrCleanupGeneration = nil
        }
    }

    /// Whether the current session was auto-stopped by max duration limit.
    private(set) var stoppedByMaxDuration = false

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

    /// Parse a Mac Action LLM reply for a `<tool_call>{...}</tool_call>`, dispatch
    /// the action via `ActionRegistry`, and return both the user-facing message
    /// and a status. The floating bar uses the status to pick an icon/color
    /// (✓ green / ✗ red / ? amber).
    private func dispatchMacAction(llmReply: String) async -> (message: String, status: MacActionResultStatus) {
        guard let toolCall = ToolCallParser.parse(llmReply) else {
            DebugFileLogger.log("macAction: no tool_call in LLM reply: \(llmReply.prefix(120))")
            return (L("未匹配到操作", "No matching action"), .unsure)
        }
        DebugFileLogger.log("macAction: dispatching \(toolCall.name) args=\(toolCall.arguments)")
        guard let result = await ActionRegistry.dispatch(name: toolCall.name, args: toolCall.arguments) else {
            DebugFileLogger.log("macAction: unknown action name \(toolCall.name)")
            return (L("未知操作：\(toolCall.name)", "Unknown action: \(toolCall.name)"), .failure)
        }
        if result.success {
            DebugFileLogger.log("macAction: success \(toolCall.name): \(result.displayMessage)")
            return (result.displayMessage, .success)
        } else {
            DebugFileLogger.log("macAction: failed \(toolCall.name): \(result.errorMessage ?? "")")
            return (result.errorMessage ?? L("操作失败", "Action failed"), .failure)
        }
    }

    /// Persist history, emit floating-bar event + `.completed`, and reset
    /// session state — the post-LLM finishing path used when Mac Action mode
    /// dispatched (or attempted to dispatch) an action. This deliberately skips
    /// the text-injection block that the normal post-LLM path runs.
    private func completeMacAction(
        message: String,
        status: MacActionResultStatus,
        rawText: String,
        recordingStartTime: Date?,
        activeProvider: ASRProvider,
        myGeneration: Int
    ) async {
        let recordId = UUID().uuidString
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let historyStatus: String = {
            switch status {
            case .success: return "action_success"
            case .failure: return "action_failed"
            case .unsure:  return "action_unmatched"
            }
        }()
        await historyStore.insert(HistoryRecord(
            id: recordId,
            createdAt: Date(),
            durationSeconds: duration,
            rawText: rawText,
            processingMode: currentMode.name,
            processedText: message,
            finalText: message,
            status: historyStatus,
            characterCount: message.count,
            asrProvider: activeProvider.displayName,
            asrModel: currentASRModelLabel(for: activeProvider)
        ))

        onASREvent?(.macActionResult(message: message, status: status))
        onASREvent?(.completed)

        if sessionGeneration == myGeneration, state != .idle {
            state = .idle
            hasEmittedReadyForCurrentSession = false
            currentTranscript = .empty
            warmUpASRConnection()
        }
        resetSpeculativeLLM()
        SystemVolumeManager.restore()
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
        maxDurationTask?.cancel()
        maxDurationTask = nil

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

        // Quick bail: if mic level never exceeded speech threshold, skip the
        // full ASR teardown (no speech = nothing to finalize). Saves 2-7s of waiting.
        if !speechDetected {
            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            DebugFileLogger.log("stop: no speech detected (duration=\(String(format: "%.1f", duration))s), fast exit")
            if let client = asrClient {
                await client.disconnect()
                self.asrClient = nil
            }
            eventConsumptionTask?.cancel()
            eventConsumptionTask = nil
            onASREvent?(.processingResult(text: ""))
            onASREvent?(.completed)
            if sessionGeneration == myGeneration, state != .idle {
                state = .idle
                hasEmittedReadyForCurrentSession = false
                currentTranscript = .empty
                warmUpASRConnection()
            }
            resetSpeculativeLLM()
            SystemVolumeManager.restore()
            return
        }

        // Two-phase wait: for streaming providers with short recordings and no
        // streaming text yet, wait briefly for ASR to respond before deciding to skip.
        // Phase 1: wait up to 1s for any streaming partial text.
        // Phase 2: if text arrives, endAudio + wait up to 1s for final result.
        let provider = activeProvider
        let providerIsStreaming = ASRProviderRegistry.capabilities(for: provider).isStreaming
        if providerIsStreaming {
            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            let hasStreamingText = !currentTranscript.composedText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if duration < 5 && !hasStreamingText {
                // Phase 1: wait up to 1s for any streaming text
                DebugFileLogger.log("stop: short recording (\(String(format: "%.1f", duration))s) with no streaming text, waiting for partial")
                let gotText = await awaitFirstStreamingText(timeout: .seconds(1))

                if !gotText {
                    // No streaming text after 1s — likely not real speech, fast exit
                    DebugFileLogger.log("stop: no streaming text after 1s wait, fast exit")
                    if let client = asrClient {
                        await client.disconnect()
                        self.asrClient = nil
                    }
                    eventConsumptionTask?.cancel()
                    eventConsumptionTask = nil
                    onASREvent?(.processingResult(text: ""))
                    onASREvent?(.completed)
                    if sessionGeneration == myGeneration, state != .idle {
                        state = .idle
                        hasEmittedReadyForCurrentSession = false
                        currentTranscript = .empty
                        warmUpASRConnection()
                    }
                    resetSpeculativeLLM()
                    SystemVolumeManager.restore()
                    return
                }

                // Phase 2: streaming text arrived — endAudio + short wait for final
                DebugFileLogger.log("stop: streaming text arrived, phase 2 teardown +\(ContinuousClock.now - stopT0)")
                if let client = asrClient {
                    _ = await withTimeout(.seconds(3)) {
                        try await client.endAudio()
                    }
                    let finalResult = await awaitFinalTranscript(timeout: .seconds(1))
                    DebugFileLogger.log("stop: phase 2 done, hasFinal=\(finalResult != nil) +\(ContinuousClock.now - stopT0)")

                    // Drain events + disconnect in background so post-teardown can start
                    let evtTask = eventConsumptionTask
                    eventConsumptionTask = nil
                    asrCleanupTask?.cancel()
                    asrCleanupGeneration = myGeneration
                    asrCleanupTask = Task { [weak self, myGeneration] in
                        if let evtTask { _ = await self?.withTimeout(.seconds(3)) { await evtTask.value } }
                        guard !Task.isCancelled else { return }
                        await client.disconnect()
                        DebugFileLogger.log("stop: phase 2 background cleanup done")
                        await self?.clearASRCleanupTask(generation: myGeneration)
                    }
                    self.asrClient = nil
                }
                // Fall through to post-teardown (LLM, inject, etc.)
                // asrClient is nil → the normal teardown block below is skipped.
            }
        }

        // Keep a matching speculative request alive, or start a stop-time
        // provisional request before waiting for ASR final.
        cancelSpeculativeLLM()
        speculativeThrottle.prepareForStop()
        var needsLLM = !currentMode.prompt.isEmpty
        var partialAtStop = currentTranscript.composedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        partialAtStop = SnippetStorage.applyEffective(to: partialAtStop, bundleId: targetBundleId)
        DebugFileLogger.log("stop: partialAtStop len=\(partialAtStop.count)")

        var earlyLLMTask: Task<String?, Never>?
        var earlyLLMInput: String?
        if needsLLM && !partialAtStop.isEmpty {
            let partialDirectDecision = ShortTextDirectPolicy.decide(
                text: partialAtStop,
                mode: currentMode
            )
            if partialDirectDecision != .directOutput {
                let existingDiff = TranscriptDiff.classify(
                    source: speculativeLLMText,
                    final: partialAtStop
                )
                if speculativeLLMGeneration == myGeneration,
                   existingDiff.canReuseLLMResult,
                   let speculativeLLMTask {
                    earlyLLMTask = speculativeLLMTask
                    earlyLLMInput = speculativeLLMText
                    DebugFileLogger.log("stop-time provisional reused inputLen=\(speculativeLLMText.count) diffType=\(existingDiff.type.rawValue) +\(ContinuousClock.now - stopT0)")
                } else if let llmConfig = loadEffectiveLLMConfig() {
                    cancelStaleSpeculativeRequest(reason: "stopInputChanged")
                    speculativeLLMText = partialAtStop
                    speculativeLLMGeneration = myGeneration
                    speculativeThrottle.markStopTimeRequestStarted(input: partialAtStop)
                    pendingLLMError = nil
                    let prompt = promptContext.expandContextVariables(currentMode.prompt)
                    let client = await currentLLMClient(config: llmConfig)
                    let provisionalInput = partialAtStop
                    DebugFileLogger.log("stop-time provisional request started model=\(llmConfig.model) len=\(provisionalInput.count) +\(ContinuousClock.now - stopT0)")
                    let task = Task<String?, Never> {
                        do {
                            let result = try await client.process(
                                text: provisionalInput, prompt: prompt, config: llmConfig
                            )
                            guard !Task.isCancelled else { return nil }
                            DebugFileLogger.log("stop-time provisional request completed len=\(result.count) +\(ContinuousClock.now - stopT0)")
                            return result
                        } catch {
                            guard !Task.isCancelled else { return nil }
                            DebugFileLogger.log("stop-time provisional request failed +\(ContinuousClock.now - stopT0) error=\(error)")
                            return nil
                        }
                    }
                    speculativeLLMTask = task
                    earlyLLMTask = task
                    earlyLLMInput = provisionalInput
                }
            } else {
                cancelStaleSpeculativeRequest(reason: "shortTextDirectOutput")
                DebugFileLogger.log(
                    "stop: provisional canceled reason=shortTextDirectOutput"
                )
            }
        }

        // Early label override for short direct output (语音润色 only).
        // Use streaming transcript to update UI immediately, before ASR teardown,
        // so the floating bar doesn't flash "润色中" → "校准中".
        if needsLLM,
           ShortTextDirectPolicy.decide(
               text: partialAtStop,
               mode: currentMode
           ) == .directOutput
        {
            onASREvent?(.processingLabelOverride(L("校准中", "Calibrating")))
        }

        // ASR teardown: send endAudio, then wait for the final transcript.
        // For streaming providers we wait for the precise isFinal signal rather than
        // draining the entire event stream, so we can fire LLM sooner.
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

            if providerIsStreaming, await awaitFinalTranscript(timeout: .seconds(2)) != nil {
                // Fast path: isFinal arrived, text is confirmed complete.
                // Run drain + disconnect in background so LLM can start immediately.
                DebugFileLogger.log("stop: isFinal received +\(ContinuousClock.now - stopT0)")
                let evtTask = eventConsumptionTask
                asrCleanupTask?.cancel()
                asrCleanupGeneration = myGeneration
                asrCleanupTask = Task { [weak self, myGeneration] in
                    if let evtTask {
                        _ = await self?.withTimeout(.seconds(3)) { await evtTask.value }
                    }
                    guard !Task.isCancelled else { return }
                    await client.disconnect()
                    DebugFileLogger.log("stop: ASR background cleanup done")
                    await self?.clearASRCleanupTask(generation: myGeneration)
                }
            } else {
                // Non-streaming or isFinal timeout: fall back to full drain.
                if providerIsStreaming {
                    DebugFileLogger.log("stop: isFinal timeout, full drain +\(ContinuousClock.now - stopT0)")
                }
                if let evtTask = eventConsumptionTask {
                    let drainTimeout: Duration = providerIsStreaming ? .seconds(5) : .seconds(5)
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
        }

        eventConsumptionTask = nil
        asrClient = nil
        hasEmittedReadyForCurrentSession = false
        guard sessionGeneration == myGeneration else {
            DebugFileLogger.log("stopRecording: zombie after ASR teardown, bailing")
            return
        }

        // Batch fallback: only when the server is truly missing audio (upload failed).
        // If upload was fine but drain timed out, the server already has all audio;
        // use whatever streaming produced rather than re-sending everything.
        let uploadFailed = uploadFailureFlag?.failed == true
        let hasUsableStreamingResult = !currentTranscript.confirmedSegments.isEmpty
        let streamingFailed = Self.shouldAttemptBatchFallback(
            uploadFailed: uploadFailed,
            asrTeardownClean: asrTeardownClean,
            streamingError: lastStreamingError
        )
        let needsBatchFallback = streamingFailed
            && (uploadFailed || lastStreamingError != nil || !hasUsableStreamingResult)
        if streamingFailed && !needsBatchFallback {
            DebugFileLogger.log("stop: drain timeout but streaming has confirmed text, skipping batch fallback")
        }
        if needsBatchFallback {
            let partialText = currentTranscript.composedText
            DebugFileLogger.log(
                "stop: streaming failed (partial=\(partialText.count) chars, uploadFailed=\(uploadFailed), hasStreamingError=\(lastStreamingError != nil)), attempting batch fallback"
            )
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
        lastStreamingError = nil

        // Combine confirmed segments + any trailing unconfirmed partial.
        let effectiveText = currentTranscript.displayText
        currentConfig = nil

        var finalLLMInput = effectiveText.trimmingCharacters(in: .whitespacesAndNewlines)
        finalLLMInput = SnippetStorage.applyEffective(to: finalLLMInput, bundleId: targetBundleId)
        let finalDiff = earlyLLMInput.map {
            TranscriptDiff.classify(source: $0, final: finalLLMInput)
        }
        if let finalDiff {
            DebugFileLogger.log(
                "stop: specLen=\(finalDiff.sourceLength) finalTranscript len=\(finalDiff.finalLength) diffType=\(finalDiff.type.rawValue) commonPrefixLength=\(finalDiff.commonPrefixLength) commonSuffixLength=\(finalDiff.commonSuffixLength) addedSuffixUnicode=\(finalDiff.addedSuffixUnicode) changedInMiddle=\(finalDiff.changedInMiddle) semanticMatch=\(finalDiff.canReuseLLMResult)"
            )
        } else {
            DebugFileLogger.log("stop: finalTranscript len=\(finalLLMInput.count) diffType=noProvisional semanticMatch=false")
        }

        let shortDirectEnabled = ShortTextDirectPolicy.isEnabled
        let shortDirectThreshold = ShortTextDirectPolicy.threshold
        let finalSemanticLength = ShortTextDirectPolicy.semanticLength(of: finalLLMInput)
        let shortDirectDecision = ShortTextDirectPolicy.decide(
            text: finalLLMInput,
            mode: currentMode,
            enabled: shortDirectEnabled,
            threshold: shortDirectThreshold
        )
        DebugFileLogger.log(
            "stop: short-text direct check mode=\(currentMode.name) rawLen=\(finalLLMInput.count) semanticLen=\(finalSemanticLength) threshold=\(shortDirectThreshold) enabled=\(shortDirectEnabled)"
        )
        switch shortDirectDecision {
        case .directOutput:
            needsLLM = false
            earlyLLMTask?.cancel()
            earlyLLMTask = nil
            cancelStaleSpeculativeRequest(reason: "shortTextDirectOutput")
            DebugFileLogger.log("stop: short-text direct output selected")
            DebugFileLogger.log("stop: provisional canceled reason=shortTextDirectOutput")
            onASREvent?(.processingLabelOverride(L("校准中", "Calibrating")))
        case .modeRequiresLLM:
            DebugFileLogger.log("stop: short-text direct output skipped reason=modeRequiresLLM")
        case .textTooLong:
            DebugFileLogger.log("stop: short-text direct output skipped reason=textTooLong")
        case .disabled:
            DebugFileLogger.log("stop: short-text direct output skipped reason=disabled")
        }

        let freshConfig = needsLLM ? loadEffectiveLLMConfig() : nil
        let freshPrompt = promptContext.expandContextVariables(currentMode.prompt)
        let freshClient: (any LLMClient)?
        if let freshConfig {
            freshClient = await currentLLMClient(config: freshConfig)
        } else {
            freshClient = nil
        }
        let freshModeName = currentMode.name
        let earlySelection = EarlyLLMTaskSelector.select(
            earlyInput: earlyLLMInput,
            finalInput: finalLLMInput,
            needsLLM: needsLLM,
            earlyTask: earlyLLMTask
        ) {
            guard let llmConfig = freshConfig,
                  let client = freshClient,
                  !finalLLMInput.isEmpty
            else {
                return nil
            }
            let freshInput = finalLLMInput
            return Task {
                DebugFileLogger.log("fresh fallback request started mode=\(freshModeName) model=\(llmConfig.model) len=\(freshInput.count) +\(ContinuousClock.now - stopT0)")
                do {
                    let result = try await client.process(
                        text: freshInput, prompt: freshPrompt, config: llmConfig
                    )
                    guard !Task.isCancelled else { return nil }
                    DebugFileLogger.log("stop: fresh LLM done len=\(result.count) +\(ContinuousClock.now - stopT0)")
                    return result
                } catch {
                    guard !Task.isCancelled else { return nil }
                    DebugFileLogger.log("stop: fresh LLM FAILED +\(ContinuousClock.now - stopT0) error=\(error)")
                    return nil
                }
            }
        }
        earlyLLMTask = earlySelection.task
        if earlyLLMTask != nil {
            state = .postProcessing
        }
        DebugFileLogger.log("stop: provisional reused=\(earlySelection.reused) +\(ContinuousClock.now - stopT0)")

        if !effectiveText.isEmpty {
            let rawText = effectiveText
            var finalText = effectiveText
            var processedText: String? = nil
            var llmFailed = false

            // Apply snippet replacements before LLM (e.g. "我的邮箱" → actual email)
            finalText = SnippetStorage.applyEffective(to: finalText, bundleId: targetBundleId)

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

                guard SessionGenerationGuard.isCurrent(
                    expected: myGeneration,
                    active: sessionGeneration
                ) else {
                    DebugFileLogger.log("stop: ignored stale early LLM completion gen=\(myGeneration) active=\(sessionGeneration)")
                    return
                }
                if let result = earlyResult, !result.isEmpty {
                    DebugFileLogger.log("stop: early LLM result received \(result.count) chars +\(ContinuousClock.now - stopT0)")
                    let cleaned = result.collapsingExtraSpaces
                    if currentMode.id == ProcessingMode.macActionId {
                        let action = await dispatchMacAction(llmReply: cleaned)
                        await completeMacAction(
                            message: action.message,
                            status: action.status,
                            rawText: rawText,
                            recordingStartTime: recordingStartTime,
                            activeProvider: activeProvider,
                            myGeneration: myGeneration
                        )
                        return
                    }
                    processedText = cleaned
                    finalText = cleaned
                    onASREvent?(.processingResult(text: cleaned))
                } else {
                    let err = pendingLLMError ?? LLMError.emptyResponse(nil)
                    DebugFileLogger.log("stop: early LLM failed, falling back to raw text: \(err)")
                    pendingLLMError = nil
                    llmFailed = true
                    onASREvent?(.processingResult(text: rawText))
                }
            } else if needsLLM {
                state = .postProcessing
                if let llmConfig = loadEffectiveLLMConfig() {
                    DebugFileLogger.log("stop: sync LLM firing mode=\(currentMode.name) model=\(llmConfig.model) with \(finalText.count) chars")
                    let client = await currentLLMClient(config: llmConfig)
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

                    guard SessionGenerationGuard.isCurrent(
                        expected: myGeneration,
                        active: sessionGeneration
                    ) else {
                        DebugFileLogger.log("stop: ignored stale sync LLM completion gen=\(myGeneration) active=\(sessionGeneration)")
                        return
                    }
                    if let result = llmResult {
                        let cleaned = result.collapsingExtraSpaces
                        if currentMode.id == ProcessingMode.macActionId {
                            let action = await dispatchMacAction(llmReply: cleaned)
                            await completeMacAction(
                                message: action.message,
                                status: action.status,
                                rawText: rawText,
                                recordingStartTime: recordingStartTime,
                                activeProvider: activeProvider,
                                myGeneration: myGeneration
                            )
                            return
                        }
                        processedText = cleaned
                        finalText = cleaned
                        onASREvent?(.processingResult(text: cleaned))
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

            finalText = finalText.removingCJKLatinSpaces
            finalText = finalText.strippingTrailingPunctuation

            state = .injecting
            let defaults = UserDefaults.standard
            injectionEngine.preserveClipboard = defaults.object(forKey: "tf_preserveClipboard") != nil
                ? defaults.bool(forKey: "tf_preserveClipboard")
                : true

            // Run injection on a detached task to avoid blocking the actor with usleep().
            // .finalized is emitted directly from the detached task so the UI updates
            // immediately after paste, without waiting for actor re-scheduling.
            let engine = injectionEngine
            let aborted = injectionAborted
            let onEvent = self.onASREvent
            let injectLog = "stop: injecting method=clipboard len=\(finalText.count) +\(ContinuousClock.now - stopT0)"
            guard SessionGenerationGuard.isCurrent(
                expected: myGeneration,
                active: sessionGeneration
            ) else {
                DebugFileLogger.log("stop: injection skipped for stale generation gen=\(myGeneration) active=\(sessionGeneration)")
                return
            }
            guard finalInjectionGuard.claim(generation: myGeneration) else {
                DebugFileLogger.log("stop: duplicate injection blocked generation=\(myGeneration)")
                return
            }
            if shortDirectDecision == .directOutput {
                DebugFileLogger.log(
                    "stop: short-text direct injecting finalTranscript len=\(finalText.count)"
                )
            }
            _ = await withCheckedContinuation { continuation in
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
                    // Notify UI immediately from this thread, before actor resumes
                    onEvent?(.finalized(text: finalText, injection: outcome))
                    DebugFileLogger.log("stop: finalized +\(ContinuousClock.now - stopT0)")
                    // Only restore clipboard when text was successfully inserted.
                    // When outcome is .copiedToClipboard (injection failed or ESC abort),
                    // keep the text in clipboard so user can manually paste.
                    if outcome == .inserted {
                        engine.finishClipboardRestore()
                    }
                    continuation.resume(returning: outcome)
                }
            }

            #if HAS_CLOUD_SUBSCRIPTION
            if isCloudMode {
                Task { await CloudQuotaManager.shared.refresh(force: true) }
            }
            #endif

            // Save to history
            let recordId = UUID().uuidString
            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            let status: String
            if injectionAborted { status = "aborted" }
            else if llmFailed { status = "llm_error" }
            else if needsBatchFallback { status = "stream_recovered" }
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
                characterCount: finalText.count,
                asrProvider: activeProvider.displayName,
                asrModel: currentASRModelLabel(for: activeProvider)
            ))
            KeychainService.addASRUsage(seconds: duration)

            // Note: injectionAborted and llmFailed info is already conveyed
            // through the .finalized event's InjectionOutcome / completionMessage.
            // No separate .error emission here to avoid green→red UI flash.

        } else {
            // No text recognized: skip history entry (don't save empty records)
            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            DebugFileLogger.log("stop: no text recognized (duration=\(duration)s), skipping history entry")
            onASREvent?(.processingResult(text: ""))
            onASREvent?(.completed)
        }

        // Only reset to idle if this is still the active session.
        if sessionGeneration == myGeneration, state != .idle {
            state = .idle
            hasEmittedReadyForCurrentSession = false
            currentTranscript = .empty
            // Pre-warm connection for next recording
            warmUpASRConnection()
        }
        resetSpeculativeLLM()
        SystemVolumeManager.restore()
        logger.info("Session complete, injected \(effectiveText.count) chars")
        DebugFileLogger.log("stop: total +\(ContinuousClock.now - stopT0)")
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
            if !transcript.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speechDetected = true
                if let cont = firstStreamingTextCont {
                    firstStreamingTextCont = nil
                    firstStreamingTextTimeoutTask?.cancel()
                    firstStreamingTextTimeoutTask = nil
                    cont.resume(returning: true)
                }
            }
            if let cont = finalTranscriptCont, isTranscriptEffectivelyFinal {
                finalTranscriptCont = nil
                finalTranscriptTimeoutTask?.cancel()
                finalTranscriptTimeoutTask = nil
                cont.resume(returning: transcript.displayText)
            }
            logger.info("Transcript updated: \(transcript.displayText)")
            if state == .recording && !currentMode.prompt.isEmpty {
                scheduleSpeculativeLLM()
            }

        case .error(let error):
            lastStreamingError = error
            logger.error("ASR error: \(error)")

        case .completed:
            logger.info("ASR stream completed")
            // Server signaled end-of-stream (e.g. Volcano 0xF0). If we're waiting
            // for a final transcript, resume now — currentTranscript contains the
            // last update the server sent before closing.
            if let cont = finalTranscriptCont {
                finalTranscriptCont = nil
                finalTranscriptTimeoutTask?.cancel()
                finalTranscriptTimeoutTask = nil
                let text = currentTranscript.displayText
                DebugFileLogger.log("stop: .completed resumed finalTranscriptCont (\(text.count) chars)")
                cont.resume(returning: text.isEmpty ? nil : text)
            }
            if state == .recording {
                NSLog("[Session] Server closed ASR while recording, initiating stop")
                DebugFileLogger.log("server-initiated stop from recording state")
                Task { await self.stopRecording() }
            }

        case .processingResult, .processingLabelOverride, .finalized, .macActionResult:
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

        audioChunkSenderTask = Task.detached {
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

    private var isSpeculativeLLMEnabled: Bool {
        if let override = UserDefaults.standard.object(forKey: "tf_enableSpeculativeLLM") as? Bool {
            return override
        }
        return !KeychainService.selectedLLMProvider.isLocal
    }

    /// Debounce transcript updates before starting a speculative request.
    private func scheduleSpeculativeLLM() {
        guard isSpeculativeLLMEnabled else { return }
        #if HAS_CLOUD_SUBSCRIPTION
        if isCloudMode { return }
        #endif

        var text = currentTranscript.composedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = SnippetStorage.applyEffective(to: text, bundleId: targetBundleId)
        let semanticLength = ShortTextDirectPolicy.semanticLength(of: text)
        let minimumSemanticLength = ShortTextDirectPolicy.isSafePolishingMode(currentMode)
            && ShortTextDirectPolicy.isEnabled
            ? ShortTextDirectPolicy.threshold + 1
            : 8
        let throttleText = String(repeating: "x", count: semanticLength)
        let submission = speculativeThrottle.submit(
            throttleText,
            minimumTextLength: minimumSemanticLength
        )

        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = nil

        switch submission {
        case .tooShort:
            DebugFileLogger.log(
                "speculative request skipped reason=textTooShort rawLen=\(text.count) semanticLen=\(semanticLength) min=\(minimumSemanticLength)"
            )
        case .deltaTooSmall:
            let delta = semanticLength - speculativeThrottle.lastStartedText.count
            DebugFileLogger.log(
                "speculative request skipped reason=deltaTooSmall len=\(text.count) delta=\(delta) minDelta=\(SpeculativeLLMThrottle.minimumCharacterIncrement)"
            )
        case .queued:
            DebugFileLogger.log(
                "speculative request queued reason=inFlight len=\(text.count)"
            )
        case .duplicate:
            break
        case .debounce:
            scheduleSpeculativeDebounce(for: text, throttleText: throttleText)
        }
    }

    private func scheduleSpeculativeDebounce(for text: String, throttleText: String) {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = Task {
            try? await Task.sleep(for: SpeculativeLLMThrottle.debounceDuration)
            guard !Task.isCancelled, state == .recording else { return }
            await fireSpeculativeLLM(text: text, throttleText: throttleText)
        }
    }

    private func fireSpeculativeLLM(text: String, throttleText: String) async {
        guard let llmConfig = loadEffectiveLLMConfig() else { return }
        guard speculativeThrottle.beginDebouncedRequest(for: throttleText) else { return }

        speculativeLLMText = text
        speculativeLLMGeneration = sessionGeneration
        pendingLLMError = nil
        let requestGeneration = sessionGeneration
        let requestText = text
        let prompt = promptContext.expandContextVariables(currentMode.prompt)

        let client = await currentLLMClient(config: llmConfig)
        DebugFileLogger.log(
            "speculative request started mode=\(currentMode.name) model=\(llmConfig.model) len=\(text.count)"
        )
        speculativeLLMTask = Task {
            let result: String?
            do {
                let processed = try await client.process(
                    text: text, prompt: prompt, config: llmConfig
                )
                guard !Task.isCancelled else {
                    self.speculativeRequestFinished(
                        input: requestText,
                        generation: requestGeneration,
                        resultWasIgnored: true
                    )
                    return nil
                }
                result = processed
            } catch {
                if Task.isCancelled {
                    self.speculativeRequestFinished(
                        input: requestText,
                        generation: requestGeneration,
                        resultWasIgnored: true
                    )
                    return nil
                }
                DebugFileLogger.log("speculative request failed error=\(error)")
                self.setPendingLLMError(
                    error,
                    generation: requestGeneration,
                    requestText: requestText
                )
                result = nil
            }
            self.speculativeRequestFinished(
                input: requestText,
                generation: requestGeneration,
                resultWasIgnored: false
            )
            return result
        }
    }

    private func speculativeRequestFinished(
        input: String,
        generation: Int,
        resultWasIgnored: Bool
    ) {
        guard generation == sessionGeneration,
              generation == speculativeLLMGeneration,
              input == speculativeLLMText
        else {
            DebugFileLogger.log(
                "speculative request result ignored reason=stale generation=\(generation) active=\(sessionGeneration) len=\(input.count)"
            )
            return
        }

        if resultWasIgnored {
            DebugFileLogger.log("speculative request result ignored reason=cancelled len=\(input.count)")
        } else {
            DebugFileLogger.log("speculative request completed len=\(input.count)")
        }

        let completedThrottleText = String(
            repeating: "x",
            count: ShortTextDirectPolicy.semanticLength(of: input)
        )
        guard let pending = speculativeThrottle.requestCompleted(input: completedThrottleText),
              state == .recording
        else { return }

        let submission = speculativeThrottle.submit(pending)
        if submission == .debounce {
            var pendingText = currentTranscript.composedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pendingText = SnippetStorage.applyEffective(
                to: pendingText,
                bundleId: targetBundleId
            )
            scheduleSpeculativeDebounce(for: pendingText, throttleText: pending)
        }
    }

    private func cancelSpeculativeLLM() {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = nil
        // Don't cancel speculativeLLMTask here — stopRecording may reuse it
    }

    private func cancelStaleSpeculativeRequest(reason: String) {
        guard let speculativeLLMTask else { return }
        speculativeLLMTask.cancel()
        self.speculativeLLMTask = nil
        DebugFileLogger.log(
            "speculative request canceled reason=\(reason) len=\(speculativeLLMText.count)"
        )
    }

    private func setPendingLLMError(_ error: Error, generation: Int, requestText: String) {
        guard generation == sessionGeneration,
              generation == speculativeLLMGeneration,
              requestText == speculativeLLMText
        else { return }
        pendingLLMError = error
    }

    private func resetSpeculativeLLM() {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = nil
        speculativeLLMTask?.cancel()
        speculativeLLMTask = nil
        speculativeLLMText = ""
        speculativeLLMGeneration = nil
        speculativeThrottle.reset()
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

    /// Wait for the ASR to emit a finalized transcript, with timeout.
    /// "Finalized" means either isFinal flag is set, or confirmed segments exist
    /// with no remaining partial text (Volcano bigmodel_async doesn't send asyncFinal).
    private func awaitFinalTranscript(timeout: Duration) async -> String? {
        if isTranscriptEffectivelyFinal {
            return currentTranscript.displayText
        }
        return await withCheckedContinuation { continuation in
            self.finalTranscriptTimeoutTask?.cancel()
            self.finalTranscriptCont = continuation
            self.finalTranscriptTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, !Task.isCancelled else { return }
                await self.resumeFinalTranscriptOnTimeout()
            }
        }
    }

    private func resumeFinalTranscriptOnTimeout() {
        if let cont = finalTranscriptCont {
            finalTranscriptCont = nil
            finalTranscriptTimeoutTask = nil
            cont.resume(returning: nil)
        }
    }

    private func resumeFirstStreamingTextOnTimeout() {
        if let cont = firstStreamingTextCont {
            firstStreamingTextCont = nil
            firstStreamingTextTimeoutTask = nil
            cont.resume(returning: false)
        }
    }

    /// Whether the current transcript is effectively final.
    /// Only trust the explicit isFinal flag (asyncFinal from server).
    /// The previous heuristic (partialText.isEmpty) caused premature triggers
    /// when the server cleared partials during finalization before sending the
    /// complete result, losing tail audio that was spoken but not yet transcribed.
    /// For providers that never send asyncFinal, we fall through to the .completed
    /// event handler which also resumes the finalTranscriptCont.
    private var isTranscriptEffectivelyFinal: Bool {
        currentTranscript.isFinal
    }

    /// Wait for the ASR to emit any non-empty streaming text, with timeout.
    /// Returns true if text arrived, false on timeout.
    private func awaitFirstStreamingText(timeout: Duration) async -> Bool {
        let text = currentTranscript.composedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return true }
        return await withCheckedContinuation { continuation in
            self.firstStreamingTextTimeoutTask?.cancel()
            self.firstStreamingTextCont = continuation
            self.firstStreamingTextTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, !Task.isCancelled else { return }
                await self.resumeFirstStreamingTextOnTimeout()
            }
        }
    }

    static func shouldAttemptBatchFallback(
        uploadFailed: Bool,
        asrTeardownClean: Bool,
        streamingError: Error?
    ) -> Bool {
        uploadFailed || !asrTeardownClean || streamingError != nil
    }

    // MARK: - Batch Fallback

    /// Try to transcribe full audio via the same provider.
    /// Soniox uses its async REST API (faster for complete audio); others use a fresh streaming connection.
    private func attemptBatchFallback(audio: Data, config: any ASRProviderConfig) async -> String? {
        let provider = activeProvider

        // Soniox: use async REST API instead of re-streaming
        if provider == .soniox, let sonioxConfig = config as? SonioxASRConfig {
            let bypass = ProxyBypassMode.current.bypassASR
            let hotwords = HotwordStorage.loadEffective()
            let apiKey = sonioxConfig.apiKey
            DebugFileLogger.log("batch fallback: using Soniox async API (\(audio.count) bytes)")
            let resultTask = Task.detached {
                await SonioxAsyncClient.transcribe(
                    audioData: audio,
                    apiKey: apiKey,
                    hotwords: hotwords,
                    bypassProxy: bypass
                )
            }
            return await withCheckedContinuation { continuation in
                let finished = OSAllocatedUnfairLock(initialState: false)
                Task.detached {
                    let result = await resultTask.value
                    if finished.withLock({ let old = $0; $0 = true; return !old }) {
                        continuation.resume(returning: result?.text)
                    }
                }
                Task.detached {
                    try? await Task.sleep(for: .seconds(90))
                    if finished.withLock({ let old = $0; $0 = true; return !old }) {
                        resultTask.cancel()
                        DebugFileLogger.log("batch fallback (async) timeout after 90s")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        // Other providers: fresh streaming connection with all audio at once
        let resultTask = Task.detached { () -> String? in
            guard let client = ASRProviderRegistry.createClient(for: provider) else { return nil }
            do {
                let options = ASRRequestOptions(enablePunc: true)
                try await client.connect(config: config, options: options)
                try await client.sendAudio(audio)
                try await client.endAudio()

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
        // If resultTask is stuck in a non-cooperative await, we return nil after 90s.
        return await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            Task.detached {
                let result = await resultTask.value
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: result)
                }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(90))
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    resultTask.cancel()
                    DebugFileLogger.log("batch fallback timeout after 90s")
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

        if let cont = firstStreamingTextCont {
            firstStreamingTextCont = nil
            firstStreamingTextTimeoutTask?.cancel()
            firstStreamingTextTimeoutTask = nil
            cont.resume(returning: false)
        }
        if let cont = finalTranscriptCont {
            finalTranscriptCont = nil
            finalTranscriptTimeoutTask?.cancel()
            finalTranscriptTimeoutTask = nil
            cont.resume(returning: nil)
        }
        eventConsumptionTask?.cancel()
        eventConsumptionTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        asrCleanupTask?.cancel()
        asrCleanupTask = nil
        asrCleanupGeneration = nil
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
        uploadFailureFlag = nil
        lastStreamingError = nil
        SystemVolumeManager.restore()
    }

}

// MARK: - String helpers

private extension String {
    /// Collapse runs of 2+ spaces into a single space.
    /// LLMs sometimes insert extra spaces between CJK and Latin text.
    var collapsingExtraSpaces: String {
        replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
    }

    /// Remove unwanted spaces around CJK characters.
    /// Chinese text never uses inter-word spaces, so any space adjacent to a
    /// CJK character is noise from ASR token boundaries or LLM formatting.
    /// Two rules cover all 5 CJK-involving combinations (中↔中, 中↔英, 英↔中,
    /// 中↔符, 符↔中) while leaving pure English "hello world" intact.
    var removingCJKLatinSpaces: String {
        let cjk = "[\\u3400-\\u4DBF\\u4E00-\\u9FFF\\uF900-\\uFAFF]"
        var s = self
        // Space after CJK, before any non-whitespace: "你 好" / "你 ," → "你好" / "你,"
        s = s.replacingOccurrences(of: "(?<=\(cjk)) +(?=\\S)", with: "", options: .regularExpression)
        // Space before CJK, after any non-whitespace: ", 你" / "Max 你" → ",你" / "Max你"
        s = s.replacingOccurrences(of: "(?<=\\S) +(?=\(cjk))", with: "", options: .regularExpression)
        return s
    }

    /// Strip trailing punctuation based on user preference (tf_stripTrailingPunctuation).
    var strippingTrailingPunctuation: String {
        let mode = UserDefaults.standard.string(forKey: "tf_stripTrailingPunctuation") ?? "off"
        guard mode != "off", !isEmpty else { return self }
        var s = self
        if mode == "period" {
            // Remove trailing periods: 。.
            while s.hasSuffix("。") || s.hasSuffix(".") {
                s.removeLast()
            }
        } else if mode == "all" {
            // Remove trailing punctuation (CJK + ASCII)
            let cjkPunc = "\u{3002}\u{FF0C}\u{FF01}\u{FF1F}\u{FF1B}\u{FF1A}\u{3001}\u{2026}\u{2014}\u{FF5E}\u{00B7}\u{300C}\u{300D}\u{300E}\u{300F}\u{3010}\u{3011}\u{FF08}\u{FF09}\u{300A}\u{300B}\u{201C}\u{201D}\u{2018}\u{2019}"
            let trailing = CharacterSet.punctuationCharacters
                .union(CharacterSet(charactersIn: cjkPunc))
            while let last = s.unicodeScalars.last, trailing.contains(last) {
                s.unicodeScalars.removeLast()
            }
        }
        return s
    }
}
