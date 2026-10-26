import XCTest
@testable import Type4Me
@testable import Type4MeReviseCore

final class ReviseCoreTests: XCTestCase {

    // MARK: - Parser Tests

    func testParseValidResponse() {
        let json = """
        {
          "schema_version": 1,
          "intent": "replace",
          "scope": {
            "kind": "literal",
            "selector": "三点",
            "ordinal": 1
          },
          "ambiguous": false,
          "external_action_requested": false,
          "result": "明天下午四点和 Jerry 开会。"
        }
        """
        let result = ReviseModelResponseParser.parse(rawText: json)
        guard case .success(let response) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }
        XCTAssertEqual(response.schemaVersion, 1)
        XCTAssertEqual(response.intent, .replace)
        XCTAssertEqual(response.scope.kind, .literal)
        XCTAssertEqual(response.scope.selector, "三点")
        XCTAssertEqual(response.scope.ordinal, 1)
        XCTAssertFalse(response.ambiguous)
        XCTAssertFalse(response.externalActionRequested)
        XCTAssertEqual(response.result, "明天下午四点和 Jerry 开会。")
    }

    func testParseResponseWithThinkTags() {
        let text = """
        <think>
        User wants to change 3 to 4.
        </think>
        {
          "schema_version": 1,
          "intent": "replace",
          "scope": {
            "kind": "literal",
            "selector": "三点"
          },
          "ambiguous": false,
          "external_action_requested": false,
          "result": "明天下午四点开会。"
        }
        """
        let result = ReviseModelResponseParser.parse(rawText: text)
        guard case .success(let response) = result else {
            XCTFail("Expected success after stripping think tags")
            return
        }
        XCTAssertEqual(response.intent, .replace)
    }

    func testParseRejectsCodeFences() {
        let markdown = """
        ```json
        {
          "schema_version": 1,
          "intent": "replace",
          "scope": { "kind": "whole" },
          "ambiguous": false,
          "external_action_requested": false,
          "result": "test"
        }
        ```
        """
        let result = ReviseModelResponseParser.parse(rawText: markdown)
        guard case .failure(let err) = result else {
            XCTFail("Expected failure for markdown code fence")
            return
        }
        XCTAssertEqual(err, .codeFence)
    }

    func testParseRejectsSchemaMismatch() {
        let json = """
        {
          "schema_version": 99,
          "intent": "replace",
          "scope": { "kind": "whole" },
          "ambiguous": false,
          "external_action_requested": false,
          "result": "test"
        }
        """
        let result = ReviseModelResponseParser.parse(rawText: json)
        guard case .failure(let err) = result else {
            XCTFail("Expected failure for schema version mismatch")
            return
        }
        XCTAssertEqual(err, .schemaVersionMismatch)
    }

    // MARK: - Undo Classifier Tests

    func testUndoClassifier() {
        XCTAssertTrue(ReviseUndoClassifier.isUndoInstruction("撤销刚才的改口"))
        XCTAssertTrue(ReviseUndoClassifier.isUndoInstruction("恢复上一版"))
        XCTAssertTrue(ReviseUndoClassifier.isUndoInstruction("刚才那次不要了。"))
        XCTAssertTrue(ReviseUndoClassifier.isUndoInstruction("undo the last revision"))
        XCTAssertTrue(ReviseUndoClassifier.isUndoInstruction("revert the last change"))

        XCTAssertFalse(ReviseUndoClassifier.isUndoInstruction("不要撤销刚才的改口"))
        XCTAssertFalse(ReviseUndoClassifier.isUndoInstruction("把‘撤销’两个字删掉"))
        XCTAssertFalse(ReviseUndoClassifier.isUndoInstruction("解释一下怎么撤销"))
        XCTAssertFalse(ReviseUndoClassifier.isUndoInstruction("把三点改成四点"))
    }

    // MARK: - Instruction Analyzer Tests

    func testInstructionAnalyzerReplace() {
        let analysis = ReviseInstructionAnalyzer.analyze("把下午三点改成四点，其他别动")
        XCTAssertEqual(analysis.likelyIntent, .replace)
        XCTAssertTrue(analysis.requiresMinimalChange)
        XCTAssertEqual(analysis.explicitOldLiterals, ["下午三点"])
        XCTAssertEqual(analysis.explicitNewLiterals, ["四点"])
        XCTAssertFalse(analysis.hasExternalActionTail)
    }

    func testInstructionAnalyzerExternalAction() {
        let analysis = ReviseInstructionAnalyzer.analyze("删掉最后一句，改好后直接发送")
        XCTAssertEqual(analysis.likelyIntent, .delete)
        XCTAssertTrue(analysis.hasExternalActionTail)
        XCTAssertTrue(analysis.ordinalReferences.contains(-1))
    }

    func testInstructionAnalyzerLanguageChange() {
        let analysis = ReviseInstructionAnalyzer.analyze("翻成英文，专有名词不要动")
        XCTAssertEqual(analysis.likelyIntent, .translate)
        XCTAssertTrue(analysis.allowsLanguageChange)
    }

    // MARK: - Scope Resolver Tests

    func testScopeResolverLiteralSingleMatch() {
        let target = "明天下午三点和 Jerry 开会。"
        let scope = ReviseScopeDescriptor(kind: .literal, selector: "三点")
        let res = ReviseScopeResolver.resolve(scope: scope, targetText: target)
        guard case .exact(let ranges) = res else {
            XCTFail("Expected exact range")
            return
        }
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(target[ranges[0]]), "三点")
    }

    func testScopeResolverLiteralMultipleMatchesWithOrdinal() {
        let target = "Type4Me 是一个语音工具，Type4Me Pro 更强。"
        let scope = ReviseScopeDescriptor(kind: .literal, selector: "Type4Me", ordinal: 2)
        let res = ReviseScopeResolver.resolve(scope: scope, targetText: target)
        guard case .exact(let ranges) = res else {
            XCTFail("Expected exact range for 2nd match")
            return
        }
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(target.distance(from: target.startIndex, to: ranges[0].lowerBound), 16)
    }

    func testScopeResolverLiteralMultipleMatchesWithoutOrdinal() {
        let target = "Type4Me 是一个语音工具，Type4Me Pro 更强。"
        let scope = ReviseScopeDescriptor(kind: .literal, selector: "Type4Me")
        let res = ReviseScopeResolver.resolve(scope: scope, targetText: target)
        guard case .ambiguous(let failure) = res else {
            XCTFail("Expected ambiguous without ordinal")
            return
        }
        XCTAssertEqual(failure, .multipleMatchesWithoutOrdinal)
    }

    func testScopeResolverSentences() {
        let target = "第一句话。第二句话！第三句话？"
        let scope = ReviseScopeDescriptor(kind: .sentence, ordinal: -1)
        let res = ReviseScopeResolver.resolve(scope: scope, targetText: target)
        guard case .exact(let ranges) = res else {
            XCTFail("Expected exact range for last sentence")
            return
        }
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(target[ranges[0]]), "第三句话？")
    }

    // MARK: - Diff Calculator Tests

    func testDiffCalculator() {
        let oldText = "明天下午三点和 Jerry 开会。"
        let newText = "明天下午四点和 Jerry 开会。"
        let diffRes = ReviseDiffCalculator.computeDiff(target: oldText, result: newText)
        guard case .success(let diff) = diffRes else {
            XCTFail("Expected diff success")
            return
        }
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.hunks[0].removedText, "三")
        XCTAssertEqual(diff.hunks[0].insertedText, "四")
    }

    // MARK: - Sensitive Scanner Tests

    func testSensitiveScanner() {
        XCTAssertTrue(ReviseSensitiveTextScanner.containsSensitiveContent("api_key = abcdef123456"))
        XCTAssertTrue(ReviseSensitiveTextScanner.containsSensitiveContent("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        XCTAssertTrue(ReviseSensitiveTextScanner.containsSensitiveContent("-----BEGIN RSA PRIVATE KEY-----"))
        XCTAssertTrue(ReviseSensitiveTextScanner.containsSensitiveContent("ghp_1234567890abcdef1234567890abcdef1234"))
        XCTAssertFalse(ReviseSensitiveTextScanner.containsSensitiveContent("明天下午三点和 Jerry 开会。"))
    }

    // MARK: - Output Validator End-to-End Tests

    func testValidatorAcceptsPreciseReplace() {
        let req = ReviseRequest(
            targetText: "明天下午三点和 Jerry 开会。",
            instruction: "把三点改成四点，其他别动",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .intelliSense
        )
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .literal, selector: "三点", ordinal: 1),
            ambiguous: false,
            externalActionRequested: false,
            result: "明天下午四点和 Jerry 开会。"
        )
        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)
        guard case .accept = res.decision else {
            XCTFail("Expected accept, got \(res.decision)")
            return
        }
        XCTAssertEqual(res.candidateText, "明天下午四点和 Jerry 开会。")
    }

    func testValidatorReturnsExactFormattedCandidate() {
        let req = ReviseRequest(
            targetText: "讨论OpenAI项目",
            instruction: "调整排版",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .format,
            scope: .init(kind: .whole),
            ambiguous: false,
            externalActionRequested: false,
            result: "讨论OpenAI项目"
        )
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .pangu,
            usesCornerQuotes: false,
            trailingPunctuationMode: .off
        )

        let res = ReviseOutputValidator.validate(
            request: req,
            response: modelResponse,
            candidateTransform: { TextOutputFormatter.format($0, options: options) }
        )

        guard case .accept = res.decision else {
            XCTFail("Expected accept, got \(res.decision)")
            return
        }
        XCTAssertEqual(res.candidateText, "讨论 OpenAI 项目")
        XCTAssertEqual(res.diff?.hunks.count, 2)
    }

    func testValidatorRejectsFormattingOutsideAuthorizedReplacement() {
        let req = ReviseRequest(
            targetText: "明天上午 9 点开会，联系OpenAI",
            instruction: "改成下午 2 点",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .whole),
            ambiguous: false,
            externalActionRequested: false,
            result: "明天下午 2 点开会，联系OpenAI"
        )
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .pangu,
            usesCornerQuotes: false,
            trailingPunctuationMode: .off
        )

        let res = ReviseOutputValidator.validate(
            request: req,
            response: modelResponse,
            candidateTransform: { TextOutputFormatter.format($0, options: options) }
        )

        XCTAssertEqual(res.decision, .reject(.changeOutsideAuthorizedScope))
    }

    func testValidatorIgnoresModelChangeOutsideDeterministicScope() {
        let req = ReviseRequest(
            targetText: "明天下午三点和 Jerry 开会，预算是 5000 元。",
            instruction: "把三点改成四点",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .intelliSense
        )
        // Model scope is literal "三点", but it also changed 5000 to 8000
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .literal, selector: "三点", ordinal: 1),
            ambiguous: false,
            externalActionRequested: false,
            result: "明天下午四点和 Jerry 开会，预算是 8000 元。"
        )
        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)
        guard case .accept(let warnings) = res.decision else {
            XCTFail("Expected safe local replacement, got \(res.decision)")
            return
        }
        XCTAssertEqual(res.candidateText, "明天下午四点和 Jerry 开会，预算是 5000 元。")
        XCTAssertTrue(warnings.contains(.modelOutputIgnoredForLocalReplacement))
    }

    func testValidatorRejectsUnauthorizedFactAdditionInRewrite() {
        let req = ReviseRequest(
            targetText: "明天下午开会，预算是 5000 元。",
            instruction: "更简洁一点",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .intelliSense
        )
        // Model rewrite changed 5000 to 8000 without authorization
        let modelResponse = ReviseModelResponse(
            intent: .rewrite,
            scope: .init(kind: .whole),
            ambiguous: false,
            externalActionRequested: false,
            result: "明天开会，预算 8000 元。"
        )
        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)
        guard case .reject(let reason) = res.decision else {
            XCTFail("Expected reject for unauthorized fact addition")
            return
        }
        XCTAssertEqual(reason, .protectedFactConflict)
    }

    func testValidatorIgnoresConversationalWrapperForDeterministicReplacement() {
        let req = ReviseRequest(
            targetText: "明天下午三点开会。",
            instruction: "改成四点",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: false),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .whole),
            ambiguous: false,
            externalActionRequested: false,
            result: "好的，修改后的内容：明天下午四点开会。"
        )
        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)
        guard case .accept(let warnings) = res.decision else {
            XCTFail("Expected safe local replacement, got \(res.decision)")
            return
        }
        XCTAssertEqual(res.candidateText, "明天下午四点开会。")
        XCTAssertTrue(warnings.contains(.modelOutputIgnoredForLocalReplacement))
    }

    func testValidatorRejectsSingleLineNewline() {
        let req = ReviseRequest(
            targetText: "搜索关键词",
            instruction: "分成两行",
            controlKind: .singleLine,
            sourceLanguage: .init(primaryScript: "han", mixed: false),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .format,
            scope: .init(kind: .whole),
            ambiguous: false,
            externalActionRequested: false,
            result: "搜索\n关键词"
        )
        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)
        guard case .reject(let reason) = res.decision else {
            XCTFail("Expected reject for single line newline violation")
            return
        }
        XCTAssertEqual(reason, .singleLineViolation)
    }

    // MARK: - Local Unique Slot Authorization & Test Plan Scenarios

    func testImplicitTimeReplacementSuccessWithSpaces() {
        let req = ReviseRequest(
            targetText: "明天上午 9 点开会一起确认一下",
            instruction: "改成下午 2 点",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .literal, selector: "上午 9 点"),
            ambiguous: false,
            externalActionRequested: false,
            result: "明天下午 2 点开会一起确认一下"
        )
        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)
        guard case .accept = res.decision else {
            XCTFail("Expected accept for implicit time slot replacement, got \(res.decision)")
            return
        }
        XCTAssertEqual(res.candidateText, "明天下午 2 点开会一起确认一下")
    }

    func testImplicitTimeReplacementNormalizesASRPunctuationAndPanguSpacing() {
        let req = ReviseRequest(
            targetText: "明天早上 9 点我们开会讨论产品的 Roadmap",
            instruction: "改成下午2点。",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .intelliSense
        )
        let response = ReviseModelResponse(
            intent: .rewrite,
            scope: .init(kind: .whole),
            ambiguous: false,
            externalActionRequested: false,
            result: "明天下午2点。我们开会讨论产品的 Roadmap"
        )
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .pangu,
            usesCornerQuotes: false,
            trailingPunctuationMode: .all
        )

        let result = ReviseOutputValidator.validate(
            request: req,
            response: response,
            candidateTransform: { TextOutputFormatter.format($0, options: options) }
        )

        guard case .accept = result.decision else {
            XCTFail("Expected accept, got \(result.decision)")
            return
        }
        XCTAssertEqual(result.candidateText, "明天下午 2 点我们开会讨论产品的 Roadmap")
    }

    func testImplicitTimeReplacementSuccessNoSpaces() {
        let req = ReviseRequest(
            targetText: "明天上午9点开会",
            instruction: "换成下午2点",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .literal, selector: "上午9点"),
            ambiguous: false,
            externalActionRequested: false,
            result: "明天下午2点开会"
        )
        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)
        guard case .accept = res.decision else {
            XCTFail("Expected accept for implicit time slot replacement without spaces")
            return
        }
        XCTAssertEqual(res.candidateText, "明天下午2点开会")
    }

    func testImplicitTimeReplacement24HourSuccess() {
        let req = ReviseRequest(
            targetText: "明天 9 点开会",
            instruction: "改为 14:30",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .literal, selector: "9 点"),
            ambiguous: false,
            externalActionRequested: false,
            result: "明天 14:30 开会"
        )
        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)
        guard case .accept = res.decision else {
            XCTFail("Expected accept for 24h format replacement")
            return
        }
        XCTAssertEqual(res.candidateText, "明天 14:30 开会")
    }

    func testImplicitTimeReplacementAmbiguousRejected() {
        let req = ReviseRequest(
            targetText: "9 点开会，16 点复盘",
            instruction: "改成下午 2 点",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .whole),
            ambiguous: false,
            externalActionRequested: false,
            result: "下午 2 点开会，16 点复盘"
        )
        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)
        guard case .reject(let reason) = res.decision else {
            XCTFail("Expected reject for ambiguous multiple time slots")
            return
        }
        XCTAssertEqual(reason, .implicitReplacementAmbiguous)
    }

    func testImplicitTimeReplacementPreservesMoneyFact() {
        let req = ReviseRequest(
            targetText: "9 点开会，预算 5000",
            instruction: "改成下午 2 点",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .direct
        )
        // Valid candidate: only time modified, budget 5000 preserved
        let validResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .literal, selector: "9 点"),
            ambiguous: false,
            externalActionRequested: false,
            result: "下午 2 点开会，预算 5000"
        )
        let validRes = ReviseOutputValidator.validate(request: req, response: validResponse)
        guard case .accept = validRes.decision else {
            XCTFail("Expected accept when budget 5000 is preserved")
            return
        }

        // Unsafe model candidate: budget erroneously altered to 8000. The
        // deterministic local candidate must win and preserve 5000.
        let invalidResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .literal, selector: "9 点"),
            ambiguous: false,
            externalActionRequested: false,
            result: "下午 2 点开会，预算 8000"
        )
        let invalidRes = ReviseOutputValidator.validate(request: req, response: invalidResponse)
        guard case .accept(let warnings) = invalidRes.decision else {
            XCTFail("Expected safe local replacement, got \(invalidRes.decision)")
            return
        }
        XCTAssertEqual(invalidRes.candidateText, "下午 2 点开会，预算 5000")
        XCTAssertTrue(warnings.contains(.modelOutputIgnoredForLocalReplacement))
    }

    func testImplicitMoneyReplacementSuccess() {
        let req = ReviseRequest(
            targetText: "预算 5000 元",
            instruction: "改成 8000 元",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .literal, selector: "5000 元"),
            ambiguous: false,
            externalActionRequested: false,
            result: "预算 8000 元"
        )
        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)
        guard case .accept = res.decision else {
            XCTFail("Expected accept for implicit money slot replacement")
            return
        }
        XCTAssertEqual(res.candidateText, "预算 8000 元")
    }

    func testImplicitNumberReplacementAmbiguousRejected() {
        let req = ReviseRequest(
            targetText: "预算 5000，人数 9",
            instruction: "改成 2",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .whole),
            ambiguous: false,
            externalActionRequested: false,
            result: "预算 5000，人数 2"
        )
        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)
        guard case .reject(let reason) = res.decision else {
            XCTFail("Expected reject for ambiguous multiple numbers")
            return
        }
        XCTAssertEqual(reason, .implicitReplacementAmbiguous)
    }

    func testImplicitTimeReplacementWithExternalActionIgnored() {
        let req = ReviseRequest(
            targetText: "明天 9 点开会",
            instruction: "改成下午 2 点并发送",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: true),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .literal, selector: "9 点"),
            ambiguous: false,
            externalActionRequested: false,
            result: "明天下午 2 点开会"
        )
        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)
        guard case .accept(let warnings) = res.decision else {
            XCTFail("Expected accept with warning for external action tail")
            return
        }
        XCTAssertTrue(warnings.contains(.externalActionIgnored))
        XCTAssertEqual(res.candidateText, "明天下午 2 点开会")
    }

    func testImplicitReplacementIgnoresModelHunkThatCrossesSlotBoundary() {
        let req = ReviseRequest(
            targetText: "明天上午 9 点开会",
            instruction: "改成下午 2 点",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: false),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .whole),
            ambiguous: false,
            externalActionRequested: false,
            result: "明天下午 2 时散会"
        )

        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)

        guard case .accept(let warnings) = res.decision else {
            XCTFail("Expected safe local replacement, got \(res.decision)")
            return
        }
        XCTAssertEqual(res.candidateText, "明天下午 2 点开会")
        XCTAssertTrue(warnings.contains(.modelOutputIgnoredForLocalReplacement))
    }

    func testImplicitReplacementIgnoresModelInsertionAtSlotBoundary() {
        let req = ReviseRequest(
            targetText: "明天 9 点开会",
            instruction: "改成下午 2 点",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: false),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .replace,
            scope: .init(kind: .whole),
            ambiguous: false,
            externalActionRequested: false,
            result: "明天下午 2 点取消开会"
        )

        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)

        guard case .accept(let warnings) = res.decision else {
            XCTFail("Expected safe local replacement, got \(res.decision)")
            return
        }
        XCTAssertEqual(res.candidateText, "明天下午 2 点开会")
        XCTAssertTrue(warnings.contains(.modelOutputIgnoredForLocalReplacement))
    }

    func testImplicitReplacementUsesLocalCandidateWhenModelRewritesInEnglish() {
        let req = ReviseRequest(
            targetText: "明天上午 9 点开会，讨论这个项目的进度",
            instruction: "改成下午 2 点",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: false),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .rewrite,
            scope: .init(kind: .whole),
            ambiguous: false,
            externalActionRequested: false,
            result: "Let's meet tomorrow afternoon at 2 to discuss the project's progress."
        )

        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)

        guard case .accept(let warnings) = res.decision else {
            XCTFail("Expected deterministic local replacement, got \(res.decision)")
            return
        }
        XCTAssertEqual(res.candidateText, "明天下午 2 点开会，讨论这个项目的进度")
        XCTAssertTrue(warnings.contains(.modelOutputIgnoredForLocalReplacement))
    }

    func testImplicitReplacementOverridesUnsupportedAmbiguousModelMetadata() {
        let req = ReviseRequest(
            targetText: "明天上午 9 点开会，讨论这个项目的进度",
            instruction: "改成下午 2 点",
            controlKind: .multiLine,
            sourceLanguage: .init(primaryScript: "han", mixed: false),
            sourceModeKind: .direct
        )
        let modelResponse = ReviseModelResponse(
            intent: .unsupported,
            scope: .init(kind: .semantic),
            ambiguous: true,
            externalActionRequested: false,
            result: req.targetText
        )

        let res = ReviseOutputValidator.validate(request: req, response: modelResponse)

        guard case .accept(let warnings) = res.decision else {
            XCTFail("Expected deterministic local replacement, got \(res.decision)")
            return
        }
        XCTAssertEqual(res.candidateText, "明天下午 2 点开会，讨论这个项目的进度")
        XCTAssertTrue(warnings.contains(.modelOutputIgnoredForLocalReplacement))
    }
}
