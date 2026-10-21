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
}
