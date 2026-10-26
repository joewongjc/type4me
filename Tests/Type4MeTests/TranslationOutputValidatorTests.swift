import XCTest
@testable import Type4Me

private struct FixedTranslationLanguageDetector: TranslationLanguageDetecting {
    let values: [String: Double]
    func hypotheses(for text: String) -> [String: Double] { values }
}

final class TranslationOutputValidatorTests: XCTestCase {
    func testAcceptsTargetLanguage() {
        let validator = TranslationOutputValidator(
            detector: FixedTranslationLanguageDetector(values: ["ja": 0.94, "en": 0.02])
        )
        XCTAssertEqual(
            validator.validate("これは十分な長さを持つ自然な日本語の翻訳結果です。", target: .japanese),
            .accept
        )
    }

    func testDetectorReportsWrongLanguageAsWarningForActionPolicy() {
        let validator = TranslationOutputValidator(
            detector: FixedTranslationLanguageDetector(values: ["en": 0.97, "ja": 0.01]),
            unexpectedLanguagePolicy: .warn
        )
        XCTAssertEqual(
            validator.validate("This is clearly a long English output from the model.", target: .japanese),
            .acceptWithWarning(.unexpectedLanguage(detected: "en", confidence: 0.97))
        )
    }

    func testStrictPolicyCanRejectAfterThresholdsAreTuned() {
        let validator = TranslationOutputValidator(
            detector: FixedTranslationLanguageDetector(values: ["en": 0.97, "ja": 0.01]),
            unexpectedLanguagePolicy: .reject
        )
        XCTAssertEqual(
            validator.validate("This is clearly a long English output from the model.", target: .japanese),
            .reject(.unexpectedLanguage(detected: "en", confidence: 0.97))
        )
    }

    func testConfidentWrongLanguageRetriesOnceThenRejects() {
        let mismatch = TranslationValidationDecision.acceptWithWarning(
            .unexpectedLanguage(detected: "zh-Hans", confidence: 0.999997854)
        )

        XCTAssertEqual(
            TranslationValidationPolicy.action(for: mismatch, attempt: .initial),
            .retry
        )
        XCTAssertEqual(
            TranslationValidationPolicy.action(for: mismatch, attempt: .retry),
            .reject(.unexpectedLanguage(
                detected: "zh-Hans",
                confidence: 0.999997854
            ))
        )
    }

    func testStrictDetectorMismatchStillUsesSingleRetryPolicy() {
        let mismatch = TranslationValidationDecision.reject(
            .unexpectedLanguage(detected: "en", confidence: 0.97)
        )

        XCTAssertEqual(
            TranslationValidationPolicy.action(for: mismatch, attempt: .initial),
            .retry
        )
        XCTAssertEqual(
            TranslationValidationPolicy.action(for: mismatch, attempt: .retry),
            .reject(.unexpectedLanguage(detected: "en", confidence: 0.97))
        )
    }

    func testUncertainWarningsRemainAcceptedWithoutRetry() {
        XCTAssertEqual(
            TranslationValidationPolicy.action(
                for: .acceptWithWarning(.insufficientNaturalLanguage),
                attempt: .initial
            ),
            .accept
        )
        XCTAssertEqual(
            TranslationValidationPolicy.action(
                for: .acceptWithWarning(.lowConfidence),
                attempt: .retry
            ),
            .accept
        )
    }

    func testStructuralFailuresNeverRetry() {
        XCTAssertEqual(
            TranslationValidationPolicy.action(
                for: .reject(.emptyOutput),
                attempt: .initial
            ),
            .reject(.emptyOutput)
        )
        XCTAssertEqual(
            TranslationValidationPolicy.action(
                for: .reject(.unsafeStructure),
                attempt: .initial
            ),
            .reject(.unsafeStructure)
        )
    }

    func testShortAndUncertainTextIsAcceptedWithWarning() {
        let validator = TranslationOutputValidator(
            detector: FixedTranslationLanguageDetector(values: [:])
        )
        XCTAssertEqual(
            validator.validate("好的", target: .simplifiedChinese),
            .acceptWithWarning(.insufficientNaturalLanguage)
        )
    }

    func testEmptyAndToolStructuresAreRejected() {
        let validator = TranslationOutputValidator(
            detector: FixedTranslationLanguageDetector(values: [:])
        )
        XCTAssertEqual(validator.validate("  \n", target: .english), .reject(.emptyOutput))
        XCTAssertEqual(
            validator.validate("<tool_call>{\"name\":\"send\"}</tool_call>", target: .english),
            .reject(.unsafeStructure)
        )
    }

    func testTechnicalFragmentsAreRemovedBeforeDetection() {
        let cleaned = TranslationOutputValidator.naturalLanguageText(
            from: "请打开 https://example.com，然后运行 `git status`，路径是 ~/Work/demo.swift，版本 2.1.0。"
        )
        XCTAssertFalse(cleaned.contains("https://"))
        XCTAssertFalse(cleaned.contains("git status"))
        XCTAssertFalse(cleaned.contains("~/Work"))
        XCTAssertFalse(cleaned.contains("2.1.0"))
        XCTAssertTrue(cleaned.contains("请打开"))
    }
}
