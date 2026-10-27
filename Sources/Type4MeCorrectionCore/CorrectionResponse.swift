import Foundation

/// Reads the model's JSON reply into the text to write.
public enum CorrectionResponse {
    public enum Result: Equatable, Sendable {
        case replace(String, also: [Int])
        case unclear
    }

    public static func resolve(_ raw: String, selected: String, attempts: [String], occurrenceCount: Int) -> Result {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let replacement = (object["replacement"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !replacement.isEmpty,
              replacement != selected.trimmingCharacters(in: .whitespacesAndNewlines),
              !attempts.contains(replacement)
        else { return .unclear }
        let numbers = (object["also"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        let also = Array(Set(numbers.filter { $0 >= 1 && $0 <= occurrenceCount })).sorted()
        return .replace(replacement, also: also)
    }
}
