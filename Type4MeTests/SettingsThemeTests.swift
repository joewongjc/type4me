import AppKit
import SwiftUI
import XCTest
@testable import Type4Me

final class SettingsThemeTests: XCTestCase {
    func testDefaultAndUnknownPreferenceFollowSystem() {
        XCTAssertEqual(SettingsTheme.defaultValue, .system)
        XCTAssertEqual(SettingsTheme.resolve("future-value"), .system)
        XCTAssertNil(SettingsTheme.system.colorScheme)
        XCTAssertNil(SettingsTheme.system.appearance)
        XCTAssertNotEqual(SettingsTheme.storageKey, RecordingTheme.storageKey)
    }

    func testExplicitThemesOverrideAppearance() {
        XCTAssertEqual(SettingsTheme.light.colorScheme, .light)
        XCTAssertEqual(SettingsTheme.dark.colorScheme, .dark)
        XCTAssertEqual(SettingsTheme.light.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertEqual(SettingsTheme.dark.appearance?.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
    }

    func testLabelsCanSwitchLanguageWithoutChangingSavedValues() {
        let themes = SettingsTheme.allCases
        let savedValues = themes.map(\.rawValue)
        XCTAssertEqual(themes.map { $0.displayName(language: .zh) }, ["跟随系统", "浅色", "深色"])
        XCTAssertEqual(themes.map { $0.displayName(language: .en) }, ["Follow System", "Light", "Dark"])
        XCTAssertEqual(themes.map { $0.displayName(language: .zh) }, ["跟随系统", "浅色", "深色"])
        XCTAssertEqual(savedValues.map(SettingsTheme.resolve), themes)
    }

    func testThemeIconsAreDefinedAndAvailable() {
        XCTAssertEqual(SettingsTheme.system.iconName, "circle.lefthalf.filled")
        XCTAssertEqual(SettingsTheme.light.iconName, "sun.max.fill")
        XCTAssertEqual(SettingsTheme.dark.iconName, "moon.fill")
        for theme in SettingsTheme.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: theme.iconName, accessibilityDescription: nil),
                            "Icon symbol for \(theme.rawValue) must exist in system symbols")
        }
    }

    func testDarkSettingsTextAndSolidButtonContrast() {
        let surfaces = [TF.settingsWindowBackground, TF.settingsBg, TF.settingsCard,
                        TF.settingsCardAlt, TF.settingsSidebar, TF.settingsControl]
        let textColors = [TF.settingsText, TF.settingsTextSecondary, TF.settingsTextTertiary,
                          TF.settingsAccentBlue, TF.settingsAccentGreen,
                          TF.settingsAccentAmber, TF.settingsAccentRed]
        for name in [NSAppearance.Name.darkAqua] {
            let appearance = NSAppearance(named: name)!
            for surface in surfaces {
                for text in textColors {
                    XCTAssertGreaterThanOrEqual(contrast(text, surface, appearance), 4.5,
                                                "Text contrast under \(name)")
                }
            }
            for fill in [TF.settingsText, TF.settingsNavActive, TF.settingsAccentBlue,
                         TF.settingsAccentGreen, TF.settingsAccentAmber, TF.settingsAccentRed] {
                XCTAssertGreaterThanOrEqual(contrast(TF.settingsOnStrong, fill, appearance), 4.5,
                                            "Button contrast under \(name)")
            }
        }
    }

    // Snapshot of the light palette before PR #288 (1486b10a).
    // Dark-mode support must not change RGB values or alpha compositing in light mode.
    func testLightPalettePreservesOriginalColorsAndAlpha() {
        let pairs: [(String, Color, Color)] = [
            ("settingsBg", TF.settingsBg, Color(red: 0.965, green: 0.965, blue: 0.965)),
            ("settingsCard", TF.settingsCard, Color.white),
            ("settingsCardAlt", TF.settingsCardAlt, Color(red: 0.935, green: 0.935, blue: 0.935)),
            ("settingsWindowBackground", TF.settingsWindowBackground, Color.white),
            ("settingsSidebar", TF.settingsSidebar, Color(red: 0.975, green: 0.975, blue: 0.975)),
            ("settingsSidebarActive", TF.settingsSidebarActive, Color(red: 0.895, green: 0.895, blue: 0.895)),
            ("settingsSidebarHover", TF.settingsSidebarHover, Color(red: 0.935, green: 0.935, blue: 0.935)),
            ("settingsControl", TF.settingsControl, Color(red: 241 / 255, green: 241 / 255, blue: 241 / 255)),
            ("settingsControlHover", TF.settingsControlHover, Color(red: 232 / 255, green: 232 / 255, blue: 232 / 255)),
            ("settingsRowHover", TF.settingsRowHover, Color(red: 248 / 255, green: 248 / 255, blue: 248 / 255)),
            ("settingsBorder", TF.settingsBorder, Color.black.opacity(0.075)),
            ("settingsNavActive", TF.settingsNavActive, Color(red: 0.10, green: 0.10, blue: 0.10)),
            ("settingsText", TF.settingsText, Color(red: 0.075, green: 0.075, blue: 0.075)),
            ("settingsTextSecondary", TF.settingsTextSecondary, Color(red: 0.30, green: 0.30, blue: 0.30)),
            ("settingsTextTertiary", TF.settingsTextTertiary, Color(red: 0.48, green: 0.48, blue: 0.48)),
            ("settingsAccentGreen", TF.settingsAccentGreen, Color(red: 0.30, green: 0.62, blue: 0.35)),
            ("settingsAccentAmber", TF.settingsAccentAmber, Color(red: 0.78, green: 0.55, blue: 0.15)),
            ("settingsAccentRed", TF.settingsAccentRed, Color(red: 0.80, green: 0.28, blue: 0.22)),
            ("settingsAccentBlue", TF.settingsAccentBlue, Color(red: 0.15, green: 0.36, blue: 0.94)),
            ("field text", TF.settingsFieldText, Color(red: 0.10, green: 0.10, blue: 0.10)),
            ("field placeholder", TF.settingsFieldPlaceholder, Color(red: 0.42, green: 0.42, blue: 0.42)),
            ("field cursor", TF.settingsFieldCursor, Color(red: 0.25, green: 0.25, blue: 0.25)),
            ("solid button label", TF.settingsOnStrong, .white),
            ("neutral overlay", TF.settingsInk, .black),
        ]
        let appearance = NSAppearance(named: .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            for (name, actual, expected) in pairs {
                let actual = NSColor(actual).usingColorSpace(.sRGB)!
                let expected = NSColor(expected).usingColorSpace(.sRGB)!
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.00001, name)
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.00001, name)
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.00001, name)
                XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.00001, name)
            }
        }
    }

    private func contrast(_ first: Color, _ second: Color, _ appearance: NSAppearance) -> Double {
        func luminance(_ color: Color) -> Double {
            var result = 0.0
            appearance.performAsCurrentDrawingAppearance {
                let rgb = NSColor(color).usingColorSpace(.sRGB)!
                func linear(_ value: CGFloat) -> Double {
                    let value = Double(value)
                    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                result = 0.2126 * linear(rgb.redComponent)
                    + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
            }
            return result
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
