import XCTest
@testable import Type4Me

final class InjectedTextResolverTests: XCTestCase {
    func testExactResolutionTracksEditInsideInjection() throws {
        let baseline = "prefix ghosty suffix"
        let result = InjectedTextResolver.resolve(
            baseline: baseline,
            injectedRange: try range(of: "ghosty", in: baseline),
            current: "prefix Ghostty suffix"
        )

        XCTAssertEqual(result.confidence, .exact)
        XCTAssertEqual(result.text, "Ghostty")
        XCTAssertTrue(result.changedInsideInjection)
        XCTAssertFalse(result.changedOutsideInjection)
    }

    func testAnchoredResolutionAllowsIndependentOutsideEdit() throws {
        let baseline = "prefix ghosty suffix"
        let result = InjectedTextResolver.resolve(
            baseline: baseline,
            injectedRange: try range(of: "ghosty", in: baseline),
            current: "new prefix Ghostty suffix"
        )

        XCTAssertEqual(result.confidence, .anchored)
        XCTAssertEqual(result.text, "Ghostty")
        XCTAssertTrue(result.changedInsideInjection)
        XCTAssertTrue(result.changedOutsideInjection)
    }

    func testCrossBoundaryEditIsAmbiguousAndNeverReturnsFullValue() throws {
        let baseline = "prefix ghosty suffix"
        let result = InjectedTextResolver.resolve(
            baseline: baseline,
            injectedRange: try range(of: "ghosty", in: baseline),
            current: "prefixGhostty suffix"
        )

        XCTAssertEqual(result.confidence, .ambiguous)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.failure, .boundaryConflict)
    }

    func testZeroBudgetStillAllowsExactButRejectsAnchoredPath() throws {
        let baseline = "prefix ghosty suffix"
        let range = try range(of: "ghosty", in: baseline)
        let exact = InjectedTextResolver.resolve(
            baseline: baseline,
            injectedRange: range,
            current: "prefix Ghostty suffix",
            budget: .zero
        )
        let anchored = InjectedTextResolver.resolve(
            baseline: baseline,
            injectedRange: range,
            current: "new prefix Ghostty suffix",
            budget: .zero
        )

        XCTAssertEqual(exact.confidence, .exact)
        XCTAssertEqual(anchored.confidence, .ambiguous)
        XCTAssertEqual(anchored.failure, .budgetExceeded)
        XCTAssertNil(anchored.text)
    }

    func testUTF16RangeSupportsEmojiAndComposedCharacters() throws {
        let baseline = "🙂 café ghosty 结束"
        let result = InjectedTextResolver.resolve(
            baseline: baseline,
            injectedRange: try range(of: "café ghosty", in: baseline),
            current: "🙂 café Ghostty 结束"
        )

        XCTAssertEqual(result.confidence, .exact)
        XCTAssertEqual(result.text, "café Ghostty")
    }

    private func range(of substring: String, in text: String) throws -> NSRange {
        guard let range = text.range(of: substring) else {
            throw NSError(domain: "InjectedTextResolverTests", code: 1)
        }
        return NSRange(range, in: text)
    }
}
