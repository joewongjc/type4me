import XCTest
@testable import Type4Me

/// #300: a replacement is invisible once applied — the history list shows the
/// rewritten output, which looks exactly like a misrecognition. Naming the rule
/// responsible is what makes it diagnosable and reversible.
final class SnippetRulesAppliedTests: XCTestCase {

    func testNamesTheRuleThatRewroteTheText() {
        let applied = SnippetStorage.rulesApplied(to: "把 Doc 发我", in: [(trigger: "Doc", value: "Docker")])

        XCTAssertEqual(applied.map(\.trigger), ["Doc"])
        XCTAssertEqual(applied.map(\.value), ["Docker"])
    }

    func testReportsNothingWhenNoRuleMatches() {
        XCTAssertTrue(
            SnippetStorage.rulesApplied(to: "把文档发我", in: [(trigger: "Doc", value: "Docker")]).isEmpty
        )
    }

    /// The trigger's boundaries are ASCII-aware, so a longer word containing it
    /// is left alone. Reporting it would send the user to an innocent rule.
    func testDoesNotReportARuleThatOnlyLooksLikeAMatch() {
        XCTAssertTrue(
            SnippetStorage.rulesApplied(to: "打开 Docker 面板", in: [(trigger: "Doc", value: "Docker")]).isEmpty
        )
    }

    /// Rules run in sequence, so one can fire on text an earlier rule produced.
    /// Both belong in the explanation.
    func testReportsRulesThatChainOffEachOther() {
        let chained = [
            (trigger: "Doc", value: "Docker"),
            (trigger: "Docker", value: "容器"),
        ]

        let applied = SnippetStorage.rulesApplied(to: "重启 Doc", in: chained)

        XCTAssertEqual(applied.map(\.trigger), ["Doc", "Docker"])
    }

    /// What the sheet relies on: the reported rules explain the whole gap
    /// between the recogniser's output and what was delivered.
    func testReportedRulesAccountForTheDeliveredOutput() {
        let rules = [(trigger: "Doc", value: "Docker")]
        let raw = "把 Doc 发我"

        // Every reported rule is one that actually fired, so the list explains
        // the whole gap between recognition and delivery.
        XCTAssertEqual(
            SnippetStorage.rulesApplied(to: raw, in: rules).map(\.value),
            ["Docker"]
        )
    }
}
