import Foundation

public struct ReviseInstructionAnalysis: Equatable, Sendable {
    public let likelyIntent: ReviseIntent?
    public let requiresMinimalChange: Bool
    public let allowsWholeRewrite: Bool
    public let allowsLanguageChange: Bool
    public let allowsEmptyResult: Bool
    public let explicitOldLiterals: [String]
    public let explicitNewLiterals: [String]
    public let replacementAuthorization: ReviseReplacementAuthorization?
    public let explicitProtectedTokens: Set<String>
    public let ordinalReferences: [Int]
    public let hasExternalActionTail: Bool

    public init(
        likelyIntent: ReviseIntent?,
        requiresMinimalChange: Bool,
        allowsWholeRewrite: Bool,
        allowsLanguageChange: Bool,
        allowsEmptyResult: Bool,
        explicitOldLiterals: [String],
        explicitNewLiterals: [String],
        replacementAuthorization: ReviseReplacementAuthorization? = nil,
        explicitProtectedTokens: Set<String>,
        ordinalReferences: [Int],
        hasExternalActionTail: Bool
    ) {
        self.likelyIntent = likelyIntent
        self.requiresMinimalChange = requiresMinimalChange
        self.allowsWholeRewrite = allowsWholeRewrite
        self.allowsLanguageChange = allowsLanguageChange
        self.allowsEmptyResult = allowsEmptyResult
        self.explicitOldLiterals = explicitOldLiterals
        self.explicitNewLiterals = explicitNewLiterals
        self.replacementAuthorization = replacementAuthorization
        self.explicitProtectedTokens = explicitProtectedTokens
        self.ordinalReferences = ordinalReferences
        self.hasExternalActionTail = hasExternalActionTail
    }
}

