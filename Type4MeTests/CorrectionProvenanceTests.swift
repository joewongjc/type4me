import XCTest
@testable import Type4Me

/// #300 review: the correction sheet must not assert that a replacement rule
/// caused a difference unless the record says so.
final class CorrectionProvenanceTests: XCTestCase {

    private let docRule = AppliedSnippetRule(trigger: "Doc", value: "Docker", bundleId: nil)

    func testIdenticalTextsNeedNoExplanation() {
        for applied in [nil, []] as [[AppliedSnippetRule]?] {
            let p = CorrectionProvenance(rawText: "同样", postSnippetText: "同样", finalText: "同样", appliedSnippets: applied)
            XCTAssertEqual(p.explanation, .identical)
            XCTAssertNil(p.message(language: .zh))
            XCTAssertNil(p.message(language: .en))
        }
    }

    /// A record without provenance must never be attributed to rules — the reviewed
    /// implementation did exactly that for polish and translation modes.
    func testMissingProvenanceIsUnknownRatherThanBlamedOnRules() {
        let p = CorrectionProvenance(rawText: "原始", postSnippetText: nil, finalText: "润色后", appliedSnippets: nil)
        XCTAssertEqual(p.explanation, .unknown)
        XCTAssertTrue(p.appliedRules.isEmpty)
    }

    func testLLMOnlyDifferenceIsNotBlamedOnRules() {
        let p = CorrectionProvenance(rawText: "原始", postSnippetText: "原始", finalText: "润色后", appliedSnippets: [])
        XCTAssertEqual(p.explanation, .laterProcessingOnly)
        XCTAssertTrue(p.appliedRules.isEmpty)
    }

    func testRulesThatFiredAreNamed() {
        let p = CorrectionProvenance(rawText: "把 Doc 发我", postSnippetText: "把 Docker 发我", finalText: "把 Docker 发我", appliedSnippets: [docRule])
        XCTAssertEqual(p.explanation, .rewrittenByRules([docRule], thenChangedFurther: false))
        XCTAssertEqual(p.appliedRules, [docRule])
    }

    func testRulesFollowedByFurtherProcessingSayBoth() {
        let p = CorrectionProvenance(rawText: "把 Doc 发我", postSnippetText: "把 Docker 发我", finalText: "请把 Docker 发给我。", appliedSnippets: [docRule])
        XCTAssertEqual(p.explanation, .rewrittenByRules([docRule], thenChangedFurther: true))
    }

    /// A cancelled LLM run falls back to the raw text, discarding the rewrite. The
    /// rules still ran and the output still differs from what they produced.
    func testRewriteLaterDiscardedStillReportsTheRulesAndTheChange() {
        let p = CorrectionProvenance(rawText: "把 Doc 发我", postSnippetText: "把 Docker 发我", finalText: "把 Doc 发我", appliedSnippets: [docRule])
        XCTAssertEqual(p.explanation, .rewrittenByRules([docRule], thenChangedFurther: true))
    }

    func testEveryExplanationHasDistinctChineseAndEnglishMessages() {
        let cases = [
            CorrectionProvenance(rawText: "a", postSnippetText: nil, finalText: "b", appliedSnippets: nil),
            CorrectionProvenance(rawText: "a", postSnippetText: "a", finalText: "b", appliedSnippets: []),
            CorrectionProvenance(rawText: "Doc", postSnippetText: "Docker", finalText: "Docker", appliedSnippets: [docRule]),
            CorrectionProvenance(rawText: "Doc", postSnippetText: "Docker", finalText: "Docker!", appliedSnippets: [docRule]),
        ]
        var zh: Set<String> = []
        var en: Set<String> = []
        for p in cases {
            let z = try? XCTUnwrap(p.message(language: .zh))
            let e = try? XCTUnwrap(p.message(language: .en))
            XCTAssertNotNil(z, "missing Chinese message for \(p.explanation)")
            XCTAssertNotNil(e, "missing English message for \(p.explanation)")
            XCTAssertNotEqual(z, e)
            if let z { zh.insert(z) }
            if let e { en.insert(e) }
        }
        XCTAssertEqual(zh.count, cases.count, "each explanation needs its own wording")
        XCTAssertEqual(en.count, cases.count, "each explanation needs its own wording")
    }

    func testScopeLabels() {
        XCTAssertEqual(CorrectionProvenance.scopeLabel(bundleId: nil, appName: nil, language: .zh), "全局")
        XCTAssertEqual(CorrectionProvenance.scopeLabel(bundleId: nil, appName: nil, language: .en), "Global")
        XCTAssertEqual(CorrectionProvenance.scopeLabel(bundleId: "com.example.editor", appName: "Editor", language: .zh), "Editor")
        XCTAssertEqual(CorrectionProvenance.scopeLabel(bundleId: "com.example.editor", appName: nil, language: .en), "com.example.editor")
    }

    func testOpeningIsOfferedOnlyForARuleThatStillExistsAsRecorded() {
        XCTAssertTrue(CorrectionProvenance.ruleStillExists(docRule, in: [("Doc", "Docker")]))
        XCTAssertTrue(CorrectionProvenance.ruleStillExists(docRule, in: [("doc", "Docker")]))
        XCTAssertFalse(CorrectionProvenance.ruleStillExists(docRule, in: [("Doc", "Dockerfile")]), "edited since")
        XCTAssertFalse(CorrectionProvenance.ruleStillExists(docRule, in: []), "deleted since")
    }

    func testRevealRequestDoesNotFocusTheNewRuleForm() {
        let reveal = VocabularyNavigationRequest(
            section: .snippets, trigger: "Doc", replacement: "Docker",
            scopeBundleId: "com.example.editor", revealExisting: true
        )
        XCTAssertNil(reveal.focus)
        XCTAssertEqual(reveal.scopeBundleId, "com.example.editor")

        let draft = VocabularyNavigationRequest(section: .snippets, trigger: "Doc", replacement: "Docker")
        XCTAssertFalse(draft.revealExisting)
        guard case .snippetReplacement? = draft.focus else {
            return XCTFail("a draft request should still focus the replacement field")
        }
    }
}
