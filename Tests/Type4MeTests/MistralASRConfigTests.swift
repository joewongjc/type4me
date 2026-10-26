import XCTest
@testable import Type4Me

final class MistralASRConfigTests: XCTestCase {

    func testConfigTrimsAPIKey() throws {
        let config = try XCTUnwrap(MistralASRConfig(credentials: ["apiKey": " mistral_key "]))
        XCTAssertEqual(config.apiKey, "mistral_key")
        XCTAssertEqual(config.model, .miniTranscribe2)
        XCTAssertEqual(config.language, "")
        XCTAssertTrue(config.isValid)
    }

    func testConfigRejectsEmptyAPIKey() {
        XCTAssertNil(MistralASRConfig(credentials: ["apiKey": "   "]))
        XCTAssertNil(MistralASRConfig(credentials: [:]))
    }

    func testConfigFallsBackOnInvalidModel() throws {
        let config = try XCTUnwrap(MistralASRConfig(credentials: [
            "apiKey": "key",
            "model": "retired-model-2024",
            "language": "zh",
        ]))
        XCTAssertEqual(config.model, .miniTranscribe2)
        XCTAssertEqual(config.language, "zh")
    }

    func testConfigParsesSmallModel() throws {
        let config = try XCTUnwrap(MistralASRConfig(credentials: [
            "apiKey": "key",
            "model": "voxtral-small-2507",
        ]))
        XCTAssertEqual(config.model, .small)
        XCTAssertEqual(config.model.endpoint, .chatCompletions)
        XCTAssertEqual(config.model.maxDuration, 15 * 60)
    }

    func testSupportedLanguagesValidation() throws {
        let validConfig = try XCTUnwrap(MistralASRConfig(credentials: [
            "apiKey": "key",
            "language": "fr",
        ]))
        XCTAssertEqual(validConfig.language, "fr")

        let invalidConfig = try XCTUnwrap(MistralASRConfig(credentials: [
            "apiKey": "key",
            "language": "unsupported-lang",
        ]))
        XCTAssertEqual(invalidConfig.language, "")
    }

    func testContextBiasSplitsAndSanitizes() {
        let hotwords = [
            "Type4Me, Claude Code",
            "Voxtral-Mini",
            "  Apple, , Orange  ",
            "Claude Code", // duplicate
        ]
        let bias = MistralBatchTranscriber.contextBias(from: hotwords)
        XCTAssertEqual(bias, ["Type4Me", "Claude", "Code", "Voxtral-Mini", "Apple", "Orange"])

        for term in bias {
            XCTAssertFalse(term.contains(" "))
            XCTAssertFalse(term.contains(","))
        }
    }

    func testTranscriptionInstructionIncludesDirectivesAndHotwords() {
        let instruction = MistralBatchTranscriber.transcriptionInstruction(
            language: "zh",
            hotwords: ["Type4Me", "Claude Code"],
            appLanguage: .zh
        )

        XCTAssertTrue(instruction.contains("Transcribe the speech in the audio verbatim."))
        XCTAssertTrue(instruction.contains("<<NO_SPEECH>>"))
        XCTAssertTrue(instruction.contains("The audio is in Chinese."))
        XCTAssertTrue(instruction.contains("Simplified Chinese"))
        XCTAssertTrue(instruction.contains("Type4Me, Claude Code"))
    }
}
