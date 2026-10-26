import SwiftUI
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

    private weak var controller: KeyboardViewController?
    private var pendingPing: UUID?
    private var requestID: UUID?
    private var startDocumentID: UUID?
    private var lastInsertion: String?
    private var redo: Redo?

    /// What an undo took out, and where, so redo puts it back only in the
    /// same place.
    private struct Redo {
        let text: String
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
    }

    func disappeared() {
        if case .recording = phase, let requestID {
            DictationChannel.send(KeyboardCommand(kind: .cancel, requestID: requestID))
        }
        resetToIdle()
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
        if let contentType, Self.sensitiveContentTypes.contains(contentType) {
            field.isSensitive = true
            return field
        }
        guard SharedSettings.intelliSenseContext else { return field }
        field.before = String((proxy.documentContextBeforeInput ?? "").suffix(FieldContext.beforeLimit))
        field.after = String((proxy.documentContextAfterInput ?? "").prefix(FieldContext.afterLimit))
        return field
    }

    /// Fields whose text must never leave the phone. Secure fields don't
    /// even get a third-party keyboard; these are the rest.
    private static let sensitiveContentTypes: Set<UITextContentType> = [
        .password, .newPassword, .oneTimeCode,
        .creditCardNumber, .creditCardSecurityCode, .creditCardExpiration,
    ]

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
        liveText = ""
        level = 0
        notice = nil
        phase = .recording(locked: false)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        DictationChannel.send(KeyboardCommand(
            kind: .start, requestID: id, mode: mode, field: fieldContext()
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
            controller.proxy.insertText(text)
            recordInsertion(text)
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

    // MARK: - Keys

    func undoLastInsertion() {
        guard let controller, let text = lastInsertion else { return }
        let before = controller.proxy.documentContextBeforeInput ?? ""
        guard before.hasSuffix(text) else {
            show(L("光标位置变了，没法撤销", "The cursor moved, so this can't be undone"), kind: .error)
            invalidateUndo()
            return
        }
        for _ in 0..<text.count { controller.proxy.deleteBackward() }
        lastInsertion = nil
        canUndo = false
        // The proxy's context updates after the deletes land, so the anchor
        // comes from the text read before them.
        redo = Redo(
            text: text,
            documentID: controller.proxy.documentIdentifier,
            anchor: String(before.dropLast(text.count).suffix(Self.anchorLength))
        )
        canRedo = true
        show(L("已撤销 · 可重做", "Undone · Redo available"))
    }

    func redoUndoneInsertion() {
        guard let controller, let redo else { return }
        let before = controller.proxy.documentContextBeforeInput ?? ""
        guard controller.proxy.documentIdentifier == redo.documentID,
              String(before.suffix(Self.anchorLength)) == redo.anchor
        else {
            show(L("光标位置变了，没法重做", "The cursor moved, so this can't be redone"), kind: .error)
            invalidateUndo()
            return
        }
        controller.proxy.insertText(redo.text)
        recordInsertion(redo.text)
        show(L("已重做", "Redone"))
    }

    /// Enough of the text before the cursor to tell that it hasn't moved;
    /// the proxy only ever shows a window of it anyway.
    private static let anchorLength = 24

    /// Dictated text that the undo key can take back out.
    private func recordInsertion(_ text: String) {
        lastInsertion = text
        canUndo = true
        redo = nil
        canRedo = false
    }

    func insert(_ text: String) {
        controller?.proxy.insertText(text)
        invalidateUndo()
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
