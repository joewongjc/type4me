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

    func testHallucinationFiltering_withAudioEvidence() {
        // 1. Unconditional subtitle/scraper artifacts are always filtered
        XCTAssertTrue(GroqHallucinationPhrases.isHallucination(
            text: "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目。",
            responseRoot: [:]
        ))
        XCTAssertTrue(GroqHallucinationPhrases.isHallucination(
            text: "字幕由amara.org社区提供",
            responseRoot: [:]
        ))

        // 2. Common phrase with hallucination audio evidence (30s window end anomaly)
        let hallucinationRoot: [String: Any] = [
            "duration": 2.0,
            "segments": [
                ["start": 0.0, "end": 29.98, "no_speech_prob": 0.0, "avg_logprob": -0.2]
            ]
        ]
        XCTAssertTrue(GroqHallucinationPhrases.isHallucination(
            text: "Thank you.",
            responseRoot: hallucinationRoot
        ))
        XCTAssertTrue(GroqHallucinationPhrases.isHallucination(
            text: "谢谢观看",
            responseRoot: hallucinationRoot
        ))

        // 3. Common phrase with REAL speech audio evidence (segment end conforms to duration)
        let realSpeechRoot: [String: Any] = [
            "duration": 1.2,
            "segments": [
                ["start": 0.0, "end": 0.8, "no_speech_prob": 0.0, "avg_logprob": -0.2]
            ]
        ]
        XCTAssertFalse(GroqHallucinationPhrases.isHallucination(
            text: "Thank you.",
            responseRoot: realSpeechRoot
        ))
        XCTAssertFalse(GroqHallucinationPhrases.isHallucination(
            text: "谢谢观看",
            responseRoot: realSpeechRoot
        ))
    }

    func testGroqBatchTranscriberPreservesRealSpeechThankYou() throws {
        let transcriber = GroqBatchTranscriber()
        let config = try XCTUnwrap(GroqASRConfig(credentials: ["apiKey": "gsk_test"]))

        let json = """
        {
            "text": "Thank you.",
            "language": "English",
            "duration": 1.0,
            "segments": [{
                "start": 0.0,
                "end": 0.6,
                "no_speech_prob": 0.0,
                "avg_logprob": -0.2
            }]
        }
        """
        let result = try transcriber.parseTranscript(
            from: Data(json.utf8),
            config: config,
            options: ASRRequestOptions()
        )
        XCTAssertEqual(result, "Thank you.")
    }

    func testGroqBatchTranscriberPreservesSpokenPhrasesWithHotwords() throws {
        let transcriber = GroqBatchTranscriber()
        let config = try XCTUnwrap(GroqASRConfig(credentials: ["apiKey": "gsk_test"]))

        let json1 = """
        {
            "text": "Use Type4Me",
            "language": "English",
            "duration": 2.0,
            "segments": [{ "start": 0.0, "end": 1.5 }]
        }
        """
        let res1 = try transcriber.parseTranscript(
            from: Data(json1.utf8),
            config: config,
            options: ASRRequestOptions(hotwords: ["Type4Me"])
        )
        XCTAssertEqual(res1, "Use Type4Me")

        let json2 = """
        {
            "text": "OpenAI API",
            "language": "English",
            "duration": 2.0,
            "segments": [{ "start": 0.0, "end": 1.5 }]
        }
        """
        let res2 = try transcriber.parseTranscript(
            from: Data(json2.utf8),
            config: config,
            options: ASRRequestOptions(hotwords: ["OpenAI"])
        )
        XCTAssertEqual(res2, "OpenAI API")
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
            "language": "Chinese",
            "duration": 3.0,
            "segments": [{ "start": 0.0, "end": 2.5 }]
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

        // Hallucinated segment (end 29.98 exceeds audio duration 2.0)
        let json = """
        {
            "text": "Thank you for watching.",
            "language": "English",
            "duration": 2.0,
            "segments": [{
                "start": 0.0,
                "end": 29.98,
                "no_speech_prob": 0.0
            }]
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
