import XCTest
@testable import Type4Me

@MainActor
final class SelectionAskControllerTests: XCTestCase {
    func testRecordingCoordinatorDoesNotEvaluateFollowUpPathUntilAction() {
        var followUpChecks = 0
        let coordinator = RecordingControlCoordinator(
            onFollowUpAction: { _ in
                followUpChecks += 1
                return false
            },
            onStandardAction: { _ in }
        )

        XCTAssertEqual(followUpChecks, 0)
        coordinator.perform(.finish)
        XCTAssertEqual(followUpChecks, 1)
    }

    func testHiddenCompletedPanelBecomesReleasable() {
        var releaseNotifications = 0
        let controller = SelectionAskController(onBecameReleasable: {
            releaseNotifications += 1
        })
        controller.begin(question: "Question", selectedText: "Context")

        controller.hide()
        XCTAssertFalse(controller.isReleasable)
        controller.completeAnswer()

        XCTAssertTrue(controller.isReleasable)
        XCTAssertEqual(releaseNotifications, 1)
    }

    func testIdleStateDoesNotRunAnswerLoadingAnimation() {
        let state = SelectionAskState()

        XCTAssertFalse(state.isAnswerLoading)

        state.phase = .loading
        XCTAssertTrue(state.isAnswerLoading)

        state.phase = .answered("Answer")
        XCTAssertFalse(state.isAnswerLoading)

        state.phase = .error("Failed")
        XCTAssertFalse(state.isAnswerLoading)
    }

    func testEscapeClosesVisiblePanelWhenFollowUpIsIdle() {
        let controller = SelectionAskController()
        controller.begin(question: "What does this mean?", selectedText: "Context")

        XCTAssertTrue(controller.isVisible)

        controller.handleEscape()

        XCTAssertFalse(controller.isVisible)
    }

    func testEscapeCancelsActiveFollowUpWithoutClosingPanel() {
        var cancellationCount = 0
        let controller = SelectionAskController(
            onStartFollowUp: { _ in true },
            onCancelFollowUp: {
                cancellationCount += 1
            }
        )
        controller.begin(question: "First question", selectedText: "Context")
        controller.completeAnswer()
        XCTAssertTrue(controller.startFollowUpRecording())
        XCTAssertTrue(controller.isRecordingFollowUp)

        controller.handleEscape()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(controller.isRecordingFollowUp)
        XCTAssertTrue(controller.isVisible)
        controller.hide()
    }

    func testCloseCancelsActiveFollowUpAndClosesPanel() {
        var cancelCount = 0
        let controller = SelectionAskController(
            onStartFollowUp: { _ in true },
            onCancelFollowUp: { cancelCount += 1 }
        )
        controller.begin(question: "First question", selectedText: "Context")
        controller.completeAnswer()
        XCTAssertTrue(controller.startFollowUpRecording())

        controller.close()

        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(controller.isRecordingFollowUp)
        XCTAssertFalse(controller.isVisible)
    }

    func testFailedFollowUpDoesNotChangeRecordingState() {
        let controller = SelectionAskController(onStartFollowUp: { _ in false })
        controller.begin(question: "First question", selectedText: "Context")

        XCTAssertFalse(controller.startFollowUpRecording())
        XCTAssertFalse(controller.isRecordingFollowUp)
        controller.hide()
    }

    func testFinishPreservesPendingTurnAndInvokesBackendOnce() {
        var finishCount = 0
        let controller = SelectionAskController(
            onStartFollowUp: { _ in true },
            onFinishFollowUp: { finishCount += 1 }
        )
        controller.begin(question: "First question", selectedText: "Context")
        controller.appendAnswerDelta("First answer")
        controller.completeAnswer()
        XCTAssertTrue(controller.startFollowUpRecording())

        XCTAssertTrue(controller.finishActiveFollowUp())
        XCTAssertFalse(controller.finishActiveFollowUp())
        XCTAssertFalse(controller.cancelActiveFollowUp())
        controller.begin(question: "Follow-up question", selectedText: "Context")

        XCTAssertEqual(finishCount, 1)
        XCTAssertFalse(controller.isRecordingFollowUp)
        XCTAssertEqual(controller.turns.map(\.question), ["First question", "Follow-up question"])
        controller.hide()
    }

    func testCancelClearsPendingTurnAndInvokesBackendOnce() {
        var cancelCount = 0
        let controller = SelectionAskController(
            onStartFollowUp: { _ in true },
            onCancelFollowUp: { cancelCount += 1 }
        )
        controller.begin(question: "First question", selectedText: "Context")
        controller.appendAnswerDelta("First answer")
        controller.completeAnswer()
        XCTAssertTrue(controller.startFollowUpRecording())

        XCTAssertTrue(controller.cancelActiveFollowUp())
        XCTAssertFalse(controller.cancelActiveFollowUp())
        XCTAssertFalse(controller.finishActiveFollowUp())
        controller.begin(question: "New question", selectedText: "Context")

        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(controller.isRecordingFollowUp)
        XCTAssertEqual(controller.turns.map(\.question), ["New question"])
        controller.hide()
    }

