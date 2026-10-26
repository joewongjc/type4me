import Foundation

enum GroqHallucinationPhrases {

    /// Obvious video subtitle / scraper artifacts that are never spoken in normal dictation.
    static let unconditionalPhrases: Set<String> = [
        "продолжение следует",
        "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
        "请不吝点赞 订阅 转发",
        "请订阅明镜与点点栏目",
        "字幕由amara.org社区提供",
        "字幕由 amara.org 社区提供",
        "字幕由amaraorg社区提供",
        "优优独播剧场——yoyo television series exclusive",
        "优优独播剧场",
    ]

    /// Common conversational phrases that Whisper frequently hallucinates on silence/noise,
    /// but can also be legitimately spoken by users.
    static let suspectedSpeechPhrases: Set<String> = [
        "thank you",
        "thank you for watching",
        "thanks for watching",
        "you",
        "谢谢观看",
        "谢谢收看",
    ]

    static func normalize(_ text: String) -> String {
        var str = text.lowercased()
        let punctuation = CharacterSet.punctuationCharacters
            .union(CharacterSet(charactersIn: "。，、？！；：“”‘’（）《》【】…—.!?,:;\"'"))
        str = str.trimmingCharacters(in: .whitespacesAndNewlines.union(punctuation))
        let components = str.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return components.joined(separator: " ")
    }

    /// Evaluates whether the transcript is a hallucination by combining text matching with audio evidence.
    static func isHallucination(text: String, responseRoot: [String: Any]) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return true }

        // 1. Unconditional subtitle/scraper artifacts are always filtered
        if unconditionalPhrases.contains(normalized) {
            return true
        }

        // 2. Common spoken phrases are ONLY filtered when audio evidence indicates lack of genuine speech
        if suspectedSpeechPhrases.contains(normalized) {
            let duration = responseRoot["duration"] as? Double ?? 0
            let segments = responseRoot["segments"] as? [[String: Any]] ?? []

            guard let firstSeg = segments.first else {
                // Without segment metadata, adopt a conservative policy: preserve speech rather than deleting it
                return false
            }

            let end = firstSeg["end"] as? Double ?? 0
            let noSpeechProb = firstSeg["no_speech_prob"] as? Double ?? 0
            let avgLogprob = firstSeg["avg_logprob"] as? Double ?? 0

            // Audio evidence of hallucination:
            // a) Whisper 30s hallucination timestamp: segment end exceeds actual audio duration by more than 0.5s
            if duration > 0 && end > duration + 0.5 {
                return true
            }

            // b) High probability of no speech or very poor acoustic confidence
            if noSpeechProb > 0.5 || avgLogprob < -1.2 {
                return true
            }

            // Otherwise, audio evidence confirms legitimate speech -> DO NOT FILTER
            return false
        }

        return false
    }
}
