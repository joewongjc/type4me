import Foundation

enum PartialCandidateReliability: Equatable, Sendable {
    case reliable
    case unreliable(reason: String)

    var isReliable: Bool {
        if case .reliable = self { return true }
        return false
    }

    var reason: String? {
        if case .unreliable(let reason) = self { return reason }
        return nil
    }
}

struct VolcPartialAssembly: Sendable, Equatable {
    let transcript: RecognitionTranscript
    let sequence: Int
    let definiteCount: Int
    let incomingLength: Int
    let committedLength: Int
    let mutableLength: Int
    let assembledPartialLength: Int
    let previousPartialLength: Int
    let commonPrefixLength: Int
    let replacedMutableSegment: Bool
    let appendedCommittedSegment: Bool
}

struct VolcPartialCandidateAssembler: Sendable {
    private var localConfirmedSegments: [String] = []
    private var lastPartialText = ""
    private var lastServerConfirmedCount = 0
    private var previousAssembledText = ""
    private var sequence = 0

    mutating func reset() {
        localConfirmedSegments = []
        lastPartialText = ""
        lastServerConfirmedCount = 0
        previousAssembledText = ""
        sequence = 0
    }

    mutating func assemble(
        result: VolcASRResult,
        isFinal: Bool
    ) -> VolcPartialAssembly {
        sequence += 1
        let serverConfirmed = result.utterances
            .filter(\.definite)
            .map(\.text)
            .filter { !$0.isEmpty }
        let partialText = result.utterances
            .last(where: { !$0.definite && !$0.text.isEmpty })?
            .text ?? ""

        let previousPartial = lastPartialText
        let previousServerConfirmedCount = lastServerConfirmedCount
        lastServerConfirmedCount = serverConfirmed.count
        let appendedCommitted = serverConfirmed.count > localConfirmedSegments.count
        if appendedCommitted {
            localConfirmedSegments = serverConfirmed
        }

        var reliability: PartialCandidateReliability = .reliable
        if !isFinal,
           serverConfirmed.count <= previousServerConfirmedCount,
           previousPartial.count >= 4
        {
            if partialText.isEmpty {
                localConfirmedSegments.append(previousPartial)
                reliability = .unreliable(reason: "duplicateRevision")
            } else {
                let prefixLength = Self.commonPrefixLength(previousPartial, partialText)
                let ratio = Double(prefixLength) / Double(previousPartial.count)
                if ratio < 0.5 {
                    localConfirmedSegments.append(previousPartial)
                    reliability = .unreliable(reason: "prefixCollapse")
                }
            }
        }

        lastPartialText = partialText

        if !partialText.isEmpty && localConfirmedSegments.count > serverConfirmed.count {
            let lastPromoted = localConfirmedSegments.last!
            let prefixLength = Self.commonPrefixLength(lastPromoted, partialText)
            let ratio = Double(prefixLength) / Double(lastPromoted.count)
            if ratio >= 0.5 {
                localConfirmedSegments.removeLast()
                reliability = .reliable
            }
        }

        let effectiveConfirmed = localConfirmedSegments.count > serverConfirmed.count
            ? localConfirmedSegments
            : serverConfirmed
        let composedText = (
            effectiveConfirmed + (partialText.isEmpty ? [] : [partialText])
        ).joined()
        let authoritativeText = result.text.isEmpty ? composedText : result.text

        if !isFinal,
           reliability.isReliable,
           previousAssembledText.count >= 8,
           composedText.count - previousAssembledText.count >= 16,
           composedText.count * 10 > previousAssembledText.count * 16
        {
            reliability = .unreliable(reason: "suspiciousLengthJump")
        }

        let previousLength = previousAssembledText.count
        let commonPrefix = Self.commonPrefixLength(previousAssembledText, composedText)
        let replacedMutable = !previousPartial.isEmpty
            && partialText != previousPartial
            && !appendedCommitted
        previousAssembledText = composedText

        let transcript = RecognitionTranscript(
            confirmedSegments: effectiveConfirmed,
            partialText: partialText,
            authoritativeText: authoritativeText,
            isFinal: isFinal,
            partialCandidateReliability: isFinal ? .reliable : reliability
        )
        return VolcPartialAssembly(
            transcript: transcript,
            sequence: sequence,
            definiteCount: serverConfirmed.count,
            incomingLength: result.text.count,
            committedLength: effectiveConfirmed.joined().count,
            mutableLength: partialText.count,
            assembledPartialLength: composedText.count,
            previousPartialLength: previousLength,
            commonPrefixLength: commonPrefix,
            replacedMutableSegment: replacedMutable,
            appendedCommittedSegment: appendedCommitted
        )
    }

    static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var leftIndex = lhs.startIndex
        var rightIndex = rhs.startIndex
        while leftIndex < lhs.endIndex,
              rightIndex < rhs.endIndex,
              lhs[leftIndex] == rhs[rightIndex]
        {
            count += 1
            leftIndex = lhs.index(after: leftIndex)
            rightIndex = rhs.index(after: rightIndex)
        }
        return count
    }
}

struct VolcSequenceGate: Sendable {
    private(set) var latest: Int32?

    mutating func accept(_ sequence: Int32?) -> Bool {
        guard let sequence else { return true }
        guard latest.map({ sequence > $0 }) ?? true else { return false }
        latest = sequence
        return true
    }

    mutating func reset() {
        latest = nil
    }
}
