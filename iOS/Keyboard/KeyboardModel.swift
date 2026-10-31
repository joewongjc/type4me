import SwiftUI
import Type4MeCorrectionCore
import UIKit

/// Keyboard-side state machine. Talks to the app through `DictationChannel`
/// and writes into the host text field through the document proxy.
@MainActor
final class KeyboardModel: ObservableObject {
    enum Liveness: Equatable {
        case checking
        /// The app answered a ping and its voice session is open.
        case ready
        /// No answer, or the app is running without a session: the mic is
        /// shown hollow and a tap opens the app once.
        case needsApp
    }

    struct KeyboardNotice: Equatable {
        enum Kind { case info, success, error }
        var text: String
        var kind: Kind
    }

    enum Phase: Equatable {
        case idle
        case recording(locked: Bool)
        case processing
    }

    @Published var liveness: Liveness = .checking {
        didSet {
            guard liveness != oldValue else { return }
            diag("连接状态 \(oldValue) → \(liveness)", "Liveness \(oldValue) → \(liveness)")
        }
    }
    @Published var phase: Phase = .idle {
        didSet { phaseDidChange(from: oldValue) }
    }
    @Published var liveText = ""
    @Published var level: Float = 0
    @Published var notice: KeyboardNotice?
    /// Read every frame by the orb; deliberately not published.
    let meter = AudioLevelMeter()
    @Published var mode: DictationMode = SharedSettings.selectedMode
    @Published var llmConfigured = SharedSettings.llmConfigured
    @Published var hasFullAccess = false
    @Published var returnKeyTitle = L("换行", "return")
    /// Read on every appearance so a change made in the app shows up the
    /// next time the keyboard opens.
    @Published var language = AppLanguage.current
    /// Full-width marks (，。) rather than ASCII (,.) on the punctuation key.
    @Published private(set) var fullWidthPunctuation = true
    @Published var canUndo = false
    /// Set right after an undo, until anything else changes the text.
    @Published var canRedo = false
    /// Where a held finger currently is, for the caption under the orb.
    @Published var holdZone: HoldZone = .none
    /// How far the held finger has slid towards a side key: -1 is all the
    /// way to cancel, 1 all the way to lock. Stepped so a drag doesn't
    /// redraw the keyboard on every point.
    @Published var holdPull: CGFloat = 0

    enum HoldZone { case none, cancel, lock }

    /// What holding the mic corrects instead of dictating.
    enum Correction: Equatable {
        case none
        /// Text is selected in the field.
        case armed(CorrectionRequest)
        /// Just replaced; holding again corrects the word before the cursor.
        case corrected(Corrected)
    }

    struct Corrected: Equatable {
        var replacement: String
        /// Every spelling tried before this one, the original first.
        var rejected: [String]
        var count: Int
        var canRemember: Bool
        var remembered = false
    }

    @Published private(set) var correction: Correction = .none

    /// Text copied a moment ago, offered in the top bar the way the system
    /// keyboard offers it.
    @Published private(set) var clipboardSuggestion: String?
    /// The pasteboard change the suggestion came from.
    private var clipboardSuggestionCount: Int?

    private weak var controller: KeyboardViewController?
    private var pendingPing: UUID?
    private var requestID: UUID?
    private var startDocumentID: UUID?
    private var lastInsertion: Insertion?
    private var lastCorrection: CorrectionUndo?
    private var redo: Redo?
    /// What clearing the field took out, so undo can put it back.
    private var lastClear: Cleared?
    /// Set once a clear is undone: redo clears this document again.
    private var clearRedoDocument: UUID?
    /// What each delete took out, newest last, so a clear can put back
    /// what the same press had already deleted before it.
    private var recentDeletions: [String] = []
    /// The correction this recording carries, and whether it re-corrects the
    /// word before the cursor rather than a selection.
    private var correctionInFlight: (request: CorrectionRequest, again: Bool)?
    /// Set while edits land in the field, so their own callbacks are ignored.
    private var applying = false
    private var pendingHotword: String?
    private var foldTask: Task<Void, Never>?

    /// Dictated text, plus the selection it typed over, so undo can put
    /// the original back.
    private struct Insertion {
        let text: String
        let replaced: String?
    }

    /// What an undo took out, and where, so redo puts it back only in the
    /// same place.
    private struct Redo {
        let insertion: Insertion
        let documentID: UUID
        /// The end of the text before the cursor once the undo is done.
        let anchor: String
    }

    /// Everything a clear took out, and where the cursor was left.
    private struct Cleared {
        let text: String
        let documentID: UUID
        /// The end of the text before the cursor once the clear is done.
        let anchor: String
    }
    private var watchdog: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var observing = false
    /// What the app last reported, so the log only notes changes.
    private var loggedAppPhase: DictationState.Phase?
    private var loggedAppInstance: UUID?
    /// The field changed under a run in flight; logged once per run.
    private var loggedFieldChange = false

    init(controller: KeyboardViewController) {
        self.controller = controller
    }

    // MARK: - Diagnostics

    /// One line in the shared log, tagged with this keyboard instance.
    func diag(_ zh: String, _ en: String) {
        let tag = controller?.instance ?? "?"
        KeyboardDiagnostics.log(L("键盘#\(tag) \(zh)", "Keyboard #\(tag) \(en)"))
    }

