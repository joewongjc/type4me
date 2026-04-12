import Foundation

/// User preference: how much live transcription fits in the floating bar.
enum FloatingBarLayoutMode: String, CaseIterable, Sendable {
    /// Single line, grows up to ~400pt (default, matches historical behavior).
    case standard
    /// Single line, grows up to a wider cap.
    case wide
    /// Multiple lines; scrolls when text exceeds visible rows.
    case multiline2
    case multiline3
    case multiline4

    static let storageKey = "tf_floatingBarLayout"

    static var `default`: FloatingBarLayoutMode { .standard }

    static func resolved(_ raw: String?) -> FloatingBarLayoutMode {
        guard let raw, let mode = FloatingBarLayoutMode(rawValue: raw) else {
            return .standard
        }
        return mode
    }

    /// Maximum horizontal extent of the capsule during recording (points).
    var maxBarWidth: CGFloat {
        switch self {
        case .standard: return 400
        case .wide: return 640
        case .multiline2: return 520
        case .multiline3: return 560
        case .multiline4: return 680
        }
    }

    /// Visible rows for multiline layouts; single-line modes use 1.
    var visibleLineCount: Int {
        switch self {
        case .standard, .wide: return 1
        case .multiline2: return 2
        case .multiline3: return 3
        case .multiline4: return 4
        }
    }

    var isMultiline: Bool { visibleLineCount > 1 }

    /// Capsule height for all phases (preparing/recording/processing/done).
    var capsuleHeight: CGFloat {
        if !isMultiline { return TF.barHeight }
        let verticalPad: CGFloat = 24
        let lineH: CGFloat = 22
        return verticalPad + CGFloat(visibleLineCount) * lineH
    }

    /// Scroll view viewport height for multiline recording text.
    var multilineScrollViewportHeight: CGFloat {
        CGFloat(visibleLineCount) * 22 + 8
    }

    /// Short labels for settings dropdown (parallel structure: 单行 / 多行 + detail).
    var settingsLabel: (zh: String, en: String) {
        switch self {
        case .standard: return ("单行 · 默认宽度", "Single line · default width")
        case .wide: return ("单行 · 加宽", "Single line · wide")
        case .multiline2: return ("多行 · 2 行", "Multi-line · 2 rows")
        case .multiline3: return ("多行 · 3 行", "Multi-line · 3 rows")
        case .multiline4: return ("多行 · 4 行", "Multi-line · 4 rows")
        }
    }
}

extension Notification.Name {
    /// Posted when `FloatingBarLayoutMode.storageKey` changes so the panel can resize.
    static let floatingBarLayoutDidChange = Notification.Name("tf_floatingBarLayoutDidChange")
}
