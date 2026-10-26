import Foundation
import NaturalLanguage

enum TechnicalTokenBoundaryResolver {
    static func tokenRange(
        containing changedRange: Range<String.Index>,
        in text: String
    ) -> Range<String.Index>? {
        guard !text.isEmpty,
              changedRange.lowerBound >= text.startIndex,
              changedRange.upperBound <= text.endIndex
        else { return nil }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var naturalRanges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            naturalRanges.append(range)
            return true
        }

        var lower = changedRange.lowerBound
        var upper = changedRange.upperBound
        while lower > text.startIndex {
            let previous = text.index(before: lower)
            guard isTechnicalBody(text[previous]) else { break }
            lower = previous
        }
        while upper < text.endIndex {
            guard isTechnicalBody(text[upper]) else { break }
            upper = text.index(after: upper)
        }

        // Permit a single internal ASCII space only when it joins two natural
        // word tokens (Open AI). Other whitespace remains a hard boundary.
        if lower > text.startIndex {
            let previous = text.index(before: lower)
            if text[previous] == " ",
               previous > text.startIndex,
               isTechnicalBody(text[text.index(before: previous)]) {
                let candidate = text.index(before: previous)..<upper
                if naturalRanges.filter({ $0.overlaps(candidate) }).count >= 2 {
                    lower = candidate.lowerBound
                }
            }
        }
        if upper < text.endIndex, text[upper] == " " {
            let afterSpace = text.index(after: upper)
            if afterSpace < text.endIndex, isTechnicalBody(text[afterSpace]) {
                var candidateUpper = afterSpace
                while candidateUpper < text.endIndex, isTechnicalBody(text[candidateUpper]) {
                    candidateUpper = text.index(after: candidateUpper)
                }
                let candidate = lower..<candidateUpper
                if naturalRanges.filter({ $0.overlaps(candidate) }).count >= 2 {
                    upper = candidateUpper
                }
            }
        }

        let resolved = lower..<upper
        guard naturalRanges.contains(where: { $0.overlaps(resolved) }) else { return nil }
        return resolved
    }

    static func isSingleStableToken(_ text: String) -> Bool {
        guard !text.isEmpty,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains("\n"),
              !text.contains("\r")
        else { return false }

        let characters = Array(text)
        if characters.allSatisfy(isASCIITechnicalBody),
           characters.contains(where: isASCIILatinCharacter) {
            return true
        }

        let spaceSeparated = text.split(separator: " ", omittingEmptySubsequences: false)
        if spaceSeparated.count == 2,
           spaceSeparated.allSatisfy({ part in
               !part.isEmpty
                   && part.allSatisfy(isASCIITechnicalBody)
                   && part.contains(where: isASCIILatinCharacter)
           }) {
            return true
        }

        guard characters.allSatisfy(isHan) else { return false }
        let fullRange = text.startIndex..<text.endIndex
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.simplifiedChinese)
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: fullRange) { range, _ in
            ranges.append(range)
            return true
        }
        return ranges == [fullRange]
    }

    private static func isTechnicalBody(_ character: Character) -> Bool {
        isASCIITechnicalBody(character)
    }

    private static func isASCIITechnicalBody(_ character: Character) -> Bool {
        isASCIILatinCharacter(character)
            || character.unicodeScalars.allSatisfy {
                $0.value < 128 && CharacterSet.decimalDigits.contains($0)
            }
            || "._+#-".contains(character)
    }

    private static func isASCIILatinCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            $0.value < 128 && CharacterSet.letters.contains($0)
        }
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }
}
