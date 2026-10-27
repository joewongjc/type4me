//
//  RecordingTheme.swift
//  Type4Me
//

import Foundation
import SwiftUI

/// Appearance theme for the floating recording indicator and related overlays.
enum RecordingTheme: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    static let storageKey = "tf_recordingTheme"
    static let defaultValue = RecordingTheme.dark

    var displayName: String {
        switch self {
        case .dark:
            L("暗色", "Dark")
        case .light:
            L("明亮", "Light")
        }
    }
}

/// Native Liquid Glass finish for the recording bar (macOS 26+). `.standard`
/// keeps the original look; `.enhanced` (the default) drops the contrast floor
/// for clear, active glass with a drop shadow for depth; `.custom` exposes
/// every knob.
enum RecordingGlassStyle: String, CaseIterable, Identifiable {
    case standard
    case enhanced
    case custom

    var id: String { rawValue }

    static let storageKey = "tf_recordingGlassStyle"
    static let defaultValue = RecordingGlassStyle.enhanced

    var displayName: String {
        switch self {
        case .standard:
            L("标准", "Standard")
        case .enhanced:
            L("增强", "Enhanced")
        case .custom:
            L("自定义", "Custom")
        }
    }
}

/// Parameters of the native glass surface. Opacities are 0...1; `edgeFade`
/// is in points and is capped by the surface's corner radius when drawn.
struct RecordingGlassTuning: Equatable {
    /// Theme-coloured floor beneath the glass. The glass samples it before the
    /// desktop, so this is the main dial between "legible" and "see-through".
    var floorOpacity: Double
    /// How far in from the rim the floor fades out, letting the edge lens
    /// refract the real background.
    var edgeFade: Double
    /// Multiplier on the soft specular rim; 0 hides it.
    var rimStrength: Double
    /// Theme-coloured tint applied inside the glass material itself.
    var glassTint: Double
    /// `Glass.clear` instead of `Glass.regular`: less frost, more see-through.
    var usesClearGlass: Bool
    /// Soft drop shadow drawn only outside the bar. Over flat light pages the
    /// glass has nothing to refract, so this depth cue is what reads as glass.
    var shadowStrength: Double
    /// macOS renders a heavily frosted "inactive" glass in windows without key
    /// appearance, and the recording panel can never become key. When true the
    /// panel reports an active appearance so the glass stays clear and
    /// refractive, as it looks in a focused window.
    var keepsActiveAppearance: Bool

    static let floorRange: ClosedRange<Double> = 0...0.9
    static let edgeFadeRange: ClosedRange<Double> = 0...20
    static let rimStrengthRange: ClosedRange<Double> = 0...2
    static let glassTintRange: ClosedRange<Double> = 0...0.6
    static let shadowStrengthRange: ClosedRange<Double> = 0...1

    /// `nil` for `.standard`, which keeps the original surface untouched.
    static func resolved(
        style: RecordingGlassStyle,
        theme: RecordingTheme,
        custom: RecordingGlassTuning
    ) -> RecordingGlassTuning? {
        switch style {
        case .standard:
            nil
        case .enhanced:
            enhanced(for: theme)
        case .custom:
            custom
        }
    }

    /// Tuned by eye on the real panel (2026-10): no extra rim, full drop
    /// shadow for depth on flat pages. Light has no floor so the glass shows
    /// the desktop. Active glass over a white page renders mid grey, which left
    /// dark-theme white text near 2.5:1, so dark keeps a thin floor.
    static func enhanced(for theme: RecordingTheme) -> RecordingGlassTuning {
        RecordingGlassTuning(
            floorOpacity: theme == .dark ? 0.30 : 0,
            edgeFade: 0,
            rimStrength: 0,
            glassTint: 0,
            usesClearGlass: false,
            shadowStrength: 1,
            keepsActiveAppearance: true
        )
    }

    /// Custom starts from the enhanced preset. Custom values apply to both
    /// themes, so start from the floorless light variant.
    static let customDefault = enhanced(for: .light)

    enum StorageKey {
        static let floorOpacity = "tf_recordingGlassFloorOpacity"
        static let edgeFade = "tf_recordingGlassEdgeFade"
        static let rimStrength = "tf_recordingGlassRimStrength"
        static let glassTint = "tf_recordingGlassTint"
        static let usesClearGlass = "tf_recordingGlassUsesClear"
        static let shadowStrength = "tf_recordingGlassShadowStrength"
        static let keepsActiveAppearance = "tf_recordingGlassKeepsActive"

        static let all = [
            floorOpacity, edgeFade, rimStrength, glassTint, usesClearGlass, shadowStrength,
            keepsActiveAppearance,
        ]
    }

    /// Whether the floating panel should report an active appearance, read
    /// straight from defaults because AppKit asks the window, not the view.
    static func panelKeepsActiveAppearance(defaults: UserDefaults = .standard) -> Bool {
        let style = defaults.string(forKey: RecordingGlassStyle.storageKey)
            .flatMap(RecordingGlassStyle.init(rawValue:)) ?? .defaultValue
        switch style {
        case .standard:
            return false
        case .enhanced:
            return enhanced(for: .dark).keepsActiveAppearance
        case .custom:
            return defaults.object(forKey: StorageKey.keepsActiveAppearance) as? Bool
                ?? customDefault.keepsActiveAppearance
        }
    }
}
