import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio

// MARK: - Start Sound Style

/// User-selectable start sound options, persisted via @AppStorage("tf_startSound").
enum StartSoundStyle: String, CaseIterable, Sendable {
    case off       = "off"
    case chime     = "chime"
    case pluck     = "pluck"
    case submerge  = "submerge"
    case pong      = "pong"
    case waterDrop1 = "waterDrop1"
    case waterDrop2 = "waterDrop2"
    case keyboard  = "keyboard"

    var displayName: String {
        switch self {
        case .off:        return L("关闭", "Off")
        case .chime:      return L("电子提示音", "Chime")
        case .pluck:      return L("拨弦", "Pluck")
        case .submerge:   return L("沉浸", "Submerge")
        case .pong:       return L("乒", "Pong")
        case .waterDrop1: return L("水滴 1", "Water Drop 1")
        case .waterDrop2: return L("水滴 2", "Water Drop 2")
        case .keyboard:   return L("键盘", "Keyboard")
        }
    }
}

/// Audio feedback using pre-prepared AVAudioPlayer instances.
/// Buffers are generated/loaded at warmup and converted to WAV data.
/// AVAudioPlayer uses AudioQueue internally, which pre-buffers audio data
/// before playback starts, avoiding the frame-drop issues seen with
/// AVAudioPlayerNode's real-time render callback path.
enum SoundFeedback {

    private struct ToneSpec {
        let tones: [(frequency: Double, duration: Double)]
        let volume: Float
        let label: String
    }

    /// All mutable state is accessed exclusively on this serial queue.
    private static let soundQueue = DispatchQueue(label: "com.type4me.sound")
    nonisolated(unsafe) private static var hasWarmedUp = false

    /// Pre-prepared AVAudioPlayer instances keyed by label (used for keep-alive, primer).
    nonisolated(unsafe) private static var cachedPlayers: [String: AVAudioPlayer] = [:]

    /// Cached WAV data for creating fresh AVAudioPlayer instances on each play.
    nonisolated(unsafe) private static var cachedWAVData: [String: Data] = [:]

    /// Retains the currently-playing player so it doesn't get deallocated.
    nonisolated(unsafe) private static var activePlayer: AVAudioPlayer?

    /// Persistent silent player that keeps the audio output path (especially BT A2DP)
    /// alive. Without this, BT speakers need to re-establish the audio stream on each
    /// play(), losing the first ~200-500ms. Mirrors Chromium's persistent AudioContext.
    nonisolated(unsafe) private static var keepAlivePlayer: AVAudioPlayer?

    /// Cached PCM buffers for tone generation and bundled sounds.
    nonisolated(unsafe) private static var cachedBuffers: [String: AVAudioPCMBuffer] = [:]

