import Foundation

/// What can truthfully be said about why a history record's delivered text differs
/// from what was recognised (#300).
///
/// Recognised text passes through replacement rules, then possibly an LLM,
/// translation and output formatting. Only the rules that fired are recorded, at
/// the moment they fired, so an explanation never re-runs today's rules against an
/// old record and never attributes an LLM's edit to a rule.
struct CorrectionProvenance: Equatable {

    enum Explanation: Equatable {
        /// Recognised and delivered text are identical.
        case identical
        /// Replacement rules rewrote the recognised text. `thenChangedFurther` is
        /// true when the delivered text differs from what the rules produced.
        case rewrittenByRules([AppliedSnippetRule], thenChangedFurther: Bool)
        /// No rule fired; the difference came from later processing.
        case laterProcessingOnly
        /// The texts differ and the record does not say which step caused it: it
        /// predates provenance, was saved by recovery, or came from an older build.
        case unknown
    }

    let deliveredText: String
    let explanation: Explanation

    init(
        rawText: String,
        postSnippetText: String?,
        finalText: String,
        appliedSnippets: [AppliedSnippetRule]?
    ) {
        deliveredText = finalText
        guard let appliedSnippets else {
            explanation = finalText == rawText ? .identical : .unknown
            return
        }
        if appliedSnippets.isEmpty {
            explanation = finalText == rawText ? .identical : .laterProcessingOnly
        } else {
            explanation = .rewrittenByRules(
                appliedSnippets,
                thenChangedFurther: (postSnippetText ?? rawText) != finalText
            )
        }
    }

    init(record: HistoryRecord) {
        self.init(
            rawText: record.rawText,
            postSnippetText: record.postSnippetText,
            finalText: record.finalText,
            appliedSnippets: record.appliedSnippets
        )
    }

    var appliedRules: [AppliedSnippetRule] {
        if case .rewrittenByRules(let rules, _) = explanation { return rules }
        return []
    }

    /// Why the characters in the correction sheet differ from the history list.
    /// `nil` when there is nothing to explain.
    func message(language: AppLanguage) -> String? {
        switch explanation {
        case .identical:
            return nil
        case .rewrittenByRules(_, let thenChangedFurther) where thenChangedFurther:
            return language == .zh
                ? "识别结果先被下列替换规则改写，之后又经过了进一步处理（例如润色、翻译或格式化）。下方是原始识别结果。"
                : "The recognition was rewritten by the replacement rules below, then changed further by later processing such as polishing, translation or formatting. The characters below are the original recognition."
        case .rewrittenByRules:
            return language == .zh
                ? "这条记录的输出被下列替换规则改写过。下方是原始识别结果，纠错以它为准。"
                : "This output was rewritten by the replacement rules below. The characters below are the original recognition, which corrections are matched against."
        case .laterProcessingOnly:
            return language == .zh
                ? "没有替换规则参与。输出与原始识别不同，是后续处理（例如润色、翻译或格式化）造成的。下方是原始识别结果。"
                : "No replacement rule was involved. The output differs from the original recognition because of later processing such as polishing, translation or formatting. The characters below are the original recognition."
        case .unknown:
            return language == .zh
                ? "输出与原始识别不同，但这条记录没有保存差异的来源。下方是原始识别结果。"
                : "The output differs from the original recognition, but this record does not say what caused it. The characters below are the original recognition."
        }
    }

    static func scopeLabel(bundleId: String?, appName: String?, language: AppLanguage) -> String {
        guard let bundleId else { return language == .zh ? "全局" : "Global" }
        return appName ?? bundleId
    }

    /// Whether a recorded rule still exists as it was. It may have been edited or
    /// deleted since, in which case there is nothing left to open.
    static func ruleStillExists(
        _ rule: AppliedSnippetRule,
        in rules: [(trigger: String, value: String)]
    ) -> Bool {
        rules.contains {
            $0.trigger.caseInsensitiveCompare(rule.trigger) == .orderedSame && $0.value == rule.value
        }
    }
}
