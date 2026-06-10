import Foundation

enum PartialCandidateGate {
    static func isEligible(_ transcript: RecognitionTranscript) -> Bool {
        transcript.isPartialCandidateReliable
    }
}
