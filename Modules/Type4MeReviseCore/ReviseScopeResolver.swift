import Foundation

public enum ReviseScopeFailure: String, Equatable, Sendable {
    case selectorNotFound
    case multipleMatchesWithoutOrdinal
    case ordinalOutOfBounds
    case invalidRange
}

public enum ReviseScopeResolution: Equatable, Sendable {
    case whole
    case exact([Range<String.Index>])
    case semantic
    case ambiguous(ReviseScopeFailure)
}

public enum ReviseScopeResolver {
    public static func resolve(scope: ReviseScopeDescriptor, targetText: String) -> ReviseScopeResolution {
        switch scope.kind {
        case .whole:
            return .whole

        case .semantic:
            return .semantic

        case .literal:
            guard let selector = scope.selector, !selector.isEmpty else {
                return .ambiguous(.selectorNotFound)
            }
            let matches = findMatches(of: selector, in: targetText)
            if matches.isEmpty {
                return .ambiguous(.selectorNotFound)
            }
            if matches.count == 1 {
                return .exact(matches)
            }
            if let ordinal = scope.ordinal {
                if ordinal == -1, let last = matches.last {
                    return .exact([last])
                }
                if ordinal >= 1 && ordinal <= matches.count {
                    return .exact([matches[ordinal - 1]])
                }
                return .ambiguous(.ordinalOutOfBounds)
            }
            return .ambiguous(.multipleMatchesWithoutOrdinal)

        case .sentence:
            let sentences = extractSentences(in: targetText)
            guard !sentences.isEmpty else { return .whole }
            if let ordinal = scope.ordinal {
                if ordinal == -1, let last = sentences.last {
                    return .exact([last])
                }
                if ordinal >= 1 && ordinal <= sentences.count {
                    return .exact([sentences[ordinal - 1]])
                }
                return .ambiguous(.ordinalOutOfBounds)
            }
            return .whole

        case .paragraph:
            let paragraphs = extractParagraphs(in: targetText)
            guard !paragraphs.isEmpty else { return .whole }
            if let ordinal = scope.ordinal {
                if ordinal == -1, let last = paragraphs.last {
                    return .exact([last])
                }
                if ordinal >= 1 && ordinal <= paragraphs.count {
                    return .exact([paragraphs[ordinal - 1]])
                }
                return .ambiguous(.ordinalOutOfBounds)
            }
            return .whole

        case .listItem:
            let items = extractListItems(in: targetText)
            guard !items.isEmpty else { return .whole }
            if let ordinal = scope.ordinal {
                if ordinal == -1, let last = items.last {
                    return .exact([last])
                }
                if ordinal >= 1 && ordinal <= items.count {
                    return .exact([items[ordinal - 1]])
                }
                return .ambiguous(.ordinalOutOfBounds)
            }
            return .whole
        }
    }

    private static func findMatches(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var matches: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            matches.append(range)
            searchStart = range.upperBound
        }
        return matches
    }

    private static func extractSentences(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let pattern = #"[^。！？!?.…\n]+[。！？!?.…\n]*"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: full) {
                if let r = Range(match.range, in: text) {
                    ranges.append(r)
                }
            }
        }
        return ranges.isEmpty && !text.isEmpty ? [text.startIndex..<text.endIndex] : ranges
    }

    private static func extractParagraphs(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let pattern = #"(?m)^.+$(?:\n|$)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: full) {
                if let r = Range(match.range, in: text) {
                    ranges.append(r)
                }
            }
        }
        return ranges.isEmpty && !text.isEmpty ? [text.startIndex..<text.endIndex] : ranges
    }

    private static func extractListItems(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let pattern = #"(?m)^\s*(?:[-*•]|\d+[.)、])\s*.+(?:\n|$)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: full) {
                if let r = Range(match.range, in: text) {
                    ranges.append(r)
                }
            }
        }
        return ranges
    }
}
