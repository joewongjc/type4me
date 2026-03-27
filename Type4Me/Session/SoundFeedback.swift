import AppKit
import AVFoundation

// MARK: - Start Sound Style

/// User-selectable start sound options, persisted via @AppStorage("tf_startSound").
enum StartSoundStyle: String, CaseIterable, Sendable {
    case off       = "off"
    case chime     = "chime"
    case waterDrop1 = "waterDrop1"
    case waterDrop2 = "waterDrop2"
    case keyboard  = "keyboard"

    var displayName: String {
        switch self {
        case .off:        return L("关闭", "Off")
        case .chime:      return L("电子提示音", "Chime")
        case .waterDrop1: return L("水滴 1", "Water Drop 1")
        case .waterDrop2: return L("水滴 2", "Water Drop 2")
        case .keyboard:   return L("键盘", "Keyboard")
        }
    }
}

/// Synthesized and bundled audio feedback tones.
enum SoundFeedback {

    private enum Delivery {
        case afplay
        case cachedPlayer
    }

    private struct ToneSpec {
        let tones: [(frequency: Double, duration: Double)]
        let volume: Float
        let label: String
        let delivery: Delivery
    }

    nonisolated(unsafe) private static var hasWarmedUp = false
    nonisolated(unsafe) private static var cachedPlayers: [String: AVAudioPlayer] = [:]
    nonisolated(unsafe) private static var activeProcesses: [Process] = []

    private static let startSpec = ToneSpec(
        tones: [
            (frequency: 587, duration: 0.06),
            (frequency: 880, duration: 0.09),
        ],
        volume: 0.52,
        label: "start",
        delivery: .afplay
    )

    private static let stopSpec = ToneSpec(
        tones: [
            (frequency: 740, duration: 0.04),
            (frequency: 1175, duration: 0.06),
        ],
        volume: 0.3,
        label: "stop",
        delivery: .cachedPlayer
    )

    private static let errorSpec = ToneSpec(
        tones: [
            (frequency: 330, duration: 0.08),
            (frequency: 220, duration: 0.1),
        ],
        volume: 0.35,
        label: "error",
        delivery: .cachedPlayer
    )

    // MARK: - Public API

    static func warmUp() {
        DispatchQueue.main.async {
            guard !hasWarmedUp else { return }
            hasWarmedUp = true
            NSLog("[SoundFeedback] warmUp")
            DebugFileLogger.log("sound warmUp")
            _ = try? soundFileURL(for: startSpec)
            preparePlayersIfNeeded()
            // Pre-cache bundled sounds
            for style in [StartSoundStyle.waterDrop1, .waterDrop2, .keyboard] {
                if let url = bundledSoundURL(for: style) {
                    _ = try? preparedPlayer(forURL: url, label: style.rawValue)
                }
            }
        }
    }

    /// Play the start sound according to user preference.
    static func playStart() {
        let style = StartSoundStyle(
            rawValue: UserDefaults.standard.string(forKey: "tf_startSound") ?? StartSoundStyle.chime.rawValue
        ) ?? .chime

        NSLog("[SoundFeedback] playStart style=%@", style.rawValue)
        DebugFileLogger.log("sound playStart style=\(style.rawValue)")

        switch style {
        case .off:
            return
        case .chime:
            play(spec: startSpec, retryCount: 2)
        case .waterDrop1, .waterDrop2, .keyboard:
            playBundled(style: style)
        }
    }

    /// Crisper, more decisive double tone for recording stop.
    static func playStop() {
        NSLog("[SoundFeedback] playStop")
        DebugFileLogger.log("sound playStop invoked")

        // Check if keyboard style is selected - use keyboard-end.wav instead
        let style = StartSoundStyle(
            rawValue: UserDefaults.standard.string(forKey: "tf_startSound") ?? StartSoundStyle.chime.rawValue
        ) ?? .chime

        if style == .keyboard {
            playBundledEnd(filename: "keyboard-end")
        } else {
            play(spec: stopSpec)
        }
    }

