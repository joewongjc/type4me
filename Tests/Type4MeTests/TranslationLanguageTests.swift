import XCTest
@testable import Type4Me

final class TranslationLanguageTests: XCTestCase {
    func testSupportedLanguagesHaveUniqueStableCodesAndExpectedOrder() {
        let codes = TranslationLanguage.allCases.map(\.rawValue)
        XCTAssertEqual(codes.count, 18)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertEqual(codes, [
            "en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "pt-BR",
            "it", "ru", "ar", "hi", "th", "vi", "id", "tr", "nl",
        ])
    }

    func testCodableRoundTrip() throws {
        for language in TranslationLanguage.allCases {
            let data = try JSONEncoder().encode(language)
            XCTAssertEqual(try JSONDecoder().decode(TranslationLanguage.self, from: data), language)
        }
    }

    func testPromptNamesAreStableEnglishNames() {
        XCTAssertEqual(TranslationLanguage.english.promptName, "English")
        XCTAssertEqual(TranslationLanguage.simplifiedChinese.promptName, "Simplified Chinese")
        XCTAssertEqual(TranslationLanguage.brazilianPortuguese.promptName, "Brazilian Portuguese")
    }

    func testChineseVariantsHaveDistinctDetectionIdentifiers() {
        XCTAssertTrue(TranslationLanguage.simplifiedChinese.naturalLanguageIdentifiers.contains("zh-Hans"))
        XCTAssertTrue(TranslationLanguage.traditionalChinese.naturalLanguageIdentifiers.contains("zh-Hant"))
    }
}
