import Foundation
import SQLite3
import XCTest
@testable import Type4Me

final class AskAnythingStoreTests: XCTestCase {
    private var store: AskAnythingStore!
    private var path: String!

    override func setUp() {
        super.setUp()
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-anything-\(UUID().uuidString).db").path
        store = AskAnythingStore(path: path)
    }

    override func tearDown() {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        path = nil
        super.tearDown()
    }

    func testCreateConversationPersistsSessionAndFirstTurn() async throws {
        let conversation = makeConversation(question: "What does this mean?")
        try await store.createConversation(
            session: conversation.session,
            firstTurn: conversation.turns[0]
        )

        let loaded = try await store.fetchConversation(id: conversation.session.id)
        XCTAssertEqual(loaded, conversation)
    }

    func testAppendAndCompleteTurnUpdatesConversation() async throws {
        let conversation = makeConversation()
        try await store.createConversation(
            session: conversation.session,
            firstTurn: conversation.turns[0]
        )
        try await store.updateTurnAnswer(
            id: conversation.turns[0].id,
            answer: "First answer",
            status: .completed,
            errorMessage: nil,
            updatedAt: conversation.turns[0].updatedAt
        )

        let followUp = AskAnythingTurn(
            id: UUID(),
            sessionID: conversation.session.id,
            ordinal: 2,
            question: "And then?",
            answer: "",
            status: .pending,
            errorMessage: nil,
            createdAt: Date(timeIntervalSince1970: 300),
            updatedAt: Date(timeIntervalSince1970: 300),
            completedAt: nil
        )
        try await store.appendTurn(followUp)
        try await store.updateTurnAnswer(
            id: followUp.id,
            answer: "Second answer",
            status: .completed,
            errorMessage: nil,
            updatedAt: Date(timeIntervalSince1970: 301)
        )

        let fetched = try await store.fetchConversation(id: conversation.session.id)
        let loaded = try XCTUnwrap(fetched)
        XCTAssertEqual(loaded.turns.count, 2)
        XCTAssertEqual(loaded.turns[1].answer, "Second answer")
        XCTAssertEqual(loaded.turns[1].status, .completed)
        XCTAssertEqual(loaded.session.status, .active)
    }

    func testDuplicateOrdinalIsRejected() async throws {
        let conversation = makeConversation()
        try await store.createConversation(
            session: conversation.session,
            firstTurn: conversation.turns[0]
        )
        var duplicate = conversation.turns[0]
        duplicate = AskAnythingTurn(
            id: UUID(),
            sessionID: duplicate.sessionID,
            ordinal: duplicate.ordinal,
            question: "Duplicate",
            answer: "",
            status: .pending,
            errorMessage: nil,
            createdAt: duplicate.createdAt,
            updatedAt: duplicate.updatedAt,
            completedAt: nil
        )
        do {
            try await store.appendTurn(duplicate)
            XCTFail("Expected duplicate ordinal to fail")
        } catch {
            XCTAssertTrue(error is AskAnythingStoreError)
        }
    }

    func testPaginationUsesUpdatedAtThenIDOrdering() async throws {
        var conversations: [AskAnythingConversation] = []
        for offset in 0..<4 {
            let conversation = makeConversation(
                question: "Question \(offset)",
                date: Date(timeIntervalSince1970: Double(100 + offset))
            )
            conversations.append(conversation)
            try await store.createConversation(
                session: conversation.session,
                firstTurn: conversation.turns[0]
            )
        }

        let first = try await store.fetchSessions(pageSize: 2)
        XCTAssertEqual(first.map(\.title), ["Question 3", "Question 2"])
        let cursor = AskAnythingSessionCursor(updatedAt: first[1].updatedAt, id: first[1].id)
        let second = try await store.fetchSessions(pageSize: 2, before: cursor)
        XCTAssertEqual(second.map(\.title), ["Question 1", "Question 0"])
    }