    var phaseDescription: String {
        switch phase {
        case .idle: return L("空闲", "idle")
        case .recording(let locked): return locked ? L("锁定录音中", "recording, locked") : L("录音中", "recording")
        case .processing: return L("处理中", "processing")
        }
    }

    private func phaseDidChange(from old: Phase) {
        guard phase != old else { return }
        let instance = controller?.instance ?? "?"
        switch phase {
        case .recording where old == .idle:
            if let requestID { KeyboardDiagnostics.recordingBegan(instance: instance, requestID: requestID) }
        case .processing:
            KeyboardDiagnostics.phaseChanged(to: "processing")
        case .idle:
            KeyboardDiagnostics.recordingEnded()
            loggedAppPhase = nil
        default:
            break
        }
    }

    /// The host field changed while a run is in flight; the result will go
    /// to the clipboard instead, which is worth knowing when it happens.
    func noteFieldChange() {
        guard phase != .idle, !loggedFieldChange, let proxy = controller?.proxy,
              proxy.documentIdentifier != startDocumentID else { return }
        loggedFieldChange = true
        diag("录音或处理中输入框变了（\(phaseDescription)）", "The text field changed mid-run (\(phaseDescription))")
    }

    // MARK: - Lifecycle

    func appeared() {
        language = AppLanguage.current
        fullWidthPunctuation = SharedSettings.fullWidthPunctuation ?? (language == .zh)
        hasFullAccess = controller?.hasFullAccess ?? false
        refreshReturnKey()
        guard hasFullAccess else { return }
        KeyFeedback.reload()
        LiquidOrbPipeline.shared.warmUp()
        mode = SharedSettings.selectedMode
        llmConfigured = SharedSettings.llmConfigured
        if !llmConfigured, mode.usesLLM { mode = .quick }
        SharedSettings.keyboardLastSeen = Date()
        DarwinNotifier.post(DarwinName.keyboardAppeared)
        if !observing {
            observing = true
            DarwinNotifier.shared.observe(DarwinName.state) { [weak self] in
                Task { @MainActor in self?.stateDidChange() }
            }
        }
        ping()
        refreshSelection()
        refreshClipboard()
    }

    func disappeared() {
        if case .recording = phase, let requestID {
            diag("键盘消失，取消录音 \(KeyboardDiagnostics.short(requestID))", "Keyboard went away, cancelling \(KeyboardDiagnostics.short(requestID))")
            DictationChannel.send(KeyboardCommand(kind: .cancel, requestID: requestID))
        }
        resetToIdle()
        correction = .none
        // Not handled: the same copy is offered again while it is recent.
        clipboardSuggestion = nil
        clipboardSuggestionCount = nil
    }

    func refreshReturnKey() {
        switch controller?.proxy.returnKeyType {
        case .send?: returnKeyTitle = L("发送", "send")
        case .search?, .google?, .yahoo?: returnKeyTitle = L("搜索", "search")
        case .go?: returnKeyTitle = L("前往", "go")
        case .done?: returnKeyTitle = L("完成", "done")
        case .next?: returnKeyTitle = L("下一项", "next")
        default: returnKeyTitle = L("换行", "return")
        }
    }

