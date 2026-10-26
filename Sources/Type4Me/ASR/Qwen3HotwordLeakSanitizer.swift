import Foundation

enum ASRHotwordLeakSanitizer {
    private struct PrefixMatch {
        let consumedText: String
        let remainder: String
        let wordCount: Int
        let hadContextLabel: Bool
    }

    private static let separatorScalars = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",，、;；:：|/\\-—_·.。.!！?？\"'“”‘’()（）[]【】<>《》"))

    private static let contextLabels = [
        "Vocabulary:", "Vocabulary：", "Vocabulary",
        "Hotwords:", "Hotwords：", "Hotwords",
        "词汇：", "词汇:", "词汇表：", "词汇表:", "热词：", "热词:", "关键词：", "关键词:",
    ]

    static func sanitize(_ text: String, hotwords: [String], fallbackText: String = "") -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return "" }

        let cleanedHotwords = hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedHotwords.isEmpty else { return trimmedText }

        let fallback = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let (searchText, hadContextLabel) = droppingLeadingContextLabel(from: trimmedText)
        guard let match = bestPrefixMatch(in: searchText, hotwords: cleanedHotwords, hadContextLabel: hadContextLabel),
              shouldTreatAsLeak(match: match, fallbackText: fallback)
        else {
            return trimmedText
        }

        // With very short or silent audio, Qwen3 can return the entire hotword
        // context as the transcription. There is no remainder in this case,
        // so the normal "hotwords followed by real text" path cannot identify
        // it. A context label is unambiguously a prompt echo; an unlabeled run
        // of multiple hotwords is also a strong signal, while a single exact
        // hotword is still allowed to be a legitimate utterance.
        if match.remainder.isEmpty {
            guard match.hadContextLabel || match.wordCount >= 2 else {
                return trimmedText
            }
            return fallback
        }

        guard !fallback.isEmpty else { return match.remainder }

        let normalizedRemainder = normalized(match.remainder)
        let normalizedFallback = normalized(fallback)
        if normalizedRemainder == normalizedFallback
            || normalizedRemainder.hasSuffix(normalizedFallback)
            || normalizedFallback.hasSuffix(normalizedRemainder)
        {
            return match.remainder
        }

        return fallback
    }

    private static func bestPrefixMatch(
        in text: String,
        hotwords: [String],
        hadContextLabel: Bool
    ) -> PrefixMatch? {
        var best: PrefixMatch?

        for startIndex in hotwords.indices {
            guard let candidate = prefixMatch(
                in: text,
                hotwords: hotwords,
                startingAt: startIndex,
                hadContextLabel: hadContextLabel
            ) else {
                continue
            }

            if let current = best {
                if candidate.wordCount > current.wordCount
                    || (candidate.wordCount == current.wordCount
                        && candidate.consumedText.count > current.consumedText.count)
                {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        return best
    }

    private static func prefixMatch(
        in text: String,
        hotwords: [String],
        startingAt startIndex: Array<String>.Index,
        hadContextLabel: Bool
    ) -> PrefixMatch? {
        var index = text.startIndex
        var consumedStart: String.Index?
        var wordCount = 0

        for hotwordIndex in startIndex..<hotwords.endIndex {
            index = skipSeparators(in: text, from: index)
            if consumedStart == nil {
                consumedStart = index
            }

            let hotword = hotwords[hotwordIndex]
            guard let range = text.range(
                of: hotword,
                options: [.caseInsensitive, .anchored],
                range: index..<text.endIndex
            ) else {
                break
            }

            index = range.upperBound
            wordCount += 1
        }

        guard wordCount > 0, let consumedStart else { return nil }
        let consumedText = String(text[consumedStart..<index])
        let remainder = trimLeadingSeparators(String(text[index...]))

        return PrefixMatch(
            consumedText: consumedText,
            remainder: remainder,
            wordCount: wordCount,
            hadContextLabel: hadContextLabel
        )
    }

    private static func shouldTreatAsLeak(match: PrefixMatch, fallbackText: String) -> Bool {
        if match.remainder.isEmpty {
            return match.hadContextLabel || match.wordCount >= 2
        }

        if match.hadContextLabel || match.wordCount >= 2 {
            return true
        }

        let normalizedFallback = normalized(fallbackText)
        guard !normalizedFallback.isEmpty else { return false }

        let normalizedConsumed = normalized(match.consumedText)
        if normalizedFallback.hasPrefix(normalizedConsumed) {
            return false
        }

        let normalizedRemainder = normalized(match.remainder)
        guard !normalizedRemainder.isEmpty else { return false }

        let tailLooksLikePreview = normalizedRemainder == normalizedFallback
            || normalizedRemainder.hasSuffix(normalizedFallback)
            || normalizedFallback.hasSuffix(normalizedRemainder)

        return tailLooksLikePreview && containsCJK(match.consumedText)
    }

    private static func droppingLeadingContextLabel(from text: String) -> (String, Bool) {
        let trimmed = trimLeadingSeparators(text)
        for label in contextLabels {
            guard let range = trimmed.range(
                of: label,
                options: [.caseInsensitive, .anchored],
                range: trimmed.startIndex..<trimmed.endIndex
            ) else {
                continue
            }
            return (trimLeadingSeparators(String(trimmed[range.upperBound...])), true)
        }
        return (trimmed, false)
    }

    private static func skipSeparators(in text: String, from start: String.Index) -> String.Index {
        var index = start
        while index < text.endIndex, isSeparator(text[index]) {
            index = text.index(after: index)
        }
        return index
    }

    private static func trimLeadingSeparators(_ text: String) -> String {
        let start = skipSeparators(in: text, from: text.startIndex)
        return String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { separatorScalars.contains($0) }
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    private static func normalized(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.filter { !separatorScalars.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
