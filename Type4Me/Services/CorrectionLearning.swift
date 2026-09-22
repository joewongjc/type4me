import AppKit
import ApplicationServices
import Foundation
import Type4MeIntelliSenseCore

struct TrackedInjectionContext: @unchecked Sendable {
    let element: AXUIElement
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let baselineValue: String
    let injectedRange: NSRange
    let beforeSelectedRange: NSRange?
    let afterSelectedRange: NSRange?
    let placeholderCandidates: [String]
    let sourceText: String
    let injectedText: String
    let sourceRecordID: String
    let modeID: UUID
    let createdAt: Date

    init(
        element: AXUIElement,
        processIdentifier: pid_t,
        bundleIdentifier: String,
        baselineValue: String,
        injectedRange: NSRange,
        beforeSelectedRange: NSRange?,
        afterSelectedRange: NSRange?,
        placeholderCandidates: [String],
        sourceText: String,
        injectedText: String,
        sourceRecordID: String,
        modeID: UUID,
        createdAt: Date = Date()
    ) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.baselineValue = baselineValue
        self.injectedRange = injectedRange
        self.beforeSelectedRange = beforeSelectedRange
        self.afterSelectedRange = afterSelectedRange
        self.placeholderCandidates = placeholderCandidates
        self.sourceText = sourceText
        self.injectedText = injectedText
        self.sourceRecordID = sourceRecordID
        self.modeID = modeID
        self.createdAt = createdAt
    }
}

typealias CorrectionObservationContext = TrackedInjectionContext

struct TrackedInjectionResult: @unchecked Sendable {
    let outcome: InjectionOutcome
    let context: TrackedInjectionContext?

    var observationContext: TrackedInjectionContext? { context }

    init(outcome: InjectionOutcome, context: TrackedInjectionContext?) {
        self.outcome = outcome
        self.context = context
    }

    init(outcome: InjectionOutcome, observationContext: TrackedInjectionContext?) {
        self.outcome = outcome
        self.context = observationContext
    }
}

struct CorrectionCandidate: Equatable, Sendable {
    let wrongText: String
    let correctedText: String
    let sourceRecordID: String
    let bundleIdentifier: String
}

enum CorrectionDiffRejection: String, Equatable, Sendable {
    case unchanged
    case invalidRange
    case noChangeInsideInjection
    case multipleChanges
    case pureInsertionOrDeletion
    case ambiguousCJKReplacement
    case invalidCandidate
    case lowAffinity
    case sensitiveContent
}

enum CorrectionDiffResult: Equatable, Sendable {
    case candidate(wrongText: String, correctedText: String)
    case rejected(CorrectionDiffRejection)
}

/// Pure, deterministic analysis of changes made after Type4Me injected text.
enum CorrectionDiffAnalyzer {
    private struct EditHunk {
        var oldStart: Int
        var oldEnd: Int
        var newStart: Int
        var newEnd: Int
    }

