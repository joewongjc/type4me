import Foundation

public enum IntelliSenseValidationWarning: String, Codable, Equatable, Sendable {
    case sourceProtectedTokenChanged
    case negationCountChanged
    case listStructureChanged
    case expectedListStructureMissing
    case largeRewrite
    case supersededContentRetained
    case contextTermAdopted
}

public enum IntelliSenseGuardRejection: String, Codable, Equatable, Sendable {
    case emptyOutput
    case protectedTokenChanged
    case negationChanged
    case responseMarkerChanged
    case answerOrExplanation
    case claimedExecution
    case codeFence
    case toolCall
    case extremeExpansion
    case languageChanged
    case sensitiveContentLeak
    case inventedProtectedFact
}

public enum IntelliSenseGuardDecision: Equatable, Sendable {
    case accept
    case acceptWithWarnings([IntelliSenseValidationWarning])
    case reject(IntelliSenseGuardRejection)
}

public struct IntelliSenseProcessingResult: Equatable, Sendable {
    public let candidateText: String
    public let finalText: String
    public let decision: IntelliSenseGuardDecision
    public let correctionAnalysis: CorrectionIntentAnalysis

    public init(
        candidateText: String,
        finalText: String,
        decision: IntelliSenseGuardDecision,
        correctionAnalysis: CorrectionIntentAnalysis
    ) {
        self.candidateText = candidateText
        self.finalText = finalText
        self.decision = decision
        self.correctionAnalysis = correctionAnalysis
    }
}

public enum IntelliSenseOutputValidator {
    public static func process(
        input: String,
        candidate: String,
        context: IntelliSenseContextSnapshot? = nil
    ) -> IntelliSenseProcessingResult {
        let analysis = CorrectionIntentAnalysis.analyze(input)
        let decision = evaluate(input: input, output: candidate, context: context, analysis: analysis)
        let final: String
        if case .reject = decision { final = input } else { final = candidate }
        return IntelliSenseProcessingResult(
            candidateText: candidate,
            finalText: final,
            decision: decision,
            correctionAnalysis: analysis
        )
    }

    public static func evaluate(
        input: String,
        output: String,
        context: IntelliSenseContextSnapshot? = nil
    ) -> IntelliSenseGuardDecision {
        evaluate(
            input: input,
            output: output,
            context: context,
            analysis: CorrectionIntentAnalysis.analyze(input)
        )
    }

    private static func evaluate(
        input: String,
        output: String,
        context: IntelliSenseContextSnapshot?,
        analysis: CorrectionIntentAnalysis
    ) -> IntelliSenseGuardDecision {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .reject(.emptyOutput) }
        guard !trimmed.contains("```") else { return .reject(.codeFence) }
        guard !looksLikeToolCall(trimmed) else { return .reject(.toolCall) }
        guard preservesLeadingResponseMarker(input: input, output: trimmed) else {
            return .reject(.responseMarkerChanged)
        }
        guard !looksLikeAnswerOrExplanation(input: input, output: trimmed) else {
            return .reject(.answerOrExplanation)
        }
        guard !claimsExecution(input: input, output: trimmed) else { return .reject(.claimedExecution) }

        for token in analysis.requiredProtectedTokens
        where ProtectedFactExtractor.isHardProtectedToken(token)
            && !contains(token: token, in: trimmed) {
            return .reject(.protectedTokenChanged)
        }
        let outputNegations = CorrectionIntentAnalysis.analyze(trimmed).semanticNegationCounts
        guard compatibleNegationRelations(analysis.semanticNegationCounts, outputNegations) else {
            return .reject(.negationChanged)
        }

        let inputCount = max(1, input.count)
        guard trimmed.count <= max(inputCount * 3, inputCount + 120) else {
            return .reject(.extremeExpansion)
        }
        guard !didChangePrimaryScript(input: input, output: trimmed) else {
            return .reject(.languageChanged)
        }
        guard !introducesSensitiveContent(input: input, output: trimmed) else {
            return .reject(.sensitiveContentLeak)
        }
        guard !inventsProtectedFact(input: input, output: trimmed, context: context) else {
            return .reject(.inventedProtectedFact)
        }

