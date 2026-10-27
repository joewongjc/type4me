import Foundation

/// Other places in the visible text that read exactly like the selection.
/// Whether each one is the same mistake is the model's call, so nothing is
/// filtered here.
public enum CorrectionOccurrences {
    public struct Occurrence: Equatable, Sendable {
        /// 1-based, in reading order; the number the prompt marks it with.
        public let number: Int
        /// Characters from the start of the selection to the start of this
        /// occurrence: negative before the selection, positive after it.
        public let offset: Int
    }

    public static func find(before: String, after: String, matching selected: String) -> [Occurrence] {
        guard !selected.isEmpty else { return [] }
        let length = selected.count
        let ahead = starts(of: selected, in: before).map { $0 - before.count }
        // Offsets after the selection count from its start, past the selection itself.
        let behind = starts(of: selected, in: after).map { $0 + length }
        return (ahead + behind).enumerated().map { Occurrence(number: $0.offset + 1, offset: $0.element) }
    }

    /// Character offsets of non-overlapping matches.
    static func starts(of needle: String, in haystack: String) -> [Int] {
        let text = Array(haystack)
        let pattern = Array(needle)
        guard pattern.count <= text.count else { return [] }
        var result: [Int] = []
        var index = 0
        while index + pattern.count <= text.count {
            if Array(text[index..<index + pattern.count]) == pattern {
                result.append(index)
                index += pattern.count
            } else {
                index += 1
            }
        }
        return result
    }
}
