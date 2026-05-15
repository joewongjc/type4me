import SwiftUI

/// A swappable visual identity. Only tokens that actually vary between themes
/// live here — spacing, bar dimensions, and animations stay invariant in `TF`.
protocol Theme {
    var id: String { get }
    var displayNameZH: String { get }
    var displayNameEN: String { get }

    // Accent colors
    var amber: Color { get }
    var recording: Color { get }
    var success: Color { get }

    // Settings palette
    var settingsBg: Color { get }
    var settingsCard: Color { get }
    var settingsCardAlt: Color { get }
    var settingsNavActiveBg: Color { get }
    var settingsNavActiveFg: Color { get }
    var settingsText: Color { get }
    var settingsTextSecondary: Color { get }
    var settingsTextTertiary: Color { get }
    var settingsAccentGreen: Color { get }
    var settingsAccentAmber: Color { get }
    var settingsAccentRed: Color { get }
    var settingsAccentBlue: Color { get }

    // Corner radii
    var cornerSM: CGFloat { get }
    var cornerMD: CGFloat { get }
    var cornerLG: CGFloat { get }

    /// Floating bar corner radius. Warm uses barHeight/2 (visually a capsule);
    /// hard-edged themes use a small value.
    var floatingBarCornerRadius: CGFloat { get }

    /// The preferred color scheme for windows using this theme.
    var colorScheme: ColorScheme { get }

    /// Processing-progress particle gradient endpoints (left → right), RGB 0...1.
    var processingParticleStart: (r: Double, g: Double, b: Double) { get }
    var processingParticleEnd: (r: Double, g: Double, b: Double) { get }

    /// When true, the floating bar renders instrument-style chrome on top of
    /// its existing content: corner registration marks, a housed status lamp,
    /// a mono telemetry readout, and a bracket mode label. Warm: false.
    var showsTechwearChrome: Bool { get }
}

/// All selectable themes.
enum AppTheme: String, CaseIterable, Identifiable {
    case warm
    case coldIndustrial

    var id: String { rawValue }

    var instance: Theme {
        switch self {
        case .warm: return WarmTheme()
        case .coldIndustrial: return ColdIndustrialTheme()
        }
    }
}
