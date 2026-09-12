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
    private var activeDownloadID: UUID?
    private var resumeData: Data?
    private var currentRelease: UpdateInfo?
    private var retryAttempt = 0
    private var lastDownloadProgress: Double = 0

    private static let maxAutomaticRetryAttempts = 3
    private static let minimumDownloadResourceTimeout: TimeInterval = 2 * 60 * 60
    private static let minimumAssumedBytesPerSecond: Double = 128 * 1024
    private nonisolated static let tooManyOpenFilesCode = 24

    // MARK: - Directories

    private var stagingDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(AppDataLocation.directoryName, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
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
        retryAttempt = 0
        lastDownloadProgress = 0
        resumeData = nil
        let url = release.downloadURL(isLocalInstallation: isLocalInstallation)

        // Ensure staging directory
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        startDownload(url: url, release: release, resetProgress: true)
    }

    func cancelDownload() {
        let cancelledDownloadID = activeDownloadID
        let cancelledVersion = currentRelease?.version
        let task = downloadTask
        let session = downloadSession
        downloadTask = nil
        downloadSession = nil
        activeDownloadID = nil
        state = .idle

        guard let task else {
            session?.invalidateAndCancel()
            return
        }

        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self,
                      self.activeDownloadID == nil,
                      self.currentRelease?.version == cancelledVersion,
                      cancelledDownloadID != nil
                else { return }
                self.resumeData = data
            }
        })
        session?.finishTasksAndInvalidate()
    }

    func retryDownload() {
        guard let release = currentRelease else { return }
        state = .idle
        retryAttempt = 0
        if resumeData != nil {
            startDownload(url: release.downloadURL(isLocalInstallation: isLocalInstallation), release: release, resetProgress: false)
        } else {
            downloadUpdate(release: release)
        }
    }

    func installAndRestart() {
        guard case .readyToInstall = state else { return }
        guard let version = downloadedVersion else { return }

        state = .installing
        let dmgPath = dmgPath(for: version, isLocal: isLocalInstallation)

        guard FileManager.default.fileExists(atPath: dmgPath.path) else {
            state = .failed(L("下载文件不存在", "Downloaded file not found"))
            return
        }

        let targetAppURL = installTargetURL()
        guard canReplaceApp(at: targetAppURL) else {
            state = .failed(L("没有权限替换应用，请手动安装下载的 DMG",
                              "No permission to replace the app. Please install the downloaded DMG manually"))
            return
        }

        let signingIdentity = currentSigningIdentity() ?? "-"
        let scriptURL = stagingDir.appendingPathComponent("updater.sh")

        do {
            let script = generateUpdaterScript(
                dmgPath: dmgPath.path,
                appPath: targetAppURL.path,
                expectedVersion: version,
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
            "APP_PATH": targetAppURL.path,
            "DMG_PATH": dmgPath.path,
            "EXPECTED_VERSION": version,
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
        cleanupDownloadSession(cancel: true)
    }

    // MARK: - Download

    private func dmgPath(for version: String, isLocal: Bool) -> URL {
        let suffix = isLocal ? "local-apple-silicon" : "cloud"
        return stagingDir.appendingPathComponent("Type4Me-v\(version)-\(suffix).dmg")
    }

    private func startDownload(url: URL, release: UpdateInfo, resetProgress: Bool) {
        cleanupDownloadSession(cancel: true)
        let downloadID = UUID()
        activeDownloadID = downloadID
        if resetProgress {
            lastDownloadProgress = 0
        }
        state = .downloading(progress: lastDownloadProgress)

        let delegate = UpdateDownloadDelegate(
            expectedBytes: release.dmgSize(isLocalInstallation: isLocalInstallation),
            onProgress: { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.activeDownloadID == downloadID else { return }
                    let clamped = min(max(fraction, 0), 1)
                    self.lastDownloadProgress = clamped
                    self.state = .downloading(progress: clamped)
                }
            },
            onComplete: { [weak self] fileURL, _, error in
                Task { @MainActor [weak self] in
                    guard let self, self.activeDownloadID == downloadID else { return }
                    self.activeDownloadID = nil
                    self.cleanupDownloadSession(cancel: false)

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
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = downloadResourceTimeout(for: release)
        config.waitsForConnectivity = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.httpMaximumConnectionsPerHost = 2
        config.httpAdditionalHeaders = [
            "Accept": "application/octet-stream,*/*",
            "User-Agent": updaterUserAgent
        ]
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
        if shouldAutomaticallyRetry(nsError),
           retryAttempt < Self.maxAutomaticRetryAttempts,
           let retryVersion = currentRelease?.version {
            retryAttempt += 1
            let scheduledRetryAttempt = retryAttempt
            let delay = retryDelay(for: retryAttempt)
            logger.warning("Update download failed with code \(nsError.code); retrying attempt \(self.retryAttempt) after \(delay, privacy: .public)s")
            state = .downloading(progress: lastDownloadProgress)

            Task { @MainActor [weak self] in
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard let self, let release = self.currentRelease else { return }
                guard case .downloading = self.state else { return }
                guard self.retryAttempt == scheduledRetryAttempt,
                      release.version == retryVersion
                else { return }
                self.startDownload(
                    url: release.downloadURL(isLocalInstallation: self.isLocalInstallation),
                    release: release,
                    resetProgress: false
                )
            }
            return
        }

        let hasResume = resumeData != nil
        let msg = hasResume
            ? L("下载中断，可以继续", "Download interrupted, can resume")
            : Self.downloadFailureMessage(for: nsError, fallback: error.localizedDescription)
        state = .failed(msg)
    }

    private func finalizeDownload(tempURL: URL, release: UpdateInfo) {
        let destination = dmgPath(for: release.version, isLocal: isLocalInstallation)

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
        if let expectedHash = release.dmgSHA256(isLocalInstallation: isLocalInstallation),
           !expectedHash.isEmpty {
            state = .verifying
            let actualHash = sha256(fileAt: destination)
            if actualHash?.lowercased() != expectedHash.lowercased() {
                try? FileManager.default.removeItem(at: destination)
                state = .failed(L("文件校验失败，请重新下载", "File verification failed, please retry"))
                return
            }
        }

        resumeData = nil
        retryAttempt = 0
        state = .readyToInstall
    }

    private var updaterUserAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return "Type4Me-Updater/\(version)"
    }

    private func downloadResourceTimeout(for release: UpdateInfo) -> TimeInterval {
        guard let size = release.dmgSize(isLocalInstallation: isLocalInstallation), size > 0 else {
            return Self.minimumDownloadResourceTimeout
        }
        let estimated = Double(size) / Self.minimumAssumedBytesPerSecond
        return max(Self.minimumDownloadResourceTimeout, estimated)
    }

    private func retryDelay(for attempt: Int) -> TimeInterval {
        min(pow(2, Double(attempt - 1)), 8)
    }

    private func shouldAutomaticallyRetry(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorDataNotAllowed,
                 NSURLErrorCannotLoadFromNetwork:
                return true
            default:
                break
            }
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return shouldAutomaticallyRetry(underlying)
        }
        return false
    }

    nonisolated static func downloadFailureMessage(for error: NSError, fallback: String) -> String {
        if isTooManyOpenFiles(error) {
            return L(
                "系统打开文件过多，请完全退出 Type4Me 后重新打开再试；如果仍失败，请手动下载 DMG 安装",
                "Too many files are open. Quit and reopen Type4Me, then try again; if it still fails, install the DMG manually"
            )
        }

        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut:
                return L("下载超时，请重试", "Download timed out, please retry")
            case NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:
                return L("无法连接下载服务器，请稍后重试", "Could not connect to the download server, please retry later")
            case NSURLErrorNetworkConnectionLost:
                return L("网络中断，请重试", "Network connection was lost, please retry")
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorDataNotAllowed,
                 NSURLErrorCannotLoadFromNetwork:
                return L("网络不可用，请检查连接后重试", "Network is unavailable, please check the connection and retry")
            default:
                break
            }
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return Self.downloadFailureMessage(for: underlying, fallback: fallback)
        }
        return L("下载失败: \(fallback)", "Download failed: \(fallback)")
    }

    private nonisolated static func isTooManyOpenFiles(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain && error.code == tooManyOpenFilesCode {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isTooManyOpenFiles(underlying)
        }
        return false
    }

    private func cleanupDownloadSession(cancel: Bool) {
        if cancel {
            downloadTask?.cancel()
            downloadSession?.invalidateAndCancel()
        } else {
            downloadSession?.finishTasksAndInvalidate()
        }
        downloadTask = nil
        downloadSession = nil
        activeDownloadID = nil
    }

    private func installTargetURL() -> URL {
        let currentURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let path = currentURL.path
        if currentURL.lastPathComponent == "Type4Me-backup.app"
            || path.contains("/Type4Me/Updates/")
            || path.contains("/AppTranslocation/")
            || path.hasPrefix("/Volumes/") {
            return URL(fileURLWithPath: "/Applications/Type4Me.app")
        }
        return currentURL
    }

    private func canReplaceApp(at url: URL) -> Bool {
        let fm = FileManager.default
        let parentPath = url.deletingLastPathComponent().path
        guard fm.isWritableFile(atPath: parentPath) else { return false }

        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue && fm.isDeletableFile(atPath: url.path)
        }
        return true
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
        expectedVersion: String,
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
        echo "Target app path: \(appPath)"
        echo "Expected version: \(expectedVersion)"
        echo "Variant: \(isLocal ? "local" : "cloud")"
        echo "Current signing identity: \(signingIdentity)"

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
        BACKUP_DIR="$STAGING_DIR/rollback"
        BACKUP_PATH="$BACKUP_DIR/Type4Me.app"
        rm -rf "$BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"

        # Rollback on error
        rollback() {
            trap - ERR
            echo "ERROR: Update failed, rolling back..."
            if [ -d "$BACKUP_PATH" ]; then
                rm -rf "$APP_PATH" 2>/dev/null || true
                ditto "$BACKUP_PATH" "$APP_PATH"
                echo "Rolled back to backup."
            fi
            if [ -d "$APP_PATH" ]; then
                open "$APP_PATH" &
            fi
            echo "FAILED"
        }
        trap 'rollback; cleanup_mount' ERR

        if [ -d "$APP_PATH" ]; then
            echo "Backing up $APP_PATH..."
            ditto "$APP_PATH" "$BACKUP_PATH"
        else
            echo "No existing app at target path; installing fresh."
        fi

        # Replace app
        echo "Replacing app bundle..."
        rm -rf "$APP_PATH"
        ditto "$NEW_APP" "$APP_PATH"

        INSTALLED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
        echo "Installed version: $INSTALLED_VERSION"
        if [ "$INSTALLED_VERSION" != "$EXPECTED_VERSION" ]; then
            echo "ERROR: Installed version mismatch"
            exit 1
        fi

        # Keep the notarized app bundle exactly as shipped in the DMG.
        codesign --verify --strict --deep "$APP_PATH"

        # Remove quarantine
        xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

        # Cleanup
        echo "Cleaning up..."
        rm -f "$DMG_PATH"
        rm -rf "$BACKUP_DIR"

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
    let expectedBytes: Int64?
    let onProgress: @Sendable (Double) -> Void
    let onComplete: @Sendable (URL?, URLResponse?, Error?) -> Void
    private var completedURL: URL?

    init(
        expectedBytes: Int64?,
        onProgress: @escaping @Sendable (Double) -> Void,
        onComplete: @escaping @Sendable (URL?, URLResponse?, Error?) -> Void
    ) {
        self.expectedBytes = expectedBytes
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
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (expectedBytes ?? 0)
        guard expected > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(expected)
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
