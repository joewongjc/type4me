import Foundation
import Type4MeIntelliSenseCore

enum ExpressionFeature: String, Codable, CaseIterable, Sendable {
    case averageSentenceLength
    case averageParagraphLength
    case lineBreakDensity
    case listUsage
    case headingUsage
    case fillerRetention
    case terminalPunctuationUsage
    case exclamationUsage
    case chineseEnglishSpacing
    case compactness
}

enum FeatureLearningState: String, Codable, Sendable {
    case insufficient
    case learning
    case stable
}

struct FeatureAccumulator: Codable, Equatable, Sendable {
    var weightedMean: Double = 0
    var totalWeight: Double = 0
    var positiveEvidence: Int = 0
    var negativeEvidence: Int = 0
    var acceptedEvidence: Int = 0
    var state: FeatureLearningState = .insufficient
    var firstObservedAt: Date?
    var updatedAt: Date = .distantPast
}

struct ScopeExpressionProfile: Codable, Equatable, Sendable {
    var sampleCount: Int = 0
    var editedSampleCount: Int = 0
    var firstObservedAt: Date?
    var lastObservedAt: Date?
    var features: [String: FeatureAccumulator] = [:]
}

struct ExpressionProfileDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion = currentSchemaVersion
    var global = ScopeExpressionProfile()
    var categories: [String: ScopeExpressionProfile] = [:]
    var applications: [String: ScopeExpressionProfile] = [:]
    /// Persisted rebuild watermark. Historical observations at or before this
    /// instant must never repopulate a profile the user explicitly cleared.
    var expressionLearningResetAt: Date?
}

struct ExpressionLearningThresholds: Equatable, Sendable {
    var learningSamples = 5
    var stableSamples = 10
    var stableDaySpan = 3
    var directionalConsistency = 0.7
    var editedWeight = 1.0
    var acceptedWeight = 0.25
    var decayHalfLifeDays = 90.0
    var stableExitConsistency = 0.55

    static let production = Self()
}

struct ExpressionObservation: Sendable {
    let sessionID: String
    let createdAt: Date
    let appBundleIdentifier: String?
    let appCategory: ApplicationCategory
    let sourceText: String?
    let injectedText: String
    let finalObservedText: String
    let correctionCandidateRange: NSRange?

    init(
        sessionID: String,
        createdAt: Date,
        appBundleIdentifier: String?,
        appCategory: ApplicationCategory,
        sourceText: String? = nil,
        injectedText: String,
        finalObservedText: String,
        correctionCandidateRange: NSRange?
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.appBundleIdentifier = appBundleIdentifier
        self.appCategory = appCategory
        self.sourceText = sourceText
        self.injectedText = injectedText
        self.finalObservedText = finalObservedText
        self.correctionCandidateRange = correctionCandidateRange
    }
}

struct ExpressionFeatureSample: Equatable, Sendable {
    let values: [ExpressionFeature: Double]
    let directions: [ExpressionFeature: Int]
    let wasEdited: Bool
}

enum ExpressionFeatureExtractor {
    static func extract(_ observation: ExpressionObservation) -> ExpressionFeatureSample? {
        let injected = observation.injectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        var final = observation.finalObservedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard injected.count >= 12, final.count >= 12 else { return nil }
        guard !IntelliSenseSensitiveTextScanner.containsSensitiveContent(injected + "\n" + final) else {
            return nil
        }

        // A confirmed vocabulary correction is content-neutral for this model.
        // If its range is known, restore the injected spelling before extracting style.
        if let range = observation.correctionCandidateRange,
           let swiftRange = Range(range, in: final),
           let injectedRange = Range(range, in: injected) {
            final.replaceSubrange(swiftRange, with: injected[injectedRange])
        }

        guard final == injected || (
            !containsFactSensitiveToken(injected + "\n" + final)
                && isSafeStyleEdit(input: injected, output: final)
        ) else { return nil }
        var before = measurements(injected)
        var after = measurements(final)
        let beforeListItems = ListStructureIntentAnalyzer.listItemCount(in: injected)
        let afterListItems = ListStructureIntentAnalyzer.listItemCount(in: final)
        if beforeListItems < 2, afterListItems < 2 {
            before.removeValue(forKey: .listUsage)
            after.removeValue(forKey: .listUsage)
        }
        before[.compactness] = 1
        after[.compactness] = Double(final.count) / Double(max(1, injected.count))
        let directions = Dictionary(uniqueKeysWithValues: ExpressionFeature.allCases.map { feature in
            let delta = (after[feature] ?? 0) - (before[feature] ?? 0)
            let epsilon = feature == .averageSentenceLength || feature == .averageParagraphLength ? 1.0 : 0.025
            return (feature, delta > epsilon ? 1 : (delta < -epsilon ? -1 : 0))
        })
        return ExpressionFeatureSample(
            values: after,
            directions: directions,
            wasEdited: final != injected
        )
    }

