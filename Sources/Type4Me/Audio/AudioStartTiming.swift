import Foundation

/// Records and formats segment timing for recording startup.
struct AudioStartTiming: Sendable, Equatable {
    var awaitIdle: Duration?
    var sessionEntry: Duration?
    var captureStartBegin: Duration?
    var deviceInput: Duration?
    var startRunning: Duration?
    var prepared: String?
    var firstSample: Duration?
    var ready: Duration?
    var device: String?

    init(
        awaitIdle: Duration? = nil,
        sessionEntry: Duration? = nil,
        captureStartBegin: Duration? = nil,
        deviceInput: Duration? = nil,
        startRunning: Duration? = nil,
        prepared: String? = nil,
        firstSample: Duration? = nil,
        ready: Duration? = nil,
        device: String? = nil
    ) {
        self.awaitIdle = awaitIdle
        self.sessionEntry = sessionEntry
        self.captureStartBegin = captureStartBegin
        self.deviceInput = deviceInput
        self.startRunning = startRunning
        self.prepared = prepared
        self.firstSample = firstSample
        self.ready = ready
        self.device = device
    }

    static func formatDuration(_ duration: Duration?) -> String {
        guard let duration else { return "-" }
        let (seconds, attoseconds) = duration.components
        let ms = Int(round(Double(seconds) * 1000.0 + Double(attoseconds) / 1_000_000_000_000_000.0))
        return "\(ms)ms"
    }

    func formattedLine() -> String {
        let awaitIdleStr = Self.formatDuration(awaitIdle)
        let sessionEntryStr = Self.formatDuration(sessionEntry)
        let captureStartBeginStr = Self.formatDuration(captureStartBegin)
        let deviceInputStr = Self.formatDuration(deviceInput)
        let startRunningStr = Self.formatDuration(startRunning)
        let preparedStr = prepared ?? "-"
        let firstSampleStr = Self.formatDuration(firstSample)
        let readyStr = Self.formatDuration(ready)
        let deviceStr = device ?? "-"

        return "audio start timing "
            + "awaitIdle=\(awaitIdleStr) "
            + "sessionEntry=\(sessionEntryStr) "
            + "captureStartBegin=\(captureStartBeginStr) "
            + "deviceInput=\(deviceInputStr) "
            + "startRunning=\(startRunningStr) "
            + "prepared=\(preparedStr) "
            + "firstSample=\(firstSampleStr) "
            + "ready=\(readyStr) "
            + "device=\(deviceStr)"
    }
}
