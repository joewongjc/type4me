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

        defaults.set(RecordingGlassStyle.custom.rawValue, forKey: RecordingGlassStyle.storageKey)
        XCTAssertTrue(RecordingGlassTuning.panelKeepsActiveAppearance(defaults: defaults))
        defaults.set(false, forKey: RecordingGlassTuning.StorageKey.keepsActiveAppearance)
        XCTAssertFalse(RecordingGlassTuning.panelKeepsActiveAppearance(defaults: defaults))

        defaults.set(RecordingGlassStyle.standard.rawValue, forKey: RecordingGlassStyle.storageKey)
        defaults.set(true, forKey: RecordingGlassTuning.StorageKey.keepsActiveAppearance)
        XCTAssertFalse(RecordingGlassTuning.panelKeepsActiveAppearance(defaults: defaults))
        defaults.removePersistentDomain(forName: "RecordingGlassTuningTests")
    }

    func testStorageKeysAreDistinct() {
        let keys = RecordingGlassTuning.StorageKey.all + [RecordingGlassStyle.storageKey]
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testPreviewDefaultsToPlainBackdrop() {
        XCTAssertEqual(PreviewBackdrop.defaultValue, .plain)
    }
}
