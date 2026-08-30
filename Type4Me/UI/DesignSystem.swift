import SwiftUI

// MARK: - Appearance Helper

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - Adaptive Color Helper

private func adaptiveColor(
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

    // MARK: Colors

    /// Warm amber accent: the signature "indicator light" color
    static let amber = adaptiveColor(
        light: (0.76, 0.49, 0.16),
        dark:  (0.83, 0.57, 0.24)
    )

    /// Recording active: warm red-orange, urgent but not alarming
    static let recording = adaptiveColor(
        light: (0.84, 0.34, 0.27),
        dark:  (0.87, 0.38, 0.30)
    )

    /// Success: muted warm green
    static let success = adaptiveColor(
        light: (0.35, 0.65, 0.35),
        dark:  (0.42, 0.70, 0.42)
    )

    /// Recording indicator palette from the floating-bar design specification.
    static let floatingBackground = Color(red: 17 / 255, green: 18 / 255, blue: 20 / 255) // #111214
    static let floatingBorder = Color(red: 38 / 255, green: 39 / 255, blue: 41 / 255) // #262729
    /// A translucent highlight that takes on the material beneath it instead of reading as a flat white rule.
    static let recordingGlassRim = LinearGradient(
        colors: [
            .white.opacity(0.80),
            .white.opacity(0.48),
            .white.opacity(0.30),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let floatingControl = Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255)
    static let floatingControlLight = Color(red: 251 / 255, green: 251 / 255, blue: 251 / 255)
    static let floatingText = Color.white

    // MARK: Settings Palette

    // The settings window deliberately uses a quiet, neutral palette.  It keeps
    // the sidebar visually separate without drawing a hard divider through the
    // window, and lets the content read as a clean white canvas.
    static let settingsBg = Color(red: 0.965, green: 0.965, blue: 0.965)
    static let settingsCard = Color.white
    static let settingsCardAlt = Color(red: 0.935, green: 0.935, blue: 0.935)
    static let settingsWindowBackground = Color.white
    static let settingsSidebar = Color(red: 0.975, green: 0.975, blue: 0.975)
    static let settingsSidebarActive = Color(red: 0.895, green: 0.895, blue: 0.895)
    static let settingsSidebarHover = Color(red: 0.935, green: 0.935, blue: 0.935)
    /// Default, hover, and row-hover fills shared by settings controls.
    static let settingsControl = Color(red: 241 / 255, green: 241 / 255, blue: 241 / 255)
    static let settingsControlHover = Color(red: 232 / 255, green: 232 / 255, blue: 232 / 255)
    static let settingsRowHover = Color(red: 248 / 255, green: 248 / 255, blue: 248 / 255)
    static let settingsBorder = Color.black.opacity(0.075)
    static let settingsNavActive = Color(red: 0.10, green: 0.10, blue: 0.10)
    static let settingsText = Color(red: 0.075, green: 0.075, blue: 0.075)
    static let settingsTextSecondary = Color(red: 0.30, green: 0.30, blue: 0.30)
    static let settingsTextTertiary = Color(red: 0.48, green: 0.48, blue: 0.48)
    static let settingsAccentGreen = Color(red: 0.30, green: 0.62, blue: 0.35)
    static let settingsAccentAmber = Color(red: 0.78, green: 0.55, blue: 0.15)
    static let settingsAccentRed = Color(red: 0.80, green: 0.28, blue: 0.22)
    static let settingsAccentBlue = Color(red: 0.15, green: 0.36, blue: 0.94)

    // MARK: Spacing

    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 12
    static let spacingLG: CGFloat = 16
    static let spacingXL: CGFloat = 24

    // MARK: Corner Radius

    static let cornerSM: CGFloat = 6
    static let cornerMD: CGFloat = 10
    static let cornerLG: CGFloat = 16

    // MARK: Floating Bar

    static let barWidth: CGFloat = 400
    static let barWidthCompact: CGFloat = 180
    static let barHeight: CGFloat = 55
    static let barBottomOffset: CGFloat = 48
    static let floatingPanelShadowInset: CGFloat = 8
    static let recordingFinishControlSize: CGFloat = 45
    static let recordingCancelControlSize: CGFloat = 35
    static let recordingLeadingInset: CGFloat = 5
    static let recordingTrailingInset: CGFloat = 10
    static let recordingEdgeInset: CGFloat = recordingTrailingInset
    static let recordingControlGap: CGFloat = 8
    static let recordingTooltipGap: CGFloat = 5
    static let recordingTooltipMaxWidth: CGFloat = 180
    static let recordingCapsuleSpringResponse = 0.3
    static let recordingTooltipBadge = Color(
        red: 138 / 255,
        green: 138 / 255,
        blue: 138 / 255
    )
    static let recordingTooltipOverhang: CGFloat = max(
        0,
        recordingTooltipMaxWidth / 2 - recordingLeadingInset - recordingFinishControlSize / 2
    )
    static let recordingChromeWidth: CGFloat = recordingFinishControlSize
        + recordingCancelControlSize
        + recordingLeadingInset
        + recordingTrailingInset
        + recordingControlGap * 2
        + 16
    static let recordingSingleButtonChromeWidth: CGFloat = recordingFinishControlSize
        + recordingLeadingInset
        + recordingTrailingInset
        + recordingControlGap
        + 16

    // MARK: Transcript Popup (hover preview above bar)

    static let transcriptPopupWidth: CGFloat = 350
    static let transcriptPopupMaxHeight: CGFloat = 120
    static let transcriptPopupCorner: CGFloat = cornerLG
    static let transcriptPopupGap: CGFloat = 10

    // MARK: Compact Recording Indicator

    static let compactIndicatorWidth: CGFloat = barWidthCompact
    static let compactIndicatorHeight: CGFloat = 24
    static let compactTranscriptLaneHeight: CGFloat = 24
    static let compactTranscriptExpandedHeight: CGFloat = 48
    static let compactTranscriptFontSize: CGFloat = 12
    static let compactTranscriptCornerRadius: CGFloat = 10
    static let compactTranscriptHorizontalInset: CGFloat = 8
    static let compactTranscriptLeadingFadeWidth: CGFloat = 10
    static let compactIndicatorControlVisualSize: CGFloat = 15
    static let compactIndicatorWaveBarWidth: CGFloat = 2
    static let compactIndicatorWaveMinHeight: CGFloat = 2
    static let compactIndicatorWaveMaxHeight: CGFloat = 18
    static let compactStatusMaxWidth: CGFloat = barWidth

    static let compactIndicatorActive = floatingControlLight
    static let compactIndicatorInactive = recordingTooltipBadge

    // MARK: Animation

    static let springSnappy = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let springGentle = Animation.spring(response: 0.5, dampingFraction: 0.75)
    static let springBouncy = Animation.spring(response: 0.4, dampingFraction: 0.65)
    static let easeQuick = Animation.easeOut(duration: 0.2)
    static let glassTint = Animation.easeInOut(duration: 0.5)
}
