import Foundation

public enum EvaluationReport {
    public static func write(
        results: [EvaluationResult],
        cases: [EvaluationCase],
        to directory: URL
    ) throws {
        let grouped = Dictionary(grouping: results, by: \.suite)
        for suite in grouped.keys.sorted() {
            let suiteResults = grouped[suite]!.sorted { ($0.caseID, $0.repetition) < ($1.caseID, $1.repetition) }
            let markdown = reviewPacket(suite: suite, results: suiteResults, cases: cases)
            try Data(markdown.utf8).write(
                to: directory.appendingPathComponent("review-packet-\(suite).md"),
                options: .atomic
            )
        }
        let summary = summaryMarkdown(results, cases: cases)
        try Data(summary.utf8).write(to: directory.appendingPathComponent("summary.md"), options: .atomic)
    }

    public static func loadResults(from url: URL) throws -> [EvaluationResult] {
        let file = url.hasDirectoryPath ? url.appendingPathComponent("run.jsonl") : url
        let text = try String(contentsOf: file, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map { try decoder.decode(EvaluationResult.self, from: Data($0.utf8)) }
    }

    public static func compare(current: [EvaluationResult], baseline: [EvaluationResult]) -> String {
        let old = Dictionary(uniqueKeysWithValues: baseline.map { ("\($0.caseID)#\($0.repetition)", $0) })
        var lines = ["# Intelli Sense Evaluation Comparison", "", "| Case | Automated | Output changed | Guard |", "|---|---:|---:|---|"]
        for result in current {
            let previous = old["\(result.caseID)#\(result.repetition)"]
            lines.append("| \(escape(result.caseID)) | \(result.automatedPass ? "PASS" : "FAIL") | \(previous?.finalText == result.finalText ? "No" : "Yes") | \(escape(result.guardDecision)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func summaryMarkdown(_ results: [EvaluationResult], cases: [EvaluationCase]) -> String {
        let passed = results.filter(\.automatedPass).count
        let rejected = results.filter { $0.guardDecision == "reject" }.count
        let expectedRejected = results.filter { result in
            result.guardDecision == "reject"
                && result.automatedChecks.first(where: { $0.name == "guard-hard-error" })?.passed == true
        }.count
        let unexpectedRejected = rejected - expectedRejected
        let unchanged = results.filter { normalized($0.inputText) == normalized($0.finalText) }.count
        let liveResults = results.filter { !$0.cached }
        let avgLatency = liveResults.isEmpty ? nil : liveResults.map(\.latencyMilliseconds).reduce(0, +) / liveResults.count
        let mustChangeIDs = Set(cases.filter(\.mustChange).map(\.id))
        let ineffectiveChanges = results.filter {
            mustChangeIDs.contains($0.caseID)
                && $0.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    == $0.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        }.count
        var lines = [
            "# Intelli Sense Evaluation Summary",
            "",
            "- Run: \(results.first?.runID ?? "unknown")",
            "- Model: \(results.first?.modelID ?? "unknown")",
            "- Results: \(results.count)",
            "- Automated checks passed: \(passed)/\(results.count)",
            "- Guard hard rejects: \(rejected) (expected safety fallbacks: \(expectedRejected), unexpected: \(unexpectedRejected))",
            "- Semantically unchanged outputs: \(unchanged)",
            "- Ineffective exact output among mustChange cases: \(ineffectiveChanges)/\(results.filter { mustChangeIDs.contains($0.caseID) }.count)",
            "- Cached results: \(results.filter(\.cached).count)/\(results.count)",
            "- Average uncached latency: \(avgLatency.map { "\($0) ms" } ?? "n/a")",
            "",
            "Automated checks only verify explicit constraints. Final quality requires human review of each suite packet.",
        ]
        let grouped = Dictionary(grouping: results, by: \.suite)
        lines.append("")
        lines.append("| Suite | Cases | Automated pass | Unexpected rejects |")
        lines.append("|---|---:|---:|---:|")
        for suite in grouped.keys.sorted() {
            let values = grouped[suite]!
            let unexpected = values.filter { result in
                result.guardDecision == "reject"
                    && result.automatedChecks.first(where: { $0.name == "guard-hard-error" })?.passed != true
            }.count
            lines.append("| \(suite) | \(values.count) | \(values.filter(\.automatedPass).count) | \(unexpected) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func reviewPacket(
        suite: String,
        results: [EvaluationResult],
        cases: [EvaluationCase]
    ) -> String {
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        var lines = [
            "# Intelli Sense Human Review Packet — \(suite)",
            "",
            "请按原意保真、去噪/改口、自然度、应用适配、上下文使用、个性化、边界安全和实际增值进行人工判断。",
            "每条填写 Verdict：`pass`、`acceptable`、`fail` 或 `needs-review`，并写明原因。该报告也可整体交给更强的 AI 工具辅助评审。",
            "",
        ]
        for result in results {
            let item = byID[result.caseID]
            lines.append("## \(result.caseID) · repetition \(result.repetition)")
            lines.append("")
            lines.append("- Intent: \(result.intentSummary)")
            lines.append("- App: \(result.application?.appName ?? "None") (`\(result.application?.bundleIdentifier ?? "none")`) · control `\(result.control.rawValue)`")
            lines.append("- Context availability: `\(result.contextAvailability.rawValue)`")
            lines.append("- Awareness: app=\(result.enabledAwareness.application), context=\(result.enabledAwareness.context), expression=\(result.enabledAwareness.expression), correction=\(result.enabledAwareness.correction)")
            lines.append("- Expression profile: \(result.expressionProfile.isEmpty ? "None" : result.expressionProfile.joined(separator: " · "))")
            lines.append("- Expected app effect: \(item?.expectedAppEffect ?? "")")
            lines.append("- Expected context use: \(item?.expectedContextUse ?? "")")
            lines.append("- Automated: \(result.automatedPass ? "PASS" : "FAIL") · Guard: `\(result.guardDecision)` \(result.guardDiagnostics.joined(separator: ", "))")
            lines.append("- Latency: \(result.latencyMilliseconds) ms · Retries: \(result.retryCount ?? 0) · Cached: \(result.cached)")
            lines.append("")
            lines.append("**ASR text**")
            lines.append("")
            lines.append("> \(quote(result.inputText))")
            if !result.contextBefore.isEmpty || !result.contextAfter.isEmpty {
                lines.append("")
                lines.append("**Injected context**")
                lines.append("")
                lines.append("```text\nBefore: \(result.contextBefore)\nAfter: \(result.contextAfter)\n```")
            }
            lines.append("")
            lines.append("**Model candidate**")
            lines.append("")
            lines.append("> \(quote(result.candidateText))")
            lines.append("")
            lines.append("**Final product output**")
            lines.append("")
            lines.append("> \(quote(result.finalText))")
            lines.append("")
            lines.append("**Input/output diff**")
            lines.append("")
            lines.append("```diff\n\(compactDiff(old: result.inputText, new: result.finalText))\n```")
            lines.append("")
            lines.append("**Automatic constraints**")
            lines.append("")
            for check in result.automatedChecks {
                lines.append("- [\(check.passed ? "x" : " ")] \(check.name): `\(check.detail)`")
            }
            lines.append("")
            lines.append("- Verdict: `needs-review`")
            lines.append("- Notes:")
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !"，。！？、,.!?;；:：".contains($0) }
    }

    private static func quote(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\n> ")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private static func compactDiff(old: String, new: String) -> String {
        if old == new { return "  (unchanged)" }
        return "- " + old.replacingOccurrences(of: "\n", with: "\n- ")
            + "\n+ " + new.replacingOccurrences(of: "\n", with: "\n+ ")
    }
}
