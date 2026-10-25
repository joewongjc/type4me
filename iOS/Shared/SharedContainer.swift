import Foundation

/// Identifiers and storage shared by the app and the keyboard extension.
///
/// The keyboard reaches all of this only with Full Access turned on; without
/// it the App Group container is not visible to the extension at all.
enum SharedContainer {
    /// `group.<bundle ID prefix>.ios`, written into each target's Info.plist
    /// from Signing.xcconfig so a self-built copy uses its own App Group.
    static let appGroupID = Bundle.main.object(forInfoDictionaryKey: "T4MAppGroup") as? String
        ?? "group.com.type4me.ios"
    static let urlScheme = "type4me"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var ipcDirectory: URL? {
        guard let url else { return nil }
        let dir = url.appendingPathComponent("ipc", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var commandsDirectory: URL? {
        guard let ipc = ipcDirectory else { return nil }
        let dir = ipc.appendingPathComponent("commands", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var stateFile: URL? { ipcDirectory?.appendingPathComponent("state.json") }

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    /// Links the keyboard opens to hand control to the app.
    enum Link {
        /// Start the voice session and show the "go back" screen.
        static let startSession = URL(string: "\(urlScheme)://session?start=1")!
    }
}

/// Small settings both processes read. The app owns everything except the
/// selected mode, which the keyboard changes when a chip is tapped.
enum SharedSettings {
    private enum Key {
        static let selectedMode = "selectedMode"
        static let llmConfigured = "llmConfigured"
        static let asrConfigured = "asrConfigured"
        static let keyboardLastSeen = "keyboardLastSeen"
        static let keyboardHostIsSelf = "keyboardHostIsSelf"
        static let keyboardDemo = "keyboardDemo"
    }

    /// DEBUG simulator screenshots: the keyboard plays a scripted dictation
    /// locally instead of talking to the app.
    static var keyboardDemo: Bool {
        get { SharedContainer.defaults?.bool(forKey: Key.keyboardDemo) ?? false }
        set { SharedContainer.defaults?.set(newValue, forKey: Key.keyboardDemo) }
    }

    static var selectedMode: DictationMode {
        get {
            // A mode taken off the keyboard or deleted falls back to the
            // first one the keyboard still shows.
            let shown = DictationMode.keyboardOrder
            if let raw = SharedContainer.defaults?.string(forKey: Key.selectedMode),
               let mode = DictationMode(rawValue: raw), shown.contains(mode) {
                return mode
            }
            return shown.first ?? .quick
        }
        set { SharedContainer.defaults?.set(newValue.rawValue, forKey: Key.selectedMode) }
    }

    static var llmConfigured: Bool {
        get { SharedContainer.defaults?.bool(forKey: Key.llmConfigured) ?? false }
        set { SharedContainer.defaults?.set(newValue, forKey: Key.llmConfigured) }
    }

    static var asrConfigured: Bool {
        get { SharedContainer.defaults?.bool(forKey: Key.asrConfigured) ?? false }
        set { SharedContainer.defaults?.set(newValue, forKey: Key.asrConfigured) }
    }

    /// Written by the keyboard each time it appears with Full Access, so the
    /// setup guide can tell that both steps are done.
    static var keyboardLastSeen: Date? {
        get { SharedContainer.defaults?.object(forKey: Key.keyboardLastSeen) as? Date }
        set { SharedContainer.defaults?.set(newValue, forKey: Key.keyboardLastSeen) }
    }
}
