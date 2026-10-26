import Foundation

public enum ReviseUndoClassifier {
    private static let exactUndoPhrases: Set<String> = [
        "撤销刚才的改口",
        "撤销改口",
        "撤销刚才那次",
        "撤销刚才修改",
        "撤销刚才的修改",
        "撤销上一次改口",
        "恢复上一版",
        "恢复上一版本",
        "恢复上一个版本",
        "恢复原样",
        "刚才那次不要了",
        "刚才的不算",
        "撤销",
        "undo",
        "undo the last revision",
        "undo last revision",
        "revert the last change",
        "revert last change",
    ]

    public static func isUndoInstruction(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。，,.!！?？"))
            .lowercased()

        // Negative check: contains "不要撤销", "别撤销", "解释", "怎么撤销"
        if trimmed.contains("不要撤销") || trimmed.contains("别撤销") || trimmed.contains("怎么撤销") || trimmed.contains("为什么") {
            return false
        }

        if exactUndoPhrases.contains(trimmed) {
            return true
        }

        let regexPatterns = [
            #"^(?:请)?(?:撤销|恢复)(?:刚才|刚刚|上一次|上一轮)?(?:的)?(?:改口|修改|版本|那次)?$"#,
            #"^(?:刚才|刚刚)(?:那次|修改|改口)?(?:不要了|不算|作废)$"#,
            #"(?i)^undo(?:\s+(?:the\s+)?(?:last\s+)?(?:revision|change|edit))?$"#,
            #"(?i)^revert(?:\s+(?:to\s+)?(?:the\s+)?(?:previous|last)\s+version)?$"#,
        ]

        for pattern in regexPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                if regex.firstMatch(in: trimmed, range: range) != nil {
                    return true
                }
            }
        }

        return false
    }
}
