import AppKit
import SwiftUI

@MainActor
@Observable
final class SelectionAskState {
    struct Turn: Identifiable, Equatable {
        let id: UUID
        var question: String
        var answer: String
        var isLoading: Bool
        var errorMessage: String?
        var isInterrupted: Bool

        init(
            id: UUID = UUID(),
            question: String,
            answer: String,
            isLoading: Bool,
            errorMessage: String? = nil,
            isInterrupted: Bool = false
        ) {
            self.id = id
            self.question = question
            self.answer = answer
            self.isLoading = isLoading
            self.errorMessage = errorMessage
            self.isInterrupted = isInterrupted
        }
    }

    enum Phase: Equatable {
        case idle
        case loading
        case answered(String)
        case error(String)
    }

    var question = ""
    var selectedText = ""
    var phase: Phase = .idle
    var turns: [Turn] = []
    var isRecordingFollowUp = false
    var followUpShortcutHint = ""
    var isHistoryEnabled = true

    /// Whether the answer UI should run its indeterminate loading animation.
    /// Treating `.idle` as loading keeps a hidden, eagerly-created panel
    /// repainting continuously even when Type4Me is otherwise inactive.
    var isAnswerLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var activeAnswer: String {
        switch phase {
        case .answered(let answer):
            return answer
        case .loading, .idle, .error:
            return turns.last?.answer ?? ""
        }
    }
}

enum SelectionAskPromptBuilder {
    enum ContextSource: String {
        case selection
        case none
    }

    static func contextSource(from context: PromptContext) -> ContextSource {
        let selected = context.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUsableSelectedText(selected) { return .selection }
        return .none
    }

    static func contextText(from context: PromptContext) -> String {
        switch contextSource(from: context) {
        case .selection:
            return context.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        case .none:
            return ""
        }
    }

    static func requestText(mode: ProcessingMode, context: PromptContext) -> String {
        context.expandContextVariables(mode.prompt)
    }

    static func requestText(
        mode: ProcessingMode,
        context: PromptContext,
        question: String,
        conversationContext: String = ""
    ) -> String {
        var result = ""
        var remaining = mode.prompt[...]
        let conversationContext = conversationContext.trimmingCharacters(in: .whitespacesAndNewlines)

        while let openRange = remaining.range(of: "{") {
            result += remaining[remaining.startIndex..<openRange.lowerBound]
            remaining = remaining[openRange.lowerBound...]

            if remaining.hasPrefix("{selected}") {
                result += context.selectedText
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 10)...]
            } else if remaining.hasPrefix("{clipboard}") {
                result += context.clipboardText
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 11)...]
            } else if remaining.hasPrefix("{tools_json}") {
                result += ActionRegistry.toolsJSON()
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 12)...]
            } else if remaining.hasPrefix("{conversation}") {
                result += conversationContext
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 14)...]
            } else if remaining.hasPrefix("{text}") {
                result += question
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 6)...]
            } else {
                result += "{"
                remaining = remaining[remaining.index(after: remaining.startIndex)...]
            }
        }

        result += remaining
        if !conversationContext.isEmpty, !mode.prompt.contains("{conversation}") {
            result += "\n\n# 上方会话上下文\n```text\n\(conversationContext)\n```"
        }
        return result
    }

    static func isUsableSelectedText(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let placeholders: Set<String> = [
            "selection",
            "selected text",
            "selected",
            "选中文本",
            "所选文本",
        ]
        return !placeholders.contains(normalized)
    }
}

