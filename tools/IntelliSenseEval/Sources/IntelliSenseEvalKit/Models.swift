import Foundation
import Type4MeIntelliSenseCore

public struct EvaluationApplication: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var appName: String
    public var category: ApplicationCategory?
}

public struct EvaluationAwareness: Codable, Equatable, Sendable {
    public var application: Bool
    public var context: Bool
    public var expression: Bool
    public var correction: Bool

    public init(application: Bool = false, context: Bool = false, expression: Bool = false, correction: Bool = false) {
        self.application = application
        self.context = context
        self.expression = expression
        self.correction = correction
    }
}

public struct EvaluationCase: Codable, Equatable, Sendable {
    public var id: String
    public var suite: String
    public var tags: [String]
    public var inputText: String
    public var application: EvaluationApplication?
    public var control: InputControlCategory
    public var contextBefore: String
    public var contextAfter: String
    public var contextAvailability: ContextAvailability
    public var enabledAwareness: EvaluationAwareness
    public var expressionProfile: [String]
    public var intentSummary: String
    public var mustPreserve: [String]
    public var mustRemove: [String]
    public var mustNotAdd: [String]
    public var acceptableVariations: [String]
    public var expectedAppEffect: String
    public var expectedContextUse: String
    public var hardAssertions: [String]
    public var mustChange: Bool
    public var smoke: Bool
    public var critical: Bool

    enum CodingKeys: String, CodingKey {
        case id, suite, tags, inputText, application, control, contextBefore, contextAfter
        case contextAvailability, enabledAwareness, expressionProfile, intentSummary
        case mustPreserve, mustRemove, mustNotAdd, acceptableVariations
        case expectedAppEffect, expectedContextUse, hardAssertions, mustChange, smoke, critical
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        suite = try c.decode(String.self, forKey: .suite)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        inputText = try c.decode(String.self, forKey: .inputText)
        application = try c.decodeIfPresent(EvaluationApplication.self, forKey: .application)
        control = try c.decodeIfPresent(InputControlCategory.self, forKey: .control) ?? .unknown
        contextBefore = try c.decodeIfPresent(String.self, forKey: .contextBefore) ?? ""
        contextAfter = try c.decodeIfPresent(String.self, forKey: .contextAfter) ?? ""
        contextAvailability = try c.decodeIfPresent(ContextAvailability.self, forKey: .contextAvailability)
            ?? ((contextBefore.isEmpty && contextAfter.isEmpty) ? .appAndControl : .full)
        enabledAwareness = try c.decodeIfPresent(EvaluationAwareness.self, forKey: .enabledAwareness) ?? .init()
        expressionProfile = try c.decodeIfPresent([String].self, forKey: .expressionProfile) ?? []
        intentSummary = try c.decodeIfPresent(String.self, forKey: .intentSummary) ?? ""
        mustPreserve = try c.decodeIfPresent([String].self, forKey: .mustPreserve) ?? []
        mustRemove = try c.decodeIfPresent([String].self, forKey: .mustRemove) ?? []
        mustNotAdd = try c.decodeIfPresent([String].self, forKey: .mustNotAdd) ?? []
        acceptableVariations = try c.decodeIfPresent([String].self, forKey: .acceptableVariations) ?? []
        expectedAppEffect = try c.decodeIfPresent(String.self, forKey: .expectedAppEffect) ?? ""
        expectedContextUse = try c.decodeIfPresent(String.self, forKey: .expectedContextUse) ?? ""
        hardAssertions = try c.decodeIfPresent([String].self, forKey: .hardAssertions) ?? []
        mustChange = try c.decodeIfPresent(Bool.self, forKey: .mustChange) ?? false
        smoke = try c.decodeIfPresent(Bool.self, forKey: .smoke) ?? false
        critical = try c.decodeIfPresent(Bool.self, forKey: .critical) ?? false
    }

