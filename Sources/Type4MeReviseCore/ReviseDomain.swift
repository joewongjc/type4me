import Foundation

public enum ReviseControlKind: String, Codable, Sendable {
    case singleLine
    case multiLine
    case code
    case terminal
    case unknown
}

public enum ReviseSourceModeKind: String, Codable, Sendable {
    case direct
    case intelliSense
    case translation
    case voicePolish
    case customText
    case otherText
}

public struct ReviseLanguageProfile: Codable, Equatable, Sendable {
    public let primaryScript: String
    public let mixed: Bool

    public init(primaryScript: String, mixed: Bool) {
        self.primaryScript = primaryScript
        self.mixed = mixed
    }

    public static func detect(in text: String) -> ReviseLanguageProfile {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {
                cjk += 1
            } else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
                latin += 1
            }
        }
        let total = cjk + latin
        if total == 0 {
            return ReviseLanguageProfile(primaryScript: "unknown", mixed: false)
        }
        let cjkRatio = Double(cjk) / Double(total)
        let latinRatio = Double(latin) / Double(total)
        let mixed = cjk > 0 && latin > 0 && min(cjkRatio, latinRatio) >= 0.15
        let primary = cjkRatio >= latinRatio ? "han" : "latin"
        return ReviseLanguageProfile(primaryScript: primary, mixed: mixed)
    }
}

public struct ReviseRequest: Equatable, Sendable {
    public let requestID: UUID
    public let targetText: String
    public let instruction: String
    public let controlKind: ReviseControlKind
    public let sourceLanguage: ReviseLanguageProfile
    public let sourceModeKind: ReviseSourceModeKind

    public init(
        requestID: UUID = UUID(),
        targetText: String,
        instruction: String,
        controlKind: ReviseControlKind,
        sourceLanguage: ReviseLanguageProfile,
        sourceModeKind: ReviseSourceModeKind
    ) {
        self.requestID = requestID
        self.targetText = targetText
        self.instruction = instruction
        self.controlKind = controlKind
        self.sourceLanguage = sourceLanguage
        self.sourceModeKind = sourceModeKind
    }
}

public enum ReviseInputBudget {
    public static let maxTargetCharacters = 16_000
    public static let maxInstructionCharacters = 2_000
    public static let maxModelResponseBytes = 256_000
    public static let maxCombinedDiffCharacters = 32_000
    public static let diffCalculationBudget: Duration = .milliseconds(20)
}

public enum ReviseIntent: String, Codable, Sendable {
    case replace
    case delete
    case insert
    case rewrite
    case format
    case translate
    case undo
    case unsupported
}

public struct ReviseScopeDescriptor: Codable, Equatable, Sendable {
    public var kind: Kind
    public var selector: String?
    public var ordinal: Int?

    public init(kind: Kind, selector: String? = nil, ordinal: Int? = nil) {
        self.kind = kind
        self.selector = selector
        self.ordinal = ordinal
    }

    public enum Kind: String, Codable, Sendable {
        case whole
        case literal
        case sentence
        case paragraph
        case listItem
        case semantic
    }
}

public enum ReviseFactKind: String, Codable, Equatable, Hashable, Sendable {
    case time
    case date
    case money
    case percentage
    case number
    case url
    case email
    case path
    case codeIdentifier
}

public struct ReviseFact: Equatable, Sendable {
    public let kind: ReviseFactKind
    public let text: String
    public let range: Range<String.Index>

    public init(kind: ReviseFactKind, text: String, range: Range<String.Index>) {
        self.kind = kind
        self.text = text
        self.range = range
    }
}

public enum ReviseReplacementAuthorization: Equatable, Sendable {
    case explicit(oldValue: String, newValue: String)
    case implicit(newValue: String, slotKind: ReviseFactKind)
}

public enum ReviseValidationWarning: String, Codable, Equatable, Sendable {
    case negationCountChanged
    case formatStructureChanged
    case minorPunctuationNormalized
    case externalActionIgnored
    case largeRewrite
    case modelOutputIgnoredForLocalReplacement
}

public enum ReviseRejection: String, Error, Codable, Equatable, Sendable {
    case emptyOutput
    case disallowedEmptyOutput
    case malformedJSON
    case schemaVersionMismatch
    case modelAmbiguous
    case unsupportedIntent
    case intentMismatch
    case scopeMissing
    case scopeNotFound
    case scopeMultipleMatchesWithoutOrdinal
    case scopeOrdinalOutOfBounds
    case implicitReplacementAmbiguous
    case changeOutsideAuthorizedScope
    case protectedTokenRemovedWithoutAuthorization
    case protectedTokenAddedWithoutAuthorization
    case protectedFactConflict
    case strongRelationChanged
    case languageChangedWithoutAuthorization
    case singleLineViolation
    case answerOrExplanation
    case claimedExecution
    case codeFence
    case toolCall
    case sensitiveContentLeak
    case extremeExpansion
    case diffBudgetExceeded
    case targetTooLong
    case instructionTooLong
    case responseTooLarge
    case noCandidate
}

public enum ReviseValidationDecision: Equatable, Sendable {
    case accept(warnings: [ReviseValidationWarning])
    case reject(ReviseRejection)
}

public enum ReviseFailure: String, Error, Codable, Sendable {
    case disabled
    case noTarget
    case expired
    case busy
    case appChanged
    case controlChanged
    case targetMissing
    case targetAmbiguous
    case targetTooLong
    case sensitive
    case excludedApp
    case instructionEmpty
    case instructionTooLong
    case instructionAmbiguous
    case unsupportedInstruction
    case implicitReplacementAmbiguous
    case protectedFactConflict
    case llmUnavailable
    case providerFailure
    case malformedModelResponse
    case validationRejected
    case targetChangedDuringProcessing
    case replacementFailed
    case partialFailure
    case nothingToUndo
    case staleTransaction
    case noEditableTarget
    case responseTooLarge
    case diffBudgetExceeded
}

public struct ReviseProcessingResult: Equatable, Sendable {
    public let request: ReviseRequest
    public let response: ReviseModelResponse?
    public let candidateText: String?
    public let diff: ReviseDiffSummary?
    public let decision: ReviseValidationDecision
    public let trace: ReviseValidationTrace

    public init(
        request: ReviseRequest,
        response: ReviseModelResponse?,
        candidateText: String?,
        diff: ReviseDiffSummary?,
        decision: ReviseValidationDecision,
        trace: ReviseValidationTrace
    ) {
        self.request = request
        self.response = response
        self.candidateText = candidateText
        self.diff = diff
        self.decision = decision
        self.trace = trace
    }
}
