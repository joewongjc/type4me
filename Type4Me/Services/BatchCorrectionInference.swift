import Foundation

struct CorrectionEvidence: Equatable, Sendable {
    let recordID: String
    let observedAt: Date
    let bundleIdentifier: String?
    let wrongText: String
    let correctedText: String
    let normalizedKey: String
    let confidence: Double
}

enum BatchCorrectionSuggestionState: String, Codable, Sendable {
    case pending
    case accepted
    case ignored
    case conflicted
    case stale
}

struct BatchCorrectionSuggestion: Codable, Equatable, Identifiable, Sendable {
    var id: String { normalizedKey }
    let normalizedKey: String
    let wrongText: String
    let correctedText: String
    let evidenceRecordIDs: [String]
    let independentSessionCount: Int
    let firstObservedAt: Date
    let lastObservedAt: Date
    let directionalShare: Double
    var state: BatchCorrectionSuggestionState
}

struct BatchCorrectionInferenceThresholds: Equatable, Sendable {
    var minimumIndependentSessions = 3
    var minimumNaturalDays = 2
    var minimumDirectionalShare = 0.8
    var decayHalfLifeDays = UserEditObservationTiming.production.evidenceDecayHalfLifeDays

    static let production = Self()
}

enum BatchCorrectionInference {
    static func extractEvidence(
        from records: [HistoryRecord],
        chineseSegmenter: any ChineseWordSegmenting = HybridChineseWordSegmenter.shared
    ) async -> [CorrectionEvidence] {
        var evidence: [CorrectionEvidence] = []
        for record in records {
            guard record.userEditVersion == UserEditObservationFormat.currentVersion,
                  record.userEditStatus == .edited || record.userEditStatus == .clearedAfterEdit,
                  let edited = record.userEditedText,
                  !record.finalText.isEmpty,
                  !edited.isEmpty,
                  !UserEditClassifier.isSensitive(record.finalText),
                  !UserEditClassifier.isSensitive(edited)
            else { continue }
            let result = await ImmediateCorrectionAnalyzer.analyze(
                original: record.finalText,
                edited: edited,
                chineseSegmenter: chineseSegmenter
            )
            guard case .candidate(let wrong, let corrected) = result else { continue }
            evidence.append(CorrectionEvidence(
                recordID: record.id,
                observedAt: record.userEditObservedAt ?? record.createdAt,
                bundleIdentifier: nil,
                wrongText: wrong,
                correctedText: corrected,
                normalizedKey: normalizedPairKey(wrong: wrong, corrected: corrected),
                confidence: 1
            ))
        }
        return evidence
    }

