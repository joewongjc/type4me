import Foundation

public enum FixtureLoader {
    public static let expectedSuiteCounts: [String: Int] = [
        "core-polish": 44,
        "boundary-fidelity": 20,
        "application": 20,
        "context": 20,
        "expression": 14,
        "privacy-fallback": 8,
    ]

    public static func loadAll() throws -> [EvaluationCase] {
        guard let resourceURL = Bundle.module.resourceURL else {
            throw EvaluationError.fixture("resource directory unavailable")
        }
        let directory = resourceURL.appendingPathComponent("Fixtures", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw EvaluationError.fixture("no JSONL files found") }

        let decoder = JSONDecoder()
        var cases: [EvaluationCase] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                do {
                    cases.append(try decoder.decode(EvaluationCase.self, from: Data(line.utf8)))
                } catch {
                    throw EvaluationError.fixture("\(file.lastPathComponent):\(offset + 1): \(error)")
                }
            }
        }
        try validate(cases)
        return cases
    }

    public static func validate(_ cases: [EvaluationCase]) throws {
        let ids = cases.map(\.id)
        guard Set(ids).count == ids.count else { throw EvaluationError.fixture("duplicate case IDs") }
        guard cases.count == expectedSuiteCounts.values.reduce(0, +) else {
            let expected = expectedSuiteCounts.values.reduce(0, +)
            throw EvaluationError.fixture("expected \(expected) cases, found \(cases.count)")
        }
        for (suite, expected) in expectedSuiteCounts {
            let actual = cases.filter { $0.suite == suite }.count
            guard actual == expected else {
                throw EvaluationError.fixture("suite \(suite) expected \(expected), found \(actual)")
            }
        }
        guard cases.filter(\.smoke).count == 28 else {
            throw EvaluationError.fixture("smoke subset must contain exactly 28 cases")
        }
        guard cases.filter(\.critical).count == 16 else {
            throw EvaluationError.fixture("critical subset must contain exactly 16 cases")
        }
        for item in cases {
            guard !item.id.isEmpty, !item.inputText.isEmpty, !item.intentSummary.isEmpty else {
                throw EvaluationError.fixture("\(item.id): id, inputText and intentSummary are required")
            }
        }
    }
}
