import SwiftUI

/// Cold Industrial Console — black-dominant, red is the only signal color,
/// hard edges. Palette drawn from an industrial instrument-panel design
/// vocabulary (ink ladder + fg greyscale + red signal).
///
/// This system is monochrome + red by design: there is no green / blue / amber.
/// "Accent" tokens that have no equivalent (green/blue) map to fg-greyscale —
/// in this language a state is either the red signal or it is calm grey.
struct ColdIndustrialTheme: Theme {
    let id = "coldIndustrial"
    let displayNameZH = "进化"
    let displayNameEN = "Evolution"

    // Accent — red (#E50914) is "signal engaged": success / operational / live.
    // Grey (#8A8F99) is "inert": failure / no signal.
    let amber = Color(red: 0.898, green: 0.035, blue: 0.078)       // #E50914 — the accent IS red here
    let recording = Color(red: 0.898, green: 0.035, blue: 0.078)   // #E50914 signal — recording is engaged
    let success = Color(red: 0.898, green: 0.035, blue: 0.078)     // #E50914 — success is "signal engaged", lit red

    // Settings palette — ink ladder (ink-100/200/300) + fg greyscale (fg-100/200/300).
    let settingsBg = Color(red: 0.039, green: 0.043, blue: 0.055)         // #0A0B0E ink-100
    let settingsCard = Color(red: 0.063, green: 0.071, blue: 0.086)       // #101216 ink-200
    let settingsCardAlt = Color(red: 0.094, green: 0.102, blue: 0.125)    // #181A20 ink-300
    let settingsNavActiveBg = Color(red: 0.133, green: 0.145, blue: 0.173)  // #22252C ink-400 — raised dark surface
    let settingsNavActiveFg = Color(red: 0.910, green: 0.925, blue: 0.949)  // #E8ECF2 fg-100 — light emphasis text
    let settingsText = Color(red: 0.910, green: 0.925, blue: 0.949)       // #E8ECF2 fg-100
    let settingsTextSecondary = Color(red: 0.753, green: 0.773, blue: 0.812) // #C0C5CF fg-200
    let settingsTextTertiary = Color(red: 0.541, green: 0.561, blue: 0.600)  // #8A8F99 fg-300
    let settingsAccentGreen = Color(red: 0.898, green: 0.035, blue: 0.078)   // #E50914 — success / saved / granted = engaged
    let settingsAccentAmber = Color(red: 0.478, green: 0.051, blue: 0.078)   // #7A0D14 red-dim — caution
    let settingsAccentRed = Color(red: 0.541, green: 0.561, blue: 0.600)     // #8A8F99 — failure / error = inert grey
    let settingsAccentBlue = Color(red: 0.541, green: 0.561, blue: 0.600)    // #8A8F99 — no blue; info state is grey

    // Corner radii — hard edges
    let cornerSM: CGFloat = 0
    let cornerMD: CGFloat = 2
    let cornerLG: CGFloat = 2

    let floatingBarCornerRadius: CGFloat = 2

    let colorScheme: ColorScheme = .dark

    let processingParticleStart: (r: Double, g: Double, b: Double) = (0.901, 0.914, 0.937)  // ~fg-100 light
    let processingParticleEnd: (r: Double, g: Double, b: Double) = (0.898, 0.035, 0.078)    // #E50914 red

    // Instrument chrome — the floating bar reads as a measurement panel.
    let showsTechwearChrome = true
}
