import Foundation
import XCTest
@testable import Type4Me

final class AskAnythingContextBuilderTests: XCTestCase {
    func testBuildIncludesCompletedTurnsInOrderWithoutRepeatingSource() {
        let conversation = makeConversation(statuses: [.completed, .completed])

        let result = AskAnythingContextBuilder.build(
            conversation: conversation,
            currentQuestion: "Current",
            promptTemplateCharacters: 20,
            totalCharacterBudget: 10_000
        )

        XCTAssertEqual(result.selectedText, "Selected source")
        XCTAssertTrue(result.conversationText.contains("用户：Question 1\n助手：Answer 1"))
        XCTAssertTrue(result.conversationText.contains("用户：Question 2\n助手：Answer 2"))
        XCTAssertLessThan(
            try XCTUnwrap(result.conversationText.range(of: "Question 1")?.lowerBound),
            try XCTUnwrap(result.conversationText.range(of: "Question 2")?.lowerBound)
        )
        XCTAssertFalse(result.conversationText.contains("Selected source"))
        XCTAssertFalse(result.wasTruncated)
    }

    func testInterruptedAndFailedAnswersAreNotIncluded() {
        let conversation = makeConversation(statuses: [.interrupted, .failed])
        let result = AskAnythingContextBuilder.build(
            conversation: conversation,
            currentQuestion: "Current",
            promptTemplateCharacters: 0,
            totalCharacterBudget: 10_000
        )

        XCTAssertTrue(result.conversationText.contains("用户：Question 1"))
        XCTAssertTrue(result.conversationText.contains("用户：Question 2"))
        XCTAssertFalse(result.conversationText.contains("Answer 1"))
        XCTAssertFalse(result.conversationText.contains("Answer 2"))
    }

    func testPendingAndStreamingTurnsAreExcluded() {
        let conversation = makeConversation(statuses: [.completed, .pending, .streaming])
        let pendingID = conversation.turns[1].id
        let result = AskAnythingContextBuilder.build(
            conversation: conversation,
            excluding: pendingID,
            currentQuestion: "Current",
            promptTemplateCharacters: 0,
            totalCharacterBudget: 10_000
        )

        XCTAssertEqual(result.includedTurnIDs, [conversation.turns[0].id])
    }

    func testBudgetCoversTemplateQuestionSourceAndRecentWholeTurns() {
        var conversation = makeConversation(statuses: [.completed, .completed, .completed])
        conversation.session.sourceText = String(repeating: "S", count: 20)
        let result = AskAnythingContextBuilder.build(
            conversation: conversation,
            currentQuestion: String(repeating: "Q", count: 10),
            promptTemplateCharacters: 10,
            totalCharacterBudget: 75
        )

        XCTAssertLessThanOrEqual(
            10 + 10 + result.selectedText.count + result.conversationText.count,
            75
        )
        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(result.includedTurnIDs.last, conversation.turns.last?.id)
    }

    func testOversizedSourceIsMiddleTruncatedBeforeHistory() {
        var conversation = makeConversation(statuses: [.completed])
        conversation.session.sourceText = "ABCDEFGHIJ"
        let result = AskAnythingContextBuilder.build(
            conversation: conversation,
            currentQuestion: "Q",
            promptTemplateCharacters: 1,
            totalCharacterBudget: 9
        )

        XCTAssertEqual(result.selectedText.count, 7)
        XCTAssertTrue(result.selectedText.hasPrefix("AB"))
        XCTAssertTrue(result.selectedText.hasSuffix("IJ"))
        XCTAssertTrue(result.conversationText.isEmpty)
        XCTAssertTrue(result.wasTruncated)
    }

    func testFitRequestBudgetsFirstQuestionSelectedTextAndConversationTogether() {
        let result = AskAnythingContextBuilder.fitRequest(
            selectedText: String(repeating: "S", count: 40),
            conversationText: "用户：Old\n助手：Answer",
            currentQuestion: String(repeating: "Q", count: 10),
            promptTemplateCharacters: 10,
            totalCharacterBudget: 50
        )

        XCTAssertLessThanOrEqual(
            10 + 10 + result.selectedText.count + result.conversationText.count,
            50
        )
        XCTAssertTrue(result.conversationText.isEmpty)
        XCTAssertTrue(result.wasTruncated)
    }

    private func makeConversation(
        statuses: [AskAnythingTurn.Status]
    ) -> AskAnythingConversation {
        let sessionID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        let turns = statuses.enumerated().map { index, status in
            AskAnythingTurn(
                id: UUID(),
                sessionID: sessionID,
                ordinal: index + 1,
                question: "Question \(index + 1)",
                answer: "Answer \(index + 1)",
                status: status,
                errorMessage: status == .failed ? "Failure" : nil,
                createdAt: date,
                updatedAt: date,
                completedAt: status == .completed ? date : nil
            )
        }
        return AskAnythingConversation(
            session: AskAnythingSession(
                id: sessionID,
                title: "Title",
                usesCustomTitle: false,
                sourceText: "Selected source",
                createdAt: date,
                updatedAt: date,
                status: .active
            ),
            turns: turns
        )
    }
}
