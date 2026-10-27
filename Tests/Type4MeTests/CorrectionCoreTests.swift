import XCTest
@testable import Type4MeCorrectionCore

final class CorrectionCoreTests: XCTestCase {
    func testFindsOccurrencesOnBothSidesInReadingOrder() {
        let found = CorrectionOccurrences.find(before: "跟 AA 和 AA 的", after: "，AA 制", matching: "AA")
        XCTAssertEqual(found.map(\.number), [1, 2, 3])
        // "跟 AA 和 AA 的" is 11 characters; matches start at 2 and 7.
        XCTAssertEqual(found.map(\.offset), [-9, -4, 3])
    }

    func testCountsCharactersNotUTF16() {
        let found = CorrectionOccurrences.find(before: "👍🏽AA", after: "🎉AA", matching: "AA")
        XCTAssertEqual(found.map(\.offset), [-2, 3])
    }

    func testNoContextFindsNothing() {
        XCTAssertTrue(CorrectionOccurrences.find(before: "", after: "", matching: "AA").isEmpty)
        XCTAssertTrue(CorrectionOccurrences.find(before: "AA", after: "AA", matching: "").isEmpty)
    }

    func testMarksSelectionAndOtherOccurrences() {
        let input = CorrectionPrompt.Input(before: "跟 AA 的人还有 ", selected: "AA", after: " 开会，AA 制", spoken: "欸欸", attempts: [])
        XCTAssertEqual(
            CorrectionPrompt.markedText(input),
            "跟 ⟦1⟧AA⟦/1⟧ 的人还有 ⟦*⟧AA⟦/*⟧ 开会，⟦2⟧AA⟦/2⟧ 制"
        )
    }

    func testPromptCarriesSpeechAndRejectedSpellings() {
        let input = CorrectionPrompt.Input(before: "", selected: "AA", after: "", spoken: "AA，叹气那个", attempts: ["AA", "诶诶"])
        for chinese in [true, false] {
            let prompt = CorrectionPrompt.build(input, chinese: chinese)
            XCTAssertTrue(prompt.user.contains("⟦*⟧AA⟦/*⟧"))
            XCTAssertTrue(prompt.user.contains("AA，叹气那个"))
            XCTAssertTrue(prompt.user.contains("「诶诶」"))
            XCTAssertTrue(prompt.system.contains("\"also\""))
        }
    }

    func testResolvesReplacementAndValidNumbers() {
        let raw = "```json\n{\"replacement\": \" 欸欸 \", \"also\": [2, 1, 2, 7, 0]}\n```"
        XCTAssertEqual(
            CorrectionResponse.resolve(raw, selected: "AA", attempts: [], occurrenceCount: 2),
            .replace("欸欸", also: [1, 2])
        )
    }

    func testUnclearReplies() {
        let cases = [
            "not json",
            "{\"replacement\": null}",
            "{\"replacement\": \"\"}",
            "{\"replacement\": \"AA\"}",
            "{\"replacement\": \"诶诶\"}",
        ]
        for raw in cases {
            XCTAssertEqual(
                CorrectionResponse.resolve(raw, selected: "AA", attempts: ["诶诶"], occurrenceCount: 0),
                .unclear,
                raw
            )
        }
    }

    func testMissingAlsoMeansOnlyTheSelection() {
        XCTAssertEqual(
            CorrectionResponse.resolve("{\"replacement\": \"API\"}", selected: "AP 爱", attempts: [], occurrenceCount: 3),
            .replace("API", also: [])
        )
    }
}
