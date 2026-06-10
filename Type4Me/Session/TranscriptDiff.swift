import Foundation

enum TranscriptDiffType: String, Equatable, Sendable {
    case exactMatch
    case punctuationOnly
    case whitespaceOnly
    case trailingPunctuationOnly
    case suffixAdded
    case prefixAdded
    case semanticChange
}

struct TranscriptDiff: Sendable, Equatable {
    let type: TranscriptDiffType
    let sourceLength: Int
    let finalLength: Int
    let commonPrefixLength: Int
    let commonSuffixLength: Int
    let addedSuffixUnicode: [String]
    let changedInMiddle: Bool

    var canReuseLLMResult: Bool {
        switch type {
        case .exactMatch, .punctuationOnly, .whitespaceOnly, .trailingPunctuationOnly:
            return true
        case .suffixAdded, .prefixAdded, .semanticChange:
            return false
        }
    }

    static func classify(source: String, final: String) -> TranscriptDiff {
        let prefixLength = commonPrefix(source, final)
        let suffixLength = commonSuffix(source, final, excludingPrefix: prefixLength)
        let sourceCharacters = Array(source)
        let finalCharacters = Array(final)
        let addedSuffix = final.hasPrefix(source)
            ? finalCharacters.dropFirst(sourceCharacters.count).map(unicodeLabel)
            : []
        let changedInMiddle = prefixLength + suffixLength < min(sourceCharacters.count, finalCharacters.count)

        let type: TranscriptDiffType
        if source == final {
            type = .exactMatch
        } else if removingWhitespace(source) == removingWhitespace(final) {
            type = .whitespaceOnly
        } else if normalizingPunctuationAndWhitespace(source) == normalizingPunctuationAndWhitespace(final) {
            type = .punctuationOnly
        } else if removingTrailingPunctuation(source) == removingTrailingPunctuation(final) {
            type = .trailingPunctuationOnly
        } else if final.hasPrefix(source) {
            type = .suffixAdded
        } else if final.hasSuffix(source) {
            type = .prefixAdded
        } else {
            type = .semanticChange
        }

        return TranscriptDiff(
            type: type,
            sourceLength: sourceCharacters.count,
            finalLength: finalCharacters.count,
            commonPrefixLength: prefixLength,
            commonSuffixLength: suffixLength,
            addedSuffixUnicode: addedSuffix,
            changedInMiddle: changedInMiddle
        )
    }

    private static let punctuationMap: [Character: Character] = [
        "，": ",", "。": ".", "！": "!", "？": "?", "；": ";", "：": ":",
        "（": "(", "）": ")", "【": "[", "】": "]", "“": "\"", "”": "\"",
        "‘": "'", "’": "'",
    ]

    private static let trailingPunctuation = CharacterSet(
        charactersIn: "，。！？；：、,.!?;:…— \t\r\n"
    )

    private static func removingWhitespace(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    private static func normalizingPunctuationAndWhitespace(_ text: String) -> String {
        String(text.compactMap { character -> Character? in
            if character.unicodeScalars.allSatisfy({
                CharacterSet.whitespacesAndNewlines.contains($0)
            }) {
                return nil
            }
            return punctuationMap[character] ?? character
        })
    }

    private static func removingTrailingPunctuation(_ text: String) -> String {
        let normalized = normalizingPunctuationAndWhitespace(text)
        return normalized.trimmingCharacters(in: trailingPunctuation)
    }

    private static func commonPrefix(_ lhs: String, _ rhs: String) -> Int {
        zip(lhs, rhs).prefix { pair in pair.0 == pair.1 }.count
    }

    private static func commonSuffix(_ lhs: String, _ rhs: String, excludingPrefix prefix: Int) -> Int {
        let maximum = min(lhs.count, rhs.count) - prefix
        guard maximum > 0 else { return 0 }
        return zip(lhs.reversed(), rhs.reversed())
            .prefix(maximum)
            .prefix { pair in pair.0 == pair.1 }
            .count
    }

    private static func unicodeLabel(_ character: Character) -> String {
        character.unicodeScalars
            .map { String(format: "U+%04X", $0.value) }
            .joined(separator: "+")
    }
}

enum EarlyLLMDecision: Equatable, Sendable {
    case noRequest
    case reuse
    case runFresh

    static func decide(earlyInput: String?, finalInput: String, needsLLM: Bool) -> EarlyLLMDecision {
        guard needsLLM, !finalInput.isEmpty else { return .noRequest }
        guard let earlyInput, !earlyInput.isEmpty else { return .runFresh }
        return TranscriptDiff.classify(source: earlyInput, final: finalInput).canReuseLLMResult
            ? .reuse
            : .runFresh
    }
}

struct EarlyLLMTaskSelection {
    let task: Task<String?, Never>?
    let reused: Bool
}

enum EarlyLLMTaskSelector {
    static func select(
        earlyInput: String?,
        finalInput: String,
        needsLLM: Bool,
        earlyTask: Task<String?, Never>?,
        makeFreshTask: () -> Task<String?, Never>?
    ) -> EarlyLLMTaskSelection {
        switch EarlyLLMDecision.decide(
            earlyInput: earlyInput,
            finalInput: finalInput,
            needsLLM: needsLLM
        ) {
        case .reuse:
            if let earlyTask {
                return EarlyLLMTaskSelection(task: earlyTask, reused: true)
            }
            return EarlyLLMTaskSelection(task: makeFreshTask(), reused: false)
        case .runFresh:
            earlyTask?.cancel()
            return EarlyLLMTaskSelection(task: makeFreshTask(), reused: false)
        case .noRequest:
            earlyTask?.cancel()
            return EarlyLLMTaskSelection(task: nil, reused: false)
        }
    }
}

enum SessionGenerationGuard {
    static func isCurrent(expected: Int, active: Int) -> Bool {
        expected == active
    }
}
