import Foundation

enum GroqHallucinationPhrases {
    static let knownPhrases: Set<String> = [
        "thank you",
        "thank you for watching",
        "thanks for watching",
        "you",
        "продолжение следует",
        "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
        "请不吝点赞 订阅 转发",
        "请订阅明镜与点点栏目",
        "字幕由amara.org社区提供",
        "字幕由 amara.org 社区提供",
        "字幕由amaraorg社区提供",
        "谢谢观看",
        "谢谢收看",
        "优优独播剧场——yoyo television series exclusive",
        "优优独播剧场",
    ]

    static func normalize(_ text: String) -> String {
        var str = text.lowercased()
        let punctuation = CharacterSet.punctuationCharacters
            .union(CharacterSet(charactersIn: "。，、？！；：“”‘’（）《》【】…—.!?,:;\"'"))
        str = str.trimmingCharacters(in: .whitespacesAndNewlines.union(punctuation))
        let components = str.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return components.joined(separator: " ")
    }

    static func isHallucination(_ text: String) -> Bool {
        let normalized = normalize(text)
        if normalized.isEmpty { return true }
        return knownPhrases.contains(normalized)
    }
}
