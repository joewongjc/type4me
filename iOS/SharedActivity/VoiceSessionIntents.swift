import AppIntents
import Foundation

/// Opens Type4Me, which starts the voice session as soon as it is in front.
/// Used by the Control Center control and the Action Button.
struct OpenVoiceSessionIntent: AppIntent {
    // English source strings; Chinese lives in zh-Hans.lproj/Localizable.strings.
    static let title: LocalizedStringResource = "Start Voice Session"
    static let description = IntentDescription("Opens Type4Me and starts a voice session, so you can go back to any app and talk with the keyboard.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        .result()
    }
}
