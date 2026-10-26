import Foundation

public enum IntelliSenseAwarenessLayer: String, Codable, Equatable, Hashable, Sendable {
    case application
    case context
    case expression
}

public enum IntelliSenseHistoryScene: String, Codable, Equatable, Sendable {
    case search
    case title
    case messaging
    case email
    case document
    case browser
    case development
    case terminal
    case general
}

public enum IntelliSenseHistoryEffect: String, Codable, Equatable, Hashable, Sendable {
    case searchQueryCompressed
    case titleCompacted
    case chatToneAdapted
    case emailToneAdapted
    case documentStructured
    case listStructured
    case technicalSyntaxPreserved
    case explicitCorrectionApplied
    case contextTermAdopted
    case fillerRemoved
    case formattingAdjusted
    case generalPolish
    case noSignificantRewrite
    case protectedResultFallback
    case processingFallback
}

public enum IntelliSenseHistoryGuardOutcome: String, Codable, Equatable, Sendable {
    case accept
    case acceptWithWarnings
    case reject
    case unavailable
}

/// Versioned, privacy-safe processing metadata persisted with one history row.
/// It deliberately excludes nearby text, expression directives, prompts and
/// model-generated explanations.
public struct IntelliSenseHistoryTrace: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var appName: String?
    public var appCategory: ApplicationCategory
    public var controlCategory: InputControlCategory
    public var contextAvailability: ContextAvailability
    public var enabledLayers: [IntelliSenseAwarenessLayer]
    public var appliedLayers: [IntelliSenseAwarenessLayer]
    public var scene: IntelliSenseHistoryScene?
    public var effects: [IntelliSenseHistoryEffect]
    public var correctionDetected: Bool
    public var correctionObservationEnabled: Bool
    public var guardOutcome: IntelliSenseHistoryGuardOutcome
    public var guardRejection: IntelliSenseGuardRejection?

    public init(
        version: Int = currentVersion,
        appName: String?,
        appCategory: ApplicationCategory,
        controlCategory: InputControlCategory,
        contextAvailability: ContextAvailability,
        enabledLayers: [IntelliSenseAwarenessLayer],
        appliedLayers: [IntelliSenseAwarenessLayer],
        scene: IntelliSenseHistoryScene?,
        effects: [IntelliSenseHistoryEffect],
        correctionDetected: Bool,
        correctionObservationEnabled: Bool,
        guardOutcome: IntelliSenseHistoryGuardOutcome,
        guardRejection: IntelliSenseGuardRejection?
    ) {
        self.version = version
        self.appName = appName
        self.appCategory = appCategory
        self.controlCategory = controlCategory
        self.contextAvailability = contextAvailability
        self.enabledLayers = enabledLayers
        self.appliedLayers = appliedLayers
        self.scene = scene
        self.effects = effects
        self.correctionDetected = correctionDetected
        self.correctionObservationEnabled = correctionObservationEnabled
        self.guardOutcome = guardOutcome
        self.guardRejection = guardRejection
    }
}

public enum IntelliSenseHistoryTraceBuilder {
    public static func build(
        input: String,
        finalText: String,
        promptInput: IntelliSensePromptInput,
        processingResult: IntelliSenseProcessingResult?,
        processingFailed: Bool
    ) -> IntelliSenseHistoryTrace {
        let context = promptInput.context
        let settings = promptInput.settings
        let awarenessAllowed = context.availability != .blacklisted
            && context.availability != .sensitive

        var enabledLayers: [IntelliSenseAwarenessLayer] = []
        if settings.applicationAwarenessEnabled { enabledLayers.append(.application) }
        if settings.contextAwarenessEnabled { enabledLayers.append(.context) }
        if settings.expressionLearningEnabled { enabledLayers.append(.expression) }

        var appliedLayers: [IntelliSenseAwarenessLayer] = []
        if settings.applicationAwarenessEnabled, awarenessAllowed {
            appliedLayers.append(.application)
        }
        if settings.contextAwarenessEnabled, context.availability == .full {
            appliedLayers.append(.context)
        }
        if settings.expressionLearningEnabled,
           awarenessAllowed,
           promptInput.expressionProfile?.directives.isEmpty == false {
            appliedLayers.append(.expression)
        }
        if processingFailed {
            appliedLayers.removeAll()
        }

        let guardDetails = guardDetails(from: processingResult?.decision)
        let correctionDetected = processingResult?.correctionAnalysis.containsExplicitCorrection
            ?? CorrectionIntentAnalysis.analyze(input).containsExplicitCorrection
        let scene = appliedLayers.contains(.application)
            ? scene(category: context.appCategory, control: context.controlCategory)
            : nil
        let effects = effects(
            input: input,
            finalText: finalText,
            scene: scene,
            appliedLayers: appliedLayers,
            processingResult: processingResult,
            processingFailed: processingFailed,
            correctionDetected: correctionDetected
        )

        return IntelliSenseHistoryTrace(
            appName: sanitizedAppName(context.appName),
            appCategory: context.appCategory,
            controlCategory: context.controlCategory,
            contextAvailability: context.availability,
            enabledLayers: enabledLayers,
            appliedLayers: appliedLayers,
            scene: scene,
            effects: effects,
            correctionDetected: correctionDetected,
            correctionObservationEnabled: settings.correctionDetectionEnabled,
            guardOutcome: processingFailed ? .unavailable : guardDetails.outcome,
            guardRejection: processingFailed ? nil : guardDetails.rejection
        )
    }

