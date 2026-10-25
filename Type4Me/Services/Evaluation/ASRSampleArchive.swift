import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// One saved recording plus the text the ASR provider returned for it, before
/// snippets, LLM processing or any other rewrite. Stored as one JSON line in
/// `manifest.jsonl` so evaluation scripts can stream the archive.
struct ASRSampleRecord: Codable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    /// Path of the WAV file relative to the archive root.
    let audioFile: String
    let audioDurationSeconds: Double
    let sampleRate: Int
    let channels: Int
    let asrProvider: String
    let asrProviderName: String
    let asrModel: String?
    let isStreaming: Bool
    /// Raw ASR output. Empty when the provider returned nothing for audible speech.
    let rawText: String
    /// `completed`, `cancelled`, `batch_fallback` or `stream_recovery`.
    let status: String
    /// `input`, `revise` or `selection_ask`.
    let purpose: String
    let processingModeId: String?
    let processingModeName: String?
    let appVersion: String
}

/// Opt-in archive of raw recordings and their ASR transcripts, kept so ASR
/// providers can be compared offline on the user's real speech.
///
/// Lives in `<profile>/asr-samples/`. It is not on the backup allowlist on
/// purpose: the audio grows without bound and the user manages it in Finder.
actor ASRSampleArchive {

    static let shared = ASRSampleArchive()

    static let enabledKey = "tf_saveASRSamples"
    static let manifestFileName = "manifest.jsonl"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var defaultRootDirectory: URL {
        AppDataLocation.profileDirectory.appendingPathComponent("asr-samples", isDirectory: true)
    }

    private let rootDirectory: URL

    init(rootDirectory: URL = ASRSampleArchive.defaultRootDirectory) {
        self.rootDirectory = rootDirectory
    }

    struct Sample: Sendable {
        var pcm: Data
        var rawText: String
        var provider: ASRProvider
        var asrModel: String?
        var isStreaming: Bool
        var status: String
        var purpose: String
        var processingModeId: String?
        var processingModeName: String?
        var createdAt: Date = Date()
        var sampleRate: Int = Int(AudioCaptureEngine.sampleRate)
    }

    /// Writes the WAV file, then appends its manifest line. Returns nil when
    /// there is no audio or the disk write fails; recording must not depend on it.
    @discardableResult
    func save(_ sample: Sample) -> ASRSampleRecord? {
        guard !sample.pcm.isEmpty else { return nil }

        let id = UUID().uuidString.lowercased()
        let dayFolder = Self.dayFormatter.string(from: sample.createdAt)
        let fileName = "\(Self.timeFormatter.string(from: sample.createdAt))_\(id.prefix(8)).wav"
        let relativePath = "\(dayFolder)/\(fileName)"
        let bytesPerSecond = Double(sample.sampleRate * MemoryLayout<Int16>.size)

        let record = ASRSampleRecord(
            id: id,
            createdAt: sample.createdAt,
            audioFile: relativePath,
            audioDurationSeconds: (Double(sample.pcm.count) / bytesPerSecond * 1000).rounded() / 1000,
            sampleRate: sample.sampleRate,
            channels: 1,
            asrProvider: sample.provider.rawValue,
            asrProviderName: sample.provider.displayName,
            asrModel: sample.asrModel,
            isStreaming: sample.isStreaming,
            rawText: sample.rawText,
            status: sample.status,
            purpose: sample.purpose,
            processingModeId: sample.processingModeId,
            processingModeName: sample.processingModeName,
            appVersion: AppBuildInfo.current.version
        )

        do {
            let fm = FileManager.default
            let dayDirectory = rootDirectory.appendingPathComponent(dayFolder, isDirectory: true)
            try fm.createDirectory(
                at: dayDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)

            let wav = WAVEncoder.encode(pcmData: sample.pcm, sampleRate: sample.sampleRate)
            try wav.write(to: dayDirectory.appendingPathComponent(fileName), options: .atomic)
            try appendManifestLine(for: record)
            DebugFileLogger.log(
                "asr sample saved \(relativePath) duration=\(record.audioDurationSeconds)s chars=\(record.rawText.count)"
            )
            return record
        } catch {
            DebugFileLogger.log("asr sample save failed: \(error)")
            return nil
        }
    }

    private func appendManifestLine(for record: ASRSampleRecord) throws {
        var line = try Self.encoder.encode(record)
        line.append(0x0A)

        let manifestURL = rootDirectory.appendingPathComponent(Self.manifestFileName)
        let fm = FileManager.default
        if !fm.fileExists(atPath: manifestURL.path) {
            fm.createFile(atPath: manifestURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: manifestURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    nonisolated static func revealInFinder() {
        let url = defaultRootDirectory
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    // MARK: - Formatting

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let dayFormatter: DateFormatter = makeFormatter("yyyy-MM-dd")
    private static let timeFormatter: DateFormatter = makeFormatter("yyyyMMdd-HHmmss")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }
}
