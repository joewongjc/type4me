import Foundation

actor UserEditObservationMetrics {
    static let shared = UserEditObservationMetrics()

    enum Event: String, Sendable {
        case observationStarted
        case snapshotExact
        case snapshotAnchored
        case snapshotAmbiguous
        case candidateDetected
        case candidateRejected
        case candidateAccepted
        case candidateIgnored
        case historyUpdateSucceeded
        case historyUpdateFailed
        case observationFinalized
        case jiebaLoaded
        case jiebaReleased
        case jiebaFallback
    }

    private var counters: [String: Int] = [:]

    func record(_ event: Event, reason: String? = nil) {
        let key = reason.map { event.rawValue + "." + $0 } ?? event.rawValue
        counters[key, default: 0] += 1
    }

    func snapshot() -> [String: Int] { counters }

    func resetForTesting() { counters.removeAll() }
}
