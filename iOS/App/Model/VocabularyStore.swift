import Foundation
import Type4MeTransferCore

/// Hotwords and snippets, the iPhone's copy of the Mac's Vocabulary page.
///
/// Hotwords go to the speech service as recognition hints; snippets rewrite
/// the transcript before any mode processes it, the same order as the Mac.
/// Both live in the app only: the keyboard never sees the transcript before
/// the app has finished with it.
@MainActor
final class VocabularyStore: ObservableObject {
    typealias Snippet = Type4MeTransferPayload.Snippet

    static let shared = VocabularyStore()

    @Published private(set) var hotwords: [String] = []
    @Published private(set) var snippets: [Snippet] = []

    private struct Saved: Codable {
        var hotwords: [String]
        var snippets: [Snippet]
    }

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("vocabulary.json")
        }
        if let data = try? Data(contentsOf: self.fileURL),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            hotwords = saved.hotwords
            snippets = saved.snippets
        }
    }

    var isEmpty: Bool { hotwords.isEmpty && snippets.isEmpty }

    /// The transcript with every snippet applied, in list order.
    func apply(to text: String) -> String {
        SnippetPattern.apply(snippets, to: text)
    }

    // MARK: - Hotwords

    /// False when the word is blank or already in the list.
    @discardableResult
    func addHotword(_ word: String) -> Bool {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !containsHotword(word) else { return false }
        hotwords.insert(word, at: 0)
        persist()
        return true
    }

    func deleteHotwords(at offsets: IndexSet) {
        hotwords.remove(atOffsets: offsets)
        persist()
    }

    func containsHotword(_ word: String) -> Bool {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return hotwords.contains { $0.lowercased() == key }
    }

    // MARK: - Snippets

    /// Adds a snippet, or replaces the one at `index`. Returns false when the
    /// trigger is blank or another snippet already uses it.
    @discardableResult
    func saveSnippet(_ snippet: Snippet, replacing index: Int? = nil) -> Bool {
        let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return false }
        let clash = snippets.indices.contains { $0 != index && Self.sameTrigger(snippets[$0].trigger, trigger) }
        guard !clash else { return false }
        let cleaned = Snippet(trigger: trigger, replacement: snippet.replacement)
        if let index, snippets.indices.contains(index) {
            snippets[index] = cleaned
        } else {
            snippets.insert(cleaned, at: 0)
        }
        persist()
        return true
    }

    func deleteSnippets(at offsets: IndexSet) {
        snippets.remove(atOffsets: offsets)
        persist()
    }

    // MARK: - Sync

    struct MergeCount: Equatable {
        var added = 0
        var updated = 0
    }

    /// What a sync would change, for the import screen.
    func preview(hotwords incoming: [String]) -> MergeCount {
        var seen = Set(hotwords.map { $0.lowercased() })
        let added = incoming.filter { seen.insert($0.lowercased()).inserted }.count
        return MergeCount(added: added)
    }

    func preview(snippets incoming: [Snippet]) -> MergeCount {
        var count = MergeCount()
        for snippet in incoming {
            if let existing = snippets.first(where: { Self.sameTrigger($0.trigger, snippet.trigger) }) {
                if existing.replacement != snippet.replacement { count.updated += 1 }
            } else {
                count.added += 1
            }
        }
        return count
    }

    /// Merges a sync from the Mac. Nothing on this iPhone is removed: new
    /// hotwords are appended, and a snippet whose trigger already exists
    /// takes the Mac's replacement.
    func applySync(hotwords incoming: [String], snippets incomingSnippets: [Snippet]) {
        for word in incoming {
            let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty, !containsHotword(word) { hotwords.append(word) }
        }
        for snippet in incomingSnippets {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { continue }
            if let index = snippets.firstIndex(where: { Self.sameTrigger($0.trigger, trigger) }) {
                snippets[index].replacement = snippet.replacement
            } else {
                snippets.append(Snippet(trigger: trigger, replacement: snippet.replacement))
            }
        }
        persist()
    }

    func clear() {
        hotwords = []
        snippets = []
        persist()
    }

    /// Triggers match ignoring case and spaces, so two triggers that differ
    /// only in those would fire on the same speech.
    static func sameTrigger(_ a: String, _ b: String) -> Bool {
        a.filter { !$0.isWhitespace }.lowercased() == b.filter { !$0.isWhitespace }.lowercased()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Saved(hotwords: hotwords, snippets: snippets)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
