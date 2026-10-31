import AVFoundation
import Foundation
import UIKit

/// Owns the voice session and runs every dictation the keyboard asks for.
///
/// Lives on the main actor. Audio buffers arrive on the capture queue and are
/// handed over through an `AsyncStream` so their order is preserved.
@MainActor
final class VoiceSession: ObservableObject {
    enum Status: Equatable {
        case off
        case idle
        case recording
        case processing
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var expiresAt: Date?
    @Published private(set) var liveText = ""
    @Published private(set) var lastError: String?

    let history: HistoryStore
    let log: DiagnosticsLog
    /// Input level for the Home orb; read per frame, never published.
    let meter = AudioLevelMeter()

    private let keeper = AudioSessionKeeper()
    private lazy var microphone = MicrophoneCapture(keeper: keeper)
    private let pip = PiPKeeper()
    private let instanceID = UUID()
    private var state: DictationState
    private var lastActivity = Date()
    private var timeoutTimer: Timer?
    private var current: Run?
    private var lastStateWrite = Date.distantPast
    private var pendingStateWrite = false

    /// One dictation from start to delivered text.
    private final class Run {
        let requestID: UUID
        let mode: DictationMode
        let startedAt = Date()
        let historyID = UUID()
        var chunks: AsyncStream<Data>.Continuation?
        var client: (any SpeechRecognizer)?
        /// False for services that upload the whole recording at the end.
        var isStreaming = true
        var transcript = ""
        /// Set once the user let go and the client was told the audio ended.
        var audioEnded = false
        /// Whether the latest transcript is final; the Mac takes that as done
        /// once the audio has ended.
        var latestIsFinal = false
        var completed = false
        var asrError: String?
        /// Intelli Sense: the field as the keyboard last saw it.
        var field: FieldContext?
        /// Set when this recording corrects a selection instead of dictating.
        var correction: CorrectionRequest?
        var pumpTask: Task<Void, Never>?
        var eventsTask: Task<Void, Never>?

        init(requestID: UUID, mode: DictationMode) {
            self.requestID = requestID
            self.mode = mode
        }
    }

    init(history: HistoryStore, log: DiagnosticsLog) {
        self.history = history
        self.log = log
        state = DictationState(instanceID: instanceID, sessionActive: false)
        DarwinNotifier.shared.observe(DarwinName.command) { [weak self] in
            self?.drainCommands()
        }
        keeper.onLog = { [weak log] in log?.add($0) }
        pip.onLog = { [weak log] in log?.add($0) }
        keeper.onInterruptionBegan = { [weak self] info in
            guard let self else { return }
            let busy = MicrophoneBusy.reason(forInterruption: info)
            self.log.add(L("音频被打断（来电或其他 App 占用）", "Audio interrupted (a call or another app took over)"))
            self.cancelCurrent(reason: busy?.interruptedMessage ?? L("录音被系统打断", "Recording interrupted by the system"))
        }
        keeper.onInterruptionEnded = { [weak self] resumed in
            guard let self else { return }
            self.log.add(resumed
                ? L("打断结束，会话已恢复", "Interruption ended; session resumed")
                : L("打断结束，会话没能恢复，需要重新开启", "Interruption ended, but the session couldn't resume and needs to be restarted"))
            if !resumed { self.endSession(reason: L("音频会话被系统收回", "The system took back the audio session")) }
        }
        // Commands sent while the app was not running are stale.
        _ = DictationChannel.drainCommands()
        publishState()
    }

    var isActive: Bool { status != .off }

    func appDidBecomeActive() {
        if isActive { pip.ensureRunning() }
    }

    // MARK: - Session

    /// Must be called while the app is in front; that is the only moment iOS
    /// lets us claim a record-capable audio session.
    func startSession(trigger: String) {
        guard ConfigStore.asr != nil else {
            lastError = L("还没有导入识别服务配置", "No speech service imported yet")
            return
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            lastError = L("还没有麦克风权限", "Microphone access hasn't been granted")
            return
        }
        do {
            if !keeper.isActive { try keeper.activate() }
            if status == .off { status = .idle }
            // Active PiP supplies background microphone eligibility;
            // the keeper does not capture audio between dictations.
            pip.prepare()
            lastError = nil
            touch()
            log.add(L("会话开启（\(trigger)）", "Session started (\(trigger))"))
            publishState()
        } catch {
            if let busy = MicrophoneBusy.reason(for: [error], inForeground: true) {
                lastError = busy.message
                log.add(L("开启语音会话失败：\(MicrophoneCapture.describe(error))", "Couldn't start the voice session: \(MicrophoneCapture.describe(error))"))
                endSession(reason: nil)
                return
            }
            lastError = L("开启语音会话失败：\(error.localizedDescription)", "Couldn't start the voice session: \(error.localizedDescription)")
            log.add(lastError!)
            endSession(reason: nil)
        }
    }

