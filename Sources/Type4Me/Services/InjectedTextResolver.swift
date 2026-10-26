import Foundation

struct LocatedInjectedText: Equatable, Sendable {
    let text: String
    let rawText: String
    let currentRange: NSRange
    let currentFullValue: String
    let confidence: ResolutionConfidence
    let changedInsideInjection: Bool
    let changedOutsideInjection: Bool

    init(
        text: String,
        rawText: String,
        currentRange: NSRange,
        currentFullValue: String,
        confidence: ResolutionConfidence,
        changedInsideInjection: Bool,
        changedOutsideInjection: Bool
    ) {
        self.text = text
        self.rawText = rawText
        self.currentRange = currentRange
        self.currentFullValue = currentFullValue
        self.confidence = confidence
        self.changedInsideInjection = changedInsideInjection
        self.changedOutsideInjection = changedOutsideInjection
    }
}

enum InjectedTextLocator {
    private struct EditHunk {
        var oldStart: Int
        var oldEnd: Int
        var newStart: Int
        var newEnd: Int

        var oldLength: Int { oldEnd - oldStart }
        var newLength: Int { newEnd - newStart }
    }

    static func locate(
        baseline: String,
        injectedRange: NSRange,
        current: String,
        budget: Duration = UserEditObservationTiming.production.resolverBudget
    ) -> Result<LocatedInjectedText, InjectedTextResolutionFailure> {
        guard let baselineRange = Range(injectedRange, in: baseline) else {
            return .failure(.invalidRange)
        }

        let injectedBaseline = String(baseline[baselineRange])
        let prefix = String(baseline[..<baselineRange.lowerBound])
        let suffix = String(baseline[baselineRange.upperBound...])
        if current.hasPrefix(prefix), current.hasSuffix(suffix) {
            let lower = current.index(current.startIndex, offsetBy: prefix.count)
            let upper = current.index(current.endIndex, offsetBy: -suffix.count)
            if lower <= upper {
                let rawResolved = String(current[lower..<upper])
                let projected = VisibleTextProjection.project(rawResolved).text
                let currentRange = NSRange(lower..<upper, in: current)
                return .success(LocatedInjectedText(
                    text: projected,
                    rawText: rawResolved,
                    currentRange: currentRange,
                    currentFullValue: current,
                    confidence: .exact,
                    changedInsideInjection: rawResolved != injectedBaseline,
                    changedOutsideInjection: false
                ))
            }
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        guard budget > .zero else { return .failure(.budgetExceeded) }

        let old = Array(baseline)
        let new = Array(current)
        // Avoid starting a potentially expensive global diff when the input is
        // clearly incompatible with the local parsing budget.
        guard old.count + new.count <= 65_536 else {
            return .failure(.budgetExceeded)
        }
        guard let hunks = editHunks(old: old, new: new) else {
            return .failure(.boundaryConflict)
        }
        guard clock.now - startedAt <= budget else {
            return .failure(.budgetExceeded)
        }

        let injectionStart = baseline.distance(
            from: baseline.startIndex,
            to: baselineRange.lowerBound
        )
        let injectionEnd = baseline.distance(
            from: baseline.startIndex,
            to: baselineRange.upperBound
        )

        var deltaBefore = 0
        var deltaInside = 0
        var changedInside = false
        var changedOutside = false

        for hunk in hunks {
            if hunk.oldStart == hunk.oldEnd,
               hunk.oldStart == injectionStart || hunk.oldStart == injectionEnd {
                return .failure(.boundaryConflict)
            }
            if hunk.oldEnd <= injectionStart {
                deltaBefore += hunk.newLength - hunk.oldLength
                changedOutside = true
            } else if hunk.oldStart >= injectionEnd {
                changedOutside = true
            } else if hunk.oldStart >= injectionStart, hunk.oldEnd <= injectionEnd {
                deltaInside += hunk.newLength - hunk.oldLength
                changedInside = true
            } else {
                return .failure(.boundaryConflict)
            }
        }

        let newStart = injectionStart + deltaBefore
        let newEnd = newStart + (injectionEnd - injectionStart) + deltaInside
        guard newStart >= 0, newEnd >= newStart, newEnd <= new.count else {
            return .failure(.boundaryConflict)
        }

        let leftAnchorLength = min(64, injectionStart)
        let rightAnchorLength = min(64, old.count - injectionEnd)
        let baselineLeft = Array(old[(injectionStart - leftAnchorLength)..<injectionStart])
        let baselineRight = Array(old[injectionEnd..<(injectionEnd + rightAnchorLength)])
        let currentLeft: [Character] = newStart >= leftAnchorLength
            ? Array(new[(newStart - leftAnchorLength)..<newStart])
            : []
        let currentRight: [Character] = newEnd + rightAnchorLength <= new.count
            ? Array(new[newEnd..<(newEnd + rightAnchorLength)])
            : []
        let hasLeftAnchor = !baselineLeft.isEmpty && baselineLeft == currentLeft
        let hasRightAnchor = !baselineRight.isEmpty && baselineRight == currentRight
        guard hasLeftAnchor || hasRightAnchor else {
            return .failure(.insufficientAnchor)
        }

        let startIdx = current.index(current.startIndex, offsetBy: newStart)
        let endIdx = current.index(current.startIndex, offsetBy: newEnd)
        let rawResolved = String(current[startIdx..<endIdx])
        let projected = VisibleTextProjection.project(rawResolved).text
        let currentRange = NSRange(startIdx..<endIdx, in: current)

        return .success(LocatedInjectedText(
            text: projected,
            rawText: rawResolved,
            currentRange: currentRange,
            currentFullValue: current,
            confidence: .anchored,
            changedInsideInjection: changedInside,
            changedOutsideInjection: changedOutside
        ))
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
            if let active { hunks.append(active) }
            active = nil
        }

        while oldIndex < old.count || newIndex < new.count {
            var edited = false
            if newIndex < new.count, insertions.contains(newIndex) {
                if active == nil {
                    active = EditHunk(
                        oldStart: oldIndex,
                        oldEnd: oldIndex,
                        newStart: newIndex,
                        newEnd: newIndex
                    )
                }
                active?.newEnd = newIndex + 1
                newIndex += 1
                edited = true
            }
            if oldIndex < old.count, removals.contains(oldIndex) {
                if active == nil {
                    active = EditHunk(
                        oldStart: oldIndex,
                        oldEnd: oldIndex,
                        newStart: newIndex,
                        newEnd: newIndex
                    )
                }
                active?.oldEnd = oldIndex + 1
                oldIndex += 1
                edited = true
            }
            if edited { continue }
            guard oldIndex < old.count,
                  newIndex < new.count,
                  old[oldIndex] == new[newIndex]
            else { return nil }
            flush()
            oldIndex += 1
            newIndex += 1
        }
        flush()
        return hunks
    }
}

enum InjectedTextResolver {
    static func resolve(
        baseline: String,
        injectedRange: NSRange,
        current: String,
        budget: Duration = UserEditObservationTiming.production.resolverBudget
    ) -> InjectedTextResolution {
        let result = InjectedTextLocator.locate(
            baseline: baseline,
            injectedRange: injectedRange,
            current: current,
            budget: budget
        )
        switch result {
        case .success(let located):
            return InjectedTextResolution(
                text: located.text,
                confidence: located.confidence,
                changedInsideInjection: located.changedInsideInjection,
                changedOutsideInjection: located.changedOutsideInjection,
                failure: nil
            )
        case .failure(let failure):
            var changedOutside = false
            if let baselineRange = Range(injectedRange, in: baseline) {
                let prefix = String(baseline[..<baselineRange.lowerBound])
                let suffix = String(baseline[baselineRange.upperBound...])
                if !current.hasPrefix(prefix) || !current.hasSuffix(suffix) {
                    changedOutside = true
                }
            }
            return InjectedTextResolution.ambiguous(failure, changedOutsideInjection: changedOutside)
        }
    }
}