public enum ReviseInstructionAnalyzer {
    public static func analyze(_ instruction: String, targetText: String = "") -> ReviseInstructionAnalysis {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        var likelyIntent: ReviseIntent? = nil
        var explicitOldLiterals: [String] = []
        var explicitNewLiterals: [String] = []
        var replacementAuthorization: ReviseReplacementAuthorization? = nil

        // Check external action tail
        let externalActionPatterns = [
            #"(?:改好|改完|修改完)?(?:后|之后)?(?:直接)?(?:发送|发出去|发给|提交)"#,
            #"(?i)send\s+(?:it|this)?\s*(?:after|to)?"#,
            #"(?i)submit\s+(?:it|this)?"#,
        ]
        let hasExternalActionTail = externalActionPatterns.contains { pattern in
            trimmed.range(of: pattern, options: .regularExpression) != nil
        }

        // Minimal change constraints
        let minimalChangePatterns = [
            #"只改"#,
            #"其他(?:都)?别动"#,
            #"其他(?:都)?不要改"#,
            #"其他(?:都)?保持原样"#,
            #"其余(?:都)?不变"#,
            #"(?i)only\s+change"#,
            #"(?i)don't\s+change\s+(?:anything\s+)?else"#,
            #"(?i)keep\s+the\s+rest"#,
        ]
        var requiresMinimalChange = minimalChangePatterns.contains { pattern in
            trimmed.range(of: pattern, options: .regularExpression) != nil
        }

        // Language change
        let languagePatterns = [
            #"(?:翻成|翻译成|改成|换成)(?:英文|英语|中文|汉语|日文|日语|法文|法语|德文|德语|韩文|韩语|西班牙语)"#,
            #"(?i)translate\s+(?:in)?to\s+(?:english|chinese|japanese|french|german|korean|spanish)"#,
        ]
        let allowsLanguageChange = languagePatterns.contains { pattern in
            trimmed.range(of: pattern, options: .regularExpression) != nil
        }

        // Whole rewrite / style / formatting
        let wholeRewritePatterns = [
            #"更简洁"#, #"简短一点"#, #"精简一点"#, #"自然一点"#, #"口语化"#, #"正式一点"#,
            #"语气(?:别那么|温和|强硬)"#, #"改成列表"#, #"编号列表"#, #"合成一段"#, #"分段"#,
            #"(?i)more\s+concise"#, #"(?i)more\s+formal"#, #"(?i)more\s+casual"#,
            #"(?i)as\s+a\s+list"#, #"(?i)bullet\s+points"#,
        ]
        let allowsWholeRewrite = wholeRewritePatterns.contains { pattern in
            trimmed.range(of: pattern, options: .regularExpression) != nil
        }

        // Entire delete
        let entireDeletePatterns = [
            #"全都删掉"#, #"整段删除"#, #"全部清除"#, #"都删了"#,
            #"(?i)delete\s+all"#, #"(?i)clear\s+all"#, #"(?i)delete\s+everything"#,
        ]
        let allowsEmptyResult = entireDeletePatterns.contains { pattern in
            trimmed.range(of: pattern, options: .regularExpression) != nil
        }

        // 1. Precise explicit replace patterns: "把 X 改成/换成/改为 Y", "不是 X 是 Y", "X 拼成 Y"
        let replaceRegexPatterns = [
            #"(?:把|将)\s*([^\s,，。]+?)\s*(?:改成|换成|改为|替换为|替换成|拼成|写成)\s*([^\s,，。]+)"#,
            #"不是\s*([^\s,，。]+?)\s*(?:，|,)?\s*(?:是|改成|换成)\s*([^\s,，。]+)"#,
            #"(?i)replace\s+(.+?)\s+with\s+(.+)"#,
            #"(?i)change\s+(.+?)\s+to\s+(.+)"#,
        ]

        for pattern in replaceRegexPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let full = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                if let match = regex.firstMatch(in: trimmed, range: full),
                   match.numberOfRanges >= 3,
                   let r1 = Range(match.range(at: 1), in: trimmed),
                   let r2 = Range(match.range(at: 2), in: trimmed) {
                    let oldVal = String(trimmed[r1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let newVal = String(trimmed[r2]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !oldVal.isEmpty && !newVal.isEmpty {
                        explicitOldLiterals.append(oldVal)
                        explicitNewLiterals.append(newVal)
                        likelyIntent = .replace
                        requiresMinimalChange = true
                        replacementAuthorization = .explicit(oldValue: oldVal, newValue: newVal)
                        break
                    }
                }
            }
        }

        // 2. Implicit replace patterns (省略旧值替换): "改成 Y", "换成 Y", "改为 Y", "设为 Y", "change it to Y"
        if likelyIntent == nil && !allowsLanguageChange && !allowsWholeRewrite {
            let implicitPatterns = [
                #"^(?:直接)?(?:改成|换成|改为|设为|替换为|替换成|更新为|调整为)\s*(.+)$"#,
                #"(?i)^change\s+(?:it\s+)?to\s+(.+)$"#,
                #"(?i)^set\s+(?:it\s+)?to\s+(.+)$"#,
            ]
            for pattern in implicitPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let full = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                if let match = regex.firstMatch(in: trimmed, range: full),
                   match.numberOfRanges >= 2,
                   let r = Range(match.range(at: 1), in: trimmed) {
                    var newVal = String(trimmed[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Strip trailing external action expressions like "并发送", "然后发送"
                    let tailPatterns = [
                        #"(?:并|然后|之后|接着|并直接)?(?:发送|发出去|提交|发给.+)$"#,
                        #"(?i)(?:and\s+)?(?:send|submit)\s*(?:it)?$"#,
                    ]
                    for tp in tailPatterns {
                        if let tailRange = newVal.range(of: tp, options: .regularExpression) {
                            newVal = String(newVal[..<tailRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }

                    if !newVal.isEmpty {
                        if let slotKind = ReviseFactExtractor.detectPrimaryFactKind(in: newVal) {
                            newVal = normalizedImplicitFactValue(newVal, kind: slotKind)
                            likelyIntent = .replace
                            requiresMinimalChange = true
                            replacementAuthorization = .implicit(newValue: newVal, slotKind: slotKind)
                            explicitNewLiterals.append(newVal)
                            break
                        }
                    }
                }
            }
        }

        // 3. Delete patterns
        if likelyIntent == nil {
            let deletePatterns = [
                #"(?:删掉|删除|去掉|去除|不要)\s*(?:最后一句|第一句|开头|结尾|第[一二三四五六七八九十\d]+[段句点项]|客套话)"#,
                #"(?i)delete\s+"#, #"(?i)remove\s+"#,
            ]
            if deletePatterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) {
                likelyIntent = .delete
            }
        }

        // 4. Insert patterns
        if likelyIntent == nil {
            let insertPatterns = [
                #"(?:加一句|加上|补充|开头加|最后加|末尾加)\s*(.+)"#,
                #"(?i)add\s+"#, #"(?i)insert\s+"#,
            ]
            if insertPatterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) {
                likelyIntent = .insert
            }
        }

        // 5. Translate / Format / Rewrite
        if likelyIntent == nil {
            if allowsLanguageChange {
                likelyIntent = .translate
            } else if trimmed.contains("列表") || trimmed.contains("分段") || trimmed.contains("合成一段") || lower.contains("list") {
                likelyIntent = .format
            } else if allowsWholeRewrite {
                likelyIntent = .rewrite
            }
        }

        // Extract ordinal references: "第1个", "第二句", "最后一句", "第3点"
        var ordinals: [Int] = []
        let ordinalPattern = #"(?:第\s*([0-9一二三四五六七八九十]+)\s*[个条句段项点]|(?:first|second|third|fourth|fifth|\b(\d+)(?:st|nd|rd|th)\b))"#
        if let regex = try? NSRegularExpression(pattern: ordinalPattern, options: .caseInsensitive) {
            let full = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            let matches = regex.matches(in: trimmed, range: full)
            for m in matches {
                if let r1 = Range(m.range(at: 1), in: trimmed) {
                    let s = String(trimmed[r1])
                    if let n = Int(s) {
                        ordinals.append(n)
                    } else {
                        let cjkMap: [String: Int] = [
                            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
                        ]
                        if let n = cjkMap[s] { ordinals.append(n) }
                    }
                }
            }
        }
        if trimmed.contains("最后") || lower.contains("last") {
            ordinals.append(-1)
        }

        // Extract protected tokens from the instruction itself
        let instTokens = ReviseFactExtractor.tokens(in: trimmed)

        return ReviseInstructionAnalysis(
            likelyIntent: likelyIntent,
            requiresMinimalChange: requiresMinimalChange,
            allowsWholeRewrite: allowsWholeRewrite,
            allowsLanguageChange: allowsLanguageChange,
            allowsEmptyResult: allowsEmptyResult,
            explicitOldLiterals: explicitOldLiterals,
            explicitNewLiterals: explicitNewLiterals,
            replacementAuthorization: replacementAuthorization,
            explicitProtectedTokens: instTokens,
            ordinalReferences: ordinals,
            hasExternalActionTail: hasExternalActionTail
        )
    }

    /// Streaming ASR commonly appends sentence punctuation to a short command,
    /// e.g. `改成下午2点。`. When the captured value consists of one structured
    /// fact plus only punctuation/whitespace, keep the fact itself as the
    /// replacement value so the punctuation is not inserted into the sentence.
    private static func normalizedImplicitFactValue(_ value: String, kind: ReviseFactKind) -> String {
        let facts = ReviseFactExtractor.extractFacts(in: value)
        guard facts.count == 1, let fact = facts.first, fact.kind == kind else { return value }

        var remainder = value
        remainder.removeSubrange(fact.range)
        let ignorable = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        guard remainder.unicodeScalars.allSatisfy({ ignorable.contains($0) }) else { return value }
        return fact.text
    }
}
