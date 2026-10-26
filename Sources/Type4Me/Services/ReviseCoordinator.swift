import AppKit
import ApplicationServices
import Foundation
import Type4MeReviseCore

struct ReviseLearningResumePlan: Sendable {
    let shouldResume: Bool
    let modeID: UUID

    init(shouldResume: Bool, modeID: UUID) {
        self.shouldResume = shouldResume
        self.modeID = modeID
    }
}

struct ReviseTarget: @unchecked Sendable {
    let id: UUID
    var revisionGeneration: Int
    var tracking: TrackedInjectionContext
    let sourceRecordID: String
    let sourceModeID: UUID
    let sourceModeKind: ReviseSourceModeKind
    let createdAt: Date
    var expiresAt: Date
    var learningResumePlan: ReviseLearningResumePlan?
    var isDeletionTombstone: Bool

    init(
        id: UUID = UUID(),
        revisionGeneration: Int = 0,
        tracking: TrackedInjectionContext,
        sourceRecordID: String,
        sourceModeID: UUID,
        sourceModeKind: ReviseSourceModeKind,
        createdAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(600),
        learningResumePlan: ReviseLearningResumePlan? = nil,
        isDeletionTombstone: Bool = false
    ) {
        self.id = id
        self.revisionGeneration = revisionGeneration
        self.tracking = tracking
        self.sourceRecordID = sourceRecordID
        self.sourceModeID = sourceModeID
        self.sourceModeKind = sourceModeKind
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.learningResumePlan = learningResumePlan
        self.isDeletionTombstone = isDeletionTombstone
    }
}

struct RevisePreparedTarget: Sendable {
    let transactionID: UUID
    let targetID: UUID
    let targetGeneration: Int
    let sourceRecordID: String
    let currentText: String
    let currentFullValue: String
    let currentRange: NSRange
    let confidence: ResolutionConfidence
    let controlKind: ReviseControlKind
    let sourceModeKind: ReviseSourceModeKind
    let learningResumePlan: ReviseLearningResumePlan?
    let isDeletionTombstone: Bool
}

struct ReviseTransaction: Sendable {
    enum Phase: Sendable {
        case reserved
        case recording
        case processing
        case committing
    }

    let prepared: RevisePreparedTarget
    var phase: Phase
    let startedAt: Date
}

struct ReviseUndoTicket: @unchecked Sendable {
    let id: UUID
    let targetID: UUID
    let targetGeneration: Int
    let revisionID: String
    let expectedAfterContext: TrackedInjectionContext
    let beforeText: String
    let afterText: String
    let expiresAt: Date
}