    public func makeRequest() -> IntelliSenseRequest {
        let category = application?.category ?? AppContextClassifier.classify(
            bundleIdentifier: application?.bundleIdentifier,
            appName: application?.appName
        )
        let snapshot = IntelliSenseContextSnapshot(
            bundleIdentifier: application?.bundleIdentifier,
            appName: application?.appName,
            appCategory: category,
            controlCategory: control,
            contextBeforeCursor: contextBefore,
            contextAfterCursor: contextAfter,
            availability: contextAvailability,
            wasTruncated: false
        )
        let blacklist: [BlacklistedApp] = contextAvailability == .blacklisted
            ? [BlacklistedApp(
                bundleIdentifier: application?.bundleIdentifier ?? "com.example.blacklisted",
                displayName: application?.appName ?? "Blacklisted"
            )]
            : []
        let settings = IntelliSenseSettings(
            applicationAwarenessEnabled: enabledAwareness.application,
            contextAwarenessEnabled: enabledAwareness.context,
            correctionDetectionEnabled: enabledAwareness.correction,
            expressionLearningEnabled: enabledAwareness.expression,
            blacklistedApps: blacklist
        )
        return IntelliSenseRequest(
            text: inputText,
            context: snapshot,
            settings: settings,
            expressionProfile: expressionProfile.isEmpty
                ? nil
                : EffectiveExpressionProfile(directives: expressionProfile, sourceScope: "evaluation")
        )
    }
}

public struct EvaluationModelConfig: Codable, Equatable, Sendable {
    public enum ThinkingMode: String, Codable, Sendable {
        case none
        case thinkingDisabled
        case enableThinkingFalse
        case reasoningEffortNone
        case thinkFalse
    }

    public var model: String
    public var baseURL: String
    public var apiKeyEnvironment: String
    public var thinkingMode: ThinkingMode

    public init(model: String, baseURL: String, apiKeyEnvironment: String, thinkingMode: ThinkingMode = .none) {
        self.model = model
        self.baseURL = baseURL
        self.apiKeyEnvironment = apiKeyEnvironment
        self.thinkingMode = thinkingMode
    }
}

public struct EvaluationConfig: Codable, Sendable {
    public var models: [String: EvaluationModelConfig]

    public init(models: [String: EvaluationModelConfig]) {
        self.models = models
    }
}

public struct AutomatedCheck: Codable, Equatable, Sendable {
    public var name: String
    public var passed: Bool
    public var detail: String
}

public struct EvaluationResult: Codable, Equatable, Sendable {
    public var runID: String
    public var caseID: String
    public var suite: String
    public var repetition: Int
    public var modelAlias: String
    public var modelID: String
    public var inputText: String
    public var application: EvaluationApplication?
    public var control: InputControlCategory
    public var contextAvailability: ContextAvailability
    public var contextBefore: String
    public var contextAfter: String
    public var enabledAwareness: EvaluationAwareness
    public var expressionProfile: [String]
    public var intentSummary: String
    public var promptHash: String
    public var candidateText: String
    public var finalText: String
    public var guardDecision: String
    public var guardDiagnostics: [String]
    public var correctionDetected: Bool
    public var automatedChecks: [AutomatedCheck]
    public var latencyMilliseconds: Int
    public var retryCount: Int?
    public var cached: Bool
    public var error: String?
    public var humanVerdict: String?
    public var humanNotes: String?

    public var automatedPass: Bool {
        error == nil && automatedChecks.allSatisfy(\.passed)
    }
}

public enum EvaluationError: LocalizedError {
    case invalidArguments(String)
    case missingModel(String)
    case missingEnvironment(String)
    case invalidResponse(String)
    case fixture(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let value): return value
        case .missingModel(let value): return "Unknown model alias: \(value)"
        case .missingEnvironment(let value): return "Missing environment variable: \(value)"
        case .invalidResponse(let value): return "Invalid model response: \(value)"
        case .fixture(let value): return "Fixture error: \(value)"
        }
    }
}
