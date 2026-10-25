import Foundation

/// Local-testing tool: replays one archived ASR sample against Volcano with a
/// fixed set of request variants, using the app's own saved Volcano
/// configuration, and writes a side-by-side report next to the archive.
///
/// Triggered by `type4me://asr-sweep?sample=<id prefix>`. The URL can only
/// name a sample already in the archive; variants are fixed here, so a link
/// cannot point the app at arbitrary files or parameters.
enum VolcReplaySweep {

    struct Variant: Sendable {
        let name: String
        let tuning: VolcTuningSettings
    }

    static var variants: [Variant] {
        func make(_ name: String, _ edit: (inout VolcTuningSettings) -> Void) -> Variant {
            var tuning = VolcTuningSettings()
            tuning.cjkAwareJoin = true
            edit(&tuning)
            return Variant(name: name, tuning: tuning)
        }
        return [
            make("A ew=800 fts=1000（当前调参）") { $0.endWindowSizeMs = 800; $0.forceToSpeechTimeMs = 1000 },
            make("B ew=1200 fts=1000") { $0.endWindowSizeMs = 1200; $0.forceToSpeechTimeMs = 1000 },
            make("C ew=1500 fts=1000") { $0.endWindowSizeMs = 1500; $0.forceToSpeechTimeMs = 1000 },
            make("D ew=2000 fts=1000") { $0.endWindowSizeMs = 2000; $0.forceToSpeechTimeMs = 1000 },
            make("E ew=3000 fts=1000") { $0.endWindowSizeMs = 3000; $0.forceToSpeechTimeMs = 1000 },
            make("F ew=3000 fts=0（正式版）") { $0.endWindowSizeMs = 3000; $0.forceToSpeechTimeMs = 0 },
            make("G ew=4000 fts=1000") { $0.endWindowSizeMs = 4000; $0.forceToSpeechTimeMs = 1000 },
            make("H 二遍 不发 ew（服务端默认）") { $0.sendEndWindowSize = false; $0.sendForceToSpeechTime = false },
            make("I 关二遍 语义分句") {
                $0.enableNonstream = false; $0.sendEndWindowSize = false; $0.sendForceToSpeechTime = false
            },
            make("J 关二遍 vad_segment=4000") {
                $0.enableNonstream = false; $0.sendEndWindowSize = false; $0.sendForceToSpeechTime = false
                $0.sendVadSegmentDuration = true; $0.vadSegmentDurationMs = 4000
            },
        ]
    }

    static let concurrency = 3
    private static let chunkBytes = AudioCaptureEngine.chunkByteSize
    private static let bytesPerSecond = 32_000.0

    enum SweepError: Error, CustomStringConvertible {
        case invalidSampleID
        case sampleNotFound
        case unreadableAudio
        case missingVolcanoConfig

        var description: String {
            switch self {
            case .invalidSampleID: return "invalid sample id"
            case .sampleNotFound: return "sample not found in manifest"
            case .unreadableAudio: return "audio file unreadable"
            case .missingVolcanoConfig: return "no saved Volcano configuration"
            }
        }
    }

    /// Parses the sample id prefix out of the URL query.
    static func sampleID(from url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "sample",
              let value = items[0].value?.lowercased(),
              (6...36).contains(value.count),
              value.allSatisfy({ $0.isHexDigit || $0 == "-" })
        else { return nil }
        return value
    }