actor ReviseCoordinator {
    static let shared = ReviseCoordinator()

    private var target: ReviseTarget?
    private var transaction: ReviseTransaction?
    private var undoTicket: ReviseUndoTicket?
    private var expiryTask: Task<Void, Never>?

    private let accessibilityClient: ReviseAccessibilityClient
    private let replacementEngine: TrackedTextReplacementEngine
    private let settingsStore: ReviseSettingsStore

    init(
        accessibilityClient: ReviseAccessibilityClient = SystemReviseAccessibilityClient.shared,
        replacementEngine: TrackedTextReplacementEngine? = nil,
        settingsStore: ReviseSettingsStore = .shared
    ) {
        self.accessibilityClient = accessibilityClient
        self.replacementEngine = replacementEngine ?? TrackedTextReplacementEngine(accessibilityClient: accessibilityClient)
        self.settingsStore = settingsStore
    }

    // MARK: - Target Registration

    func registerTarget(
        context: TrackedInjectionContext,
        sourceModeKind: ReviseSourceModeKind,
        learningResumePlan: ReviseLearningResumePlan? = nil
    ) async {
        expiryTask?.cancel()
        expiryTask = nil
        transaction = nil
        undoTicket = nil

        let settings = settingsStore.load()
        guard settings.enabled && ReviseSettingsStore.isRuntimeEnabled else {
            target = nil
            return
        }

        if settings.isExcluded(bundleIdentifier: context.bundleIdentifier) {
            target = nil
            return
        }

        let newTarget = ReviseTarget(
            tracking: context,
            sourceRecordID: context.sourceRecordID,
            sourceModeID: context.modeID,
            sourceModeKind: sourceModeKind,
            createdAt: context.createdAt,
            expiresAt: context.createdAt.addingTimeInterval(600),
            learningResumePlan: learningResumePlan,
            isDeletionTombstone: false
        )
        self.target = newTarget

        let targetID = newTarget.id
        let gen = newTarget.revisionGeneration
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            await self?.handleExpiry(targetID: targetID, generation: gen)
        }
    }

    private func handleExpiry(targetID: UUID, generation: Int) {
        guard let current = target, current.id == targetID, current.revisionGeneration == generation else {
            return
        }
        target = nil
        undoTicket = nil
    }

    /// A privacy-safe readiness check for entry points such as the menu bar.
    /// It intentionally verifies only the stored target's lifetime and whether
    /// another revision owns the coordinator; accessibility validation remains
    /// in `prepareForRecording()` immediately before recording starts.
    func hasAvailableTarget() -> Bool {
        guard settingsStore.isReviseActive(), transaction == nil, let target else {
            return false
        }
        guard target.expiresAt > Date() else {
            self.target = nil
            undoTicket = nil
            return false
        }
        return true
    }

    // MARK: - Preparation for Recording

    func prepareForRecording() async -> Result<RevisePreparedTarget, ReviseFailure> {
        let isReviseActive = settingsStore.isReviseActive()
        guard isReviseActive else {
            return .failure(.disabled)
        }

        guard transaction == nil else {
            return .failure(.busy)
        }

        guard let currentTarget = target else {
            return .failure(.noTarget)
        }

        guard currentTarget.expiresAt > Date() else {
            target = nil
            return .failure(.expired)
        }

        guard let snapshot = try? accessibilityClient.focusedControl() else {
            return .failure(.controlChanged)
        }

        guard let snapshotPID = snapshot.processIdentifier,
              snapshotPID == currentTarget.tracking.processIdentifier,
              let snapshotBundle = snapshot.bundleIdentifier,
              snapshotBundle.caseInsensitiveCompare(currentTarget.tracking.bundleIdentifier) == .orderedSame else {
            return .failure(.appChanged)
        }

        guard let element = snapshot.element, CFEqual(element, currentTarget.tracking.element) else {
            return .failure(.controlChanged)
        }

        guard snapshot.isEditable, !snapshot.isSecure else {
            return .failure(.sensitive)
        }

        let settings = settingsStore.load()
        if settings.isExcluded(bundleIdentifier: snapshotBundle) {
            return .failure(.excludedApp)
        }

        // Deletion tombstone check
        if currentTarget.isDeletionTombstone {
            let prepared = RevisePreparedTarget(
                transactionID: UUID(),
                targetID: currentTarget.id,
                targetGeneration: currentTarget.revisionGeneration,
                sourceRecordID: currentTarget.sourceRecordID,
                currentText: "",
                currentFullValue: snapshot.value ?? "",
                currentRange: NSRange(location: 0, length: 0),
                confidence: .exact,
                controlKind: snapshot.supportsSingleLineOnly ? .singleLine : .multiLine,
                sourceModeKind: currentTarget.sourceModeKind,
                learningResumePlan: currentTarget.learningResumePlan,
                isDeletionTombstone: true
            )
            self.transaction = ReviseTransaction(
                prepared: prepared,
                phase: .recording,
                startedAt: Date()
            )
            return .success(prepared)
        }

        guard let currentFullValue = snapshot.value else {
            return .failure(.targetMissing)
        }

        let locationResult = InjectedTextLocator.locate(
            baseline: currentTarget.tracking.baselineValue,
            injectedRange: currentTarget.tracking.injectedRange,
            current: currentFullValue
        )

        guard case .success(let located) = locationResult else {
            if case .failure(let err) = locationResult {
                if err == .invalidRange || err == .insufficientAnchor || err == .boundaryConflict {
                    return .failure(.targetAmbiguous)
                }
            }
            return .failure(.targetAmbiguous)
        }

        guard located.text.count <= ReviseInputBudget.maxTargetCharacters else {
            return .failure(.targetTooLong)
        }

        // Finalize post-injection learning observation before revise
        await PostInjectionLearningCoordinator.shared.finalizeBeforeRevise()

        // Re-read value to ensure no change during finalization
        guard let recheckedValue = try? accessibilityClient.value(of: element),
              recheckedValue == currentFullValue else {
            return .failure(.targetChangedDuringProcessing)
        }

        let controlKind: ReviseControlKind = snapshot.supportsSingleLineOnly ? .singleLine : .multiLine
        let transactionID = UUID()
        let prepared = RevisePreparedTarget(
            transactionID: transactionID,
            targetID: currentTarget.id,
            targetGeneration: currentTarget.revisionGeneration,
            sourceRecordID: currentTarget.sourceRecordID,
            currentText: located.text,
            currentFullValue: currentFullValue,
            currentRange: located.currentRange,
            confidence: located.confidence,
            controlKind: controlKind,
            sourceModeKind: currentTarget.sourceModeKind,
            learningResumePlan: currentTarget.learningResumePlan,
            isDeletionTombstone: false
        )

        self.transaction = ReviseTransaction(
            prepared: prepared,
            phase: .recording,
            startedAt: Date()
        )

        return .success(prepared)
    }

    // MARK: - Transaction Management

    func setProcessing(transactionID: UUID) {
        if transaction?.prepared.transactionID == transactionID {
            transaction?.phase = .processing
        }
    }

    func cancel(transactionID: UUID) {
        if transaction?.prepared.transactionID == transactionID {
            guard transaction?.phase != .committing else { return }
            transaction = nil
        }
    }

    func cancelActiveTransaction() {
        guard transaction?.phase != .committing else { return }
        transaction = nil
    }

    // MARK: - Commit

    func commit(
        transactionID: UUID,
        candidate: String,
        revisionID: String = UUID().uuidString
    ) async -> Result<TrackedTextReplacementSuccess, ReviseFailure> {
        guard var currentTransaction = transaction,
              currentTransaction.prepared.transactionID == transactionID,
              let currentTarget = target,
              currentTarget.id == currentTransaction.prepared.targetID,
              currentTarget.revisionGeneration == currentTransaction.prepared.targetGeneration else {
            return .failure(.staleTransaction)
        }

        currentTransaction.phase = .committing
        self.transaction = currentTransaction

        let req = TrackedTextReplacementRequest(
            element: currentTarget.tracking.element,
            processIdentifier: currentTarget.tracking.processIdentifier,
            bundleIdentifier: currentTarget.tracking.bundleIdentifier,
            expectedFullValue: currentTransaction.prepared.currentFullValue,
            expectedRange: currentTransaction.prepared.currentRange,
            expectedText: currentTransaction.prepared.currentText,
            replacementText: candidate,
            placeholderCandidates: currentTarget.tracking.placeholderCandidates
        )

        let replaceResult = await replacementEngine.replace(req)
        self.transaction = nil

        switch replaceResult {
        case .success(let success):
            var updatedTarget = currentTarget
            updatedTarget.revisionGeneration += 1
            if let newContext = success.trackingContext {
                updatedTarget.tracking = newContext
            }
            if candidate.isEmpty {
                updatedTarget.isDeletionTombstone = true
            } else {
                updatedTarget.isDeletionTombstone = false
            }
            self.target = updatedTarget

            if let context = success.trackingContext {
                self.undoTicket = ReviseUndoTicket(
                    id: UUID(),
                    targetID: updatedTarget.id,
                    targetGeneration: updatedTarget.revisionGeneration,
                    revisionID: revisionID,
                    expectedAfterContext: context,
                    beforeText: currentTransaction.prepared.currentText,
                    afterText: candidate,
                    expiresAt: updatedTarget.expiresAt
                )
            }

            return .success(success)

        case .failure(let err):
            DebugFileLogger.log(
                "revise_replace: failure=\(err.rawValue) bundle=\(currentTarget.tracking.bundleIdentifier)"
            )
            switch err {
            case .appMismatch: return .failure(.appChanged)
            case .controlMismatch: return .failure(.controlChanged)
            case .secureOrReadOnly: return .failure(.sensitive)
            case .valueChangedBeforeWrite: return .failure(.targetChangedDuringProcessing)
            case .rangeInvalid: return .failure(.targetAmbiguous)
            case .textMismatch: return .failure(.targetChangedDuringProcessing)
            case .singleLineViolation: return .failure(.validationRejected)
            case .noChange: return .failure(.replacementFailed)
            case .controlReset: return .failure(.replacementFailed)
            case .verificationMismatch: return .failure(.replacementFailed)
            case .partialFailure: return .failure(.partialFailure)
            }
        }
    }

    // MARK: - Undo

    func undo(ticketID: UUID? = nil) async -> Result<String, ReviseFailure> {
        if transaction?.phase != .committing {
            transaction = nil
        }

        guard let ticket = undoTicket else {
            return .failure(.nothingToUndo)
        }

        if let ticketID, ticket.id != ticketID {
            return .failure(.nothingToUndo)
        }

        guard var currentTarget = target,
              currentTarget.id == ticket.targetID,
              currentTarget.revisionGeneration == ticket.targetGeneration,
              ticket.expiresAt > Date() else {
            return .failure(.nothingToUndo)
        }

        guard let snapshot = try? accessibilityClient.focusedControl(),
              let element = snapshot.element,
              CFEqual(element, currentTarget.tracking.element),
              let currentVal = snapshot.value else {
            return .failure(.controlChanged)
        }

        let req = TrackedTextReplacementRequest(
            element: currentTarget.tracking.element,
            processIdentifier: currentTarget.tracking.processIdentifier,
            bundleIdentifier: currentTarget.tracking.bundleIdentifier,
            expectedFullValue: currentVal,
            expectedRange: currentTarget.tracking.injectedRange,
            expectedText: ticket.afterText,
            replacementText: ticket.beforeText,
            placeholderCandidates: currentTarget.tracking.placeholderCandidates
        )

        let replaceResult = await replacementEngine.replace(req)
        switch replaceResult {
        case .success(let success):
            currentTarget.revisionGeneration += 1
            if let newContext = success.trackingContext {
                currentTarget.tracking = newContext
            }
            currentTarget.isDeletionTombstone = false
            self.target = currentTarget
            self.undoTicket = nil
            return .success(ticket.beforeText)

        case .failure:
            return .failure(.replacementFailed)
        }
    }

    func clearTarget() {
        expiryTask?.cancel()
        expiryTask = nil
        target = nil
        transaction = nil
        undoTicket = nil
    }

    func getLatestUndoTicketID() -> UUID? {
        undoTicket?.id
    }
}
