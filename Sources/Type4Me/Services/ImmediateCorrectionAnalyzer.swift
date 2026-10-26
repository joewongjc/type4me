import Foundation

enum ImmediateCorrectionAnalyzer {
    static func analyze(
        original: String,
        edited: String,
        chineseSegmenter: any ChineseWordSegmenting = HybridChineseWordSegmenter.shared,
        confirmedMappings: [CorrectionMapping]? = nil
    ) async -> CorrectionDiffResult {
        let direct = CorrectionDiffAnalyzer.analyze(
            baseline: original,
            injectedRange: NSRange(original.startIndex..<original.endIndex, in: original),
            current: edited
        )
        let classification = UserEditClassifier.classify(original: original, edited: edited)
        if case .candidate(let wrong, let corrected) = direct {
            guard classification == .lexicalCorrection else {
                return .rejected(classification == .sensitive ? .sensitiveContent : .invalidCandidate)
            }
            if let mixedBoundary = mixedScriptBoundary(
                original: original,
                edited: edited,
                wrong: wrong,
                corrected: corrected
            ) {
                let spans = await chineseSegmenter.tokenSpans(in: mixedBoundary.text)
                guard acceptsChineseBoundary(mixedBoundary.range, spans: spans) else {
                    return .rejected(.invalidCandidate)
                }
            }
            guard hasHighCorrectionAffinity(
                wrong: wrong,
                corrected: corrected,
                confirmedMappings: confirmedMappings
            ) else {
                return .rejected(.lowAffinity)
            }
            return direct
        }
        guard direct == .rejected(.ambiguousCJKReplacement),
              let diff = minimalReplacement(original: original, edited: edited),
              diff.oldText.count == 1,
              diff.newText.count == 1,
              isHanOnly(diff.oldText),
              isHanOnly(diff.newText)
        else { return direct }

        async let oldSpans = chineseSegmenter.tokenSpans(in: original)
        async let newSpans = chineseSegmenter.tokenSpans(in: edited)
        let oldCandidates = coveringCandidates(
            spans: await oldSpans,
            diffRange: diff.oldRange,
            in: original
        )
        let newCandidates = coveringCandidates(
            spans: await newSpans,
            diffRange: diff.newRange,
            in: edited
        )
        let sharedKeys = Set(oldCandidates.keys).intersection(newCandidates.keys)
        let acceptedKeys = sharedKeys.filter { key in
            guard key.length >= 2, key.length <= 8,
                  let oldSources = oldCandidates[key],
                  let newSources = newCandidates[key]
            else { return false }
            if oldSources.contains(.userDictionary) || newSources.contains(.userDictionary) {
                return true
            }
            let required: Set<ChineseTokenSpan.Source> = [.jiebaAccurate, .naturalLanguage]
            return required.isSubset(of: oldSources) && required.isSubset(of: newSources)
        }
        guard let selected = acceptedKeys.min(by: { lhs, rhs in
            lhs.length == rhs.length ? lhs.start < rhs.start : lhs.length < rhs.length
        }),
        acceptedKeys.filter({ $0.length == selected.length }).count == 1,
        let wrong = substring(in: original, start: selected.start, length: selected.length),
        let corrected = substring(in: edited, start: selected.start, length: selected.length),
        wrong != corrected
        else { return direct }

        guard hasHighCorrectionAffinity(
            wrong: wrong,
            corrected: corrected,
            confirmedMappings: confirmedMappings
        ) else {
            return .rejected(.lowAffinity)
        }

        return .candidate(wrongText: wrong, correctedText: corrected)
    }

    private struct ReplacementDiff {
        let oldRange: Range<String.Index>
        let newRange: Range<String.Index>
        let oldText: String
        let newText: String
    }

    private struct SpanKey: Hashable {
        let start: Int
        let length: Int
    }

    private struct MixedScriptBoundary {
        let text: String
        let range: Range<String.Index>
    }

