import XCTest
@testable import Type4Me

final class AssemblyAIASRConfigTests: XCTestCase {

    func testInit_usesDefaultModelWhenMissing() throws {
        let config = try XCTUnwrap(AssemblyAIASRConfig(credentials: [
            "apiKey": "aa_test_key",
        ]))

        XCTAssertEqual(config.model, AssemblyAIASRConfig.defaultModel)
        XCTAssertEqual(config.model, "universal-3-6-pro")
        XCTAssertTrue(config.isValid)
    }

    func testSupportedModelsExposeUniversal36ProFirst() {
        XCTAssertEqual(AssemblyAIASRConfig.supportedModels.first, "universal-3-6-pro")
        XCTAssertTrue(AssemblyAIASRConfig.supportedModels.contains("u3-rt-pro"))
        XCTAssertTrue(AssemblyAIASRConfig.supportedModels.contains("universal-streaming-multilingual"))
    }

    func testInit_rejectsMissingAPIKey() {
        XCTAssertNil(AssemblyAIASRConfig(credentials: [:]))
        XCTAssertNil(AssemblyAIASRConfig(credentials: ["apiKey": "   "]))
    }

    func testInit_fallsBackToDefaultModelForUnsupportedValue() throws {
        let config = try XCTUnwrap(AssemblyAIASRConfig(credentials: [
            "apiKey": "aa_test_key",
            "model": "whisper-rt",
        ]))

        XCTAssertEqual(config.model, AssemblyAIASRConfig.defaultModel)
    }

    func testToCredentials_roundTrips() throws {
        let config = try XCTUnwrap(AssemblyAIASRConfig(credentials: [
            "apiKey": "aa_test_key",
            "model": "universal-3-5-pro",
        ]))

        XCTAssertEqual(
            config.toCredentials(),
            [
                "apiKey": "aa_test_key",
                "model": "universal-3-5-pro",
            ]
        )
    }
}