        var warnings: [IntelliSenseValidationWarning] = []
        if analysis.semanticNegationCounts != outputNegations {
            warnings.append(.negationCountChanged)
        }
        let inputTokens = ProtectedFactExtractor.tokens(in: input)
        if inputTokens != ProtectedFactExtractor.tokens(in: trimmed), analysis.supersededProtectedTokens.isEmpty {
            warnings.append(.sourceProtectedTokenChanged)
        }
        if listMarkerCount(in: trimmed) != listMarkerCount(in: input) {
            warnings.append(.listStructureChanged)
        }
        let structureIntent = ListStructureIntentAnalyzer.analyze(input)
        if ListStructureIntentAnalyzer.supportsStructuredOutput(context),
           let requiredItems = structureIntent.requiredItemCount,
           ListStructureIntentAnalyzer.listItemCount(in: trimmed) < requiredItems {
            warnings.append(.expectedListStructureMissing)
        }
        if abs(trimmed.count - input.count) > max(24, input.count / 2) {
            warnings.append(.largeRewrite)
        }
        if analysis.supersededProtectedTokens.contains(where: { contains(token: $0, in: trimmed) }) {
            warnings.append(.supersededContentRetained)
        }
        if let context, adoptedContextTerm(input: input, output: trimmed, context: context) {
            warnings.append(.contextTermAdopted)
        }
        return warnings.isEmpty ? .accept : .acceptWithWarnings(warnings)
    }

    private static func contains(token: String, in text: String) -> Bool {
        text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func compatibleNegationRelations(
        _ input: [String: Int],
        _ output: [String: Int]
    ) -> Bool {
        // During product evaluation, only strong prohibitions and emphatic
        // "never" relations justify discarding the entire polished result.
        // Other negation changes are observable warnings because valid
        // paraphrases frequently change their surface count.
        return input["prohibition", default: 0] == output["prohibition", default: 0]
            && input["never", default: 0] == output["never", default: 0]
    }

    private static func looksLikeAnswerOrExplanation(input: String, output: String) -> Bool {
        guard let outputPrefix = leadingAnswerPrefix(in: output) else { return false }
        return !sourceStartsWithAnswerPrefix(input, prefix: outputPrefix)
    }

    private static func sourceStartsWithAnswerPrefix(_ text: String, prefix: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix(prefix) else { return false }
        let isASCIIEnglishPrefix = prefix.unicodeScalars.allSatisfy { $0.value < 128 }
        guard isASCIIEnglishPrefix else { return true }
        let boundaryIndex = normalized.index(normalized.startIndex, offsetBy: prefix.count)
        guard boundaryIndex < normalized.endIndex else { return true }
        let next = normalized[boundaryIndex]
        return next.isWhitespace || "，,：:。.!！?？".contains(next)
    }

    private static func leadingAnswerPrefix(in text: String) -> String? {
        let prefixes = [
            "答案是", "回答", "当然可以", "好的", "以下是", "解释如下", "建议如下",
            "the answer is", "sure", "here is", "here's", "i recommend",
        ]
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return prefixes.first { prefix in
            guard normalized.hasPrefix(prefix) else { return false }
            let boundaryIndex = normalized.index(normalized.startIndex, offsetBy: prefix.count)
            guard boundaryIndex < normalized.endIndex else { return true }
            let next = normalized[boundaryIndex]
            return next.isWhitespace || "，,：:。.!！?？".contains(next)
        }
    }

    private static func preservesLeadingResponseMarker(input: String, output: String) -> Bool {
        guard let inputMarker = leadingResponseMarker(in: input) else { return true }
        return leadingResponseMarker(in: output) == inputMarker
    }

    private static func leadingResponseMarker(in text: String) -> String? {
        let markers = ["当然可以", "好的", "okay", "yes", "ok", "嗯", "哦", "好"]
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        for marker in markers where lower.hasPrefix(marker) {
            let boundaryIndex = lower.index(lower.startIndex, offsetBy: marker.count)
            guard boundaryIndex < lower.endIndex else { return marker }
            let next = lower[boundaryIndex]
            guard "，,：:。.!！?？".contains(next) else { continue }
            let remainder = lower[lower.index(after: boundaryIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nonResponseContinuations = [
                "那个", "呃", "啊", "就是说", "你知道吧",
                "不对", "哦不", "改成", "换成", "应该是", "i mean", "sorry",
            ]
            guard !nonResponseContinuations.contains(where: remainder.hasPrefix) else {
                continue
            }
            return marker
        }
        return nil
    }

    private static func claimsExecution(input: String, output: String) -> Bool {
        let requestSignals = ["帮我", "请", "部署", "发送", "删除", "创建", "打开", "关闭"]
        guard requestSignals.contains(where: input.contains) else { return false }
        let claims = ["已经为你", "已为你", "操作完成", "部署完成", "发送成功", "删除成功", "创建成功", "done", "completed successfully"]
        let lower = output.lowercased()
        return claims.contains { lower.hasPrefix($0.lowercased()) }
    }

    private static func looksLikeToolCall(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("<tool_call")
            || lower.contains("\"tool_calls\"")
            || lower.hasPrefix("{\"name\":")
            || lower.hasPrefix("{\n  \"name\":")
    }

    private static func listMarkerCount(in text: String) -> Int {
        text.split(separator: "\n").filter { line in
            line.range(of: #"^\s*(?:[-*•]|\d+[.)、])\s*"#, options: .regularExpression) != nil
        }.count
    }

    private static func didChangePrimaryScript(input: String, output: String) -> Bool {
        let inputCounts = scriptCounts(input)
        let outputCounts = scriptCounts(output)
        // Mixed technical dictation can contain many Latin path/identifier
        // tokens while its surrounding sentence is still clearly Chinese.
        // Never allow that Chinese carrier sentence to disappear entirely.
        if inputCounts.cjk >= 4, outputCounts.cjk == 0 {
            return true
        }
        guard inputCounts.total >= 8, outputCounts.total >= 8 else { return false }
        let inputCJKRatio = Double(inputCounts.cjk) / Double(inputCounts.total)
        let outputCJKRatio = Double(outputCounts.cjk) / Double(outputCounts.total)
        return (inputCJKRatio >= 0.65 && outputCJKRatio <= 0.2)
            || (inputCJKRatio <= 0.2 && outputCJKRatio >= 0.65)
    }

    private static func scriptCounts(_ text: String) -> (cjk: Int, latin: Int, total: Int) {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) { cjk += 1 }
            else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) { latin += 1 }
        }
        return (cjk, latin, cjk + latin)
    }

    private static func introducesSensitiveContent(input: String, output: String) -> Bool {
        !containsSensitivePattern(input) && containsSensitivePattern(output)
    }

    private static func containsSensitivePattern(_ text: String) -> Bool {
        let patterns = [
            #"(?i)\b(?:api[_-]?key|secret|access[_-]?token|password)\b\s*[:=]"#,
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{12,}={0,2}"#,
            #"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----"#,
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func inventsProtectedFact(
        input: String,
        output: String,
        context: IntelliSenseContextSnapshot?
    ) -> Bool {
        let inputTokens = ProtectedFactExtractor.tokens(in: input)
        let outputTokens = ProtectedFactExtractor.tokens(in: output)
        let contextText = (context?.contextBeforeCursor ?? "") + "\n" + (context?.contextAfterCursor ?? "")
        let contextTokens = ProtectedFactExtractor.tokens(in: contextText)
        let additions = outputTokens.filter { token in
            !inputTokens.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame })
                && !contextTokens.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame })
        }
        guard !additions.isEmpty else { return false }
        // New Arabic facts are hard errors when the source already contained
        // protected facts. For ASR-shaped Chinese-number normalization, emit no
        // hard rejection because the source may not contain an Arabic token.
        return !inputTokens.isEmpty && additions.contains { token in
            token.rangeOfCharacter(from: .decimalDigits) != nil
                && !appearsOnlyAsListMarker(token, in: output)
        }
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
        return !contains(token: token, in: withoutMarkers)
    }

    private static func adoptedContextTerm(
        input: String,
        output: String,
        context: IntelliSenseContextSnapshot
    ) -> Bool {
        let contextText = context.contextBeforeCursor + "\n" + context.contextAfterCursor
        let terms = ProtectedFactExtractor.tokens(in: contextText)
        return terms.contains { term in !contains(token: term, in: input) && contains(token: term, in: output) }
    }
}

// Compatibility spelling retained for existing product call sites while the
// richer validator result is adopted incrementally.
public typealias IntelliSenseOutputGuard = IntelliSenseOutputValidator
