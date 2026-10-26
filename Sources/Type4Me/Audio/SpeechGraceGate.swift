import Foundation

/// Thread-safe gate for speech grace periods to prevent start sound playback
/// from being falsely detected as user speech, while preserving speech that occurs
/// before the sound actually plays.
final class SpeechGraceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var graceUntil: ContinuousClock.Instant?

    init() {}

    /// Arm the grace window until a specific instant.
    func arm(until: ContinuousClock.Instant) {
        lock.withLock {
            graceUntil = until
        }
    }

    /// Returns `true` if speech should be ignored (currently within the armed grace window).
    /// When unarmed (`arm` has not been called), returns `false` so speech is detected immediately.
    func isSpeechIgnored(at instant: ContinuousClock.Instant = .now) -> Bool {
        lock.withLock {
            guard let graceUntil else {
                return false
            }
            return instant < graceUntil
        }
    }

    /// Reset the gate to unarmed state.
    func disarm() {
        lock.withLock {
            graceUntil = nil
        }
    }
}
