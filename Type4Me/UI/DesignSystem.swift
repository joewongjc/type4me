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
    static let floatingBackgroundLight = Color(red: 246 / 255, green: 246 / 255, blue: 248 / 255)
    static let floatingBorderLight = Color(red: 218 / 255, green: 218 / 255, blue: 222 / 255)
    /// Contrast floor beneath dark Liquid Glass so the bar stays legible over
    /// bright background content. Native glass alone is too transparent there.
    ///
    /// Do not move this above the glass or into `Glass.tint`: a scrim on top
    /// makes the un-sampled first frames flash harder, and a tint inside the
    /// glass style cannot hold the theme either.
    static let glassDarkContrastFloor: Double = 0.52
    /// A translucent highlight that takes on the material beneath it instead of reading as a flat white rule.
    /// Only used by the macOS 14/15 fallback; native Liquid Glass draws its own rim.
    static let recordingGlassRim = LinearGradient(
        colors: [
            .white.opacity(0.80),
            .white.opacity(0.48),
            .white.opacity(0.30),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    /// A translucent highlight for the light frosted glass theme.
    /// Only used by the macOS 14/15 fallback; native Liquid Glass draws its own rim.
    static let recordingLightGlassRim = LinearGradient(
        colors: [
            .white.opacity(0.95),
            .white.opacity(0.60),
            Color.black.opacity(0.12),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let floatingControl = Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255)
    static let floatingControlLight = Color(red: 251 / 255, green: 251 / 255, blue: 251 / 255)
    static let floatingText = Color.white
    static let floatingTextLight = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let floatingTextSecondaryLight = Color(red: 90 / 255, green: 90 / 255, blue: 95 / 255)

    // MARK: Settings Palette

    // Light values intentionally match the pre-dark-mode palette, including alpha.
    // Neutral overlays retain their original per-control opacity and compositing.
    static let settingsInk = adaptiveColor(light: (0, 0, 0), dark: (1, 1, 1))
    static let settingsFieldText = adaptiveColor(light: (0.10, 0.10, 0.10), dark: (0.94, 0.94, 0.94))
    static let settingsFieldPlaceholder = adaptiveColor(light: (0.42, 0.42, 0.42), dark: (0.67, 0.67, 0.67))
    static let settingsFieldCursor = adaptiveColor(light: (0.25, 0.25, 0.25), dark: (0.94, 0.94, 0.94))
    static let settingsBg = adaptiveColor(light: (0.965, 0.965, 0.965), dark: (0.10, 0.10, 0.10))
    static let settingsCard = adaptiveColor(light: (1, 1, 1), dark: (0.16, 0.16, 0.16))
    static let settingsCardAlt = adaptiveColor(light: (0.935, 0.935, 0.935), dark: (0.20, 0.20, 0.20))
    static let settingsWindowBackground = adaptiveColor(light: (1, 1, 1), dark: (0.12, 0.12, 0.12))
    static let settingsSidebar = adaptiveColor(light: (0.975, 0.975, 0.975), dark: (0.145, 0.145, 0.145))
    static let settingsSidebarActive = adaptiveColor(light: (0.895, 0.895, 0.895), dark: (0.27, 0.27, 0.27))
    static let settingsSidebarHover = adaptiveColor(light: (0.935, 0.935, 0.935), dark: (0.22, 0.22, 0.22))
    static let settingsControl = adaptiveColor(light: (241 / 255, 241 / 255, 241 / 255), dark: (0.20, 0.20, 0.20))
    static let settingsControlHover = adaptiveColor(light: (232 / 255, 232 / 255, 232 / 255), dark: (0.26, 0.26, 0.26))
    static let settingsRowHover = adaptiveColor(light: (248 / 255, 248 / 255, 248 / 255), dark: (0.19, 0.19, 0.19))
    static let settingsBorder = settingsInk.opacity(0.075)
    static let settingsNavActive = adaptiveColor(light: (0.10, 0.10, 0.10), dark: (0.92, 0.92, 0.92))
    static let settingsText = adaptiveColor(light: (0.075, 0.075, 0.075), dark: (0.94, 0.94, 0.94))
    static let settingsTextSecondary = adaptiveColor(light: (0.30, 0.30, 0.30), dark: (0.78, 0.78, 0.78))
    static let settingsTextTertiary = adaptiveColor(light: (0.48, 0.48, 0.48), dark: (0.67, 0.67, 0.67))
    static let settingsOnStrong = adaptiveColor(light: (1, 1, 1), dark: (0.08, 0.08, 0.08))
    static let settingsAccentGreen = adaptiveColor(light: (0.30, 0.62, 0.35), dark: (0.46, 0.82, 0.51))
    static let settingsAccentAmber = adaptiveColor(light: (0.78, 0.55, 0.15), dark: (0.94, 0.72, 0.32))
    static let settingsAccentRed = adaptiveColor(light: (0.80, 0.28, 0.22), dark: (1.0, 0.55, 0.49))
    static let settingsAccentBlue = adaptiveColor(light: (0.15, 0.36, 0.94), dark: (0.52, 0.72, 1.0))

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
    static let recordingTextEdgeInset: CGFloat = 8
    static let recordingTextEdgeFadeWidth: CGFloat = 14
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
    // Fixed control chrome. FloatingBarView adds the text inset for the
    // actual trailing boundary: the visible cancel circle or the capsule edge.
    //
    // Either control can be hidden from Settings, so the width is summed from
    // whichever ones are actually drawn rather than picked from a fixed pair.
    static func recordingChromeWidth(
        showsFinishButton: Bool,
        showsCancelButton: Bool
    ) -> CGFloat {
        var width = recordingLeadingInset + recordingTrailingInset
        if showsFinishButton {
            width += recordingFinishControlSize + recordingControlGap
        }
        if showsCancelButton {
            width += recordingCancelControlSize + recordingControlGap
        }
        return width
    }

    static let recordingChromeWidth: CGFloat = recordingChromeWidth(
        showsFinishButton: true,
        showsCancelButton: true
    )
    static let recordingSingleButtonChromeWidth: CGFloat = recordingChromeWidth(
        showsFinishButton: true,
        showsCancelButton: false
    )

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
