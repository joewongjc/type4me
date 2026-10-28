import Foundation

/// The request that turns "the selection is wrong, and here is what I said"
/// into the text to write.
public enum CorrectionPrompt {
    public struct Input: Equatable, Sendable {
        public var before: String
        public var selected: String
        public var after: String
        /// What the speech service heard when the user explained the fix.
        public var spoken: String
        /// Spellings the user already rejected, oldest first.
        public var attempts: [String]

        public init(before: String, selected: String, after: String, spoken: String, attempts: [String]) {
            self.before = before
            self.selected = selected
            self.after = after
            self.spoken = spoken
            self.attempts = attempts
        }
    }

    public static func build(_ input: Input, chinese: Bool) -> (system: String, user: String) {
        (chinese ? systemZH : systemEN, user(input, chinese: chinese))
    }

    /// The visible text with the selection marked ⟦*⟧ and each other
    /// occurrence ⟦n⟧, numbered like `CorrectionOccurrences`.
    public static func markedText(_ input: Input) -> String {
        let length = input.selected.count
        let occurrences = CorrectionOccurrences.find(before: input.before, after: input.after, matching: input.selected)
        var before = Array(input.before)
        var after = Array(input.after)
        // Back to front, so earlier offsets stay valid while marks go in.
        for occurrence in occurrences.reversed() {
            let open = Array("⟦\(occurrence.number)⟧"), close = Array("⟦/\(occurrence.number)⟧")
            if occurrence.offset < 0 {
                let start = before.count + occurrence.offset
                before.insert(contentsOf: close, at: start + length)
                before.insert(contentsOf: open, at: start)
            } else {
                let start = occurrence.offset - length
                after.insert(contentsOf: close, at: start + length)
                after.insert(contentsOf: open, at: start)
            }
        }
        return String(before) + "⟦*⟧" + input.selected + "⟦/*⟧" + String(after)
    }

    private static func user(_ input: Input, chinese: Bool) -> String {
        let attempts = input.attempts.isEmpty
            ? (chinese ? "（无）" : "(none)")
            : input.attempts.map { "「\($0)」" }.joined(separator: chinese ? "、" : ", ")
        if chinese {
            return """
            原文：
            \(markedText(input))

            用户说的话（语音识别结果）：\(input.spoken)
            已被否定的写法：\(attempts)
            """
        }
        return """
        Text:
        \(markedText(input))

        What the user said (speech recognition): \(input.spoken)
        Already rejected: \(attempts)
        """
    }

    private static let systemZH = """
    你在帮用户修正语音输入里识别错的文字。原文中 ⟦*⟧…⟦/*⟧ 标出的部分识别错了，用户刚才口头说明了正确内容。

    规则：
    1. 用户的话也经过了语音识别，可能同样有误。如果它和被标出的内容相同或读音相近，说明这是同音或近音错误，请根据上下文推断最可能的正确写法，不要原样返回。
    2. 用户可能直接说出正确内容，也可能带着解释，比如"叹气那个欸""姓张，弓长张""是英文缩写"。只返回最终应写入的文字，不要把解释写进去。
    3. 用户也可能把整段完整地重说一遍，这时直接返回重说的内容。
    4. 用户也可能不直接说正确内容，而是说明为什么错、本来想表达什么意思，比如"不是这个，我说的是天气忽冷忽热那个""这里应该是一个人名""意思反了"。这时结合上下文和用户的描述，推断最可能的正确写法。用户话里提到的错误写法（如"不是 X"里的 X）不是答案。
    5. 返回的内容必须和被标出的内容不同。"已被否定的写法"里的内容也不能再给，此时给出下一个最可能的写法。
    6. 原文里 ⟦1⟧、⟦2⟧ 等标出的是和被标出内容相同的其他位置。逐个判断它们是不是同一个错误，是的放进 also。
    7. 只输出 JSON，不要输出其他文字：{"replacement": "正确写法", "also": [编号]}。只要用户的话里有任何线索，就给出最可能的写法；只有完全无法从用户的话和上下文推断时，才输出 {"replacement": null}。
    """

    private static let systemEN = """
    You fix words that speech recognition got wrong. In the text, the part marked ⟦*⟧…⟦/*⟧ was misrecognized, and the user just said what it should be.

    Rules:
    1. What the user said also went through speech recognition and may be wrong the same way. If it matches or sounds like the marked part, it is a homophone or near-homophone error: infer the most likely spelling from context instead of returning it unchanged.
    2. The user may say the right words directly or explain them, such as "the sigh one", "surname Zhang, the one with a bow", or "it's an English abbreviation". Return only the text to write, never the explanation.
    3. The user may also say the whole passage again; then return what they said.
    4. The user may instead explain why it is wrong or what they meant, such as "not that, I meant the weather going up and down", "this should be a person's name", or "it means the opposite". Then infer the most likely spelling from the context and their description. A wrong spelling they mention (the X in "not X") is not the answer.
    5. Your answer must differ from the marked part. Never return anything listed as already rejected either; give the next most likely spelling instead.
    6. Places marked ⟦1⟧, ⟦2⟧ and so on read the same as the marked part. Decide for each whether it is the same mistake, and list those in "also".
    7. Output JSON only, nothing else: {"replacement": "the right text", "also": [numbers]}. Whenever what the user said gives any clue, give the most likely spelling; output {"replacement": null} only when nothing in their words or the context lets you infer it.
    """
}