    private func ping() {
        #if DEBUG
        if SharedSettings.keyboardDemo { liveness = .ready; return }
        #endif
        let command = KeyboardCommand(kind: .ping)
        pendingPing = command.id
        if liveness != .ready { liveness = .checking }
        DictationChannel.send(command)
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if pendingPing == command.id {
                // A suspended or killed app never answers.
                diag("App 450 ms 内没回应 ping", "The app didn't answer a ping within 450 ms")
                pendingPing = nil
                liveness = .needsApp
            }
        }
    }

    // MARK: - Mode

    /// Modes that need a text model wait until one is imported.
    func isAvailable(_ mode: DictationMode) -> Bool {
        !mode.usesLLM || llmConfigured
    }

    /// `haptic` is off when the control picking the mode already ticked.
    func select(_ newMode: DictationMode, haptic: Bool = true) {
        guard phase == .idle else { return }
        if newMode.usesLLM, !llmConfigured {
            show(L("先在 Type4Me 里导入处理模型配置", "Import a text model in Type4Me first"), kind: .error)
            return
        }
        mode = newMode
        SharedSettings.selectedMode = newMode
        if haptic { UISelectionFeedbackGenerator().selectionChanged() }
    }

    // MARK: - Intelli Sense

    /// What Intelli Sense gets to see of the field, or nil for other modes.
    private func fieldContext() -> FieldContext? {
        guard mode.kind == .intelliSense, let proxy = controller?.proxy else { return nil }
        let contentType = proxy.textContentType ?? nil
        var field = FieldContext(
            keyboardType: (proxy.keyboardType ?? .default).rawValue,
            returnKeyType: (proxy.returnKeyType ?? .default).rawValue,
            textContentType: contentType?.rawValue
        )
        if isSensitiveField {
            field.isSensitive = true
            return field
        }
        guard SharedSettings.intelliSenseContext else { return field }
        field.before = String((proxy.documentContextBeforeInput ?? "").suffix(FieldContext.beforeLimit))
        field.after = String((proxy.documentContextAfterInput ?? "").prefix(FieldContext.afterLimit))
        return field
    }

    private var isSensitiveField: Bool {
        guard let proxy = controller?.proxy else { return true }
        if let contentType = proxy.textContentType ?? nil, Self.sensitiveContentTypes.contains(contentType) { return true }
        // Card numbers, codes and amounts often come without a content
        // type, only a digit pad. Nothing typed there needs context.
        if let keyboardType = proxy.keyboardType ?? nil, Self.digitPads.contains(keyboardType) { return true }
        return false
    }

    /// Fields whose text must never leave the phone. Secure fields don't
    /// even get a third-party keyboard; these are the rest.
    private static let sensitiveContentTypes: Set<UITextContentType> = [
        .password, .newPassword, .oneTimeCode,
        .creditCardNumber, .creditCardSecurityCode, .creditCardExpiration,
    ]

    /// Phone pads never get a third-party keyboard, so they aren't here.
    private static let digitPads: Set<UIKeyboardType> = [.numberPad, .decimalPad, .asciiCapableNumberPad]

    // MARK: - Mic

    func micPressed() {
        guard hasFullAccess else { return }
        diag("按下麦克风（\(phaseDescription)，\(liveness)）", "Mic pressed (\(phaseDescription), \(liveness))")
        switch phase {
        case .idle:
            if liveness == .ready {
                // A new dictation replaces whatever an undo took out.
                redo = nil
                clearRedoDocument = nil
                canRedo = false
                startRecording()
            } else {
                openApp(reason: L("会话未就绪", "session not ready"))
            }
        case .recording(locked: true):
            stopRecording()
        default:
            break
        }
    }

    func micReleased(cancelled: Bool, locked: Bool) {
        guard case .recording(let wasLocked) = phase, !wasLocked else { return }
        diag(
            "松开麦克风（\(cancelled ? "取消" : locked ? "锁定" : "结束")）",
            "Mic released (\(cancelled ? "cancel" : locked ? "lock" : "finish"))"
        )
        if cancelled {
            cancelRecording()
        } else if locked {
            phase = .recording(locked: true)
        } else {
            stopRecording()
        }
    }

    #if DEBUG
    private var demoTask: Task<Void, Never>?

    /// A scripted dictation: syllable-shaped levels and a growing transcript.
    private func startDemo() {
        let sentence = L(
            "明天下午三点的会改到四点，记得通知设计组，顺便把新版本的发布计划也同步一下",
            "Move tomorrow's 3 PM meeting to 4 and let the design team know, and share the release plan too"
        )
        requestID = UUID()
        liveText = ""
        notice = nil
        phase = .recording(locked: false)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        demoTask?.cancel()
        demoTask = Task {
            let started = Date()
            while !Task.isCancelled, case .recording = phase {
                let t = Date().timeIntervalSince(started)
                let speaking = t > 0.8
                let syllable = abs(sin(t * 9)) * (0.55 + 0.35 * sin(t * 1.7))
                level = speaking ? Float(0.25 + syllable * 0.6) : 0.05
                meter.current = level
                if speaking {
                    let count = min(sentence.count, Int((t - 0.8) * 5.5))
                    liveText = String(sentence.prefix(count))
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func stopDemo() {
        demoTask?.cancel()
        phase = .processing
        level = 0
        meter.current = 0
        let text = liveText
        demoTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            if !text.isEmpty {
                let ending = L("。", ".")
                controller?.proxy.insertText(text + ending)
                recordInsertion(text + ending)
                show(L("已完成", "Done"), kind: .success, duration: 1.1)
            }
            resetToIdle()
        }
    }
    #endif

    /// The lock key that replaces delete while the mic is held.
    func lockFromKey() {
        guard phase == .recording(locked: false) else { return }
        diag("点了锁定键", "Lock key tapped")
        phase = .recording(locked: true)
        holdZone = .none
        holdPull = 0
    }

    /// The done key that replaces lock once recording is locked.
    func finishFromKey() {
        guard phase == .recording(locked: true) else { return }
        diag("点了完成键", "Done key tapped")
        stopRecording()
    }

    /// The cancel key that replaces undo while recording.
    func cancelFromKey() {
        guard case .recording = phase else { return }
        diag("点了取消键", "Cancel key tapped")
        #if DEBUG
        if SharedSettings.keyboardDemo { demoTask?.cancel(); resetToIdle(); return }
        #endif
        cancelRecording()
    }

    private func startRecording() {
        dropClipboardSuggestion()
        #if DEBUG
        if SharedSettings.keyboardDemo { startDemo(); return }
        #endif
        guard let controller else { return }
        let id = UUID()
        requestID = id
        startDocumentID = controller.proxy.documentIdentifier
        correctionInFlight = pendingCorrection()
        liveText = ""
        level = 0
        notice = nil
        loggedFieldChange = false
        diag(
            "开始录音 \(KeyboardDiagnostics.short(id))（\(mode.rawValue)\(correctionInFlight == nil ? "" : "，纠正")）",
            "Recording \(KeyboardDiagnostics.short(id)) (\(mode.rawValue)\(correctionInFlight == nil ? "" : ", correction"))"
        )
        phase = .recording(locked: false)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        DictationChannel.send(KeyboardCommand(
            kind: .start, requestID: id, mode: mode,
            field: correctionInFlight == nil ? fieldContext() : nil,
            correction: correctionInFlight?.request
        ))
        // If the app does not acknowledge, it is gone: fall back to opening it.
        watchdog?.cancel()
        watchdog = Task {
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled, requestID == id, case .recording = phase, !acknowledged else { return }
            diag("App 1.2 秒内没确认录音 \(KeyboardDiagnostics.short(id))", "The app didn't confirm \(KeyboardDiagnostics.short(id)) within 1.2 s")
            resetToIdle()
            liveness = .needsApp
            openApp(reason: L("App 没确认录音", "the app didn't confirm"))
        }
        acknowledged = false
    }

    private var acknowledged = false

    private func stopRecording() {
        #if DEBUG
        if SharedSettings.keyboardDemo { stopDemo(); return }
        #endif
        guard let requestID else { return }
        diag("结束录音 \(KeyboardDiagnostics.short(requestID))，等结果", "Stopped \(KeyboardDiagnostics.short(requestID)), waiting for the result")
        phase = .processing
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Read again on release, as the Mac refreshes before processing.
        DictationChannel.send(KeyboardCommand(kind: .stop, requestID: requestID, field: fieldContext()))
        watchdog?.cancel()
        watchdog = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, self.requestID == requestID else { return }
            diag("等结果 30 秒超时 \(KeyboardDiagnostics.short(requestID))", "Timed out after 30 s waiting for \(KeyboardDiagnostics.short(requestID))")
            resetToIdle()
            show(L("处理超时，没有拿到结果", "Timed out waiting for the result"), kind: .error)
        }
    }

    private func cancelRecording() {
        guard let requestID else { return }
        diag("取消录音 \(KeyboardDiagnostics.short(requestID))", "Cancelled \(KeyboardDiagnostics.short(requestID))")
        DictationChannel.send(KeyboardCommand(kind: .cancel, requestID: requestID))
        // Like the Mac bar: cancelling simply puts the keyboard back.
        resetToIdle()
    }

    private func resetToIdle() {
        watchdog?.cancel()
        requestID = nil
        correctionInFlight = nil
        phase = .idle
        liveText = ""
        level = 0
        meter.current = 0
    }

    private func openApp(reason: String) {
        diag("跳转到 App：\(reason)", "Opening the app: \(reason)")
        controller?.openContainingApp(SharedContainer.Link.startSession)
    }

    // MARK: - State from the app

    private func stateDidChange() {
        guard let state = DictationChannel.readState() else { return }
        if state.instanceID != loggedAppInstance {
            if loggedAppInstance != nil {
                diag("App 重新启动过（会话\(state.sessionActive ? "开" : "关")）", "The app restarted (session \(state.sessionActive ? "on" : "off"))")
            }
            loggedAppInstance = state.instanceID
        }
        if let requestID, state.requestID == requestID, state.phase != loggedAppPhase {
            loggedAppPhase = state.phase
            var extra = ""
            if state.phase == .done { extra = L("，\(state.finalText?.count ?? 0) 字", ", \(state.finalText?.count ?? 0) characters") }
            if state.needsForeground { extra += L("，需要前台", ", needs the foreground") }
            if state.errorMessage != nil { extra += L("，带错误信息", ", with an error message") }
            diag(
                "App 报告 \(KeyboardDiagnostics.short(requestID))：\(state.phase.rawValue)\(extra)",
                "App reports \(KeyboardDiagnostics.short(requestID)): \(state.phase.rawValue)\(extra)"
            )
        }
        if let ping = pendingPing, state.pongFor == ping {
            pendingPing = nil
        }
        if pendingPing == nil {
            liveness = state.sessionActive ? .ready : .needsApp
        }
        if let word = pendingHotword, state.rememberedHotword == word {
            pendingHotword = nil
            if case .corrected(var done) = correction, done.replacement == word {
                done.remembered = true
                correction = .corrected(done)
            }
        }

        guard let requestID, state.requestID == requestID else { return }
        acknowledged = true
        switch state.phase {
        case .recording:
            liveText = state.liveText
            level = state.level
            meter.current = state.level
        case .processing:
            liveText = state.liveText
            if phase != .processing { phase = .processing }
        case .done:
            if let outcome = state.correction, let inFlight = correctionInFlight {
                // Stays "processing" until every edit has landed.
                watchdog?.cancel()
                correctionInFlight = nil
                Task {
                    await applyCorrection(outcome, request: inFlight.request, again: inFlight.again)
                    resetToIdle()
                }
                return
            }
            if let text = state.finalText { deliver(text, note: state.errorMessage) }
            resetToIdle()
        case .failed:
            resetToIdle()
            if state.needsForeground {
                liveness = .needsApp
                openApp(reason: L("App 需要回到前台", "the app needs the foreground"))
            } else if let message = state.errorMessage {
                show(message, kind: .error)
            }
        case .idle:
            break
        }
    }

    private func deliver(_ text: String, note: String?) {
        guard let controller, let requestID else { return }
        let sameField = controller.proxy.documentIdentifier == startDocumentID
        diag(
            "交付 \(KeyboardDiagnostics.short(requestID))：\(text.count) 字，\(sameField ? "插入" : "输入框已变，复制")",
            "Delivering \(KeyboardDiagnostics.short(requestID)): \(text.count) characters, \(sameField ? "inserted" : "field changed, copied")"
        )
        if sameField {
            // Inserting types over a selection; read it right before, as
            // that is exactly what gets replaced.
            let replaced = controller.proxy.selectedText
            controller.proxy.insertText(text)
            recordInsertion(text, replacing: replaced)
            DictationChannel.send(KeyboardCommand(kind: .delivered, requestID: requestID, mode: mode, delivery: .inserted))
            if let note { show(note) } else { show(L("已完成", "Done"), kind: .success, duration: 1.1) }
        } else {
            // The user switched fields while we were processing; never type
            // into a place they did not dictate into.
            UIPasteboard.general.string = text
            ClipboardMemory.handledCount = UIPasteboard.general.changeCount
            DictationChannel.send(KeyboardCommand(kind: .delivered, requestID: requestID, mode: mode, delivery: .copied))
            show(L("输入框已变，文字已复制到剪贴板", "The text field changed, so the text was copied"), kind: .success)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Correction

    /// Called whenever the host's text or selection changes: a selection
    /// turns the mic into a correction, and moving off a fresh correction
    /// turns it back.
    func refreshSelection() {
        guard hasFullAccess, phase == .idle, !applying, let proxy = controller?.proxy else { return }
        let selected = proxy.selectedText ?? ""
        if !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !isSensitiveField else {
                if correction != .none { correction = .none }
                return
            }
            let reads = SharedSettings.intelliSenseContext
            let request = CorrectionRequest(
                before: reads ? String((proxy.documentContextBeforeInput ?? "").suffix(FieldContext.beforeLimit)) : "",
                selected: selected,
                after: reads ? String((proxy.documentContextAfterInput ?? "").prefix(FieldContext.afterLimit)) : ""
            )
            if correction != .armed(request) { correction = .armed(request) }
            return
        }
        if case .corrected(let done) = correction, (proxy.documentContextBeforeInput ?? "").hasSuffix(done.replacement) {
            return
        }
        if correction != .none { correction = .none }
    }

    func exitCorrection() {
        foldTask?.cancel()
        correction = .none
    }

    var isCorrecting: Bool {
        correction != .none || correctionInFlight != nil
    }

    /// The caption under the orb while the request is processed.
    var processingLabel: String {
        correctionInFlight != nil ? L("正在纠正…", "Correcting…") : mode.processingLabel
    }

    private func pendingCorrection() -> (request: CorrectionRequest, again: Bool)? {
        switch correction {
        case .none:
            return nil
        case .armed(let request):
            return (request, false)
        case .corrected(let done):
            guard let proxy = controller?.proxy else { return nil }
            let before = proxy.documentContextBeforeInput ?? ""
            guard before.hasSuffix(done.replacement) else { return nil }
            let reads = SharedSettings.intelliSenseContext
            return (CorrectionRequest(
                before: reads ? String(before.dropLast(done.replacement.count).suffix(FieldContext.beforeLimit)) : "",
                selected: done.replacement,
                after: reads ? String((proxy.documentContextAfterInput ?? "").prefix(FieldContext.afterLimit)) : "",
                attempts: done.rejected
            ), true)
        }
    }

    /// Positions below are characters from where the corrected word starts
    /// in the text as it was sent; edits further on never move earlier
    /// text, so every pass works from the end backwards.
    private func applyCorrection(_ outcome: CorrectionOutcome, request: CorrectionRequest, again: Bool) async {
        guard let proxy = controller?.proxy else { return }
        let old = request.selected
        let new = outcome.replacement
        let inPlace = again
            ? (proxy.selectedText ?? "").isEmpty && (proxy.documentContextBeforeInput ?? "").hasSuffix(old)
            : proxy.selectedText == old
        guard proxy.documentIdentifier == startDocumentID, inPlace else {
            UIPasteboard.general.string = new
            ClipboardMemory.handledCount = UIPasteboard.general.changeCount
            show(L("选中的位置变了，结果已复制", "The selection changed, so the result was copied"), kind: .success)
            correction = .none
            return
        }

        applying = true
        defer { applying = false }
        if again {
            for _ in 0..<old.count { proxy.deleteBackward() }
        }
        proxy.insertText(new)

        // The same mistake elsewhere: after the word first, then before it.
        let delta = new.count - old.count
        var cursor = new.count
        var changed = [0]
        let others = CorrectionOccurrences.find(before: request.before, after: request.after, matching: old)
            .filter { outcome.also.contains($0.number) }
            .sorted { $0.offset > $1.offset }
        for other in others {
            let start = other.offset > 0 ? other.offset + delta : other.offset
            guard await swap(old, for: new, endingAt: start + old.count, cursor: &cursor) else { break }
            changed.append(other.offset)
        }
        let end = new.count + delta * changed.filter { $0 < 0 }.count
        proxy.adjustTextPosition(byCharacterOffset: end - cursor)

        lastInsertion = nil
        lastClear = nil
        redo = nil
        clearRedoDocument = nil
        canRedo = false
        lastCorrection = CorrectionUndo(old: old, new: new, starts: changed)
        canUndo = true
        correction = .corrected(Corrected(
            replacement: new,
            rejected: request.attempts + [old],
            count: changed.count,
            canRemember: !outcome.isHotword && Self.isHotwordSized(new)
        ))
        let message = changed.count > 1
            ? L("已改为「\(new)」· 共 \(changed.count) 处", "Changed to “\(new)” · \(changed.count) places")
            : L("已改为「\(new)」", "Changed to “\(new)”")
        show(message, kind: .success, duration: 1.1)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        foldCorrectionLater()
    }

    /// The result bar folds back into the dial after a few quiet seconds;
    /// selecting the word again brings correction back.
    private func foldCorrectionLater() {
        foldTask?.cancel()
        foldTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, phase == .idle, case .corrected = correction else { return }
            correction = .none
        }
    }

    /// Hotwords are words: up to five Chinese characters or two English
    /// words, without punctuation.
    static func isHotwordSized(_ text: String) -> Bool {
        guard !text.contains(where: { $0.isPunctuation || $0.isNewline }) else { return false }
        if text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
            return text.filter { !$0.isWhitespace }.count <= 5
        }
        return text.split(whereSeparator: \.isWhitespace).count <= 2
    }

    /// One correction, enough to put every place back.
    private struct CorrectionUndo {
        let old: String
        let new: String
        /// Where each changed place started before the change, the
        /// corrected word itself at 0.
        let starts: [Int]
    }

    private func undoCorrection(_ undo: CorrectionUndo) async {
        guard let proxy = controller?.proxy else { return }
        let delta = undo.new.count - undo.old.count
        // Where each place starts now that the earlier ones changed length.
        let now = undo.starts.map { start in start + delta * undo.starts.filter { $0 < start }.count }
        let mainStart = delta * undo.starts.filter { $0 < 0 }.count
        guard (proxy.documentContextBeforeInput ?? "").hasSuffix(undo.new) else {
            show(L("光标位置变了，没法撤销", "The cursor moved, so this can't be undone"), kind: .error)
            return
        }
        applying = true
        defer { applying = false }
        var cursor = mainStart + undo.new.count
        for start in now.sorted(by: >) {
            guard await swap(undo.new, for: undo.old, endingAt: start + undo.new.count, cursor: &cursor) else { break }
        }
        proxy.adjustTextPosition(byCharacterOffset: undo.old.count - cursor)
        correction = .none
        show(L("已撤销", "Undone"))
    }

    /// Moves to the end of `old` and swaps it for `new`, if `old` is really there.
    private func swap(_ old: String, for new: String, endingAt end: Int, cursor: inout Int) async -> Bool {
        guard let proxy = controller?.proxy else { return false }
        if end != cursor {
            proxy.adjustTextPosition(byCharacterOffset: end - cursor)
            cursor = end
        }
        // The proxy's context catches up a moment after the cursor moves.
        var found = false
        for _ in 0..<15 {
            if (proxy.documentContextBeforeInput ?? "").hasSuffix(old) { found = true; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard found else { return false }
        for _ in 0..<old.count { proxy.deleteBackward() }
        proxy.insertText(new)
        cursor = end - old.count + new.count
        return true
    }

    func rememberCorrection() {
        guard case .corrected(let done) = correction, !done.remembered else { return }
        let word = done.replacement
        foldCorrectionLater()
        pendingHotword = word
        DictationChannel.send(KeyboardCommand(kind: .rememberHotword, hotword: word))
        Task {
            try? await Task.sleep(for: .milliseconds(1_200))
            guard pendingHotword == word else { return }
            pendingHotword = nil
            show(L("没能记住，打开 Type4Me 再试", "Couldn't remember it. Open Type4Me and try again"), kind: .error)
        }
    }

    // MARK: - Keys

    func undoLastInsertion() {
        if let cleared = lastClear {
            lastClear = nil
            canUndo = false
            restoreCleared(cleared)
            return
        }
        if let undo = lastCorrection {
            lastCorrection = nil
            canUndo = false
            Task { await undoCorrection(undo) }
            return
        }
        guard let controller, let insertion = lastInsertion else { return }
        let text = insertion.text
        let before = controller.proxy.documentContextBeforeInput ?? ""
        guard before.hasSuffix(text) else {
            show(L("光标位置变了，没法撤销", "The cursor moved, so this can't be undone"), kind: .error)
            invalidateUndo()
            return
        }
        for _ in 0..<text.count { controller.proxy.deleteBackward() }
        let replaced = insertion.replaced ?? ""
        if !replaced.isEmpty { controller.proxy.insertText(replaced) }
        lastInsertion = nil
        canUndo = false
        // The proxy's context updates after the edits land, so the anchor
        // comes from the text read before them.
        redo = Redo(
            insertion: insertion,
            documentID: controller.proxy.documentIdentifier,
            anchor: String((before.dropLast(text.count) + replaced).suffix(Self.anchorLength))
        )
        canRedo = true
        show(L("已撤销 · 可重做", "Undone · Redo available"))
    }

    func redoUndoneInsertion() {
        if let document = clearRedoDocument {
            clearRedoDocument = nil
            canRedo = false
            guard controller?.proxy.documentIdentifier == document else {
                show(L("输入框换了，没法重做", "The text field changed, so this can't be redone"), kind: .error)
                return
            }
            Task { await clearField() }
            return
        }
        guard let controller, let redo else { return }
        let before = controller.proxy.documentContextBeforeInput ?? ""
        let replaced = redo.insertion.replaced ?? ""
        guard controller.proxy.documentIdentifier == redo.documentID,
              String(before.suffix(Self.anchorLength)) == redo.anchor,
              before.hasSuffix(replaced)
        else {
            show(L("光标位置变了，没法重做", "The cursor moved, so this can't be redone"), kind: .error)
            invalidateUndo()
            return
        }
        // Undo put the original selection back; take it out again.
        for _ in 0..<replaced.count { controller.proxy.deleteBackward() }
        controller.proxy.insertText(redo.insertion.text)
        recordInsertion(redo.insertion.text, replacing: redo.insertion.replaced)
        show(L("已重做", "Redone"))
    }

    /// Enough of the text before the cursor to tell that it hasn't moved;
    /// the proxy only ever shows a window of it anyway.
    private static let anchorLength = 24

    /// Dictated text that the undo key can take back out.
    private func recordInsertion(_ text: String, replacing replaced: String? = nil) {
        lastCorrection = nil
        lastClear = nil
        lastInsertion = Insertion(text: text, replaced: replaced)
        canUndo = true
        redo = nil
        clearRedoDocument = nil
        canRedo = false
    }

    // MARK: - Clear

    /// Swiping up on delete empties the field. The press already deleted
    /// something on touch-down, so that goes back in first and undo
    /// restores the field whole.
    func clearAll(afterDeleting deletes: Int) {
        guard !applying else { return }
        let pressed = recentDeletions.suffix(deletes).reversed().joined()
        recentDeletions.removeAll()
        Task { await clearField(puttingBack: pressed) }
    }

    /// The proxy only shows a window of text either side of the cursor, so
    /// the cursor goes to the end first and the text before it is deleted a
    /// window at a time.
    private func clearField(puttingBack pressed: String = "") async {
        guard let proxy = controller?.proxy else { return }
        applying = true
        defer { applying = false }
        let documentID = proxy.documentIdentifier

        if !pressed.isEmpty {
            proxy.insertText(pressed)
            _ = await settled { (proxy.documentContextBeforeInput ?? "").hasSuffix(pressed) }
        }
        for _ in 0..<Self.clearWindowLimit {
            let after = proxy.documentContextAfterInput ?? ""
            guard !after.isEmpty else { break }
            // Going past the end is harmless; stopping short is not.
            proxy.adjustTextPosition(byCharacterOffset: after.utf16.count)
            guard await settled({ (proxy.documentContextAfterInput ?? "") != after }) else { break }
        }
        var cleared = ""
        for _ in 0..<Self.clearWindowLimit {
            let before = proxy.documentContextBeforeInput ?? ""
            guard !before.isEmpty else { break }
            for _ in 0..<before.count { proxy.deleteBackward() }
            cleared = before + cleared
            guard await settled({ (proxy.documentContextBeforeInput ?? "") != before }) else { break }
        }
        guard !cleared.isEmpty else { return }

        invalidateUndo()
        lastClear = Cleared(
            text: cleared,
            documentID: documentID,
            anchor: String((proxy.documentContextBeforeInput ?? "").suffix(Self.anchorLength))
        )
        canUndo = true
        show(L("已清空 · 可撤销", "Cleared · Undo available"))
    }

    private func restoreCleared(_ cleared: Cleared) {
        guard let proxy = controller?.proxy else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        guard proxy.documentIdentifier == cleared.documentID,
              String(before.suffix(Self.anchorLength)) == cleared.anchor
        else {
            show(L("光标位置变了，没法撤销", "The cursor moved, so this can't be undone"), kind: .error)
            invalidateUndo()
            return
        }
        proxy.insertText(cleared.text)
        clearRedoDocument = cleared.documentID
        canRedo = true
        show(L("已撤销 · 可重做", "Undone · Redo available"))
    }

    /// Waits for the proxy's context to catch up, which it does a moment
    /// after an edit or a cursor move.
    private func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<15 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Enough for any field a keyboard is used in; a huge document stops
    /// here instead of tying the keyboard up.
    private static let clearWindowLimit = 500
    private static let deletionMemory = 200

    func insert(_ text: String) {
        controller?.proxy.insertText(text)
        invalidateUndo()
        dropClipboardSuggestion()
    }

    /// The punctuation key's mark, then what a long press offers.
    var punctuation: (main: String, more: [String]) {
        fullWidthPunctuation ? ("，", ["。", "？", "！", "、"]) : (",", [".", "?", "!", "'"])
    }

    func togglePunctuationWidth() {
        fullWidthPunctuation.toggle()
        SharedSettings.fullWidthPunctuation = fullWidthPunctuation
    }

    /// The space-bar trackpad. Undo checks the text before the cursor
    /// itself, so moving away and back keeps it.
    func moveCursor(by offset: Int) {
        controller?.proxy.adjustTextPosition(byCharacterOffset: offset)
    }

    func deleteBackward() {
        guard let proxy = controller?.proxy else { return }
        let selected = proxy.selectedText ?? ""
        recentDeletions.append(selected.isEmpty ? (proxy.documentContextBeforeInput?.last.map(String.init) ?? "") : selected)
        if recentDeletions.count > Self.deletionMemory { recentDeletions.removeFirst() }
        proxy.deleteBackward()
        invalidateUndo()
        leaveCorrection()
        dropClipboardSuggestion()
    }

    func returnKey() {
        controller?.proxy.insertText("\n")
        invalidateUndo()
        leaveCorrection()
        dropClipboardSuggestion()
    }

    // MARK: - Clipboard

    /// Only the change count is read until there is a new copy to offer:
    /// it reads no content, so it never brings up the paste prompt.
    func refreshClipboard() {
        guard SharedSettings.keyboardClipboard, hasFullAccess, phase == .idle else {
            clipboardSuggestion = nil
            clipboardSuggestionCount = nil
            return
        }
        let pasteboard = UIPasteboard.general
        let count = pasteboard.changeCount
        guard count != clipboardSuggestionCount else { return }
        clipboardSuggestion = nil
        clipboardSuggestionCount = nil
        guard let handled = ClipboardMemory.handledCount else {
            // First run: whatever is already on the clipboard is old.
            ClipboardMemory.handledCount = count
            return
        }
        guard count != handled else { return }
        if ClipboardMemory.seenCount != count {
            ClipboardMemory.seenCount = count
            ClipboardMemory.seenAt = Date()
        }
        guard let seenAt = ClipboardMemory.seenAt, Date().timeIntervalSince(seenAt) < Self.clipboardFreshness,
              !isSensitiveField
        else { return }
        let text: String
        if let cached = Self.clipboardCache, cached.count == count {
            text = cached.text
        } else {
            // Each read may bring up the paste prompt, so a copy is read
            // once; if the extension was relaunched since, it is let go.
            guard ClipboardMemory.readCount != count, pasteboard.hasStrings,
                  // Password managers mark what they copy.
                  !pasteboard.types.contains("org.nspasteboard.ConcealedType")
            else { return }
            ClipboardMemory.readCount = count
            guard let read = pasteboard.string else { return }
            Self.clipboardCache = (count, read)
            text = read
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clipboardSuggestion = text
        clipboardSuggestionCount = count
    }

    func pasteClipboardSuggestion() {
        guard let text = clipboardSuggestion, let proxy = controller?.proxy else { return }
        let replaced = proxy.selectedText
        dropClipboardSuggestion()
        proxy.insertText(text)
        recordInsertion(text, replacing: replaced)
        leaveCorrection()
    }

    /// Typing, dictating, pasting or the close button puts the copy away
    /// for good.
    func dropClipboardSuggestion() {
        guard let count = clipboardSuggestionCount else { return }
        ClipboardMemory.handledCount = count
        Self.clipboardCache = nil
        clipboardSuggestion = nil
        clipboardSuggestionCount = nil
    }

    /// Like the system keyboard, only a recent copy is offered.
    private static let clipboardFreshness: TimeInterval = 180

    /// The copy as last read, kept in memory only, for as long as the
    /// extension's process lives.
    private static var clipboardCache: (count: Int, text: String)?

    /// Survives the extension being relaunched each time it appears.
    private enum ClipboardMemory {
        private static let handledKey = "keyboardClipboardHandled"
        private static let seenCountKey = "keyboardClipboardSeenCount"
        private static let seenAtKey = "keyboardClipboardSeenAt"
        private static let readCountKey = "keyboardClipboardReadCount"

        /// The last change already pasted, put away or written by us.
        static var handledCount: Int? {
            get { SharedContainer.defaults?.object(forKey: handledKey) as? Int }
            set { SharedContainer.defaults?.set(newValue, forKey: handledKey) }
        }

        static var seenCount: Int? {
            get { SharedContainer.defaults?.object(forKey: seenCountKey) as? Int }
            set { SharedContainer.defaults?.set(newValue, forKey: seenCountKey) }
        }

        /// The last change whose text was read; never the text itself.
        static var readCount: Int? {
            get { SharedContainer.defaults?.object(forKey: readCountKey) as? Int }
            set { SharedContainer.defaults?.set(newValue, forKey: readCountKey) }
        }

        /// When the keyboard first noticed `seenCount`.
        static var seenAt: Date? {
            get { SharedContainer.defaults?.object(forKey: seenAtKey) as? Date }
            set { SharedContainer.defaults?.set(newValue, forKey: seenAtKey) }
        }
    }

    /// The keyboard's own edits don't reliably reach `textDidChange`, so an
    /// edit made here drops the correction itself: speaking next inserts at
    /// the cursor instead of correcting a selection that is gone.
    private func leaveCorrection() {
        guard correctionInFlight == nil, correction != .none else { return }
        exitCorrection()
    }

    /// The "4" button next to the modes: more settings live in the app.
    func openSettings() {
        diag("点了「4」按钮打开设置", "The \"4\" button opened Settings")
        controller?.openContainingApp(SharedContainer.Link.settings)
    }

    func dismissKeyboard() {
        diag("点了收起键盘", "Hide keyboard tapped")
        controller?.dismissKeyboard()
    }

    func nextKeyboard() {
        diag("点了地球键，切换到下一个键盘（\(phaseDescription)）", "Globe key tapped, switching keyboards (\(phaseDescription))")
        controller?.advanceToNextInputMode()
    }

    var needsGlobeKey: Bool { controller?.needsInputModeSwitchKey ?? true }

    private func invalidateUndo() {
        lastCorrection = nil
        lastInsertion = nil
        lastClear = nil
        canUndo = false
        redo = nil
        clearRedoDocument = nil
        canRedo = false
    }

    private func show(_ message: String, kind: KeyboardNotice.Kind = .info, duration: Double = 2.5) {
        notice = KeyboardNotice(text: message, kind: kind)
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}
