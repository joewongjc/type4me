import XCTest
@testable import Type4Me

final class Qwen3HotwordLeakSanitizerTests: XCTestCase {
    func testStripsSingleChineseHotwordLeakWhenPreviewMatchesTail() {
        let text = ASRHotwordLeakSanitizer.sanitize(
            "一二三四三字",
            hotwords: ["一二三四"],
            fallbackText: "三字"
        )

        XCTAssertEqual(text, "三字")
    }

    func testKeepsFullHotwordUtterance() {
        let text = ASRHotwordLeakSanitizer.sanitize(
            "一二三四",
            hotwords: ["一二三四"],
            fallbackText: "一二三四"
        )

        XCTAssertEqual(text, "一二三四")
    }

    func testStripsPureHotwordDumpWithoutContextLabel() {
        let text = ASRHotwordLeakSanitizer.sanitize(
            "Type4Me Qwen Deepgram",
            hotwords: ["Type4Me", "Qwen", "Deepgram"]
        )

        XCTAssertEqual(text, "")
    }

    func testStripsPureLabeledHotwordDump() {
        let text = ASRHotwordLeakSanitizer.sanitize(
            "Vocabulary: Type4Me, Qwen, Deepgram",
            hotwords: ["Type4Me", "Qwen", "Deepgram"]
        )

        XCTAssertEqual(text, "")
    }

    func testUsesFallbackForPureHotwordDump() {
        let text = ASRHotwordLeakSanitizer.sanitize(
            "Type4Me Qwen",
            hotwords: ["Type4Me", "Qwen"],
            fallbackText: "真实内容"
        )

        XCTAssertEqual(text, "真实内容")
    }

    func testKeepsSingleHotwordUtteranceWithoutFallback() {
        let text = ASRHotwordLeakSanitizer.sanitize(
            "Qwen",
            hotwords: ["Qwen"]
        )

        XCTAssertEqual(text, "Qwen")
    }

    func testKeepsHotwordCorrectionWhenPreviewAlreadyStartsWithHotword() {
        let text = ASRHotwordLeakSanitizer.sanitize(
            "张三今天开会",
            hotwords: ["张三"],
            fallbackText: "张三今天开会"
        )

        XCTAssertEqual(text, "张三今天开会")
    }

    func testStripsLabeledHotwordDumpWithoutFallback() {
        let text = ASRHotwordLeakSanitizer.sanitize(
            "Vocabulary: OpenAI, Qwen, hello world",
            hotwords: ["OpenAI", "Qwen"]
        )

        XCTAssertEqual(text, "hello world")
    }

    func testFallsBackWhenDumpTailDoesNotMatchPreview() {
        let text = ASRHotwordLeakSanitizer.sanitize(
            "Claude, OpenAI, unrelated",
            hotwords: ["Claude", "OpenAI"],
            fallbackText: "真实内容"
        )

        XCTAssertEqual(text, "真实内容")
    }

    func testKeepsSingleHotwordPrefixWithoutFallback() {
        let text = ASRHotwordLeakSanitizer.sanitize(
            "一二三四三字",
            hotwords: ["一二三四"]
        )

        XCTAssertEqual(text, "一二三四三字")
    }
}
