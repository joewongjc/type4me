import Foundation

struct AskAnythingPreparedContext: Equatable, Sendable {
    let selectedText: String
    let conversationText: String
    let wasTruncated: Bool
    let includedTurnIDs: [UUID]
}

enum AskAnythingContextBuilder {
    static let fallbackTotalCharacterBudget = 24_000
    private static let truncationMarker = "\n…\n"

    static func build(
        conversation: AskAnythingConversation,
        excluding pendingTurnID: UUID? = nil,
        currentQuestion: String,
        promptTemplateCharacters: Int,
        totalCharacterBudget: Int = fallbackTotalCharacterBudget
    ) -> AskAnythingPreparedContext {
        let fixedCharacters = max(0, promptTemplateCharacters) + currentQuestion.count
        var remaining = max(0, totalCharacterBudget - fixedCharacters)
        var wasTruncated = false

        let sourceText: String
        if conversation.session.sourceText.count <= remaining {
            sourceText = conversation.session.sourceText
            remaining -= sourceText.count
        } else {
            sourceText = truncateMiddle(conversation.session.sourceText, limit: remaining)
            remaining = 0
            wasTruncated = !conversation.session.sourceText.isEmpty
        }

        let eligible = conversation.turns.filter { turn in
            guard turn.id != pendingTurnID else { return false }
            switch turn.status {
            case .completed:
                return true
            case .failed, .interrupted:
                return true
            case .pending, .streaming:
                return false
            }
        }

        var selectedBlocks: [(UUID, String)] = []
        for turn in eligible.reversed() {
            let block = contextBlock(for: turn)
            let separatorCost = selectedBlocks.isEmpty ? 0 : 2
            guard block.count + separatorCost <= remaining else {
                wasTruncated = true
                break
            }
            selectedBlocks.append((turn.id, block))
            remaining -= block.count + separatorCost
        }
        selectedBlocks.reverse()

        return AskAnythingPreparedContext(
            selectedText: sourceText,
            conversationText: selectedBlocks.map(\.1).joined(separator: "\n\n"),
            wasTruncated: wasTruncated || selectedBlocks.count < eligible.count,
            includedTurnIDs: selectedBlocks.map(\.0)
        )
    }

    static func fitRequest(
        selectedText: String,
        conversationText: String,
        currentQuestion: String,
        promptTemplateCharacters: Int,
        totalCharacterBudget: Int = fallbackTotalCharacterBudget
    ) -> AskAnythingPreparedContext {
        let fixedCharacters = max(0, promptTemplateCharacters) + currentQuestion.count
        var remaining = max(0, totalCharacterBudget - fixedCharacters)
        var wasTruncated = false

        let fittedSelectedText: String
        if selectedText.count <= remaining {
            fittedSelectedText = selectedText
            remaining -= selectedText.count
        } else {
            fittedSelectedText = truncateMiddle(selectedText, limit: remaining)
            remaining = 0
            wasTruncated = !selectedText.isEmpty
        }

        let blocks = conversationText
            .components(separatedBy: "\n\n")
            .filter { !$0.isEmpty }
        var fittedBlocks: [String] = []
        for block in blocks.reversed() {
            let separatorCost = fittedBlocks.isEmpty ? 0 : 2
            guard block.count + separatorCost <= remaining else {
                wasTruncated = true
                break
            }
            fittedBlocks.append(block)
            remaining -= block.count + separatorCost
        }
        fittedBlocks.reverse()

        return AskAnythingPreparedContext(
            selectedText: fittedSelectedText,
            conversationText: fittedBlocks.joined(separator: "\n\n"),
            wasTruncated: wasTruncated || fittedBlocks.count < blocks.count,
            includedTurnIDs: []
        )
    }

    private static func contextBlock(for turn: AskAnythingTurn) -> String {
        let question = turn.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if turn.status == .completed {
            let answer = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return "用户：\(question)\n助手：\(answer)"
        }
        // Failed and interrupted assistant output remains visible in history but is
        // intentionally excluded from future model context.
        return "用户：\(question)"
    }

    private static func truncateMiddle(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        guard limit > truncationMarker.count else {
            return String(text.prefix(limit))
        }
        let payload = limit - truncationMarker.count
        let prefixCount = (payload + 1) / 2
        let suffixCount = payload / 2
        return String(text.prefix(prefixCount))
            + truncationMarker
            + String(text.suffix(suffixCount))
    }
}
