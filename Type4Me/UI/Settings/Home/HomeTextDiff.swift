import Foundation

/// Character-level before/after segments for showing what post-processing
/// changed. Within each changed run, removals are listed before insertions so
/// the result reads as "struck text, then its replacement".
enum HomeTextDiff {

    enum Kind: Equatable {
        case same, removed, inserted
    }

    struct Segment: Equatable {
        let kind: Kind
        let text: String
    }

    /// Longer inputs are shown without a diff; the cost grows with length and a
    /// long rewrite is unreadable as strikethrough anyway.
    static let maxComparedLength = 600

    static func segments(from old: String, to new: String) -> [Segment]? {
        guard old != new, old.count <= maxComparedLength, new.count <= maxComparedLength else { return nil }
        let a = Array(old)
        let b = Array(new)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var raw: [(Kind, Character)] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                raw.append((.removed, a[i])); i += 1
            } else if j < b.count, inserted.contains(j) {
                raw.append((.inserted, b[j])); j += 1
            } else if i < a.count, j < b.count {
                raw.append((.same, a[i])); i += 1; j += 1
            } else {
                break
            }
        }
        return grouped(absorbingShortMatches(merge(raw)))
    }

    /// Share of the original text left untouched; a low value means the text
    /// was rewritten rather than edited, and a diff would only be noise.
    static func unchangedRatio(_ segments: [Segment], originalLength: Int) -> Double {
        guard originalLength > 0 else { return 0 }
        let same = segments.filter { $0.kind == .same }.reduce(0) { $0 + $1.text.count }
        return Double(same) / Double(originalLength)
    }

    private static func merge(_ raw: [(Kind, Character)]) -> [Segment] {
        var result: [Segment] = []
        for (kind, character) in raw {
            if let last = result.last, last.kind == kind {
                result[result.count - 1] = Segment(kind: kind, text: last.text + String(character))
            } else {
                result.append(Segment(kind: kind, text: String(character)))
            }
        }
        return result
    }

    /// A single unchanged character between two edits (often "的" or a comma)
    /// splits one edit into two; folding it into both sides reads better.
    private static func absorbingShortMatches(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        for (index, segment) in segments.enumerated() {
            let isInterior = index > 0 && index < segments.count - 1
            if segment.kind == .same, segment.text.count == 1, isInterior {
                result.append(Segment(kind: .removed, text: segment.text))
                result.append(Segment(kind: .inserted, text: segment.text))
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private static func grouped(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        var removedRun = ""
        var insertedRun = ""
        func flush() {
            if !removedRun.isEmpty { result.append(Segment(kind: .removed, text: removedRun)) }
            if !insertedRun.isEmpty { result.append(Segment(kind: .inserted, text: insertedRun)) }
            removedRun = ""
            insertedRun = ""
        }
        for segment in segments {
            switch segment.kind {
            case .removed: removedRun += segment.text
            case .inserted: insertedRun += segment.text
            case .same:
                flush()
                if let last = result.last, last.kind == .same {
                    result[result.count - 1] = Segment(kind: .same, text: last.text + segment.text)
                } else {
                    result.append(segment)
                }
            }
        }
        flush()
        return result
    }
}
