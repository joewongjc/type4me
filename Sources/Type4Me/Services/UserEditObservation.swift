import Foundation

enum UserEditObservationFormat {
    /// Version of the persisted user-edit evidence payload. This is independent
    /// from the SQLite schema migration sequence.
    static let currentVersion = 2
}

struct UserEditObservationTiming: Equatable, Sendable {
    var stableWindow: Duration
    var candidatePresentationDelay: Duration
    var readRetryDelay: Duration
    var observationTimeout: Duration
    var resolverBudget: Duration
    var evidenceDecayHalfLifeDays: Double

    static let production = Self(
        stableWindow: .milliseconds(800),
        candidatePresentationDelay: .seconds(4),
        readRetryDelay: .milliseconds(100),
        observationTimeout: .seconds(60),
        resolverBudget: .milliseconds(10),
        evidenceDecayHalfLifeDays: 90
    )
}

enum UserEditObservedValueSanitizer {
    static func contentValue(
        _ value: String,
        placeholderCandidates: [String?]
    ) -> String {
        let normalizedValue = normalize(value)
        guard !normalizedValue.isEmpty else { return "" }
        let isPlaceholder = placeholderCandidates
            .compactMap { $0 }
            .map(normalize)
            .contains { !$0.isEmpty && $0 == normalizedValue }
        return isPlaceholder ? "" : value
    }

