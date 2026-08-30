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
