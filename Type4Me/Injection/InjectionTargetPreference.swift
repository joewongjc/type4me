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
                "优先写入停止录音时明确聚焦的输入框；微信等不透明编辑器仅在应用、窗口和后续输入均未变化时尝试粘贴。由于无法验证是否写入，结果始终保留到剪贴板。",
                "Prefer the field explicitly focused when recording stops. For opaque editors such as WeChat, attempt paste only while the app, window, and subsequent input remain unchanged. Because insertion cannot be verified, always keep the result in the clipboard."
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
