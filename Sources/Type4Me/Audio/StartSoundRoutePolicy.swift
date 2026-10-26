import Foundation

enum StartSoundRoutePolicy {
    static func requiresRouteSettle(
        startSoundEnabled: Bool,
        inputCategory: AudioInputDeviceCategory,
        input: (uid: String, name: String),
        output: (uid: String, name: String, isBluetooth: Bool)?
    ) -> Bool {
        guard startSoundEnabled else { return false }
        guard inputCategory == .bluetooth else { return false }
        guard let output else { return false }

        if !input.uid.isEmpty && input.uid == output.uid {
            return true
        }

        if output.isBluetooth {
            let inName = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let outName = output.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !inName.isEmpty && inName.caseInsensitiveCompare(outName) == .orderedSame {
                return true
            }
        }

        return false
    }
}

enum StartSoundVolumeSchedule: Equatable {
    case afterSound(ContinuousClock.Instant)
    case immediately
    case none
}

enum StartSoundPlaybackDecision {
    static func volumeSchedule(
        for playback: StartSoundPlayback,
        soundDuration: Duration
    ) -> StartSoundVolumeSchedule {
        switch playback {
        case .played(let startedAt):
            return .afterSound(startedAt + soundDuration)
        case .disabled, .skipped(.noPlayer), .skipped(.playFailed):
            return .immediately
        case .skipped(.invalidated):
            return .none
        }
    }

    static func shouldPlayStartSound(
        outcome: StartSoundRouteGate.Outcome,
        barPhase: FloatingBarPhase,
        readyGeneration: UInt64?,
        expectedGeneration: UInt64
    ) -> Bool {
        guard outcome != .cancelled else { return false }
        guard barPhase == .recording else { return false }
        guard readyGeneration == expectedGeneration else { return false }
        return true
    }
}
