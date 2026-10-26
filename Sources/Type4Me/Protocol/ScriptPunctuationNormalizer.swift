import Foundation

/// Normalizes punctuation style to match the transcript script / configured language.
enum ScriptPunctuationNormalizer {

    private static let cjkLanguageCodes: Set<String> = ["zh", "zh-tw", "ja", "ko"]

    private static let cjkToLatinMap: [Character: Character] = [
        "，": ",", "。": ".", "！": "!", "？": "?", "；": ";", "：": ":",
        "（": "(", "）": ")", "【": "[", "】": "]",
        "\u{201C}": "\"", "\u{201D}": "\"",
        "\u{2018}": "'", "\u{2019}": "'",
        "、": ",",
    ]

    private static let spacingAfterPunctuation = ",;:!?"

    /// Whether CJK punctuation in `text` should be converted to Latin punctuation.
    static func shouldUseLatinPunctuation(languageCode: String, text: String) -> Bool {
        let normalizedLanguage = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cjkLanguageCodes.contains(normalizedLanguage) {
            return false
        }
        if !normalizedLanguage.isEmpty {
            return true
        }
        return !text.contains(where: \.isCJKUnifiedIdeograph)
    }

    static func normalizeCJKPunctuationToLatin(_ text: String) -> String {
        insertLatinPunctuationSpacing(mapCJKPunctuationToLatin(text))
    }

    static func normalizeIfNeeded(languageCode: String, text: String) -> String {
        guard shouldUseLatinPunctuation(languageCode: languageCode, text: text) else {
            return text
        }
        return normalizeCJKPunctuationToLatin(text)
    }

    private static func mapCJKPunctuationToLatin(_ text: String) -> String {
        String(text.map { cjkToLatinMap[$0] ?? $0 })
    }

    /// Inserts spaces after Latin clause/sentence punctuation when the next character is a word.
    private static func insertLatinPunctuationSpacing(_ text: String) -> String {
        let characters = Array(text)
        guard !characters.isEmpty else { return text }

        var result = ""
        for index in characters.indices {
            let character = characters[index]
            result.append(character)

            guard index + 1 < characters.count else { continue }
            let next = characters[index + 1]
            guard shouldInsertSpace(after: character, before: next, previous: index > 0 ? characters[index - 1] : nil) else {
                continue
            }
            result.append(" ")
        }
        return result
    }

    private static func shouldInsertSpace(
        after punctuation: Character,
        before next: Character,
        previous: Character?
    ) -> Bool {
        guard !next.isWhitespace, next.isLatinWordCharacter else { return false }

        if spacingAfterPunctuation.contains(punctuation) {
            return true
        }

        if punctuation == "." {
            if let previous, previous.isNumber, next.isNumber {
                return false
            }
            return true
        }

        return false
    }
}

private extension Character {
    var isLatinWordCharacter: Bool {
        isLetter && unicodeScalars.allSatisfy { $0.value < 128 }
    }
}
