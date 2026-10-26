import Foundation

public struct ReviseFactMatch: Equatable, Sendable {
    public let token: String
    public let range: Range<String.Index>

    public init(token: String, range: Range<String.Index>) {
        self.token = token
        self.range = range
    }
}

public enum ReviseFactExtractor {
    // Regex definitions with capture priority
    private static let urlPattern = #"https?://[^\s<>]+"#
    private static let emailPattern = #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
    private static let pathPattern = #"(?:/[^\s/]+){2,}"#
    private static let datePatterns = [
        #"\b\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?\b"#,
        #"\b\d{1,2}月\d{1,2}[日号]\b"#,
        #"(?:周|星期|礼拜)[一二三四五六日天]"#,
    ]
    private static let timePatterns = [
        #"(?i)(?:上午|下午|早上|中午|晚上|凌晨|清晨|傍晚)?\s*(?:[0-9一二三四五六七八九十两\d]+)\s*点(?:半|整|(?:\s*[0-9一二三四五六七八九十两\d]+\s*分)?|(?:\s*:\s*\d{2}))"#,
        #"(?i)(?:上午|下午|早上|中午|晚上|凌晨|清晨|傍晚)\s*(?:[0-9一二三四五六七八九十两\d]+)\s*点"#,
        #"(?:[01]?\d|2[0-3])\s*:\s*[0-5]\d"#,
        #"(?i)(?:[0-9一二三四五六七八九十两\d]+)\s*点"#,
    ]
    private static let moneyPatterns = [
        #"(?:[￥$¥€£]|CNY|RMB|USD)\s*\d+(?:\.\d+)?"#,
        #"\b\d+(?:\.\d+)?\s*(?:元|块|万元|亿元|dollars?|yuan)\b"#,
    ]
    private static let percentagePatterns = [
        #"\b\d+(?:\.\d+)?%"#,
        #"百分之\s*[0-9一二三四五六七八九十百千万\d]+(?:\.[0-9\d]+)?"#,
    ]
    private static let codePattern = #"\b[A-Za-z_$][A-Za-z0-9_$]*(?:[-_.$][A-Za-z0-9_$-]+|[A-Z][A-Za-z0-9_$]*)+\b|--?[A-Za-z][A-Za-z0-9_-]*"#
    private static let numberPattern = #"(?<![A-Za-z0-9])\d+(?:\.\d+)?(?![A-Za-z0-9])"#

    public static func detectPrimaryFactKind(in text: String) -> ReviseFactKind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Test in priority order
        if matchesPattern(urlPattern, in: trimmed, exact: true) { return .url }
        if matchesPattern(emailPattern, in: trimmed, exact: true) { return .email }
        if matchesPattern(pathPattern, in: trimmed, exact: true) { return .path }
        for p in datePatterns where matchesPattern(p, in: trimmed, exact: true) { return .date }
        for p in timePatterns where matchesPattern(p, in: trimmed, exact: true) { return .time }
        for p in moneyPatterns where matchesPattern(p, in: trimmed, exact: true) { return .money }
        for p in percentagePatterns where matchesPattern(p, in: trimmed, exact: true) { return .percentage }
        if matchesPattern(codePattern, in: trimmed, exact: true) { return .codeIdentifier }
        if matchesPattern(numberPattern, in: trimmed, exact: true) { return .number }

        // If not exact match, check facts extracted
        let facts = extractFacts(in: trimmed)
        if facts.count == 1 {
            return facts[0].kind
        }
        return facts.first?.kind
    }

    private static func matchesPattern(_ pattern: String, in text: String, exact: Bool) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: full) else { return false }
        return exact ? match.range == full : true
    }

    public static func extractFacts(in text: String) -> [ReviseFact] {
        var facts: [ReviseFact] = []
        var claimedRanges: [Range<String.Index>] = []

        func addMatches(pattern: String, kind: ReviseFactKind) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            for m in regex.matches(in: text, range: full) {
                guard let r = Range(m.range, in: text) else { continue }
                // Avoid overlapping with already claimed higher priority facts
                let overlaps = claimedRanges.contains { claimed in
                    claimed.overlaps(r) || claimed == r
                }
                if !overlaps {
                    let token = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !token.isEmpty {
                        facts.append(ReviseFact(kind: kind, text: token, range: r))
                        claimedRanges.append(r)
                    }
                }
            }
        }

        // 1. URL
        addMatches(pattern: urlPattern, kind: .url)
        // 2. Email
        addMatches(pattern: emailPattern, kind: .email)
        // 3. Path
        addMatches(pattern: pathPattern, kind: .path)
        // 4. Date
        for p in datePatterns { addMatches(pattern: p, kind: .date) }
        // 5. Time
        for p in timePatterns { addMatches(pattern: p, kind: .time) }
        // 6. Money
        for p in moneyPatterns { addMatches(pattern: p, kind: .money) }
        // 7. Percentage
        for p in percentagePatterns { addMatches(pattern: p, kind: .percentage) }
        // 8. Code Identifier
        addMatches(pattern: codePattern, kind: .codeIdentifier)
        // 9. Number
        addMatches(pattern: numberPattern, kind: .number)

        // Sort by start index
        return facts.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    public static func tokens(in text: String) -> Set<String> {
        Set(extractFacts(in: text).map(\.text))
    }

    public static func isHardProtectedToken(_ token: String) -> Bool {
        guard let kind = detectPrimaryFactKind(in: token) else { return false }
        switch kind {
        case .url, .email, .path, .date, .time, .money, .percentage, .number:
            return true
        case .codeIdentifier:
            return false
        }
    }
}