    /// Low descending fifth (330→220 Hz). Unmistakable but not harsh.
    static func playError() {
        NSLog("[SoundFeedback] playError")
        DebugFileLogger.log("sound playError invoked")
        play(spec: errorSpec)
    }

    /// Preview a start sound style (for settings UI).
    static func previewStartSound(_ style: StartSoundStyle) {
        switch style {
        case .off: return
        case .chime: play(spec: startSpec, retryCount: 0)
        case .waterDrop1, .waterDrop2, .keyboard: playBundled(style: style)
        }
    }

    // MARK: - Bundled Sound Playback

    private static func bundledSoundURL(for style: StartSoundStyle) -> URL? {
        let filename: String
        switch style {
        case .waterDrop1: filename = "water-drop-1"
        case .waterDrop2: filename = "water-drop-2"
        case .keyboard: filename = "keyboard-start"
        default: return nil
        }
        // Look in app bundle Resources/Sounds
        if let url = Bundle.main.url(forResource: filename, withExtension: "wav", subdirectory: "Sounds") {
            return url
        }
        // Fallback: look in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Type4Me", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        let url = appSupport.appendingPathComponent("\(filename).wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func playBundled(style: StartSoundStyle) {
        DispatchQueue.main.async {
            guard let url = bundledSoundURL(for: style) else {
                NSLog("[SoundFeedback] bundled sound not found for %@, falling back to chime", style.rawValue)
                play(spec: startSpec, retryCount: 0)
                return
            }
            do {
                let player = try preparedPlayer(forURL: url, label: style.rawValue)
                player.stop()
                player.currentTime = 0
                player.volume = 0.5
                _ = player.play()
                NSLog("[SoundFeedback] %@ played OK", style.rawValue)
            } catch {
                NSLog("[SoundFeedback] %@ play failed: %@", style.rawValue, String(describing: error))
                play(spec: startSpec, retryCount: 0)
            }
        }
    }

    /// Play a bundled end sound (keyboard-end) for stop feedback.
    private static func playBundledEnd(filename: String) {
        DispatchQueue.main.async {
            // Look in app bundle Resources/Sounds
            guard let url = Bundle.main.url(forResource: filename, withExtension: "wav", subdirectory: "Sounds") ?? {
                // Fallback: look in Application Support
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Type4Me", isDirectory: true)
                    .appendingPathComponent("Sounds", isDirectory: true)
                let fallbackURL = appSupport.appendingPathComponent("\(filename).wav")
                return FileManager.default.fileExists(atPath: fallbackURL.path) ? fallbackURL : nil
            }() else {
                NSLog("[SoundFeedback] bundled end sound not found: %@, falling back to stop", filename)
                play(spec: stopSpec)
                return
            }
            do {
                let player = try preparedPlayer(forURL: url, label: filename)
                player.stop()
                player.currentTime = 0
                player.volume = 0.5
                _ = player.play()
                NSLog("[SoundFeedback] %@ played OK", filename)
            } catch {
                NSLog("[SoundFeedback] %@ play failed: %@", filename, String(describing: error))
                play(spec: stopSpec)
            }
        }
    }

    private static func preparedPlayer(forURL url: URL, label: String) throws -> AVAudioPlayer {
        if let player = cachedPlayers[label] {
            return player
        }
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        cachedPlayers[label] = player
        return player
    }

    // MARK: - Synthesized Sound Playback

