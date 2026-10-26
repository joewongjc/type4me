import XCTest
@testable import Type4Me

final class GeminiLocalizationTests: XCTestCase {

    private var previousLanguage: String?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.string(forKey: "tf_language")
    }

    override func tearDown() {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: "tf_language")
        } else {
            UserDefaults.standard.removeObject(forKey: "tf_language")
        }
        super.tearDown()
    }

    func testProviderDisplayName_isConsistentAcrossLanguages() {
        // The provider is "Gemini"; the model is selected separately underneath
        // it, so the provider name must not carry a model version.
        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(ASRProvider.gemini.displayName, "Gemini")

        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(ASRProvider.gemini.displayName, "Gemini")
    }

    func testModelFieldLabelLocalization_switchesDynamically() {
        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(GeminiASRConfig.credentialFields.first { $0.key == "model" }?.label, "模型")

        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(GeminiASRConfig.credentialFields.first { $0.key == "model" }?.label, "Model")
    }

    func testCredentialFieldsLocalization_switchesDynamically() {
        // 1. Chinese
        UserDefaults.standard.set("zh", forKey: "tf_language")
        let zhFields = GeminiASRConfig.credentialFields

        let zhModeField = zhFields.first { $0.key == "mode" }
        XCTAssertEqual(zhModeField?.label, "转写模式")
        XCTAssertEqual(zhModeField?.options.first { $0.value == "SMART" }?.label, "智能整理")
        XCTAssertEqual(zhModeField?.options.first { $0.value == "VERBATIM" }?.label, "逐字转写")

        let zhLangField = zhFields.first { $0.key == "languageCode" }
        XCTAssertEqual(zhLangField?.label, "语言提示")
        XCTAssertEqual(zhLangField?.options.first { $0.value == "auto" }?.label, "自动检测")
        XCTAssertEqual(zhLangField?.options.first { $0.value == "cmn-Hans-CN" }?.label, "中文（普通话）")
        XCTAssertEqual(zhLangField?.options.first { $0.value == "yue-Hant-HK" }?.label, "粤语")

        // 2. English
        UserDefaults.standard.set("en", forKey: "tf_language")
        let enFields = GeminiASRConfig.credentialFields

        let enModeField = enFields.first { $0.key == "mode" }
        XCTAssertEqual(enModeField?.label, "Transcription Mode")
        XCTAssertEqual(enModeField?.options.first { $0.value == "SMART" }?.label, "Smart")
        XCTAssertEqual(enModeField?.options.first { $0.value == "VERBATIM" }?.label, "Verbatim")

        let enLangField = enFields.first { $0.key == "languageCode" }
        XCTAssertEqual(enLangField?.label, "Language Hint")
        XCTAssertEqual(enLangField?.options.first { $0.value == "auto" }?.label, "Auto Detect")
        XCTAssertEqual(enLangField?.options.first { $0.value == "cmn-Hans-CN" }?.label, "Mandarin Chinese")
        XCTAssertEqual(enLangField?.options.first { $0.value == "yue-Hant-HK" }?.label, "Cantonese")
    }

    func testConfigSemanticValues_remainIntactAcrossLanguageSwitches() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: [
            "apiKey": "test-key",
            "mode": "SMART",
            "languageCode": "cmn-Hans-CN"
        ]))

        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(config.mode.rawValue, "SMART")
        XCTAssertEqual(config.languageCode, "cmn-Hans-CN")

        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(config.mode.rawValue, "SMART")
        XCTAssertEqual(config.languageCode, "cmn-Hans-CN")
    }

    func testErrorDescriptions_haveBothLanguages() {
        let errors: [GeminiASRError] = [
            .unsupportedProvider,
            .invalidConfig,
            .invalidEndpoint,
            .handshakeTimedOut,
            .setupTimedOut,
            .setupRejected("Invalid model"),
            .emptyAudio,
            .closedBeforeSetup(code: 1006, reason: "Reset"),
            .closed(code: 1000, reason: "Normal"),
            .quotaExceeded("Rate limit"),
            .sessionLimitReached,
            .invalidResponse,
            .serverError(code: 500, message: "Internal error")
        ]

        UserDefaults.standard.set("zh", forKey: "tf_language")
        for err in errors {
            XCTAssertFalse(err.localizedDescription.isEmpty, "ZH description should not be empty for \(err)")
        }

        UserDefaults.standard.set("en", forKey: "tf_language")
        for err in errors {
            XCTAssertFalse(err.localizedDescription.isEmpty, "EN description should not be empty for \(err)")
        }
    }
}
