import Foundation

enum CorrectionAffinityReason: String, Equatable, Sendable {
    case confirmedMapping
    case orthographic
    case chineseHomophone
    case transliteration
    case unrelated
}

struct CorrectionAffinityResult: Equatable, Sendable {
    let isHighConfidence: Bool
    let reason: CorrectionAffinityReason
}

enum CorrectionAffinityAnalyzer {
    static func evaluate(
        wrong: String,
        corrected: String,
        confirmedMappings: [CorrectionMapping] = []
    ) -> CorrectionAffinityResult {
        let wrong = wrong.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = corrected.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !corrected.isEmpty, wrong != corrected else {
            return .init(isHighConfidence: false, reason: .unrelated)
        }

        if confirmedMappings.contains(where: {
            $0.trigger.caseInsensitiveCompare(wrong) == .orderedSame
                && $0.replacement.caseInsensitiveCompare(corrected) == .orderedSame
        }) {
            return .init(isHighConfidence: true, reason: .confirmedMapping)
        }

        let wrongIsHan = isHanOnly(wrong)
        let correctedIsHan = isHanOnly(corrected)
        let wrongIsLatin = isLatinTechnicalToken(wrong)
        let correctedIsLatin = isLatinTechnicalToken(corrected)

        if wrongIsLatin, correctedIsLatin {
            let lhs = normalizedLatin(wrong)
            let rhs = normalizedLatin(corrected)
            guard !lhs.isEmpty, !rhs.isEmpty else {
                return .init(isHighConfidence: false, reason: .unrelated)
            }
            if lhs == rhs {
                return .init(isHighConfidence: true, reason: .orthographic)
            }
            let maximumLength = max(lhs.count, rhs.count)
            let distance = damerauLevenshtein(lhs, rhs)
            let allowedDistance: Int
            switch maximumLength {
            case ...4: allowedDistance = 1
            case 5...8: allowedDistance = 2
            default: allowedDistance = max(2, Int(floor(Double(maximumLength) * 0.25)))
            }
            let similarity = 1 - Double(distance) / Double(maximumLength)
            if distance <= allowedDistance, similarity >= 0.65 {
                return .init(isHighConfidence: true, reason: .orthographic)
            }
            return .init(isHighConfidence: false, reason: .unrelated)
        }

        if wrongIsHan, correctedIsHan {
            let lhs = mandarinLatin(wrong)
            let rhs = mandarinLatin(corrected)
            if !lhs.isEmpty, lhs == rhs {
                return .init(isHighConfidence: true, reason: .chineseHomophone)
            }
            return .init(isHighConfidence: false, reason: .unrelated)
        }

        if (wrongIsHan && correctedIsLatin) || (wrongIsLatin && correctedIsHan) {
            let han = wrongIsHan ? wrong : corrected
            let latin = wrongIsLatin ? wrong : corrected
            let transliterated = mandarinLatin(han)
            let normalizedTarget = normalizedLatin(latin)
            guard let firstSource = transliterated.first,
                  let firstTarget = normalizedTarget.first,
                  firstSource == firstTarget,
                  !transliterated.isEmpty,
                  !normalizedTarget.isEmpty
            else {
                return .init(isHighConfidence: false, reason: .unrelated)
            }
            let maximumLength = max(transliterated.count, normalizedTarget.count)
            let distance = damerauLevenshtein(transliterated, normalizedTarget)
            let similarity = 1 - Double(distance) / Double(maximumLength)
            let lengthRatio = Double(min(transliterated.count, normalizedTarget.count))
                / Double(maximumLength)
            if similarity >= 0.48, lengthRatio >= 0.6 {
                return .init(isHighConfidence: true, reason: .transliteration)
            }
        }

        return .init(isHighConfidence: false, reason: .unrelated)
    }

    private static func isLatinTechnicalToken(_ text: String) -> Bool {
        TechnicalTokenBoundaryResolver.isSingleStableToken(text)
            && text.contains { character in
                character.unicodeScalars.allSatisfy {
                    $0.value < 128 && CharacterSet.letters.contains($0)
                }
            }
    }

    private static func isHanOnly(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { character in
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

    private static func mandarinLatin(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return normalizedLatin(mutable as String)
    }

    private static func normalizedLatin(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter {
                $0.value < 128
                    && (CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0))
            }
            .map(String.init)
            .joined()
    }

    private static func damerauLevenshtein(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }
        var matrix = Array(
            repeating: Array(repeating: 0, count: right.count + 1),
            count: left.count + 1
        )
        for index in 0...left.count { matrix[index][0] = index }
        for index in 0...right.count { matrix[0][index] = index }

        for leftIndex in 1...left.count {
            for rightIndex in 1...right.count {
                let substitutionCost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                matrix[leftIndex][rightIndex] = min(
                    matrix[leftIndex - 1][rightIndex] + 1,
                    matrix[leftIndex][rightIndex - 1] + 1,
                    matrix[leftIndex - 1][rightIndex - 1] + substitutionCost
                )
                if leftIndex > 1,
                   rightIndex > 1,
                   left[leftIndex - 1] == right[rightIndex - 2],
                   left[leftIndex - 2] == right[rightIndex - 1] {
                    matrix[leftIndex][rightIndex] = min(
                        matrix[leftIndex][rightIndex],
                        matrix[leftIndex - 2][rightIndex - 2] + 1
                    )
                }
            }
        }
        return matrix[left.count][right.count]
    }
}
