import AppKit
import os
import Type4MeIntelliSenseCore
import Type4MeReviseCore

/// Thread-safe flag for the detached sender to signal upload failure.
private final class UploadFailureFlag: Sendable {
    private let _value = OSAllocatedUnfairLock(initialState: false)
    var failed: Bool {
        get { _value.withLock { $0 } }
        set { _value.withLock { $0 = newValue } }
    }
}

enum TranslationError: LocalizedError, Sendable {
    case unsupportedTarget(String)
    case llmUnavailable
    case emptyOutput
    case unsafeOutput
    case unexpectedLanguage(TranslationLanguage)

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget(let code):
            return L("暂不支持目标语言：\(code)", "Unsupported target language: \(code)")
        case .llmUnavailable:
            return L("翻译失败，请检查 LLM 设置后重试。", "Translation failed. Check your LLM settings and try again.")
        case .emptyOutput:
            return L("翻译模型没有返回有效内容，请重试。", "The translation model returned no usable text. Please try again.")
        case .unsafeOutput:
            return L("翻译结果包含异常结构，已停止粘贴。", "The translation contained an unsafe structure and was not pasted.")
        case .unexpectedLanguage(let target):
            return L(
                "翻译结果不是目标语言（\(target.displayName)），已停止粘贴。",
                "The translation was not in the target language (\(target.displayName)) and was not pasted."
            )
        }
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
        case recovering
    }

    enum RecoveryHotkeyAction: Equatable, Sendable {
        case notRecovering
        case prompted
        case interrupted
    }

    enum RecordingPurpose: Sendable {
        case input(ProcessingMode)
        case revise(RevisePreparedTarget)
    }

    private(set) var state: SessionState = .idle {
        didSet {
            if state == .idle {
                Task { [historyStore] in
                    await historyStore.shrinkMemory()
                }
            }
        }
    }

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

    /// A connect error is actionable only while the same session still owns
    /// the recording lifecycle. Stopping or replacing the session deliberately
    /// tears down an in-flight connection.
    static func shouldReportASRConnectFailure(
        expectedGeneration: Int,
        currentGeneration: Int,
        state: SessionState
    ) -> Bool {
        expectedGeneration == currentGeneration && state == .recording
    }

    /// Exposed for testing; production code should resolve modes through startRecording / switchMode.
    func currentModeForTesting() -> ProcessingMode {
        currentMode
    }

    /// Test seam for request-freezing behavior without starting microphone I/O.
    func freezeTranslationModeForTesting(_ mode: ProcessingMode) throws {
        guard mode.id == ProcessingMode.translationModeId else {
            throw TranslationError.unsupportedTarget("")
        }
        let code = mode.translationTargetLanguageCode ?? TranslationLanguage.english.rawValue
        guard let target = TranslationLanguage(rawValue: code) else {
            throw TranslationError.unsupportedTarget(code)
        }
        sessionGeneration &+= 1
        currentMode = mode
        translationRequestContext = TranslationRequestContext(
            generation: sessionGeneration,
            target: target,
            prompt: TranslationPromptBuilder.prompt(target: target)
        )
    }

    func replaceTranslationModeSnapshotForTesting(_ mode: ProcessingMode) {
        currentMode = mode
    }

    func frozenTranslationTargetForTesting() -> TranslationLanguage? {
        translationRequestContext?.target
    }

    func freezeIntelliSenseForTesting(
        snapshot: IntelliSenseContextSnapshot,
        settings: IntelliSenseSettings,
        expressionProfile: EffectiveExpressionProfile? = nil
    ) {
        sessionGeneration &+= 1
        currentMode = .intelliSense
        intelliSenseStartedModeID = ProcessingMode.intelliSenseId
        intelliSenseRequestContext = IntelliSenseRequestContext(
            settings: settings,
            snapshot: snapshot,
            expressionProfile: expressionProfile,
            startingModeID: ProcessingMode.intelliSenseId,
            generation: sessionGeneration
        )
    }

    func promptForCurrentModeForTesting(text: String? = nil) async -> String {
        await promptForCurrentMode(text: text)
    }

    /// Pure formatting seam used to verify that every session completion path
    /// resolves punctuation from the mode selected for processing.
    static func formattedOutputText(
        _ text: String,
        mode: ProcessingMode,
        userDefaults: UserDefaults = .standard
    ) -> String {
        TextOutputFormatter.format(
            text,
            options: .current(
                userDefaults: userDefaults,
                modePunctuation: mode.punctuationMode
            )
        )
    }

    // MARK: - Dependencies

    private let audioEngine = AudioCaptureEngine()
    private let injectionEngine = TextInjectionEngine()
    let historyStore = HistoryStore.shared
    private var asrClient: (any SpeechRecognizer)?
    private var llmClientCache = LLMClientCache()
    private(set) var recordingPurpose: RecordingPurpose = .input(.direct)

    private let logger = Logger(
        subsystem: "com.type4me.session",
        category: "RecognitionSession"
    )

    #if HAS_CLOUD_SUBSCRIPTION
    private var isCloudMode: Bool { activeProvider == .cloud }
    #endif

    private func resolveLLMRuntime() async -> ResolvedLLMRuntime? {
        guard let resolution = LLMRuntime.resolve(
            isCloudMode: isCloudModeForLLM,
            cache: &llmClientCache
        ) else {
            if let staleClient = llmClientCache.remove() {
                await staleClient.invalidate()
                DebugFileLogger.log("llm client cache cleared reason=configurationUnavailable")
            }
            return nil
        }

        if let invalidated = resolution.invalidated {
            await invalidated.invalidate()
            let reasons = resolution.invalidationReasons.joined(separator: ",")
            DebugFileLogger.log("llm client cache replaced reasons=\(reasons)")
        } else if resolution.reused {
            DebugFileLogger.log("llm client cache reused provider=\(resolution.runtime.providerID)")
        } else {
            DebugFileLogger.log("llm client cache created provider=\(resolution.runtime.providerID)")
        }
        return resolution.runtime
    }

    private var isCloudModeForLLM: Bool {
        #if HAS_CLOUD_SUBSCRIPTION
        return isCloudMode
        #else
        return false
        #endif
    }

    private func currentASRModelLabel(for provider: ASRProvider) -> String? {
        let providerName = provider.displayName

        if provider == .sherpa {
            return "\(providerName) · \(ModelManager.selectedStreamingModel.displayName)"
        }
        if provider == .cartesia {
            return "\(providerName) · \(CartesiaASRConfig.model)"
        }
        if provider == .stepfun {
            return "\(providerName) · \(StepFunASRConfig.model)"
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

    private static func volcanoConfigFromEnvironment(
        _ environment: [String: String]
    ) -> VolcanoASRConfig? {
        var credentials = [
            "resourceId": environment["VOLC_RESOURCE_ID"]
                ?? VolcanoASRConfig.resourceIdSeedASR,
        ]

        if let apiKey = nonEmptyEnvironmentValue("VOLC_API_KEY", in: environment) {
            credentials["authMode"] = VolcanoASRConfig.authModeAPIKey
            credentials["apiKey"] = apiKey
        } else if let appKey = nonEmptyEnvironmentValue("VOLC_APP_KEY", in: environment),
                  let accessKey = nonEmptyEnvironmentValue("VOLC_ACCESS_KEY", in: environment) {
            credentials["authMode"] = VolcanoASRConfig.authModeLegacy
            credentials["appKey"] = appKey
            credentials["accessKey"] = accessKey
        } else {
            return nil
        }

        return VolcanoASRConfig(credentials: credentials)
    }

    private static func nonEmptyEnvironmentValue(
        _ key: String,
        in environment: [String: String]
    ) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
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
        _ = try? await URLSession.shared.data(for: req)
    }

    private func currentASREndpoint() -> String {
        let provider = KeychainService.selectedASRProvider
        switch provider {
        case .volcano:
            return "https://openspeech.bytedance.com"
        case .stepfun:
            return "https://api.stepfun.com"
        case .stepfunBatch:
            return "https://api.stepfun.com"
        case .soniox:
            return "https://stt-rt.soniox.com"
        case .deepgram:
            return "https://api.deepgram.com"
        case .gemini:
            return "https://generativelanguage.googleapis.com"
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

    /// Gemini Live sessions are terminated by the server at roughly 10 minutes,
    /// measured from `connect()`. Stopping slightly earlier lets Type4Me finish
    /// the recording through the normal path (and surface the existing
    /// "已达最大时长" hint) instead of losing the tail to a server-side close.
    private let geminiMaxRecordingDuration: TimeInterval = 570  // 9m30s

    private func maxRecordingDuration(for provider: ASRProvider) -> TimeInterval {
        provider == .gemini ? geminiMaxRecordingDuration : maxRecordingDuration
    }

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
    private var recoveryTask: Task<Void, Never>?
    private var recoveryInterruptPromptShown = false
    private var recoveryRecordId: String?
    private var recoveryCreatedAt: Date?
    private var recoveryRawPartialText = ""
    private var recoveryPartialText = ""
    private var recoveryDuration: Double = 0
    private var recoveryModeName: String?
    private var recoveryProvider: ASRProvider = .volcano
    private var recoveryASRModel: String?

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

    private struct PendingPromptContextCapture: Sendable {
        let id: UUID
        let generation: Int
        let requirements: PromptContext.CaptureRequirements
        let task: Task<PromptContext, Never>
    }

    private var promptContext: PromptContext = .empty
    private var capturedPromptContextRequirements: PromptContext.CaptureRequirements = []
    private var pendingPromptContextCapture: PendingPromptContextCapture?
    /// A serialization barrier that prevents temporary Command+C clipboard
    /// fallbacks from consecutive sessions from overlapping their restore work.
    private var lastPromptContextCaptureTask: Task<PromptContext, Never>?
    private var lastPromptContextCaptureID: UUID?

    private func resetPromptContextCapture(
        for purpose: RecordingPurpose,
        generation: Int
    ) {
        promptContext = .empty
        capturedPromptContextRequirements = []
        pendingPromptContextCapture = nil
        guard case .input(let mode) = purpose else { return }
        schedulePromptContextCaptureIfNeeded(for: mode, generation: generation)
    }

    private func schedulePromptContextCaptureIfNeeded(
        for mode: ProcessingMode,
        generation: Int
    ) {
        // Selection Ask consumes the selection outside normal template expansion.
        // Mac Action passes it to selection-aware actions after the LLM reply.
        let requiresSelection = mode.executionKind == .selectionAsk
            || mode.id == ProcessingMode.macActionId
        let requested = PromptContext.captureRequirements(
            for: mode.prompt,
            requiresSelection: requiresSelection
        )
        let pendingRequirements = pendingPromptContextCapture?.generation == generation
            ? pendingPromptContextCapture?.requirements ?? []
            : []
        let covered = capturedPromptContextRequirements.union(pendingRequirements)
        let missing = requested.subtracting(covered)

        guard !missing.isEmpty else {
            if requested.isEmpty {
                DebugFileLogger.log(
                    "prompt context capture skipped mode=\(mode.name) requirements=none"
                )
            }
            return
        }

        let previousTask = lastPromptContextCaptureTask
        let previousPending = pendingPromptContextCapture
        let baseContext = promptContext
        let id = UUID()
        let combinedRequirements = covered.union(missing)
        DebugFileLogger.log(
            "prompt context capture scheduled mode=\(mode.name) "
                + "missing=\(missing.logDescription) "
                + "total=\(combinedRequirements.logDescription)"
        )

        let task = Task.detached {
            let previousResult = await previousTask?.value
            let base: PromptContext
            if previousPending?.generation == generation, let previousResult {
                base = previousResult
            } else {
                base = baseContext
            }

            let captureStartedAt = ContinuousClock.now
            let addition = await PromptContext.capture(requirements: missing)
            DebugFileLogger.log(
                "prompt context capture completed requirements=\(missing.logDescription) "
                    + "duration=\(ContinuousClock.now - captureStartedAt)"
            )
            return base.merging(addition)
        }

        lastPromptContextCaptureTask = task
        lastPromptContextCaptureID = id
        pendingPromptContextCapture = PendingPromptContextCapture(
            id: id,
            generation: generation,
            requirements: combinedRequirements,
            task: task
        )
        Task { [weak self] in
            _ = await task.value
            await self?.clearPromptContextCaptureBarrier(id: id)
        }
    }

    private func clearPromptContextCaptureBarrier(id: UUID) {
        guard lastPromptContextCaptureID == id else { return }
        lastPromptContextCaptureTask = nil
        lastPromptContextCaptureID = nil
    }

    private func resolvePromptContextIfNeeded(generation: Int) async {
        while let pending = pendingPromptContextCapture,
              pending.generation == generation {
            let context = await pending.task.value
            guard sessionGeneration == generation else { return }

            // A cross-mode switch may schedule a superset while this task is
            // suspended. In that case, wait for the replacement task instead.
            guard pendingPromptContextCapture?.id == pending.id else { continue }

            promptContext = context
            capturedPromptContextRequirements.formUnion(pending.requirements)
            pendingPromptContextCapture = nil
            DebugFileLogger.log(
                "prompt context capture resolved requirements="
                    + capturedPromptContextRequirements.logDescription
            )
            return
        }
    }

    private struct IntelliSenseRequestContext: Sendable {
        let settings: IntelliSenseSettings
        let snapshot: IntelliSenseContextSnapshot
        let expressionProfile: EffectiveExpressionProfile?
        let startingModeID: UUID
        let generation: Int
    }

    private var intelliSenseContextTask: Task<IntelliSenseContextSnapshot, Never>?
    private var intelliSenseRequestContext: IntelliSenseRequestContext?
    private var intelliSenseSettings: IntelliSenseSettings?
    private var intelliSenseTarget: TargetApplicationContext?
    private var intelliSenseStartedModeID: UUID?
    private var intelliSenseCrossModeFallback = false
    private var intelliSenseGuardRejected = false
    private var intelliSenseLastProcessingResult: IntelliSenseProcessingResult?

    private struct TranslationRequestContext: Sendable {
        let generation: Int
        let target: TranslationLanguage
        let prompt: String
    }

    private var translationRequestContext: TranslationRequestContext?
    /// Provider/model paired with the LLM request whose result this history row uses.
    private var historyLLMProvider: String?
    private var historyLLMModel: String?
    private var historyASRDurationSeconds: Double?
    private var historyLLMDurationSeconds: Double?

    /// Bundle identifier of the frontmost app when recording started.
    /// Used to select app-specific snippet rules.
    private var targetBundleId: String?
    /// The frontmost application captured when recording starts, used to restore focus if needed.
    private var targetApplication: NSRunningApplication?
    /// Frozen for the lifetime of one recording. Only normal manual recordings
    /// receive the user's configured value; specialized/automated flows pass the
    /// backward-compatible recording-start preference.
    private var injectionTargetPreference: InjectionTargetPreference = .defaultValue

    /// Pure, testable classification of how to treat the injection target that was
    /// captured when recording started, evaluated at paste time.
    ///
    /// The overriding goal is to never paste dictated text into an application the
    /// user did not intend, so anything uncertain fails safe to the clipboard.
    enum InjectionTargetPlan: Equatable {
        /// No target was captured because Type4Me itself was frontmost at record
        /// start (e.g. a URL Scheme command activated the app, then yielded focus).
        /// The application focused at paste time *is* the user's intended target,
        /// so pasting into the current frontmost app is correct.
        case injectIntoCurrentFrontmost
        /// A live target was captured; it must be activated and confirmed frontmost
        /// (PID match) before pasting, otherwise fall back to the clipboard.
        case activateAndConfirm
        /// A stop-time destination was captured with an explicit evidence tier.
        /// Exact and best-effort opaque targets perform their own revalidation.
        case injectIntoEndTarget
        /// The captured target terminated during transcription/processing. Never
        /// paste — whatever is frontmost now is a different app — retain the text
        /// in the clipboard for a deliberate manual paste.
        case failSafeClipboard
    }

    static func planInjectionTarget(
        preference: InjectionTargetPreference = .recordingStart,
        hasCapturedTarget: Bool,
        isTerminated: Bool,
        hasEndTarget: Bool = false
    ) -> InjectionTargetPlan {
        if preference == .recordingEnd {
            return hasEndTarget ? .injectIntoEndTarget : .failSafeClipboard
        }
        guard hasCapturedTarget else { return .injectIntoCurrentFrontmost }
        return isTerminated ? .failSafeClipboard : .activateAndConfirm
    }

    static func resolvedIntelliSenseTarget(
        preference: InjectionTargetPreference,
        recordingStartTarget: TargetApplicationContext?,
        recordingEndTarget: TargetApplicationContext?
    ) -> TargetApplicationContext? {
        preference == .recordingEnd ? recordingEndTarget : recordingStartTarget
    }

    /// Activates `target` and waits until it actually becomes the frontmost
    /// application, up to a short timeout. Returns `true` only once the target is
    /// confirmed frontmost, so callers can fail-safe (skip pasting) instead of
    /// risking text landing in whatever application happens to be focused.
    ///
    /// `NSRunningApplication.activate()` is asynchronous and can fail (e.g. the app
    /// quit, or the system denied activation), so its return value alone is not a
    /// safe signal — we verify the real frontmost app instead.
    nonisolated static func activateAndConfirmFrontmost(_ target: NSRunningApplication) -> Bool {
        let targetPid = target.processIdentifier
        guard !target.isTerminated, let targetBundleID = target.bundleIdentifier else {
            return false
        }
        let activated = DispatchQueue.main.sync {
            target.activate()
        }
        if !activated {
            DebugFileLogger.log("stop: target.activate() returned false pid=\(targetPid)")
        }
        if !target.isTerminated,
           !isExpectedFrontmostApplication(pid: targetPid, bundleIdentifier: targetBundleID) {
            // macOS can reject delayed activation from a menu-bar app even
            // though the recording began from a global user hotkey. Type4Me is
            // already Accessibility-trusted, so use the target application's
            // explicit AXFrontmost attribute as a narrow fallback.
            let appElement = AXUIElementCreateApplication(targetPid)
            AXUIElementSetMessagingTimeout(appElement, 0.1)
            let axResult = AXUIElementSetAttributeValue(
                appElement,
                kAXFrontmostAttribute as CFString,
                true as CFTypeRef
            )
            DebugFileLogger.log(
                "stop: target AXFrontmost fallback result=\(axResult.rawValue) pid=\(targetPid)"
            )
        }
        // Switching back to an app on another macOS Space includes the desktop
        // animation, which regularly takes longer than 400 ms.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if target.isTerminated { return false }
            if isExpectedFrontmostApplication(pid: targetPid, bundleIdentifier: targetBundleID) {
                return true
            }
            usleep(20_000)
        }
        return !target.isTerminated
            && isExpectedFrontmostApplication(pid: targetPid, bundleIdentifier: targetBundleID)
    }

    nonisolated private static func isExpectedFrontmostApplication(
        pid: pid_t,
        bundleIdentifier: String
    ) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.processIdentifier == pid
            && frontmost.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
    }

    // MARK: - Speculative LLM (fire during recording pauses)

    private struct TimedLLMResult: Sendable {
        let text: String?
        let durationSeconds: Double
    }

    private var speculativeLLMTask: Task<TimedLLMResult, Never>?
    private var speculativeLLMText: String = ""
    private var speculativeDebounceTask: Task<Void, Never>?
    private var speculativeThrottle = SpeculativeLLMThrottle()
    /// Stores the last LLM error from the early/fresh LLM task, consumed once by stopRecording().
    private var pendingLLMError: Error?
    private var pendingSelectionAskRequestContext: SelectionAskRequestContext?
    private enum CompletionIntent: Sendable {
        case normal
        case cancelled
    }

    /// Both the clipboard policy and the completion intent are frozen per
    /// session so a Settings change cannot alter an in-flight recording.
    private var clipboardOutputPolicy = ClipboardOutputPolicy.defaultValue
    private var completionIntent: CompletionIntent = .normal
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
            await stopRecording(endTarget: captureAutomaticEndTarget())
        case .recovering:
            _ = await handleRecoveryHotkeyPress()
        default:
            logger.warning("toggleRecording ignored in state: \(String(describing: self.state))")
        }
    }

    func handleRecoveryHotkeyPress() async -> RecoveryHotkeyAction {
        guard state == .recovering else { return .notRecovering }

        if !recoveryInterruptPromptShown {
            recoveryInterruptPromptShown = true
            onASREvent?(.recoveryPrompt(
                text: recoveryPartialText,
                message: L(
                    "正在恢复上一次识别。继续按下将打断当前恢复并重新开始录音。",
                    "Recovering the previous dictation. Press again to interrupt recovery and start a new recording."
                )
            ))
            return .prompted
        }

        await interruptRecoveryForRestart()
        return .interrupted
    }

    private func interruptRecoveryForRestart() async {
        DebugFileLogger.log("recovery interrupted by hotkey")
        recoveryTask?.cancel()
        recoveryTask = nil
        if !recoveryPartialText.isEmpty {
            await saveRecoveryHistory(status: "recovery_interrupted", finalText: recoveryPartialText)
        }
        onASREvent?(.recoveryInterrupted(
            text: recoveryPartialText,
            message: L("已停止恢复，开始新的录音", "Recovery stopped. Starting a new recording.")
        ))
        clearRecoveryState()
        state = .idle
        currentTranscript = .empty
        warmUpASRConnection()
    }

    // MARK: - Start

    func startRecording(
        mode: ProcessingMode = .direct,
        requestedAt: ContinuousClock.Instant? = nil,
        injectionTargetPreference: InjectionTargetPreference = .recordingStart
    ) async {
        await startRecording(
            purpose: .input(mode),
            requestedAt: requestedAt,
            injectionTargetPreference: injectionTargetPreference
        )
    }

    func startReviseRecording(_ target: RevisePreparedTarget) async {
        await startRecording(purpose: .revise(target))
    }

    func cancelReviseRecording() async {
        if case .revise(let prepared) = recordingPurpose {
            await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
        }
        await forceReset()
        onASREvent?(.reviseCancelled)
    }

    func startRecording(
        purpose: RecordingPurpose,
        requestedAt: ContinuousClock.Instant? = nil,
        injectionTargetPreference: InjectionTargetPreference = .recordingStart
    ) async {
        let recordingRequestStartedAt = requestedAt ?? ContinuousClock.now
        if state == .finishing || state == .injecting || state == .postProcessing || state == .recovering {
            NSLog("[Session] startRecording: blocked, current session still processing (state=%@)", String(describing: state))
            DebugFileLogger.log("startRecording blocked: still processing state=\(state)")
            return
        }
        if state != .idle {
            NSLog("[Session] startRecording: forcing reset from state=%@", String(describing: state))
            DebugFileLogger.log("session forcing reset from state=\(state)")
            await forceReset()
        }

        await MainActor.run {
            CorrectionLearningCoordinator.shared.finalizeBeforeNextRecording()
        }

        self.recordingPurpose = purpose
        self.injectionTargetPreference = injectionTargetPreference
        clipboardOutputPolicy = ClipboardOutputPolicy.current()
        completionIntent = .normal
        stoppedByMaxDuration = false
        // Determine the injection target fresh for every recording. Never inherit
        // the previous session's target: if Type4Me itself is frontmost (e.g. a URL
        // Scheme command activated the app), we deliberately clear the target rather
        // than reusing a stale one, so we can never re-activate and paste into the
        // wrong application. In that case the natural frontmost app at paste time
        // receives the text, guarded by the frontmost confirmation below.
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let isSelf = frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        if isSelf {
            targetApplication = nil
            targetBundleId = nil
        } else {
            targetApplication = frontmostApplication
            targetBundleId = frontmostApplication?.bundleIdentifier
        }
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

        sessionGeneration &+= 1
        let myGeneration = sessionGeneration

        historyLLMProvider = nil
        historyLLMModel = nil
        historyASRDurationSeconds = nil
        historyLLMDurationSeconds = nil
        clearIntelliSenseSessionContext()
        clearTranslationSessionContext()
        intelliSenseGuardRejected = false

        switch purpose {
        case .input(let mode):
            let effectiveMode = ASRProviderRegistry.resolvedMode(for: mode, provider: provider)
            if effectiveMode.executionKind != .selectionAsk {
                pendingSelectionAskRequestContext = nil
            } else if pendingSelectionAskRequestContext == nil {
                pendingSelectionAskRequestContext = SelectionAskRequestContext(
                    requestID: UUID(),
                    sessionID: nil,
                    turnID: nil,
                    selectedText: "",
                    overridesSelectedText: false,
                    conversationContext: "",
                    contextWasTruncated: false
                )
            }
            self.currentMode = effectiveMode

            if effectiveMode.id == ProcessingMode.translationModeId {
                let code = effectiveMode.translationTargetLanguageCode
                    ?? TranslationLanguage.english.rawValue
                guard let target = TranslationLanguage(rawValue: code) else {
                    SoundFeedback.playError()
                    state = .idle
                    onASREvent?(.error(TranslationError.unsupportedTarget(code)))
                    onASREvent?(.completed)
                    return
                }
                translationRequestContext = TranslationRequestContext(
                    generation: myGeneration,
                    target: target,
                    prompt: TranslationPromptBuilder.prompt(target: target)
                )
                DebugFileLogger.log(
                    "translation start target=\(target.rawValue) generation=\(myGeneration)"
                )
            }
            if effectiveMode.id == ProcessingMode.intelliSenseId {
                let settings = await IntelliSenseSettingsStore.shared.load()
                let recordingStartTarget = TargetApplicationContext(
                    processIdentifier: frontmostApplication?.processIdentifier,
                    bundleIdentifier: frontmostApplication?.bundleIdentifier,
                    displayName: frontmostApplication?.localizedName
                )
                let target = Self.resolvedIntelliSenseTarget(
                    preference: injectionTargetPreference,
                    recordingStartTarget: recordingStartTarget,
                    recordingEndTarget: nil
                )
                intelliSenseSettings = settings
                intelliSenseTarget = target
                intelliSenseStartedModeID = effectiveMode.id
                if let target {
                    intelliSenseContextTask = Task {
                        await IntelliSenseContextCapturer.capture(target: target, settings: settings)
                    }
                } else {
                    // The destination is intentionally unknown until the user
                    // stops a recording in the stop-time target mode.
                    intelliSenseContextTask = nil
                }
            }

        case .revise:
            pendingSelectionAskRequestContext = nil
        }

        // Capture prompt context beside credential loading and audio startup.
        // It is resolved only when a prompt or selection-aware action needs it.
        resetPromptContextCapture(for: purpose, generation: myGeneration)

        self.recordingStartTime = nil
        hasEmittedReadyForCurrentSession = false
        speculativeThrottle.reset()
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
                clearIntelliSenseSessionContext()
                return
            }
            // Verify required models are downloaded
            if !ModelManager.shared.areRequiredModelsAvailable() {
                NSLog("[Session] Required local models not downloaded for %@", provider.rawValue)
                SoundFeedback.playError()
                state = .idle
                onASREvent?(.error(NSError(domain: "Type4Me", code: -3, userInfo: [NSLocalizedDescriptionKey: L("请先下载识别模型", "Please download ASR models first")])))
                onASREvent?(.completed)
                clearIntelliSenseSessionContext()
                return
            }
        } else if let savedConfig = KeychainService.loadASRConfig(for: provider) {
            config = savedConfig
            NSLog("[Session] Loaded %@ credentials from file store", provider.rawValue)
        } else if provider == .volcano,
                  let volcConfig = Self.volcanoConfigFromEnvironment(
                      ProcessInfo.processInfo.environment
                  ) {
            // Env var fallback (volcano only, for dev convenience)
            do {
                try KeychainService.saveASRCredentials(for: .volcano, values: volcConfig.toCredentials())
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
            clearIntelliSenseSessionContext()
            return
        }

        self.currentConfig = config

        guard let client = ASRProviderRegistry.createClient(for: provider) else {
            NSLog("[Session] No client implementation for provider=%@", provider.rawValue)
            SoundFeedback.playError()
            state = .idle
            onASREvent?(.error(NSError(domain: "Type4Me", code: -2, userInfo: [NSLocalizedDescriptionKey: L("\(provider.displayName) 暂不支持", "\(provider.displayName) not yet supported")])))
            onASREvent?(.completed)
            clearIntelliSenseSessionContext()
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
            let captureResolution = AudioInputDevicePreferenceStore.cachedCaptureResolution()
            let selectedDeviceUID: String?
            switch captureResolution {
            case .explicitDevice(let uid):
                selectedDeviceUID = uid
            case .systemDefault:
                selectedDeviceUID = nil
            case .unavailable:
                throw AudioCaptureError.preferredInputDeviceUnavailable
            }
            let preferenceMode = AudioInputDevicePreferenceStore.mode().rawValue
            let priorityUIDs = AudioInputDevicePreferenceStore.priorityEntries().map(\.uid).joined(separator: ",")
            audioEngine.selectedDeviceUID = selectedDeviceUID
            DebugFileLogger.log(
                "audio input selected uid=\(selectedDeviceUID ?? "system-default") " +
                "mode=\(preferenceMode) priority=[\(priorityUIDs)]"
            )
            let audioEngineStartAt = ContinuousClock.now
            try audioEngine.start()
            NSLog("[Session] Audio engine started OK")
            let audioReadyAt = ContinuousClock.now
            DebugFileLogger.log(
                "audio engine started OK "
                    + "requestToReady=\(audioReadyAt - recordingRequestStartedAt) "
                    + "engineStart=\(audioReadyAt - audioEngineStartAt)"
            )
        } catch {
            NSLog("[Session] Audio engine start FAILED: %@", String(describing: error))
            DebugFileLogger.log("audio engine start failed: \(String(describing: error))")
            SoundFeedback.playError()
            await client.disconnect()
            self.asrClient = nil
            state = .idle
            onASREvent?(.error(error))
            onASREvent?(.completed)
            clearIntelliSenseSessionContext()
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
            // stopRecording() may intentionally disconnect the recognizer while
            // connect() is suspended. That cancellation belongs to the stopped
            // (or superseded) session and must not surface as an ASR failure.
            guard Self.shouldReportASRConnectFailure(
                expectedGeneration: myGeneration,
                currentGeneration: sessionGeneration,
                state: state
            ) else {
                DebugFileLogger.log(
                    "ASR connect ended after session stopped "
                        + "provider=\(provider.rawValue) gen=\(myGeneration) "
                        + "current=\(sessionGeneration) state=\(state) "
                        + "error=\(String(describing: error))"
                )
                await client.disconnect()
                if sessionGeneration == myGeneration {
                    self.asrClient = nil
                }
                return
            }
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
            clearIntelliSenseSessionContext()
            return
        }

        // Bail out if session was superseded or user stopped while we were connecting
        guard sessionGeneration == myGeneration, state == .recording else {
            DebugFileLogger.log("startRecording: zombie or state change after connect (gen=\(myGeneration) current=\(sessionGeneration) state=\(state)), bailing")
            await client.disconnect()
            if sessionGeneration == myGeneration {
                self.asrClient = nil
            }
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
        if !currentMode.prompt.isEmpty, let runtime = await resolveLLMRuntime() {
            Task { await runtime.client.warmUp(baseURL: runtime.config.baseURL) }
        }

        // Safety: auto-stop after maxRecordingDuration to prevent unbounded memory use
        maxDurationTask?.cancel()
        asrCleanupTask?.cancel()
        asrCleanupTask = nil
        asrCleanupGeneration = nil
        let recordingLimit = maxRecordingDuration(for: activeProvider)
        maxDurationTask = Task { [weak self, recordingLimit] in
            try? await Task.sleep(for: .seconds(recordingLimit))
            guard let self, !Task.isCancelled else { return }
            await self.autoStopIfRecording(limit: recordingLimit)
        }
    }

    func setSelectionAskRequestContext(_ context: SelectionAskRequestContext) {
        pendingSelectionAskRequestContext = context
    }

    /// Auto-stop triggered by max recording duration timer.
    private func autoStopIfRecording(limit: TimeInterval) async {
        guard state == .recording else { return }
        DebugFileLogger.log("max recording duration reached (\(limit)s), auto-stopping")
        stoppedByMaxDuration = true
        await stopRecording(endTarget: captureAutomaticEndTarget())
    }

    private func captureAutomaticEndTarget() -> TextInjectionEngine.EndInjectionTarget? {
        guard injectionTargetPreference == .recordingEnd,
              currentMode.supportsOutputFormatting,
              completionIntent == .normal
        else { return nil }
        return TextInjectionEngine.captureEndInjectionTarget()
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
    func switchMode(to mode: ProcessingMode) async {
        let resolved = ASRProviderRegistry.resolvedMode(for: mode, provider: activeProvider)
        let previousModeID = currentMode.id
        if previousModeID != resolved.id {
            // A speculative result belongs to the prompt of the mode that
            // started it. Never reuse it after a cross-mode finish.
            speculativeDebounceTask?.cancel()
            speculativeDebounceTask = nil
            speculativeLLMTask?.cancel()
            speculativeLLMTask = nil
            speculativeLLMText = ""
            speculativeThrottle.reset()
            pendingLLMError = nil
            historyLLMProvider = nil
            historyLLMModel = nil
            historyLLMDurationSeconds = nil
        }
        if currentMode.id == ProcessingMode.intelliSenseId,
           resolved.id != ProcessingMode.intelliSenseId {
            clearIntelliSenseSessionContext()
        } else if currentMode.id != ProcessingMode.intelliSenseId,
                  resolved.id == ProcessingMode.intelliSenseId {
            clearIntelliSenseSessionContext()
            intelliSenseSettings = await IntelliSenseSettingsStore.shared.load()
            intelliSenseStartedModeID = currentMode.id
            intelliSenseCrossModeFallback = true
        }
        if previousModeID != ProcessingMode.translationModeId,
           resolved.id == ProcessingMode.translationModeId {
            let code = resolved.translationTargetLanguageCode ?? TranslationLanguage.english.rawValue
            if let target = TranslationLanguage(rawValue: code) {
                translationRequestContext = TranslationRequestContext(
                    generation: sessionGeneration,
                    target: target,
                    prompt: TranslationPromptBuilder.prompt(target: target)
                )
            } else {
                translationRequestContext = nil
            }
        } else if previousModeID == ProcessingMode.translationModeId,
                  resolved.id != ProcessingMode.translationModeId {
            clearTranslationSessionContext()
        }
        currentMode = resolved
        schedulePromptContextCaptureIfNeeded(
            for: resolved,
            generation: sessionGeneration
        )
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

    /// Mark the current result as cancelled. Recognition and history still
    /// proceed; the frozen clipboard policy decides whether it is retained.
    func abortInjection() {
        completionIntent = .cancelled
        if cancellationSkipsLLM {
            cancelAllSpeculativeLLM()
        }
        DebugFileLogger.log(
            "abortInjection: policy=\(clipboardOutputPolicy.rawValue) "
                + "processesCancelled=\(clipboardOutputPolicy.processesCancelledResult)"
        )
    }

    /// Raw transcript and never-copy cancellation still wait for final ASR,
    /// but they have no LLM phase. The UI can hide the processing indicator
    /// while that non-interactive finalization completes.
    func cancellationHidesProcessingUI() -> Bool {
        usesClipboardOutputPolicy && !clipboardOutputPolicy.processesCancelledResult
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
        let actionContext = MacActionContext(selectedText: promptContext.selectedText)
        guard let result = await ActionRegistry.dispatch(
            name: toolCall.name,
            args: toolCall.arguments,
            context: actionContext
        ) else {
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
            asrModel: currentASRModelLabel(for: activeProvider),
            llmProvider: historyLLMProvider,
            llmModel: historyLLMModel,
            asrDurationSeconds: historyASRDurationSeconds,
            llmDurationSeconds: historyLLMDurationSeconds
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

    private func completeSelectionAsk(
        questionText: String,
        recordingStartTime: Date?,
        activeProvider: ASRProvider,
        myGeneration: Int
    ) async {
        await resolvePromptContextIfNeeded(generation: myGeneration)
        guard sessionGeneration == myGeneration else { return }

        let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestContext = pendingSelectionAskRequestContext ?? SelectionAskRequestContext(
            requestID: UUID(),
            sessionID: nil,
            turnID: nil,
            selectedText: "",
            overridesSelectedText: false,
            conversationContext: "",
            contextWasTruncated: false
        )
        pendingSelectionAskRequestContext = nil
        let capturedContextText = SelectionAskPromptBuilder.contextText(from: promptContext)
        let contextText = requestContext.overridesSelectedText
            ? requestContext.selectedText
            : capturedContextText
        let contextSource: SelectionAskPromptBuilder.ContextSource = contextText.isEmpty ? .none : .selection
        let conversationContext = requestContext.conversationContext
        let requestID = requestContext.requestID

        guard !question.isEmpty else {
            onASREvent?(.selectionAskStarted(
                requestID: requestID,
                question: "",
                selectedText: contextText,
                contextWasTruncated: false
            ))
            onASREvent?(.selectionAskAnswerFailed(
                requestID: requestID,
                message: L("没有识别到问题，请重试。", "No question was recognized. Please try again.")
            ))
            onASREvent?(.completed)
            finishSelectionAskSession(myGeneration: myGeneration)
            return
        }

        guard let runtime = await resolveLLMRuntime() else {
            onASREvent?(.selectionAskStarted(
                requestID: requestID,
                question: question,
                selectedText: contextText,
                contextWasTruncated: false
            ))
            onASREvent?(.selectionAskAnswerFailed(
                requestID: requestID,
                message: L("请先在设置中配置 LLM。", "Please configure an LLM provider in Settings first.")
            ))
            onASREvent?(.completed)
            finishSelectionAskSession(myGeneration: myGeneration)
            return
        }

        let fittedRequest = AskAnythingContextBuilder.fitRequest(
            selectedText: contextText,
            conversationText: conversationContext,
            currentQuestion: question,
            promptTemplateCharacters: currentMode.prompt.count
        )
        state = .postProcessing
        onASREvent?(.selectionAskStarted(
            requestID: requestID,
            question: question,
            selectedText: contextText,
            contextWasTruncated: requestContext.contextWasTruncated || fittedRequest.wasTruncated
        ))

        let llmConfig = runtime.config
        let client = runtime.client
        let effectiveContext = PromptContext(selectedText: fittedRequest.selectedText, clipboardText: "")
        let prompt = SelectionAskPromptBuilder.requestText(
            mode: currentMode,
            context: effectiveContext,
            question: question,
            conversationContext: fittedRequest.conversationText
        )
        DebugFileLogger.log(
            "selectionAsk LLM request requestID=\(requestID.uuidString) "
                + "provider=\(KeychainService.selectedLLMProvider.rawValue) "
                + "model=\(llmConfig.model) contextSource=\(contextSource.rawValue) "
                + "questionChars=\(question.count) contextChars=\(fittedRequest.selectedText.count) "
                + "conversationChars=\(fittedRequest.conversationText.count) "
                + "contextTruncated=\(requestContext.contextWasTruncated || fittedRequest.wasTruncated)"
        )
        do {
            _ = try await client.processStreaming(
                text: prompt,
                prompt: "{text}",
                config: llmConfig
            ) { [weak self] delta in
                await self?.emitSelectionAskDelta(delta, requestID: requestID)
            }
            onASREvent?(.selectionAskAnswerCompleted(requestID: requestID))
        } catch {
            onASREvent?(.selectionAskAnswerFailed(
                requestID: requestID,
                message: userFacingLLMError(error)
            ))
        }

        onASREvent?(.completed)
        finishSelectionAskSession(myGeneration: myGeneration)
    }

    private func emitSelectionAskDelta(_ delta: String, requestID: UUID) {
        guard !delta.isEmpty else { return }
        onASREvent?(.selectionAskAnswerDelta(requestID: requestID, delta: delta))
    }

    private func finishSelectionAskSession(myGeneration: Int) {
        if sessionGeneration == myGeneration, state != .idle {
            state = .idle
            hasEmittedReadyForCurrentSession = false
            currentTranscript = .empty
            warmUpASRConnection()
        }
        resetSpeculativeLLM()
        SystemVolumeManager.restore()
    }

    private func userFacingLLMError(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
    }

    func stopRecording(
        endTarget: TextInjectionEngine.EndInjectionTarget? = nil
    ) async {
        let myGeneration = sessionGeneration
        guard state == .recording else {
            logger.warning("stopRecording called but state is \(String(describing: self.state))")
            return
        }

        // Set state BEFORE any await to prevent a second stop from
        // slipping through the guard during the suspension point.
        state = .finishing
        let endTarget = injectionTargetPreference == .recordingEnd
            && currentMode.supportsOutputFormatting
            && completionIntent == .normal
            ? endTarget
            : nil
        prepareStopTimeTargetContext(endTarget)
        if let translationContext = translationRequestContext,
           currentMode.id == ProcessingMode.translationModeId {
            onASREvent?(.processingLabelOverride(L(
                "正在翻译为\(translationContext.target.displayName)…",
                "Translating to \(translationContext.target.displayName)…"
            )))
        }
        maxDurationTask?.cancel()
        maxDurationTask = nil

        let stopT0 = ContinuousClock.now
        let asrFinishingStartedAt = Date()
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
            if case .revise(let prepared) = recordingPurpose {
                await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
                onASREvent?(.reviseFailed(.instructionEmpty))
                cleanupSessionAfterRevise(myGeneration: myGeneration)
                return
            }
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
                    if case .revise(let prepared) = recordingPurpose {
                        await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
                        onASREvent?(.reviseFailed(.instructionEmpty))
                        cleanupSessionAfterRevise(myGeneration: myGeneration)
                        return
                    }
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
                        // Cancellation means a newer session no longer wants to
                        // wait for the drain; disconnect is still mandatory so
                        // the previous client's resources cannot be stranded.
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

        // Keep speculative LLM task alive — we'll compare its input text
        // against the final ASR transcript after full teardown.
        cancelSpeculativeLLM()
        var needsLLM = Self.shouldRunInputModeLLM(
            recordingPurpose: recordingPurpose,
            mode: currentMode
        )
        if cancellationSkipsLLM {
            needsLLM = false
            cancelAllSpeculativeLLM()
            clearHistoryLLMMetadata()
            DebugFileLogger.log("stop: cancelled output skips LLM")
        }

        // Early label override for short text exemption (语音润色 only).
        // Use streaming transcript to update UI immediately, before ASR teardown,
        // so the floating bar doesn't flash "润色中" → "校准中".
        if needsLLM && currentMode.shortTextExemption > 0 {
            let exemptionThreshold = currentMode.shortTextExemption
            if exemptionThreshold > 0 {
                let streamingText = currentTranscript.composedText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if streamingText.count < exemptionThreshold {
                    onASREvent?(.processingLabelOverride(L("校准中", "Calibrating")))
                }
            }
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
                    // A new recording may cancel this wait, but it must not
                    // cancel ownership cleanup for the previous ASR client.
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
        historyASRDurationSeconds = max(0, Date().timeIntervalSince(asrFinishingStartedAt))

        // Now that we have the final transcript, decide whether to reuse
        // the speculative LLM result or fire a fresh request.
        let canEarlyLLM = providerIsStreaming
        var earlyLLMTask: Task<TimedLLMResult, Never>?
        if needsLLM && canEarlyLLM {
            var finalASRText = currentTranscript.displayText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            finalASRText = SnippetStorage.applyEffective(to: finalASRText, bundleId: targetBundleId)

            // Short text exemption: skip LLM for short texts (per-mode threshold)
            let exemptionThreshold = currentMode.shortTextExemption
            if exemptionThreshold > 0 && finalASRText.count < exemptionThreshold {
                DebugFileLogger.log("stop: short text exemption (\(finalASRText.count) < \(exemptionThreshold) chars), skipping LLM")
                needsLLM = false
                historyLLMProvider = nil
                historyLLMModel = nil
                historyLLMDurationSeconds = nil
                onASREvent?(.processingLabelOverride(L("校准中", "Calibrating")))
            }

            let speculativeDiff = TranscriptDiff.classify(source: speculativeLLMText, final: finalASRText)
            DebugFileLogger.log(
                "stop: needsLLM=\(needsLLM) mode=\(currentMode.name) text=\(finalASRText.count)chars specDiff=\(speculativeDiff.type.rawValue)"
            )
            if needsLLM && !finalASRText.isEmpty {
                if speculativeDiff.canReuseLLMResult, let specTask = speculativeLLMTask {
                    // Final transcript is semantically equivalent to speculative input — reuse (may already be done!)
                    earlyLLMTask = specTask
                    state = .postProcessing
                    DebugFileLogger.log("stop: reusing speculative LLM +\(ContinuousClock.now - stopT0)")
                } else {
                    // Final transcript differs from speculative input (tail words arrived),
                    // discard stale result and fire fresh LLM with complete text.
                    speculativeLLMTask?.cancel()
                    historyLLMProvider = nil
                    historyLLMModel = nil
                    historyLLMDurationSeconds = nil
                    if let runtime = await resolveLLMRuntime() {
                        rememberHistoryLLM(runtime)
                        let llmConfig = runtime.config
                        let prompt = await promptForCurrentMode(text: finalASRText)
                        let inputBoundary = llmInputBoundaryForCurrentMode()
                        let client = runtime.client
                        state = .postProcessing
                        if finalASRText != speculativeLLMText {
                            DebugFileLogger.log("stop: final transcript changed (spec=\(speculativeLLMText.count)chars final=\(finalASRText.count)chars), firing fresh LLM")
                        }
                        DebugFileLogger.log("stop: fresh LLM firing mode=\(currentMode.name) model=\(llmConfig.model) with \(finalASRText.count) chars +\(ContinuousClock.now - stopT0)")
                        let requestStartedAt = Date()
                        earlyLLMTask = Task {
                            do {
                                let result = try await client.process(
                                    text: finalASRText,
                                    prompt: prompt,
                                    config: llmConfig,
                                    inputBoundary: inputBoundary
                                )
                                DebugFileLogger.log("stop: fresh LLM done \(result.count) chars +\(ContinuousClock.now - stopT0)")
                                return TimedLLMResult(
                                    text: result,
                                    durationSeconds: max(0, Date().timeIntervalSince(requestStartedAt))
                                )
                            } catch {
                                DebugFileLogger.log("stop: fresh LLM FAILED +\(ContinuousClock.now - stopT0) error=\(error)")
                                self.setPendingLLMError(error)
                                return TimedLLMResult(
                                    text: nil,
                                    durationSeconds: max(0, Date().timeIntervalSince(requestStartedAt))
                                )
                            }
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
                onASREvent?(.processingResult(text: partialText.isEmpty ? L("重新识别中...", "Retrying recognition...") : partialText))
                if let batchText = await attemptBatchFallback(audio: fullAudio, config: config, provider: activeProvider) {
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
            historyASRDurationSeconds = max(0, Date().timeIntervalSince(asrFinishingStartedAt))
        }
        uploadFailureFlag = nil
        lastStreamingError = nil

        currentTranscript = Self.resolveEffectiveTranscript(
            currentTranscript: currentTranscript,
            providerIsStreaming: providerIsStreaming
        )

        // Combine confirmed segments + any trailing unconfirmed partial.
        let effectiveText = currentTranscript.displayText
        currentConfig = nil

        if !effectiveText.isEmpty {
            let rawText = effectiveText
            var finalText = effectiveText
            var processedText: String? = nil
            var llmFailed = false

            if case .revise(let prepared) = recordingPurpose {
                let asrDuration = recordingStartTime.map { Date().timeIntervalSince($0) }
                await completeRevise(
                    prepared: prepared,
                    rawInstruction: rawText,
                    asrDuration: asrDuration,
                    myGeneration: myGeneration
                )
                return
            }

            if currentMode.executionKind == .selectionAsk {
                await completeSelectionAsk(
                    questionText: rawText,
                    recordingStartTime: recordingStartTime,
                    activeProvider: activeProvider,
                    myGeneration: myGeneration
                )
                return
            }

            // Apply snippet replacements before LLM (e.g. "我的邮箱" → actual email)
            finalText = SnippetStorage.applyEffective(to: finalText, bundleId: targetBundleId)
            let intelliSenseGuardInput = finalText

            if cancellationSkipsLLM {
                // A cancellation may arrive while ASR teardown is awaiting.
                // Discard any speculative result and retain the final ASR text.
                needsLLM = false
                earlyLLMTask?.cancel()
                earlyLLMTask = nil
                cancelAllSpeculativeLLM()
                clearHistoryLLMMetadata()
                finalText = rawText
                DebugFileLogger.log("stop: cancellation received before LLM completion, using raw ASR")
            }

            // Short text exemption (for non-streaming providers, per-mode threshold)
            if needsLLM && earlyLLMTask == nil && currentMode.shortTextExemption > 0 {
                let exemptionThreshold = currentMode.shortTextExemption
                if exemptionThreshold > 0 && finalText.count < exemptionThreshold {
                    DebugFileLogger.log("stop: short text exemption (\(finalText.count) < \(exemptionThreshold) chars), skipping LLM (sync path)")
                    needsLLM = false
                    historyLLMProvider = nil
                    historyLLMModel = nil
                    historyLLMDurationSeconds = nil
                    onASREvent?(.processingLabelOverride(L("校准中", "Calibrating")))
                }
            }

            // LLM post-processing: prefer early result (fired at stop time),
            // fall back to synchronous call for very short recordings where
            // no streaming text was available yet.
            if let earlyTask = earlyLLMTask {
                state = .postProcessing
                DebugFileLogger.log("stop: awaiting early LLM result +\(ContinuousClock.now - stopT0)")

                // Timeout: don't wait more than 15s for LLM
                let earlyOutcome: TimedLLMResult = await withCheckedContinuation { continuation in
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
                            continuation.resume(returning: TimedLLMResult(text: nil, durationSeconds: 15))
                        }
                    }
                }
                historyLLMDurationSeconds = earlyOutcome.durationSeconds
                let earlyResult = earlyOutcome.text

                if let result = earlyResult, !result.isEmpty {
                    DebugFileLogger.log("stop: early LLM result received \(result.count) chars +\(ContinuousClock.now - stopT0)")
                    let cleaned = result
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
                    if currentMode.id == ProcessingMode.translationModeId {
                        do {
                            let translated = try await resolveTranslationOutputWithRetry(
                                cleaned,
                                sourceText: finalText
                            )
                            processedText = translated
                            finalText = translated
                            onASREvent?(.processingResult(text: translated))
                        } catch {
                            if cancellationSkipsLLM {
                                DebugFileLogger.log(
                                    "stop: cancelled raw output ignores translation failure"
                                )
                            } else {
                                await failTranslation(error, rawText: rawText, myGeneration: myGeneration)
                                return
                            }
                        }
                    } else {
                        let guarded = applyIntelliSenseGuard(
                            output: cleaned,
                            input: intelliSenseGuardInput
                        )
                        processedText = guarded.rejected ? nil : guarded.text
                        finalText = guarded.text
                        onASREvent?(.processingResult(text: guarded.text))
                    }
                } else {
                    let err = pendingLLMError ?? LLMError.emptyResponse(nil)
                    DebugFileLogger.log("stop: early LLM failed: \(err)")
                    pendingLLMError = nil
                    if currentMode.id == ProcessingMode.translationModeId {
                        if cancellationSkipsLLM {
                            DebugFileLogger.log(
                                "stop: cancelled raw output ignores unavailable translation LLM"
                            )
                        } else {
                            await failTranslation(
                                TranslationError.llmUnavailable,
                                rawText: rawText,
                                myGeneration: myGeneration
                            )
                            return
                        }
                    }
                    llmFailed = true
                    onASREvent?(.processingResult(text: rawText))
                }
            } else if needsLLM {
                state = .postProcessing
                if let runtime = await resolveLLMRuntime() {
                    rememberHistoryLLM(runtime)
                    let llmConfig = runtime.config
                    DebugFileLogger.log("stop: sync LLM firing mode=\(currentMode.name) model=\(llmConfig.model) with \(finalText.count) chars")
                    let client = runtime.client
                    let prompt = await promptForCurrentMode(text: finalText)
                    let inputBoundary = llmInputBoundaryForCurrentMode()
                    let textForLLM = finalText

                    let requestStartedAt = Date()
                    let llmOutcome: TimedLLMResult = await withCheckedContinuation { continuation in
                        let finished = OSAllocatedUnfairLock(initialState: false)
                        let llmTask = Task {
                            do {
                                let result = try await client.process(
                                    text: textForLLM,
                                    prompt: prompt,
                                    config: llmConfig,
                                    inputBoundary: inputBoundary
                                )
                                return TimedLLMResult(
                                    text: result.isEmpty ? nil : result,
                                    durationSeconds: max(0, Date().timeIntervalSince(requestStartedAt))
                                )
                            } catch {
                                DebugFileLogger.log("stop: sync LLM FAILED: \(error)")
                                return TimedLLMResult(
                                    text: nil,
                                    durationSeconds: max(0, Date().timeIntervalSince(requestStartedAt))
                                )
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
                                continuation.resume(returning: TimedLLMResult(text: nil, durationSeconds: 15))
                            }
                        }
                    }
                    historyLLMDurationSeconds = llmOutcome.durationSeconds
                    let llmResult = llmOutcome.text

                    if let result = llmResult {
                        let cleaned = result
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
                        if currentMode.id == ProcessingMode.translationModeId {
                            do {
                                let translated = try await resolveTranslationOutputWithRetry(
                                    cleaned,
                                    sourceText: finalText
                                )
                                processedText = translated
                                finalText = translated
                                onASREvent?(.processingResult(text: translated))
                            } catch {
                                if cancellationSkipsLLM {
                                    DebugFileLogger.log(
                                        "stop: cancelled raw output ignores translation failure"
                                    )
                                } else {
                                    await failTranslation(error, rawText: rawText, myGeneration: myGeneration)
                                    return
                                }
                            }
                        } else {
                            let guarded = applyIntelliSenseGuard(
                                output: cleaned,
                                input: intelliSenseGuardInput
                            )
                            processedText = guarded.rejected ? nil : guarded.text
                            finalText = guarded.text
                            onASREvent?(.processingResult(text: guarded.text))
                        }
                    } else {
                        if currentMode.id == ProcessingMode.translationModeId {
                            if cancellationSkipsLLM {
                                DebugFileLogger.log(
                                    "stop: cancelled raw output ignores unavailable translation LLM"
                                )
                            } else {
                                await failTranslation(
                                    TranslationError.llmUnavailable,
                                    rawText: rawText,
                                    myGeneration: myGeneration
                                )
                                return
                            }
                        }
                        llmFailed = true
                        onASREvent?(.processingResult(text: rawText))
                    }
                } else {
                    DebugFileLogger.log("stop: no LLM credentials")
                    if currentMode.id == ProcessingMode.translationModeId {
                        if cancellationSkipsLLM {
                            DebugFileLogger.log(
                                "stop: cancelled raw output ignores unavailable translation LLM"
                            )
                        } else {
                            await failTranslation(
                                TranslationError.llmUnavailable,
                                rawText: rawText,
                                myGeneration: myGeneration
                            )
                            return
                        }
                    }
                    llmFailed = true
                    onASREvent?(.processingResult(text: rawText))
                }
            }

            if cancellationSkipsLLM {
                // A pre-existing LLM request can finish while the user cancels.
                // Its result is intentionally ignored for raw/never policies.
                finalText = rawText
                processedText = nil
                llmFailed = false
                clearHistoryLLMMetadata()
            }

            finalText = formattedOutputText(finalText)

            state = .injecting
            let wasCancelled = completionIntent == .cancelled
            let retainsClipboardResult = clipboardOutputPolicy.retainsResult(
                forCancellation: wasCancelled
            )
            injectionEngine.clipboardRetention = retainsClipboardResult
                ? .retainResult
                : .restoreOriginal

            // Run injection on a detached task to avoid blocking the actor with usleep().
            // .finalized is emitted directly from the detached task so the UI updates
            // immediately after paste, without waiting for actor re-scheduling.
            let engine = injectionEngine
            let onEvent = self.onASREvent
            let recordId = UUID().uuidString
            let modeID = currentMode.id
            let sessionSettings = intelliSenseRequestContext?.settings ?? intelliSenseSettings
            let contextAvailability = intelliSenseRequestContext?.snapshot.availability
            let learningPlan = PostInjectionLearningPlan.resolve(
                settings: sessionSettings,
                modeID: modeID,
                startedModeID: intelliSenseStartedModeID,
                isCrossModeFallback: intelliSenseCrossModeFallback,
                aborted: wasCancelled,
                guardRejected: intelliSenseGuardRejected,
                contextAvailability: contextAvailability,
                targetBundleIdentifier: targetBundleId
            )
            let correctionLearningEnabled = learningPlan.correctionEnabled
            let expressionLearningEnabled = learningPlan.expressionLearningEnabled
            let shouldTrackLearning = learningPlan.shouldTrackInjection
            let observationAppCategory = intelliSenseRequestContext?.snapshot.appCategory
                ?? AppContextClassifier.classify(
                    bundleIdentifier: targetBundleId,
                    appName: nil
                )
            let targetApp = targetApplication
            let targetPreference = injectionTargetPreference
            let injectLog = "stop: injecting method=clipboard len=\(finalText.count) +\(ContinuousClock.now - stopT0)"
            let injectionResult: TrackedInjectionResult = await withCheckedContinuation { continuation in
                Task.detached {
                    let result: TrackedInjectionResult
                    if wasCancelled, retainsClipboardResult {
                        engine.copyToClipboard(finalText)
                        DebugFileLogger.log("stop: cancelled result retained in clipboard & history")
                        result = TrackedInjectionResult(
                            outcome: .copiedToClipboard,
                            observationContext: nil
                        )
                    } else if wasCancelled {
                        DebugFileLogger.log("stop: cancelled result not retained in clipboard")
                        result = TrackedInjectionResult(
                            outcome: .discarded,
                            observationContext: nil
                        )
                    } else {
                        let plan = RecognitionSession.planInjectionTarget(
                            preference: targetPreference,
                            hasCapturedTarget: targetApp != nil,
                            isTerminated: targetApp?.isTerminated ?? false,
                            hasEndTarget: endTarget != nil
                        )
                        let allowInjection: Bool
                        switch plan {
                        case .injectIntoCurrentFrontmost:
                            allowInjection = true
                        case .activateAndConfirm:
                            allowInjection = targetApp.map(RecognitionSession.activateAndConfirmFrontmost) ?? false
                        case .injectIntoEndTarget:
                            allowInjection = endTarget != nil
                        case .failSafeClipboard:
                            allowInjection = false
                        }
                        if allowInjection {
                            DebugFileLogger.log(injectLog)
                            if shouldTrackLearning {
                                result = engine.injectTracked(
                                    finalText,
                                    sourceText: rawText,
                                    sourceRecordID: recordId,
                                    modeID: modeID,
                                    requiring: endTarget
                                )
                            } else {
                                result = TrackedInjectionResult(
                                    outcome: engine.inject(
                                        finalText,
                                        requiring: endTarget
                                    ),
                                    observationContext: nil
                                )
                            }
                        } else {
                            // Fail-safe: the intended target is gone or never became
                            // frontmost, so pasting now could leak the dictated text
                            // into the wrong app. Retain it in the clipboard instead.
                            engine.copyToClipboard(finalText)
                            let reason: String
                            if targetPreference == .recordingEnd {
                                reason = "end target missing or focus changed"
                            } else {
                                reason = plan == .failSafeClipboard
                                    ? "target terminated"
                                    : "target focus unconfirmed"
                            }
                            DebugFileLogger.log("stop: \(reason); retained in clipboard, paste skipped")
                            result = TrackedInjectionResult(
                                outcome: .copiedToClipboard,
                                observationContext: nil
                            )
                        }
                    }
                    // Notify UI immediately from this thread, before actor resumes
                    onEvent?(.finalized(text: finalText, injection: result.outcome))
                    DebugFileLogger.log("stop: finalized emitted from injection task")
                    // Restoring policies must restore even when there was no
                    // editable destination, otherwise a failed paste leaks text.
                    if !retainsClipboardResult && !wasCancelled {
                        engine.finishClipboardRestore()
                    }
                    continuation.resume(returning: result)
                }
            }

            #if HAS_CLOUD_SUBSCRIPTION
            if isCloudMode {
                Task { await CloudQuotaManager.shared.refresh(force: true) }
            }
            #endif

            // Save to history
            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            let status: String
            if wasCancelled {
                status = clipboardOutputPolicy.cancelledHistoryStatus
            }
            else if llmFailed { status = "llm_error" }
            else if needsBatchFallback { status = "stream_recovered" }
            else { status = "completed" }
            let intelliSenseTraceJSON = await makeIntelliSenseHistoryTraceJSON(
                input: rawText,
                finalText: finalText,
                processingFailed: llmFailed
            )
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
                asrModel: currentASRModelLabel(for: activeProvider),
                llmProvider: historyLLMProvider,
                llmModel: historyLLMModel,
                asrDurationSeconds: historyASRDurationSeconds,
                llmDurationSeconds: historyLLMDurationSeconds,
                intelliSenseTraceJSON: intelliSenseTraceJSON
            ))
            if injectionResult.outcome == .inserted,
               let context = injectionResult.observationContext {
                let sourceKind: ReviseSourceModeKind
                if currentMode.id == ProcessingMode.intelliSenseId {
                    sourceKind = .intelliSense
                } else if currentMode.id == ProcessingMode.translationModeId {
                    sourceKind = .translation
                } else if currentMode == .direct {
                    sourceKind = .direct
                } else {
                    sourceKind = .customText
                }
                await ReviseCoordinator.shared.registerTarget(
                    context: context,
                    sourceModeKind: sourceKind,
                    learningResumePlan: ReviseLearningResumePlan(shouldResume: shouldTrackLearning, modeID: currentMode.id)
                )

                if shouldTrackLearning {
                    await MainActor.run {
                        PostInjectionLearningCoordinator.shared.begin(
                            context,
                            options: PostInjectionLearningOptions(
                                correctionEnabled: correctionLearningEnabled,
                                expressionLearningEnabled: expressionLearningEnabled,
                                appCategory: observationAppCategory
                            )
                        )
                    }
                }
            } else {
                // A new output that cannot be tracked (AX-blind app, clipboard-only
                // fallback, or unverifiable range) must invalidate the previous
                // app's target. Otherwise Revise reports a misleading focus error
                // and risks carrying stale target identity across applications.
                await ReviseCoordinator.shared.clearTarget()
                DebugFileLogger.log("revise_target: cleared reason=untracked_injection")
            }
            KeychainService.addASRUsage(seconds: duration)

            // Note: cancellation and LLM-failure details are already conveyed
            // through the .finalized event's InjectionOutcome / completionMessage.
            // No separate .error emission here to avoid green→red UI flash.

        } else {
            // No text recognized: skip history entry (don't save empty records)
            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            DebugFileLogger.log("stop: no text recognized (duration=\(duration)s), skipping history entry")
            if case .revise(let prepared) = recordingPurpose {
                await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
                onASREvent?(.reviseFailed(.instructionEmpty))
                cleanupSessionAfterRevise(myGeneration: myGeneration)
                return
            }
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
    }

    // MARK: - Stream interruption recovery

    private func beginStreamRecovery(trigger: String) async {
        guard state == .recording else {
            DebugFileLogger.log("recovery ignored: state=\(state) trigger=\(trigger)")
            return
        }

        let myGeneration = sessionGeneration
        let provider = activeProvider
        let config = currentConfig
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let rawPartialText = currentTranscript.displayText
        let partialText = normalizedRecoveryText(rawPartialText)
        let asrModel = currentASRModelLabel(for: provider)

        DebugFileLogger.log("recovery started trigger=\(trigger) partial=\(partialText.count) chars")
        state = .recovering
        recoveryInterruptPromptShown = false
        recoveryRecordId = UUID().uuidString
        recoveryCreatedAt = Date()
        recoveryRawPartialText = rawPartialText
        recoveryPartialText = partialText
        recoveryDuration = duration
        recoveryModeName = currentMode == .direct ? nil : currentMode.name
        recoveryProvider = provider
        recoveryASRModel = asrModel

        maxDurationTask?.cancel()
        maxDurationTask = nil
        cancelSpeculativeLLM()
        SystemVolumeManager.restore()

        audioEngine.stop()
        audioEngine.onAudioChunk = nil
        audioEngine.onAudioLevel = nil
        await finishAudioChunkPipeline(timeout: .milliseconds(250))
        let fullAudio = audioEngine.getRecordedAudio()

        eventConsumptionTask?.cancel()
        eventConsumptionTask = nil
        if let client = asrClient {
            Task.detached { await client.disconnect() }
        }
        asrClient = nil
        uploadFailureFlag = nil
        lastStreamingError = nil

        if !recoveryPartialText.isEmpty {
            await saveRecoveryHistory(status: "stream_partial_saved", finalText: recoveryPartialText)
            injectRecoveryPartial(recoveryPartialText)
        }

        onASREvent?(.recoveryStarted(
            text: partialText,
            message: L(
                "连接中断，已保留当前文字，正在用整段录音重试",
                "Connection interrupted. Current text was saved; retrying with the full recording."
            )
        ))

        guard sessionGeneration == myGeneration, state == .recovering else { return }
        guard !fullAudio.isEmpty, let config else {
            await finishRecovery(
                recoveredText: nil,
                generation: myGeneration,
                failureMessage: L(
                    "连接中断，已保留部分识别结果",
                    "Connection interrupted. Partial recognition was saved."
                )
            )
            return
        }

        recoveryTask?.cancel()
        recoveryTask = Task {
            let recovered = await self.attemptBatchFallback(
                audio: fullAudio,
                config: config,
                provider: provider
            )
            await self.finishRecovery(
                recoveredText: recovered,
                generation: myGeneration,
                failureMessage: L(
                    "连接中断，已保留部分识别结果",
                    "Connection interrupted. Partial recognition was saved."
                )
            )
        }
    }

    private func finishRecovery(
        recoveredText: String?,
        generation: Int,
        failureMessage: String
    ) async {
        guard state == .recovering, generation == sessionGeneration, !Task.isCancelled else {
            return
        }

        let recovered = recoveredText.map(normalizedRecoveryText)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let recovered, !recovered.isEmpty {
            if clipboardOutputPolicy.retainsNormalResult {
                injectionEngine.copyToClipboard(recovered)
            }
            currentTranscript = RecognitionTranscript(
                confirmedSegments: [recovered],
                partialText: "",
                authoritativeText: recovered,
                isFinal: true
            )
            await saveRecoveryHistory(status: "stream_recovered", finalText: recovered)
            KeychainService.addASRUsage(seconds: recoveryDuration)
            onASREvent?(.recoverySucceeded(
                text: recovered,
                message: L("已恢复完整识别", "Full recognition recovered")
            ))
            DebugFileLogger.log("recovery succeeded \(recovered.count) chars")
        } else {
            if !recoveryPartialText.isEmpty {
                await saveRecoveryHistory(status: "stream_partial_saved", finalText: recoveryPartialText)
                KeychainService.addASRUsage(seconds: recoveryDuration)
            }
            onASREvent?(.recoveryFailed(text: recoveryPartialText, message: failureMessage))
            DebugFileLogger.log("recovery failed, partial=\(recoveryPartialText.count) chars")
        }

        clearRecoveryState()
        state = .idle
        currentTranscript = .empty
        resetSpeculativeLLM()
        SystemVolumeManager.restore()
        warmUpASRConnection()
    }

    private func normalizedRecoveryText(_ text: String) -> String {
        formattedOutputText(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func formattedOutputText(_ text: String) -> String {
        Self.formattedOutputText(text, mode: currentMode)
    }

    private func injectRecoveryPartial(_ text: String) {
        let engine = injectionEngine
        let retainsClipboardResult = clipboardOutputPolicy.retainsNormalResult
        Task.detached {
            engine.clipboardRetention = retainsClipboardResult
                ? .retainResult
                : .restoreOriginal
            _ = engine.inject(text)
            if !retainsClipboardResult {
                engine.finishClipboardRestore()
            }
        }
    }

    private func saveRecoveryHistory(status: String, finalText: String) async {
        let recordId = recoveryRecordId ?? UUID().uuidString
        recoveryRecordId = recordId
        await historyStore.insert(HistoryRecord(
            id: recordId,
            createdAt: recoveryCreatedAt ?? Date(),
            durationSeconds: recoveryDuration,
            rawText: recoveryRawPartialText,
            processingMode: recoveryModeName,
            processedText: nil,
            finalText: finalText,
            status: status,
            characterCount: finalText.count,
            asrProvider: recoveryProvider.displayName,
            asrModel: recoveryASRModel
        ))
    }

    private func clearRecoveryState() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryInterruptPromptShown = false
        recoveryRecordId = nil
        recoveryCreatedAt = nil
        recoveryRawPartialText = ""
        recoveryPartialText = ""
        recoveryDuration = 0
        recoveryModeName = nil
        recoveryProvider = .volcano
        recoveryASRModel = nil
        currentConfig = nil
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

        // Notify UI layer for all non-ready events. Streaming errors during
        // recording become recoverable interruptions, not red error toasts.
        if case .error = event, state == .recording {
            // beginStreamRecovery surfaces the user-facing state.
        } else {
            onASREvent?(event)
        }

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
            if state == .recording && !currentMode.prompt.isEmpty && currentMode.executionKind == .recording {
                scheduleSpeculativeLLM()
            }

        case .error(let error):
            lastStreamingError = error
            logger.error("ASR error: \(error)")
            if state == .recording {
                Task { await self.beginStreamRecovery(trigger: "ASR error: \(error)") }
            }

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
                if lastStreamingError != nil || uploadFailureFlag?.failed == true {
                    NSLog("[Session] Server closed ASR after interruption, initiating recovery")
                    DebugFileLogger.log("server completed after streaming interruption")
                    Task { await self.beginStreamRecovery(trigger: "ASR completed after interruption") }
                } else if activeProvider != .grok {
                    NSLog("[Session] Server closed ASR while recording, initiating stop")
                    DebugFileLogger.log("server-initiated stop from recording state")
                    Task {
                        await self.stopRecording(
                            endTarget: self.captureAutomaticEndTarget()
                        )
                    }
                }
            }

        case .processingResult, .processingLabelOverride, .recoveryStarted,
             .recoveryPrompt, .recoverySucceeded, .recoveryFailed,
             .recoveryInterrupted, .finalized, .macActionResult,
             .selectionAskStarted, .selectionAskAnswerDelta,
             .selectionAskAnswerCompleted, .selectionAskAnswerFailed,
             .reviseProcessing, .reviseCompleted, .reviseFailed,
             .reviseCancelled, .reviseUndone:
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
                    Task { await self.beginStreamRecovery(trigger: "audio chunk send failed: \(error)") }
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
        // IntelliSense cannot know the relevant application or editor until
        // stop time in this mode. Reusing a request built from the start-time
        // app would make both processing and history attribution incorrect.
        if injectionTargetPreference == .recordingEnd,
           currentMode.id == ProcessingMode.intelliSenseId {
            return false
        }
        let provider = KeychainService.selectedLLMProvider
        guard provider.supportsSpeculativeProcessing else { return false }
        if let override = UserDefaults.standard.object(forKey: "tf_enableSpeculativeLLM") as? Bool {
            return override
        }
        return true
    }

    private func prepareStopTimeTargetContext(
        _ endTarget: TextInjectionEngine.EndInjectionTarget?
    ) {
        guard injectionTargetPreference == .recordingEnd else { return }

        let recordingEndTarget = endTarget.map { target in
            TargetApplicationContext(
                processIdentifier: target.processIdentifier,
                bundleIdentifier: target.bundleIdentifier,
                displayName: NSRunningApplication(
                    processIdentifier: target.processIdentifier
                )?.localizedName
            )
        }
        targetBundleId = recordingEndTarget?.bundleIdentifier

        guard currentMode.id == ProcessingMode.intelliSenseId,
              intelliSenseStartedModeID == ProcessingMode.intelliSenseId,
              !intelliSenseCrossModeFallback
        else { return }

        cancelAllSpeculativeLLM()
        speculativeThrottle.reset()
        pendingLLMError = nil
        clearHistoryLLMMetadata()
        intelliSenseContextTask?.cancel()
        intelliSenseContextTask = nil
        intelliSenseRequestContext = nil
        intelliSenseLastProcessingResult = nil
        intelliSenseTarget = Self.resolvedIntelliSenseTarget(
            preference: injectionTargetPreference,
            recordingStartTarget: intelliSenseTarget,
            recordingEndTarget: recordingEndTarget
        )

        guard let target = intelliSenseTarget,
              let settings = intelliSenseSettings else {
            DebugFileLogger.log("intelli sense stop target unavailable")
            return
        }
        intelliSenseContextTask = Task {
            await IntelliSenseContextCapturer.capture(target: target, settings: settings)
        }
        DebugFileLogger.log(
            "intelli sense retargeted at stop bundle=\(target.bundleIdentifier ?? "unknown")"
        )
    }

    /// Debounce: after each transcript update, wait 800ms of silence before
    /// speculatively sending current text to LLM. If the user is still
    /// speaking, the timer resets.
    private func scheduleSpeculativeLLM() {
        guard case .input = recordingPurpose else { return }
        guard isSpeculativeLLMEnabled else { return }
        #if HAS_CLOUD_SUBSCRIPTION
        if isCloudMode { return }
        #endif
        var text = currentTranscript.composedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = SnippetStorage.applyEffective(to: text, bundleId: targetBundleId)
        scheduleSpeculativeLLM(text: text)
    }

    private func scheduleSpeculativeLLM(text: String) {
        guard case .input = recordingPurpose else { return }
        guard state == .recording else { return }
        switch speculativeThrottle.submit(text) {
        case .tooShort:
            DebugFileLogger.log("speculative LLM: skipped reason=tooShort len=\(text.count)")
            speculativeDebounceTask?.cancel()
            speculativeDebounceTask = nil
            return
        case .duplicate:
            DebugFileLogger.log("speculative LLM: skipped reason=duplicate len=\(text.count)")
            speculativeDebounceTask?.cancel()
            speculativeDebounceTask = nil
            return
        case .deltaTooSmall:
            DebugFileLogger.log(
                "speculative LLM: skipped reason=deltaTooSmall len=\(text.count) last=\(speculativeThrottle.lastStartedText.count)"
            )
            speculativeDebounceTask?.cancel()
            speculativeDebounceTask = nil
            return
        case .queued:
            DebugFileLogger.log("speculative LLM: queued pending len=\(text.count)")
            return
        case .debounce:
            break
        }

        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = Task { [text] in
            try? await Task.sleep(for: SpeculativeLLMThrottle.debounceDuration)
            guard !Task.isCancelled, state == .recording else { return }
            await fireSpeculativeLLM(text: text)
        }
    }

    private func fireSpeculativeLLM(text: String) async {
        guard speculativeThrottle.beginDebouncedRequest(for: text) else { return }
        let contextGeneration = sessionGeneration
        await resolvePromptContextIfNeeded(generation: contextGeneration)
        guard !Task.isCancelled,
              sessionGeneration == contextGeneration,
              state == .recording else {
            _ = speculativeThrottle.requestCompleted(input: text)
            return
        }
        guard let runtime = await resolveLLMRuntime() else {
            _ = speculativeThrottle.requestCompleted(input: text)
            return
        }
        rememberHistoryLLM(runtime)
        let llmConfig = runtime.config

        speculativeLLMText = text
        let prompt = await promptForCurrentMode(text: text)
        let inputBoundary = llmInputBoundaryForCurrentMode()

        let client = runtime.client
        DebugFileLogger.log("speculative LLM: firing mode=\(currentMode.name) model=\(llmConfig.model) with \(text.count) chars")
        let requestStartedAt = Date()
        speculativeLLMTask = Task {
            do {
                let result = try await client.process(
                    text: text,
                    prompt: prompt,
                    config: llmConfig,
                    inputBoundary: inputBoundary
                )
                guard !Task.isCancelled else {
                    _ = self.speculativeThrottle.requestCompleted(input: text)
                    return TimedLLMResult(
                        text: nil,
                        durationSeconds: max(0, Date().timeIntervalSince(requestStartedAt))
                    )
                }
                DebugFileLogger.log("speculative LLM: done \(result.count) chars")
                if let pending = self.speculativeThrottle.requestCompleted(input: text),
                   self.state == .recording {
                    self.scheduleSpeculativeLLM(text: pending)
                }
                return TimedLLMResult(
                    text: result,
                    durationSeconds: max(0, Date().timeIntervalSince(requestStartedAt))
                )
            } catch {
                _ = self.speculativeThrottle.requestCompleted(input: text)
                guard !Task.isCancelled else {
                    return TimedLLMResult(
                        text: nil,
                        durationSeconds: max(0, Date().timeIntervalSince(requestStartedAt))
                    )
                }
                DebugFileLogger.log("speculative LLM: failed \(error)")
                self.setPendingLLMError(error)
                return TimedLLMResult(
                    text: nil,
                    durationSeconds: max(0, Date().timeIntervalSince(requestStartedAt))
                )
            }
        }
    }

    private func rememberHistoryLLM(_ runtime: ResolvedLLMRuntime) {
        let provider = runtime.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = runtime.config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        historyLLMProvider = provider.isEmpty ? nil : String(provider.prefix(80))
        historyLLMModel = model.isEmpty ? nil : String(model.prefix(160))
    }

    private func cancelSpeculativeLLM() {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = nil
        // Don't cancel speculativeLLMTask here — stopRecording may reuse it
    }

    /// The clipboard policy applies only to text modes that ultimately target
    /// another application. Ask Anything, Revise and Mac Action keep their
    /// own cancellation semantics.
    private var usesClipboardOutputPolicy: Bool {
        guard case .input = recordingPurpose else { return false }
        return currentMode.supportsOutputFormatting
    }

    private var cancellationSkipsLLM: Bool {
        usesClipboardOutputPolicy
            && completionIntent == .cancelled
            && !clipboardOutputPolicy.processesCancelledResult
    }

    private func cancelAllSpeculativeLLM() {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = nil
        speculativeLLMTask?.cancel()
        speculativeLLMTask = nil
        speculativeLLMText = ""
    }

    private func clearHistoryLLMMetadata() {
        historyLLMProvider = nil
        historyLLMModel = nil
        historyLLMDurationSeconds = nil
    }

    private func setPendingLLMError(_ error: Error) {
        pendingLLMError = error
    }

    private func applyIntelliSenseGuard(
        output: String,
        input: String
    ) -> (text: String, rejected: Bool) {
        guard currentMode.id == ProcessingMode.intelliSenseId else {
            return (output, false)
        }
        let result = IntelliSenseOutputValidator.process(
            input: input,
            candidate: output,
            context: intelliSenseRequestContext?.snapshot
        )
        intelliSenseLastProcessingResult = result
        DebugFileLogger.log(
            "intelli sense validation candidateLength=\(output.count) finalLength=\(result.finalText.count) correction=\(result.correctionAnalysis.containsExplicitCorrection)"
        )
        switch result.decision {
        case .accept:
            return (result.finalText, false)
        case .acceptWithWarnings(let warnings):
            DebugFileLogger.log(
                "intelli sense guard warnings=\(warnings.map(\.rawValue).joined(separator: ","))"
            )
            return (result.finalText, false)
        case .reject(let reason):
            intelliSenseGuardRejected = true
            DebugFileLogger.log("intelli sense guard rejected reason=\(reason.rawValue)")
            return (result.finalText, true)
        }
    }

    private func llmInputBoundaryForCurrentMode() -> LLMInputBoundary {
        guard currentMode.id == ProcessingMode.formalWritingId else {
            return .inline
        }
        return .isolatedTranscript(LLMInputContext(
            prompt: currentMode.prompt,
            selectedText: promptContext.selectedText,
            clipboardText: promptContext.clipboardText
        ))
    }

    private func promptForCurrentMode(text: String? = nil) async -> String {
        await resolvePromptContextIfNeeded(generation: sessionGeneration)

        if currentMode.id == ProcessingMode.translationModeId,
           let context = translationRequestContext,
           context.generation == sessionGeneration {
            return context.prompt
        }
        guard currentMode.id == ProcessingMode.intelliSenseId else {
            if currentMode.id == ProcessingMode.formalWritingId {
                return promptContext.expandTrustedContextVariables(currentMode.prompt)
            }
            return promptContext.expandContextVariables(currentMode.prompt)
        }
        if intelliSenseCrossModeFallback {
            return IntelliSensePromptBuilder.baseTemplate
        }
        if let context = intelliSenseRequestContext,
           context.generation == sessionGeneration {
            return IntelliSensePromptBuilder.build(request: IntelliSenseRequest(
                text: text ?? "",
                context: context.snapshot,
                settings: context.settings,
                expressionProfile: context.expressionProfile
            ))
        }

        let settings: IntelliSenseSettings
        if let intelliSenseSettings {
            settings = intelliSenseSettings
        } else {
            settings = await IntelliSenseSettingsStore.shared.load()
        }
        let snapshot: IntelliSenseContextSnapshot
        if let task = intelliSenseContextTask {
            snapshot = await task.value
        } else if let target = intelliSenseTarget {
            snapshot = .appOnly(target)
        } else {
            snapshot = .appOnly(TargetApplicationContext(
                processIdentifier: nil,
                bundleIdentifier: targetBundleId,
                displayName: nil
            ))
        }
        guard intelliSenseStartedModeID == ProcessingMode.intelliSenseId else {
            return IntelliSensePromptBuilder.baseTemplate
        }
        let expressionProfile: EffectiveExpressionProfile?
        if settings.expressionLearningEnabled,
           snapshot.availability != .blacklisted,
           snapshot.availability != .sensitive {
            expressionProfile = await ExpressionProfileStore.shared.effectiveProfile(
                bundleIdentifier: snapshot.bundleIdentifier,
                category: snapshot.appCategory
            )
        } else {
            expressionProfile = nil
        }
        DebugFileLogger.log(
            "intelli sense context app=\(snapshot.appCategory.rawValue) control=\(snapshot.controlCategory.rawValue) availability=\(snapshot.availability.rawValue) beforeLength=\(snapshot.contextBeforeCursor.count) afterLength=\(snapshot.contextAfterCursor.count) truncated=\(snapshot.wasTruncated) layers=app:\(settings.applicationAwarenessEnabled),context:\(settings.contextAwarenessEnabled),expression:\(settings.expressionLearningEnabled),correction:\(settings.correctionDetectionEnabled) profileScope=\(expressionProfile?.sourceScope ?? "none") profileDirectives=\(expressionProfile?.directives.count ?? 0)"
        )
        intelliSenseRequestContext = IntelliSenseRequestContext(
            settings: settings,
            snapshot: snapshot,
            expressionProfile: expressionProfile,
            startingModeID: ProcessingMode.intelliSenseId,
            generation: sessionGeneration
        )
        return IntelliSensePromptBuilder.build(request: IntelliSenseRequest(
            text: text ?? "",
            context: snapshot,
            settings: settings,
            expressionProfile: expressionProfile
        ))
    }

    private func clearIntelliSenseSessionContext() {
        intelliSenseContextTask?.cancel()
        intelliSenseContextTask = nil
        intelliSenseRequestContext = nil
        intelliSenseSettings = nil
        intelliSenseTarget = nil
        intelliSenseStartedModeID = nil
        intelliSenseCrossModeFallback = false
        intelliSenseGuardRejected = false
        intelliSenseLastProcessingResult = nil
    }

    private func clearTranslationSessionContext() {
        translationRequestContext = nil
    }

    private func resolveTranslationOutputWithRetry(
        _ candidate: String,
        sourceText: String
    ) async throws -> String {
        guard let context = translationRequestContext,
              context.generation == sessionGeneration else {
            throw TranslationError.llmUnavailable
        }

        let initialDecision = TranslationOutputValidator.production.validate(
            candidate,
            target: context.target
        )
        switch translationValidationAction(
            initialDecision,
            attempt: .initial,
            target: context.target
        ) {
        case .accept:
            return candidate
        case .reject(let failure):
            throw translationError(for: failure, target: context.target)
        case .retry:
            break
        }

        guard let runtime = await resolveLLMRuntime() else {
            throw TranslationError.llmUnavailable
        }
        rememberHistoryLLM(runtime)
        let retryPrompt = TranslationPromptBuilder.retryPrompt(target: context.target)
        DebugFileLogger.log(
            "translation retry started reason=unexpectedLanguage target=\(context.target.rawValue) model=\(runtime.config.model) input=\(sourceText.count)chars"
        )
        let retryOutcome = await performTranslationRetry(
            text: sourceText,
            prompt: retryPrompt,
            runtime: runtime
        )
        historyLLMDurationSeconds = (historyLLMDurationSeconds ?? 0)
            + retryOutcome.durationSeconds
        guard let retryResult = retryOutcome.text else {
            throw TranslationError.llmUnavailable
        }

        let cleanedRetry = retryResult
        let retryDecision = TranslationOutputValidator.production.validate(
            cleanedRetry,
            target: context.target
        )
        switch translationValidationAction(
            retryDecision,
            attempt: .retry,
            target: context.target
        ) {
        case .accept:
            DebugFileLogger.log(
                "translation retry completed decision=accept target=\(context.target.rawValue) chars=\(cleanedRetry.count)"
            )
            return cleanedRetry
        case .retry:
            assertionFailure("Retry validation must not request another retry")
            throw TranslationError.unexpectedLanguage(context.target)
        case .reject(let failure):
            throw translationError(for: failure, target: context.target)
        }
    }

    private func translationValidationAction(
        _ decision: TranslationValidationDecision,
        attempt: TranslationValidationAttempt,
        target: TranslationLanguage
    ) -> TranslationValidationAction {
        let action = TranslationValidationPolicy.action(for: decision, attempt: attempt)
        switch (decision, action) {
        case (.accept, .accept):
            DebugFileLogger.log(
                "translation validation decision=accept target=\(target.rawValue) attempt=\(String(describing: attempt))"
            )
        case (.acceptWithWarning(let warning), .accept):
            DebugFileLogger.log(
                "translation validation decision=warning target=\(target.rawValue) attempt=\(String(describing: attempt)) warning=\(String(describing: warning))"
            )
        case (.acceptWithWarning(let warning), .retry):
            DebugFileLogger.log(
                "translation validation decision=retry target=\(target.rawValue) warning=\(String(describing: warning))"
            )
        case (_, .reject(let failure)):
            DebugFileLogger.log(
                "translation validation decision=reject target=\(target.rawValue) attempt=\(String(describing: attempt)) failure=\(String(describing: failure))"
            )
        default:
            break
        }
        return action
    }

    private func translationError(
        for failure: TranslationValidationFailure,
        target: TranslationLanguage
    ) -> TranslationError {
        switch failure {
        case .emptyOutput:
            return .emptyOutput
        case .unsafeStructure:
            return .unsafeOutput
        case .unexpectedLanguage:
            return .unexpectedLanguage(target)
        }
    }

    private func performTranslationRetry(
        text: String,
        prompt: String,
        runtime: ResolvedLLMRuntime
    ) async -> TimedLLMResult {
        let requestStartedAt = Date()
        return await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            let retryTask = Task {
                do {
                    let result = try await runtime.client.process(
                        text: text,
                        prompt: prompt,
                        config: runtime.config
                    )
                    DebugFileLogger.log(
                        "translation retry response chars=\(result.count) model=\(runtime.config.model)"
                    )
                    return TimedLLMResult(
                        text: result,
                        durationSeconds: max(0, Date().timeIntervalSince(requestStartedAt))
                    )
                } catch {
                    DebugFileLogger.log("translation retry failed error=\(error)")
                    return TimedLLMResult(
                        text: nil,
                        durationSeconds: max(0, Date().timeIntervalSince(requestStartedAt))
                    )
                }
            }
            Task {
                let result = await retryTask.value
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: result)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(15))
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    retryTask.cancel()
                    DebugFileLogger.log("translation retry timeout after 15s")
                    continuation.resume(returning: TimedLLMResult(
                        text: nil,
                        durationSeconds: 15
                    ))
                }
            }
        }
    }

    private func failTranslation(
        _ error: Error,
        rawText: String,
        myGeneration: Int
    ) async {
        DebugFileLogger.log("translation failed reason=\(String(describing: error))")
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        await historyStore.insert(HistoryRecord(
            id: UUID().uuidString,
            createdAt: Date(),
            durationSeconds: duration,
            rawText: rawText,
            processingMode: currentMode.name,
            processedText: nil,
            finalText: rawText,
            status: "translation_error",
            characterCount: rawText.count,
            asrProvider: activeProvider.displayName,
            asrModel: currentASRModelLabel(for: activeProvider),
            llmProvider: historyLLMProvider,
            llmModel: historyLLMModel,
            asrDurationSeconds: historyASRDurationSeconds,
            llmDurationSeconds: historyLLMDurationSeconds
        ))
        KeychainService.addASRUsage(seconds: duration)
        SoundFeedback.playError()
        onASREvent?(.error(error))
        onASREvent?(.completed)
        if sessionGeneration == myGeneration {
            state = .idle
            currentTranscript = .empty
            hasEmittedReadyForCurrentSession = false
        }
        resetSpeculativeLLM()
        clearTranslationSessionContext()
        SystemVolumeManager.restore()
        warmUpASRConnection()
    }

    private func makeIntelliSenseHistoryTraceJSON(
        input: String,
        finalText: String,
        processingFailed: Bool
    ) async -> String? {
        guard currentMode.id == ProcessingMode.intelliSenseId,
              intelliSenseStartedModeID == ProcessingMode.intelliSenseId,
              !intelliSenseCrossModeFallback else { return nil }

        let settings: IntelliSenseSettings
        if let frozenSettings = intelliSenseRequestContext?.settings ?? intelliSenseSettings {
            settings = frozenSettings
        } else {
            settings = await IntelliSenseSettingsStore.shared.load()
        }
        let snapshot: IntelliSenseContextSnapshot
        if let frozen = intelliSenseRequestContext?.snapshot {
            snapshot = frozen
        } else if let task = intelliSenseContextTask {
            snapshot = await task.value
        } else if let target = intelliSenseTarget {
            snapshot = .appOnly(target)
        } else {
            snapshot = .unavailable
        }
        let promptInput = IntelliSensePromptInput(
            context: snapshot,
            settings: settings,
            expressionProfile: intelliSenseRequestContext?.expressionProfile
        )
        let trace = IntelliSenseHistoryTraceBuilder.build(
            input: input,
            finalText: finalText,
            promptInput: promptInput,
            processingResult: intelliSenseLastProcessingResult,
            processingFailed: processingFailed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(trace) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func resetSpeculativeLLM() {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = nil
        speculativeLLMTask?.cancel()
        speculativeLLMTask = nil
        speculativeLLMText = ""
        speculativeThrottle.reset()
        clearIntelliSenseSessionContext()
        clearTranslationSessionContext()
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

    /// Batch / non-streaming providers must strictly produce finalized output.
    /// If a batch provider or its fallback failed without emitting isFinal,
    /// discard unconfirmed partial text to avoid injecting truncated fragments.
    static func resolveEffectiveTranscript(
        currentTranscript: RecognitionTranscript,
        providerIsStreaming: Bool
    ) -> RecognitionTranscript {
        if !providerIsStreaming && !currentTranscript.isFinal {
            return .empty
        }
        return currentTranscript
    }

    static func shouldRunInputModeLLM(
        recordingPurpose: RecordingPurpose,
        mode: ProcessingMode
    ) -> Bool {
        guard case .input = recordingPurpose else { return false }
        return !mode.prompt.isEmpty && mode.executionKind == .recording
    }

    // MARK: - Batch Fallback

    /// Try to transcribe full audio via the same provider.
    /// Soniox uses its async REST API (faster for complete audio); others use a fresh streaming connection.
    private func attemptBatchFallback(
        audio: Data,
        config: any ASRProviderConfig,
        provider: ASRProvider
    ) async -> String? {
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
        recoveryTask?.cancel()
        recoveryTask = nil
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
        promptContext = .empty
        capturedPromptContextRequirements = []
        pendingPromptContextCapture = nil
        pendingSelectionAskRequestContext = nil
        hasEmittedReadyForCurrentSession = false
        currentConfig = nil
        uploadFailureFlag = nil
        lastStreamingError = nil
        clearRecoveryState()
        SystemVolumeManager.restore()
    }

    // MARK: - Revise Implementation

    private func completeRevise(
        prepared: RevisePreparedTarget,
        rawInstruction: String,
        asrDuration: Double?,
        myGeneration: Int
    ) async {
        let trimmedInstruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
            onASREvent?(.reviseFailed(.instructionEmpty))
            cleanupSessionAfterRevise(myGeneration: myGeneration)
            return
        }

        // Check local deterministic undo
        if ReviseUndoClassifier.isUndoInstruction(trimmedInstruction) {
            await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
            let undoResult = await ReviseCoordinator.shared.undo()
            switch undoResult {
            case .success(let restoredText):
                if let latestRevs = await historyStore.fetchRevisions(sourceRecordID: prepared.sourceRecordID).last {
                    await historyStore.markRevisionUndone(id: latestRevs.id)
                }
                onASREvent?(.reviseUndone(text: restoredText))
            case .failure(let failure):
                onASREvent?(.reviseFailed(failure))
            }
            cleanupSessionAfterRevise(myGeneration: myGeneration)
            return
        }

        if prepared.isDeletionTombstone {
            await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
            onASREvent?(.reviseFailed(.noEditableTarget))
            cleanupSessionAfterRevise(myGeneration: myGeneration)
            return
        }

        // Budget & sensitive scan
        if prepared.currentText.count > ReviseInputBudget.maxTargetCharacters {
            await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
            onASREvent?(.reviseFailed(.targetTooLong))
            cleanupSessionAfterRevise(myGeneration: myGeneration)
            return
        }

        if trimmedInstruction.count > ReviseInputBudget.maxInstructionCharacters {
            await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
            onASREvent?(.reviseFailed(.instructionTooLong))
            cleanupSessionAfterRevise(myGeneration: myGeneration)
            return
        }

        if ReviseSensitiveTextScanner.containsSensitiveContent(prepared.currentText) ||
           ReviseSensitiveTextScanner.containsSensitiveContent(trimmedInstruction) {
            await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
            onASREvent?(.reviseFailed(.sensitive))
            cleanupSessionAfterRevise(myGeneration: myGeneration)
            return
        }

        // Resolve LLM runtime
        guard let runtime = await resolveLLMRuntime() else {
            await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
            onASREvent?(.reviseFailed(.llmUnavailable))
            cleanupSessionAfterRevise(myGeneration: myGeneration)
            return
        }

        onASREvent?(.reviseProcessing)
        await ReviseCoordinator.shared.setProcessing(transactionID: prepared.transactionID)

        let request = ReviseRequest(
            targetText: prepared.currentText,
            instruction: trimmedInstruction,
            controlKind: prepared.controlKind,
            sourceLanguage: ReviseLanguageProfile.detect(in: prepared.currentText),
            sourceModeKind: prepared.sourceModeKind
        )
        let userPrompt = RevisePromptBuilder.buildUserPrompt(request: request)
        let systemPrompt = RevisePromptBuilder.systemPrompt

        let llmStart = Date()
        do {
            let rawModelResponse = try await runtime.client.process(
                text: userPrompt,
                prompt: systemPrompt,
                config: runtime.config
            )
            let llmDuration = max(0, Date().timeIntervalSince(llmStart))

            guard sessionGeneration == myGeneration else {
                await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
                return
            }

            let validation = ReviseOutputValidator.validate(
                request: request,
                rawModelResponse: rawModelResponse,
                candidateTransform: { TextOutputFormatter.format($0) }
            )
            let diagLog = "revise_diag: tx=\(prepared.transactionID.uuidString.prefix(8)) instLen=\(trimmedInstruction.count) targetLen=\(prepared.currentText.count) respLen=\(rawModelResponse.count) intent=\(validation.trace.intent?.rawValue ?? "none") scope=\(validation.trace.scopeKind?.rawValue ?? "none") decision=\(validation.trace.decision) rejection=\(validation.trace.rejection?.rawValue ?? "none") hunks=\(validation.trace.diffHunkCount ?? 0) asrSec=\(String(format: "%.2f", asrDuration ?? 0)) llmSec=\(String(format: "%.2f", llmDuration))"
            DebugFileLogger.log(diagLog)

            switch validation.decision {
            case .accept:
                guard let candidate = validation.candidateText else {
                    await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
                    onASREvent?(.reviseFailed(.validationRejected))
                    cleanupSessionAfterRevise(myGeneration: myGeneration)
                    return
                }

                let revisionID = UUID().uuidString
                let commitResult = await ReviseCoordinator.shared.commit(
                    transactionID: prepared.transactionID,
                    candidate: candidate,
                    revisionID: revisionID
                )

                switch commitResult {
                case .success(let success):
                    let traceJSON = (try? JSONEncoder().encode(validation.trace)).flatMap { String(data: $0, encoding: .utf8) }
                    let revRecord = RecognitionRevisionRecord(
                        id: revisionID,
                        sourceRecordID: prepared.sourceRecordID,
                        instructionText: trimmedInstruction,
                        beforeText: prepared.currentText,
                        afterText: candidate,
                        intent: validation.trace.intent ?? .rewrite,
                        scopeKind: validation.trace.scopeKind ?? .whole,
                        status: "applied",
                        asrProvider: activeProvider.displayName,
                        asrModel: currentASRModelLabel(for: activeProvider),
                        llmProvider: runtime.providerID,
                        llmModel: runtime.config.model,
                        asrDurationSeconds: asrDuration,
                        llmDurationSeconds: llmDuration,
                        validationTraceJSON: traceJSON
                    )
                    await historyStore.insertRevision(revRecord)

                    if prepared.learningResumePlan?.shouldResume == true,
                       let newContext = success.trackingContext {
                        let category = AppContextClassifier.classify(
                            bundleIdentifier: newContext.bundleIdentifier,
                            appName: nil
                        )
                        await MainActor.run {
                            PostInjectionLearningCoordinator.shared.begin(
                                newContext,
                                options: PostInjectionLearningOptions(
                                    correctionEnabled: true,
                                    expressionLearningEnabled: true,
                                    appCategory: category
                                )
                            )
                        }
                    }

                    let undoTicketID = await ReviseCoordinator.shared.getLatestUndoTicketID()
                    onASREvent?(.reviseCompleted(
                        text: candidate,
                        message: L("已改好", "Revised"),
                        undoTicketID: undoTicketID
                    ))

                case .failure(let err):
                    DebugFileLogger.log("revise_diag: commit failure=\(err)")
                    onASREvent?(.reviseFailed(err))
                }

            case .reject(let rejection):
                await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
                let failure: ReviseFailure
                switch rejection {
                case .instructionTooLong: failure = .instructionTooLong
                case .targetTooLong: failure = .targetTooLong
                case .sensitiveContentLeak: failure = .sensitive
                case .malformedJSON, .schemaVersionMismatch, .codeFence, .toolCall: failure = .malformedModelResponse
                case .modelAmbiguous, .scopeMultipleMatchesWithoutOrdinal: failure = .instructionAmbiguous
                case .implicitReplacementAmbiguous: failure = .implicitReplacementAmbiguous
                case .protectedFactConflict, .protectedTokenRemovedWithoutAuthorization, .protectedTokenAddedWithoutAuthorization: failure = .protectedFactConflict
                case .unsupportedIntent: failure = .unsupportedInstruction
                case .responseTooLarge: failure = .responseTooLarge
                case .diffBudgetExceeded: failure = .diffBudgetExceeded
                default: failure = .validationRejected
                }
                onASREvent?(.reviseFailed(failure))
            }
        } catch {
            await ReviseCoordinator.shared.cancel(transactionID: prepared.transactionID)
            DebugFileLogger.log("revise_diag: runtime LLM exception occurred")
            onASREvent?(.reviseFailed(.providerFailure))
        }

        cleanupSessionAfterRevise(myGeneration: myGeneration)
    }

    private func cleanupSessionAfterRevise(myGeneration: Int) {
        if sessionGeneration == myGeneration, state != .idle {
            state = .idle
            hasEmittedReadyForCurrentSession = false
            currentTranscript = .empty
            recordingPurpose = .input(.direct)
            warmUpASRConnection()
        }
        resetSpeculativeLLM()
        SystemVolumeManager.restore()
    }

}