@MainActor
final class SelectionAskPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        minSize = NSSize(width: 560, height: 440)
        maxSize = NSSize(width: 820, height: 760)
        contentMinSize = minSize
        contentMaxSize = maxSize
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode != 53 else {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private struct SelectionAskThemedRoot: View {
    let content: SelectionAskView
    let onThemeChange: @MainActor (SettingsTheme) -> Void

    @AppStorage(SettingsTheme.storageKey)
    private var themeRaw = SettingsTheme.defaultValue.rawValue

    var body: some View {
        content
            .preferredColorScheme(SettingsTheme.resolve(themeRaw).colorScheme)
            .onChange(of: themeRaw) { _, newValue in
                onThemeChange(SettingsTheme.resolve(newValue))
            }
    }
}

@MainActor
final class SelectionAskController {
    let coordinator: AskAnythingCoordinator
    private var state: SelectionAskState { coordinator.state }
    private let panel: SelectionAskPanel
    private var requestGeneration = 0
    private let onStartFollowUp: (SelectionAskRequestContext) -> Bool
    private let onFinishFollowUp: () -> Void
    private let onCancelFollowUp: () -> Void
    private let onOpenInType4Me: (UUID) -> Void
    private let onBecameReleasable: () -> Void
    private var currentRequestID: UUID?

    init(
        coordinator: AskAnythingCoordinator? = nil,
        onStartFollowUp: @escaping (SelectionAskRequestContext) -> Bool = { _ in false },
        onStartNewQuestion: @escaping (SelectionAskRequestContext) -> Bool = { _ in false },
        onFinishFollowUp: @escaping () -> Void = {},
        onCancelFollowUp: @escaping () -> Void = {},
        onOpenInType4Me: @escaping (UUID) -> Void = { _ in },
        onBecameReleasable: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator ?? AskAnythingCoordinator(
            store: AskAnythingStore(path: ":memory:"),
            historyEnabled: false
        )
        self.onStartFollowUp = onStartFollowUp
        self.onFinishFollowUp = onFinishFollowUp
        self.onCancelFollowUp = onCancelFollowUp
        self.onOpenInType4Me = onOpenInType4Me
        self.onBecameReleasable = onBecameReleasable
        self.coordinator.configureRuntime(
            onStartFollowUp: onStartFollowUp,
            onStartNewQuestion: onStartNewQuestion,
            onFinishFollowUp: onFinishFollowUp,
            onCancelFollowUp: onCancelFollowUp
        )
        let size = NSSize(width: 680, height: 560)
        let panel = SelectionAskPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.appearance = SettingsTheme.resolve(
            UserDefaults.standard.string(forKey: SettingsTheme.storageKey) ?? SettingsTheme.defaultValue.rawValue
        ).appearance
        self.panel = panel

        let view = SelectionAskView(state: self.coordinator.state) { [weak self] in
            self?.close()
        } onFollowUp: { [weak self] in
            _ = self?.performPrimaryFollowUpAction()
        } onCancelFollowUp: { [weak self] in
            _ = self?.handleActiveRecordingAction(.cancel)
        } onOpenInType4Me: { [weak self] in
            self?.openInType4Me()
        }
        let targetPanel = panel
        let themedRoot = SelectionAskThemedRoot(content: view) { [weak targetPanel] theme in
            targetPanel?.appearance = theme.appearance
        }
        let hosting = NSHostingView(rootView: themedRoot)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(NSRect(origin: .zero, size: size), display: false)
        panel.onEscape = { [weak self] in
            self?.handleEscape()
        }
    }

    var isVisible: Bool { panel.isVisible }
    var isReleasable: Bool {
        !panel.isVisible && !state.isRecordingFollowUp && currentRequestID == nil
    }

    var isRecordingFollowUp: Bool { state.isRecordingFollowUp }
    var turns: [SelectionAskState.Turn] { state.turns }

    func updateFollowUpShortcutHint(_ hint: String) {
        coordinator.updateFollowUpShortcutHint(hint)
    }

    func begin(question: String, selectedText: String) {
        begin(
            requestID: coordinator.pendingFollowUpRequestID ?? UUID(),
            question: question,
            selectedText: selectedText
        )
    }

    func begin(
        requestID: UUID,
        question: String,
        selectedText: String,
        contextWasTruncated: Bool = false
    ) {
        requestGeneration &+= 1
        currentRequestID = requestID
        coordinator.begin(
            requestID: requestID,
            question: question,
            selectedText: selectedText,
            contextWasTruncated: contextWasTruncated
        )
        if coordinator.presentation == .panel {
            show()
        } else {
            hide()
        }
    }

    func appendAnswerDelta(_ delta: String) {
        guard let currentRequestID else {
            coordinator.appendTransientAnswerDelta(delta)
            return
        }
        coordinator.appendAnswerDelta(requestID: currentRequestID, delta: delta)
    }

    func completeAnswer() {
        guard let currentRequestID else { return }
        coordinator.completeAnswer(requestID: currentRequestID)
        self.currentRequestID = nil
        notifyIfReleasable()
    }

    func completeAnswer(requestID: UUID) {
        guard currentRequestID == requestID else { return }
        coordinator.completeAnswer(requestID: requestID)
        currentRequestID = nil
        notifyIfReleasable()
    }

    func appendAnswerDelta(requestID: UUID, delta: String) {
        guard currentRequestID == requestID else { return }
        coordinator.appendAnswerDelta(requestID: requestID, delta: delta)
    }

    func showError(requestID: UUID, message: String) {
        guard currentRequestID == requestID else { return }
        coordinator.failAnswer(requestID: requestID, message: message)
        currentRequestID = nil
        notifyIfReleasable()
    }

    func showTransientError(_ message: String) {
        coordinator.appendTransientAnswerDelta(message)
        if !state.turns.isEmpty {
            state.turns[state.turns.count - 1].errorMessage = message
            state.turns[state.turns.count - 1].isLoading = false
        }
        state.phase = .error(message)
    }

    func showError(_ message: String) {
        if let currentRequestID {
            coordinator.failAnswer(requestID: currentRequestID, message: message)
            self.currentRequestID = nil
            notifyIfReleasable()
        } else {
            showTransientError(message)
        }
    }

    func recordingDidEnd(_ action: RecordingControlAction) {
        coordinator.recordingDidEnd(action)
        notifyIfReleasable()
    }

    func hide() {
        panel.orderOut(nil)
        notifyIfReleasable()
    }

    func close() {
        _ = handleActiveRecordingAction(.cancel)
        hide()
    }

    func releasePanelResources() {
        panel.orderOut(nil)
        panel.contentView = nil
        panel.onEscape = nil
    }

    private func show() {
        positionNearMouse()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    @discardableResult
    func startFollowUpRecording() -> Bool {
        coordinator.startFollowUpRecording()
    }

    @discardableResult
    func finishActiveFollowUp() -> Bool {
        coordinator.finishActiveFollowUp()
    }

    @discardableResult
    func cancelActiveFollowUp() -> Bool {
        coordinator.cancelActiveFollowUp()
    }

    @discardableResult
    func handleActiveRecordingAction(_ action: RecordingControlAction) -> Bool {
        switch action {
        case .finish:
            return finishActiveFollowUp()
        case .cancel:
            return cancelActiveFollowUp()
        }
    }

    @discardableResult
    func performPrimaryFollowUpAction() -> Bool {
        if state.isRecordingFollowUp {
            return handleActiveRecordingAction(.finish)
        }
        return startFollowUpRecording()
    }

    func handleEscape() {
        guard panel.isVisible else { return }
        if state.isRecordingFollowUp {
            _ = handleActiveRecordingAction(.cancel)
        } else {
            hide()
        }
    }

    private func openInType4Me() {
        guard let sessionID = coordinator.activeConversation?.session.id else { return }
        onOpenInType4Me(sessionID)
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        let x = visible.midX - frame.width / 2
        let y = visible.midY - frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func notifyIfReleasable() {
        guard isReleasable else { return }
        onBecameReleasable()
    }
}
