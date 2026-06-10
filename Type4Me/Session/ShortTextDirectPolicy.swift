import Foundation

enum ShortTextDirectPolicy {
    static let enabledKey = "tf_shortTextDirectEnabled"
    static let thresholdKey = "tf_shortTextDirectThreshold"
    static let defaultThreshold = 8

    enum Decision: Equatable, Sendable {
        case directOutput
        case disabled
        case modeRequiresLLM
        case textTooLong
    }

    static var isEnabled: Bool {
        guard let stored = UserDefaults.standard.object(forKey: enabledKey) else {
            return true
        }
        return stored as? Bool ?? true
    }

    static var threshold: Int {
        guard let stored = UserDefaults.standard.object(forKey: thresholdKey) else {
            return defaultThreshold
        }
        if let value = stored as? Int {
            return max(0, value)
        }
        if let value = stored as? String, let parsed = Int(value) {
            return max(0, parsed)
        }
        return defaultThreshold
    }

    static func semanticLength(of text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            guard !CharacterSet.whitespacesAndNewlines.contains(scalar),
                  !CharacterSet.punctuationCharacters.contains(scalar)
            else { return }
            count += 1
        }
    }

    static func isSafePolishingMode(_ mode: ProcessingMode) -> Bool {
        mode.id == ProcessingMode.formalWritingId
            && mode.prompt == ProcessingMode.formalWritingPromptTemplate
    }

    static func decide(
        text: String,
        mode: ProcessingMode,
        enabled: Bool = isEnabled,
        threshold: Int = threshold
    ) -> Decision {
        guard enabled else { return .disabled }
        guard isSafePolishingMode(mode) else { return .modeRequiresLLM }
        return semanticLength(of: text) <= threshold ? .directOutput : .textTooLong
    }

    static func shouldStartStopTimeProvisional(
        partialText: String,
        mode: ProcessingMode,
        enabled: Bool = isEnabled,
        threshold: Int = threshold
    ) -> Bool {
        decide(
            text: partialText,
            mode: mode,
            enabled: enabled,
            threshold: threshold
        ) != .directOutput
    }
}