    /// Runs every variant and returns the report path.
    static func run(sampleIDPrefix: String) async throws -> URL {
        let root = ASRSampleArchive.defaultRootDirectory
        let (sampleID, audioURL, originalText) = try locateSample(prefix: sampleIDPrefix, root: root)
        let pcm = try readPCM(audioURL)
        guard let config = KeychainService.loadASRConfig(for: .volcano) as? VolcanoASRConfig else {
            throw SweepError.missingVolcanoConfig
        }
        let options = ASRRequestOptions(
            enablePunc: true,
            hotwords: HotwordStorage.loadEffective(),
            boostingTableID: ASRBiasSettingsStorage.load().boostingTableID,
            bypassProxy: ProxyBypassMode.current.bypassASR
        )
        DebugFileLogger.log("asr-sweep start sample=\(sampleID) variants=\(variants.count) audio=\(String(format: "%.1f", Double(pcm.count) / bytesPerSecond))s")

        var results: [Int: String] = [:]
        let all = variants
        var next = 0
        await withTaskGroup(of: (Int, String).self) { group in
            func launch(_ index: Int) {
                let variant = all[index]
                group.addTask {
                    let report = await runVariant(variant, pcm: pcm, config: config, options: options)
                    return (index, report)
                }
            }
            while next < min(concurrency, all.count) { launch(next); next += 1 }
            while let (index, report) = await group.next() {
                results[index] = report
                if next < all.count { launch(next); next += 1 }
            }
        }

        var text = """
        # Volcano replay sweep
        sample: \(sampleID)
        audio: \(audioURL.lastPathComponent) (\(String(format: "%.2f", Double(pcm.count) / bytesPerSecond)) s)
        resource: \(config.resourceId)
        hotwords: \(options.boostingTableID.map { _ in "boosting table" } ?? "\(VolcProtocol.inlineHotwords(options.hotwords).count) inline")
        original: \(originalText)

        """
        for index in all.indices {
            text += "\n" + (results[index] ?? "## \(all[index].name)\n  (no result)") + "\n"
        }

        let dir = root.appendingPathComponent("sweeps", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let out = dir.appendingPathComponent("\(sampleID.prefix(8))-\(formatter.string(from: Date())).txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        DebugFileLogger.log("asr-sweep done report=\(out.path)")
        return out
    }

    // MARK: - Sample lookup

    private static func locateSample(prefix: String, root: URL) throws -> (String, URL, String) {
        let manifest = root.appendingPathComponent(ASRSampleArchive.manifestFileName)
        guard let content = try? String(contentsOf: manifest, encoding: .utf8) else {
            throw SweepError.sampleNotFound
        }
        for line in content.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (entry["id"] as? String)?.lowercased(), id.hasPrefix(prefix),
                  let file = entry["audioFile"] as? String,
                  !file.contains(".."), !file.hasPrefix("/")
            else { continue }
            let url = root.appendingPathComponent(file)
            guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) else { continue }
            return (id, url, entry["rawText"] as? String ?? "")
        }
        throw SweepError.sampleNotFound
    }

