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

    @Published var liveness: Liveness = .checking
    @Published var phase: Phase = .idle
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

    private weak var controller: KeyboardViewController?
    private var pendingPing: UUID?
    private var requestID: UUID?
    private var startDocumentID: UUID?
    private var lastInsertion: Insertion?
    private var lastCorrection: CorrectionUndo?
    private var redo: Redo?
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
    private var watchdog: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var observing = false

    init(controller: KeyboardViewController) {
        self.controller = controller
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
    }

    func disappeared() {
        if case .recording = phase, let requestID {
            DictationChannel.send(KeyboardCommand(kind: .cancel, requestID: requestID))
        }
        resetToIdle()
        correction = .none
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
        switch phase {
        case .idle:
            if liveness == .ready {
                // A new dictation replaces whatever an undo took out.
                redo = nil
                canRedo = false
                startRecording()
            } else {
                openApp()
            }
        case .recording(locked: true):
            stopRecording()
        default:
            break
        }
    }

    func micReleased(cancelled: Bool, locked: Bool) {
        guard case .recording(let wasLocked) = phase, !wasLocked else { return }
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
        phase = .recording(locked: true)
        holdZone = .none
        holdPull = 0
    }

    /// The done key that replaces lock once recording is locked.
    func finishFromKey() {
        guard phase == .recording(locked: true) else { return }
        stopRecording()
    }

    /// The cancel key that replaces undo while recording.
    func cancelFromKey() {
        guard case .recording = phase else { return }
        #if DEBUG
        if SharedSettings.keyboardDemo { demoTask?.cancel(); resetToIdle(); return }
        #endif
        cancelRecording()
    }

    private func startRecording() {
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
            resetToIdle()
            liveness = .needsApp
            openApp()
        }
        acknowledged = false
    }

    private var acknowledged = false

    private func stopRecording() {
        #if DEBUG
        if SharedSettings.keyboardDemo { stopDemo(); return }
        #endif
        guard let requestID else { return }
        phase = .processing
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Read again on release, as the Mac refreshes before processing.
        DictationChannel.send(KeyboardCommand(kind: .stop, requestID: requestID, field: fieldContext()))
        watchdog?.cancel()
        watchdog = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, self.requestID == requestID else { return }
            resetToIdle()
            show(L("处理超时，没有拿到结果", "Timed out waiting for the result"), kind: .error)
        }
    }

    private func cancelRecording() {
        guard let requestID else { return }
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

    private func openApp() {
        controller?.openContainingApp(SharedContainer.Link.startSession)
    }

    // MARK: - State from the app

    private func stateDidChange() {
        guard let state = DictationChannel.readState() else { return }
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
                openApp()
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
        redo = nil
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
        lastInsertion = Insertion(text: text, replaced: replaced)
        canUndo = true
        redo = nil
        canRedo = false
    }

    func insert(_ text: String) {
        controller?.proxy.insertText(text)
        invalidateUndo()
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
        controller?.proxy.deleteBackward()
        invalidateUndo()
    }

    func returnKey() {
        controller?.proxy.insertText("\n")
        invalidateUndo()
    }

    /// The "4" button next to the modes: more settings live in the app.
    func openSettings() {
        controller?.openContainingApp(SharedContainer.Link.settings)
    }

    func dismissKeyboard() {
        controller?.dismissKeyboard()
    }

    func nextKeyboard() {
        controller?.advanceToNextInputMode()
    }

    var needsGlobeKey: Bool { controller?.needsInputModeSwitchKey ?? true }

    private func invalidateUndo() {
        lastCorrection = nil
        lastInsertion = nil
        canUndo = false
        redo = nil
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