    static func infer(
        from evidence: [CorrectionEvidence],
        now: Date = Date(),
        thresholds: BatchCorrectionInferenceThresholds = .production,
        ignoredKeys: Set<String> = []
    ) -> [BatchCorrectionSuggestion] {
        let unique = Dictionary(evidence.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
            .values
        let groupedByWrong = Dictionary(grouping: unique) { item in
            normalizedText(item.wrongText)
        }
        var suggestions: [BatchCorrectionSuggestion] = []
        for (_, wrongEvidence) in groupedByWrong {
            let byPair = Dictionary(grouping: wrongEvidence, by: \.normalizedKey)
            let weightedTotal = wrongEvidence.reduce(0.0) { partial, item in
                partial + decayedWeight(for: item, now: now, halfLifeDays: thresholds.decayHalfLifeDays)
            }
            guard weightedTotal > 0 else { continue }
            let ranked = byPair.map { key, items in
                (
                    key: key,
                    items: items,
                    weight: items.reduce(0.0) { partial, item in
                        partial + decayedWeight(
                            for: item,
                            now: now,
                            halfLifeDays: thresholds.decayHalfLifeDays
                        )
                    }
                )
            }.sorted { $0.weight > $1.weight }
            guard let winner = ranked.first else { continue }
            let share = winner.weight / weightedTotal
            let days = Set(winner.items.map { Calendar.current.startOfDay(for: $0.observedAt) })
            let hasEquivalentConflict = ranked.dropFirst().first.map {
                abs($0.weight - winner.weight) < 0.000_001
            } ?? false
            let state: BatchCorrectionSuggestionState
            if ignoredKeys.contains(winner.key) {
                continue
            } else if hasEquivalentConflict {
                state = .conflicted
            } else if winner.items.count >= thresholds.minimumIndependentSessions,
                      days.count >= thresholds.minimumNaturalDays,
                      share >= thresholds.minimumDirectionalShare {
                state = .pending
            } else {
                continue
            }
            guard let representative = winner.items.max(by: { $0.observedAt < $1.observedAt }),
                  let first = winner.items.map(\.observedAt).min(),
                  let last = winner.items.map(\.observedAt).max()
            else { continue }
            suggestions.append(BatchCorrectionSuggestion(
                normalizedKey: winner.key,
                wrongText: representative.wrongText,
                correctedText: representative.correctedText,
                evidenceRecordIDs: winner.items.map(\.recordID).sorted(),
                independentSessionCount: winner.items.count,
                firstObservedAt: first,
                lastObservedAt: last,
                directionalShare: share,
                state: state
            ))
        }
        return suggestions.sorted { $0.lastObservedAt > $1.lastObservedAt }
    }

    static func normalizedPairKey(wrong: String, corrected: String) -> String {
        normalizedText(wrong) + "\u{001F}" + normalizedText(corrected)
    }

    private static func normalizedText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func decayedWeight(
        for evidence: CorrectionEvidence,
        now: Date,
        halfLifeDays: Double
    ) -> Double {
        guard halfLifeDays > 0 else { return evidence.confidence }
        let days = max(0, now.timeIntervalSince(evidence.observedAt) / 86_400)
        return evidence.confidence * pow(0.5, days / halfLifeDays)
    }
}

actor BatchCorrectionSuggestionStore {
    static let shared = BatchCorrectionSuggestionStore()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = AppDataLocation.directory
            self.fileURL = directory.appendingPathComponent("batch-correction-suggestions-v1.json")
        }
    }

    func load() -> [BatchCorrectionSuggestion] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BatchCorrectionSuggestion].self, from: data)) ?? []
    }

    func save(_ suggestions: [BatchCorrectionSuggestion]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(suggestions).write(to: fileURL, options: .atomic)
    }

    func ignore(normalizedKey: String) throws {
        var suggestions = load()
        guard let index = suggestions.firstIndex(where: { $0.normalizedKey == normalizedKey }) else {
            return
        }
        suggestions[index].state = .ignored
        try save(suggestions)
    }

    func accept(normalizedKey: String) async throws {
        var suggestions = load()
        guard let index = suggestions.firstIndex(where: { $0.normalizedKey == normalizedKey }) else {
            return
        }
        let suggestion = suggestions[index]
        let candidate = CorrectionCandidate(
            wrongText: suggestion.wrongText,
            correctedText: suggestion.correctedText,
            sourceRecordID: suggestion.evidenceRecordIDs.first ?? "batch",
            bundleIdentifier: ""
        )
        try CorrectionLearningStore().learn(candidate)
        await HybridChineseWordSegmenter.shared.insertConfirmedUserWord(
            suggestion.correctedText
        )
        suggestions[index].state = .accepted
        try save(suggestions)
    }
}

actor BatchCorrectionInferenceCoordinator {
    static let shared = BatchCorrectionInferenceCoordinator()

    private var pendingTask: Task<Void, Never>?

    func schedule(
        historyStore: HistoryStore,
        suggestionStore: BatchCorrectionSuggestionStore = .shared,
        delay: Duration = .seconds(5)
    ) {
        pendingTask?.cancel()
        pendingTask = Task(priority: .background) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let records = await historyStore.fetchUserEditEvidenceRecords()
            let evidence = await BatchCorrectionInference.extractEvidence(from: records)
            let inferred = BatchCorrectionInference.infer(from: evidence)
            let existing = await suggestionStore.load()
            let protected = Dictionary(
                uniqueKeysWithValues: existing
                    .filter { $0.state == .accepted || $0.state == .ignored }
                    .map { ($0.normalizedKey, $0) }
            )
            let merged = inferred.map { suggestion in
                guard let prior = protected[suggestion.normalizedKey] else { return suggestion }
                if prior.state == .accepted { return prior }
                let previousEvidence = Set(prior.evidenceRecordIDs)
                let newEvidence = Set(suggestion.evidenceRecordIDs).subtracting(previousEvidence)
                guard newEvidence.count >= BatchCorrectionInferenceThresholds
                    .production.minimumIndependentSessions
                else { return prior }
                return suggestion
            } + protected.values.filter { protectedSuggestion in
                !inferred.contains { $0.normalizedKey == protectedSuggestion.normalizedKey }
            }
            do {
                try await suggestionStore.save(merged.sorted { $0.lastObservedAt > $1.lastObservedAt })
            } catch {
                DebugFileLogger.log("batch correction suggestion save failed")
            }
        }
    }
}