    private static func mixedScriptBoundary(
        original: String,
        edited: String,
        wrong: String,
        corrected: String
    ) -> MixedScriptBoundary? {
        let wrongIsHan = isHanOnly(wrong)
        let correctedIsHan = isHanOnly(corrected)
        let wrongIsLatin = isLatinTechnicalToken(wrong)
        let correctedIsLatin = isLatinTechnicalToken(corrected)
        guard (wrongIsHan && correctedIsLatin) || (wrongIsLatin && correctedIsHan),
              let diff = minimalReplacement(original: original, edited: edited),
              diff.oldText == wrong,
              diff.newText == corrected
        else { return nil }
        if wrongIsHan {
            return MixedScriptBoundary(text: original, range: diff.oldRange)
        }
        return MixedScriptBoundary(text: edited, range: diff.newRange)
    }

    private static func acceptsChineseBoundary(
        _ range: Range<String.Index>,
        spans: [ChineseTokenSpan]
    ) -> Bool {
        let exactSources = Set(spans.filter { $0.range == range }.map(\.source))
        if exactSources.contains(.userDictionary) { return true }
        guard exactSources.contains(.naturalLanguage) else { return false }

        // When CppJieba is available, require its accurate mode to agree with
        // NLTokenizer. If no jieba spans exist, retain the documented native
        // fallback instead of disabling mixed-script corrections entirely.
        let jiebaAvailable = spans.contains { $0.source == .jiebaAccurate }
        return !jiebaAvailable || exactSources.contains(.jiebaAccurate)
    }

    private static func isLatinTechnicalToken(_ text: String) -> Bool {
        guard TechnicalTokenBoundaryResolver.isSingleStableToken(text) else { return false }
        return text.contains { character in
            character.unicodeScalars.allSatisfy {
                $0.value < 128 && CharacterSet.letters.contains($0)
            }
        }
    }

    private static func hasHighCorrectionAffinity(
        wrong: String,
        corrected: String,
        confirmedMappings: [CorrectionMapping]?
    ) -> Bool {
        let mappings = confirmedMappings ?? SnippetStorage.load().map {
            CorrectionMapping(trigger: $0.trigger, replacement: $0.value)
        }
        return CorrectionAffinityAnalyzer.evaluate(
            wrong: wrong,
            corrected: corrected,
            confirmedMappings: mappings
        ).isHighConfidence
    }

    private static func minimalReplacement(original: String, edited: String) -> ReplacementDiff? {
        let old = Array(original)
        let new = Array(edited)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix,
              suffix < new.count - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] {
            suffix += 1
        }
        let oldStart = original.index(original.startIndex, offsetBy: prefix)
        let oldEnd = original.index(original.endIndex, offsetBy: -suffix)
        let newStart = edited.index(edited.startIndex, offsetBy: prefix)
        let newEnd = edited.index(edited.endIndex, offsetBy: -suffix)
        guard oldStart <= oldEnd, newStart <= newEnd else { return nil }
        return ReplacementDiff(
            oldRange: oldStart..<oldEnd,
            newRange: newStart..<newEnd,
            oldText: String(original[oldStart..<oldEnd]),
            newText: String(edited[newStart..<newEnd])
        )
    }

    private static func coveringCandidates(
        spans: [ChineseTokenSpan],
        diffRange: Range<String.Index>,
        in text: String
    ) -> [SpanKey: Set<ChineseTokenSpan.Source>] {
        var candidates: [SpanKey: Set<ChineseTokenSpan.Source>] = [:]
        for span in spans where span.range.lowerBound <= diffRange.lowerBound
            && span.range.upperBound >= diffRange.upperBound {
            let start = text.distance(from: text.startIndex, to: span.range.lowerBound)
            let length = text.distance(from: span.range.lowerBound, to: span.range.upperBound)
            candidates[SpanKey(start: start, length: length), default: []].insert(span.source)
        }
        return candidates
    }

    private static func substring(in text: String, start: Int, length: Int) -> String? {
        guard let lower = text.index(text.startIndex, offsetBy: start, limitedBy: text.endIndex),
              let upper = text.index(lower, offsetBy: length, limitedBy: text.endIndex)
        else { return nil }
        return String(text[lower..<upper])
    }

    private static func isHanOnly(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { character in
            character.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                    return true
                default:
                    return false
                }
            }
        }
    }
}
