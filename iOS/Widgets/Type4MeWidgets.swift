import AppIntents
import SwiftUI
import WidgetKit

@main
struct Type4MeWidgets: WidgetBundle {
    var body: some Widget {
        VoiceSessionControl()
    }
}

// MARK: - Control Center

/// One tap in Control Center (or on the Action Button) opens Type4Me, which
/// starts the voice session; iOS only allows that from the foreground.
struct VoiceSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.type4me.ios.voiceSession") {
            ControlWidgetButton(action: OpenVoiceSessionIntent()) {
                Label("Voice Session", systemImage: "mic")
            }
        }
        // English source strings; Chinese lives in zh-Hans.lproj. Control
        // Center follows the system language.
        .displayName("Type4Me Voice Session")
        .description("Opens Type4Me and starts a voice session.")
    }
}