    func testPrimaryFollowUpActionStartsThenFinishes() {
        var startCount = 0
        var finishCount = 0
        let controller = SelectionAskController(
            onStartFollowUp: { _ in
                startCount += 1
                return true
            },
            onFinishFollowUp: { finishCount += 1 }
        )
        controller.begin(question: "First question", selectedText: "Context")
        controller.completeAnswer()

        XCTAssertTrue(controller.performPrimaryFollowUpAction())
        XCTAssertTrue(controller.isRecordingFollowUp)
        XCTAssertTrue(controller.performPrimaryFollowUpAction())

        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(finishCount, 1)
        XCTAssertFalse(controller.isRecordingFollowUp)
        controller.hide()
    }

    func testAutomaticFinishClearsRecordingAndPreservesPendingTurn() {
        let controller = SelectionAskController(onStartFollowUp: { _ in true })
        controller.begin(question: "First question", selectedText: "Context")
        controller.completeAnswer()
        XCTAssertTrue(controller.startFollowUpRecording())

        controller.recordingDidEnd(.finish)
        controller.begin(question: "Automatically finished", selectedText: "Context")

        XCTAssertFalse(controller.isRecordingFollowUp)
        XCTAssertEqual(controller.turns.map(\.question), ["First question", "Automatically finished"])
        controller.hide()
    }

    func testRecordingErrorClearsRecordingAndPendingTurn() {
        let controller = SelectionAskController(onStartFollowUp: { _ in true })
        controller.begin(question: "First question", selectedText: "Context")
        controller.completeAnswer()
        XCTAssertTrue(controller.startFollowUpRecording())

        controller.recordingDidEnd(.cancel)
        controller.begin(question: "Question after error", selectedText: "Context")

        XCTAssertFalse(controller.isRecordingFollowUp)
        XCTAssertEqual(controller.turns.map(\.question), ["Question after error"])
        controller.hide()
    }

    func testCoordinatorRoutesActiveFollowUpActionsBeforeStandardRecording() {
        var finishCount = 0
        var cancelCount = 0
        var standardActions: [RecordingControlAction] = []
        let controller = SelectionAskController(
            onStartFollowUp: { _ in true },
            onFinishFollowUp: { finishCount += 1 },
            onCancelFollowUp: { cancelCount += 1 }
        )
        let coordinator = RecordingControlCoordinator(
            onFollowUpAction: { controller.handleActiveRecordingAction($0) },
            onStandardAction: { standardActions.append($0) }
        )
        controller.begin(question: "First question", selectedText: "Context")
        controller.completeAnswer()
        XCTAssertTrue(controller.startFollowUpRecording())

        coordinator.perform(.finish)

        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(cancelCount, 0)
        XCTAssertTrue(standardActions.isEmpty)
        XCTAssertFalse(controller.isRecordingFollowUp)

        XCTAssertTrue(controller.startFollowUpRecording())
        coordinator.perform(.cancel)

        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertTrue(standardActions.isEmpty)
        XCTAssertFalse(controller.isRecordingFollowUp)
        controller.hide()
    }

    func testCoordinatorUsesStandardPathWhenFollowUpIsIdle() {
        var standardActions: [RecordingControlAction] = []
        let controller = SelectionAskController()
        let coordinator = RecordingControlCoordinator(
            onFollowUpAction: { controller.handleActiveRecordingAction($0) },
            onStandardAction: { standardActions.append($0) }
        )

        coordinator.perform(.finish)
        coordinator.perform(.cancel)

        XCTAssertEqual(standardActions, [.finish, .cancel])
    }

    func testCoordinatorCancelsFollowUpEvenWhenAppPhaseAlreadyDrifted() {
        let appState = AppState()
        appState.barPhase = .processing
        var cancelCount = 0
        var standardCount = 0
        let controller = SelectionAskController(
            onStartFollowUp: { _ in true },
            onCancelFollowUp: { cancelCount += 1 }
        )
        let coordinator = RecordingControlCoordinator(
            onFollowUpAction: { controller.handleActiveRecordingAction($0) },
            onStandardAction: { _ in standardCount += 1 }
        )
        controller.begin(question: "First question", selectedText: "Context")
        controller.completeAnswer()
        XCTAssertTrue(controller.startFollowUpRecording())

        coordinator.perform(.cancel)

        XCTAssertEqual(appState.barPhase, .processing)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(standardCount, 0)
        XCTAssertFalse(controller.isRecordingFollowUp)
        controller.hide()
    }

    func testCannotStartFollowUpWhileCurrentAnswerIsGenerating() {
        let controller = SelectionAskController(onStartFollowUp: { _ in true })
        controller.begin(question: "First question", selectedText: "Context")

        XCTAssertFalse(controller.startFollowUpRecording())
        XCTAssertFalse(controller.isRecordingFollowUp)
        controller.hide()
    }

    func testFollowUpStartGateRejectsCancelledDelayedStart() {
        var gate = SelectionAskFollowUpStartGate()
        let token = gate.begin()

        XCTAssertTrue(gate.allowsStart(token: token, isFollowUpActive: true, phase: .preparing))

        gate.invalidate()

        XCTAssertFalse(gate.allowsStart(token: token, isFollowUpActive: true, phase: .preparing))
    }

    func testFollowUpStartGateRequiresActiveFollowUpAndRecordingPhase() {
        var gate = SelectionAskFollowUpStartGate()
        let token = gate.begin()

        XCTAssertFalse(gate.allowsStart(token: token, isFollowUpActive: false, phase: .preparing))
        XCTAssertFalse(gate.allowsStart(token: token, isFollowUpActive: true, phase: .processing))
        XCTAssertTrue(gate.allowsStart(token: token, isFollowUpActive: true, phase: .recording))
    }
}
