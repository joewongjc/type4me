//
//  RecordingTheme.swift
//  Type4Me
//

import Foundation
import SwiftUI
import AppKit

/// Appearance theme for the floating recording indicator and related overlays.
enum RecordingTheme: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    static let storageKey = "tf_recordingTheme"
    /// New installations start with the translucent material. An explicit
    /// user selection remains stored under `storageKey` and takes precedence.
    static let defaultValue = RecordingTheme.light

    var displayName: String {
        switch self {
        case .dark:
            L("纯色", "Solid")
        case .light:
            L("毛玻璃版本", "Frosted Glass")
        }
    }

    var usesGlass: Bool {
        self == .light
    }
}

/// User-editable background for the non-glass recording theme.
/// Solid surfaces start from white and remain independently user-editable.
struct RecordingSolidColor: Equatable, Sendable {
    static let storageKey = "tf_recordingSolidColor"
    static let defaultHex = "#FFFFFF"

    let red: Double
    let green: Double
    let blue: Double

    init(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16) else {
            self.init(red: 1, green: 1, blue: 1)
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var hex: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    /// Select content contrast independently from the selected surface type.
    var usesDarkForeground: Bool {
        relativeLuminance > 0.43
    }

    static func hex(from color: Color) -> String {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            return defaultHex
        }
        return RecordingSolidColor(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent
        ).hex
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    private var relativeLuminance: Double {
        func linearize(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red)
            + 0.7152 * linearize(green)
            + 0.0722 * linearize(blue)
    }
}
