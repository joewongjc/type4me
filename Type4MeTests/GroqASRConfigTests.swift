import XCTest
@testable import Type4Me

final class GroqASRConfigTests: XCTestCase {

    func testConfigTrimsAPIKey() throws {
        let config = try XCTUnwrap(GroqASRConfig(credentials: ["apiKey": " gsk_test "]))
        XCTAssertEqual(config.apiKey, "gsk_test")
        XCTAssertEqual(config.model, .largeV3Turbo)
        XCTAssertEqual(config.language, "")
        XCTAssertTrue(config.isValid)
    }

    func testConfigRejectsEmptyAPIKey() {
        XCTAssertNil(GroqASRConfig(credentials: ["apiKey": "   "]))
        XCTAssertNil(GroqASRConfig(credentials: [:]))
    }

    func testConfigFallsBackOnInvalidModel() throws {
        let config = try XCTUnwrap(GroqASRConfig(credentials: [
            "apiKey": "gsk_test",
            "model": "non-existent-model",
            "language": "zh",
        ]))
        XCTAssertEqual(config.model, .largeV3Turbo)
        XCTAssertEqual(config.language, "zh")
    }

    func testConfigParsesLargeV3Model() throws {
        let config = try XCTUnwrap(GroqASRConfig(credentials: [
            "apiKey": "gsk_test",
            "model": "whisper-large-v3",
        ]))
        XCTAssertEqual(config.model, .largeV3)
    }

    func testPromptByteBudgetTruncation() {
        // Build hotwords that exceed 880 bytes
        var hotwords: [String] = []
        for i in 0..<100 {
            hotwords.append("测试专有名词词汇\(i)")
        }

        let prompt = GroqBatchTranscriber.prompt(hotwords: hotwords)
        XCTAssertLessThanOrEqual(prompt.utf8.count, GroqBatchTranscriber.promptByteBudget)
        XCTAssertTrue(prompt.contains("测试专有名词词汇0"))
    }

    func testHallucinationFiltering() {
        XCTAssertTrue(GroqHallucinationPhrases.isHallucination("Thank you."))
        XCTAssertTrue(GroqHallucinationPhrases.isHallucination("  Thank you for watching!  "))
        XCTAssertTrue(GroqHallucinationPhrases.isHallucination("谢谢观看"))
        XCTAssertTrue(GroqHallucinationPhrases.isHallucination("请不吝点赞 订阅 转发 打赏支持明镜与点点栏目。"))
        XCTAssertFalse(GroqHallucinationPhrases.isHallucination("谢谢你的帮助，我们明天见"))
    }

    func testGroqBatchTranscriberParsingAndHantHans() throws {
        let transcriber = GroqBatchTranscriber()
        let config = try XCTUnwrap(GroqASRConfig(credentials: [
            "apiKey": "gsk_test",
            "language": "zh",
        ]))

        // Traditional Chinese text should be converted to Simplified
        let json = """
        {
            "text": "這個Feature的PR已經Merge了",
            "language": "Chinese"
        }
        """
        let result = try transcriber.parseTranscript(
            from: Data(json.utf8),
            config: config,
            options: ASRRequestOptions()
        )
        XCTAssertEqual(result, "这个Feature的PR已经Merge了")
    }

    func testGroqBatchTranscriberFiltersHallucinations() throws {
        let transcriber = GroqBatchTranscriber()
        let config = try XCTUnwrap(GroqASRConfig(credentials: ["apiKey": "gsk_test"]))

        let json = """
        {
            "text": "Thank you for watching.",
            "language": "English"
        }
        """
        let result = try transcriber.parseTranscript(
            from: Data(json.utf8),
            config: config,
            options: ASRRequestOptions()
        )
        XCTAssertEqual(result, "")
    }
}
