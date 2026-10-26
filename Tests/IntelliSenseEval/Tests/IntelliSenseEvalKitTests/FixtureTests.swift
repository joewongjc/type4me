import XCTest
import Type4MeIntelliSenseCore
@testable import IntelliSenseEvalKit

final class FixtureTests: XCTestCase {
    func testFixtureContractAndCounts() throws {
        let cases = try FixtureLoader.loadAll()
        XCTAssertEqual(cases.count, 126)
        XCTAssertEqual(cases.filter(\.smoke).count, 28)
        XCTAssertEqual(cases.filter(\.critical).count, 16)
    }

    func testEveryFixtureUsesProductionPromptAndLeavesNoPlaceholder() throws {
        for item in try FixtureLoader.loadAll() {
            let prompt = IntelliSensePromptBuilder.build(request: item.makeRequest())
            XCTAssertFalse(prompt.contains("{text}"), item.id)
            XCTAssertTrue(prompt.contains("<user_dictation>"), item.id)
            XCTAssertTrue(prompt.contains("</user_dictation>"), item.id)
        }
    }

    func testSmokeCoversEveryEvaluationDimension() throws {
        let smoke = try FixtureLoader.loadAll().filter(\.smoke)
        let suites = Set(smoke.map(\.suite))
        XCTAssertEqual(suites, Set(FixtureLoader.expectedSuiteCounts.keys))
    }

    func testListStructureAnalyzerRecognizesCommonChineseAndMarkdownMarkers() {
        XCTAssertEqual(EvaluationListStructure.itemCount(in: "说明：\n1. 第一项\n2、第二项\n• 第三项"), 3)
        XCTAssertEqual(EvaluationListStructure.itemCount(in: "问题包括：\n一、第一项\n二）第二项"), 2)
        XCTAssertEqual(EvaluationListStructure.itemCount(in: "一个是今天发，另一个是明天发。"), 0)
    }
}
