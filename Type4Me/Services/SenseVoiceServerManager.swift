import Foundation
import os

/// Manages the local Qwen3-ASR Python server process.
/// SenseVoice streaming is now handled natively via sherpa-onnx (SenseVoiceASRClient).
actor SenseVoiceServerManager {
    static let shared = SenseVoiceServerManager()

    /// Synchronous kill of all server processes. Safe to call from applicationWillTerminate.
    /// Reads PIDs from disk file, only kills processes we spawned.
    nonisolated static func killAllServerProcesses() {
        if let content = try? String(contentsOf: pidFileURL, encoding: .utf8) {
            for line in content.split(separator: "\n") {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 0 {
                    kill(pid, SIGTERM)
                }
            }
        }
        clearPidFile()
        currentQwen3Port = nil
    }

    /// Write effective hotwords (builtin + user) to hotwords.txt for Qwen3 server.
    nonisolated static func syncHotwordsFile() {
        let words = HotwordStorage.loadEffective()
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Type4Me")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hotwords.txt")
        let content = words.joined(separator: "\n")
        try? content.write(to: path, atomically: true, encoding: .utf8)
        DebugFileLogger.log("Synced \(words.count) hotwords to hotwords.txt")
    }

    /// Sync hotwords and restart Qwen3 server to pick up changes.
    nonisolated static func syncHotwordsAndRestart() {
        syncHotwordsFile()
        Task {
            let mgr = shared
            await mgr.restartForHotwordUpdate()
        }
    }

    /// Port of the running Qwen3-ASR server.
    private static let _portLock = OSAllocatedUnfairLock(initialState: Int?(nil))
    static var currentQwen3Port: Int? {
        get { _portLock.withLock { $0 } }
        set { _portLock.withLock { $0 = newValue } }
    }

    private let logger = Logger(subsystem: "com.type4me.sensevoice", category: "ServerManager")

    private var qwen3Process: Process?
    private(set) var qwen3Port: Int?
    private var qwen3StdoutPipe: Pipe?
    private var qwen3StderrPipe: Pipe?
    private var qwen3CrashRestarts = 0
    private let maxCrashRestarts = 3
    private var qwen3Starting = false
    private var hotwordRestartInFlight = false
    /// Set to true when we intentionally stop the process (prevents crash handler from firing).
    private var intentionalStop = false

    var isRunning: Bool { qwen3Process?.isRunning ?? false }

    var qwen3WSURL: URL? {
        guard let qwen3Port else { return nil }
        return URL(string: "ws://127.0.0.1:\(qwen3Port)/ws")
    }

    /// Called once at app launch. Kills orphans, then starts Qwen3 server.
    func start() async throws {
        killOrphanedServers()
        Self.syncHotwordsFile()

        let qwen3Enabled = UserDefaults.standard.object(forKey: "tf_qwen3FinalEnabled") as? Bool ?? true

        DebugFileLogger.log("start(): q3=\(qwen3Enabled)")

        if qwen3Enabled {
            if qwen3Starting {
                DebugFileLogger.log("start(): Qwen3 start already in progress")
                return
            }
            if let proc = qwen3Process, proc.isRunning, qwen3Port != nil {
                DebugFileLogger.log("start(): Qwen3 already running q3Port=\(qwen3Port ?? -1)")
                return
            }
            qwen3Starting = true
            defer { qwen3Starting = false }
            do {
                try await launchQwen3Server()
            } catch {
                logger.warning("Qwen3-ASR failed to start: \(error)")
                DebugFileLogger.log("Qwen3-ASR launch failed: \(error)")
                throw error
            }
        }

        DebugFileLogger.log("start() done: q3Port=\(Self.currentQwen3Port ?? -1)")
    }

    /// Launch the Qwen3-ASR server (final calibration + LLM).
    private func launchQwen3Server() async throws {
        let proc = Process()
        var args: [String] = []

        try configureQwen3Server(proc: proc, args: &args)

        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let msg = String(data: data, encoding: .utf8) else { return }
            for line in msg.split(separator: "\n") where !line.isEmpty {
                DebugFileLogger.log("qwen3-asr-server: \(line)")
            }
        }
        self.qwen3StdoutPipe = pipe
        self.qwen3StderrPipe = errPipe

        logger.info("Starting Qwen3-ASR server: \(proc.executableURL?.path ?? "?")")

        do {
            try proc.run()
        } catch {
            cleanupQwen3Process(proc, intentional: true, killIfRunning: false)
            logger.error("Failed to start Qwen3-ASR server: \(error)")
            throw ServerError.launchFailed(error)
        }
        self.qwen3Process = proc
        self.intentionalStop = false

        proc.terminationHandler = { [weak self] terminatedProc in
            let status = terminatedProc.terminationStatus
            let pid = terminatedProc.processIdentifier
            Task { await self?.handleQwen3Termination(pid: pid, status: status) }
        }

        let portResult = await readPortFromStdout(pipe: pipe, timeout: 120)
        guard let discoveredPort = portResult else {
            cleanupQwen3Process(proc, intentional: true, killIfRunning: true)
            throw ServerError.portDiscoveryFailed
        }
        self.qwen3Port = discoveredPort
        Self.currentQwen3Port = discoveredPort
        logger.info("Qwen3-ASR server started on port \(discoveredPort)")

        // Health check for Qwen3
        let qwen3HealthURL = URL(string: "http://127.0.0.1:\(discoveredPort)/health")!
        var healthy = false
        for _ in 0..<30 {
            do {
                let (_, response) = try await URLSession.shared.data(from: qwen3HealthURL)
                if (response as? HTTPURLResponse)?.statusCode == 200 { healthy = true; break }
            } catch {}
            try? await Task.sleep(for: .seconds(1))
        }
        if !healthy {
            logger.error("Qwen3-ASR server started but health check failed after 30s")
            DebugFileLogger.log("Qwen3-ASR health check failed — server may be non-functional")
            cleanupQwen3Process(proc, intentional: true, killIfRunning: true)
            throw ServerError.launchFailed(
                NSError(domain: "SenseVoiceServerManager", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Health check failed after server start"])
            )
        }
        savePidsToFile()
    }

    /// Start the Qwen3-ASR server independently.
    func startQwen3() async throws {
        guard qwen3Process == nil, !qwen3Starting else { return }
        qwen3Starting = true
        defer { qwen3Starting = false }
        try await launchQwen3Server()
    }

    /// Stop the Qwen3-ASR server independently (e.g. when user disables verification).
    func stopQwen3() {
        cleanupQwen3Process(intentional: true, killIfRunning: true)
        logger.info("Qwen3-ASR server stopped")
        DebugFileLogger.log("Qwen3-ASR server stopped (user toggle)")
    }

    /// Stop the server.
    func stop() {
        cleanupQwen3Process(intentional: true, killIfRunning: true)
        logger.info("Qwen3-ASR server stopped")
    }

    // MARK: - Crash Handling

    private func cleanupQwen3Process(_ proc: Process? = nil, intentional: Bool, killIfRunning: Bool) {
        if intentional {
            intentionalStop = true
        }

        let processToClean = proc ?? qwen3Process
        if let processToClean, killIfRunning, processToClean.isRunning {
            processToClean.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak processToClean] in
                guard let processToClean, processToClean.isRunning else { return }
                kill(processToClean.processIdentifier, SIGKILL)
            }
        }

        if proc == nil || qwen3Process === proc {
            qwen3Process?.terminationHandler = nil
            qwen3Process = nil
        } else {
            proc?.terminationHandler = nil
        }

        qwen3StdoutPipe?.fileHandleForReading.readabilityHandler = nil
        qwen3StderrPipe?.fileHandleForReading.readabilityHandler = nil
        qwen3StdoutPipe = nil
        qwen3StderrPipe = nil
        qwen3Port = nil
        Self.currentQwen3Port = nil
        savePidsToFile()
    }

    private func handleQwen3Termination(pid: Int32, status: Int32) {
        let current = qwen3Process
        if let current, current.processIdentifier != pid {
            DebugFileLogger.log("Ignored stale Qwen3 termination pid=\(pid)")
            return
        }
        guard !intentionalStop else {
            cleanupQwen3Process(current, intentional: true, killIfRunning: false)
            return
        }
        // Abnormal exit: clear state and optionally restart
        NSLog("[SenseVoiceServerManager] Qwen3 process crashed with exit status %d", status)
        DebugFileLogger.log("Qwen3 process crashed (exit \(status))")
        cleanupQwen3Process(current, intentional: false, killIfRunning: false)

        if qwen3CrashRestarts < maxCrashRestarts {
            qwen3CrashRestarts += 1
            NSLog("[SenseVoiceServerManager] Auto-restarting Qwen3 (attempt %d/%d)", qwen3CrashRestarts, maxCrashRestarts)
            DebugFileLogger.log("Qwen3 auto-restart attempt \(qwen3CrashRestarts)/\(maxCrashRestarts)")
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard !qwen3Starting, qwen3Process == nil else {
                    DebugFileLogger.log("Qwen3 auto-restart skipped: start already in progress or process exists")
                    return
                }
                qwen3Starting = true
                defer { qwen3Starting = false }
                do {
                    try await launchQwen3Server()
                } catch {
                    NSLog("[SenseVoiceServerManager] Qwen3 restart failed: %@", error.localizedDescription)
                    DebugFileLogger.log("Qwen3 restart failed: \(error)")
                }
            }
        } else {
            NSLog("[SenseVoiceServerManager] Qwen3 crash restart limit reached (%d)", maxCrashRestarts)
            DebugFileLogger.log("Qwen3 crash restart limit reached")
        }
    }

    private func restartForHotwordUpdate() async {
        guard qwen3Port != nil || qwen3Process != nil else { return }
        guard !hotwordRestartInFlight else {
            DebugFileLogger.log("Qwen3 hotword restart skipped: already in flight")
            return
        }
        hotwordRestartInFlight = true
        defer { hotwordRestartInFlight = false }

        stop()
        try? await Task.sleep(for: .milliseconds(300))
        do {
            try await start()
            DebugFileLogger.log("Qwen3 server restarted for hotword update")
        } catch {
            DebugFileLogger.log("Qwen3 hotword restart failed: \(error)")
        }
    }

    // MARK: - PID File Management

    private static var pidFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("Type4Me/server-pids.txt")
    }

    /// Save current managed PIDs to disk so we can clean up after a crash.
    private func savePidsToFile() {
        var pids: [String] = []
        if let p = qwen3Process, p.isRunning { pids.append(String(p.processIdentifier)) }
        try? pids.joined(separator: "\n").write(to: Self.pidFileURL, atomically: true, encoding: .utf8)
    }

    private static func clearPidFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// Kill orphaned server processes from previous app runs using saved PID file.
    /// Only kills PIDs we previously spawned, never touches other users' processes.
    /// Verifies the process is actually a Python/qwen3 process before killing to avoid
    /// killing unrelated processes after PID reuse.
    private func killOrphanedServers() {
        guard let content = try? String(contentsOf: Self.pidFileURL, encoding: .utf8) else { return }
        for line in content.split(separator: "\n") {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 0 else { continue }
            // Verify process is still alive before killing
            guard kill(pid, 0) == 0 else { continue }
            // Verify the process is actually a Python/qwen3 process (guard against PID reuse)
            guard isQwen3Process(pid: pid) else {
                DebugFileLogger.log("Skipped orphan PID \(pid): not a qwen3/python process")
                continue
            }
            kill(pid, SIGTERM)
            DebugFileLogger.log("Killed orphaned server PID \(pid)")
        }
        Self.clearPidFile()
    }

    /// Check if a PID belongs to a Python or qwen3-asr-server process.
    private func isQwen3Process(pid: Int32) -> Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/ps")
        check.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        check.standardOutput = pipe
        check.standardError = Pipe()
        do {
            try check.run()
            check.waitUntilExit()
        } catch {
            return false
        }
        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return false
        }
        let comm = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return comm.contains("python") || comm.contains("qwen3")
    }

    /// Check if the Qwen3 server is healthy.
    nonisolated func isHealthy() async -> Bool {
        guard let port = await qwen3Port else { return false }
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Qwen3-ASR

    private func configureQwen3Server(proc: Process, args: inout [String]) throws {
        let serverScript: String
        let executable: String

        // Dev mode: qwen3-asr-server/.venv/bin/python + server.py
        // Production: bundled binary at Contents/MacOS/qwen3-asr-server
        let devDir = findDevServerDir(name: "qwen3-asr-server")
        if let dir = devDir {
            executable = (dir as NSString).appendingPathComponent(".venv/bin/python")
            serverScript = (dir as NSString).appendingPathComponent("server.py")
            guard FileManager.default.fileExists(atPath: executable) else {
                throw ServerError.venvNotFound
            }
        } else {
            let bundledBinary = Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("qwen3-asr-server")
                .path
            guard let bin = bundledBinary, FileManager.default.fileExists(atPath: bin) else {
                throw ServerError.serverNotFound
            }
            executable = bin
            serverScript = ""
        }

        // Model path: bundled or ModelScope cache
        guard let modelPath = resolveQwen3ModelPath() else {
            throw ServerError.modelNotFound
        }
        logger.info("Qwen3-ASR model: \(modelPath)")

        // Hotwords file
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let hotwordsPath = appSupport
            .appendingPathComponent("Type4Me")
            .appendingPathComponent("hotwords.txt")
        let hotwordsFile = FileManager.default.fileExists(atPath: hotwordsPath.path) ? hotwordsPath.path : ""

        proc.executableURL = URL(fileURLWithPath: executable)
        if !serverScript.isEmpty {
            args.append(serverScript)
        }
        args += [
            "--model-path", modelPath,
            "--port", "0",
            "--hotwords-file", hotwordsFile,
        ]
        logger.info("Starting Qwen3-ASR server")
    }

    private func resolveQwen3ModelPath() -> String? {
        // 1. Bundled in app (production DMG)
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Models")
            .appendingPathComponent("Qwen3-ASR")
        if let b = bundled, FileManager.default.fileExists(atPath: b.path) {
            return b.path
        }
        // 2. App Support (user-downloaded)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let userModel = appSupport
            .appendingPathComponent("Type4Me")
            .appendingPathComponent("Models/Qwen3-ASR")
        if FileManager.default.fileExists(atPath: userModel.path) {
            return userModel.path
        }
        // 3. ModelScope cache (dev fallback)
        let cache06 = NSHomeDirectory() + "/.cache/modelscope/hub/models/Qwen/Qwen3-ASR-0.6B"
        if FileManager.default.fileExists(atPath: cache06) { return cache06 }
        let cache17 = NSHomeDirectory() + "/.cache/modelscope/hub/models/Qwen/Qwen3-ASR-1.7B"
        if FileManager.default.fileExists(atPath: cache17) { return cache17 }
        return nil
    }

    // MARK: - Dev server discovery

    private func findDevServerDir(name: String) -> String? {
        // Walk up from binary location to find server directory
        var dir = Bundle.main.bundlePath
        for _ in 0..<5 {
            dir = (dir as NSString).deletingLastPathComponent
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: (candidate as NSString).appendingPathComponent("server.py")) {
                return candidate
            }
        }
        let home = NSHomeDirectory()
        let fallback = (home as NSString).appendingPathComponent("projects/type4me/\(name)")
        if FileManager.default.fileExists(atPath: (fallback as NSString).appendingPathComponent("server.py")) {
            return fallback
        }
        return nil
    }

    private func readPortFromStdout(pipe: Pipe, timeout: Int) async -> Int? {
        return await withCheckedContinuation { continuation in
            let handle = pipe.fileHandleForReading
            let lock = NSLock()
            var resolved = false

            // Read in background
            DispatchQueue.global().async {
                while true {
                    let data = handle.availableData
                    guard !data.isEmpty else { break }
                    if let output = String(data: data, encoding: .utf8) {
                        for line in output.split(separator: "\n") {
                            if line.hasPrefix("PORT:"),
                               let portNum = Int(line.dropFirst(5)) {
                                lock.lock()
                                guard !resolved else { lock.unlock(); return }
                                resolved = true
                                lock.unlock()
                                continuation.resume(returning: portNum)
                                return
                            }
                        }
                    }
                }
                lock.lock()
                guard !resolved else { lock.unlock(); return }
                resolved = true
                lock.unlock()
                continuation.resume(returning: nil)
            }

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                lock.lock()
                guard !resolved else { lock.unlock(); return }
                resolved = true
                lock.unlock()
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Errors

    enum ServerError: Error, LocalizedError {
        case serverNotFound
        case venvNotFound
        case modelNotFound
        case launchFailed(Error)
        case portDiscoveryFailed

        var errorDescription: String? {
            switch self {
            case .serverNotFound:
                return L("Qwen3-ASR 服务未找到", "Qwen3-ASR server not found")
            case .venvNotFound:
                return L("Python 环境未配置", "Python environment not configured")
            case .modelNotFound:
                return L("本地 ASR 模型未找到，请先下载", "Local ASR model not found, please download first")
            case .launchFailed(let e):
                return L("服务启动失败: \(e.localizedDescription)", "Server launch failed: \(e.localizedDescription)")
            case .portDiscoveryFailed:
                return L("服务端口发现失败", "Server port discovery failed")
            }
        }
    }
}
