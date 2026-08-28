import Foundation

/// Selects when a normal, manually triggered recording chooses its text
/// injection target. Automated and specialized recording flows keep their
/// existing target semantics.
enum InjectionTargetPreference: String, CaseIterable, Identifiable, Sendable {
    case recordingStart
    case recordingEnd

    static let storageKey = "tf_injectionTargetPreference"
    static let defaultValue: Self = .recordingStart

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recordingStart:
            return L("录音开始时的应用", "App at Recording Start")
        case .recordingEnd:
            return L("录音结束时的输入框", "Focused Field at Recording End")
        }
    }

    var detail: String {
        switch self {
        case .recordingStart:
            return L(
                "完成后返回录音开始时的应用并写入文字。",
                "Return to the app active when recording started and insert the text."
            )
        case .recordingEnd:
            return L(
                "仅写入停止录音时明确聚焦的可编辑输入框；无法确认时保留到剪贴板。",
                "Insert only into the editable field explicitly focused when recording stops; otherwise keep the result in the clipboard."
            )
        }
    }

    static func current(userDefaults: UserDefaults = .standard) -> Self {
        guard let rawValue = userDefaults.string(forKey: storageKey),
              let preference = Self(rawValue: rawValue)
        else { return defaultValue }
        return preference
    }
}
