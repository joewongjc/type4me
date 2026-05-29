import AppKit
import CommonCrypto
import os

// MARK: - App Updater

@Observable @MainActor
final class AppUpdater {

    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case verifying
        case readyToInstall
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var downloadedVersion: String?

    /// Detected once at init
    let isLocalInstallation: Bool

    private let logger = Logger(subsystem: "com.type4me", category: "AppUpdater")
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var resumeData: Data?
    private var currentRelease: UpdateInfo?

    // MARK: - Directories

    private var stagingDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Type4Me/Updates")
    }

    private var updateLogURL: URL { stagingDir.appendingPathComponent("update.log") }

    // MARK: - Init

    init() {
        let resourcesURL = Bundle.main.resourceURL
        isLocalInstallation = FileManager.default.fileExists(
            atPath: resourcesURL?.appendingPathComponent("qwen3-asr-server-dist").path ?? ""
        )
    }

    // MARK: - Public API

    func downloadUpdate(release: UpdateInfo) {
        switch state {
        case .idle, .failed: break
        default: return
        }

        currentRelease = release
        downloadedVersion = release.version
        let url = release.resolvedDmgURL

        // Ensure staging directory
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        startDownload(url: url, release: release)
    }

    func cancelDownload() {
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                self?.resumeData = data
            }
        })
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        downloadTask = nil
        state = .idle
    }

    func retryDownload() {
        guard let release = currentRelease else { return }
        state = .idle
        if resumeData != nil {
            startDownload(url: release.resolvedDmgURL, release: release)
        } else {
            downloadUpdate(release: release)
        }
    }

    func installAndRestart() {
        guard case .readyToInstall = state else { return }
        guard let version = downloadedVersion else { return }

        state = .installing
        let dmgPath = dmgPath(for: version)

        guard FileManager.default.fileExists(atPath: dmgPath.path) else {
            state = .failed(L("下载文件不存在", "Downloaded file not found"))
            return
        }

        let signingIdentity = currentSigningIdentity() ?? "-"
        let scriptURL = stagingDir.appendingPathComponent("updater.sh")

        do {
            let script = generateUpdaterScript(
                dmgPath: dmgPath.path,
                appPath: Bundle.main.bundlePath,
                signingIdentity: signingIdentity,
                isLocal: isLocalInstallation,
                stagingDir: stagingDir.path
            )
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
            )
        } catch {
            state = .failed(L("无法生成更新脚本: \(error.localizedDescription)",
                              "Failed to generate update script: \(error.localizedDescription)"))
            return
        }

        // Kill ASR servers before quitting
        SenseVoiceServerManager.killAllServerProcesses()

        // Launch updater script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.environment = [
            "APP_PID": "\(ProcessInfo.processInfo.processIdentifier)",
            "APP_PATH": Bundle.main.bundlePath,
            "DMG_PATH": dmgPath.path,
            "SIGNING_IDENTITY": signingIdentity,
            "IS_LOCAL": isLocalInstallation ? "1" : "0",
            "STAGING_DIR": stagingDir.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        process.qualityOfService = .utility

        do {
            try process.run()
            logger.info("Updater script launched, PID=\(process.processIdentifier)")
        } catch {
            state = .failed(L("无法启动更新脚本: \(error.localizedDescription)",
                              "Failed to launch update script: \(error.localizedDescription)"))
            return
        }

        // Quit the app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Check post-update status on launch (called from AppDelegate).
    func checkPostUpdateStatus() {
        guard FileManager.default.fileExists(atPath: updateLogURL.path) else { return }
        defer { cleanupStaging() }

        guard let log = try? String(contentsOf: updateLogURL, encoding: .utf8) else { return }
        if log.contains("SUCCESS") {
            logger.info("Post-update check: update succeeded")
        } else if log.contains("FAILED") {
            logger.error("Post-update check: update failed, see log")
        }
    }

    func reset() {
        state = .idle
        downloadedVersion = nil
        currentRelease = nil
        resumeData = nil
    }

    // MARK: - Download

    private func dmgPath(for version: String) -> URL {
        stagingDir.appendingPathComponent("Type4Me-v\(version)-cloud.dmg")
    }

    private func startDownload(url: URL, release: UpdateInfo) {
        state = .downloading(progress: 0)

        let delegate = UpdateDownloadDelegate(
            onProgress: { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.state = .downloading(progress: fraction)
                }
            },
            onComplete: { [weak self] fileURL, _, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        self.handleDownloadError(error)
                        return
                    }
                    guard let fileURL else {
                        self.state = .failed(L("下载失败", "Download failed"))
                        return
                    }
                    self.finalizeDownload(tempURL: fileURL, release: release)
                }
            }
        )

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.downloadSession = session

        if let resumeData {
            self.resumeData = nil
            downloadTask = session.downloadTask(withResumeData: resumeData)
        } else {
            downloadTask = session.downloadTask(with: url)
        }
        downloadTask?.resume()
    }

    private func handleDownloadError(_ error: Error) {
        let nsError = error as NSError
        // Capture resume data for retry
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData = data
        }
        // Also check underlying error
        if resumeData == nil,
           let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           let data = underlying.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData = data
        }

        if nsError.code == NSURLErrorCancelled { return } // User cancelled
        let hasResume = resumeData != nil
        let msg = hasResume
            ? L("下载中断，可以继续", "Download interrupted, can resume")
            : L("下载失败: \(error.localizedDescription)", "Download failed: \(error.localizedDescription)")
        state = .failed(msg)
    }

    private func finalizeDownload(tempURL: URL, release: UpdateInfo) {
        let destination = dmgPath(for: release.version)

        // Move downloaded file to staging
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            state = .failed(L("无法保存下载文件: \(error.localizedDescription)",
                              "Failed to save download: \(error.localizedDescription)"))
            return
        }

        // SHA256 verification
        if let expectedHash = release.cloudDmgSHA256, !expectedHash.isEmpty {
            state = .verifying
            let actualHash = sha256(fileAt: destination)
            if actualHash?.lowercased() != expectedHash.lowercased() {
                try? FileManager.default.removeItem(at: destination)
                state = .failed(L("文件校验失败，请重新下载", "File verification failed, please retry"))
                return
            }
        }

        resumeData = nil
        state = .readyToInstall
    }

    // MARK: - Signing Identity

    private func currentSigningIdentity() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dvvv", Bundle.main.bundlePath]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("Authority=") {
                return String(line.dropFirst("Authority=".count))
            }
        }
        return nil
    }

    // MARK: - SHA256

    private func sha256(fileAt url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                CC_SHA256_Update(&context, buffer, CC_LONG(read))
            }
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Updater Script

    private func generateUpdaterScript(
        dmgPath: String,
        appPath: String,
        signingIdentity: String,
        isLocal: Bool,
        stagingDir: String
    ) -> String {
        """
        #!/bin/bash
        set -euo pipefail
        LOG="\(stagingDir)/update.log"
        exec > "$LOG" 2>&1
        echo "Type4Me updater started at $(date)"

        # Wait for app to exit
        while kill -0 "$APP_PID" 2>/dev/null; do sleep 0.2; done
        sleep 0.5
        echo "App exited."

        # Mount DMG
        echo "Mounting DMG..."
        MOUNT_OUTPUT=$(hdiutil attach -nobrowse -noverify -mountrandom /tmp "$DMG_PATH" 2>&1)
        MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | grep '/tmp/' | awk '{print $NF}')
        echo "Mounted at $MOUNT_POINT"

        cleanup_mount() {
            hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
        }
        trap cleanup_mount EXIT

        # Find .app in DMG
        NEW_APP=$(find "$MOUNT_POINT" -maxdepth 1 -name "*.app" -type d | head -1)
        if [ -z "$NEW_APP" ] || [ ! -d "$NEW_APP" ]; then
            echo "ERROR: Type4Me.app not found in DMG"
            exit 1
        fi
        echo "Found: $NEW_APP"

        # Backup current app
        BACKUP_PATH="$STAGING_DIR/Type4Me-backup.app"
        rm -rf "$BACKUP_PATH"
        echo "Backing up $APP_PATH..."
        cp -R "$APP_PATH" "$BACKUP_PATH"

        # Rollback on error
        rollback() {
            echo "ERROR: Update failed, rolling back..."
            if [ -d "$BACKUP_PATH" ]; then
                rm -rf "$APP_PATH" 2>/dev/null || true
                mv "$BACKUP_PATH" "$APP_PATH"
                echo "Rolled back to backup."
            fi
            open "$APP_PATH" &
            echo "FAILED"
        }
        trap 'rollback; cleanup_mount' ERR

        # Preserve local components (server dists + models)
        TEMP_LOCAL=""
        if [ "$IS_LOCAL" = "1" ]; then
            TEMP_LOCAL="$(mktemp -d)"
            echo "Preserving local components to $TEMP_LOCAL..."
            [ -d "$APP_PATH/Contents/Resources/qwen3-asr-server-dist" ] && mv "$APP_PATH/Contents/Resources/qwen3-asr-server-dist" "$TEMP_LOCAL/"
            [ -f "$APP_PATH/Contents/MacOS/qwen3-asr-server" ] && mv "$APP_PATH/Contents/MacOS/qwen3-asr-server" "$TEMP_LOCAL/"
            [ -d "$APP_PATH/Contents/Resources/Models" ] && mv "$APP_PATH/Contents/Resources/Models" "$TEMP_LOCAL/"
        fi

        # Replace app
        echo "Replacing app bundle..."
        rm -rf "$APP_PATH"
        cp -R "$NEW_APP" "$APP_PATH"

        # Restore local components
        if [ "$IS_LOCAL" = "1" ] && [ -n "$TEMP_LOCAL" ] && [ -d "$TEMP_LOCAL" ]; then
            echo "Restoring local components..."
            [ -d "$TEMP_LOCAL/qwen3-asr-server-dist" ] && mv "$TEMP_LOCAL/qwen3-asr-server-dist" "$APP_PATH/Contents/Resources/"
            [ -f "$TEMP_LOCAL/qwen3-asr-server" ] && mv "$TEMP_LOCAL/qwen3-asr-server" "$APP_PATH/Contents/MacOS/"
            [ -d "$TEMP_LOCAL/Models" ] && mv "$TEMP_LOCAL/Models" "$APP_PATH/Contents/Resources/"
            rm -rf "$TEMP_LOCAL"
        fi

        # Skip re-signing: the DMG contains a properly notarized app.
        # Re-signing would strip the original signature and may trigger
        # Gatekeeper issues. The restored local files in Contents/Resources/
        # don't invalidate the seal since they're outside Contents/MacOS/.

        # Remove quarantine
        xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

        # Cleanup
        echo "Cleaning up..."
        rm -f "$DMG_PATH"
        rm -rf "$BACKUP_PATH"

        # Relaunch
        echo "Relaunching..."
        open "$APP_PATH" &

        echo "Update completed successfully at $(date)"
        echo "SUCCESS"
        """
    }

    // MARK: - Cleanup

    private func cleanupStaging() {
        try? FileManager.default.removeItem(at: stagingDir)
    }
}

// MARK: - Download Delegate

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    let onComplete: @Sendable (URL?, URLResponse?, Error?) -> Void
    private var completedURL: URL?

    init(
        onProgress: @escaping @Sendable (Double) -> Void,
        onComplete: @escaping @Sendable (URL?, URLResponse?, Error?) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dmg")
        try? FileManager.default.copyItem(at: location, to: temp)
        completedURL = temp
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            onComplete(nil, nil, error)
        } else {
            onComplete(completedURL, task.response, nil)
        }
    }
}
