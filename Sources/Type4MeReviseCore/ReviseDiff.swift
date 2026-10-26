import Foundation

public struct ReviseDiffHunk: Equatable, Sendable {
    public let sourceCharacterRange: Range<Int>
    public let resultCharacterRange: Range<Int>
    public let removedText: String
    public let insertedText: String

    public init(
        sourceCharacterRange: Range<Int>,
        resultCharacterRange: Range<Int>,
        removedText: String,
        insertedText: String
    ) {
        self.sourceCharacterRange = sourceCharacterRange
        self.resultCharacterRange = resultCharacterRange
        self.removedText = removedText
        self.insertedText = insertedText
    }
}

public struct ReviseDiffSummary: Equatable, Sendable {
    public let hunks: [ReviseDiffHunk]
    public let removedCharacterCount: Int
    public let insertedCharacterCount: Int
    public let changeRatio: Double

    public init(
        hunks: [ReviseDiffHunk],
        removedCharacterCount: Int,
        insertedCharacterCount: Int,
        changeRatio: Double
    ) {
        self.hunks = hunks
        self.removedCharacterCount = removedCharacterCount
        self.insertedCharacterCount = insertedCharacterCount
        self.changeRatio = changeRatio
    }
}

public enum ReviseDiffCalculator {
    public static func computeDiff(
        target: String,
        result: String,
        budget: Duration = ReviseInputBudget.diffCalculationBudget
    ) -> Result<ReviseDiffSummary, ReviseRejection> {
        let oldChars = Array(target)
        let newChars = Array(result)

        guard oldChars.count + newChars.count <= ReviseInputBudget.maxCombinedDiffCharacters else {
            return .failure(.diffBudgetExceeded)
        }

        let clock = ContinuousClock()
        let start = clock.now

        let difference = newChars.difference(from: oldChars)
        guard clock.now - start <= budget else {
            return .failure(.diffBudgetExceeded)
        }

        var removals: [Int: Character] = [:]
        var insertions: [Int: Character] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, let element, _):
                removals[offset] = element
            case .insert(let offset, let element, _):
                insertions[offset] = element
            }
        }

        var hunks: [ReviseDiffHunk] = []
        var oldIdx = 0
        var newIdx = 0

        var currentOldStart = 0
        var currentNewStart = 0
        var currentRemoved = ""
        var currentInserted = ""
        var inHunk = false

        func flushHunk() {
            if inHunk {
                hunks.append(ReviseDiffHunk(
                    sourceCharacterRange: currentOldStart..<oldIdx,
                    resultCharacterRange: currentNewStart..<newIdx,
                    removedText: currentRemoved,
                    insertedText: currentInserted
                ))
                currentRemoved = ""
                currentInserted = ""
                inHunk = false
            }
        }

        while oldIdx < oldChars.count || newIdx < newChars.count {
            if clock.now - start > budget {
                return .failure(.diffBudgetExceeded)
            }

            var edited = false
            if let ins = insertions[newIdx] {
                if !inHunk {
                    inHunk = true
                    currentOldStart = oldIdx
                    currentNewStart = newIdx
                }
                currentInserted.append(ins)
                newIdx += 1
                edited = true
            }
            if let rem = removals[oldIdx] {
                if !inHunk {
                    inHunk = true
                    currentOldStart = oldIdx
                    currentNewStart = newIdx
                }
                currentRemoved.append(rem)
                oldIdx += 1
                edited = true
            }
            if edited { continue }

            flushHunk()
            oldIdx += 1
            newIdx += 1
        }
        flushHunk()

        let removedCount = hunks.reduce(0) { $0 + $1.removedText.count }
        let insertedCount = hunks.reduce(0) { $0 + $1.insertedText.count }
        let baseCount = max(1, target.count)
        let changeRatio = Double(removedCount + insertedCount) / Double(baseCount)

        return .success(ReviseDiffSummary(
            hunks: hunks,
            removedCharacterCount: removedCount,
            insertedCharacterCount: insertedCount,
            changeRatio: changeRatio
        ))
    }
}
