import Foundation

public enum ReviseOutputValidator {
    public static func validate(
        request: ReviseRequest,
        rawModelResponse: String,
        candidateTransform: ((String) -> String)? = nil
    ) -> ReviseProcessingResult {
        // 1. Parse raw model response
        let parseResult = ReviseModelResponseParser.parse(rawText: rawModelResponse)
        guard case .success(let response) = parseResult else {
            let rejection: ReviseRejection
            if case .failure(let err) = parseResult { rejection = err } else { rejection = .malformedJSON }
            let trace = ReviseValidationTrace(
                intent: nil,
                scopeKind: nil,
                targetResolution: "failed_parse",
                decision: "reject",
                rejection: rejection,
                warnings: [],
                diffHunkCount: nil,
                changeRatioBucket: nil,
                externalActionIgnored: false
            )
            return ReviseProcessingResult(
                request: request,
                response: nil,
                candidateText: nil,
                diff: nil,
                decision: .reject(rejection),
                trace: trace
            )
        }

        return validate(
            request: request,
            response: response,
            candidateTransform: candidateTransform
        )
    }

    public static func validate(
        request: ReviseRequest,
        response: ReviseModelResponse,
        candidateTransform: ((String) -> String)? = nil
    ) -> ReviseProcessingResult {
        let instructionAnalysis = ReviseInstructionAnalyzer.analyze(request.instruction, targetText: request.targetText)
        var warnings: [ReviseValidationWarning] = []

        // Resolve deterministic local replacements before trusting any model
        // metadata or output. If the instruction and target identify exactly one
        // slot, the locally constructed candidate is safer and more reliable than
        // a model-provided rewrite, scope, or ambiguity judgment.
        let authDecision = ReviseAuthorizationResolver.resolve(
            target: request.targetText,
            instruction: request.instruction,
            analysis: instructionAnalysis
        )
        var localAuthRanges: [Range<String.Index>]? = nil
        switch authDecision {
        case .ambiguous(let rejection):
            return rejectResult(
                request: request,
                response: response,
                rejection: rejection,
                scopeKind: response.scope.kind,
                warnings: warnings
            )
        case .authorized(let ranges, _):
            localAuthRanges = ranges
        case .unconstrained:
            break
        }

        let localCandidate = localAuthRanges.flatMap { ranges in
            instructionAnalysis.replacementAuthorization.flatMap { authorization in
                candidateByApplyingLocalReplacement(
                    target: request.targetText,
                    ranges: ranges,
                    authorization: authorization
                )
            }
        }
        var candidate = response.result
        if let localCandidate,
           candidate != localCandidate,
           removingWhitespace(from: candidate) != removingWhitespace(from: localCandidate) {
            candidate = localCandidate
            warnings.append(.modelOutputIgnoredForLocalReplacement)
        }
        let hasDeterministicLocalCandidate = localCandidate != nil

        // Apply deterministic output policy before any candidate checks. The value
        // returned by this validator must be the exact value later committed; otherwise
        // formatting after validation could introduce unscoped or unsafe changes.
        if let candidateTransform {
            candidate = candidateTransform(candidate)
        }

        // 2. Check ambiguity
        if response.ambiguous && !hasDeterministicLocalCandidate {
            return rejectResult(
                request: request,
                response: response,
                rejection: .modelAmbiguous,
                scopeKind: response.scope.kind,
                warnings: warnings
            )
        }

        // 3. Check intent
        if response.intent == .unsupported && !hasDeterministicLocalCandidate {
            return rejectResult(
                request: request,
                response: response,
                rejection: .unsupportedIntent,
                scopeKind: response.scope.kind,
                warnings: warnings
            )
        }
        if response.intent == .undo {
            return rejectResult(
                request: request,
                response: response,
                rejection: .unsupportedIntent,
                scopeKind: response.scope.kind,
                warnings: warnings
            )
        }

        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        // 4. Empty candidate handling
        if trimmedCandidate.isEmpty {
            if !instructionAnalysis.allowsEmptyResult {
                return rejectResult(
                    request: request,
                    response: response,
                    rejection: .disallowedEmptyOutput,
                    scopeKind: response.scope.kind,
                    warnings: warnings
                )
            }
        }

        // 5. Single line constraint
        if request.controlKind == .singleLine {
            if candidate.contains("\n") || candidate.contains("\r") {
                return rejectResult(
                    request: request,
                    response: response,
                    rejection: .singleLineViolation,
                    scopeKind: response.scope.kind,
                    warnings: warnings
                )
            }
        }

        // 6. Sensitive content scan
        if ReviseSensitiveTextScanner.containsSensitiveContent(candidate) &&
           !ReviseSensitiveTextScanner.containsSensitiveContent(request.targetText) {
            return rejectResult(
                request: request,
                response: response,
                rejection: .sensitiveContentLeak,
                scopeKind: response.scope.kind,
                warnings: warnings
            )
        }

        // 7. Extreme expansion check
        let maxAllowedLength = max(request.targetText.count * 3, request.targetText.count + 400)
        if candidate.count > maxAllowedLength {
            return rejectResult(
                request: request,
                response: response,
                rejection: .extremeExpansion,
                scopeKind: response.scope.kind,
                warnings: warnings
            )
        }

        // 8. Answer / explanation / execution claims
        if looksLikeAnswerOrExplanation(target: request.targetText, candidate: candidate) {
            return rejectResult(
                request: request,
                response: response,
                rejection: .answerOrExplanation,
                scopeKind: response.scope.kind,
                warnings: warnings
            )
        }
        if claimsExecution(candidate) {
            return rejectResult(
                request: request,
                response: response,
                rejection: .claimedExecution,
                scopeKind: response.scope.kind,
                warnings: warnings
            )
        }

        // 9. Language change check
        if !instructionAnalysis.allowsLanguageChange && response.intent != .translate {
            if didChangePrimaryScript(target: request.targetText, candidate: candidate) {
                return rejectResult(
                    request: request,
                    response: response,
                    rejection: .languageChangedWithoutAuthorization,
                    scopeKind: response.scope.kind,
                    warnings: warnings
                )
            }
        }

        // 10. Model scope resolution. A deterministic local range takes
        // precedence, so model scope is advisory in that case.
        let scopeResolution = ReviseScopeResolver.resolve(scope: response.scope, targetText: request.targetText)
        if localAuthRanges == nil {
            if case .ambiguous(let failure) = scopeResolution {
                let rejection: ReviseRejection
                switch failure {
                case .selectorNotFound:
                    rejection = .scopeNotFound
                case .multipleMatchesWithoutOrdinal:
                    rejection = .scopeMultipleMatchesWithoutOrdinal
                case .ordinalOutOfBounds:
                    rejection = .scopeOrdinalOutOfBounds
                case .invalidRange:
                    rejection = .scopeMissing
                }
                return rejectResult(
                    request: request,
                    response: response,
                    rejection: rejection,
                    scopeKind: response.scope.kind,
                    warnings: warnings
                )
            }
        }

        // 11. Diff calculation & scope bounding
        let diffResult = ReviseDiffCalculator.computeDiff(target: request.targetText, result: candidate)
        guard case .success(let diff) = diffResult else {
            let rejection: ReviseRejection
            if case .failure(let err) = diffResult { rejection = err } else { rejection = .diffBudgetExceeded }
            return rejectResult(
                request: request,
                response: response,
                rejection: rejection,
                scopeKind: response.scope.kind,
                warnings: warnings
            )
        }

        // Verify localized edits do not alter outside authorized scope
        let effectiveAuthRanges: [Range<String.Index>]? = {
            if let local = localAuthRanges { return local }
            if case .exact(let ranges) = scopeResolution { return ranges }
            return nil
        }()

        if instructionAnalysis.requiresMinimalChange || response.scope.kind == .literal || localAuthRanges != nil {
            if let targetRanges = effectiveAuthRanges {
                let targetString = request.targetText
                let authIntRanges: [Range<Int>] = targetRanges.compactMap { authRange in
                    let lower = targetString.distance(from: targetString.startIndex, to: authRange.lowerBound)
                    let upper = targetString.distance(from: targetString.startIndex, to: authRange.upperBound)
                    return lower <= upper ? lower..<upper : nil
                }

                for hunk in diff.hunks {
                    let hunkRange = hunk.sourceCharacterRange
                    let withinAuthorizedRange = authIntRanges.contains(where: { authIntRange in
                        if hunkRange.isEmpty {
                            return authIntRange.lowerBound <= hunkRange.lowerBound
                                && hunkRange.lowerBound <= authIntRange.upperBound
                        }
                        return authIntRange.lowerBound <= hunkRange.lowerBound
                            && hunkRange.upperBound <= authIntRange.upperBound
                    })
                    if !withinAuthorizedRange {
                        return rejectResult(
                            request: request,
                            response: response,
                            rejection: .changeOutsideAuthorizedScope,
                            scopeKind: response.scope.kind,
                            diff: diff,
                            warnings: warnings
                        )
                    }
                }
            }
        }

        // 12. Protected facts validation
        let factsResult = ReviseProtectedFactAnalyzer.validateFacts(
            target: request.targetText,
            candidate: candidate,
            instruction: request.instruction,
            analysis: instructionAnalysis,
            scopeResolution: scopeResolution,
            authorizedRanges: localAuthRanges
        )
        if case .failure(let rejection) = factsResult {
            return rejectResult(
                request: request,
                response: response,
                rejection: rejection,
                scopeKind: response.scope.kind,
                diff: diff,
                warnings: warnings
            )
        }

        if instructionAnalysis.hasExternalActionTail || response.externalActionRequested {
            warnings.append(.externalActionIgnored)
        }
        if diff.changeRatio > 0.5 {
            warnings.append(.largeRewrite)
        }

        let trace = ReviseValidationTrace(
            intent: response.intent,
            scopeKind: response.scope.kind,
            targetResolution: "resolved",
            decision: "accept",
            rejection: nil,
            warnings: warnings,
            diffHunkCount: diff.hunks.count,
            changeRatioBucket: ReviseValidationTrace.ratioBucket(diff.changeRatio),
            externalActionIgnored: warnings.contains(.externalActionIgnored)
        )

        return ReviseProcessingResult(
            request: request,
            response: response,
            candidateText: candidate,
            diff: diff,
            decision: .accept(warnings: warnings),
            trace: trace
        )
    }

