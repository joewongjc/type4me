import SwiftUI

/// The default theme — reproduces the original DesignSystem.swift values
/// exactly. Selecting "Warm" must be visually indistinguishable from the
/// pre-theme-system app.
struct WarmTheme: Theme {
    let id = "warm"
    let displayNameZH = "经典"
    let displayNameEN = "Warm"

    // Accent colors — identical to original TF.amber / .recording / .success
    let amber = adaptiveColor(
        light: (0.76, 0.49, 0.16),
        dark:  (0.83, 0.57, 0.24)
    )
    let recording = adaptiveColor(
        light: (0.84, 0.34, 0.27),
        dark:  (0.87, 0.38, 0.30)
    )
    let success = adaptiveColor(
        light: (0.35, 0.65, 0.35),
        dark:  (0.42, 0.70, 0.42)
    )

    // Settings palette — identical to original TF.settings* literals
    let settingsBg = Color(red: 0.95, green: 0.92, blue: 0.88)
    let settingsCard = Color(red: 0.98, green: 0.96, blue: 0.93)
    let settingsCardAlt = Color(red: 0.91, green: 0.89, blue: 0.85)
    let settingsNavActiveBg = Color(red: 0.10, green: 0.10, blue: 0.10)
    let settingsNavActiveFg = Color(red: 0.10, green: 0.10, blue: 0.10)
    let settingsText = Color(red: 0.10, green: 0.10, blue: 0.10)
    let settingsTextSecondary = Color(red: 0.24, green: 0.24, blue: 0.24)
    let settingsTextTertiary = Color(red: 0.42, green: 0.42, blue: 0.42)
    let settingsAccentGreen = Color(red: 0.30, green: 0.62, blue: 0.35)
    let settingsAccentAmber = Color(red: 0.78, green: 0.55, blue: 0.15)
    let settingsAccentRed = Color(red: 0.80, green: 0.28, blue: 0.22)
    let settingsAccentBlue = Color(red: 0.20, green: 0.45, blue: 0.75)

    // Corner radii — identical to original TF.cornerSM / .cornerMD / .cornerLG
    let cornerSM: CGFloat = 6
    let cornerMD: CGFloat = 10
    let cornerLG: CGFloat = 16

    // barHeight/2 → RoundedRectangle at this radius is visually identical to a Capsule
    let floatingBarCornerRadius: CGFloat = 26

    let colorScheme: ColorScheme = .light

    let processingParticleStart: (r: Double, g: Double, b: Double) = (0.82, 0.85, 1.0)
    let processingParticleEnd: (r: Double, g: Double, b: Double) = (0.40, 0.60, 1.0)

    // No instrument chrome — Warm is visually identical to the pre-theme app.
    let showsTechwearChrome = false
}