    static func analyze(
        baseline: String,
        injectedRange: NSRange,
        current: String
    ) -> CorrectionDiffResult {
        guard baseline != current else { return .rejected(.unchanged) }
        guard let baselineRange = Range(injectedRange, in: baseline) else {
            return .rejected(.invalidRange)
        }

        let old = Array(baseline)
        let new = Array(current)
        let injectionStart = baseline.distance(from: baseline.startIndex, to: baselineRange.lowerBound)
        let injectionEnd = baseline.distance(from: baseline.startIndex, to: baselineRange.upperBound)

        guard let hunks = editHunks(old: old, new: new) else {
            return .rejected(.multipleChanges)
        }

        let inside = hunks.filter { hunk in
            if hunk.oldStart == hunk.oldEnd {
                return hunk.oldStart > injectionStart && hunk.oldStart < injectionEnd
            }
            return hunk.oldStart < injectionEnd && hunk.oldEnd > injectionStart
        }
        guard !inside.isEmpty else { return .rejected(.noChangeInsideInjection) }
        guard var hunk = mergedLexicalHunk(inside, old: old, new: new) else {
            return .rejected(.multipleChanges)
        }

        if isSensitiveChange(in: baseline, characterRange: hunk.oldStart..<hunk.oldEnd)
            || isSensitiveChange(in: current, characterRange: hunk.newStart..<hunk.newEnd) {
            return .rejected(.sensitiveContent)
        }

        let rawRemoved = Array(old[hunk.oldStart..<hunk.oldEnd])
        let rawInserted = Array(new[hunk.newStart..<hunk.newEnd])
        if !rawRemoved.isEmpty,
           !rawInserted.isEmpty,
           !(rawRemoved + rawInserted).contains(where: isLearnableCharacter) {
            return .rejected(.invalidCandidate)
        }
        let isCJKReplacement = !rawRemoved.isEmpty
            && !rawInserted.isEmpty
            && rawRemoved.allSatisfy(isCJK)
            && rawInserted.allSatisfy(isCJK)
        let isMixedScriptReplacement = isCJKLatinReplacement(
            removed: rawRemoved,
            inserted: rawInserted
        )
        if isMixedScriptReplacement {
            let cjkLength = rawRemoved.allSatisfy(isCJK) ? rawRemoved.count : rawInserted.count
            let latinLength = rawRemoved.allSatisfy(isCJK) ? rawInserted.count : rawRemoved.count
            guard cjkLength >= 2, latinLength >= 2 else {
                return .rejected(.ambiguousCJKReplacement)
            }
        }

        // A multi-character Chinese replacement already carries a useful word
        // boundary. Expanding it with arbitrary neighboring Han characters is
        // what turned “加好 → 佳豪” into “人的加好程度 → 人的佳豪程度”.
        // A single-character Chinese diff has no reliable word boundary, so V1
        // skips it rather than learning a dangerously broad mapping.
        if isCJKReplacement {
            guard rawRemoved.count >= 2, rawInserted.count >= 2 else {
                return .rejected(.ambiguousCJKReplacement)
            }
        } else if rawRemoved.isEmpty || rawInserted.isEmpty {
            let changedCharacters = rawRemoved + rawInserted
            let neighbors = [
                adjacentCharacter(in: old, before: hunk.oldStart),
                adjacentCharacter(in: old, at: hunk.oldEnd),
                adjacentCharacter(in: new, before: hunk.newStart),
                adjacentCharacter(in: new, at: hunk.newEnd),
            ].compactMap { $0 }
            // A one-sided diff is valid only when it edits the interior or edge
            // of an existing Latin/technical token. Adding/removing a whole
            // word necessarily includes a hard boundary and stays rejected.
            let changesTokenInterior = !changedCharacters.isEmpty
                && changedCharacters.allSatisfy(isTechnicalTokenCharacter)
                && neighbors.contains(where: isLatinTokenCharacter)
            let mergesOrSplitsTechnicalToken = !changedCharacters.isEmpty
                && changedCharacters.allSatisfy(\.isWhitespace)
                && neighbors.filter(isLatinTokenCharacter).count >= 2
            guard changesTokenInterior || mergesOrSplitsTechnicalToken,
                  !neighbors.contains(where: isCJK)
            else { return .rejected(.pureInsertionOrDeletion) }
        }

        // A Han transliteration corrected to a Latin technical/name token (or
        // the reverse) already has a hard script boundary. Expanding through
        // Character.isLetter is unsafe because Swift correctly treats Han as
        // letters too, which previously turned “杰瑞 → Jerry” into a whole-
        // sentence replacement candidate.
        let shouldExpandContext = !isCJKReplacement && !isMixedScriptReplacement
        let contextLimit = shouldExpandContext ? 64 : 0

        var leftExpansion = 0
        while hunk.oldStart > injectionStart,
              hunk.newStart > 0,
              leftExpansion < contextLimit {
            let oldCharacter = old[hunk.oldStart - 1]
            let newCharacter = new[hunk.newStart - 1]
            guard oldCharacter == newCharacter,
                  shouldExpand(over: oldCharacter, cjkMode: false)
            else { break }
            hunk.oldStart -= 1
            hunk.newStart -= 1
            leftExpansion += 1
        }

        var rightExpansion = 0
        while hunk.oldEnd < injectionEnd,
              hunk.newEnd < new.count,
              rightExpansion < contextLimit {
            let oldCharacter = old[hunk.oldEnd]
            let newCharacter = new[hunk.newEnd]
            guard oldCharacter == newCharacter,
                  shouldExpand(over: oldCharacter, cjkMode: false)
            else { break }
            hunk.oldEnd += 1
            hunk.newEnd += 1
            rightExpansion += 1
        }

        let wrong = String(old[hunk.oldStart..<hunk.oldEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = String(new[hunk.newStart..<hunk.newEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidCandidate(wrong), isValidCandidate(corrected), wrong != corrected else {
            return .rejected(.invalidCandidate)
        }
        guard !isSensitive(wrong), !isSensitive(corrected) else {
            return .rejected(.sensitiveContent)
        }
        if wrong.contains(where: isLatinTokenCharacter)
            || corrected.contains(where: isLatinTokenCharacter) {
            guard TechnicalTokenBoundaryResolver.isSingleStableToken(wrong),
                  TechnicalTokenBoundaryResolver.isSingleStableToken(corrected)
            else { return .rejected(.invalidCandidate) }
        }
        // Edit distance is not meaningful across writing systems: every
        // character in “杰瑞 → Jerry” differs even though it is a compact
        // lexical correction. ImmediateCorrectionAnalyzer separately verifies
        // the Han token boundary with the hybrid segmenter.
        if !isMixedScriptReplacement {
            let maximumLength = max(wrong.count, corrected.count)
            let maximumDistance = max(3, Int(ceil(Double(maximumLength) * 0.4)))
            guard editDistance(wrong, corrected) <= maximumDistance else {
                return .rejected(.invalidCandidate)
            }
        }
        return .candidate(wrongText: wrong, correctedText: corrected)
    }

    private static func mergedLexicalHunk(
        _ hunks: [EditHunk],
        old: [Character],
        new: [Character]
    ) -> EditHunk? {
        guard var merged = hunks.first else { return nil }
        for next in hunks.dropFirst() {
            let oldGap = next.oldStart >= merged.oldEnd
                ? Array(old[merged.oldEnd..<next.oldStart])
                : []
            let newGap = next.newStart >= merged.newEnd
                ? Array(new[merged.newEnd..<next.newStart])
                : []
            let gapIsWithinOneLexicalUnit = oldGap.count <= 4
                && newGap.count <= 4
                && oldGap.allSatisfy(isLearnableCharacter)
                && newGap.allSatisfy(isLearnableCharacter)
            guard gapIsWithinOneLexicalUnit else { return nil }
            merged.oldEnd = max(merged.oldEnd, next.oldEnd)
            merged.newEnd = max(merged.newEnd, next.newEnd)
        }
        return merged
    }

    private static func editHunks(old: [Character], new: [Character]) -> [EditHunk]? {
        let difference = new.difference(from: old)
        let removals = Set(difference.compactMap { change -> Int? in
            guard case .remove(let offset, _, _) = change else { return nil }
            return offset
        })
        let insertions = Set(difference.compactMap { change -> Int? in
            guard case .insert(let offset, _, _) = change else { return nil }
            return offset
        })

        var oldIndex = 0
        var newIndex = 0
        var hunks: [EditHunk] = []
        var active: EditHunk?

        func flush() {
            if let active {
                hunks.append(active)
            }
            active = nil
        }

        while oldIndex < old.count || newIndex < new.count {
            var edited = false
            if newIndex < new.count, insertions.contains(newIndex) {
                if active == nil {
                    active = EditHunk(
                        oldStart: oldIndex, oldEnd: oldIndex,
                        newStart: newIndex, newEnd: newIndex
                    )
                }
                active?.newEnd = newIndex + 1
                newIndex += 1
                edited = true
            }
            if oldIndex < old.count, removals.contains(oldIndex) {
                if active == nil {
                    active = EditHunk(
                        oldStart: oldIndex, oldEnd: oldIndex,
                        newStart: newIndex, newEnd: newIndex
                    )
                }
                active?.oldEnd = oldIndex + 1
                oldIndex += 1
                edited = true
            }
            if edited { continue }

            guard oldIndex < old.count, newIndex < new.count, old[oldIndex] == new[newIndex] else {
                return nil
            }
            flush()
            oldIndex += 1
            newIndex += 1
        }
        flush()
        return hunks
    }

    private static func adjacentCharacter(in characters: [Character], before index: Int) -> Character? {
        guard index > 0, index <= characters.count else { return nil }
        return characters[index - 1]
    }

    private static func adjacentCharacter(in characters: [Character], at index: Int) -> Character? {
        guard index >= 0, index < characters.count else { return nil }
        return characters[index]
    }

    private static func shouldExpand(over character: Character, cjkMode: Bool) -> Bool {
        if cjkMode { return isCJK(character) }
        return character.isLetter || character.isNumber || character == "_"
    }

    private static func isLearnableCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || isCJK(character)
    }

    private static func isTechnicalTokenCharacter(_ character: Character) -> Bool {
        isLatinTokenCharacter(character) || ".-_+#".contains(character)
    }

    private static func isLatinTokenCharacter(_ character: Character) -> Bool {
        character.isNumber || character.unicodeScalars.allSatisfy { scalar in
            scalar.value < 128 && CharacterSet.letters.contains(scalar)
        }
    }

    private static func isCJKLatinReplacement(
        removed: [Character],
        inserted: [Character]
    ) -> Bool {
        guard !removed.isEmpty, !inserted.isEmpty else { return false }
        let removedIsCJK = removed.allSatisfy(isCJK)
        let insertedIsCJK = inserted.allSatisfy(isCJK)
        let removedIsLatin = removed.allSatisfy(isTechnicalTokenCharacter)
            && removed.contains(where: isLatinTokenCharacter)
        let insertedIsLatin = inserted.allSatisfy(isTechnicalTokenCharacter)
            && inserted.contains(where: isLatinTokenCharacter)
        return (removedIsCJK && insertedIsLatin)
            || (removedIsLatin && insertedIsCJK)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    private static func isValidCandidate(_ text: String) -> Bool {
        guard !text.contains("\n"), !text.contains("\r") else { return false }
        guard (2...64).contains(text.count) else { return false }
        guard text.split(whereSeparator: { $0.isWhitespace }).count <= 5 else { return false }
        return text.contains(where: isLearnableCharacter)
    }

    private static func isSensitive(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("://") || lowered.hasPrefix("www.") { return true }
        if matches(#"\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#, in: text) { return true }
        if matches(#"(?:\d[\s-]?){7,}"#, in: text) { return true }
        if matches(#"\b(?=[A-Za-z0-9_-]{20,}\b)(?=[A-Za-z0-9_-]*[A-Za-z])(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]+\b"#, in: text) {
            return true
        }
        return false
    }

    private static func isSensitiveChange(in text: String, characterRange: Range<Int>) -> Bool {
        let characters = Array(text)
        guard characterRange.lowerBound >= 0,
              characterRange.upperBound <= characters.count
        else { return true }
        let lowerIndex = text.index(text.startIndex, offsetBy: characterRange.lowerBound)
        let upperIndex = text.index(text.startIndex, offsetBy: characterRange.upperBound)
        let changedRange = NSRange(lowerIndex..<upperIndex, in: text)
        let patterns = [
            #"\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#,
            #"(?:https?://|www\.)\S+"#,
            #"(?:\d[\s-]?){7,}"#,
            #"\b(?=[A-Za-z0-9_-]{20,}\b)(?=[A-Za-z0-9_-]*[A-Za-z])(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]+\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: fullRange) {
                if changedRange.length == 0 {
                    if changedRange.location >= match.range.location,
                       changedRange.location <= NSMaxRange(match.range) {
                        return true
                    }
                } else if NSIntersectionRange(changedRange, match.range).length > 0 {
                    return true
                }
            }
        }
        return false
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.precomposedStringWithCanonicalMapping)
        let right = Array(rhs.precomposedStringWithCanonicalMapping)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitution = previous[rightIndex]
                    + (leftCharacter == rightCharacter ? 0 : 1)
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    substitution
                )
            }
            previous = current
        }
        return previous[right.count]
    }
}

struct CorrectionMapping: Equatable, Sendable {
    let trigger: String
    let replacement: String
}

protocol CorrectionVocabularyPersisting {
    func loadHotwords() -> [String]
    func loadMappings() -> [CorrectionMapping]
    func saveHotwords(_ words: [String]) throws
    func saveMappings(_ mappings: [CorrectionMapping]) throws
}

struct Type4MeCorrectionVocabularyPersistence: CorrectionVocabularyPersisting {
    func loadHotwords() -> [String] { HotwordStorage.load() }
    func loadMappings() -> [CorrectionMapping] {
        SnippetStorage.load().map { CorrectionMapping(trigger: $0.trigger, replacement: $0.value) }
    }
    func saveHotwords(_ words: [String]) throws { try HotwordStorage.saveOrThrow(words) }
    func saveMappings(_ mappings: [CorrectionMapping]) throws {
        try SnippetStorage.saveOrThrow(mappings.map { (trigger: $0.trigger, value: $0.replacement) })
    }
}

struct CorrectionLearningStore {
    let persistence: any CorrectionVocabularyPersisting

