import Foundation

public enum ListStructureIntent: Equatable, Sendable {
    case none
    case unordered(minimumItems: Int)
    case ordered(expectedItems: Int)

    public var requiredItemCount: Int? {
        switch self {
        case .none: nil
        case .unordered(let minimumItems): minimumItems
        case .ordered(let expectedItems): expectedItems
        }
    }
}

public enum ListStructureIntentAnalyzer {
    public static func analyze(_ text: String) -> ListStructureIntent {
        let normalized = text.precomposedStringWithCanonicalMapping
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }

        let orderedCandidates = [
            chineseOrdinalValues(in: normalized),
            bareChineseOrdinalValues(in: normalized),
            chineseIsValues(in: normalized),
            arabicMarkerValues(in: normalized),
            englishOrdinalValues(in: normalized),
        ]
        if let sequence = orderedCandidates
            .filter({ $0.count >= 2 && isContiguousFromOne($0) })
            .max(by: { $0.count < $1.count }) {
            return .ordered(expectedItems: sequence.count)
        }

        let transitionCount = orderedTransitionCount(in: normalized)
        if transitionCount >= 2 {
            return .ordered(expectedItems: transitionCount)
        }

        let existingItems = listItemCount(in: normalized)
        if existingItems >= 2 {
            return .unordered(minimumItems: existingItems)
        }

        if let declared = declaredItemCount(in: normalized), declared >= 3 {
            return .unordered(minimumItems: declared)
        }
        return .none
    }

    public static func supportsStructuredOutput(_ context: IntelliSenseContextSnapshot?) -> Bool {
        guard let context else { return true }
        return context.controlCategory != .search
            && context.controlCategory != .title
            && context.controlCategory != .terminal
            && context.appCategory != .terminal
    }

    public static func listItemCount(in text: String) -> Int {
        matches(#"(?m)^\s*(?:[-*•]|\d+[.)、]|[一二三四五六七八九十]+[、.)）])\s*\S"#, in: text).count
    }

    private static func chineseOrdinalValues(in text: String) -> [Int] {
        let captures = matches(
            #"第\s*([一二两三四五六七八九十\d]+)\s*(?:(个|项|点|部分|块|步|方面|类|种|条|阶段)(?:\s*(?:是|为|：|:|、|，|,|就|需要|要|由|针对))?|(?:是|为|：|:|、|，|,|就|需要|要|由|针对))"#,
            in: text
        )
        return captures.compactMap { chineseNumber($0[1]) }
    }

    private static func chineseIsValues(in text: String) -> [Int] {
        matches(#"(?:^|[\s，,。；;：:])([一二三四五六七八九十])\s*(?:是|要|为)"#, in: text)
            .compactMap { chineseNumber($0[1]) }
    }

    private static func bareChineseOrdinalValues(in text: String) -> [Int] {
        let pattern = #"第\s*([一二两三四五六七八九十\d]+)(?!\s*(?:版|天|次|章|页|届|代|年|月|周|季度))"#
        return matches(pattern, in: text).compactMap { chineseNumber($0[1]) }
    }

    private static func arabicMarkerValues(in text: String) -> [Int] {
        matches(#"(?:^|[\s，,。；;：:])(\d{1,2})\s*[.)、：:]"#, in: text)
            .compactMap { Int($0[1]) }
    }

    private static func englishOrdinalValues(in text: String) -> [Int] {
        let pattern = #"(?i)(?:^|[\s,.;:])(first(?:ly)?|second(?:ly)?|third(?:ly)?|fourth(?:ly)?|fifth(?:ly)?)(?=\s|[,.;:])"#
        return matches(pattern, in: text).compactMap {
            switch $0[1].lowercased() {
            case "first", "firstly": 1
            case "second", "secondly": 2
            case "third", "thirdly": 3
            case "fourth", "fourthly": 4
            case "fifth", "fifthly": 5
            default: nil
            }
        }
    }

    private static func orderedTransitionCount(in text: String) -> Int {
        let lowercased = text.lowercased()
        let chinese = ["首先", "其次", "再次", "最后"].filter { lowercased.contains($0) }
        guard chinese.contains("首先") else { return 0 }
        return chinese.count
    }

    private static func declaredItemCount(in text: String) -> Int? {
        let pattern = #"(?:分为|包括|包含|涉及|共有|有|存在)\s*([一二两三四五六七八九十\d]+)\s*(?:个|项|点|部分|块|步|方面|类|种|条|阶段|问题|事情|内容)"#
        return matches(pattern, in: text).compactMap { chineseNumber($0[1]) }.max()
    }

    private static func isContiguousFromOne(_ values: [Int]) -> Bool {
        var unique: [Int] = []
        for value in values where unique.last != value {
            unique.append(value)
        }
        return unique == Array(1...unique.count)
    }

    private static func chineseNumber(_ value: String) -> Int? {
        if let number = Int(value) { return number }
        let digits: [Character: Int] = [
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        if value == "十" { return 10 }
        if value.hasPrefix("十"), let tail = value.last.flatMap({ digits[$0] }) { return 10 + tail }
        if value.hasSuffix("十"), let head = value.first.flatMap({ digits[$0] }) { return head * 10 }
        if value.contains("十") {
            let parts = value.split(separator: "十", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let head = parts[0].first.flatMap({ digits[$0] }),
                  let tail = parts[1].first.flatMap({ digits[$0] })
            else { return nil }
            return head * 10 + tail
        }
        return value.count == 1 ? value.first.flatMap { digits[$0] } : nil
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                let capture = match.range(at: index)
                guard capture.location != NSNotFound,
                      let swiftRange = Range(capture, in: text)
                else { return "" }
                return String(text[swiftRange])
            }
        }
    }
}
