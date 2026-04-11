@preconcurrency import AVFoundation
import os

/// Keeps audio devices alive by maintaining minimal audio I/O activity.
/// Speaker keep-alive delegates to SoundFeedback (same AVAudioPlayer path).
/// Microphone keep-alive runs a lightweight AVCaptureSession.
enum AudioKeepAliveManager {

    private static let logger = Logger(subsystem: "com.type4me.keepalive", category: "AudioKeepAlive")
    private static let queue = DispatchQueue(label: "com.type4me.keepalive.mic", qos: .background)

    nonisolated(unsafe) private static var micSession: AVCaptureSession?

    // MARK: - Public

    /// Restore keep-alive state from UserDefaults. Call once at app launch.
    static func syncState() {
        syncSpeakerState()
        syncMicState()
    }

    static func syncSpeakerState() {
        let enabled = UserDefaults.standard.bool(forKey: "tf_speakerKeepAlive")
        if enabled {
            SoundFeedback.enableSpeakerKeepAlive()
        } else {
            SoundFeedback.disableSpeakerKeepAlive()
        }
    }

    static func syncMicState() {
        let enabled = UserDefaults.standard.bool(forKey: "tf_micKeepAlive")
        queue.async {
            if enabled { startMic() } else { stopMic() }
        }
    }

    // MARK: - Microphone

    private static func startMic() {
        guard micSession == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            logger.warning("Mic keep-alive skipped: no permission")
            return
        }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            logger.warning("Mic keep-alive skipped: no input device")
            return
        }

        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            // No delegate: captured audio is silently discarded.

            session.startRunning()
            micSession = session
            logger.info("Mic keep-alive started")
        } catch {
            logger.error("Mic keep-alive failed: \(error.localizedDescription)")
        }
    }

    private static func stopMic() {
        guard let session = micSession else { return }
        session.stopRunning()
        micSession = nil
        logger.info("Mic keep-alive stopped")
    }
}
