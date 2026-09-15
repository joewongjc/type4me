import XCTest
@testable import Type4Me

/// #300 review. The rules reported for a history record must be the ones that
/// produced its text in the same pass. These drive rule application over explicit
/// lists, so they never read or write stored snippets, whose path is not isolated
/// under XCTest.
final class SnippetApplicationTests: XCTestCase {

    private func apply(
        _ text: String,
        global: [(trigger: String, value: String)] = [],
        app: [(trigger: String, value: String)] = [],
        bundleId: String? = nil
    ) -> SnippetApplication {
        SnippetStorage.apply(to: text, globalRules: global, appRules: app, bundleId: bundleId)
    }

    func testReportsTheGlobalRuleThatFired() {
        let result = apply("把 Doc 发我", global: [("Doc", "Docker")])
        XCTAssertEqual(result.text, "把 Docker 发我")
        XCTAssertEqual(result.appliedRules, [AppliedSnippetRule(trigger: "Doc", value: "Docker", bundleId: nil)])
    }

    func testReportsNothingWhenNoRuleMatches() {
        let result = apply("把文档发我", global: [("Doc", "Docker")])
        XCTAssertEqual(result.text, "把文档发我")
        XCTAssertTrue(result.appliedRules.isEmpty)
    }

    /// Triggers stop at ASCII word boundaries; a longer word containing the trigger
    /// is untouched and must not be reported.
    func testDoesNotReportARuleThatOnlyLooksLikeAMatch() {
        let result = apply("打开 Docker 面板", global: [("Doc", "Docker")])
        XCTAssertEqual(result.text, "打开 Docker 面板")
        XCTAssertTrue(result.appliedRules.isEmpty)
    }

    func testReportsRulesThatChainOffEachOtherInOrder() {
        let result = apply("重启 Doc", global: [("Doc", "Docker"), ("Docker", "容器")])
        XCTAssertEqual(result.text, "重启 容器")
        XCTAssertEqual(result.appliedRules.map(\.trigger), ["Doc", "Docker"])
    }

    /// The overridden global rule does not run, so it must not be reported either.
    func testAppRuleOverridesAConflictingGlobalRuleAndOnlyItIsReported() {
        let result = apply(
            "把 Doc 发我",
            global: [("Doc", "Docker")],
            app: [("Doc", "文档")],
            bundleId: "com.example.editor"
        )
        XCTAssertEqual(result.text, "把 文档 发我")
        XCTAssertEqual(result.appliedRules, [AppliedSnippetRule(trigger: "Doc", value: "文档", bundleId: "com.example.editor")])
    }

    func testGlobalAndAppRulesAreBothReportedWithTheirScopes() {
        let result = apply(
            "Doc 和 PR",
            global: [("Doc", "Docker")],
            app: [("PR", "Pull Request")],
            bundleId: "com.example.editor"
        )
        XCTAssertEqual(result.text, "Docker 和 Pull Request")
        XCTAssertEqual(result.appliedRules, [
            AppliedSnippetRule(trigger: "Doc", value: "Docker", bundleId: nil),
            AppliedSnippetRule(trigger: "PR", value: "Pull Request", bundleId: "com.example.editor"),
        ])
    }

    func testAppRulesAreIgnoredWithoutAScope() {
        let result = apply("PR", app: [("PR", "Pull Request")], bundleId: nil)
        XCTAssertEqual(result.text, "PR")
        XCTAssertTrue(result.appliedRules.isEmpty)
    }

    /// The refactor must not change any replacement output. This compares against
    /// the pass exactly as it was written before tracking was added.
    func testOutputMatchesThePreviousReplacementPass() {
        let cases: [(String, [(trigger: String, value: String)], [(trigger: String, value: String)], String?)] = [
            ("把 Doc 发我", [("Doc", "Docker")], [], nil),
            ("重启 Doc", [("Doc", "Docker"), ("Docker", "容器")], [], nil),
            ("把 Doc 发我", [("Doc", "Docker")], [("Doc", "文档")], "com.example.editor"),
            ("Doc 和 PR", [("Doc", "Docker")], [("PR", "Pull Request")], "com.example.editor"),
            ("my app id is here", [("app id", "app_id")], [], nil),
            ("my APP  ID is here", [("app id", "app_id")], [], nil),
            ("打开 Docker 面板", [("Doc", "Docker")], [], nil),
            ("PR", [], [("PR", "Pull Request")], ""),
        ]
        for (text, global, app, bundleId) in cases {
            XCTAssertEqual(
                apply(text, global: global, app: app, bundleId: bundleId).text,
                previousPass(text, global: global, app: app, bundleId: bundleId),
                "output changed for \(text)"
            )
        }
    }

    // MARK: - The replacement pass before this change

    private func previousPass(
        _ text: String,
        global: [(trigger: String, value: String)],
        app: [(trigger: String, value: String)],
        bundleId: String?
    ) -> String {
        func pattern(_ trigger: String) -> String {
            let chars = trigger.filter { !$0.isWhitespace }
            guard !chars.isEmpty else { return NSRegularExpression.escapedPattern(for: trigger) }
            let core = chars.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*")
            return "(?<![a-zA-Z0-9])" + core + "(?![a-zA-Z0-9])"
        }
        func compile(_ rules: [(trigger: String, value: String)]) -> [(regex: NSRegularExpression, pattern: String, template: String)] {
            rules.compactMap { rule in
                let p = pattern(rule.trigger)
                guard let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return nil }
                return (regex, p, NSRegularExpression.escapedTemplate(for: rule.value))
            }
        }
        func run(_ rules: [(regex: NSRegularExpression, pattern: String, template: String)], on input: String, skipping: Set<String> = []) -> String {
            var result = input
            for rule in rules where !skipping.contains(rule.pattern) {
                result = rule.regex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.template
                )
            }
            return result
        }
        let globalRules = compile(global)
        guard let bundleId, !bundleId.isEmpty else { return run(globalRules, on: text) }
        let appRules = compile(app)
        guard !appRules.isEmpty else { return run(globalRules, on: text) }
        let afterGlobal = run(globalRules, on: text, skipping: Set(appRules.map(\.pattern)))
        return run(appRules, on: afterGlobal)
    }
}
