import Foundation
import Type4MeIntelliSenseCore

/// Local-testing benchmark: replays every archived sample (plus optional
/// scripted cases under `asr-samples/bench/`) through Volcano with the shipped
/// defaults and with the saved tuning, then runs each transcript through the
/// quick, polish and IntelliSense modes. Writes one JSON result file.
///
/// Triggered by `type4me://asr-bench`. It reads only files inside the sample
/// archive and uses the app's own saved ASR/LLM configuration.
enum VolcBench {

    struct Config: Sendable {
        let key: String
        let label: String
        let tuning: VolcTuningSettings
    }

    struct Case: Sendable {
        let id: String
        let source: String
        let audio: URL
        let reference: String?
        let note: String?
    }

    /// Text the app would have produced at each moment, plus timing.
    struct Capture: Sendable {
        var updates: [(t: Double, text: String, isFinal: Bool)] = []
        var definite: [String] = []
        var lastPacketAt: Double?
        var finishedAt: Double = 0
        var failure: String?
    }

    static let polishModeName = "语音润色"

    static func run() async throws -> URL {
        let root = ASRSampleArchive.defaultRootDirectory
        let cases = try loadCases(root: root)
        guard let volc = KeychainService.loadASRConfig(for: .volcano) as? VolcanoASRConfig else {
            throw VolcReplaySweep.SweepError.missingVolcanoConfig
        }
        var shipped = VolcTuningSettings()
        shipped.cjkAwareJoin = false
        let configs = [
            Config(key: "shipped", label: "线上默认", tuning: shipped),
            Config(key: "current", label: "当前客户端", tuning: VolcTuningStorage.load()),
        ]
        let options = ASRRequestOptions(
            enablePunc: true,
            hotwords: HotwordStorage.loadEffective(),
            boostingTableID: ASRBiasSettingsStorage.load().boostingTableID,
            bypassProxy: ProxyBypassMode.current.bypassASR
        )
        DebugFileLogger.log("asr-bench start cases=\(cases.count) configs=\(configs.count)")

        // 1. ASR replays, three at a time.
        var jobs: [(Int, Int)] = []
        for c in cases.indices { for k in configs.indices { jobs.append((c, k)) } }
        var captures: [String: Capture] = [:]
        var pcmCache: [Int: Data] = [:]
        for (c, _) in jobs where pcmCache[c] == nil {
            pcmCache[c] = try? VolcReplaySweep.readPCM(cases[c].audio)
        }
        var next = 0
        await withTaskGroup(of: (String, Capture).self) { group in
            func launch(_ index: Int) {
                let (c, k) = jobs[index]
                let pcm = pcmCache[c] ?? Data()
                let tuning = configs[k].tuning
                let key = "\(c)-\(k)"
                group.addTask {
                    (key, await replay(pcm: pcm, tuning: tuning, config: volc, options: options))
                }
            }
            while next < min(3, jobs.count) { launch(next); next += 1 }
            while let (key, capture) = await group.next() {
                captures[key] = capture
                if next < jobs.count { launch(next); next += 1 }
            }
        }

        // 2. Mode processing, sequential so LLM timings are not contended.
        var llmCache = LLMClientCache()
        let runtime = LLMRuntime.resolve(cache: &llmCache)?.runtime
        let modes = ModeStorage().load()
        let polishMode = modes.first { $0.name == polishModeName }
        let intelliSettings = await IntelliSenseSettingsStore.shared.load()
        let intelliContext = IntelliSenseContextSnapshot.appOnly(
            TargetApplicationContext(processIdentifier: nil, bundleIdentifier: nil, displayName: nil)
        )

        var caseResults: [[String: Any]] = []
        for (c, item) in cases.enumerated() {
            var perConfig: [String: Any] = [:]
            for (k, config) in configs.enumerated() {
                let capture = captures["\(c)-\(k)"] ?? Capture()
                let outcome = committedText(capture, tuning: config.tuning)
                let asrText = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let snippetText = SnippetStorage.applyEffective(to: asrText, bundleId: nil)
                var entry: [String: Any] = [
                    "asrText": asrText,
                    "quickText": snippetText,
                    "tailMs": Int((outcome.waitSeconds * 1000).rounded()),
                    "serverTailMs": capture.lastPacketAt.map { Int(((capture.finishedAt - $0) * 1000).rounded()) } as Any,
                    "committedEarly": outcome.committedEarly,
                    "definite": capture.definite,
                ]
                if let failure = capture.failure { entry["failure"] = failure }
                if let runtime, !snippetText.isEmpty {
                    if let polishMode {
                        let prompt = PromptContext.empty.expandContextVariables(polishMode.prompt)
                        entry["polish"] = await timedLLM(runtime: runtime, text: snippetText, prompt: prompt, mode: polishMode.name)
                    }
                    let intelliPrompt = IntelliSensePromptBuilder.build(request: IntelliSenseRequest(
                        text: snippetText,
                        context: intelliContext,
                        settings: intelliSettings,
                        expressionProfile: nil
                    ))
                    var intelli = await timedLLM(runtime: runtime, text: snippetText, prompt: intelliPrompt, mode: "智能感知")
                    if let raw = intelli["text"] as? String {
                        let validated = IntelliSenseOutputValidator.process(input: snippetText, candidate: raw, context: intelliContext)
                        intelli["text"] = validated.finalText
                        if case .reject(let reason) = validated.decision { intelli["rejected"] = reason.rawValue }
                    }
                    entry["intelli"] = intelli
                }
                perConfig[config.key] = entry
            }
            caseResults.append([
                "id": item.id,
                "source": item.source,
                "audio": item.audio.lastPathComponent,
                "durationSeconds": Double(pcmCache[c]?.count ?? 0) / 32_000,
                "reference": item.reference as Any,
                "note": item.note as Any,
                "configs": perConfig,
            ])
            DebugFileLogger.log("asr-bench case \(c + 1)/\(cases.count) done")
        }

        let report: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "resourceId": volc.resourceId,
            "llmProvider": runtime?.providerID ?? "none",
            "llmModel": runtime?.config.model ?? "none",
            "configs": configs.map { ["key": $0.key, "label": $0.label, "summary": $0.tuning.logSummary] },
            "cases": caseResults,
        ]
        let dir = root.appendingPathComponent("bench", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let out = dir.appendingPathComponent("results-\(formatter.string(from: Date())).json")
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out)
        DebugFileLogger.log("asr-bench done report=\(out.path)")
        return out
    }

    // MARK: - Cases

    private static func loadCases(root: URL) throws -> [Case] {
        var cases: [Case] = []
        let manifest = root.appendingPathComponent(ASRSampleArchive.manifestFileName)
        if let content = try? String(contentsOf: manifest, encoding: .utf8) {
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = entry["id"] as? String,
                      let file = entry["audioFile"] as? String,
                      !file.contains(".."), !file.hasPrefix("/")
                else { continue }
                cases.append(Case(
                    id: String(id.prefix(8)),
                    source: "recorded",
                    audio: root.appendingPathComponent(file),
                    reference: nil,
                    note: "原始识别（\(entry["asrProvider"] as? String ?? "?")）：\(entry["rawText"] as? String ?? "")"
                ))
            }
        }
        // Scripted cases: bench/cases.json = [{"id","file","reference","note"}]
        let benchDir = root.appendingPathComponent("bench", isDirectory: true)
        if let data = try? Data(contentsOf: benchDir.appendingPathComponent("cases.json")),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for entry in list {
                guard let id = entry["id"] as? String,
                      let file = entry["file"] as? String,
                      !file.contains(".."), !file.hasPrefix("/")
                else { continue }
                cases.append(Case(
                    id: id,
                    source: "scripted",
                    audio: benchDir.appendingPathComponent(file),
                    reference: entry["reference"] as? String,
                    note: entry["note"] as? String
                ))
            }
        }
        return cases
    }

    // MARK: - Stop semantics

    /// Replays the app's stop flow: wait up to `finalWaitMs` for the final
    /// result; on timeout either commit the current text, or (shipped) keep
    /// draining for up to 5 s more.
    static func committedText(_ capture: Capture, tuning: VolcTuningSettings) -> (text: String, waitSeconds: Double, committedEarly: Bool) {
        guard let sentAt = capture.lastPacketAt else {
            return (capture.updates.last?.text ?? "", 0, false)
        }
        let serverTail = capture.finishedAt - sentAt
        let finalWait = Double(tuning.finalWaitMs) / 1000
        let limit = tuning.commitOnFinalTimeout ? finalWait : finalWait + 5
        if serverTail <= limit {
            return (capture.updates.last?.text ?? "", serverTail, false)
        }
        let cutoff = sentAt + limit
        let text = capture.updates.last(where: { $0.t <= cutoff })?.text ?? ""
        return (text, limit, true)
    }

    // MARK: - Replay

    static func replay(
        pcm: Data,
        tuning: VolcTuningSettings,
        config: VolcanoASRConfig,
        options: ASRRequestOptions
    ) async -> Capture {
        var capture = Capture()
        guard !pcm.isEmpty else {
            capture.failure = "audio unreadable"
            return capture
        }
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!)
        for (field, value) in VolcProtocol.authHeaders(
            authentication: config.authentication,
            resourceId: config.resourceId,
            connectId: UUID().uuidString
        ) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        var options = options
        options.contextHistoryLength = tuning.contextHistoryLength
        let payload = VolcProtocol.buildClientRequest(uid: config.uid, options: options, tuning: tuning)
        let initMessage = VolcProtocol.encodeMessage(
            header: VolcHeader(messageType: .fullClientRequest, flags: .noSequence, serialization: .json, compression: .none),
            payload: payload
        )
        let session = URLSession(configuration: options.urlSessionConfiguration)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        let start = ContinuousClock.now
        func elapsed() -> Double {
            let d = ContinuousClock.now - start
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        do {
            try await task.send(.data(initMessage))
        } catch {
            capture.failure = "connect: \(error.localizedDescription)"
            return capture
        }

        let chunk = tuning.audioChunkByteSize
        let lastPacketAt = LockedBox<Double?>(nil)
        let sender = Task {
            var offset = 0
            while offset < pcm.count {
                let end = min(pcm.count, offset + chunk)
                try await task.send(.data(VolcProtocol.encodeAudioPacket(audioData: Data(pcm[offset ..< end]), isLast: false)))
                offset = end
                let wait = Double(offset) / 32_000 - elapsed()
                if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
            }
            try await task.send(.data(VolcProtocol.encodeAudioPacket(audioData: Data(), isLast: true)))
            lastPacketAt.value = elapsed()
        }

        var accumulator = VolcTranscriptAccumulator(cjkAwareJoin: tuning.cjkAwareJoin)
        var lastText = ""
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if lastPacketAt.value == nil { capture.failure = "receive: \(error.localizedDescription)" }
                break
            }
            guard case .data(let data) = message, data.count >= 4 else { continue }
            if (data[1] >> 4) & 0x0F == 0x0F {
                let extracted = VolcProtocol.extractServerError(data)
                if extracted.code != nil || extracted.message != nil {
                    capture.failure = "server error \(extracted.code.map(String.init) ?? "?"): \(extracted.message ?? "")"
                }
                break
            }
            guard let response = try? VolcProtocol.decodeServerResponse(data) else { continue }
            let isFinal = response.header.flags == .asyncFinal
            let transcript = accumulator.apply(result: response.result, isFinal: isFinal).transcript
            let text = transcript.displayText
            if text != lastText || isFinal {
                capture.updates.append((elapsed(), text, isFinal))
                lastText = text
            }
            capture.definite = response.result.utterances.filter(\.definite).map(\.text)
            if isFinal { break }
        }
        capture.finishedAt = elapsed()
        capture.lastPacketAt = lastPacketAt.value
        sender.cancel()
        return capture
    }

    // MARK: - LLM

    private static func timedLLM(runtime: ResolvedLLMRuntime, text: String, prompt: String, mode: String) async -> [String: Any] {
        let started = ContinuousClock.now
        do {
            let output = try await runtime.client.process(
                text: text,
                prompt: prompt,
                config: runtime.config,
                inputBoundary: .inline,
                invocationContext: .dictation(modeName: mode)
            )
            let d = ContinuousClock.now - started
            return ["text": output, "ms": Int(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)]
        } catch {
            return ["error": String(describing: error)]
        }
    }
}
