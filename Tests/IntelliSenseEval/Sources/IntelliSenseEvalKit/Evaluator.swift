import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Type4MeIntelliSenseCore

public struct EvaluationRunOptions: Sendable {
    public var suite: String
    public var caseID: String?
    public var tag: String?
    public var modelAlias: String
    public var concurrency: Int
    public var criticalRepetitions: Int
    public var noCache: Bool
    public var outputDirectory: URL

    public init(
        suite: String = "smoke",
        caseID: String? = nil,
        tag: String? = nil,
        modelAlias: String = "product",
        concurrency: Int = 3,
        criticalRepetitions: Int = 1,
        noCache: Bool = false,
        outputDirectory: URL
    ) {
        self.suite = suite
        self.caseID = caseID
        self.tag = tag
        self.modelAlias = modelAlias
        self.concurrency = max(1, concurrency)
        self.criticalRepetitions = max(1, criticalRepetitions)
        self.noCache = noCache
        self.outputDirectory = outputDirectory
    }
}

public final class IntelliSenseEvaluator: Sendable {
    public init() {}

    public func run(
        cases allCases: [EvaluationCase],
        config: EvaluationConfig,
        options: EvaluationRunOptions
    ) async throws -> URL {
        guard let model = config.models[options.modelAlias] else {
            throw EvaluationError.missingModel(options.modelAlias)
        }
        guard let apiKey = ProcessInfo.processInfo.environment[model.apiKeyEnvironment], !apiKey.isEmpty else {
            throw EvaluationError.missingEnvironment(model.apiKeyEnvironment)
        }
        let selected = select(cases: allCases, options: options)
        guard !selected.isEmpty else { throw EvaluationError.invalidArguments("No cases matched the filters") }

        let runID = Self.runID()
        let runDirectory = options.outputDirectory.appendingPathComponent(runID, isDirectory: true)
        let cacheDirectory = options.outputDirectory.deletingLastPathComponent().appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var jobs: [(EvaluationCase, Int)] = []
        for item in selected {
            let repetitions = item.critical ? options.criticalRepetitions : 1
            for repetition in 1...repetitions { jobs.append((item, repetition)) }
        }

        var results: [EvaluationResult] = []
        for batchStart in stride(from: 0, to: jobs.count, by: options.concurrency) {
            let batch = Array(jobs[batchStart..<min(jobs.count, batchStart + options.concurrency)])
            let batchResults = await withTaskGroup(of: EvaluationResult.self) { group in
                for (item, repetition) in batch {
                    group.addTask {
                        await self.evaluate(
                            item,
                            repetition: repetition,
                            runID: runID,
                            modelAlias: options.modelAlias,
                            model: model,
                            apiKey: apiKey,
                            cacheDirectory: cacheDirectory,
                            noCache: options.noCache
                        )
                    }
                }
                var values: [EvaluationResult] = []
                for await value in group { values.append(value) }
                return values
            }
            results.append(contentsOf: batchResults)
        }
        results.sort { ($0.caseID, $0.repetition) < ($1.caseID, $1.repetition) }

        let resultURL = runDirectory.appendingPathComponent("run.jsonl")
        try writeJSONL(results, to: resultURL)
        try EvaluationReport.write(results: results, cases: selected, to: runDirectory)
        return runDirectory
    }

    private func select(cases: [EvaluationCase], options: EvaluationRunOptions) -> [EvaluationCase] {
        cases.filter { item in
            let suiteMatch = options.suite == "all" || (options.suite == "smoke" ? item.smoke : item.suite == options.suite)
            let caseMatch = options.caseID == nil || item.id == options.caseID
            let tagMatch = options.tag == nil || item.tags.contains(options.tag!)
            return suiteMatch && caseMatch && tagMatch
        }
    }

    private func evaluate(
        _ item: EvaluationCase,
        repetition: Int,
        runID: String,
        modelAlias: String,
        model: EvaluationModelConfig,
        apiKey: String,
        cacheDirectory: URL,
        noCache: Bool
    ) async -> EvaluationResult {
        let request = item.makeRequest()
        let prompt = IntelliSensePromptBuilder.build(request: request)
        let promptHash = stableHash(prompt)
        let cacheKey = stableHash("\(model.model)\n\(prompt)")
        let cacheURL = cacheDirectory.appendingPathComponent("\(cacheKey).json")
        let started = ContinuousClock.now
        var cached = false
        var candidate = ""
        var errorText: String?
        var retryCount = 0

        if !noCache, let data = try? Data(contentsOf: cacheURL),
           let cachedValue = try? JSONDecoder().decode(CacheEntry.self, from: data) {
            candidate = cachedValue.output
            cached = true
        } else {
            while true {
                do {
                    candidate = try await callModel(prompt: prompt, model: model, apiKey: apiKey)
                    let data = try JSONEncoder().encode(CacheEntry(output: candidate))
                    try data.write(to: cacheURL, options: .atomic)
                    break
                } catch {
                    guard retryCount < 2 else {
                        errorText = error.localizedDescription
                        break
                    }
                    retryCount += 1
                    try? await Task.sleep(for: .milliseconds(250 * retryCount))
                }
            }
        }

        let validation = IntelliSenseOutputValidator.process(
            input: item.inputText,
            candidate: candidate,
            context: request.context
        )
        let decision = describe(validation.decision)
        let checks = automatedChecks(item: item, finalText: validation.finalText, decision: validation.decision)
        let elapsed = started.duration(to: .now)
        let latency = Int(Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000)

        return EvaluationResult(
            runID: runID,
            caseID: item.id,
            suite: item.suite,
            repetition: repetition,
            modelAlias: modelAlias,
            modelID: model.model,
            inputText: item.inputText,
            application: item.application,
            control: item.control,
            contextAvailability: item.contextAvailability,
            contextBefore: item.contextBefore,
            contextAfter: item.contextAfter,
            enabledAwareness: item.enabledAwareness,
            expressionProfile: item.expressionProfile,
            intentSummary: item.intentSummary,
            promptHash: promptHash,
            candidateText: candidate,
            finalText: validation.finalText,
            guardDecision: decision.label,
            guardDiagnostics: decision.diagnostics,
            correctionDetected: validation.correctionAnalysis.containsExplicitCorrection,
            automatedChecks: checks,
            latencyMilliseconds: latency,
            retryCount: retryCount,
            cached: cached,
            error: errorText,
            humanVerdict: nil,
            humanNotes: nil
        )
    }

