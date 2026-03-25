import Foundation
import os

/// Manages downloading, verifying, and locating SherpaOnnx model files.
actor ModelManager {

    static let shared = ModelManager()

    private let logger = Logger(subsystem: "com.type4me.models", category: "ModelManager")

    // MARK: - Paths

    static var defaultModelsDir: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Type4Me", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .path
    }

    private var modelsDir: String { Self.defaultModelsDir }

    // MARK: - Model Architecture

    enum ModelArchitecture: String, Sendable {
        case paraformer
        case ctc
    }

    // MARK: - Streaming Model Variants

    enum StreamingModel: String, CaseIterable, Sendable {
        case zipformerSmallCtc    = "zipformer-small-ctc"
        case zipformerCtcMulti    = "zipformer-ctc-multi"
        case paraformerBilingual  = "paraformer-bilingual"

        var displayName: String {
            switch self {
            case .zipformerSmallCtc:   return L("极速轻量", "Ultra Light")
            case .zipformerCtcMulti:   return L("均衡推荐", "Balanced")
            case .paraformerBilingual: return L("中英双语", "Bilingual")
            }
        }

        var description: String {
            switch self {
            case .zipformerSmallCtc:
                return L("最小模型，适合快速输入，精度一般",
                         "Smallest model, fast input, moderate accuracy")
            case .zipformerCtcMulti:
                return L("14000小时训练，精度与大小的最佳平衡",
                         "14k hours training, best accuracy/size balance")
            case .paraformerBilingual:
                return L("精度最高，支持中英文混合识别",
                         "Highest accuracy, Chinese + English mixed recognition")
            }
        }

        var architecture: ModelArchitecture {
            switch self {
            case .zipformerSmallCtc, .zipformerCtcMulti: return .ctc
            case .paraformerBilingual: return .paraformer
            }
        }

        var directoryName: String {
            switch self {
            case .zipformerSmallCtc:   return "sherpa-onnx-streaming-zipformer-small-ctc-zh-int8-2025-04-01"
            case .zipformerCtcMulti:   return "sherpa-onnx-streaming-zipformer-ctc-multi-zh-hans-2023-12-13"
            case .paraformerBilingual: return "sherpa-onnx-streaming-paraformer-bilingual-zh-en"
            }
        }

        var downloadURL: URL {
            let base = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
            return URL(string: base + directoryName + ".tar.bz2")!
        }

        var requiredFiles: [String] {
            switch self {
            case .zipformerSmallCtc:
                return ["model.int8.onnx", "tokens.txt"]
            case .zipformerCtcMulti:
                return ["ctc-epoch-20-avg-1-chunk-16-left-128.onnx", "tokens.txt"]
            case .paraformerBilingual:
                return ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"]
            }
        }

        /// The primary model file used by the recognizer.
        var modelFileName: String {
            switch self {
            case .zipformerSmallCtc:   return "model.int8.onnx"
            case .zipformerCtcMulti:   return "ctc-epoch-20-avg-1-chunk-16-left-128.onnx"
            case .paraformerBilingual: return "encoder.int8.onnx"  // uses encoder+decoder
            }
        }

        /// Approximate download size in MB for UI display.
        var approximateSizeMB: Int {
            switch self {
            case .zipformerSmallCtc:   return 20
            case .zipformerCtcMulti:   return 236
            case .paraformerBilingual: return 1000
            }
        }
    }

    // MARK: - Auxiliary Model Types (punctuation, offline, etc.)

    enum AuxModelType: String, CaseIterable, Sendable {
        case offlineParaformer = "offline-paraformer"
        case punctuation       = "punctuation"

        var displayName: String {
            switch self {
            case .offlineParaformer: return L("离线识别模型", "Offline ASR")
            case .punctuation:       return L("标点恢复模型", "Punctuation")
            }
        }

        var directoryName: String {
            switch self {
            case .offlineParaformer: return "sherpa-onnx-paraformer-zh-2023-09-14"
            case .punctuation:       return "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12"
            }
        }

        var downloadURL: URL {
            let base: String
            switch self {
            case .offlineParaformer:
                base = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
            case .punctuation:
                base = "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/"
            }
            return URL(string: base + directoryName + ".tar.bz2")!
        }

        var requiredFiles: [String] {
            switch self {
            case .offlineParaformer: return ["model.int8.onnx", "tokens.txt"]
            case .punctuation:       return ["model.onnx"]
            }
        }

        var approximateSizeMB: Int {
            switch self {
            case .offlineParaformer: return 700
            case .punctuation:       return 72
            }
        }
    }

    // MARK: - Selected Model (persisted)

    private static let selectedModelKey = "tf_selectedStreamingModel"

    nonisolated static var selectedStreamingModel: StreamingModel {
        get {
            if let raw = UserDefaults.standard.string(forKey: selectedModelKey),
               let model = StreamingModel(rawValue: raw) {
                return model
            }
            return .zipformerCtcMulti  // default
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedModelKey)
        }
    }

    // MARK: - Model Status

    enum ModelStatus: Sendable, Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case invalid
    }

    /// Current download progress keyed by directory name.
    private var downloadProgress: [String: Double] = [:]

    /// Active download tasks keyed by directory name.
    private var activeTasks: [String: Task<Void, Error>] = [:]

    /// Active URLSessions keyed by directory name (for real cancellation).
    private var activeSessions: [String: URLSession] = [:]

    /// Resume data from failed downloads, keyed by directory name.
    private var resumeData: [String: Data] = [:]

    /// Max auto-retry attempts for large downloads.
    private let maxRetries = 20

    // MARK: - Query (Streaming Models)

    nonisolated func isModelAvailable(_ model: StreamingModel) -> Bool {
        checkFiles(dir: model.directoryName, files: model.requiredFiles)
    }

    nonisolated func isSelectedModelAvailable() -> Bool {
        isModelAvailable(Self.selectedStreamingModel)
    }

    /// Legacy compatibility — used by RecognitionSession.
    nonisolated func areRequiredModelsAvailable() -> Bool {
        isSelectedModelAvailable()
    }

    func status(for model: StreamingModel) -> ModelStatus {
        let key = model.directoryName
        if let progress = downloadProgress[key], progress < 1.0 {
            return .downloading(progress: progress)
        }
        if isModelAvailable(model) { return .downloaded }
        return .notDownloaded
    }

    nonisolated func modelPath(for model: StreamingModel) -> String? {
        guard isModelAvailable(model) else { return nil }
        return (Self.defaultModelsDir as NSString).appendingPathComponent(model.directoryName)
    }

    // MARK: - Query (Auxiliary Models)

    nonisolated func isModelAvailable(_ aux: AuxModelType) -> Bool {
        checkFiles(dir: aux.directoryName, files: aux.requiredFiles)
    }

    nonisolated func modelPath(for aux: AuxModelType) -> String? {
        guard isModelAvailable(aux) else { return nil }
        return (Self.defaultModelsDir as NSString).appendingPathComponent(aux.directoryName)
    }

    // MARK: - Backward Compat (old ModelType references)

    /// Old ModelType kept for punctuation checks in existing code.
    enum ModelType: String, CaseIterable, Sendable {
        case onlineParaformer  = "online-paraformer"
        case offlineParaformer = "offline-paraformer"
        case punctuation       = "punctuation"

        var displayName: String {
            switch self {
            case .onlineParaformer:  return "Streaming ASR"
            case .offlineParaformer: return "Offline ASR"
            case .punctuation:       return "Punctuation"
            }
        }
    }

    /// Legacy: check punctuation model availability.
    nonisolated func isModelAvailable(_ type: ModelType) -> Bool {
        switch type {
        case .punctuation:       return isModelAvailable(AuxModelType.punctuation)
        case .offlineParaformer: return isModelAvailable(AuxModelType.offlineParaformer)
        case .onlineParaformer:  return isSelectedModelAvailable()
        }
    }

    // MARK: - Download (Streaming Model)

    func downloadModel(
        _ model: StreamingModel,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await downloadGeneric(
            key: model.directoryName,
            url: model.downloadURL,
            requiredFiles: model.requiredFiles,
            onProgress: onProgress
        )
    }

    func cancelDownload(_ model: StreamingModel) {
        cancelGeneric(key: model.directoryName)
    }

    func deleteModel(_ model: StreamingModel) throws {
        try deleteGeneric(key: model.directoryName)
    }

    // MARK: - Download (Auxiliary)

    func downloadModel(
        _ aux: AuxModelType,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await downloadGeneric(
            key: aux.directoryName,
            url: aux.downloadURL,
            requiredFiles: aux.requiredFiles,
            onProgress: onProgress
        )
    }

    func cancelDownload(_ aux: AuxModelType) {
        cancelGeneric(key: aux.directoryName)
    }

    func deleteModel(_ aux: AuxModelType) throws {
        try deleteGeneric(key: aux.directoryName)
    }

    // Legacy overload for old code using ModelType
    func cancelDownload(_ type: ModelType) {
        switch type {
        case .punctuation:       cancelDownload(AuxModelType.punctuation)
        case .offlineParaformer: cancelDownload(AuxModelType.offlineParaformer)
        case .onlineParaformer:  cancelDownload(Self.selectedStreamingModel)
        }
    }

    func deleteModel(_ type: ModelType) throws {
        switch type {
        case .punctuation:       try deleteModel(AuxModelType.punctuation)
        case .offlineParaformer: try deleteModel(AuxModelType.offlineParaformer)
        case .onlineParaformer:  try deleteModel(Self.selectedStreamingModel)
        }
    }

    // MARK: - Generic Download

    private func downloadGeneric(
        key: String,
        url: URL,
        requiredFiles: [String],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Cancel any existing download task but keep resume data for continuation
        cancelGeneric(key: key, clearResumeData: false)

        let destDir = (modelsDir as NSString).appendingPathComponent(key)
        logger.info("Starting download: \(key) from \(url.absoluteString)")
        downloadProgress[key] = 0
        onProgress(0)

        try FileManager.default.createDirectory(
            atPath: modelsDir,
            withIntermediateDirectories: true
        )

        let task = Task {
            let tempFile = try await downloadWithProgress(
                url: url,
                key: key,
                onProgress: { [weak self] progress in
                    Task { await self?.setProgress(key, progress) }
                    onProgress(progress)
                }
            )

            try Task.checkCancellation()

            logger.info("Extracting \(key) to \(self.modelsDir)")
            onProgress(0.95)
            try await extractTarBz2(tempFile, to: modelsDir)
            try? FileManager.default.removeItem(at: tempFile)

            guard checkFiles(dir: key, files: requiredFiles) else {
                logger.error("Model validation failed: \(key)")
                throw ModelError.extractionFailed
            }

            setProgress(key, 1.0)
            onProgress(1.0)
            logger.info("Model \(key) ready at \(destDir)")
        }

        activeTasks[key] = task
        try await task.value
        activeTasks[key] = nil
        activeSessions[key] = nil
    }

    private func cancelGeneric(key: String, clearResumeData: Bool = true) {
        activeTasks[key]?.cancel()
        activeTasks[key] = nil
        activeSessions[key]?.invalidateAndCancel()
        activeSessions[key] = nil
        downloadProgress[key] = nil
        if clearResumeData {
            resumeData[key] = nil
        }
    }

    private func deleteGeneric(key: String) throws {
        let dir = (modelsDir as NSString).appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.removeItem(atPath: dir)
            logger.info("Deleted model: \(key)")
        }
        downloadProgress[key] = nil
    }

    // MARK: - Internal Helpers

    private nonisolated func checkFiles(dir: String, files: [String]) -> Bool {
        let fullDir = (Self.defaultModelsDir as NSString).appendingPathComponent(dir)
        let fm = FileManager.default
        return files.allSatisfy { file in
            fm.fileExists(atPath: (fullDir as NSString).appendingPathComponent(file))
        }
    }

    private func setProgress(_ key: String, _ value: Double) {
        downloadProgress[key] = value
    }

    private func downloadWithProgress(
        url: URL,
        key: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                try Task.checkCancellation()

                if attempt > 0 {
                    // Exponential backoff: 3, 5, 8, 10, 10, ...
                    let delay = min(3.0 + 2.0 * Double(attempt - 1), 10.0)
                    logger.info("Retry \(attempt)/\(self.maxRetries) for \(key) in \(delay)s")
                    try await Task.sleep(for: .seconds(delay))
                    try Task.checkCancellation()
                }

                let existingResumeData = resumeData[key]
                let (tempURL, response) = try await downloadFile(
                    url: url,
                    key: key,
                    existingResumeData: existingResumeData,
                    onProgress: onProgress
                )

                // Success — clear resume data
                resumeData[key] = nil

                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw ModelError.downloadFailed(url)
                }

                return tempURL
            } catch {
                lastError = error

                if Task.isCancelled { throw error }

                // Check for resume data in the error
                let nsError = error as NSError
                if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    resumeData[key] = data
                    logger.info("Download interrupted for \(key), got resume data (\(data.count) bytes), will retry")
                    continue
                }

                // Also check underlying error
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
                   let data = underlying.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    resumeData[key] = data
                    logger.info("Download interrupted for \(key), got resume data from underlying error, will retry")
                    continue
                }

                // For network errors without resume data, still retry (just from scratch)
                let code = nsError.code
                let retryableCodes: Set<Int> = [
                    NSURLErrorTimedOut,                  // -1001
                    NSURLErrorCannotConnectToHost,       // -1004
                    NSURLErrorNetworkConnectionLost,     // -1005
                    NSURLErrorNotConnectedToInternet,    // -1009
                    NSURLErrorSecureConnectionFailed,    // -1200
                ]
                if nsError.domain == NSURLErrorDomain, retryableCodes.contains(code) {
                    logger.info("Download failed for \(key) (retryable error \(code)), will retry from scratch")
                    continue
                }

                // Non-retryable error — throw immediately
                logger.error("Download failed for \(key) (non-retryable): \(error)")
                throw error
            }
        }

        throw lastError ?? ModelError.downloadFailed(url)
    }

    private func downloadFile(
        url: URL,
        key: String,
        existingResumeData: Data?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let delegate = DownloadProgressDelegate(
                onProgress: { fraction in
                    onProgress(fraction * 0.9)
                },
                onComplete: { location, response, error in
                    guard !resumed else { return }
                    resumed = true
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let location, let response else {
                        continuation.resume(throwing: ModelError.extractionFailed)
                        return
                    }
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + ".tar.bz2")
                    do {
                        try FileManager.default.moveItem(at: location, to: dest)
                        continuation.resume(returning: (dest, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            )
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300       // 5 min per chunk
            config.timeoutIntervalForResource = 7200     // 2 hours total
            config.waitsForConnectivity = true
            config.httpMaximumConnectionsPerHost = 1
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            Task { await self.storeSession(session, forKey: key) }

            // Resume from previous partial download if available
            if let data = existingResumeData {
                logger.info("Resuming download for \(key) with \(data.count) bytes of resume data")
                session.downloadTask(withResumeData: data).resume()
            } else {
                session.downloadTask(with: URLRequest(url: url)).resume()
            }
        }
    }

    private func storeSession(_ session: URLSession, forKey key: String) {
        activeSessions[key] = session
    }

    private func extractTarBz2(_ archive: URL, to destDir: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xjf", archive.path, "-C", destDir]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ModelError.extractionFailed
        }
    }

    // MARK: - Errors

    enum ModelError: Error, LocalizedError {
        case downloadFailed(URL)
        case extractionFailed

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let url):
                return L("模型下载失败: \(url.lastPathComponent)", "Model download failed: \(url.lastPathComponent)")
            case .extractionFailed:
                return L("模型解压失败", "Model extraction failed")
            }
        }
    }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    let onComplete: @Sendable (URL?, URLResponse?, Error?) -> Void

    /// Retain the completed file URL until the task delegate fires.
    private var completedURL: URL?
    private var completedResponse: URLResponse?

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
        // Copy to temp before system cleans up the delegate-provided location
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".partial")
        try? FileManager.default.copyItem(at: location, to: temp)
        completedURL = temp
        completedResponse = downloadTask.response
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            onComplete(nil, nil, error)
        } else {
            onComplete(completedURL, completedResponse, nil)
        }
        session.invalidateAndCancel()
    }
}
