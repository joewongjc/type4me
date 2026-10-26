import Foundation

/// Per-mode overrides for the whole recording-display block.
///
/// The floating bar reads every one of its values through `FloatingBarPresentation`.
/// A mode with a stored profile uses that presentation verbatim and stops
/// following the global Appearance settings; a mode without one keeps using the
/// global values. Profiles are keyed by mode id, so deleting a mode leaves an
/// entry that the next load prunes.
struct RecordingDisplayProfileStore {

    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = AppDataLocation.profileDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("recording-display-profiles.json")
        }
    }

    private struct Document: Codable {
        var profiles: [Entry]
    }

    private struct Entry: Codable {
        var modeID: UUID
        var display: FloatingBarPresentation
    }

    func load() -> [UUID: FloatingBarPresentation] {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else {
            return [:]
        }
        return Dictionary(
            document.profiles.map { ($0.modeID, $0.display) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    func save(_ profiles: [UUID: FloatingBarPresentation]) throws {
        // Sorted so the file is stable across writes that changed nothing.
        let entries = profiles
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { Entry(modeID: $0.key, display: $0.value) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(profiles: entries)).write(to: fileURL, options: .atomic)
    }

    /// Writes the profiles, mirrors them into `AppState`, and tells every
    /// observer to re-read. Returns whether the disk write succeeded.
    @MainActor
    @discardableResult
    static func persist(
        _ profiles: [UUID: FloatingBarPresentation],
        appState: AppState,
        storage: RecordingDisplayProfileStore = RecordingDisplayProfileStore()
    ) -> Bool {
        do {
            try storage.save(profiles)
            appState.recordingDisplayProfiles = profiles
            NotificationCenter.default.post(name: .recordingDisplayProfilesDidChange, object: nil)
            return true
        } catch {
            NSLog(
                "[Type4Me] Failed to save recording display profiles: %@",
                String(describing: error)
            )
            return false
        }
    }
}
