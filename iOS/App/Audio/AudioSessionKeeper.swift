import AVFoundation
import os

/// Keeps the app alive in the background between dictations.
///
/// Silent output keeps keyboard commands deliverable between dictations.
/// An active PiP session supplies the eligibility iOS requires to open the
/// microphone from the background. This keeper does not open the input until
/// startInput is called, and stopInput returns to a fresh output-only engine.
final class AudioSessionKeeper {
    private let logger = Logger(subsystem: "com.type4me.ios", category: "AudioSession")
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var isGraphReady = false
    private(set) var isActive = false

    var onInterruptionEnded: ((Bool) -> Void)?
    /// Receives the notification's userInfo, which says why.
    var onInterruptionBegan: (([AnyHashable: Any]?) -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        // Mixable, so music and videos in other apps keep playing. A2DP rather
        // than HFP keeps AirPods in high-quality playback while idle; the
        // built-in microphone is used for dictation.
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
        )
        // iOS mutes haptics while the mic records, which would swallow the
        // keyboard's tap when a held finger crosses into cancel or lock.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        try startSilence()
        isActive = true
        logger.info("voice session activated")
    }

    // MARK: - Microphone on the running engine

    /// Opens the microphone on the engine that is already playing silence,
    /// instead of starting a second audio engine. A second engine's I/O
    /// failed to start in the background on a device ('what'); reusing the
    /// I/O the system already lets us run is the other way in.
    func startInput(tap: @escaping (AVAudioPCMBuffer) -> Void) throws -> AVAudioFormat {
        player.stop()
        engine.stop()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            rebuildOutputOnly()
            throw NSError(domain: "Type4Me", code: 1, userInfo: [NSLocalizedDescriptionKey: L("没有可用的麦克风输入", "No microphone input is available")])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in tap(buffer) }
        do {
            try startSilence()
        } catch {
            input.removeTap(onBus: 0)
            rebuildOutputOnly()
            throw error
        }
        logger.info("input opened on the shared engine")
        return format
    }

    /// Closes the microphone. An engine whose input was used keeps the input
    /// unit enabled, so the silent output moves to a fresh, output-only engine
    /// and the indicator goes off.
    func stopInput() {
        engine.inputNode.removeTap(onBus: 0)
        rebuildOutputOnly()
    }

    private func rebuildOutputOnly() {
        player.stop()
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        isGraphReady = false
        guard isActive else { return }
        do {
            try startSilence()
        } catch {
            logger.error("silence restart failed: \(error.localizedDescription, privacy: .public)")
            onLog?(L("静音输出没能重新开始：\(MicrophoneCapture.describe(error))，App 在后台可能会被挂起", "Silent output didn't restart: \(MicrophoneCapture.describe(error)). The app may be suspended in the background."))
        }
    }

    var onLog: ((String) -> Void)?

    /// One line for the diagnostics log when the microphone will not start.
    var diagnostics: String {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map(\.portName).joined(separator: ",")
        let outputs = session.currentRoute.outputs.map(\.portName).joined(separator: ",")
        let category = session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        return L(
            "会话\(isActive ? "已激活" : "未激活")，静音\(player.isPlaying ? "播放中" : "已停")，类别 \(category)，"
                + "输入可用 \(session.isInputAvailable)，输入 [\(inputs)]，输出 [\(outputs)]，其他声音 \(session.isOtherAudioPlaying)",
            "session \(isActive ? "active" : "inactive"), silence \(player.isPlaying ? "playing" : "stopped"), category \(category), "
                + "input available \(session.isInputAvailable), inputs [\(inputs)], outputs [\(outputs)], other audio \(session.isOtherAudioPlaying)"
        )
    }

    func deactivate() {
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
        logger.info("voice session deactivated")
    }

    private func startSilence() throws {
        if !isGraphReady {
            engine.attach(player)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: format)
            isGraphReady = true
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = buffer.frameCapacity // zero-filled: one second of silence
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
            logger.info("interruption began")
            onInterruptionBegan?(info)
        case .ended:
            // Try to get the session back even without `shouldResume`: a
            // phone call ending is exactly when the user wants to dictate again.
            var resumed = false
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try startSilence()
                resumed = true
            } catch {
                logger.error("resume failed: \(error.localizedDescription, privacy: .public)")
            }
            onInterruptionEnded?(resumed)
        @unknown default:
            break
        }
    }

    @objc private func handleMediaReset(_ note: Notification) {
        isGraphReady = false
        onInterruptionEnded?(false)
    }
}
