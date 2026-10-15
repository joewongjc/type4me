import Foundation
import os

protocol MagpieHeldLock: Sendable {
    func release()
}

protocol MagpieAgentWriteLockProviding: Sendable {
    func acquire(timeout: Duration) throws -> any MagpieHeldLock
}

final class MagpieAgentWriteLock: MagpieAgentWriteLockProviding, @unchecked Sendable {
    static let shared = MagpieAgentWriteLock()

    private let lockFileURL: URL

    init(lockFileURL: URL = MagpieAgentFile.defaultURL.deletingLastPathComponent().appendingPathComponent("magpie-agent.json.lock")) {
        self.lockFileURL = lockFileURL
    }

    final class Held: MagpieHeldLock, @unchecked Sendable {
        private var fd: Int32?

        init(fd: Int32) {
            self.fd = fd
        }

        func release() {
            guard let descriptor = fd else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            fd = nil
        }

        deinit {
            release()
        }
    }

    func acquire(timeout: Duration = .seconds(6)) throws -> any MagpieHeldLock {
        let dir = lockFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = lockFileURL.path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw MagpieAgentModelWriter.Failure.io("Cannot open lock file: \(path)")
        }

        let start = ContinuousClock.now
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return Held(fd: fd)
            }
            let elapsed = ContinuousClock.now - start
            if elapsed >= timeout {
                close(fd)
                throw MagpieAgentModelWriter.Failure.busy
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

protocol MagpieCommandRunner: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> Int32
}

final class DefaultMagpieCommandRunner: MagpieCommandRunner, Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        return await withCheckedContinuation { continuation in
            let checkInterval: TimeInterval = 0.05
            let startTime = Date()

            Task.detached {
                while process.isRunning {
                    if Date().timeIntervalSince(startTime) >= timeout {
                        process.terminate()
                        process.waitUntilExit()
                        continuation.resume(returning: process.terminationStatus)
                        return
                    }
                    try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                }
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }
}

actor MagpieReconciler {
    static let shared = MagpieReconciler()

    private let runner: any MagpieCommandRunner
    private let lockProvider: any MagpieAgentWriteLockProviding
    private var isRunning = false
    private var pendingModel: String?

    init(
        runner: any MagpieCommandRunner = DefaultMagpieCommandRunner(),
        lock: any MagpieAgentWriteLockProviding = MagpieAgentWriteLock.shared
    ) {
        self.runner = runner
        self.lockProvider = lock
    }

    func reconcile(model: String, fileURL: URL = MagpieAgentFile.defaultURL) async {
        if isRunning {
            pendingModel = model
            return
        }

        isRunning = true
        var target = model
        while true {
            await performReconcile(targetModel: target, fileURL: fileURL)
            if let next = pendingModel {
                pendingModel = nil
                target = next
            } else {
                break
            }
        }
        isRunning = false
    }

    private func performReconcile(targetModel: String, fileURL: URL) async {
        guard let cli = MagpieInstallation.cliURL() else {
            NSLog("[MagpieReconciler] Magpie CLI not found; skipping reconcile")
            return
        }

        let lock: any MagpieHeldLock
        do {
            lock = try lockProvider.acquire(timeout: .seconds(6))
        } catch {
            NSLog("[MagpieReconciler] Lock acquisition failed: %@", error.localizedDescription)
            return
        }
        defer { lock.release() }

        MagpieAgentFile.clearCache()
        guard case .managed(let current) = MagpieAgentFile.load(from: fileURL),
              current.model == targetModel
        else {
            NSLog("[MagpieReconciler] File model no longer matches target %@; skipping reconcile", targetModel)
            return
        }

        let start = Date()
        do {
            let status = try await runner.run(
                executable: cli,
                arguments: ["type4me", "magpie/\(targetModel)"],
                timeout: 5.0
            )
            let duration = Date().timeIntervalSince(start)
            NSLog("[MagpieReconciler] Reconciled model %@, exit=%d, duration=%.2fs", targetModel, status, duration)
        } catch {
            NSLog("[MagpieReconciler] Reconcile execution error: %@", error.localizedDescription)
        }

        MagpieAgentFile.clearCache()
        _ = MagpieAgentFile.load(from: fileURL)
    }
}

enum MagpieAgentModelWriter {
    enum Failure: Error, Equatable {
        case notManaged
        case notInCatalog
        case busy
        case verifyFailed
        case io(String)
    }

    static func writeModel(
        _ model: String,
        to url: URL = MagpieAgentFile.defaultURL,
        lockProvider: any MagpieAgentWriteLockProviding = MagpieAgentWriteLock.shared
    ) throws {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Failure.notInCatalog
        }

        if !MagpieModelCatalog.isModelAllowed(trimmed) {
            throw Failure.notInCatalog
        }

        let lock = try lockProvider.acquire(timeout: .seconds(6))
        defer { lock.release() }

        MagpieAgentFile.clearCache()
        guard case .managed = MagpieAgentFile.load(from: url) else {
            throw Failure.notManaged
        }

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              var dict = json as? [String: Any]
        else {
            throw Failure.io("Unable to read agent file at \(url.path)")
        }

        dict["model"] = trimmed

        let newData: Data
        do {
            newData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .withoutEscapingSlashes])
        } catch {
            throw Failure.io("Serialization failed: \(error.localizedDescription)")
        }

        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".magpie-agent-\(UUID().uuidString).tmp")
        do {
            try newData.write(to: tempURL, options: .atomic)
            if let perms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber {
                try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: tempURL.path)
            }
            if rename(tempURL.path, url.path) != 0 {
                throw Failure.io("Failed to rename temporary file to target")
            }
        } catch let err as Failure {
            try? FileManager.default.removeItem(at: tempURL)
            throw err
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw Failure.io("Write error: \(error.localizedDescription)")
        }

        MagpieAgentFile.clearCache()
        guard case .managed(let reloaded) = MagpieAgentFile.load(from: url),
              reloaded.model == trimmed
        else {
            throw Failure.verifyFailed
        }

        reconcileWithMagpie(model: trimmed)
    }

    static func reconcileWithMagpie(model: String) {
        Task.detached {
            await MagpieReconciler.shared.reconcile(model: model)
        }
    }
}