    static func measurements(_ text: String) -> [ExpressionFeature: Double] {
        let scalars = max(1, text.unicodeScalars.count)
        let sentences = text.split(whereSeparator: { ".!?。！？\n".contains($0) })
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        let lines = text.components(separatedBy: .newlines)
        let nonemptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let listLines = nonemptyLines.filter {
            $0.range(of: #"^\s*(?:[-*•]|\d+[.)、])\s+"#, options: .regularExpression) != nil
        }
        let headingLines = nonemptyLines.filter {
            $0.range(of: #"^\s*(?:#{1,6}\s+|[^\n]{1,30}[:：]\s*$)"#, options: .regularExpression) != nil
        }
        let fillers = matches(#"(?:\b(?:um|uh|like)\b|嗯|呃|啊|那个)"#, in: text, caseInsensitive: true)
        let terminalPunctuation = nonemptyLines.filter {
            $0.trimmingCharacters(in: .whitespaces).last.map { ".!?。！？".contains($0) } == true
        }.count
        let exclamations = text.filter { "!！".contains($0) }.count
        let spacedTransitions = matches(#"(?:\p{Han}\s+[A-Za-z]|[A-Za-z]\s+\p{Han})"#, in: text)
        let allTransitions = matches(#"(?:\p{Han}\s*[A-Za-z]|[A-Za-z]\s*\p{Han})"#, in: text)

        return [
            .averageSentenceLength: Double(scalars) / Double(max(1, sentences.count)),
            .averageParagraphLength: Double(scalars) / Double(max(1, paragraphs.count)),
            .lineBreakDensity: Double(text.filter { $0 == "\n" }.count) / Double(scalars),
            .listUsage: Double(listLines.count) / Double(max(1, nonemptyLines.count)),
            .headingUsage: Double(headingLines.count) / Double(max(1, nonemptyLines.count)),
            .fillerRetention: Double(fillers) / Double(scalars),
            .terminalPunctuationUsage: Double(terminalPunctuation) / Double(max(1, nonemptyLines.count)),
            .exclamationUsage: Double(exclamations) / Double(scalars),
            .chineseEnglishSpacing: Double(spacedTransitions) / Double(max(1, allTransitions)),
            .compactness: Double(scalars),
        ]
    }

    private static func isSafeStyleEdit(input: String, output: String) -> Bool {
        let guardedInput = removingStructuralListMarkers(from: input)
        let guardedOutput = removingStructuralListMarkers(from: output)
        if case .reject = IntelliSenseOutputGuard.evaluate(
            input: guardedInput,
            output: guardedOutput
        ) {
            return false
        }
        let delta = abs(output.count - input.count)
        return delta <= max(24, input.count / 3)
    }

    private static func containsFactSensitiveToken(_ text: String) -> Bool {
        let pattern = #"(?:https?://|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|(?:/[^\s/]+){2,}|\b\d+(?:[.,:/-]\d+)*(?:%|元|美元|万|亿)?\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return true
        }
        let value = removingStructuralListMarkers(from: text)
        return regex.firstMatch(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        ) != nil
    }

    private static func removingStructuralListMarkers(from text: String) -> String {
        let pattern = #"(?m)^\s*(?:\d+[.)、]|[一二三四五六七八九十]+[、.)）])\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: ""
        )
    }

    private static func matches(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> Int {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }
}

actor ExpressionProfileStore {
    static let shared = ExpressionProfileStore()

    let fileURL: URL
    private let thresholds: ExpressionLearningThresholds
    private var cached: ExpressionProfileDocument?

    init(fileURL: URL? = nil, thresholds: ExpressionLearningThresholds = .production) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = AppDataLocation.directory
            self.fileURL = directory.appendingPathComponent("intelli-sense-expression-profile.json")
        }
        self.thresholds = thresholds
    }

    func record(_ observation: ExpressionObservation) throws {
        var document = loadDocument()
        guard document.expressionLearningResetAt.map({ observation.createdAt > $0 }) ?? true,
              let sample = ExpressionFeatureExtractor.extract(observation)
        else { return }
        update(&document.global, sample: sample, at: observation.createdAt)
        update(&document.categories[observation.appCategory.rawValue, default: ScopeExpressionProfile()], sample: sample, at: observation.createdAt)
        if let bundleID = normalizedBundleID(observation.appBundleIdentifier) {
            update(&document.applications[bundleID, default: ScopeExpressionProfile()], sample: sample, at: observation.createdAt)
        }
        try persist(document)
        cached = document
    }

    func effectiveProfile(
        bundleIdentifier: String?,
        category: ApplicationCategory
    ) -> EffectiveExpressionProfile? {
        let document = loadDocument()
        let application = normalizedBundleID(bundleIdentifier).flatMap { document.applications[$0] }
        let categoryProfile = document.categories[category.rawValue]
        var resolved: [ExpressionFeature: FeatureAccumulator] = [:]
        var sourceScopes = Set<String>()
        for feature in ExpressionFeature.allCases {
            let key = feature.rawValue
            if let value = application?.features[key], value.state == .stable {
                resolved[feature] = value
                sourceScopes.insert("application")
            } else if let value = categoryProfile?.features[key], value.state == .stable {
                resolved[feature] = value
                sourceScopes.insert("category")
            } else if let value = document.global.features[key], value.state == .stable {
                resolved[feature] = value
                sourceScopes.insert("global")
            }
        }
        let directives = directives(from: resolved)
        let sourceScope = sourceScopes.count == 1 ? sourceScopes.first : (sourceScopes.isEmpty ? nil : "mixed")
        return directives.isEmpty ? nil : EffectiveExpressionProfile(
            directives: Array(directives.prefix(5)),
            sourceScope: sourceScope
        )
    }

    func clear(at date: Date = Date()) throws {
        var empty = ExpressionProfileDocument()
        empty.expressionLearningResetAt = date
        try persist(empty)
        cached = empty
    }

    func rebuild(from records: [HistoryRecord]) throws {
        let previous = loadDocument()
        var rebuilt = ExpressionProfileDocument()
        rebuilt.expressionLearningResetAt = previous.expressionLearningResetAt
        for record in records {
            guard let edited = record.userEditedText,
                  record.userEditVersion == UserEditObservationFormat.currentVersion,
                  record.userEditStatus == .edited || record.userEditStatus == .clearedAfterEdit,
                  rebuilt.expressionLearningResetAt.map({ record.createdAt > $0 }) ?? true
            else { continue }
            let classification = UserEditClassifier.classify(
                original: record.finalText,
                edited: edited
            )
            guard classification == .expressionEdit || classification == .mixedEdit else {
                continue
            }
            let observation = ExpressionObservation(
                sessionID: record.id,
                createdAt: record.userEditObservedAt ?? record.createdAt,
                appBundleIdentifier: nil,
                appCategory: .other,
                sourceText: record.rawText,
                injectedText: record.finalText,
                finalObservedText: edited,
                correctionCandidateRange: nil
            )
            guard let sample = ExpressionFeatureExtractor.extract(observation) else { continue }
            update(&rebuilt.global, sample: sample, at: observation.createdAt)
            update(
                &rebuilt.categories[ApplicationCategory.other.rawValue, default: ScopeExpressionProfile()],
                sample: sample,
                at: observation.createdAt
            )
        }
        try persist(rebuilt)
        cached = rebuilt
    }

    func documentForTesting() -> ExpressionProfileDocument { loadDocument() }

    private func loadDocument() -> ExpressionProfileDocument {
        if let cached { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode(ExpressionProfileDocument.self, from: data),
              decoded.schemaVersion == 1
                || decoded.schemaVersion == ExpressionProfileDocument.currentSchemaVersion
        else {
            let empty = ExpressionProfileDocument()
            cached = empty
            return empty
        }
        if decoded.schemaVersion == 1 {
            var migrated = decoded
            migrated.schemaVersion = ExpressionProfileDocument.currentSchemaVersion
            resetListUsage(in: &migrated.global)
            for key in Array(migrated.categories.keys) {
                resetListUsage(in: &migrated.categories[key, default: ScopeExpressionProfile()])
            }
            for key in Array(migrated.applications.keys) {
                resetListUsage(in: &migrated.applications[key, default: ScopeExpressionProfile()])
            }
            try? persist(migrated)
            cached = migrated
            return migrated
        }
        cached = decoded
        return decoded
    }

    private func update(
        _ profile: inout ScopeExpressionProfile,
        sample: ExpressionFeatureSample,
        at date: Date
    ) {
        profile.sampleCount += 1
        if sample.wasEdited { profile.editedSampleCount += 1 }
        profile.firstObservedAt = min(profile.firstObservedAt ?? date, date)
        profile.lastObservedAt = max(profile.lastObservedAt ?? date, date)
        let weight = sample.wasEdited ? thresholds.editedWeight : thresholds.acceptedWeight

        for feature in ExpressionFeature.allCases {
            guard let value = sample.values[feature] else { continue }
            var accumulator = profile.features[feature.rawValue] ?? FeatureAccumulator()
            applyDecay(to: &accumulator, at: date)
            let newWeight = accumulator.totalWeight + weight
            accumulator.weightedMean = newWeight > 0
                ? ((accumulator.weightedMean * accumulator.totalWeight) + value * weight) / newWeight
                : value
            accumulator.totalWeight = newWeight
            switch sample.directions[feature] ?? 0 {
            case 1: accumulator.positiveEvidence += 1
            case -1: accumulator.negativeEvidence += 1
            default: accumulator.acceptedEvidence += 1
            }
            accumulator.firstObservedAt = min(accumulator.firstObservedAt ?? date, date)
            accumulator.updatedAt = date
            accumulator.state = learningState(
                for: accumulator,
                feature: feature,
                profile: profile
            )
            profile.features[feature.rawValue] = accumulator
        }
    }

    private func learningState(
        for accumulator: FeatureAccumulator,
        feature: ExpressionFeature,
        profile: ScopeExpressionProfile
    ) -> FeatureLearningState {
        if feature == .listUsage {
            let evidence = accumulator.positiveEvidence
                + accumulator.negativeEvidence
                + accumulator.acceptedEvidence
            guard evidence >= thresholds.learningSamples else { return .insufficient }
            guard evidence >= thresholds.stableSamples,
                  let first = accumulator.firstObservedAt,
                  Calendar.current.dateComponents(
                      [.day],
                      from: first,
                      to: accumulator.updatedAt
                  ).day ?? 0 >= thresholds.stableDaySpan
            else { return .learning }
        } else {
            guard profile.sampleCount >= thresholds.learningSamples else { return .insufficient }
            guard profile.sampleCount >= thresholds.stableSamples,
                  let first = profile.firstObservedAt,
                  let last = profile.lastObservedAt,
                  Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0 >= thresholds.stableDaySpan
            else { return .learning }
        }
        let directional = accumulator.positiveEvidence + accumulator.negativeEvidence
        if directional == 0 { return .stable }
        let dominant = max(accumulator.positiveEvidence, accumulator.negativeEvidence)
        let requiredConsistency = accumulator.state == .stable
            ? thresholds.stableExitConsistency
            : thresholds.directionalConsistency
        return Double(dominant) / Double(directional) >= requiredConsistency ? .stable : .learning
    }

    private func applyDecay(to accumulator: inout FeatureAccumulator, at date: Date) {
        guard accumulator.updatedAt != .distantPast,
              thresholds.decayHalfLifeDays > 0
        else { return }
        let elapsedDays = max(0, date.timeIntervalSince(accumulator.updatedAt) / 86_400)
        guard elapsedDays > 0 else { return }
        let factor = pow(0.5, elapsedDays / thresholds.decayHalfLifeDays)
        accumulator.totalWeight *= factor
        // Evidence remains integer and privacy-preserving; periodically reducing
        // it provides the same old-sample fade without persisting raw sessions.
        accumulator.positiveEvidence = Int((Double(accumulator.positiveEvidence) * factor).rounded())
        accumulator.negativeEvidence = Int((Double(accumulator.negativeEvidence) * factor).rounded())
        accumulator.acceptedEvidence = Int((Double(accumulator.acceptedEvidence) * factor).rounded())
    }

    private func directives(from values: [ExpressionFeature: FeatureAccumulator]) -> [String] {
        var output: [String] = []
        if let value = values[.averageSentenceLength]?.weightedMean {
            if value < 22 { output.append("倾向短句，避免把多个意思合成长句。") }
            else if value > 42 { output.append("保留自然完整的长句，不做不必要拆分。") }
        }
        if let value = values[.lineBreakDensity]?.weightedMean, value > 0.025 {
            output.append("保留自然分段。")
        }
        if let value = values[.listUsage]?.weightedMean {
            if value > 0.2 { output.append("口述包含多个明确要点时，倾向使用简洁列表。") }
            else if value < 0.03 { output.append("倾向连续自然段，减少列表。") }
        }
        if let value = values[.terminalPunctuationUsage]?.weightedMean {
            output.append(value >= 0.65 ? "保留句末标点。" : "非正式短句通常省略句末标点。")
        }
        if let value = values[.exclamationUsage]?.weightedMean, value > 0.02 {
            output.append("保留原本表达出的感叹语气。")
        }
        if let value = values[.chineseEnglishSpacing]?.weightedMean {
            output.append(value >= 0.65 ? "中文与英文之间倾向保留空格。" : "不要自动在中文与英文之间添加空格。")
        }
        return output
    }

    private func persist(_ document: ExpressionProfileDocument) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }

    private func resetListUsage(in profile: inout ScopeExpressionProfile) {
        profile.features.removeValue(forKey: ExpressionFeature.listUsage.rawValue)
    }

    private func normalizedBundleID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }
}