    private static func candidateByApplyingLocalReplacement(
        target: String,
        ranges: [Range<String.Index>],
        authorization: ReviseReplacementAuthorization
    ) -> String? {
        guard ranges.count == 1, let range = ranges.first else { return nil }
        let newValue: String
        switch authorization {
        case .explicit(_, let value):
            newValue = value
        case .implicit(let value, let slotKind):
            if slotKind == .time,
               timeQualifier(in: value) == nil,
               let existingQualifier = timeQualifier(in: String(target[range])) {
                newValue = existingQualifier + value
            } else {
                newValue = value
            }
        }

        var expected = target
        expected.replaceSubrange(range, with: newValue)
        return expected
    }

    private static func timeQualifier(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let qualifiers = ["上午", "下午", "早上", "中午", "晚上", "凌晨", "清晨", "傍晚"]
        return qualifiers.first { trimmed.hasPrefix($0) }
    }

    private static func removingWhitespace(from text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static func rejectResult(
        request: ReviseRequest,
        response: ReviseModelResponse,
        rejection: ReviseRejection,
        scopeKind: ReviseScopeDescriptor.Kind?,
        diff: ReviseDiffSummary? = nil,
        warnings: [ReviseValidationWarning]
    ) -> ReviseProcessingResult {
        let trace = ReviseValidationTrace(
            intent: response.intent,
            scopeKind: scopeKind,
            targetResolution: "rejected",
            decision: "reject",
            rejection: rejection,
            warnings: warnings,
            diffHunkCount: diff?.hunks.count,
            changeRatioBucket: diff.map { ReviseValidationTrace.ratioBucket($0.changeRatio) },
            externalActionIgnored: warnings.contains(.externalActionIgnored)
        )
        return ReviseProcessingResult(
            request: request,
            response: response,
            candidateText: response.result,
            diff: diff,
            decision: .reject(rejection),
            trace: trace
        )
    }

    private static func looksLikeAnswerOrExplanation(target: String, candidate: String) -> Bool {
        let prefixes = [
            "答案是", "回答", "当然可以", "好的，", "好的！", "好的,", "以下是", "解释如下", "建议如下", "修改后的内容：",
            "the answer is", "sure,", "sure!", "here is", "here's", "i recommend",
        ]
        let lowerCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerTarget = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        for prefix in prefixes {
            let lowerPrefix = prefix.lowercased()
            if lowerCandidate.hasPrefix(lowerPrefix) && !lowerTarget.hasPrefix(lowerPrefix) {
                return true
            }
        }
        return false
    }

    private static func claimsExecution(_ candidate: String) -> Bool {
        let claims = ["已经为你发送", "已为你发送", "操作完成", "部署完成", "发送成功", "已发送", "创建成功", "done", "completed successfully"]
        let lower = candidate.lowercased()
        return claims.contains { lower.contains($0.lowercased()) }
    }

    private static func didChangePrimaryScript(target: String, candidate: String) -> Bool {
        let targetCounts = scriptCounts(target)
        let candidateCounts = scriptCounts(candidate)
        if targetCounts.cjk >= 4 && candidateCounts.cjk == 0 {
            return true
        }
        guard targetCounts.total >= 8 && candidateCounts.total >= 8 else { return false }
        let targetCJKRatio = Double(targetCounts.cjk) / Double(targetCounts.total)
        let candidateCJKRatio = Double(candidateCounts.cjk) / Double(candidateCounts.total)
        return (targetCJKRatio >= 0.65 && candidateCJKRatio <= 0.2)
            || (targetCJKRatio <= 0.2 && candidateCJKRatio >= 0.65)
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
}