public enum ReviseProtectedFactAnalyzer {
    public static func validateFacts(
        target: String,
        candidate: String,
        instruction: String,
        analysis: ReviseInstructionAnalysis,
        scopeResolution: ReviseScopeResolution,
        authorizedRanges: [Range<String.Index>]? = nil
    ) -> Result<Void, ReviseRejection> {
        let targetFacts = ReviseFactExtractor.extractFacts(in: target)
        let candidateFacts = ReviseFactExtractor.extractFacts(in: candidate)
        let instructionFacts = ReviseFactExtractor.extractFacts(in: instruction)

        // 1. Check for unauthorized REMOVAL of protected tokens
        let removedFacts = targetFacts.filter { targetFact in
            !candidateFacts.contains { factsAreEquivalent(targetFact, $0) }
        }
        for fact in removedFacts where ReviseFactExtractor.isHardProtectedToken(fact.text) {
            let token = fact.text
            let authorizedByOldLiterals = analysis.explicitOldLiterals.contains { old in
                normalizedFactText(old).contains(normalizedFactText(token))
                    || normalizedFactText(token).contains(normalizedFactText(old))
            }
            let authorizedByInstruction = normalizedFactText(instruction).contains(normalizedFactText(token))
            let authorizedByLocalRange = authorizedRanges?.contains(where: { range in
                let sub = target[range]
                return normalizedFactText(String(sub)).contains(normalizedFactText(token))
                    || normalizedFactText(token).contains(normalizedFactText(String(sub)))
            }) ?? false

            let authorizedByScope: Bool = {
                switch scopeResolution {
                case .exact(let ranges):
                    return ranges.contains { range in
                        let sub = target[range]
                        return normalizedFactText(String(sub)).contains(normalizedFactText(token))
                            || normalizedFactText(token).contains(normalizedFactText(String(sub)))
                    }
                case .whole:
                    return analysis.allowsEmptyResult || analysis.allowsWholeRewrite
                case .semantic, .ambiguous:
                    return false
                }
            }()

            if !authorizedByOldLiterals && !authorizedByInstruction && !authorizedByLocalRange && !authorizedByScope {
                return .failure(.protectedFactConflict)
            }
        }

        // 2. Check for unauthorized ADDITION of invented protected tokens
        let addedFacts = candidateFacts.filter { candidateFact in
            !targetFacts.contains { factsAreEquivalent(candidateFact, $0) }
        }
        for fact in addedFacts where ReviseFactExtractor.isHardProtectedToken(fact.text) {
            let token = fact.text
            let authorizedByNewLiterals = analysis.explicitNewLiterals.contains { new in
                normalizedFactText(new).contains(normalizedFactText(token))
                    || normalizedFactText(token).contains(normalizedFactText(new))
            }
            let authorizedByInstruction = normalizedFactText(instruction).contains(normalizedFactText(token))
                || instructionFacts.contains { factsAreEquivalent(fact, $0) }
            let isListMarker = appearsOnlyAsListMarker(token, in: candidate)

            if !authorizedByNewLiterals && !authorizedByInstruction && !isListMarker {
                return .failure(.protectedFactConflict)
            }
        }

        // 3. Verify facts outside authorized ranges remain completely identical in candidate
        if let authorizedRanges, !authorizedRanges.isEmpty {
            for fact in targetFacts {
                let isInsideAuth = authorizedRanges.contains { auth in
                    auth.overlaps(fact.range) || auth == fact.range
                }
                if !isInsideAuth {
                    // This fact was outside the authorized slot, candidate MUST contain it
                    if !candidateFacts.contains(where: { factsAreEquivalent(fact, $0) }) {
                        return .failure(.protectedFactConflict)
                    }
                }
            }
        }

        // 4. Check semantic negation relations (e.g. "prohibition" / "never")
        let targetNegations = semanticNegations(in: target)
        let candidateNegations = semanticNegations(in: candidate)
        let instructionMentionsNegation = instruction.contains("不要") || instruction.contains("别") || instruction.contains("允许") || instruction.contains("不")

        if !instructionMentionsNegation {
            if targetNegations["never", default: 0] != candidateNegations["never", default: 0]
                || targetNegations["prohibition", default: 0] != candidateNegations["prohibition", default: 0] {
                return .failure(.strongRelationChanged)
            }
        }

        return .success(())
    }

    private static func factsAreEquivalent(_ lhs: ReviseFact, _ rhs: ReviseFact) -> Bool {
        lhs.kind == rhs.kind && normalizedFactText(lhs.text) == normalizedFactText(rhs.text)
    }

    private static func normalizedFactText(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    private static func appearsOnlyAsListMarker(_ token: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        guard let marker = try? NSRegularExpression(
            pattern: #"(?m)^\s*"# + escaped + #"[.)、]\s*"#
        ) else { return false }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard marker.firstMatch(in: text, range: fullRange) != nil else { return false }
        let withoutMarkers = marker.stringByReplacingMatches(
            in: text,
            range: fullRange,
            withTemplate: ""
        )
        return withoutMarkers.range(of: token) == nil
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
            ("never", #"(?i)从不|绝不|never"#),
            ("inability", #"(?i)不能|无法|不可|can't|cannot"#),
            ("absence", #"(?i)尚未|没有|未|没|not\s+yet|didn't|hasn't|haven't"#),
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
