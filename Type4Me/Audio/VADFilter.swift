import Foundation
import os

/// State machine that decides whether to emit audio chunks based on VAD results.
/// States: waitingForSpeech → speaking → maybeSilent → (back to waitingForSpeech or speaking)
///
/// - `waitingForSpeech`: Silence before speech begins. Audio is NOT emitted.
/// - `speaking`: Active speech detected. Audio IS emitted.
/// - `maybeSilent`: Speech stopped but might resume (thinking pause). Audio IS still emitted
///   to preserve server-side endpoint detection (`end_window_size`).
///   After `silenceTimeout` seconds, transitions back to `waitingForSpeech`.
final class VADFilter {

    enum State: Sendable {
        case waitingForSpeech
        case speaking
        case maybeSilent
    }

    /// Seconds of continuous silence before transitioning from maybeSilent → waitingForSpeech.
    /// Must be longer than the server's `end_window_size` (3s) to avoid conflicts.
    var silenceTimeout: TimeInterval = 4.0

    private(set) var state: State = .waitingForSpeech
    private var silenceStart: Date?

    private let logger = Logger(subsystem: "com.type4me.vad", category: "VADFilter")

    /// Process a VAD detection result and return whether the audio chunk should be emitted.
    /// - Parameter speechDetected: Whether speech is currently detected by the VAD.
    /// - Returns: `true` if the chunk should be sent to ASR.
    func shouldEmit(speechDetected: Bool) -> Bool {
        switch state {
        case .waitingForSpeech:
            if speechDetected {
                state = .speaking
                silenceStart = nil
                logger.debug("VAD: speech detected, start emitting")
                return true
            }
            return false

        case .speaking:
            if !speechDetected {
                state = .maybeSilent
                silenceStart = Date()
                return true
            }
            return true

        case .maybeSilent:
            if speechDetected {
                state = .speaking
                silenceStart = nil
                return true
            }
            if let start = silenceStart, Date().timeIntervalSince(start) >= silenceTimeout {
                state = .waitingForSpeech
                silenceStart = nil
                logger.debug("VAD: silence timeout, stop emitting")
                return false
            }
            return true
        }
    }

    /// Reset to initial state. Call when starting a new recording session.
    func reset() {
        state = .waitingForSpeech
        silenceStart = nil
    }
}