    private static func guardDetails(
        from decision: IntelliSenseGuardDecision?
    ) -> (outcome: IntelliSenseHistoryGuardOutcome, rejection: IntelliSenseGuardRejection?) {
        guard let decision else { return (.unavailable, nil) }
        switch decision {
        case .accept:
            return (.accept, nil)
        case .acceptWithWarnings:
            return (.acceptWithWarnings, nil)
        case .reject(let reason):
            return (.reject, reason)
        }
    }

    private static func scene(
        category: ApplicationCategory,
        control: InputControlCategory
    ) -> IntelliSenseHistoryScene {
        if control == .search { return .search }
        if control == .title { return .title }
        switch category {
        case .messaging: return .messaging
        case .email: return .email
        case .document: return .document
        case .browser: return .browser
        case .development: return .development
        case .terminal: return .terminal
        case .other: return .general
        }
    }

    private static func effects(
        input: String,
        finalText: String,
        scene: IntelliSenseHistoryScene?,
        appliedLayers: [IntelliSenseAwarenessLayer],
        processingResult: IntelliSenseProcessingResult?,
        processingFailed: Bool,
        correctionDetected: Bool
    ) -> [IntelliSenseHistoryEffect] {
        if processingFailed { return [.processingFallback] }
        if case .reject = processingResult?.decision { return [.protectedResultFallback] }

        let inputTrimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputTrimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if inputTrimmed == outputTrimmed { return [.noSignificantRewrite] }

        var values: [IntelliSenseHistoryEffect] = []
        if correctionDetected,
           processingResult?.correctionAnalysis.supersededProtectedTokens.contains(where: {
               outputTrimmed.localizedCaseInsensitiveContains($0)
           }) != true {
            values.append(.explicitCorrectionApplied)
        }
        if processingResult?.decision.historyWarnings.contains(.contextTermAdopted) == true {
            values.append(.contextTermAdopted)
        }
        if removedFiller(from: inputTrimmed, in: outputTrimmed) {
            values.append(.fillerRemoved)
        }
        if ListStructureIntentAnalyzer.analyze(inputTrimmed) != .none,
           ListStructureIntentAnalyzer.listItemCount(in: outputTrimmed) >= 2 {
            values.append(.listStructured)
        }

        switch scene {
        case .search:
            values.append(.searchQueryCompressed)
        case .title:
            values.append(.titleCompacted)
        case .messaging:
            values.append(.chatToneAdapted)
        case .email:
            values.append(.emailToneAdapted)
        case .document where structureChanged(input: inputTrimmed, output: outputTrimmed)
            && !values.contains(.listStructured):
            values.append(.documentStructured)
        case .development, .terminal:
            values.append(.technicalSyntaxPreserved)
        default:
            break
        }

        if comparableText(inputTrimmed) == comparableText(outputTrimmed) {
            values.append(.formattingAdjusted)
        }
        if values.isEmpty {
            values.append(.generalPolish)
        }
        var seen = Set<IntelliSenseHistoryEffect>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func removedFiller(from input: String, in output: String) -> Bool {
        ["嗯", "呃", "就是说", "你知道吧"].contains {
            input.contains($0) && !output.contains($0)
        }
    }

    private static func structureChanged(input: String, output: String) -> Bool {
        input.filter(\.isNewline).count != output.filter(\.isNewline).count
            || listMarkerCount(in: input) != listMarkerCount(in: output)
    }

    private static func listMarkerCount(in text: String) -> Int {
        text.split(separator: "\n").filter {
            $0.range(of: #"^\s*(?:[-*•]|\d+[.)、])\s*"#, options: .regularExpression) != nil
        }.count
    }

    private static func comparableText(_ text: String) -> String {
        text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
        }.map(String.init).joined().lowercased()
    }

    private static func sanitizedAppName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }
}

private extension IntelliSenseGuardDecision {
    var historyWarnings: [IntelliSenseValidationWarning] {
        guard case .acceptWithWarnings(let values) = self else { return [] }
        return values
    }
}