    func endSession(reason: String?) {
        cancelCurrent(reason: nil)
        microphone.stopEngine()
        pip.tearDown()
        keeper.deactivate()
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        status = .off
        expiresAt = nil
        if let reason { log.add(L("会话结束：\(reason)", "Session ended: \(reason)")) }
        publishState()
    }

    private func touch() {
        lastActivity = Date()
        let minutes = AppSettings.sessionTimeoutMinutes
        expiresAt = minutes > 0 ? lastActivity.addingTimeInterval(TimeInterval(minutes * 60)) : nil
        if timeoutTimer == nil {
            timeoutTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkTimeout() }
            }
        }
    }

    private func checkTimeout() {
        guard status == .idle, let expiresAt, Date() >= expiresAt else { return }
        endSession(reason: L("闲置超时", "Idle timeout"))
    }

    /// Dictation is over: give the microphone back so the indicator goes off.
    private func releaseMicrophoneIfUnneeded() {
        guard current == nil, microphone.isRunning else { return }
        microphone.stopEngine()
        log.add(L("麦克风已关闭", "Microphone closed"))
        pip.logState(L("麦克风关闭后", "after the mic closed"))
    }

    // MARK: - Commands

    private func drainCommands() {
        for command in DictationChannel.drainCommands() {
            // Ignore anything that sat in the queue for long; the user has
            // moved on and acting on it now would surprise them.
            let age = Date().timeIntervalSince(command.sentAt)
            guard age < 20 else {
                log.add(L("丢弃过期的键盘指令 \(command.kind.rawValue)（\(Int(age))s 前）", "Dropped a stale keyboard command \(command.kind.rawValue) (\(Int(age))s old)"))
                continue
            }
            if command.kind == .start || command.kind == .stop || command.kind == .cancel {
                let id = command.requestID.map { String($0.uuidString.prefix(8)) } ?? "-"
                log.add(L(
                    "收到键盘指令 \(command.kind.rawValue) \(id)（延迟 \(Int(age * 1000)) ms，当前\(status)）",
                    "Keyboard command \(command.kind.rawValue) \(id) (\(Int(age * 1000)) ms late, now \(status))"
                ))
            }
            handle(command)
        }
    }

    private func handle(_ command: KeyboardCommand) {
        switch command.kind {
        case .ping:
            state.pongFor = command.id
            publishState(force: true)
        case .start:
            guard let requestID = command.requestID else { return }
            startDictation(requestID: requestID, mode: command.mode ?? .quick)
            if current?.requestID == requestID {
                current?.field = command.field
                current?.correction = command.correction
            }
        case .stop:
            guard let current, current.requestID == command.requestID else { return }
            if let field = command.field { current.field = field }
            finishDictation(current)
        case .cancel:
            guard current?.requestID == command.requestID else { return }
            cancelCurrent(reason: nil)
        case .delivered:
            if let id = command.requestID, let run = deliveredRuns[id] {
                history.update(id: run, delivery: command.delivery == .copied ? .copied : .inserted)
                deliveredRuns[id] = nil
            }
        case .rememberHotword:
            guard let word = command.hotword else { return }
            if VocabularyStore.shared.addHotword(word) {
                log.add(L("已从键盘加入 1 个热词", "Added 1 hotword from the keyboard"))
            }
            state.rememberedHotword = word
            publishState(force: true)
        }
    }

    private var deliveredRuns: [UUID: UUID] = [:]

    // MARK: - Dictation

    private func startDictation(requestID: UUID, mode: DictationMode) {
        guard status != .off else {
            fail(requestID: requestID, mode: mode, message: L("语音会话没有开启", "The voice session isn't on"), needsForeground: true)
            return
        }
        guard let endpoint = ConfigStore.asr,
              let entry = PhoneASR.entry(for: endpoint.provider),
              let config = PhoneASR.config(for: endpoint)
        else {
            fail(requestID: requestID, mode: mode, message: L("先在 Type4Me 里导入识别服务配置", "Import a speech service in Type4Me first"), needsForeground: true)
            return
        }
        if current != nil { cancelCurrent(reason: nil) }

        if !microphone.isRunning {
            let inBackground = UIApplication.shared.applicationState != .active
            let where_ = inBackground ? L("后台", "background") : L("前台", "foreground")
            let pipState = pip.isActive ? L("开着", "on") : L("没开", "off")
            let started = Date()
            do {
                try microphone.startEngine()
                log.add(L(
                    "\(where_)开启麦克风成功（\(microphone.lastStartNotes)，画中画\(pipState)），用时 \(Int(Date().timeIntervalSince(started) * 1000)) ms",
                    "Mic started in the \(where_) (\(microphone.lastStartNotes), PiP \(pipState)) in \(Int(Date().timeIntervalSince(started) * 1000)) ms"
                ))
                pip.logState(L("麦克风开启后", "after the mic started"))
            } catch {
                // Never fall back to an always-on microphone by ourselves; the
                // user only wants it on while dictating. Record why iOS said no.
                log.add(L(
                    "\(where_)开启麦克风失败：\(microphone.lastStartNotes)；画中画\(pipState)；\(keeper.diagnostics)",
                    "Mic failed to start in the \(where_): \(microphone.lastStartNotes); PiP \(pipState); \(keeper.diagnostics)"
                ))
                // Another app holding the mic (a call, a recorder) gets a plain
                // explanation, like other keyboards give; the rest stays a
                // pointer to the diagnostics.
                let message: String
                if let busy = MicrophoneBusy.reason(for: microphone.lastStartErrors, inForeground: !inBackground) {
                    log.add(L("麦克风被占用：\(busy.message)", "Microphone busy: \(busy.message)"))
                    message = busy.message
                } else if inBackground {
                    message = L("系统没让 Type4Me 在后台开麦克风，原因见诊断记录", "iOS didn't let Type4Me use the mic in the background. See Diagnostics.")
                } else {
                    message = L("麦克风没能开启，原因见诊断记录", "The mic didn't start. See Diagnostics.")
                }
                fail(requestID: requestID, mode: mode, message: message, needsForeground: false)
                return
            }
        }

        let run = Run(requestID: requestID, mode: mode)
        current = run
        status = .recording
        liveText = ""
        touch()
        state.phase = .recording
        state.requestID = requestID
        state.mode = mode
        state.liveText = ""
        state.finalText = nil
        state.correction = nil
        state.errorMessage = nil
        state.needsForeground = false
        state.level = 0
        publishState(force: true)

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        run.chunks = continuation
        microphone.beginForwarding(
            onChunk: { data in continuation.yield(data) },
            onLevel: { [weak self] level in
                Task { @MainActor in self?.updateLevel(level, for: requestID) }
            }
        )

        let variant = entry.variant(for: config)
        let client = variant.createClient()
        var options = PhoneASR.requestOptions(for: endpoint)
        options.hotwords = VocabularyStore.shared.hotwords
        run.client = client
        run.isStreaming = variant.isStreaming
        if !variant.isStreaming {
            liveText = L("录音中 · 松手后识别", "Recording · text when you let go")
            state.liveText = liveText
        }
        run.pumpTask = Task { [weak self] in
            do {
                try await client.connect(config: config, options: options)
                let events = await client.events
                await MainActor.run {
                    self?.consume(events, run: run)
                }
                // Chunks recorded while connecting are buffered by the stream.
                for await chunk in stream {
                    try? await client.sendAudio(chunk)
                }
                // Batch services upload and transcribe here.
                try await client.endAudio()
                await MainActor.run { run.audioEnded = true }
            } catch {
                await MainActor.run {
                    run.audioEnded = true
                    if run.asrError == nil {
                        run.asrError = L("识别服务出错：\(error.localizedDescription)", "The speech service failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func consume(_ events: AsyncStream<RecognitionEvent>, run: Run) {
        run.eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .transcript(let transcript):
                    let text = transcript.displayText
                    // Blank interim frames would flash the live text empty.
                    if !text.isEmpty { run.transcript = text }
                    run.latestIsFinal = transcript.isFinal
                    if self.current === run, !text.isEmpty {
                        self.liveText = text
                        self.state.liveText = text
                        self.publishState()
                    }
                case .error(let error):
                    run.asrError = error.localizedDescription
                case .completed:
                    run.completed = true
                case .ready, .sessionReady:
                    break
                }
            }
            run.completed = true
        }
    }

    private func updateLevel(_ level: Float, for requestID: UUID) {
        guard current?.requestID == requestID else { return }
        state.level = level
        meter.current = level
        publishState()
    }

    private func finishDictation(_ run: Run) {
        let tail = microphone.endForwarding()
        if !tail.isEmpty { run.chunks?.yield(tail) }
        run.chunks?.finish()
        run.chunks = nil
        status = .processing
        state.phase = .processing
        state.level = 0
        meter.current = 0
        publishState(force: true)

        Task { [weak self] in
            // Same budget as the Mac: streaming services get a few seconds to
            // send the final hypothesis after the last packet; batch services
            // upload the whole recording inside endAudio.
            let upload = Date().addingTimeInterval(run.isStreaming ? 3 : BatchASRHTTP.requestTimeout + 5)
            while !run.audioEnded, run.asrError == nil, !run.completed, Date() < upload {
                try? await Task.sleep(for: .milliseconds(40))
            }
            let final = Date().addingTimeInterval(run.isStreaming ? 2 : 5)
            while !run.latestIsFinal, !run.completed, run.asrError == nil, Date() < final {
                try? await Task.sleep(for: .milliseconds(40))
            }
            await self?.complete(run)
        }
    }

    private func complete(_ run: Run) async {
        guard current === run else { return }
        await run.client?.disconnect()
        let raw = run.transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if raw.isEmpty {
            let message = run.asrError ?? L("没有听到内容", "Didn't hear anything")
            log.add(L("识别结束：\(message)", "Recognition ended: \(message)"))
            finish(run, text: nil, raw: raw, error: message)
            return
        }

        if let correction = run.correction {
            let result = await CorrectionRunner.run(spoken: raw, request: correction, log: log)
            guard current === run else { return }
            switch result {
            case .replace(var outcome):
                outcome.isHotword = VocabularyStore.shared.containsHotword(outcome.replacement)
                finishCorrection(run, outcome: outcome, error: nil)
            case .failed(let message): finishCorrection(run, outcome: nil, error: message)
            }
            return
        }

        // Snippets run before the mode, as on the Mac, so a model sees the
        // corrected words.
        let input = VocabularyStore.shared.apply(to: raw)
        var output = input
        var note: String?
        let definition = run.mode.definition
        // The Mac's short-text skip: below the mode's threshold the words go
        // out as recognized, without a round trip to the text model.
        let threshold = definition?.shortTextExemption ?? 0
        let skipsLLM = run.mode.usesLLM && threshold > 0
            && input.trimmingCharacters(in: .whitespacesAndNewlines).count < threshold
        if skipsLLM {
            log.add(L("少于 \(threshold) 字，跳过\(run.mode.title)", "Under \(threshold) characters, so \(run.mode.title) was skipped"))
        }
        if run.mode.usesLLM, !skipsLLM {
            let intelliSense = run.mode.kind == .intelliSense
                ? PhoneIntelliSense.request(text: input, field: run.field)
                : nil
            if let endpoint = ConfigStore.llm, let config = LLMEndpointConfig(endpoint: endpoint),
               let request = intelliSense?.prompt ?? ModePrompts.request(for: run.mode, text: input) {
                let started = Date()
                do {
                    let client = ChatClient(config: config)
                    output = try await client.complete(system: request.system, user: request.user)
                    if let intelliSense {
                        let checked = PhoneIntelliSense.check(output, input: input, request: intelliSense)
                        output = checked.text
                        if let rejection = checked.rejection {
                            log.add(L("智能感知结果没通过检查（\(rejection)），已用原文", "Intelli Sense output didn't pass the check (\(rejection)), so your words were used"))
                        }
                        log.add(L("智能感知场景：\(intelliSense.summary)", "Intelli Sense scene: \(intelliSense.summary)"))
                    }
                    if run.mode.kind == .translation {
                        let checked = try await checkTranslation(output, raw: input, mode: run.mode, client: client)
                        output = checked.text
                        note = checked.note
                    }
                    log.add(L("\(run.mode.title) 完成，用时 \(Int(Date().timeIntervalSince(started) * 1000)) ms", "\(run.mode.title) finished in \(Int(Date().timeIntervalSince(started) * 1000)) ms"))
                } catch {
                    note = L("处理失败，已用原文", "Processing failed, so your original words were used")
                    log.add(L("\(run.mode.title) 失败：\(error.localizedDescription)", "\(run.mode.title) failed: \(error.localizedDescription)"))
                }
            } else {
                note = L("没有配置处理模型，已用原文", "No text model is set up, so your original words were used")
            }
        }
        guard current === run else { return }
        finish(run, text: TextOutputSettings.format(output, mode: definition), raw: raw, error: note)
    }

    /// The Mac's rule: a reply confidently in the wrong language gets one
    /// retry with a stricter prompt; a second miss, or an unsafe reply, falls
    /// back to the original words instead of inserting it.
    private func checkTranslation(_ output: String, raw: String, mode: DictationMode, client: ChatClient) async throws -> (text: String, note: String?) {
        let target = ModePrompts.translationTarget(of: mode)
        let validator = TranslationOutputValidator.production
        var candidate = output
        var attempt = TranslationValidationAttempt.initial
        while true {
            switch TranslationValidationPolicy.action(for: validator.validate(candidate, target: target), attempt: attempt) {
            case .accept:
                return (candidate, nil)
            case .retry:
                log.add(L("翻译结果不是\(target.displayName)，重试一次", "The translation wasn't in \(target.displayName); retrying once"))
                let retry = ModePrompts.translationRetry(for: mode, text: raw)
                candidate = try await client.complete(system: retry.system, user: retry.user)
                attempt = .retry
            case .reject:
                log.add(L("翻译结果没通过检查（目标\(target.displayName)）", "The translation didn't pass the check (target \(target.displayName))"))
                return (raw, L("翻译结果不是\(target.displayName)，已用原文", "The translation wasn't in \(target.displayName), so your original words were used"))
            }
        }
    }

    private func finish(_ run: Run, text: String?, raw: String, error: String?) {
        if let text {
            history.add(HistoryEntry(
                id: run.historyID, mode: run.mode, rawText: raw, finalText: text,
                delivered: .inserted, note: error
            ))
            deliveredRuns[run.requestID] = run.historyID
        }
        state.phase = text == nil ? .failed : .done
        state.finalText = text
        state.errorMessage = error
        state.liveText = ""
        publishState(force: true)
        current = nil
        status = keeper.isActive ? .idle : .off
        liveText = ""
        touch()
        releaseMicrophoneIfUnneeded()
    }

    /// Corrections stay out of history: they fix text that is already there.
    private func finishCorrection(_ run: Run, outcome: CorrectionOutcome?, error: String?) {
        state.phase = outcome == nil ? .failed : .done
        state.finalText = nil
        state.correction = outcome
        state.errorMessage = error
        state.liveText = ""
        publishState(force: true)
        current = nil
        status = keeper.isActive ? .idle : .off
        liveText = ""
        touch()
        releaseMicrophoneIfUnneeded()
    }

    private func fail(requestID: UUID, mode: DictationMode, message: String, needsForeground: Bool) {
        state.phase = .failed
        state.requestID = requestID
        state.mode = mode
        state.errorMessage = message
        state.needsForeground = needsForeground
        state.finalText = nil
        state.correction = nil
        publishState(force: true)
    }

    private func cancelCurrent(reason: String?) {
        guard let run = current else { return }
        _ = microphone.endForwarding()
        run.chunks?.finish()
        run.pumpTask?.cancel()
        run.eventsTask?.cancel()
        if let client = run.client { Task { await client.disconnect() } }
        current = nil
        status = keeper.isActive ? .idle : .off
        liveText = ""
        state.phase = reason == nil ? .idle : .failed
        state.errorMessage = reason
        state.liveText = ""
        state.level = 0
        publishState(force: true)
        releaseMicrophoneIfUnneeded()
    }

    // MARK: - State

    /// Writes are throttled to ~12 per second; level and live text change faster.
    private func publishState(force: Bool = false) {
        state.sessionActive = status != .off
        state.sessionExpiresAt = expiresAt
        let now = Date()
        if force || now.timeIntervalSince(lastStateWrite) > 0.08 {
            state.updatedAt = now
            DictationChannel.write(state)
            lastStateWrite = now
            state.pongFor = nil
            pendingStateWrite = false
        } else if !pendingStateWrite {
            pendingStateWrite = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                await MainActor.run { self?.publishState(force: true) }
            }
        }
    }
}
