import Foundation

public struct CorrectionIntentAnalysis: Equatable, Codable, Sendable {
    public let containsExplicitCorrection: Bool
    public let requiredProtectedTokens: Set<String>
    public let supersededProtectedTokens: Set<String>
    public let semanticNegationCounts: [String: Int]

    public init(
        containsExplicitCorrection: Bool,
        requiredProtectedTokens: Set<String>,
        supersededProtectedTokens: Set<String>,
        semanticNegationCounts: [String: Int]
    ) {
        self.containsExplicitCorrection = containsExplicitCorrection
        self.requiredProtectedTokens = requiredProtectedTokens
        self.supersededProtectedTokens = supersededProtectedTokens
        self.semanticNegationCounts = semanticNegationCounts
    }

    public static func analyze(_ text: String) -> Self {
        let ranges = explicitCorrectionRanges(in: text)
        let tokens = ProtectedFactExtractor.tokensWithRanges(in: text)
        var superseded = Set<String>()
        var required = Set(tokens.map(\.token))

        for range in ranges {
            let before = tokens.filter { $0.range.upperBound <= range.lowerBound }
            let after = tokens.filter { $0.range.lowerBound >= range.upperBound }
            guard let replacement = after.first else { continue }
            required.insert(replacement.token)
            if let old = before.last, old.token.caseInsensitiveCompare(replacement.token) != .orderedSame {
                superseded.insert(old.token)
                required.remove(old.token)
            }
        }

        return Self(
            containsExplicitCorrection: !ranges.isEmpty,
            requiredProtectedTokens: required,
            supersededProtectedTokens: superseded,
            semanticNegationCounts: semanticNegations(in: text)
        )
    }

    private static func explicitCorrectionRanges(in text: String) -> [Range<String.Index>] {
        let patterns = [
            #"(?i)(?<!不)(?<!别)(?:不对|哦不|改口|算了|重说|i\s+mean|sorry)(?:\s*[，,。.]?\s*(?:改成|换成|应该是|是))?"#,
            #"(?i)(?<!不)(?<!别)(?:改成|换成|应该是)(?!不要)"#,
        ]
        return patterns.flatMap { pattern -> [Range<String.Index>] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.matches(in: text, range: full).compactMap { match in
                guard let range = Range(match.range, in: text) else { return nil }
                let prefix = String(text[..<range.lowerBound]).suffix(4)
                if prefix.hasSuffix("不要") || prefix.hasSuffix("不能") || prefix.hasSuffix("别") {
                    return nil
                }
                return range
            }
        }.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func semanticNegations(in text: String) -> [String: Int] {
        var semantic = text
        let metaPatterns = [
            #"(?i)不对|哦不|i\s+mean|sorry"#,
            #"(?i)能不能|可不可以|是不是|要不要|有没有|是否"#,
            #"不过|不仅|不但|不论|不管"#,
        ]
        for pattern in metaPatterns {
            semantic = semantic.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let groups: [(String, String)] = [
            ("prohibition", #"(?i)不要|别|请勿|不得|do\s+not|don't|must\s+not"#),
            ("inability", #"(?i)不能|无法|不可|can't|cannot"#),
            ("absence", #"(?i)尚未|没有|未|没|not\s+yet|didn't|hasn't|haven't"#),
            ("contradiction", #"(?i)并非|不是|\bnot\b|\bno\b"#),
            ("never", #"(?i)从不|绝不|never"#),
            ("general", #"不"#),
        ]
        var counts: [String: Int] = [:]
        var consumed = semantic
        for (key, pattern) in groups {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let full = NSRange(consumed.startIndex..<consumed.endIndex, in: consumed)
            let matches = regex.matches(in: consumed, range: full)
            if !matches.isEmpty { counts[key] = matches.count }
            consumed = regex.stringByReplacingMatches(in: consumed, range: full, withTemplate: " ")
        }
        return counts
    }
}

enum ProtectedFactExtractor {
    struct Match {
        let token: String
        let range: Range<String.Index>
    }

    private static let hardPatterns = [
        #"https?://[^\s<>]+"#,
        #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        #"(?:/[^\s/]+){2,}"#,
        #"(?<![A-Za-z0-9])\d+(?:[.,:/-]\d+)*(?![A-Za-z0-9])"#,
        #"(?:周|星期|礼拜)[一二三四五六日天]"#,
    ]

    private static let softPatterns = [
        #"(?:^|\s)(?:--?[A-Za-z][A-Za-z0-9_-]*)(?=\s|=|$)"#,
        #"\b[A-Za-z_$][A-Za-z0-9_$]*(?:[-_.$][A-Za-z0-9_$-]+|[A-Z][A-Za-z0-9_$]*)+\b"#,
    ]

    private static let patterns = hardPatterns + softPatterns

    static func tokens(in text: String) -> Set<String> {
        Set(tokensWithRanges(in: text).map(\.token))
    }

    static func isHardProtectedToken(_ token: String) -> Bool {
        hardPatterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let fullRange = NSRange(token.startIndex..<token.endIndex, in: token)
            guard let match = regex.firstMatch(in: token, range: fullRange) else { return false }
            return match.range == fullRange
        }
    }

    static func tokensWithRanges(in text: String) -> [Match] {
        var result: [Match] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.anchorsMatchLines]
            ) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let token = text[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(Match(token: token, range: swiftRange))
            }
        }
        return result
    }
}
