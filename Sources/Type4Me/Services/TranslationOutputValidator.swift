import Foundation
import NaturalLanguage

enum TranslationValidationWarning: Equatable, Sendable {
    case insufficientNaturalLanguage
    case lowConfidence
    case unexpectedLanguage(detected: String, confidence: Double)
}

enum TranslationValidationFailure: Equatable, Sendable {
    case emptyOutput
    case unsafeStructure
    case unexpectedLanguage(detected: String, confidence: Double)
}

enum TranslationValidationDecision: Equatable, Sendable {
    case accept
    case acceptWithWarning(TranslationValidationWarning)
    case reject(TranslationValidationFailure)
}

enum TranslationValidationAttempt: Sendable {
    case initial
    case retry
}

enum TranslationValidationAction: Equatable, Sendable {
    case accept
    case retry
    case reject(TranslationValidationFailure)
}

/// Converts detector evidence into product behavior. Short or uncertain text
/// remains warning-only, while a confident target-language mismatch gets one
/// retry before becoming a hard failure.
enum TranslationValidationPolicy {
    static func action(
        for decision: TranslationValidationDecision,
        attempt: TranslationValidationAttempt
    ) -> TranslationValidationAction {
        switch decision {
        case .accept:
            return .accept
        case .acceptWithWarning(.unexpectedLanguage(let detected, let confidence)):
            switch attempt {
            case .initial:
                return .retry
            case .retry:
                return .reject(.unexpectedLanguage(
                    detected: detected,
                    confidence: confidence
                ))
            }
        case .acceptWithWarning:
            return .accept
        case .reject(.unexpectedLanguage(let detected, let confidence)):
            switch attempt {
            case .initial:
                return .retry
            case .retry:
                return .reject(.unexpectedLanguage(
                    detected: detected,
                    confidence: confidence
                ))
            }
        case .reject(let failure):
            return .reject(failure)
        }
    }
}

protocol TranslationLanguageDetecting: Sendable {
    func hypotheses(for text: String) -> [String: Double]
}

struct NaturalTranslationLanguageDetector: TranslationLanguageDetecting {
    func hypotheses(for text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return Dictionary(
            uniqueKeysWithValues: recognizer
                .languageHypotheses(withMaximum: 4)
                .map { ($0.key.rawValue, $0.value) }
        )
    }
}

struct TranslationOutputValidator: Sendable {
    enum UnexpectedLanguagePolicy: Sendable {
        case warn
        case reject
    }

    static let minimumNaturalLanguageCharacterCount = 12
    static let dominantWrongLanguageConfidence = 0.90
    static let maximumTargetLanguageConfidenceForMismatch = 0.03

    /// The detector reports language mismatches as warnings. The session-level
    /// policy promotes a confident mismatch to one retry, then a hard failure.
    /// Structural failures are rejected immediately.
    static let production = TranslationOutputValidator(
        detector: NaturalTranslationLanguageDetector(),
        unexpectedLanguagePolicy: .warn
    )

    let detector: any TranslationLanguageDetecting
    let unexpectedLanguagePolicy: UnexpectedLanguagePolicy

    init(
        detector: any TranslationLanguageDetecting,
        unexpectedLanguagePolicy: UnexpectedLanguagePolicy = .warn
    ) {
        self.detector = detector
        self.unexpectedLanguagePolicy = unexpectedLanguagePolicy
    }

    func validate(_ output: String, target: TranslationLanguage) -> TranslationValidationDecision {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .reject(.emptyOutput) }
        guard !Self.containsUnsafeStructure(trimmed) else { return .reject(.unsafeStructure) }

        let naturalText = Self.naturalLanguageText(from: trimmed)
        let characterCount = naturalText.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) { count += 1 }
        }
        guard characterCount >= Self.minimumNaturalLanguageCharacterCount else {
            return .acceptWithWarning(.insufficientNaturalLanguage)
        }

        let hypotheses = detector.hypotheses(for: naturalText)
        guard let dominant = hypotheses.max(by: { $0.value < $1.value }) else {
            return .acceptWithWarning(.lowConfidence)
        }

        let targetConfidence = target.naturalLanguageIdentifiers
            .compactMap { hypotheses[$0] }
            .max() ?? 0
        if targetConfidence > Self.maximumTargetLanguageConfidenceForMismatch {
            return .accept
        }

        guard dominant.value >= Self.dominantWrongLanguageConfidence else {
            return .acceptWithWarning(.lowConfidence)
        }

        let warning = TranslationValidationWarning.unexpectedLanguage(
            detected: dominant.key,
            confidence: dominant.value
        )
        switch unexpectedLanguagePolicy {
        case .warn:
            return .acceptWithWarning(warning)
        case .reject:
            return .reject(.unexpectedLanguage(
                detected: dominant.key,
                confidence: dominant.value
            ))
        }
    }

    private static func containsUnsafeStructure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("<tool_call")
            || lower.contains("</tool_call>")
            || lower.contains("<function_call")
            || lower.contains("</function_call>")
    }

    /// Remove technical fragments that can dominate language recognition. A
    /// conservative cleaner is preferable here: uncertainty is accepted.
    static func naturalLanguageText(from text: String) -> String {
        let patterns = [
            #"```[\s\S]*?```"#,
            #"`[^`\n]+`"#,
            #"https?://\S+"#,
            #"\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#,
            #"(?:^|\s)(?:~?/|\./|\.\./)[^\s]+"#,
            #"\b[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+\b"#,
            #"\b\d+(?:[.,:/-]\d+)*\b"#,
        ]
        return patterns.reduce(text) { partial, pattern in
            partial.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }
    }
}
