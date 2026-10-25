import AppIntents

struct Type4MeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenVoiceSessionIntent(),
            // Chinese phrases live in zh-Hans.lproj/AppShortcuts.strings.
            phrases: ["Start a voice session with \(.applicationName)"],
            shortTitle: "Start Voice Session",
            systemImageName: "mic"
        )
    }
}
