import Foundation

enum RecordingGlassBlurEffect: String, CaseIterable, Sendable {
    case clear
    case frosted
}

/// Resolved, clamped glass parameters shared by the Settings preview and live panel.
///
/// The accepted light theme fixes native style and tint, leaving transparency
/// as its sole user-facing calibration axis.
struct RecordingGlassTuning: Equatable, Sendable {
    static let transparencyKey = "tf_recordingGlassTransparency"

    // Read-only compatibility key used to migrate the first debug build.
    private static let legacyMaterialOpacityKey = "tf_recordingGlassMaterialOpacity"

    /// Calibrated from the accepted light-glass configuration. Existing users
    /// keep their exact saved value; new installs start at a clean 10%.
    static let defaultTransparency = 0.10
    let transparency: Double

    init(
        transparency: Double = defaultTransparency
    ) {
        self.transparency = Self.clamp(transparency)
    }

    /// The native material view uses opacity, while the UI intentionally exposes
    /// the more intuitive inverse value: 0% transparency is fully materialized.
    var materialOpacity: Double {
        1 - transparency
    }

    /// Preserve values from the first calibration build without keeping its
    /// redundant controls in the current data model.
    static func migrateLegacyPreferencesIfNeeded(
        userDefaults: UserDefaults = .standard
    ) {
        if userDefaults.object(forKey: transparencyKey) == nil,
           let legacyOpacity = userDefaults.object(forKey: legacyMaterialOpacityKey) as? NSNumber {
            userDefaults.set(
                1 - clamp(legacyOpacity.doubleValue),
                forKey: transparencyKey
            )
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