    private static let sampleRate: Double = 44100
    private static let engineFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: true
    )!

    private static let startSpec = ToneSpec(
        tones: [(frequency: 587, duration: 0.06), (frequency: 880, duration: 0.09)],
        volume: 0.52, label: "start"
    )
    private static let stopSpec = ToneSpec(
        tones: [(frequency: 740, duration: 0.04), (frequency: 1175, duration: 0.06)],
        volume: 0.3, label: "stop"
    )
    private static let errorSpec = ToneSpec(
        tones: [(frequency: 330, duration: 0.08), (frequency: 220, duration: 0.1)],
        volume: 0.35, label: "error"
    )

    // MARK: - Public API

    static func warmUp() {
        soundQueue.async {
            guard !hasWarmedUp else { return }
            hasWarmedUp = true
            NSLog("[SoundFeedback] warmUp")
            DebugFileLogger.log("sound warmUp")
            prepareBuffers()
            preparePlayers()
        }
    }

    static func playStart() {
        let style = StartSoundStyle(
            rawValue: UserDefaults.standard.string(forKey: "tf_startSound") ?? StartSoundStyle.chime.rawValue
        ) ?? .chime
        NSLog("[SoundFeedback] playStart style=%@", style.rawValue)
        DebugFileLogger.log("sound playStart style=\(style.rawValue)")
        switch style {
        case .off: return
        case .chime: playSound(startSpec.label, volume: startSpec.volume)
        case .pluck: playSound("pluck", volume: 1.0, fallback: startSpec)
        case .submerge: playSound("submerge", volume: 1.0, fallback: startSpec)
        case .pong: playSound("pong", volume: 1.0, fallback: startSpec)
        case .waterDrop1, .waterDrop2, .keyboard:
            playSound(style.rawValue, volume: 1.0, fallback: startSpec)
        }
    }

    static func playStop() {
        let style = StartSoundStyle(
            rawValue: UserDefaults.standard.string(forKey: "tf_startSound") ?? StartSoundStyle.chime.rawValue
        ) ?? .chime
        NSLog("[SoundFeedback] playStop style=%@", style.rawValue)
        DebugFileLogger.log("sound playStop style=\(style.rawValue)")
        switch style {
        case .off: return
        case .chime: playSound(stopSpec.label, volume: stopSpec.volume)
        case .pluck: playSound("pluck", volume: 1.0, fallback: stopSpec)
        case .submerge: playSound("submerge", volume: 1.0, fallback: stopSpec)
        case .pong: playSound("pong", volume: 1.0, fallback: stopSpec)
        case .waterDrop1: playSound(StartSoundStyle.waterDrop1.rawValue, volume: 1.0, fallback: stopSpec)
        case .waterDrop2: playSound(StartSoundStyle.waterDrop2.rawValue, volume: 1.0, fallback: stopSpec)
        case .keyboard: playSound("keyboard-end", volume: 1.0, fallback: stopSpec)
        }
    }

    static func playError() {
        NSLog("[SoundFeedback] playError")
        DebugFileLogger.log("sound playError invoked")
        playSound(errorSpec.label, volume: errorSpec.volume)
    }

    static func previewStartSound(_ style: StartSoundStyle) {
        switch style {
        case .off: return
        case .chime: playSound(startSpec.label, volume: startSpec.volume)
        case .pluck: playSound("pluck", volume: 1.0, fallback: startSpec)
        case .submerge: playSound("submerge", volume: 1.0, fallback: startSpec)
        case .pong: playSound("pong", volume: 1.0, fallback: startSpec)
        case .waterDrop1, .waterDrop2, .keyboard:
            playSound(style.rawValue, volume: 1.0, fallback: startSpec)
        }
    }

    /// Play a silent primer to wake up BT amplifiers before the real sound.
    /// The primer is a short silent WAV played via AVAudioPlayer. By the time
    /// it finishes, the BT output path is warm and the next sound plays instantly.
    static func playBTPrimer(durationMs: Int) {
        soundQueue.async {
            let frames = Int(sampleRate * Double(durationMs) / 1000.0)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            // Buffer is already zeroed (silence)
            guard let wavData = pcmBufferToWAVData(buffer),
                  let player = try? AVAudioPlayer(data: wavData) else { return }
            applyOutputDevice(to: player)
            player.play()
            cachedPlayers["_btPrimer"] = player // retain
            NSLog("[SoundFeedback] BT primer playing (%dms)", durationMs)
            DebugFileLogger.log("sound BT primer \(durationMs)ms")
        }
    }

    // MARK: - Speaker Keep-Alive

    /// Start a persistent silent audio loop to keep the output path warm.
    /// Essential for BT speakers whose A2DP link drops between sounds.
    static func enableSpeakerKeepAlive() {
        soundQueue.async {
            guard keepAlivePlayer == nil else { return }
            // 16kHz tone at 0.005 amplitude, looping forever.
            // 16kHz is at the upper edge of adult hearing (most people over 25
            // can't hear it). Amplitude 0.005 (~-46dB) is very quiet even for
            // those who can. BT SBC codec supports up to ~16kHz, so the data
            // passes through to keep the DAC and amplifier active.
            let frames = Int(sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = buffer.floatChannelData![0]
            for i in 0..<frames {
                data[i] = Float(sin(2.0 * .pi * 16000.0 * Double(i) / sampleRate) * 0.005)
            }
            guard let wavData = pcmBufferToWAVData(buffer),
                  let player = try? AVAudioPlayer(data: wavData) else { return }
            player.numberOfLoops = -1
            player.volume = 1.0
            applyOutputDevice(to: player)
            player.play()
            keepAlivePlayer = player
            NSLog("[SoundFeedback] keep-alive started (16kHz)")
            DebugFileLogger.log("speaker keep-alive started (16kHz)")
        }
    }

    static func disableSpeakerKeepAlive() {
        soundQueue.async {
            keepAlivePlayer?.stop()
            keepAlivePlayer = nil
            NSLog("[SoundFeedback] keep-alive stopped")
            DebugFileLogger.log("speaker keep-alive stopped")
        }
    }

    /// Restart keep-alive if active (e.g., after output device change).
    static func restartKeepAliveIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "tf_speakerKeepAlive") else { return }
        disableSpeakerKeepAlive()
        enableSpeakerKeepAlive()
    }

    // MARK: - Buffer Preparation

    private static func prepareBuffers() {
        // Chime: synthesized tones
        cachedBuffers["start"] = buildToneBuffer(for: startSpec)
        cachedBuffers["stop"] = buildToneBuffer(for: stopSpec)
        cachedBuffers["error"] = buildToneBuffer(for: errorSpec)

        // Pre-cache bundled sounds
        let bundledStyles: [StartSoundStyle] = [.waterDrop1, .waterDrop2, .keyboard]
        for style in bundledStyles {
            if let url = bundledSoundURL(for: style) {
                cachedBuffers[style.rawValue] = loadWAVBuffer(url: url)
            }
        }
        for filename in ["keyboard-end", "pluck", "submerge", "pong"] {
            if let url = bundledSoundURL(filename: filename) {
                cachedBuffers[filename] = loadWAVBuffer(url: url)
            }
        }
    }

    /// Pre-create AVAudioPlayer instances from cached buffers (like Howler.js initSounds).
    /// Players are reused on each play, not re-created.
    private static func preparePlayers() {
        for (label, buffer) in cachedBuffers {
            guard let wavData = pcmBufferToWAVData(buffer) else {
                NSLog("[SoundFeedback] failed to convert %@ to WAV", label)
                continue
            }
            do {
                let player = try AVAudioPlayer(data: wavData)
                player.volume = 0.4  // match Howler.js volume
                player.prepareToPlay()
                cachedPlayers[label] = player
                NSLog("[SoundFeedback] prepared: %@ (%.0fms)", label,
                      Double(buffer.frameLength) / sampleRate * 1000)
            } catch {
                NSLog("[SoundFeedback] failed to create player for %@: %@", label, error.localizedDescription)
            }
        }
        DebugFileLogger.log("sound players prepared: \(cachedPlayers.keys.sorted().joined(separator: ", "))")
    }

    private static func buildToneBuffer(for spec: ToneSpec) -> AVAudioPCMBuffer {
        let leadInFrames = Int(0.2 * sampleRate)
        var totalFrames = leadInFrames
        for tone in spec.tones { totalFrames += Int(tone.duration * sampleRate) }

        let buffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: AVAudioFrameCount(totalFrames))!
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        let data = buffer.floatChannelData![0]

        var offset = leadInFrames
        for tone in spec.tones {
            let frameCount = Int(tone.duration * sampleRate)
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                let envelope = sin(.pi * t / tone.duration)
                data[offset + i] = Float(sin(2.0 * .pi * tone.frequency * t) * envelope * 0.5)
            }
            offset += frameCount
        }
        return buffer
    }

    private static func loadWAVBuffer(url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let srcFormat = file.processingFormat

        guard let srcBuffer = AVAudioPCMBuffer(
            pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(file.length)
        ) else { return nil }
        do { try file.read(into: srcBuffer) } catch { return nil }

        if srcFormat.sampleRate == engineFormat.sampleRate
            && srcFormat.channelCount == engineFormat.channelCount {
            return srcBuffer
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: engineFormat) else { return nil }
        let ratio = engineFormat.sampleRate / srcFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(file.length) * ratio) + 256
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: capacity) else { return nil }

        var error: NSError?
        nonisolated(unsafe) var hasData = true
        converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return srcBuffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        return error == nil ? dstBuffer : nil
    }

    // MARK: - Playback via AVAudioPlayer

    private static func playSound(_ label: String, volume: Float, fallback: ToneSpec? = nil) {
        soundQueue.async {
            let player = cachedPlayers[label] ?? (fallback.flatMap { cachedPlayers[$0.label] })
            guard let player else {
                NSLog("[SoundFeedback] %@ no player, no fallback", label)
                NSSound.beep()
                return
            }
            // Stop all other sounds first (like Howler.js: audioCache.forEach(r=>r.stop()))
            for (key, p) in cachedPlayers where key != label {
                p.stop()
            }
            applyOutputDevice(to: player)
            player.currentTime = 0
            player.play()
            NSLog("[SoundFeedback] %@ playing via AVAudioPlayer (vol=%.2f)", label, player.volume)
            DebugFileLogger.log("sound \(label) play() => AVAudioPlayer")
        }
    }

    /// Set the output device on an AVAudioPlayer based on user preference.
    /// Falls back to system default if the selected device is unavailable.
    private static func applyOutputDevice(to player: AVAudioPlayer) {
        let uid = UserDefaults.standard.string(forKey: "tf_selectedSpeakerUID") ?? ""
        guard !uid.isEmpty else { return } // system default
        let available = availableOutputDevices()
        if available.contains(where: { $0.uid == uid }) {
            player.currentDevice = uid
        } else {
            // Selected device gone, reset to system default
            UserDefaults.standard.removeObject(forKey: "tf_selectedSpeakerUID")
        }
    }

    // MARK: - Output Device Enumeration

    /// List available audio output devices via CoreAudio.
    static func availableOutputDevices() -> [(uid: String, name: String)] {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize
        ) == noErr else { return [] }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceIDs
        ) == noErr else { return [] }

        var result: [(uid: String, name: String)] = []
        for id in deviceIDs {
            // Check if device has output channels
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &outputAddress, 0, nil, &bufSize) == noErr,
                  bufSize > 0 else { continue }

            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferList.deallocate() }
            guard AudioObjectGetPropertyData(id, &outputAddress, 0, nil, &bufSize, bufferList) == noErr else { continue }

            let channelCount = (0..<Int(bufferList.pointee.mNumberBuffers)).reduce(0) { total, i in
                total + Int(UnsafeMutableAudioBufferListPointer(bufferList)[i].mNumberChannels)
            }
            guard channelCount > 0 else { continue }

            // Get device UID
            var uidRef: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize,
                                             &uidRef) == noErr else { continue }

            // Get device name
            var nameRef: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize,
                                             &nameRef) == noErr else { continue }

            result.append((uid: uidRef as String, name: nameRef as String))
        }
        return result
    }

    // MARK: - PCM Buffer → WAV Data

    /// Convert a float32 PCM buffer to in-memory WAV data for AVAudioPlayer.
    private static func pcmBufferToWAVData(_ buffer: AVAudioPCMBuffer) -> Data? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let floatData = buffer.floatChannelData?[0] else { return nil }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let sr = UInt32(sampleRate)
        let dataSize = UInt32(frameCount * Int(channels) * bytesPerSample)

        var wav = Data(capacity: 44 + Int(dataSize))

        // RIFF header
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendUInt32(&wav, 36 + dataSize)
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendUInt32(&wav, 16)
        appendUInt16(&wav, 1) // PCM
        appendUInt16(&wav, channels)
        appendUInt32(&wav, sr)
        appendUInt32(&wav, sr * UInt32(channels) * UInt32(bytesPerSample))
        appendUInt16(&wav, channels * UInt16(bytesPerSample))
        appendUInt16(&wav, bitsPerSample)

        // data chunk
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendUInt32(&wav, dataSize)

        // Convert float32 samples to int16
        for i in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, floatData[i]))
            let int16 = Int16(clamped * Float(Int16.max))
            appendInt16(&wav, int16)
        }
        return wav
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    private static func appendInt16(_ data: inout Data, _ value: Int16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    // MARK: - Bundled Sound URLs

    private static func bundledSoundURL(for style: StartSoundStyle) -> URL? {
        let filename: String
        switch style {
        case .waterDrop1: filename = "water-drop-1"
        case .waterDrop2: filename = "water-drop-2"
        case .keyboard: filename = "keyboard-start"
        default: return nil
        }
        return bundledSoundURL(filename: filename)
    }

    private static func bundledSoundURL(filename: String) -> URL? {
        if let url = Bundle.main.url(forResource: filename, withExtension: "wav", subdirectory: "Sounds") {
            return url
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Type4Me", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        let url = appSupport.appendingPathComponent("\(filename).wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
