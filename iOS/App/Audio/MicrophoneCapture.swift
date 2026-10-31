import AVFoundation
import os

/// Microphone input converted to what Volcengine expects: 16 kHz mono
/// 16-bit PCM, delivered in ~100 ms chunks.
final class MicrophoneCapture {
    private let logger = Logger(subsystem: "com.type4me.ios", category: "Microphone")
    private let queue = DispatchQueue(label: "com.type4me.ios.capture")
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!
    private var converter: AVAudioConverter?
    private var pending = Data()
    private static let chunkBytes = 3_200 // 100 ms

    /// While false, input keeps running but buffers are dropped. Used by the
    /// always-on strategy between dictations.
    private var isForwarding = false
    private var onChunk: ((Data) -> Void)?
    private var onLevel: ((Float) -> Void)?

    enum Path: String {
        /// The engine that already plays silence in the background.
        case shared
        /// A second engine of our own.
        case separate

        var title: String {
            switch self {
            case .shared: return L("共用静音通道", "shared silent engine")
            case .separate: return L("独立引擎", "separate engine")
            }
        }
    }

    private let keeper: AudioSessionKeeper
    private let ownEngine = AVAudioEngine()
    private(set) var activePath: Path?
    /// What happened on the way in, for the diagnostics log.
    private(set) var lastStartNotes = ""
    /// The errors behind the last failed start, so the caller can tell
    /// "another app holds the mic" from other failures.
    private(set) var lastStartErrors: [Error] = []

    init(keeper: AudioSessionKeeper) {
        self.keeper = keeper
    }

    var isRunning: Bool { activePath != nil }

    /// Starts the input, trying the shared engine first. Throws when iOS
    /// refuses both ways; from the background that is the open question.
    func startEngine() throws {
        guard activePath == nil else { return }
        var notes: [String] = []
        lastStartErrors = []
        do {
            let format = try keeper.startInput { [weak self] buffer in self?.handle(buffer) }
            converter = AVAudioConverter(from: format, to: targetFormat)
            activePath = .shared
            lastStartNotes = Path.shared.title
            return
        } catch {
            lastStartErrors.append(error)
            notes.append(L("\(Path.shared.title)失败 \(Self.describe(error))", "\(Path.shared.title) failed: \(Self.describe(error))"))
        }
        do {
            try startOwnEngine()
            activePath = .separate
            notes.append(L("\(Path.separate.title)成功", "\(Path.separate.title) succeeded"))
            lastStartNotes = notes.joined(separator: "；")
        } catch {
            lastStartErrors.append(error)
            notes.append(L("\(Path.separate.title)失败 \(Self.describe(error))", "\(Path.separate.title) failed: \(Self.describe(error))"))
            lastStartNotes = notes.joined(separator: "；")
            throw NSError(domain: "Type4Me", code: 2, userInfo: [NSLocalizedDescriptionKey: lastStartNotes])
        }
    }

    private func startOwnEngine() throws {
        let input = ownEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Type4Me", code: 1, userInfo: [NSLocalizedDescriptionKey: L("没有可用的麦克风输入", "No microphone input is available")])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        ownEngine.prepare()
        do {
            try ownEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        logger.info("microphone started at \(inputFormat.sampleRate) Hz")
    }

    func stopEngine() {
        switch activePath {
        case .shared?:
            keeper.stopInput()
        case .separate?:
            ownEngine.inputNode.removeTap(onBus: 0)
            ownEngine.stop()
            // Drops the input unit as well, so iOS takes the indicator down.
            ownEngine.reset()
        case nil:
            break
        }
        activePath = nil
        queue.sync { isForwarding = false; pending.removeAll() }
    }

    /// "561145187 (!rec)": the code plus its four-letter form, which is how
    /// Core Audio errors are documented.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        let raw = UInt32(truncatingIfNeeded: ns.code)
        let bytes = [24, 16, 8, 0].map { UInt8((raw >> UInt32($0)) & 0xFF) }
        if ns.code > 0x2020_2020, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            text += " (\(String(decoding: bytes, as: UTF8.self)))"
        }
        return text + " " + ns.localizedDescription
    }

    func beginForwarding(onChunk: @escaping (Data) -> Void, onLevel: @escaping (Float) -> Void) {
        #if DEBUG
        FakeSpeech.shared?.rewind()
        #endif
        queue.sync {
            pending.removeAll()
            self.onChunk = onChunk
            self.onLevel = onLevel
            isForwarding = true
        }
    }

    /// Stops forwarding and returns whatever is buffered so the tail of the
    /// last word is not lost.
    func endForwarding() -> Data {
        queue.sync {
            isForwarding = false
            let rest = pending
            pending.removeAll()
            onChunk = nil
            onLevel = nil
            return rest
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData else { return }
        let count = Int(output.frameLength)
        var data = Data(bytes: samples[0], count: count * 2)
        #if DEBUG
        if let fake = FakeSpeech.shared { data = fake.next(bytes: data.count) }
        #endif

        var sum: Float = 0
        data.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) {
                let f = Float(v) / 32_768
                sum += f * f
            }
        }
        let rms = sqrt(sum / Float(max(count, 1)))
        let level = min(1, max(0, (20 * log10(max(rms, 0.000_01)) + 50) / 50))

        queue.async { [weak self] in
            guard let self, self.isForwarding else { return }
            self.pending.append(data)
            self.onLevel?(level)
            while self.pending.count >= Self.chunkBytes {
                let chunk = self.pending.prefix(Self.chunkBytes)
                self.pending.removeFirst(Self.chunkBytes)
                self.onChunk?(Data(chunk))
            }
        }
    }
}

#if DEBUG
/// Device UI tests set `T4M_FAKE_SPEECH` to raw 16 kHz mono 16-bit PCM file in the
/// App Group's Library folder. The real microphone still opens (so the
/// background path is exercised), but its samples are replaced by the file,
/// so a test never needs to play sound out loud.
final class FakeSpeech: @unchecked Sendable {
    static let shared: FakeSpeech? = {
        guard let name = ProcessInfo.processInfo.environment["T4M_FAKE_SPEECH"],
              let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroupID),
              let data = try? Data(contentsOf: base.appendingPathComponent("Library").appendingPathComponent(name)),
              !data.isEmpty
        else { return nil }
        return FakeSpeech(pcm: data)
    }()

    private let pcm: Data
    private var offset = 0
    private let lock = NSLock()

    private init(pcm: Data) { self.pcm = pcm }

    func rewind() {
        lock.lock(); offset = 0; lock.unlock()
    }

    func next(bytes: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        var out = Data(count: bytes)
        let available = max(0, min(bytes, pcm.count - offset))
        if available > 0 {
            out.replaceSubrange(0..<available, with: pcm.subdata(in: offset..<(offset + available)))
            offset += available
        }
        return out
    }
}
#endif
