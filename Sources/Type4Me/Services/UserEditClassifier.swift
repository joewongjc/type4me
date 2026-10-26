import Foundation

enum UserEditClassifier {
    static func classify(original: String, edited: String) -> UserEditClassification {
        guard original != edited else { return .unchanged }
        guard !isSensitive(original), !isSensitive(edited) else { return .sensitive }

        if factualTokens(in: original) != factualTokens(in: edited)
            || negationPolarity(in: original) != negationPolarity(in: edited) {
            return .contentEdit
        }

        if expressionSkeleton(original) == expressionSkeleton(edited) {
            return .expressionEdit
        }

        let fullRange = NSRange(original.startIndex..<original.endIndex, in: original)
        switch CorrectionDiffAnalyzer.analyze(
            baseline: original,
            injectedRange: fullRange,
            current: edited
        ) {
        case .candidate:
            return .lexicalCorrection
        case .rejected(.multipleChanges):
            return hasExpressionChange(original: original, edited: edited)
                ? .mixedEdit
                : .ambiguous
        case .rejected(.sensitiveContent):
            return .sensitive
        case .rejected(.unchanged):
            return .unchanged
        default:
            let distance = edited.difference(from: original).count
            let scale = max(original.count, edited.count, 1)
            return Double(distance) / Double(scale) > 0.6 ? .contentEdit : .ambiguous
        }
    }

    static func isSensitive(_ text: String) -> Bool {
        let patterns = [
            #"\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#,
            #"(?:https?://|www\.)\S+"#,
            #"(?:\d[\s-]?){7,}"#,
            #"(?:^|\s)(?:/[^\s]+|[A-Za-z]:\\[^\s]+)"#,
            #"\b(?=[A-Za-z0-9_-]{20,}\b)(?=[A-Za-z0-9_-]*[A-Za-z])(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]+\b"#,
        ]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return patterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?
                .firstMatch(in: text, range: range) != nil
        }
    }

    private static func expressionSkeleton(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func hasExpressionChange(original: String, edited: String) -> Bool {
        let expression = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return original.unicodeScalars.filter(expression.contains)
            != edited.unicodeScalars.filter(expression.contains)
    }

    private static func factualTokens(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}_])[-+]?\d+(?:[.,:/-]\d+)*(?:%|元|美元|日|月|年)?"#
        ) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func negationPolarity(in text: String) -> Bool {
        let markers = ["不", "没", "无", "别", "非", "不是", "不能", "never", "not", "no"]
        let folded = text.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return markers.contains { folded.contains($0) }
    }
}