    init(persistence: any CorrectionVocabularyPersisting = Type4MeCorrectionVocabularyPersistence()) {
        self.persistence = persistence
    }

    func learn(_ candidate: CorrectionCandidate) throws {
        let oldHotwords = persistence.loadHotwords()
        let oldMappings = persistence.loadMappings()

        var newHotwords = oldHotwords
        if !newHotwords.contains(where: { $0.caseInsensitiveCompare(candidate.correctedText) == .orderedSame }) {
            newHotwords.append(candidate.correctedText)
        }

        var newMappings = oldMappings
        if let index = newMappings.firstIndex(where: {
            $0.trigger.caseInsensitiveCompare(candidate.wrongText) == .orderedSame
        }) {
            newMappings[index] = CorrectionMapping(
                trigger: candidate.wrongText,
                replacement: candidate.correctedText
            )
        } else {
            newMappings.append(CorrectionMapping(
                trigger: candidate.wrongText,
                replacement: candidate.correctedText
            ))
        }

        let hotwordsChanged = newHotwords != oldHotwords
        let mappingsChanged = newMappings != oldMappings
        guard hotwordsChanged || mappingsChanged else { return }

        do {
            if hotwordsChanged { try persistence.saveHotwords(newHotwords) }
            do {
                if mappingsChanged { try persistence.saveMappings(newMappings) }
            } catch {
                if hotwordsChanged { try? persistence.saveHotwords(oldHotwords) }
                throw error
            }
        } catch {
            throw error
        }
    }
}

struct PostInjectionLearningOptions: Equatable, Sendable {
    var correctionEnabled: Bool
    var expressionLearningEnabled: Bool
    var appCategory: ApplicationCategory
}

struct PostInjectionLearningPlan: Equatable, Sendable {
    let correctionEnabled: Bool
    let expressionLearningEnabled: Bool

