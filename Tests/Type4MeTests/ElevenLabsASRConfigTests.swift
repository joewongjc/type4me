import XCTest
@testable import Type4Me

final class ElevenLabsASRConfigTests: XCTestCase {

    func testInit_acceptsAPIKeyAndDefaultsModelAndLanguage() throws {
        let config = try XCTUnwrap(ElevenLabsASRConfig(credentials: [
            "apiKey": "eleven_test_key",
        ]))

        XCTAssertEqual(config.apiKey, "eleven_test_key")
        XCTAssertEqual(config.model, ElevenLabsASRConfig.defaultModel)
        XCTAssertEqual(config.model, "scribe_v2_realtime")
        XCTAssertEqual(config.language, "")
        XCTAssertTrue(config.isValid)
    }

    func testCredentialFieldsExposeRealtimeModelPicker() throws {
        let modelField = try XCTUnwrap(ElevenLabsASRConfig.credentialFields.first { $0.key == "model" })

        XCTAssertEqual(modelField.defaultValue, "scribe_v2_realtime")
        XCTAssertEqual(modelField.options.map(\.value), ["scribe_v2_realtime"])
    }
}
