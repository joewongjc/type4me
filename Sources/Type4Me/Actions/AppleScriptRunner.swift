import Foundation

enum AppleScriptError: Error, LocalizedError {
    case nonZeroExit(code: Int32, stderr: String)
    case timeout
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(let code, let stderr):
            return L("操作退出（\(code)）：\(stderr)", "Process exited \(code): \(stderr)")
        case .timeout:
            return L("操作超时", "Action timed out")
        case .launchFailed(let msg):
            return L("无法启动操作：\(msg)", "Failed to launch process: \(msg)")
        }
    }
}

/// Subprocess helper for running AppleScript and shell commands invoked by Mac actions.
///
/// IMPORTANT: shell commands here are only constructed by curated, in-app action
/// implementations. The LLM never supplies a raw shell string — it can only
/// pick a registered action and supply structured JSON args.
enum AppleScriptRunner {

    /// Run an AppleScript snippet via `osascript -e <script>` and return stdout.
    static func runScript(_ script: String, timeoutSeconds: TimeInterval = 10) async throws -> String {
        try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script],
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Run a shell command via `/bin/sh -c <command>` and return stdout.
    static func runShell(_ command: String, timeoutSeconds: TimeInterval = 10) async throws -> String {
        try await runProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AppleScriptError.launchFailed(error.localizedDescription)
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if process.isRunning {
                process.terminate()
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                timeoutTask.cancel()
                let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    let trimmedErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: AppleScriptError.nonZeroExit(
                            code: proc.terminationStatus,
                            stderr: trimmedErr.isEmpty ? stdout : trimmedErr
                        )
                    )
                }
            }
        }
    }

    /// Escapes a string for safe inclusion inside an AppleScript double-quoted literal.
    static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
