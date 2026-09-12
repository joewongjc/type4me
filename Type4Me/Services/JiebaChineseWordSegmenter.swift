import Foundation

#if HAS_CPPJIEBA
import CppJiebaBridge

actor JiebaChineseWordSegmenter: ChineseWordSegmenting {
    nonisolated static let experimentDefaultsKey = "tf_cppJiebaExperimentEnabled"

    nonisolated static var isExperimentEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: experimentDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: experimentDefaultsKey)
    }

    private final class TokenCollector: @unchecked Sendable {
        struct Token {
            let offset: Int
            let length: Int
            let source: ChineseTokenSpan.Source
        }

        let source: ChineseTokenSpan.Source
        var tokens: [Token] = []

        init(source: ChineseTokenSpan.Source) {
            self.source = source
        }
    }

    private var handle: OpaquePointer?
    private var failedToLoad = false
    private var persistedWords = Set<String>()
    private let resourceDirectory: URL?
    private let overlayURL: URL
    private let idleTimeout: Duration
    private var idleEvictionTask: Task<Void, Never>?
    private var activityGeneration = 0
    private var recordedFallbackReasons = Set<String>()

    init(
        resourceDirectory: URL? = nil,
        overlayURL: URL? = nil,
        idleTimeout: Duration = .seconds(600)
    ) {
        self.resourceDirectory = resourceDirectory ?? Self.defaultResourceDirectory()
        self.idleTimeout = idleTimeout
        if let overlayURL {
            self.overlayURL = overlayURL
        } else {
            let appSupport = AppDataLocation.directory
            self.overlayURL = appSupport.appendingPathComponent("jieba-user-dictionary-v1.utf8")
        }
    }

    deinit {
        idleEvictionTask?.cancel()
        if let handle {
            t4m_jieba_destroy(handle)
            t4m_jieba_purge_global_cache()
        }
    }

    func tokenSpans(in text: String) -> [ChineseTokenSpan] {
        guard Self.isExperimentEnabled else {
            recordFallbackOnce(reason: "disabled")
            unloadHandle()
            return []
        }
        guard !text.isEmpty,
              let handle = ensureLoaded()
        else { return [] }
        beginActivity()
        defer { scheduleIdleEviction() }

        var spans: [ChineseTokenSpan] = []
        spans.append(contentsOf: cut(text, handle: handle, searchMode: false))
        spans.append(contentsOf: cut(text, handle: handle, searchMode: true))
        return spans
    }

    func insertConfirmedUserWord(_ word: String, frequency: Int = 10_000) {
        let normalized = word.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isExperimentEnabled else {
            recordFallbackOnce(reason: "disabled")
            unloadHandle()
            return
        }
        guard !normalized.isEmpty, let handle = ensureLoaded() else { return }
        beginActivity()
        defer { scheduleIdleEviction() }
        let inserted = normalized.withCString { pointer in
            t4m_jieba_insert_user_word(handle, pointer, Int32(frequency))
        }
        guard inserted else { return }
        if persistedWords.insert(normalized).inserted {
            persistOverlayWord(normalized, frequency: frequency)
        }
    }

    func releaseForDisabledExperiment() {
        unloadHandle()
    }

    private func ensureLoaded() -> OpaquePointer? {
        if let handle { return handle }
        guard !failedToLoad, let resourceDirectory else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: overlayURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: overlayURL.path) {
                try Data().write(to: overlayURL, options: .atomic)
            }
            if let existing = try? String(contentsOf: overlayURL, encoding: .utf8) {
                persistedWords = Set(existing.split(whereSeparator: \.isNewline).compactMap { line in
                    line.split(whereSeparator: \.isWhitespace).first.map(String.init)
                })
            }
        } catch {
            failedToLoad = true
            recordFallbackOnce(reason: "overlay_initialization")
            DebugFileLogger.log("jieba overlay initialization failed")
            return nil
        }
        let dictionary = resourceDirectory.appendingPathComponent("dict.txt.small").path
        let hmm = resourceDirectory.appendingPathComponent("hmm_model.utf8").path
        guard FileManager.default.fileExists(atPath: dictionary),
              FileManager.default.fileExists(atPath: hmm)
        else {
            failedToLoad = true
            recordFallbackOnce(reason: "resources_unavailable")
            DebugFileLogger.log("jieba resources unavailable; using native tokenizer")
            return nil
        }
        let loaded = dictionary.withCString { dictionaryPointer in
            hmm.withCString { hmmPointer in
                overlayURL.path.withCString { overlayPointer in
                    t4m_jieba_create(dictionaryPointer, hmmPointer, overlayPointer)
                }
            }
        }
        guard let loaded else {
            failedToLoad = true
            recordFallbackOnce(reason: "dictionary_load")
            DebugFileLogger.log("jieba compact dictionary load failed; using native tokenizer")
            return nil
        }
        handle = loaded
        Task { await UserEditObservationMetrics.shared.record(.jiebaLoaded) }
        let builtInWords = ["Type4Me", "智能感知"]
        for word in builtInWords + HotwordStorage.load() {
            let normalized = word.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            _ = normalized.withCString { pointer in
                t4m_jieba_insert_user_word(loaded, pointer, 10_000)
            }
            if persistedWords.insert(normalized).inserted {
                persistOverlayWord(normalized, frequency: 10_000)
            }
        }
        return loaded
    }

    private func cut(
        _ text: String,
        handle: OpaquePointer,
        searchMode: Bool
    ) -> [ChineseTokenSpan] {
        let source: ChineseTokenSpan.Source = searchMode ? .jiebaSearch : .jiebaAccurate
        let collector = TokenCollector(source: source)
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let succeeded = text.withCString { pointer in
            t4m_jieba_cut(
                handle,
                pointer,
                searchMode,
                { _, length, offset, context in
                    guard let context else { return }
                    let collector = Unmanaged<TokenCollector>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    collector.tokens.append(.init(
                        offset: Int(offset),
                        length: Int(length),
                        source: collector.source
                    ))
                },
                context
            )
        }
        guard succeeded else { return [] }
        return collector.tokens.compactMap { token in
            guard let lowerUTF8 = text.utf8.index(
                text.utf8.startIndex,
                offsetBy: token.offset,
                limitedBy: text.utf8.endIndex
            ),
            let upperUTF8 = text.utf8.index(
                lowerUTF8,
                offsetBy: token.length,
                limitedBy: text.utf8.endIndex
            ),
            let lower = String.Index(lowerUTF8, within: text),
            let upper = String.Index(upperUTF8, within: text)
            else { return nil }
            return ChineseTokenSpan(range: lower..<upper, source: token.source)
        }
    }

    private func persistOverlayWord(_ word: String, frequency: Int) {
        let line = "\(word) \(frequency) nz\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: overlayURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            DebugFileLogger.log("jieba overlay persistence failed")
        }
    }

    private func beginActivity() {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
        activityGeneration &+= 1
    }

    private func scheduleIdleEviction() {
        activityGeneration &+= 1
        let generation = activityGeneration
        idleEvictionTask?.cancel()
        idleEvictionTask = Task { [idleTimeout] in
            do {
                try await Task.sleep(for: idleTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.unloadIfIdle(generation: generation)
        }
    }

    private func unloadIfIdle(generation: Int) {
        guard generation == activityGeneration else { return }
        unloadHandle()
    }

    private func unloadHandle() {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
        activityGeneration &+= 1
        guard let handle else { return }
        t4m_jieba_destroy(handle)
        t4m_jieba_purge_global_cache()
        self.handle = nil
        Task { await UserEditObservationMetrics.shared.record(.jiebaReleased) }
        DebugFileLogger.log("jieba compact dictionary released after idle")
    }

    private func recordFallbackOnce(reason: String) {
        guard recordedFallbackReasons.insert(reason).inserted else { return }
        Task {
            await UserEditObservationMetrics.shared.record(.jiebaFallback, reason: reason)
        }
    }

#if DEBUG
    func isLoadedForTesting() -> Bool { handle != nil }

    func unloadForTesting() {
        unloadHandle()
    }
#endif

    nonisolated private static func defaultResourceDirectory() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Jieba"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Jieba")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }
}
#endif
