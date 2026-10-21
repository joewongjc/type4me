import Foundation

/// Minimal protocol for audio capture engines to support test injection and timing inspection.
protocol AudioCapturing: AnyObject, Sendable {
    var selectedDeviceUID: String? { get set }
    var onAudioChunk: ((Data) -> Void)? { get set }
    var onAudioLevel: ((Float) -> Void)? { get set }
    var onFirstSample: (@Sendable (ContinuousClock.Instant) -> Void)? { get set }

    var lastStartInfo: AudioCaptureStartInfo { get }

    func start() throws
    func stop()
    func getRecordedAudio() -> Data
    func warmUp()
    func prepareIfEligible()
    func invalidatePrepared(reason: String)
}

extension AudioCapturing {
    func warmUp() {}
    func prepareIfEligible() {}
    func invalidatePrepared(reason: String) {}
}

struct AudioCaptureStartInfo: Sendable {
    var deviceInputDuration: Duration?
    var startRunningDuration: Duration?
    var preparedStatus: String
    var deviceCategory: String

    init(
        deviceInputDuration: Duration? = nil,
        startRunningDuration: Duration? = nil,
        preparedStatus: String = "-",
        deviceCategory: String = "-"
    ) {
        self.deviceInputDuration = deviceInputDuration
        self.startRunningDuration = startRunningDuration
        self.preparedStatus = preparedStatus
        self.deviceCategory = deviceCategory
    }
}
