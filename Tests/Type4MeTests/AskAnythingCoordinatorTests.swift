import Foundation
import XCTest
@testable import Type4Me

@MainActor
final class AskAnythingCoordinatorTests: XCTestCase {
    private var store: AskAnythingStore!
    private var coordinator: AskAnythingCoordinator!
    private var path: String!

    override func setUp() async throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-coordinator-\(UUID().uuidString).db").path
        store = AskAnythingStore(path: path)
        coordinator = AskAnythingCoordinator(store: store, historyEnabled: true)
    }

    override func tearDown() async throws {
        coordinator = nil
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        path = nil
    }

    func testFirstQuestionCreatesAndPersistsConversation() async throws {
        let requestID = UUID()
        coordinator.begin(requestID: requestID, question: "What is this?", selectedText: "Context")
        coordinator.appendAnswerDelta(requestID: requestID, delta: "An answer")
        coordinator.completeAnswer(requestID: requestID)
        await coordinator.waitForPersistence()

        let active = try XCTUnwrap(coordinator.activeConversation)
        XCTAssertEqual(active.turns.count, 1)
        XCTAssertEqual(active.turns[0].status, .completed)
        let persisted = try await store.fetchConversation(id: active.session.id)
        XCTAssertEqual(persisted, active)
    }

    func testFollowUpAppendsToSameConversationWithPreparedRequestID() async throws {
        let firstID = UUID()
        coordinator.begin(requestID: firstID, question: "First", selectedText: "Context")
        coordinator.appendAnswerDelta(requestID: firstID, delta: "Answer one")
        coordinator.completeAnswer(requestID: firstID)
        let sessionID = try XCTUnwrap(coordinator.activeConversation?.session.id)

        let request = try XCTUnwrap(coordinator.prepareFollowUpRequest())
        coordinator.markFollowUpRecordingStarted()
        XCTAssertTrue(coordinator.finishActiveFollowUp())
        coordinator.begin(requestID: request.requestID, question: "Second", selectedText: request.selectedText)
        coordinator.appendAnswerDelta(requestID: request.requestID, delta: "Answer two")
        coordinator.completeAnswer(requestID: request.requestID)
        await coordinator.waitForPersistence()

        let active = try XCTUnwrap(coordinator.activeConversation)
        XCTAssertEqual(active.session.id, sessionID)
        XCTAssertEqual(active.turns.map(\.question), ["First", "Second"])
        let fetched = try await store.fetchConversation(id: sessionID)
        let persisted = try XCTUnwrap(fetched)
        XCTAssertEqual(persisted.turns.count, 2)
    }

    func testCancelledFollowUpDoesNotAppendTurn() throws {
        let requestID = UUID()
        coordinator.begin(requestID: requestID, question: "First", selectedText: "Context")
        coordinator.completeAnswer(requestID: requestID)
        _ = try XCTUnwrap(coordinator.prepareFollowUpRequest())
        coordinator.markFollowUpRecordingStarted()

        XCTAssertTrue(coordinator.cancelActiveFollowUp())
        XCTAssertEqual(coordinator.activeConversation?.turns.count, 1)
        XCTAssertNil(coordinator.pendingFollowUpRequestID)
    }

    func testStaleDeltaCannotMutateCurrentTurn() throws {
        let requestID = UUID()
        coordinator.begin(requestID: requestID, question: "Question", selectedText: "Context")
        coordinator.appendAnswerDelta(requestID: UUID(), delta: "Stale")

        let conversation = try XCTUnwrap(coordinator.activeConversation)
        XCTAssertEqual(conversation.turns[0].answer, "")
    }

    func testEmptyQuestionDoesNotCreatePersistentConversation() async throws {
        let requestID = UUID()
        coordinator.begin(requestID: requestID, question: "   ", selectedText: "Context")
        coordinator.failAnswer(requestID: requestID, message: "Nothing recognized")
        await coordinator.waitForPersistence()

        XCTAssertNil(coordinator.activeConversation)
        let sessions = try await store.fetchSessions(pageSize: 10)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testHistoryDisabledKeepsConversationOnlyInMemory() async throws {
        coordinator.historyEnabled = false
        let requestID = UUID()
        coordinator.begin(requestID: requestID, question: "Ephemeral", selectedText: "Context")
        coordinator.appendAnswerDelta(requestID: requestID, delta: "Answer")
        coordinator.completeAnswer(requestID: requestID)
        await coordinator.waitForPersistence()

        XCTAssertNotNil(coordinator.activeConversation)
        let sessions = try await store.fetchSessions(pageSize: 10)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testActiveAnsweringConversationCannotBeDeleted() async throws {
        let requestID = UUID()
        coordinator.begin(requestID: requestID, question: "Question", selectedText: "Context")
        let sessionID = try XCTUnwrap(coordinator.activeConversation?.session.id)

        do {
            try await coordinator.deleteSession(id: sessionID)
            XCTFail("Expected active conversation deletion to fail")
        } catch {
            XCTAssertNotNil(error as? AskAnythingStoreError)
        }
    }

    func testBrowsingHistoryIsNotReplacedByActiveAnswerDeltas() async throws {
        let historicalID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let historicalSession = AskAnythingSession(
            id: historicalID,
            title: "Historical",
            usesCustomTitle: false,
            sourceText: "Old source",
            createdAt: now,
            updatedAt: now,
            status: .active
        )
        let historicalTurn = AskAnythingTurn(
            id: UUID(), sessionID: historicalID, ordinal: 1,
            question: "Old question", answer: "Old answer", status: .completed,
            errorMessage: nil, createdAt: now, updatedAt: now, completedAt: now
        )
        try await store.createConversation(session: historicalSession, firstTurn: historicalTurn)

        let requestID = UUID()
        coordinator.begin(requestID: requestID, question: "Live question", selectedText: "Live source")
        try await coordinator.selectSession(id: historicalID)
        coordinator.appendAnswerDelta(requestID: requestID, delta: "Live answer")

        XCTAssertEqual(coordinator.selectedConversation?.session.id, historicalID)
        XCTAssertEqual(coordinator.turns.map(\.question), ["Old question"])
        XCTAssertEqual(coordinator.activeConversation?.turns.first?.answer, "Live answer")
    }

    func testStaleCompletionCannotFinishCurrentRequest() throws {
        let requestID = UUID()
        coordinator.begin(requestID: requestID, question: "Question", selectedText: "Context")

        coordinator.completeAnswer(requestID: UUID())

        XCTAssertEqual(coordinator.activeConversation?.turns.first?.status, .pending)
        XCTAssertNotNil(coordinator.activeBinding)
    }
}
