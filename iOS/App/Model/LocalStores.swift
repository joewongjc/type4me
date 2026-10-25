import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var mode: DictationMode
    var rawText: String
    var finalText: String
    /// Inserted into the text field, or only copied because the field changed.
    var delivered: Delivery
    var note: String?

    enum Delivery: String, Codable {
        case inserted
        case copied
        case failed
    }
}

/// Recent dictations, kept on this device only.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private let limit = 300

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }

    func update(id: UUID, delivery: HistoryEntry.Delivery) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].delivered = delivery
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    var todayCharacterCount: Int {
        let calendar = Calendar.current
        return entries
            .filter { calendar.isDateInToday($0.date) && $0.delivered != .failed }
            .reduce(0) { $0 + $1.finalText.count }
    }

    var totalCharacterCount: Int {
        entries.filter { $0.delivered != .failed }.reduce(0) { $0 + $1.finalText.count }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// What happened in the voice session, newest first. Shown under Settings so
/// a device test can be read back without Xcode attached.
@MainActor
final class DiagnosticsLog: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        let date = Date()
        let text: String
    }

    @Published private(set) var lines: [Line] = []

    func add(_ text: String) {
        lines.insert(Line(text: text), at: 0)
        if lines.count > 120 { lines.removeLast() }
        SharedLog.add(text)
    }

    var exportText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return lines.reversed().map { "\(formatter.string(from: $0.date)) \($0.text)" }.joined(separator: "\n")
    }
}

enum AppSettings {
    private enum Key {
        static let timeout = "sessionTimeoutMinutes"
        static let importCardDismissed = "importCardDismissed"
        static let onboarded = "onboardingCompleted"
        static let aiConsent = "aiSharingConsent"
    }

    /// Services the user agreed to send speech and text to (`AIConsent`).
    static var aiConsentKeys: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.aiConsent) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Key.aiConsent) }
    }

    /// 0 means never close automatically.
    static var sessionTimeoutMinutes: Int {
        get { UserDefaults.standard.object(forKey: Key.timeout) as? Int ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: Key.timeout) }
    }

    /// The Home "Import from Mac" card was swiped away or closed.
    static var importCardDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: Key.importCardDismissed) }
        set { UserDefaults.standard.set(newValue, forKey: Key.importCardDismissed) }
    }

    static var onboardingCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: Key.onboarded) }
        set { UserDefaults.standard.set(newValue, forKey: Key.onboarded) }
    }

    /// Stable per-install ID sent to Volcengine as `user.uid`.
    static var asrUID: String {
        if let saved = UserDefaults.standard.string(forKey: "asrUID") { return saved }
        let uid = UUID().uuidString
        UserDefaults.standard.set(uid, forKey: "asrUID")
        return uid
    }
}