    var shouldTrackInjection: Bool {
        correctionEnabled || expressionLearningEnabled
    }

    static func isBaseEligible(
        settings: IntelliSenseSettings?,
        modeID: UUID,
        startedModeID: UUID?,
        isCrossModeFallback: Bool,
        aborted: Bool,
        guardRejected: Bool,
        contextAvailability: ContextAvailability?
    ) -> Bool {
        guard !aborted,
              !guardRejected,
              contextAvailability != .sensitive,
              modeID == ProcessingMode.intelliSenseId,
              let settings else { return false }

        let correctionEligible = settings.correctionDetectionEnabled
        let expressionEligible = settings.expressionLearningEnabled
            && !isCrossModeFallback
            && startedModeID == ProcessingMode.intelliSenseId

        return correctionEligible || expressionEligible
    }

    static func resolve(
        settings: IntelliSenseSettings?,
        modeID: UUID,
        startedModeID: UUID?,
        isCrossModeFallback: Bool,
        aborted: Bool,
        guardRejected: Bool,
        contextAvailability: ContextAvailability?,
        targetBundleIdentifier: String?
    ) -> Self {
        let isBase = isBaseEligible(
            settings: settings,
            modeID: modeID,
            startedModeID: startedModeID,
            isCrossModeFallback: isCrossModeFallback,
            aborted: aborted,
            guardRejected: guardRejected,
            contextAvailability: contextAvailability
        )
        let blocked = contextAvailability == .blacklisted
            || settings?.isBlacklisted(bundleIdentifier: targetBundleIdentifier) == true
        let common = isBase && !blocked
        return Self(
            correctionEnabled: common && settings?.correctionDetectionEnabled == true,
            expressionLearningEnabled: common
                && settings?.expressionLearningEnabled == true
                && !isCrossModeFallback
                && startedModeID == ProcessingMode.intelliSenseId
        )
    }
}

@MainActor
final class PostInjectionLearningCoordinator: NSObject {
    static let shared = PostInjectionLearningCoordinator()

    nonisolated static let enabledDefaultsKey = "tf_autoCorrectionLearningEnabled"

