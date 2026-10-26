import Foundation

enum AudioCapturePreparationPolicy {
    static func allowsPreparedSession(
        for category: AudioInputDeviceCategory,
        isAggregateWithBluetooth: Bool
    ) -> Bool {
        switch category {
        case .builtIn, .external:
            return true
        case .virtual:
            return !isAggregateWithBluetooth
        case .bluetooth, .other:
            return false
        }
    }

    /// Whether a just-stopped graph may stay attached for reuse. Judged from the
    /// device the graph actually captured, never from a freshly resolved target,
    /// and only kept when that device is still the one the next start resolves to.
    static func shouldRetainAfterStop(
        isEnabled: Bool,
        pendingInvalidate: Bool,
        capturedDeviceUID: String?,
        capturedCategory: AudioInputDeviceCategory,
        capturedIsAggregateWithBluetooth: Bool,
        targetDeviceUID: String?
    ) -> Bool {
        guard isEnabled, !pendingInvalidate,
              let capturedDeviceUID, capturedDeviceUID == targetDeviceUID else { return false }
        return allowsPreparedSession(
            for: capturedCategory,
            isAggregateWithBluetooth: capturedIsAggregateWithBluetooth
        )
    }
}