    private static func normalize(_ value: String) -> String {
        VisibleTextProjection.project(value).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct VisibleTextProjection: Equatable, Sendable {
    let text: String
    private let sourceUTF16BoundaryToVisibleUTF16: [Int: Int]

    static func project(_ source: String) -> Self {
        let characters = Array(source)
        let boundaryArtifacts = boundaryArtifactOffsets(in: characters)
        var output = ""
        var sourceOffset = 0
        var boundaryMap: [Int: Int] = [0: 0]

        for (offset, character) in characters.enumerated() {
            let sourceLength = String(character).utf16.count
            let projected = boundaryArtifacts.contains(offset)
                ? ""
                : visibleValue(of: character)
            output += projected
            sourceOffset += sourceLength
            boundaryMap[sourceOffset] = output.utf16.count
        }
        return Self(
            text: output.precomposedStringWithCanonicalMapping,
            sourceUTF16BoundaryToVisibleUTF16: boundaryMap
        )
    }

    func projectedRange(from sourceRange: NSRange) -> NSRange? {
        guard sourceRange.location >= 0,
              sourceRange.length >= 0,
              let lower = sourceUTF16BoundaryToVisibleUTF16[sourceRange.location],
              let upper = sourceUTF16BoundaryToVisibleUTF16[NSMaxRange(sourceRange)],
              upper >= lower
        else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func visibleValue(of character: Character) -> String {
        var scalars: [Unicode.Scalar] = []
        let sourceScalars = Array(character.unicodeScalars)
        var index = 0
        while index < sourceScalars.count {
            let scalar = sourceScalars[index]
            if scalar.value == 0x0D {
                if index + 1 < sourceScalars.count,
                   sourceScalars[index + 1].value == 0x0A {
                    index += 1
                }
                scalars.append(Unicode.Scalar(0x0A)!)
            } else if shouldPreserve(scalar) {
                scalars.append(scalar)
            }
            index += 1
        }
        return String(String.UnicodeScalarView(scalars))
            .precomposedStringWithCanonicalMapping
    }

    private static func shouldPreserve(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x09 || scalar.value == 0x0A { return true }
        if isEditorSentinel(scalar) { return false }
        return scalar.properties.generalCategory != .control
    }

    private static func boundaryArtifactOffsets(in characters: [Character]) -> Set<Int> {
        guard !characters.isEmpty else { return [] }
        var result: Set<Int> = []

        func scan(_ offsets: [Int]) -> Set<Int> {
            var candidate: Set<Int> = []
            var containsSentinel = false
            for offset in offsets {
                let character = characters[offset]
                if isEditorSentinel(character) {
                    containsSentinel = true
                    candidate.insert(offset)
                } else if isLineBreak(character) {
                    candidate.insert(offset)
                } else {
                    break
                }
            }
            return containsSentinel ? candidate : []
        }

        result.formUnion(scan(Array(characters.indices)))
        result.formUnion(scan(Array(characters.indices.reversed())))
        return result
    }

    private static func isEditorSentinel(_ character: Character) -> Bool {
        !character.unicodeScalars.isEmpty
            && character.unicodeScalars.allSatisfy(isEditorSentinel)
    }

    private static func isEditorSentinel(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x200B || scalar.value == 0xFEFF || scalar.value == 0x2060
    }

    private static func isLineBreak(_ character: Character) -> Bool {
        !character.unicodeScalars.isEmpty
            && character.unicodeScalars.allSatisfy {
                $0.value == 0x0A || $0.value == 0x0D
            }
    }
}

enum UserEditControlResetDetector {
    static func isLikelyReset(
        baselineValue: String,
        injectedRange: NSRange,
        injectedText: String,
        lastReliableInjectedText: String,
        previousFullValue: String,
        currentValue: String,
        structuralChangeThreshold: Double = 0.70
    ) -> Bool {
        guard !currentValue.isEmpty,
              currentValue != baselineValue,
              !currentValue.contains(injectedText),
              !currentValue.contains(lastReliableInjectedText),
              let baselineRange = Range(injectedRange, in: baselineValue)
        else { return false }

        let prefix = String(baselineValue[..<baselineRange.lowerBound])
        let suffix = String(baselineValue[baselineRange.upperBound...])
        // Sending a message can leave only the content that existed outside
        // this injection. In that state the injected slice was removed; it was
        // not rewritten to the remaining prefix/suffix.
        if currentValue == prefix + suffix {
            return true
        }

        let retainedExternalAnchor = (!prefix.isEmpty && currentValue.hasPrefix(prefix))
            || (!suffix.isEmpty && currentValue.hasSuffix(suffix))
        guard !retainedExternalAnchor else { return false }

        return normalizedChangeRatio(
            previous: previousFullValue,
            current: currentValue
        ) > structuralChangeThreshold
    }

    static func normalizedChangeRatio(
        previous: String,
        current: String
    ) -> Double {
        guard previous != current else { return 0 }
        let old = Array(previous)
        let new = Array(current)
        let maximumLength = max(old.count, new.count)
        guard maximumLength > 0 else { return 0 }
        let difference = new.difference(from: old)
        var insertions = 0
        var removals = 0
        for change in difference {
            switch change {
            case .insert: insertions += 1
            case .remove: removals += 1
            }
        }
        return Double(max(insertions, removals)) / Double(maximumLength)
    }
}

enum UserEditVisibleTransition: Equatable, Sendable {
    case unchanged
    case changed
    case valueCleared
    case structureChanged
}

enum UserEditVisibleStateMachine {
    static func classify(
        currentVisibleValue: String,
        isPlaceholder: Bool,
        baselineVisibleValue: String,
        visibleInjectedRange: NSRange,
        visibleInjectedText: String,
        lastReliableVisibleInjectedText: String,
        previousVisibleFullValue: String
    ) -> UserEditVisibleTransition {
        if isPlaceholder { return .structureChanged }
        if currentVisibleValue.isEmpty { return .valueCleared }
        if currentVisibleValue == previousVisibleFullValue { return .unchanged }
        if UserEditControlResetDetector.isLikelyReset(
            baselineValue: baselineVisibleValue,
            injectedRange: visibleInjectedRange,
            injectedText: visibleInjectedText,
            lastReliableInjectedText: lastReliableVisibleInjectedText,
            previousFullValue: previousVisibleFullValue,
            currentValue: currentVisibleValue
        ) {
            return .structureChanged
        }
        return .changed
    }
}

enum UserEditObservationEndReason: String, Codable, Sendable {
    case timeout
    case valueCleared
    case structureChanged
    case nextRecording
    case elementDestroyed
    case readFailure
    case appTerminated
    case settingsDisabled
    case appBlacklisted
    case cancelled
    case reviseStarted
    case reviseApplied
}

enum UserEditObservationStatus: String, Codable, Sendable {
    case unchanged
    case edited
    case clearedAfterEdit
    case ambiguous
    case sensitiveRedacted
    case unavailable

    var informationRank: Int {
        switch self {
        case .unavailable: 0
        case .ambiguous: 1
        case .unchanged: 2
        case .sensitiveRedacted: 3
        case .edited: 4
        case .clearedAfterEdit: 5
        }
    }
}

enum UserEditClassification: String, Codable, Sendable {
    case unchanged
    case lexicalCorrection
    case expressionEdit
    case contentEdit
    case mixedEdit
    case ambiguous
    case sensitive
}

enum ResolutionConfidence: String, Codable, Sendable {
    case exact
    case anchored
    case ambiguous
}

enum InjectedTextResolutionFailure: String, Error, Codable, Sendable {
    case invalidRange
    case boundaryConflict
    case insufficientAnchor
    case budgetExceeded
}

struct InjectedTextResolution: Equatable, Sendable {
    let text: String?
    let confidence: ResolutionConfidence
    let changedInsideInjection: Bool
    let changedOutsideInjection: Bool
    let failure: InjectedTextResolutionFailure?

    static func ambiguous(
        _ failure: InjectedTextResolutionFailure,
        changedOutsideInjection: Bool = false
    ) -> Self {
        Self(
            text: nil,
            confidence: .ambiguous,
            changedInsideInjection: false,
            changedOutsideInjection: changedOutsideInjection,
            failure: failure
        )
    }
}

struct UserEditObservationSettlement: Equatable, Sendable {
    let text: String?
    let status: UserEditObservationStatus
    let classification: UserEditClassification

    static func resolve(
        original: String,
        lastReliableText: String,
        latestResolutionConfidence: ResolutionConfidence,
        hasObservedExternalChanges: Bool,
        endReason: UserEditObservationEndReason
    ) -> Self {
        let original = VisibleTextProjection.project(original).text
        let lastReliableText = VisibleTextProjection.project(lastReliableText).text
        let classification = UserEditClassifier.classify(
            original: original,
            edited: lastReliableText
        )
        if endReason == .appBlacklisted || endReason == .settingsDisabled {
            return Self(text: nil, status: .unavailable, classification: .ambiguous)
        }
        if classification == .sensitive {
            return Self(text: nil, status: .sensitiveRedacted, classification: classification)
        }
        if endReason == .readFailure, !hasObservedExternalChanges {
            return Self(text: nil, status: .unavailable, classification: classification)
        }
        if latestResolutionConfidence == .ambiguous,
           lastReliableText == original,
           hasObservedExternalChanges {
            return Self(text: nil, status: .ambiguous, classification: classification)
        }
        if lastReliableText == original {
            return Self(text: nil, status: .unchanged, classification: classification)
        }
        return Self(
            text: lastReliableText,
            status: endReason == .valueCleared ? .clearedAfterEdit : .edited,
            classification: classification
        )
    }
}