    private struct ActiveObservation {
        let context: CorrectionObservationContext
        let observer: AXObserver
        let observesElementDestruction: Bool
        var options: PostInjectionLearningOptions
        let startedAt: Date
        let baselineVisibleValue: String
        let visibleInjectedRange: NSRange
        let visibleInjectedText: String
        var lastRawFullValue: String
        var lastVisibleFullValue: String
        var lastReliableVisibleInjectedText: String
        var lastReliableObservedAt: Date
        var latestResolution: InjectedTextResolution
        var hasObservedVisibleChanges: Bool
        var lastSelectedRange: NSRange?
    }

    private struct PendingCorrectionCandidate {
        let candidate: CorrectionCandidate
        let observedText: String
    }

    private var active: ActiveObservation?
    private var timeoutTask: Task<Void, Never>?
    private var stableWindowTask: Task<Void, Never>?
    private var readRetryTask: Task<Void, Never>?
    private var candidatePresentationTask: Task<Void, Never>?
    private var pendingCorrectionCandidate: PendingCorrectionCandidate?
    private var handledCorrectionCandidate: CorrectionCandidate?
    /// Keep the panel truly lazy. `cancelObservation()` runs at the start of
    /// every recording, including when correction learning is disabled; using
    /// a Swift `lazy` property there would still instantiate its NSHostingView.
    private var panelController: CorrectionLearningPanelController?
    private let learningStore = CorrectionLearningStore()
    private let historyStore: HistoryStore
    private let timing: UserEditObservationTiming

    init(
        historyStore: HistoryStore = .shared,
        timing: UserEditObservationTiming = .production
    ) {
        self.historyStore = historyStore
        self.timing = timing
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .intelliSenseSettingsDidChange,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    var isPanelControllerLoaded: Bool { panelController != nil }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    static func supports(modeID: UUID) -> Bool {
        modeID == ProcessingMode.intelliSenseId
    }

    func begin(
        _ context: CorrectionObservationContext,
        options: PostInjectionLearningOptions
    ) {
        finalizeObservation(reason: .cancelled, hidePanel: true)
        guard Self.supports(modeID: context.modeID),
              options.correctionEnabled || options.expressionLearningEnabled
        else { return }

        let baselineProjection = VisibleTextProjection.project(context.baselineValue)
        guard let visibleInjectedRange = baselineProjection.projectedRange(
            from: context.injectedRange
        ) else {
            recordUnavailable(context: context)
            return
        }
        let visibleInjectedText = VisibleTextProjection.project(context.injectedText).text

        var observer: AXObserver?
        let createStatus = AXObserverCreate(context.processIdentifier, correctionAXObserverCallback, &observer)
        guard createStatus == .success, let observer else {
            DebugFileLogger.log("correction observer skipped: create status=\(createStatus.rawValue) bundle=\(context.bundleIdentifier)")
            recordUnavailable(context: context)
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addStatus = AXObserverAddNotification(
            observer,
            context.element,
            kAXValueChangedNotification as CFString,
            refcon
        )
        guard addStatus == .success else {
            DebugFileLogger.log("correction observer skipped: add status=\(addStatus.rawValue) bundle=\(context.bundleIdentifier)")
            recordUnavailable(context: context)
            return
        }

        let destructionStatus = AXObserverAddNotification(
            observer,
            context.element,
            kAXUIElementDestroyedNotification as CFString,
            refcon
        )

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            CFRunLoopMode.commonModes
        )
        active = ActiveObservation(
            context: context,
            observer: observer,
            observesElementDestruction: destructionStatus == .success,
            options: options,
            startedAt: Date(),
            baselineVisibleValue: baselineProjection.text,
            visibleInjectedRange: visibleInjectedRange,
            visibleInjectedText: visibleInjectedText,
            lastRawFullValue: context.baselineValue,
            lastVisibleFullValue: baselineProjection.text,
            lastReliableVisibleInjectedText: visibleInjectedText,
            lastReliableObservedAt: Date(),
            latestResolution: InjectedTextResolution(
                text: visibleInjectedText,
                confidence: .exact,
                changedInsideInjection: false,
                changedOutsideInjection: false,
                failure: nil
            ),
            hasObservedVisibleChanges: false,
            lastSelectedRange: context.afterSelectedRange
        )
        handledCorrectionCandidate = nil
        pendingCorrectionCandidate = nil
        DebugFileLogger.log("correction observer started: bundle=\(context.bundleIdentifier) injectedLength=\(context.injectedText.count)")
        Task { await UserEditObservationMetrics.shared.record(.observationStarted) }

        timeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.timing.observationTimeout)
            guard !Task.isCancelled else { return }
            self.finalizeObservation(
                reason: .timeout,
                hidePanel: self.handledCorrectionCandidate == nil
            )
        }
    }

    /// Compatibility entry point for the existing correction-card tests and call sites.
    func begin(_ context: CorrectionObservationContext) {
        begin(context, options: PostInjectionLearningOptions(
            correctionEnabled: true,
            expressionLearningEnabled: false,
            appCategory: AppContextClassifier.classify(
                bundleIdentifier: context.bundleIdentifier,
                appName: nil
            )
        ))
    }

    func cancelObservation() {
        finalizeObservation(reason: .cancelled, hidePanel: true)
    }

    func finalizeBeforeNextRecording() {
        finalizeObservation(reason: .nextRecording, hidePanel: true)
    }

    func finalizeBeforeRevise() {
        finalizeObservation(reason: .reviseStarted, hidePanel: true)
    }

    private func recordUnavailable(context: CorrectionObservationContext) {
        Task {
            _ = await historyStore.updateUserEditObservation(
                recordID: context.sourceRecordID,
                text: nil,
                status: .unavailable,
                observedAt: nil
            )
        }
    }

