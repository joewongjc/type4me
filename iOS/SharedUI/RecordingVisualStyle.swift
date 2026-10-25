import Foundation

/// The Mac app's recording visual presets. The iPhone ships only the default
/// (`siri`) for now, but keeps the same raw values so the shared
/// `OrbPreset.swift` compiles unchanged and a later setting can sync with Mac.
enum RecordingVisualStyle: String, CaseIterable {
    case siri
    case blueDrop
    case chromaticMetal
    case frost
    case opal
    case voiceWave
    case violetEmber
    case aurora
    case chrome
    case spectrum
    case staticSiri = "staticSiri"

    var isAnimated: Bool { self != .staticSiri }
}

/// Written from the keyboard's state callback, read every render frame by the
/// orb. Deliberately not observable, mirroring the Mac `AudioLevelMeter`.
final class AudioLevelMeter: @unchecked Sendable {
    var current: Float = 0
}
