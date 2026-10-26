import Foundation
import IntelliSenseEvalKit

@main
struct IntelliSenseEvalCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            return
        }
        arguments.removeFirst()
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        switch command {
        case "validate":
            let cases = try FixtureLoader.loadAll()
            print("Validated \(cases.count) cases; smoke=\(cases.filter(\.smoke).count), critical=\(cases.filter(\.critical).count)")
            for suite in FixtureLoader.expectedSuiteCounts.keys.sorted() {
                print("  \(suite): \(cases.filter { $0.suite == suite }.count)")
            }
        case "run":
            let parsed = parse(arguments)
            let configURL = URL(fileURLWithPath: parsed["config"] ?? "eval-config.json", relativeTo: packageRoot).standardizedFileURL
            let config = try loadConfig(configURL)
            let output = URL(fileURLWithPath: parsed["output"] ?? "Runs", relativeTo: packageRoot).standardizedFileURL
            let options = EvaluationRunOptions(
                suite: parsed["suite"] ?? "smoke",
                caseID: parsed["case"],
                tag: parsed["tag"],
                modelAlias: parsed["model"] ?? "product",
                concurrency: Int(parsed["concurrency"] ?? "3") ?? 3,
                criticalRepetitions: Int(parsed["repeat"] ?? "1") ?? 1,
                noCache: parsed["no-cache"] == "true",
                outputDirectory: output
            )
            let directory = try await IntelliSenseEvaluator().run(
                cases: FixtureLoader.loadAll(),
                config: config,
                options: options
            )
            print("Evaluation complete: \(directory.path)")
        case "report":
            let parsed = parse(arguments)
            guard let run = parsed["run"] else { throw EvaluationError.invalidArguments("report requires --run") }
            let runURL = resolveRun(run, root: packageRoot)
            let results = try EvaluationReport.loadResults(from: runURL)
            try EvaluationReport.write(results: results, cases: FixtureLoader.loadAll(), to: runURL)
            print("Reports regenerated: \(runURL.path)")
        case "compare":
            let parsed = parse(arguments)
            guard let baseline = parsed["baseline"] else {
                throw EvaluationError.invalidArguments("compare requires --baseline; --run defaults to the latest run")
            }
            let runURL = try parsed["run"].map { resolveRun($0, root: packageRoot) }
                ?? latestRun(root: packageRoot)
            let current = try EvaluationReport.loadResults(from: runURL)
            let baselineURL = URL(fileURLWithPath: "Baselines/\(baseline).jsonl", relativeTo: packageRoot).standardizedFileURL
            let old = try EvaluationReport.loadResults(from: baselineURL)
            let markdown = EvaluationReport.compare(current: current, baseline: old)
            let outputURL = runURL.appendingPathComponent("comparison-\(baseline).md")
            try Data(markdown.utf8).write(to: outputURL, options: .atomic)
            print("Comparison written: \(outputURL.path)")
        default:
            printUsage()
            throw EvaluationError.invalidArguments("Unknown command: \(command)")
        }
    }

    private static func parse(_ arguments: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            guard value.hasPrefix("--") else { index += 1; continue }
            let key = String(value.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                result[key] = arguments[index + 1]
                index += 2
            } else {
                result[key] = "true"
                index += 1
            }
        }
        return result
    }

    private static func loadConfig(_ url: URL) throws -> EvaluationConfig {
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(EvaluationConfig.self, from: Data(contentsOf: url))
        }
        guard let model = ProcessInfo.processInfo.environment["INTELLISENSE_EVAL_MODEL"],
              let baseURL = ProcessInfo.processInfo.environment["INTELLISENSE_EVAL_BASE_URL"]
        else {
            throw EvaluationError.invalidArguments(
                "Provide eval-config.json or INTELLISENSE_EVAL_MODEL, INTELLISENSE_EVAL_BASE_URL and INTELLISENSE_EVAL_API_KEY"
            )
        }
        return EvaluationConfig(models: [
            "product": EvaluationModelConfig(
                model: model,
                baseURL: baseURL,
                apiKeyEnvironment: "INTELLISENSE_EVAL_API_KEY"
            ),
        ])
    }

    private static func resolveRun(_ value: String, root: URL) -> URL {
        if value.contains("/") { return URL(fileURLWithPath: value, relativeTo: root).standardizedFileURL }
        return root.appendingPathComponent("Runs/\(value)", isDirectory: true)
    }

    private static func latestRun(root: URL) throws -> URL {
        let directory = root.appendingPathComponent("Runs", isDirectory: true)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter(\.hasDirectoryPath).sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let latest = candidates.first else {
            throw EvaluationError.invalidArguments("No runs found under \(directory.path)")
        }
        return latest
    }

    private static func printUsage() {
        print("""
        Intelli Sense semantic evaluation (manual only)

          swift run intellisense-eval validate
          swift run intellisense-eval run --suite smoke --model product [--case ID] [--tag TAG]
          swift run intellisense-eval run --suite all --model product --concurrency 3 --repeat 3
          swift run intellisense-eval report --run RUN_ID
          swift run intellisense-eval compare [--run RUN_ID] --baseline approved
        """)
    }
}