    private func finalizeObservation(
        reason: UserEditObservationEndReason,
        hidePanel: Bool
    ) {
        guard var observation = active else {
            if hidePanel { panelController?.hide() }
            return
        }
        // Clear active first. All callbacks run on MainActor, so this is the
        // single atomic finalization gate for every end path.
        active = nil
        timeoutTask?.cancel()
        stableWindowTask?.cancel()
        readRetryTask?.cancel()
        candidatePresentationTask?.cancel()
        timeoutTask = nil
        stableWindowTask = nil
        readRetryTask = nil
        candidatePresentationTask = nil
        pendingCorrectionCandidate = nil

        var effectiveReason = reason
        if reason != .valueCleared,
           reason != .structureChanged,
           let currentSnapshot = copyObservedContentSnapshot(
               for: observation
           ) {
            switch visibleTransition(currentSnapshot, observation: observation) {
            case .valueCleared:
                effectiveReason = .valueCleared
            case .structureChanged:
                effectiveReason = .structureChanged
            case .changed:
                applyResolution(
                    rawValue: currentSnapshot.rawValue,
                    visibleValue: currentSnapshot.visibleValue,
                    to: &observation
                )
            case .unchanged:
                break
            }
        }

        AXObserverRemoveNotification(
            observation.observer,
            observation.context.element,
            kAXValueChangedNotification as CFString
        )
        if observation.observesElementDestruction {
            AXObserverRemoveNotification(
                observation.observer,
                observation.context.element,
                kAXUIElementDestroyedNotification as CFString
            )
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observation.observer),
            CFRunLoopMode.commonModes
        )