    private static func play(
        spec: ToneSpec,
        retryCount: Int = 0,
        forcedVolume: Float? = nil
    ) {
        DispatchQueue.main.async {
            do {
                let didPlay: Bool
                switch spec.delivery {
                case .afplay:
                    didPlay = try playWithAFPlay(spec: spec)
                case .cachedPlayer:
                    didPlay = try playWithCachedPlayer(spec: spec, forcedVolume: forcedVolume)
                }

                NSLog("[SoundFeedback] %@ play() => %@", spec.label, didPlay ? "true" : "false")
                DebugFileLogger.log("sound \(spec.label) play() => \(didPlay)")
                guard didPlay else {
                    if retryCount > 0 {
                        NSLog("[SoundFeedback] %@ retry scheduled (%d left)", spec.label, retryCount)
                        DebugFileLogger.log("sound \(spec.label) retry scheduled, remaining=\(retryCount)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            play(spec: spec, retryCount: retryCount - 1, forcedVolume: forcedVolume)
                        }
                    } else {
                        NSLog("[SoundFeedback] %@ falling back to NSSound.beep()", spec.label)
                        DebugFileLogger.log("sound \(spec.label) fallback to NSSound.beep()")
                        NSSound.beep()
                    }
                    return
                }
            } catch {
                NSLog("[SoundFeedback] %@ init failed: %@", spec.label, String(describing: error))
                DebugFileLogger.log("sound \(spec.label) init failed: \(String(describing: error))")
                NSSound.beep()
            }
        }
    }

    private static func preparePlayersIfNeeded() {
        do {
            _ = try preparedPlayer(for: stopSpec)
            _ = try preparedPlayer(for: errorSpec)
        } catch {
            DebugFileLogger.log("sound preparePlayersIfNeeded failed: \(String(describing: error))")
        }
    }

    private static func preparedPlayer(for spec: ToneSpec) throws -> AVAudioPlayer {
        if let player = cachedPlayers[spec.label] {
            return player
        }

        let player = try AVAudioPlayer(data: buildToneData(for: spec))
        player.prepareToPlay()
        cachedPlayers[spec.label] = player
        return player
    }

    private static func playWithCachedPlayer(spec: ToneSpec, forcedVolume: Float?) throws -> Bool {
        let player = try preparedPlayer(for: spec)
        player.stop()
        player.currentTime = 0
        player.numberOfLoops = 0
        player.volume = forcedVolume ?? spec.volume
        player.prepareToPlay()
        return player.play()
    }

    private static func playWithAFPlay(spec: ToneSpec) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [try soundFileURL(for: spec).path]
        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                activeProcesses.removeAll { $0 === finished }
                DebugFileLogger.log("sound \(spec.label) afplay terminated status=\(finished.terminationStatus)")
            }
        }
        try process.run()
        activeProcesses.append(process)
        DebugFileLogger.log("sound \(spec.label) afplay launched pid=\(process.processIdentifier)")
        return process.isRunning
    }

    private static func soundFileURL(for spec: ToneSpec) throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Type4Me", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sound-\(spec.label).wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try buildToneData(for: spec).write(to: url, options: .atomic)
        }
        return url
    }

    private static func buildToneData(for spec: ToneSpec) -> Data {
        let sampleRate = 44100.0
        var samples = [Int16]()

        for tone in spec.tones {
            let frameCount = Int(tone.duration * sampleRate)
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                let envelope = sin(.pi * t / tone.duration)
                let value = sin(2.0 * .pi * tone.frequency * t) * envelope * 0.5
                samples.append(Int16(value * 32767))
            }
        }

        return buildWAV(samples: samples, sampleRate: Int(sampleRate))
    }

    // MARK: - WAV Builder

    private static func buildWAV(samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        let fileSize = 36 + dataSize

        var wav = Data(capacity: 44 + dataSize)

        // RIFF header
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        wav.appendLE(UInt32(fileSize))
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk (16 bytes, PCM)
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(1))                    // PCM format
        wav.appendLE(UInt16(1))                    // mono
        wav.appendLE(UInt32(sampleRate))
        wav.appendLE(UInt32(sampleRate * 2))       // byte rate
        wav.appendLE(UInt16(2))                    // block align
        wav.appendLE(UInt16(16))                   // bits per sample

        // data chunk
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        wav.appendLE(UInt32(dataSize))
        for sample in samples {
            wav.appendLE(sample)
        }

        return wav
    }
}

// MARK: - Data Helper

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