    /// Reads the PCM payload of a 16 kHz mono Int16 WAV written by the archive.
    private static func readPCM(_ url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { throw SweepError.unreadableAudio }
        // Walk the RIFF chunks to find "data".
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset ..< offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            if id == "data" {
                let end = min(data.count, offset + 8 + size)
                return Data(data[offset + 8 ..< end])
            }
            offset += 8 + size + (size & 1)
        }
        throw SweepError.unreadableAudio
    }

    // MARK: - One variant

    private struct DefiniteEvent {
        let arrival: Double
        let startMs: Int?
        let endMs: Int?
        let text: String
    }

    private static func runVariant(
        _ variant: Variant,
        pcm: Data,
        config: VolcanoASRConfig,
        options: ASRRequestOptions
    ) async -> String {
        var lines = ["## \(variant.name)"]
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!)
        for (field, value) in VolcProtocol.authHeaders(
            authentication: config.authentication,
            resourceId: config.resourceId,
            connectId: UUID().uuidString
        ) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        var options = options
        options.contextHistoryLength = variant.tuning.contextHistoryLength
        let payload = VolcProtocol.buildClientRequest(uid: config.uid, options: options, tuning: variant.tuning)
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
            return (lines + ["  FAILED connect: \(error.localizedDescription)"]).joined(separator: "\n")
        }

        let lastPacketAt = LockedBox<Double?>(nil)
        let sender = Task {
            var offset = 0
            while offset < pcm.count {
                let end = min(pcm.count, offset + chunkBytes)
                let packet = VolcProtocol.encodeAudioPacket(audioData: Data(pcm[offset ..< end]), isLast: false)
                try await task.send(.data(packet))
                offset = end
                let target = Double(offset) / bytesPerSecond
                let wait = target - elapsed()
                if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
            }
            try await task.send(.data(VolcProtocol.encodeAudioPacket(audioData: Data(), isLast: true)))
            lastPacketAt.value = elapsed()
        }

        var events: [DefiniteEvent] = []
        var seen = Set<String>()
        var lastResult: [String: Any] = [:]
        var failure: String?
        receive: while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if lastPacketAt.value == nil { failure = "receive: \(error.localizedDescription)" }
                break
            }
            guard case .data(let data) = message, data.count >= 4 else { continue }
            let messageType = (data[1] >> 4) & 0x0F
            if messageType == 0x0F {
                let extracted = VolcProtocol.extractServerError(data)
                if extracted.code != nil || extracted.message != nil {
                    failure = "server error \(extracted.code.map(String.init) ?? "?"): \(extracted.message ?? "")"
                }
                break receive
            }
            guard let json = rawJSON(data) else { continue }
            let result = json["result"] as? [String: Any] ?? [:]
            lastResult = result
            for utterance in result["utterances"] as? [[String: Any]] ?? [] {
                guard utterance["definite"] as? Bool == true else { continue }
                let text = utterance["text"] as? String ?? ""
                let startMs = utterance["start_time"] as? Int
                let endMs = utterance["end_time"] as? Int
                let key = "\(startMs ?? -1)|\(endMs ?? -1)|\(text)"
                if seen.insert(key).inserted {
                    events.append(DefiniteEvent(arrival: elapsed(), startMs: startMs, endMs: endMs, text: text))
                }
            }
            if (data[1] & 0x0F) == 0b0011 { break }
        }
        let finishedAt = elapsed()
        sender.cancel()

        if let failure { lines.append("  FAILED \(failure)") }
        for event in events {
            let span = "\(event.startMs.map(String.init) ?? "?")–\(event.endMs.map(String.init) ?? "?")ms"
            lines.append(String(format: "  definite @%5.2fs  [%@] %@", event.arrival, span, event.text))
        }
        let utterances = (lastResult["utterances"] as? [[String: Any]] ?? []).map { u -> String in
            let text = u["text"] as? String ?? ""
            return u["definite"] as? Bool == true ? "「\(text)」✓" : "「\(text)」"
        }
        lines.append("  final utterances: " + utterances.joined(separator: " | "))
        lines.append("  result.text: \(lastResult["text"] as? String ?? "")")
        let pieces = (lastResult["utterances"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
        lines.append("  app text (CJK join): \(CJKAwareJoiner.join(pieces))")
        if let sentAt = lastPacketAt.value {
            lines.append(String(format: "  last packet → end: %.0f ms", (finishedAt - sentAt) * 1000))
        }
        return lines.joined(separator: "\n")
    }

    private static func rawJSON(_ data: Data) -> [String: Any]? {
        guard let header = try? VolcHeader.decode(from: data) else { return nil }
        var offset = Int(header.headerSize) * 4
        if header.flags == .positiveSequence || header.flags == .negativeSequenceLast { offset += 4 }
        guard data.count >= offset + 4 else { return nil }
        let base = data.startIndex
        let size = Int(data[base + offset]) << 24 | Int(data[base + offset + 1]) << 16
            | Int(data[base + offset + 2]) << 8 | Int(data[base + offset + 3])
        offset += 4
        guard data.count >= offset + size else { return nil }
        var payload = Data(data[base + offset ..< base + offset + size])
        if header.compression == .gzip, let unzipped = try? VolcProtocol.gzipDecompress(payload) {
            payload = unzipped
        }
        return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }
}

/// Minimal lock-protected box for a value shared with a child task.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