        settleHistoryAndExpression(observation: observation, reason: effectiveReason)
        Task {
            await UserEditObservationMetrics.shared.record(
                .observationFinalized,
                reason: effectiveReason.rawValue
            )
        }
        handledCorrectionCandidate = nil
        if hidePanel { panelController?.hide() }
    }

    fileprivate func accessibilityValueDidChange(element: AXUIElement) {
        guard let active, CFEqual(active.context.element, element) else { return }
        captureCurrentValue(isRetry: false)
    }

    fileprivate func accessibilityElementWasDestroyed(element: AXUIElement) {
        guard let active, CFEqual(active.context.element, element) else { return }
        finalizeObservation(reason: .elementDestroyed, hidePanel: true)
    }

    @objc private func settingsDidChange() {
        Task { [weak self] in
            guard let self else { return }
            let settings = await IntelliSenseSettingsStore.shared.load()
            guard var active = self.active else { return }
            if settings.isBlacklisted(bundleIdentifier: active.context.bundleIdentifier) {
                self.finalizeObservation(reason: .appBlacklisted, hidePanel: true)
                return
            }
            active.options.correctionEnabled = active.options.correctionEnabled
                && settings.correctionDetectionEnabled
            active.options.expressionLearningEnabled = active.options.expressionLearningEnabled
                && settings.expressionLearningEnabled
            guard active.options.correctionEnabled || active.options.expressionLearningEnabled else {
                self.finalizeObservation(reason: .settingsDisabled, hidePanel: true)
                return
            }
            self.active = active
        }
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
              application.processIdentifier == active?.context.processIdentifier
        else { return }
        finalizeObservation(reason: .appTerminated, hidePanel: true)
    }

    private func captureCurrentValue(isRetry: Bool) {
        guard var observation = active else { return }
        guard let currentSnapshot = copyObservedContentSnapshot(for: observation) else {
            if !isRetry {
                readRetryTask?.cancel()
                readRetryTask = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: self.timing.readRetryDelay)
                    guard !Task.isCancelled else { return }
                    self.captureCurrentValue(isRetry: true)
                }
            } else {
                DebugFileLogger.log(
                    "user edit observation finalized: reason=readFailure "
                        + "bundle=\(observation.context.bundleIdentifier)"
                )
                finalizeObservation(reason: .readFailure, hidePanel: true)
            }
            return
        }
        readRetryTask?.cancel()
        readRetryTask = nil
        switch visibleTransition(currentSnapshot, observation: observation) {
        case .valueCleared:
            finalizeObservation(reason: .valueCleared, hidePanel: true)
            return
        case .structureChanged:
            finalizeObservation(reason: .structureChanged, hidePanel: true)
            return
        case .unchanged:
            observation.lastRawFullValue = currentSnapshot.rawValue
            observation.lastSelectedRange = currentSnapshot.selectedRange
            active = observation
            return
        case .changed:
            break
        }

        observation.lastRawFullValue = currentSnapshot.rawValue
        observation.lastSelectedRange = currentSnapshot.selectedRange
        applyResolution(
            rawValue: currentSnapshot.rawValue,
            visibleValue: currentSnapshot.visibleValue,
            to: &observation
        )
        active = observation

        candidatePresentationTask?.cancel()
        candidatePresentationTask = nil
        pendingCorrectionCandidate = nil
        if observation.latestResolution.confidence != .ambiguous,
           observation.lastReliableVisibleInjectedText != observation.visibleInjectedText {
            let expectedText = observation.lastReliableVisibleInjectedText
            candidatePresentationTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.timing.candidatePresentationDelay)
                guard !Task.isCancelled else { return }
                self.presentPendingCandidate(expectedText: expectedText)
            }
        }

        stableWindowTask?.cancel()
        stableWindowTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.timing.stableWindow)
            guard !Task.isCancelled, let active = self.active else { return }
            guard let current = self.copyObservedContentSnapshot(for: active) else {
                self.captureCurrentValue(isRetry: false)
                return
            }
            guard !current.isPlaceholder,
                  current.visibleValue == active.lastVisibleFullValue
            else {
                self.captureCurrentValue(isRetry: false)
                return
            }
            self.analyzeStableValue()
        }
    }

    private func applyResolution(
        rawValue: String,
        visibleValue: String,
        to observation: inout ActiveObservation
    ) {
        observation.lastRawFullValue = rawValue
        observation.lastVisibleFullValue = visibleValue
        observation.hasObservedVisibleChanges = true
        let resolution = InjectedTextResolver.resolve(
            baseline: observation.baselineVisibleValue,
            injectedRange: observation.visibleInjectedRange,
            current: visibleValue,
            budget: timing.resolverBudget
        )
        observation.latestResolution = resolution
        let resolutionConfidence = resolution.confidence
        let resolutionFailure = resolution.failure?.rawValue
        Task {
            let event: UserEditObservationMetrics.Event
            switch resolutionConfidence {
            case .exact: event = .snapshotExact
            case .anchored: event = .snapshotAnchored
            case .ambiguous: event = .snapshotAmbiguous
            }
            await UserEditObservationMetrics.shared.record(
                event,
                reason: resolutionFailure
            )
        }
        guard resolution.confidence != .ambiguous,
              let resolvedText = resolution.text,
              !resolvedText.isEmpty
        else { return }
        observation.lastReliableVisibleInjectedText = resolvedText
        observation.lastReliableObservedAt = Date()
    }

    private func visibleTransition(
        _ snapshot: ObservedContentSnapshot,
        observation: ActiveObservation
    ) -> UserEditVisibleTransition {
        UserEditVisibleStateMachine.classify(
            currentVisibleValue: snapshot.visibleValue,
            isPlaceholder: snapshot.isPlaceholder,
            baselineVisibleValue: observation.baselineVisibleValue,
            visibleInjectedRange: observation.visibleInjectedRange,
            visibleInjectedText: observation.visibleInjectedText,
            lastReliableVisibleInjectedText: observation.lastReliableVisibleInjectedText,
            previousVisibleFullValue: observation.lastVisibleFullValue
        )
    }

    private func analyzeStableValue() {
        guard let observation = active,
              observation.options.correctionEnabled,
              handledCorrectionCandidate == nil,
              observation.lastReliableVisibleInjectedText != observation.visibleInjectedText
        else { return }
        let sourceRecordID = observation.context.sourceRecordID
        let original = observation.visibleInjectedText
        let edited = observation.lastReliableVisibleInjectedText
        Task { [weak self] in
            let result = await ImmediateCorrectionAnalyzer.analyze(
                original: original,
                edited: edited
            )
            guard let self,
                  self.active?.context.sourceRecordID == sourceRecordID,
                  self.active?.lastReliableVisibleInjectedText == edited
            else { return }
            self.stageCandidateResult(
                result,
                observation: observation,
                observedText: edited
            )
        }
    }

    private func stageCandidateResult(
        _ result: CorrectionDiffResult,
        observation: ActiveObservation,
        observedText: String
    ) {
        guard handledCorrectionCandidate == nil else { return }
        switch result {
        case .candidate(let wrongText, let correctedText):
            let candidate = CorrectionCandidate(
                wrongText: wrongText,
                correctedText: correctedText,
                sourceRecordID: observation.context.sourceRecordID,
                bundleIdentifier: observation.context.bundleIdentifier
            )
            pendingCorrectionCandidate = PendingCorrectionCandidate(
                candidate: candidate,
                observedText: observedText
            )
        case .rejected(let reason):
            DebugFileLogger.log("correction candidate rejected: reason=\(reason.rawValue) bundle=\(observation.context.bundleIdentifier)")
            Task {
                await UserEditObservationMetrics.shared.record(
                    .candidateRejected,
                    reason: reason.rawValue
                )
            }
        }
    }

    private func presentPendingCandidate(expectedText: String) {
        candidatePresentationTask = nil
        guard handledCorrectionCandidate == nil,
              let active,
              active.lastReliableVisibleInjectedText == expectedText,
              let pending = pendingCorrectionCandidate,
              pending.observedText == expectedText
        else { return }

        let candidate = pending.candidate
        pendingCorrectionCandidate = nil
        handledCorrectionCandidate = candidate
        Task { await UserEditObservationMetrics.shared.record(.candidateDetected) }
        let panelController = panelController ?? CorrectionLearningPanelController()
        self.panelController = panelController
        panelController.show(
            candidate: candidate,
            onLearn: { [weak self] in self?.learn(candidate) },
            onIgnore: { [weak self] in
                Task { await UserEditObservationMetrics.shared.record(.candidateIgnored) }
                self?.panelController?.hide()
            }
        )
    }

    private func settleHistoryAndExpression(
        observation: ActiveObservation,
        reason: UserEditObservationEndReason
    ) {
        let settlement = UserEditObservationSettlement.resolve(
            original: observation.visibleInjectedText,
            lastReliableText: observation.lastReliableVisibleInjectedText,
            latestResolutionConfidence: observation.latestResolution.confidence,
            hasObservedExternalChanges: observation.hasObservedVisibleChanges,
            endReason: reason
        )
        let recordID = observation.context.sourceRecordID
        let observedAt = observation.lastReliableObservedAt

        Task {
            let updated = await historyStore.updateUserEditObservation(
                recordID: recordID,
                text: settlement.text,
                status: settlement.status,
                observedAt: observedAt
            )
            if !updated {
                await UserEditObservationMetrics.shared.record(.historyUpdateFailed)
                DebugFileLogger.log(
                    "user edit observation history update failed: status=\(settlement.status.rawValue)"
                )
            } else {
                await UserEditObservationMetrics.shared.record(.historyUpdateSucceeded)
                await BatchCorrectionInferenceCoordinator.shared.schedule(
                    historyStore: historyStore
                )
            }
        }

        guard observation.options.expressionLearningEnabled,
              settlement.text != nil,
              settlement.classification == .expressionEdit
                || settlement.classification == .mixedEdit
        else { return }
        recordExpressionSample(
            active: observation,
            finalValue: observation.lastVisibleFullValue
        )
    }

    private func learn(_ candidate: CorrectionCandidate) {
        do {
            try learningStore.learn(candidate)
            Task { await UserEditObservationMetrics.shared.record(.candidateAccepted) }
            Task {
                await HybridChineseWordSegmenter.shared.insertConfirmedUserWord(
                    candidate.correctedText
                )
            }
            panelController?.showLearned()
        } catch {
            DebugFileLogger.log("correction learning save failed: bundle=\(candidate.bundleIdentifier) error=\(error.localizedDescription)")
            panelController?.showSaveFailure()
        }
    }

    private func recordExpressionSample(active: ActiveObservation, finalValue: String) {
        guard var styleValue = observedInjectedText(
            baselineValue: active.baselineVisibleValue,
            injectedRange: active.visibleInjectedRange,
            injectedText: active.visibleInjectedText,
            currentValue: finalValue
        ) else { return }
        if let candidate = handledCorrectionCandidate,
           let range = styleValue.range(of: candidate.correctedText) {
            styleValue.replaceSubrange(range, with: candidate.wrongText)
        }
        let observation = ExpressionObservation(
            sessionID: active.context.sourceRecordID,
            createdAt: Date(),
            appBundleIdentifier: active.context.bundleIdentifier,
            appCategory: active.options.appCategory,
            sourceText: active.context.sourceText,
            injectedText: active.visibleInjectedText,
            finalObservedText: styleValue,
            correctionCandidateRange: nil
        )
        let bundleIdentifier = active.context.bundleIdentifier
        Task {
            do {
                let settings = await IntelliSenseSettingsStore.shared.load()
                guard settings.expressionLearningEnabled,
                      !settings.isBlacklisted(bundleIdentifier: bundleIdentifier)
                else { return }
                try await ExpressionProfileStore.shared.record(observation)
            } catch {
                DebugFileLogger.log(
                    "expression profile save failed bundle=\(bundleIdentifier) "
                        + "error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func observedInjectedText(
        baselineValue: String,
        injectedRange: NSRange,
        injectedText: String,
        currentValue: String
    ) -> String? {
        let baseline = baselineValue as NSString
        guard injectedRange.location >= 0,
              NSMaxRange(injectedRange) <= baseline.length
        else { return nil }
        let prefix = baseline.substring(to: injectedRange.location)
        let suffix = baseline.substring(from: NSMaxRange(injectedRange))
        guard currentValue.hasPrefix(prefix), currentValue.hasSuffix(suffix) else {
            return currentValue == baselineValue ? injectedText : nil
        }
        let start = currentValue.index(currentValue.startIndex, offsetBy: prefix.count)
        let end = currentValue.index(currentValue.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(currentValue[start..<end])
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private struct ObservedContentSnapshot {
        let rawValue: String
        let visibleValue: String
        let isPlaceholder: Bool
        let selectedRange: NSRange?
    }

    private func copyObservedContentSnapshot(
        for observation: ActiveObservation
    ) -> ObservedContentSnapshot? {
        let element = observation.context.element
        guard let rawValue = copyStringAttribute(kAXValueAttribute as CFString, from: element) else {
            return nil
        }
        let selectedRange = copyRangeAttribute(
            kAXSelectedTextRangeAttribute as CFString,
            from: element
        )
        let contentValue = UserEditObservedValueSanitizer.contentValue(
            rawValue,
            placeholderCandidates: observation.context.placeholderCandidates.map(Optional.some) + [
                copyStringAttribute(kAXPlaceholderValueAttribute as CFString, from: element),
                copyStringAttribute(kAXDescriptionAttribute as CFString, from: element),
            ]
        )
        let isPlaceholder = contentValue.isEmpty && !rawValue.isEmpty
        return ObservedContentSnapshot(
            rawValue: rawValue,
            visibleValue: isPlaceholder
                ? ""
                : VisibleTextProjection.project(contentValue).text,
            isPlaceholder: isPlaceholder,
            selectedRange: selectedRange
        )
    }

    private func copyRangeAttribute(_ attribute: CFString, from element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }
}

typealias CorrectionLearningCoordinator = PostInjectionLearningCoordinator

private let correctionAXObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let coordinator = Unmanaged<PostInjectionLearningCoordinator>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    Task { @MainActor in
        switch notification as String {
        case kAXValueChangedNotification:
            coordinator.accessibilityValueDidChange(element: element)
        case kAXUIElementDestroyedNotification:
            coordinator.accessibilityElementWasDestroyed(element: element)
        default:
            break
        }
    }
}
