import XCTest
@testable import Type4Me

final class RecordingGlassTuningTests: XCTestCase {

    private let custom = RecordingGlassTuning(
        floorOpacity: 0.1,
        edgeFade: 12,
        rimStrength: 1.5,
        glassTint: 0.2,
        usesClearGlass: true,
        shadowStrength: 0.3,
        keepsActiveAppearance: false
    )

    func testStandardKeepsOriginalSurface() {
        XCTAssertNil(RecordingGlassTuning.resolved(style: .standard, theme: .dark, custom: custom))
    }

    func testEnhancedIsDefaultAndCustomStartsFromIt() {
        XCTAssertEqual(RecordingGlassStyle.defaultValue, .enhanced)
        XCTAssertEqual(RecordingGlassTuning.customDefault, RecordingGlassTuning.enhanced(for: .light))
    }

    func testEnhancedIgnoresCustomValuesAndFollowsTheme() {
        let dark = RecordingGlassTuning.resolved(style: .enhanced, theme: .dark, custom: custom)
        let light = RecordingGlassTuning.resolved(style: .enhanced, theme: .light, custom: custom)
        XCTAssertEqual(dark, RecordingGlassTuning.enhanced(for: .dark))
        XCTAssertEqual(light, RecordingGlassTuning.enhanced(for: .light))
        // Enhanced must be visibly thinner than the standard contrast floors.
        XCTAssertLessThan(dark!.floorOpacity, TF.glassDarkContrastFloor)
        XCTAssertLessThan(light!.floorOpacity, TF.glassLightContrastFloor)
        // White text needs a thin dark floor over bright pages; light stays clear.
        XCTAssertGreaterThan(dark!.floorOpacity, 0)
        XCTAssertEqual(light!.floorOpacity, 0)
    }

    func testCustomUsesStoredValues() {
        XCTAssertEqual(RecordingGlassTuning.resolved(style: .custom, theme: .light, custom: custom), custom)
    }

    func testCustomDefaultsSitInsideSliderRanges() {
        let d = RecordingGlassTuning.customDefault
        XCTAssertTrue(RecordingGlassTuning.floorRange.contains(d.floorOpacity))
        XCTAssertTrue(RecordingGlassTuning.edgeFadeRange.contains(d.edgeFade))
        XCTAssertTrue(RecordingGlassTuning.rimStrengthRange.contains(d.rimStrength))
        XCTAssertTrue(RecordingGlassTuning.glassTintRange.contains(d.glassTint))
        XCTAssertTrue(RecordingGlassTuning.shadowStrengthRange.contains(d.shadowStrength))
    }

    func testPanelActiveAppearanceFollowsStyle() {
        let defaults = UserDefaults(suiteName: "RecordingGlassTuningTests")!
        defaults.removePersistentDomain(forName: "RecordingGlassTuningTests")
        // Unset style falls back to the enhanced default.
        XCTAssertTrue(RecordingGlassTuning.panelKeepsActiveAppearance(defaults: defaults))

        defaults.set(RecordingGlassStyle.enhanced.rawValue, forKey: RecordingGlassStyle.storageKey)
        XCTAssertTrue(RecordingGlassTuning.panelKeepsActiveAppearance(defaults: defaults))

        defaults.set(RecordingGlassStyle.system.rawValue, forKey: RecordingGlassStyle.storageKey)
        XCTAssertTrue(RecordingGlassTuning.panelKeepsActiveAppearance(defaults: defaults))

        defaults.set(RecordingGlassStyle.custom.rawValue, forKey: RecordingGlassStyle.storageKey)
        XCTAssertTrue(RecordingGlassTuning.panelKeepsActiveAppearance(defaults: defaults))
        defaults.set(false, forKey: RecordingGlassTuning.StorageKey.keepsActiveAppearance)
        XCTAssertFalse(RecordingGlassTuning.panelKeepsActiveAppearance(defaults: defaults))

        defaults.set(RecordingGlassStyle.standard.rawValue, forKey: RecordingGlassStyle.storageKey)
        defaults.set(true, forKey: RecordingGlassTuning.StorageKey.keepsActiveAppearance)
        XCTAssertFalse(RecordingGlassTuning.panelKeepsActiveAppearance(defaults: defaults))
        defaults.removePersistentDomain(forName: "RecordingGlassTuningTests")
    }

    // MARK: - System glass

    func testSystemGlassKeepsThemeTextReadableOnBothThemes() {
        for theme in RecordingTheme.allCases {
            let tuning = RecordingGlassTuning.resolved(
                style: .system, theme: theme, custom: custom, systemGlassAvailable: true
            )
            XCTAssertEqual(tuning, RecordingGlassTuning.system(for: theme))
            XCTAssertEqual(tuning?.usesSystemGlass, true)
            // The floorless light preset is what let dark text vanish over dark windows.
            XCTAssertGreaterThan(tuning?.floorOpacity ?? 0, 0, "\(theme)")
            XCTAssertTrue(RecordingGlassTuning.floorRange.contains(tuning?.floorOpacity ?? -1))
        }
    }

    func testSystemFallsBackToEnhancedWithoutPrivateGlass() {
        for theme in RecordingTheme.allCases {
            XCTAssertEqual(
                RecordingGlassTuning.resolved(style: .system, theme: theme, custom: custom, systemGlassAvailable: false),
                RecordingGlassTuning.enhanced(for: theme)
            )
        }
        var systemCustom = custom
        systemCustom.usesSystemGlass = true
        XCTAssertEqual(
            RecordingGlassTuning.resolved(style: .custom, theme: .dark, custom: systemCustom, systemGlassAvailable: true)?
                .usesSystemGlass,
            true
        )
        XCTAssertEqual(
            RecordingGlassTuning.resolved(style: .custom, theme: .dark, custom: systemCustom, systemGlassAvailable: false)?
                .usesSystemGlass,
            false
        )
    }

    func testSystemOptionIsOfferedOnlyWithPrivateGlassAndIsNotTheDefault() {
        XCTAssertEqual(RecordingGlassStyle.defaultValue, .enhanced)
        XCTAssertFalse(RecordingGlassTuning.customDefault.usesSystemGlass)
        XCTAssertEqual(RecordingGlassStyle.availableCases(systemGlassAvailable: true), [.standard, .enhanced, .system, .custom])
        XCTAssertEqual(RecordingGlassStyle.availableCases(systemGlassAvailable: false), [.standard, .enhanced, .custom])
    }

    func testStyleNamesFollowLanguageSetting() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: "tf_language")
        defer {
            if let original {
                defaults.set(original, forKey: "tf_language")
            } else {
                defaults.removeObject(forKey: "tf_language")
            }
        }
        defaults.set("zh", forKey: "tf_language")
        XCTAssertEqual(RecordingGlassStyle.allCases.map(\.displayName), ["标准", "增强", "系统浮窗", "自定义"])
        defaults.set("en", forKey: "tf_language")
        XCTAssertEqual(RecordingGlassStyle.allCases.map(\.displayName), ["Standard", "Enhanced", "System", "Custom"])
    }

    func testStorageKeysAreDistinct() {
        let keys = RecordingGlassTuning.StorageKey.all + [RecordingGlassStyle.storageKey]
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testPreviewDefaultsToPlainBackdrop() {
        XCTAssertEqual(PreviewBackdrop.defaultValue, .plain)
    }
}
