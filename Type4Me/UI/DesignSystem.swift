import SwiftUI

// MARK: - Appearance Helper

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - Adaptive Color Helper

func adaptiveColor(
    light: (r: CGFloat, g: CGFloat, b: CGFloat),
    dark: (r: CGFloat, g: CGFloat, b: CGFloat)
) -> Color {
    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.isDark {
            return NSColor(srgbRed: dark.r, green: dark.g, blue: dark.b, alpha: 1.0)
        }
        return NSColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: 1.0)
    }))
}

// MARK: - Design Tokens

enum TF {

    // MARK: Colors (theme-driven)

    private static var theme: Theme { ThemeStore.shared.current.instance }

    static var amber: Color { theme.amber }
    static var recording: Color { theme.recording }
    static var success: Color { theme.success }

    // MARK: Settings Palette (theme-driven)

    static var settingsBg: Color { theme.settingsBg }
    static var settingsCard: Color { theme.settingsCard }
    static var settingsCardAlt: Color { theme.settingsCardAlt }
    static var settingsNavActiveBg: Color { theme.settingsNavActiveBg }
    static var settingsNavActiveFg: Color { theme.settingsNavActiveFg }
    static var settingsText: Color { theme.settingsText }
    static var settingsTextSecondary: Color { theme.settingsTextSecondary }
    static var settingsTextTertiary: Color { theme.settingsTextTertiary }
    static var settingsAccentGreen: Color { theme.settingsAccentGreen }
    static var settingsAccentAmber: Color { theme.settingsAccentAmber }
    static var settingsAccentRed: Color { theme.settingsAccentRed }
    static var settingsAccentBlue: Color { theme.settingsAccentBlue }

    // MARK: Color Scheme (theme-driven)

    static var colorScheme: ColorScheme { theme.colorScheme }
    static var processingParticleStart: (r: Double, g: Double, b: Double) { theme.processingParticleStart }
    static var processingParticleEnd: (r: Double, g: Double, b: Double) { theme.processingParticleEnd }
    static var showsTechwearChrome: Bool { theme.showsTechwearChrome }

    // MARK: Spacing

    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 12
    static let spacingLG: CGFloat = 16
    static let spacingXL: CGFloat = 24

    // MARK: Corner Radius (theme-driven)

    static var cornerSM: CGFloat { theme.cornerSM }
    static var cornerMD: CGFloat { theme.cornerMD }
    static var cornerLG: CGFloat { theme.cornerLG }
    static var floatingBarCornerRadius: CGFloat { theme.floatingBarCornerRadius }

    // MARK: Floating Bar

    static let barWidth: CGFloat = 400
    static let barWidthCompact: CGFloat = 200
    static let barHeight: CGFloat = 52
    static let barBottomOffset: CGFloat = 48

    // MARK: Transcript Popup (hover preview above bar)

    static let transcriptPopupMaxHeight: CGFloat = 400
    static let transcriptPopupCorner: CGFloat = 14
    static let transcriptPopupGap: CGFloat = 8

    // MARK: Animation

    static let springSnappy = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let springGentle = Animation.spring(response: 0.5, dampingFraction: 0.75)
    static let springBouncy = Animation.spring(response: 0.4, dampingFraction: 0.65)
    static let easeQuick = Animation.easeOut(duration: 0.2)
    static let glassTint = Animation.easeInOut(duration: 0.5)
}