    func testSearchMatchesTitleSourceQuestionAnswerAndEscapesWildcards() async throws {
        let cases = [
            ("Alpha title", "plain", "question", "answer"),
            ("Title", "中文上下文", "question", "answer"),
            ("Title", "plain", "MixedCaseQuestion", "answer"),
            ("Title", "plain", "question", "literal 100%_done"),
        ]
        for (index, item) in cases.enumerated() {
            var conversation = makeConversation(
                question: item.2,
                sourceText: item.1,
                date: Date(timeIntervalSince1970: Double(100 + index))
            )
            conversation.session.title = item.0
            conversation.turns[0].answer = item.3
            conversation.turns[0].status = .completed
            try await store.createConversation(
                session: conversation.session,
                firstTurn: conversation.turns[0]
            )
        }

        let alphaMatches = try await store.searchSessions(query: "alpha")
        let chineseMatches = try await store.searchSessions(query: "中文")
        let mixedCaseMatches = try await store.searchSessions(query: "mixedcase")
        let escapedMatches = try await store.searchSessions(query: "%_")
        XCTAssertEqual(alphaMatches.count, 1)
        XCTAssertEqual(chineseMatches.count, 1)
        XCTAssertEqual(mixedCaseMatches.count, 1)
        XCTAssertEqual(escapedMatches.count, 1)
    }

    func testRenameAndDeleteCascade() async throws {
        let conversation = makeConversation()
        try await store.createConversation(
            session: conversation.session,
            firstTurn: conversation.turns[0]
        )
        try await store.renameSession(id: conversation.session.id, title: "Renamed")
        let fetched = try await store.fetchConversation(id: conversation.session.id)
        let loaded = try XCTUnwrap(fetched)
        XCTAssertEqual(loaded.session.title, "Renamed")
        XCTAssertTrue(loaded.session.usesCustomTitle)

        try await store.deleteSession(id: conversation.session.id)
        let deleted = try await store.fetchConversation(id: conversation.session.id)
        XCTAssertNil(deleted)
    }

    func testMarkUnfinishedTurnsInterruptedCoversPendingAndStreaming() async throws {
        let first = makeConversation(question: "Pending")
        try await store.createConversation(session: first.session, firstTurn: first.turns[0])

        var second = makeConversation(question: "Streaming", date: Date(timeIntervalSince1970: 200))
        second.turns[0].status = .streaming
        second.turns[0].answer = "Partial"
        try await store.createConversation(session: second.session, firstTurn: second.turns[0])

        try await store.markUnfinishedTurnsInterrupted(at: Date(timeIntervalSince1970: 500))

        let fetchedFirst = try await store.fetchConversation(id: first.session.id)
        let fetchedSecond = try await store.fetchConversation(id: second.session.id)
        let loadedFirst = try XCTUnwrap(fetchedFirst)
        let loadedSecond = try XCTUnwrap(fetchedSecond)
        XCTAssertEqual(loadedFirst.turns[0].status, .interrupted)
        XCTAssertEqual(loadedSecond.turns[0].status, .interrupted)
        XCTAssertEqual(loadedSecond.turns[0].answer, "Partial")
    }

    func testDeleteAllRemovesEveryConversation() async throws {
        for index in 0..<3 {
            let conversation = makeConversation(
                question: "Question \(index)",
                date: Date(timeIntervalSince1970: Double(index + 1))
            )
            try await store.createConversation(
                session: conversation.session,
                firstTurn: conversation.turns[0]
            )
        }
        try await store.deleteAll()
        let remaining = try await store.fetchSessions(pageSize: 10)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testShrinkMemoryDoesNotThrowOrCorrupt() async throws {
        let conversation = makeConversation(question: "Shrink test")
        try await store.createConversation(
            session: conversation.session,
            firstTurn: conversation.turns[0]
        )
        await store.shrinkMemory()
        let loaded = try await store.fetchConversation(id: conversation.session.id)
        XCTAssertEqual(loaded?.session.title, "Shrink test")
    }

    private func makeConversation(
        question: String = "Question",
        sourceText: String = "Selected text",
        date: Date = Date(timeIntervalSince1970: 100)
    ) -> AskAnythingConversation {
        let sessionID = UUID()
        let turn = AskAnythingTurn(
            id: UUID(),
            sessionID: sessionID,
            ordinal: 1,
            question: question,
            answer: "",
            status: .pending,
            errorMessage: nil,
            createdAt: date,
            updatedAt: date,
            completedAt: nil
        )
        return AskAnythingConversation(
            session: AskAnythingSession(
                id: sessionID,
                title: question,
                usesCustomTitle: false,
                sourceText: sourceText,
                createdAt: date,
                updatedAt: date,
                status: .answering
            ),
            turns: [turn]
        )
    }
}