    private func callModel(prompt: String, model: EvaluationModelConfig, apiKey: String) async throws -> String {
        guard let url = URL(string: model.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw EvaluationError.invalidArguments("Invalid base URL")
        }
        var body: [String: Any] = [
            "model": model.model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ]
        switch model.thinkingMode {
        case .none: break
        case .thinkingDisabled: body["thinking"] = ["type": "disabled"]
        case .enableThinkingFalse: body["enable_thinking"] = false
        case .reasoningEffortNone: body["reasoning_effort"] = "none"
        case .thinkFalse: body["think"] = false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EvaluationError.invalidResponse("HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw EvaluationError.invalidResponse(String(decoding: data.prefix(500), as: UTF8.self)) }
        return content
            .replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func automatedChecks(
        item: EvaluationCase,
        finalText: String,
        decision: IntelliSenseGuardDecision
    ) -> [AutomatedCheck] {
        var checks: [AutomatedCheck] = []
        for value in item.mustPreserve {
            checks.append(.init(name: "preserve", passed: constraintContains(value, in: finalText), detail: value))
        }
        for value in item.mustRemove {
            checks.append(.init(name: "remove", passed: !constraintContains(value, in: finalText), detail: value))
        }
        for value in item.mustNotAdd {
            checks.append(.init(name: "not-add", passed: !constraintContains(value, in: finalText), detail: value))
        }
        let correction = CorrectionIntentAnalysis.analyze(item.inputText)
        for value in correction.supersededProtectedTokens {
            checks.append(.init(
                name: "remove-superseded-fact",
                passed: !finalText.localizedCaseInsensitiveContains(value),
                detail: value
            ))
        }
        if item.mustChange {
            checks.append(.init(
                name: "must-change",
                passed: changeComparable(finalText) != changeComparable(item.inputText),
                detail: "output should differ from the ASR text after trivial outer-whitespace normalization"
            ))
        }
        for assertion in item.hardAssertions {
            let minimumListPrefix = "expectListMinItems:"
            if assertion.hasPrefix(minimumListPrefix),
               let minimum = Int(assertion.dropFirst(minimumListPrefix.count)) {
                let actual = EvaluationListStructure.itemCount(in: finalText)
                checks.append(.init(
                    name: "list-min-items",
                    passed: actual >= minimum,
                    detail: "expected at least \(minimum) list items, found \(actual)"
                ))
            } else if assertion == "expectNoList" {
                let actual = EvaluationListStructure.itemCount(in: finalText)
                checks.append(.init(
                    name: "no-list",
                    passed: actual == 0,
                    detail: "expected continuous prose, found \(actual) list items"
                ))
            }
        }
        let expectedReject = item.hardAssertions.compactMap { assertion -> String? in
            let prefix = "expectGuardReject:"
            return assertion.hasPrefix(prefix) ? String(assertion.dropFirst(prefix.count)) : nil
        }.first
        let guardDescription = describe(decision)
        checks.append(.init(
            name: "guard-hard-error",
            passed: expectedReject.map { guardDescription.label == "reject" && guardDescription.diagnostics.contains($0) }
                ?? { if case .reject = decision { return false }; return true }(),
            detail: expectedReject.map { "expected reject: \($0)" } ?? guardDescription.label
        ))
        return checks
    }

    private func constraintContains(_ needle: String, in text: String) -> Bool {
        constraintComparable(text).contains(constraintComparable(needle))
    }

    private func constraintComparable(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    private func changeComparable(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !"，。！？、,.!?;；:：".contains($0) }
    }

    private func describe(_ decision: IntelliSenseGuardDecision) -> (label: String, diagnostics: [String]) {
        switch decision {
        case .accept: return ("accept", [])
        case .acceptWithWarnings(let warnings): return ("acceptWithWarnings", warnings.map(\.rawValue))
        case .reject(let reason): return ("reject", [reason.rawValue])
        }
    }

    private func writeJSONL(_ results: [EvaluationResult], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try results.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func runID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

private struct CacheEntry: Codable {
    var output: String
}

enum EvaluationListStructure {
    private static let marker = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•]|\d+[.)、]|[一二三四五六七八九十]+[、.）)])\s*"#
    )

    static func itemCount(in text: String) -> Int {
        text.split(whereSeparator: \.isNewline).reduce(into: 0) { count, line in
            let value = String(line)
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if marker.firstMatch(in: value, range: range) != nil {
                count += 1
            }
        }
    }
}
