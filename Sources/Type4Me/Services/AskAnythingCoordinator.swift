import Foundation
import Observation

struct SelectionAskRequestContext: Equatable, Sendable {
    let requestID: UUID
    let sessionID: UUID?
    let turnID: UUID?
    let selectedText: String
    let overridesSelectedText: Bool
    let conversationContext: String
    let contextWasTruncated: Bool
}

struct AskAnythingRequestBinding: Equatable, Sendable {
    let requestID: UUID
    let sessionID: UUID
    let turnID: UUID
    let generation: Int
}

enum AskAnythingPresentation: Equatable, Sendable {
    case panel
    case mainWindow
}

@MainActor
@Observable
final class AskAnythingCoordinator {
    static let historyEnabledDefaultsKey = "tf_askAnythingHistoryEnabled"

    let state: SelectionAskState
    private(set) var activeConversation: AskAnythingConversation?
    private(set) var selectedConversation: AskAnythingConversation?
    private(set) var selectedSessionID: UUID?
    private(set) var activeBinding: AskAnythingRequestBinding?
    private(set) var persistenceError: String?
    private(set) var contextWasTruncated = false
    private(set) var presentation: AskAnythingPresentation = .panel

    var historyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(historyEnabled, forKey: Self.historyEnabledDefaultsKey)
            state.isHistoryEnabled = historyEnabled
        }
    }

    private let store: AskAnythingStore
    private var generation = 0
    private var preparedFollowUp: AskAnythingRequestBinding?
    private var transientRequestID: UUID?
    private var persistenceTask: Task<Void, Never>?
    private var streamingFlushTask: Task<Void, Never>?
    private var onStartFollowUp: (SelectionAskRequestContext) -> Bool = { _ in false }
    private var onStartNewQuestion: (SelectionAskRequestContext) -> Bool = { _ in false }
    private var onFinishFollowUp: () -> Void = {}
    private var onCancelFollowUp: () -> Void = {}

    init(
        store: AskAnythingStore = AskAnythingStore(),
        state: SelectionAskState? = nil,
        historyEnabled: Bool? = nil
    ) {
        self.store = store
        self.state = state ?? SelectionAskState()
        if let historyEnabled {
            self.historyEnabled = historyEnabled
        } else if UserDefaults.standard.object(forKey: Self.historyEnabledDefaultsKey) == nil {
            self.historyEnabled = true
        } else {
            self.historyEnabled = UserDefaults.standard.bool(forKey: Self.historyEnabledDefaultsKey)
        }
        self.state.isHistoryEnabled = self.historyEnabled
    }

    var isRecordingFollowUp: Bool { state.isRecordingFollowUp }
    var turns: [SelectionAskState.Turn] { state.turns }
    var hasActiveConversation: Bool { activeConversation != nil }
    var pendingFollowUpRequestID: UUID? { preparedFollowUp?.requestID }

    func configureRuntime(
        onStartFollowUp: @escaping (SelectionAskRequestContext) -> Bool,
        onStartNewQuestion: @escaping (SelectionAskRequestContext) -> Bool = { _ in false },
        onFinishFollowUp: @escaping () -> Void,
        onCancelFollowUp: @escaping () -> Void
    ) {
        self.onStartFollowUp = onStartFollowUp
        self.onStartNewQuestion = onStartNewQuestion
        self.onFinishFollowUp = onFinishFollowUp
        self.onCancelFollowUp = onCancelFollowUp
    }

    func restoreAfterLaunch() async {
        do {
            try await store.markUnfinishedTurnsInterrupted()
        } catch {
            persistenceError = userFacingPersistenceError(error)
        }
    }

    func updateFollowUpShortcutHint(_ hint: String) {
        state.followUpShortcutHint = hint
    }

    func prepareForExternalNewQuestion() {
        presentation = .panel
    }

    func presentInMainWindow() {
        presentation = .mainWindow
    }

    func begin(
        requestID: UUID = UUID(),
        question: String,
        selectedText: String,
        contextWasTruncated: Bool = false
    ) {
        streamingFlushTask?.cancel()
        state.question = question
        state.selectedText = selectedText
        state.phase = .loading
        state.isRecordingFollowUp = false
        self.contextWasTruncated = contextWasTruncated

        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuestion.isEmpty else {
            preparedFollowUp = nil
            activeBinding = nil
            transientRequestID = requestID
            state.turns = [SelectionAskState.Turn(question: question, answer: "", isLoading: true)]
            return
        }
        transientRequestID = nil

        let now = Self.storageDate()
        if let prepared = preparedFollowUp, prepared.requestID == requestID,
           var conversation = activeConversation,
           prepared.sessionID == conversation.session.id {
            let turn = AskAnythingTurn(
                id: prepared.turnID,
                sessionID: prepared.sessionID,
                ordinal: conversation.turns.count + 1,
                question: normalizedQuestion,
                answer: "",
                status: .pending,
                errorMessage: nil,
                createdAt: now,
                updatedAt: now,
                completedAt: nil
            )
            conversation.turns.append(turn)
            conversation.session.status = .answering
            conversation.session.updatedAt = now
            activeConversation = conversation
            selectedConversation = conversation
            activeBinding = prepared
            preparedFollowUp = nil
            state.selectedText = conversation.session.sourceText
            syncStateTurns(from: conversation)
            enqueuePersistence { store in
                try await store.appendTurn(turn)
            }
            return
        }

        generation &+= 1
        let sessionID = UUID()
        let turnID = UUID()
        let session = AskAnythingSession(
            id: sessionID,
            title: Self.defaultTitle(for: normalizedQuestion),
            usesCustomTitle: false,
            sourceText: selectedText.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            updatedAt: now,
            status: .answering
        )
        let turn = AskAnythingTurn(
            id: turnID,
            sessionID: sessionID,
            ordinal: 1,
            question: normalizedQuestion,
            answer: "",
            status: .pending,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now,
            completedAt: nil
        )
        let conversation = AskAnythingConversation(session: session, turns: [turn])
        activeConversation = conversation
        selectedConversation = conversation
        selectedSessionID = sessionID
        activeBinding = AskAnythingRequestBinding(
            requestID: requestID,
            sessionID: sessionID,
            turnID: turnID,
            generation: generation
        )
        syncStateTurns(from: conversation)
        enqueuePersistence { store in
            try await store.createConversation(session: session, firstTurn: turn)
        }
    }

    func appendAnswerDelta(requestID: UUID, delta: String) {
        guard !delta.isEmpty, let binding = matchingBinding(requestID) else { return }
        guard var conversation = activeConversation,
              let index = conversation.turns.firstIndex(where: { $0.id == binding.turnID })
        else { return }
        conversation.turns[index].answer += delta
        conversation.turns[index].status = .streaming
        conversation.turns[index].updatedAt = Self.storageDate()
        conversation.session.status = .answering
        conversation.session.updatedAt = conversation.turns[index].updatedAt
        activeConversation = conversation
        if selectedSessionID == conversation.session.id {
            selectedConversation = conversation
        }
        if isPresenting(conversation) {
            syncStateTurns(from: conversation)
            state.phase = .answered(conversation.turns[index].answer)
        }
        scheduleStreamingFlush(binding: binding)
    }

    func appendTransientAnswerDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if !state.turns.isEmpty {
            state.turns[state.turns.count - 1].answer += delta
            state.turns[state.turns.count - 1].isLoading = false
        }
        switch state.phase {
        case .answered(let current): state.phase = .answered(current + delta)
        case .loading, .idle: state.phase = .answered(delta)
        case .error: break
        }
    }

    func completeAnswer(requestID: UUID) {
        guard let binding = matchingBinding(requestID), var conversation = activeConversation,
              let index = conversation.turns.firstIndex(where: { $0.id == binding.turnID })
        else {
            guard transientRequestID == requestID else { return }
            completeTransientAnswer()
            transientRequestID = nil
            return
        }
        streamingFlushTask?.cancel()
        let now = Self.storageDate()
        conversation.turns[index].status = .completed
        conversation.turns[index].updatedAt = now
        conversation.turns[index].completedAt = now
        conversation.session.status = .active
        conversation.session.updatedAt = now
        activeConversation = conversation
        if selectedSessionID == conversation.session.id {
            selectedConversation = conversation
        }
        if isPresenting(conversation) {
            syncStateTurns(from: conversation)
            state.phase = .answered(conversation.turns[index].answer)
        }
        activeBinding = nil
        let turn = conversation.turns[index]
        enqueuePersistence { store in
            try await store.updateTurnAnswer(
                id: turn.id,
                answer: turn.answer,
                status: .completed,
                errorMessage: nil,
                updatedAt: turn.updatedAt
            )
        }
    }

    func failAnswer(requestID: UUID, message: String) {
        guard let binding = matchingBinding(requestID), var conversation = activeConversation,
              let index = conversation.turns.firstIndex(where: { $0.id == binding.turnID })
        else {
            guard transientRequestID == requestID else { return }
            state.phase = .error(message)
            if !state.turns.isEmpty {
                state.turns[state.turns.count - 1].errorMessage = message
                state.turns[state.turns.count - 1].isLoading = false
            }
            transientRequestID = nil
            return
        }
        streamingFlushTask?.cancel()
        let now = Self.storageDate()
        conversation.turns[index].status = .failed
        conversation.turns[index].errorMessage = message
        conversation.turns[index].updatedAt = now
        conversation.turns[index].completedAt = now
        conversation.session.status = .failed
        conversation.session.updatedAt = now
        activeConversation = conversation
        if selectedSessionID == conversation.session.id {
            selectedConversation = conversation
        }
        if isPresenting(conversation) {
            syncStateTurns(from: conversation)
            state.phase = .error(message)
        }
        activeBinding = nil
        let turn = conversation.turns[index]
        enqueuePersistence { store in
            try await store.updateTurnAnswer(
                id: turn.id,
                answer: turn.answer,
                status: .failed,
                errorMessage: message,
                updatedAt: turn.updatedAt
            )
        }
    }

    func prepareFollowUpRequest() -> SelectionAskRequestContext? {
        guard !state.isRecordingFollowUp, activeBinding == nil else { return nil }
        if presentation == .mainWindow, let selectedConversation {
            activeConversation = selectedConversation
        }
        guard let conversation = activeConversation else { return nil }
        generation &+= 1
        let binding = AskAnythingRequestBinding(
            requestID: UUID(),
            sessionID: conversation.session.id,
            turnID: UUID(),
            generation: generation
        )
        let prepared = AskAnythingContextBuilder.build(
            conversation: conversation,
            currentQuestion: "",
            promptTemplateCharacters: ProcessingMode.selectionAsk.prompt.count
        )
        contextWasTruncated = prepared.wasTruncated
        preparedFollowUp = binding
        return SelectionAskRequestContext(
            requestID: binding.requestID,
            sessionID: binding.sessionID,
            turnID: binding.turnID,
            selectedText: prepared.selectedText,
            overridesSelectedText: true,
            conversationContext: prepared.conversationText,
            contextWasTruncated: prepared.wasTruncated
        )
    }

    func markFollowUpRecordingStarted() {
        state.isRecordingFollowUp = true
    }

    func startFollowUpRecording() -> Bool {
        guard let context = prepareFollowUpRequest() else { return false }
        guard onStartFollowUp(context) else {
            preparedFollowUp = nil
            return false
        }
        markFollowUpRecordingStarted()
        return true
    }

    func startNewQuestionRecording() -> Bool {
        guard !state.isRecordingFollowUp, activeBinding == nil else { return false }
        generation &+= 1
        let context = SelectionAskRequestContext(
            requestID: UUID(),
            sessionID: nil,
            turnID: nil,
            selectedText: "",
            overridesSelectedText: true,
            conversationContext: "",
            contextWasTruncated: false
        )
        guard onStartNewQuestion(context) else { return false }
        presentation = .mainWindow
        state.isRecordingFollowUp = true
        return true
    }

    func performPrimaryFollowUpAction() -> Bool {
        if state.isRecordingFollowUp {
            return finishActiveFollowUp()
        }
        return startFollowUpRecording()
    }

    func finishActiveFollowUp() -> Bool {
        guard state.isRecordingFollowUp else { return false }
        state.isRecordingFollowUp = false
        onFinishFollowUp()
        return true
    }

    func cancelActiveFollowUp() -> Bool {
        guard state.isRecordingFollowUp else { return false }
        state.isRecordingFollowUp = false
        preparedFollowUp = nil
        transientRequestID = nil
        generation &+= 1
        onCancelFollowUp()
        return true
    }

    func recordingDidEnd(_ action: RecordingControlAction) {
        guard state.isRecordingFollowUp else { return }
        state.isRecordingFollowUp = false
        if action == .cancel {
            preparedFollowUp = nil
            generation &+= 1
        }
    }

    func selectSession(id: UUID) async throws {
        guard let conversation = try await store.fetchConversation(id: id) else {
            throw AskAnythingStoreError.invalidRecord
        }
        selectedConversation = conversation
        presentation = .mainWindow
        selectedSessionID = id
        if activeBinding == nil, !state.isRecordingFollowUp {
            activeConversation = conversation
        }
        state.question = conversation.turns.last?.question ?? ""
        state.selectedText = conversation.session.sourceText
        state.phase = conversation.session.status == .failed
            ? .error(conversation.turns.last?.errorMessage ?? L("回答失败", "Answer failed"))
            : .answered(conversation.turns.last?.answer ?? "")
        syncStateTurns(from: conversation)
    }

    func fetchSessions(
        pageSize: Int,
        before cursor: AskAnythingSessionCursor? = nil
    ) async throws -> [AskAnythingSessionSummary] {
        try await store.fetchSessions(pageSize: pageSize, before: cursor)
    }

    func searchSessions(query: String, limit: Int = 100) async throws -> [AskAnythingSessionSummary] {
        try await store.searchSessions(query: query, limit: limit)
    }

    func renameSession(id: UUID, title: String) async throws {
        try await store.renameSession(id: id, title: title)
        if activeConversation?.session.id == id {
            activeConversation?.session.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            activeConversation?.session.usesCustomTitle = true
        }
        if selectedConversation?.session.id == id {
            selectedConversation?.session.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            selectedConversation?.session.usesCustomTitle = true
        }
    }

    func deleteSession(id: UUID) async throws {
        guard activeBinding?.sessionID != id, !(state.isRecordingFollowUp && activeConversation?.session.id == id) else {
            throw AskAnythingStoreError.executeFailed(L("请先结束当前追问。", "Finish the current follow-up first."))
        }
        try await store.deleteSession(id: id)
        if activeConversation?.session.id == id {
            activeConversation = nil
        }
        if selectedConversation?.session.id == id {
            clearSelectedConversation()
        }
    }

    func clearHistory() async throws {
        guard activeBinding == nil, !state.isRecordingFollowUp else {
            throw AskAnythingStoreError.executeFailed(L("请先结束当前追问。", "Finish the current follow-up first."))
        }
        try await store.deleteAll()
        clearActiveConversation()
    }

    func createEmptyDraftForMainWindow() {
        guard activeBinding == nil, !state.isRecordingFollowUp else { return }
        activeConversation = nil
        selectedConversation = nil
        selectedSessionID = nil
        preparedFollowUp = nil
        state.question = ""
        state.selectedText = ""
        state.phase = .idle
        state.turns = []
    }

    func waitForPersistence() async {
        await persistenceTask?.value
    }

    private func matchingBinding(_ requestID: UUID) -> AskAnythingRequestBinding? {
        guard let binding = activeBinding,
              binding.requestID == requestID,
              binding.generation == generation
        else { return nil }
        return binding
    }

    private func isPresenting(_ conversation: AskAnythingConversation) -> Bool {
        presentation == .panel || selectedSessionID == conversation.session.id
    }

    private func completeTransientAnswer() {
        if !state.turns.isEmpty {
            state.turns[state.turns.count - 1].isLoading = false
        }
        if case .loading = state.phase { state.phase = .answered("") }
    }

    private func scheduleStreamingFlush(binding: AskAnythingRequestBinding) {
        streamingFlushTask?.cancel()
        streamingFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self,
                  self.matchingBinding(binding.requestID) == binding,
                  let conversation = self.activeConversation,
                  let turn = conversation.turns.first(where: { $0.id == binding.turnID })
            else { return }
            self.enqueuePersistence { store in
                try await store.updateTurnAnswer(
                    id: turn.id,
                    answer: turn.answer,
                    status: .streaming,
                    errorMessage: nil,
                    updatedAt: turn.updatedAt,
                    notify: false
                )
            }
        }
    }

    private func enqueuePersistence(
        _ operation: @escaping @Sendable (AskAnythingStore) async throws -> Void
    ) {
        guard historyEnabled else { return }
        let previous = persistenceTask
        let store = store
        persistenceTask = Task { [weak self] in
            await previous?.value
            do {
                try await operation(store)
            } catch {
                self?.persistenceError = self?.userFacingPersistenceError(error)
            }
        }
    }

    private func syncStateTurns(from conversation: AskAnythingConversation) {
        state.turns = conversation.turns.map { turn in
            SelectionAskState.Turn(
                id: turn.id,
                question: turn.question,
                answer: turn.answer,
                isLoading: turn.status == .pending || turn.status == .streaming,
                errorMessage: turn.errorMessage,
                isInterrupted: turn.status == .interrupted
            )
        }
    }

    private func clearActiveConversation() {
        streamingFlushTask?.cancel()
        activeConversation = nil
        selectedConversation = nil
        selectedSessionID = nil
        activeBinding = nil
        preparedFollowUp = nil
        transientRequestID = nil
        state.question = ""
        state.selectedText = ""
        state.phase = .idle
        state.turns = []
        state.isRecordingFollowUp = false
    }

    private func clearSelectedConversation() {
        selectedConversation = nil
        selectedSessionID = nil
        state.question = ""
        state.selectedText = ""
        state.phase = .idle
        state.turns = []
    }

    private static func defaultTitle(for question: String) -> String {
        let collapsed = question
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(80))
    }

    private static func storageDate() -> Date {
        let milliseconds = (Date().timeIntervalSince1970 * 1_000).rounded(.down)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private func userFacingPersistenceError(_ error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
