import XCTest
@testable import Type4Me

final class MagpieReasoningLevelTests: XCTestCase {

    func testLowestReasoningEffortRanking() {
        XCTAssertEqual(
            MagpieModelCatalog.findLowestReasoningEffort(in: ["low", "high", "max"]),
            "low"
        )
        XCTAssertEqual(
            MagpieModelCatalog.findLowestReasoningEffort(in: ["minimal", "low"]),
            "minimal"
        )
        XCTAssertEqual(
            MagpieModelCatalog.findLowestReasoningEffort(in: ["high", "none", "low"]),
            "none"
        )
        XCTAssertEqual(
            MagpieModelCatalog.findLowestReasoningEffort(in: ["medium", "xhigh"]),
            "medium"
        )
        XCTAssertNil(
            MagpieModelCatalog.findLowestReasoningEffort(in: [])
        )
        XCTAssertNil(
            MagpieModelCatalog.findLowestReasoningEffort(in: ["custom-unknown", "another-unknown"])
        )
    }
}
