import Foundation

/// What the keyboard writes to the shared diagnostics log during the test
/// period. Never the dictated text itself: lengths, phases and ids only.
///
/// iOS puts the previous keyboard back when an extension dies, with no
/// callback, so a recording leaves a marker in the App Group with a
/// heartbeat, cleared once the recording ends. A keyboard that starts and
/// finds the marker knows the last one went away mid-recording and logs
/// how long ago, and how much memory it had then.
@MainActor
enum KeyboardDiagnostics {
    private static let markerKey = "keyboardDiagnosticsRecording"
    private static let pid = ProcessInfo.processInfo.processIdentifier
    /// Set by the first controller in this process.
    private static var processStarted = false
    private static var heartbeat: Task<Void, Never>?

    private static let heartbeatInterval: Duration = .seconds(2)
    /// One heartbeat in this many also writes the memory to the log.
    private static let memoryLogEvery = 5

    static func log(_ text: String) {
        SharedLog.add(text)
    }

    /// The first characters of an id, enough to match lines up.
    static func short(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(8)) } ?? "-"
    }

    // MARK: Controller lifecycle

    static func controllerLoaded(_ instance: String, needsGlobe: Bool, fullAccess: Bool) {
        let fresh = !processStarted
        processStarted = true
        log(L(
            "键盘#\(instance) 加载（进程 \(pid)\(fresh ? "，新进程" : "，复用进程")，完全访问\(fullAccess ? "开" : "关")，地球键\(needsGlobe ? "显示" : "不显示")，\(SharedLog.memorySummary)）",
            "Keyboard #\(instance) loaded (process \(pid)\(fresh ? ", new process" : ", reused process"), full access \(fullAccess ? "on" : "off"), globe key \(needsGlobe ? "shown" : "hidden"), \(SharedLog.memorySummary))"
        ))
        checkUnfinishedRecording()
    }

    static func memoryWarning(_ instance: String) {
        log(L("键盘#\(instance) 收到内存警告（\(SharedLog.memorySummary)）", "Keyboard #\(instance) got a memory warning (\(SharedLog.memorySummary))"))
    }

    // MARK: Recording marker

    private struct Marker: Codable {
        var pid: Int32
        var instance: String
        var request: String
        var startedAt: Date
        var beatAt: Date
        var phase: String
        var footprintMB: Double?
        var availableMB: Double
    }

    /// A recording or processing run is in flight from this keyboard.
    static func recordingBegan(instance: String, requestID: UUID) {
        let now = Date()
        write(Marker(
            pid: pid, instance: instance, request: short(requestID),
            startedAt: now, beatAt: now, phase: "recording",
            footprintMB: SharedLog.footprintMB, availableMB: SharedLog.availableMB
        ))
        heartbeat?.cancel()
        heartbeat = Task { @MainActor in
            var beats = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeatInterval)
                guard !Task.isCancelled, var marker = read() else { return }
                beats += 1
                marker.beatAt = Date()
                marker.footprintMB = SharedLog.footprintMB
                marker.availableMB = SharedLog.availableMB
                write(marker)
                if beats % memoryLogEvery == 0 {
                    log(L(
                        "键盘#\(instance) 录音中 \(Int(Date().timeIntervalSince(marker.startedAt)))s，\(SharedLog.memorySummary)",
                        "Keyboard #\(instance) \(Int(Date().timeIntervalSince(marker.startedAt)))s into the run, \(SharedLog.memorySummary)"
                    ))
                }
            }
        }
    }

    static func phaseChanged(to phase: String) {
        guard var marker = read() else { return }
        marker.phase = phase
        write(marker)
    }

    static func recordingEnded() {
        heartbeat?.cancel()
        heartbeat = nil
        SharedContainer.defaults?.removeObject(forKey: markerKey)
    }

    private static func checkUnfinishedRecording() {
        guard let marker = read() else { return }
        SharedContainer.defaults?.removeObject(forKey: markerKey)
        let since = Int(Date().timeIntervalSince(marker.beatAt))
        let length = Int(marker.beatAt.timeIntervalSince(marker.startedAt))
        let used = marker.footprintMB.map { String(format: "%.1f MB", $0) } ?? "?"
        let left = String(format: "%.1f MB", marker.availableMB)
        if marker.pid == pid {
            log(L(
                "⚠️ 上一个键盘#\(marker.instance) 在\(marker.phase == "processing" ? "处理" : "录音")中被同一进程里的新实例替换（请求 \(marker.request)，已进行 \(length)s）",
                "⚠️ Keyboard #\(marker.instance) was replaced by a new instance in the same process while \(marker.phase) (request \(marker.request), \(length)s in)"
            ))
        } else {
            log(L(
                "⚠️ 上次键盘进程 \(marker.pid) 在\(marker.phase == "processing" ? "处理" : "录音")中意外结束（键盘#\(marker.instance)，请求 \(marker.request)，已进行 \(length)s，最后心跳在 \(since)s 前，当时内存 \(used)，剩余 \(left)）",
                "⚠️ Keyboard process \(marker.pid) ended unexpectedly while \(marker.phase) (keyboard #\(marker.instance), request \(marker.request), \(length)s in, last heartbeat \(since)s ago, memory \(used), \(left) left)"
            ))
        }
    }

    private static func read() -> Marker? {
        guard let data = SharedContainer.defaults?.data(forKey: markerKey) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    private static func write(_ marker: Marker) {
        guard let data = try? JSONEncoder().encode(marker) else { return }
        SharedContainer.defaults?.set(data, forKey: markerKey)
    }
}
