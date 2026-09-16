import Foundation

/// Syncs LLM pricing tables from OpenRouter's public Models API.
///
/// - Cache file: `~/Library/Application Support/Type4Me/llm-pricing-cache.json`
/// - Cooldown: 7 days between automatic fetches (`tf_lastPricingSync`)
/// - Failures keep the current snapshot (seed catalog on first run) and leave
///   the cooldown untouched so the next launch retries.
@MainActor
@Observable
final class LLMPricingSyncService {

    static let shared = LLMPricingSyncService()

    private let url = URL(string: "https://openrouter.ai/api/v1/models")!
    private let lastSyncKey = "tf_lastPricingSync"
    private let autoSyncKey = "tf_pricingAutoSync"
    private let syncInterval: TimeInterval = 7 * 24 * 60 * 60
    private var timer: Timer?

    private let cacheFileURL: URL

    // MARK: - Observable state

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastSyncError: String?
    private(set) var entryCount = 0

    private init() {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Type4Me", isDirectory: true)
        self.cacheFileURL = directory.appendingPathComponent("llm-pricing-cache.json")
    }

    // MARK: - Lifecycle

    /// Loads the cached snapshot, then starts the periodic sync timer if enabled.
    func start() {
        loadCachedSnapshot()

        let autoSync = UserDefaults.standard.object(forKey: autoSyncKey) as? Bool ?? true
        guard autoSync else { return }

        Task { await syncIfNeeded() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.syncIfNeeded()
            }
        }
    }

    // MARK: - Cache

    /// Synchronously loads the on-disk snapshot into the registry.
    /// Corrupt or undecodable files are ignored (seed catalog stays active);
    /// the file is neither deleted nor rewritten.
    func loadCachedSnapshot() {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return }
        guard let snapshot = try? JSONDecoder().decode(LLMPricingSnapshot.self, from: data) else { return }

        LLMPricingRegistry.applyRemoteSnapshot(snapshot)
        lastSyncDate = snapshot.fetchedAt
        entryCount = snapshot.entries.count
    }

    // MARK: - Sync

    /// Fetches only if the cooldown interval has elapsed.
    private func syncIfNeeded() async {
        let lastSync = UserDefaults.standard.double(forKey: lastSyncKey)
        let now = Date().timeIntervalSince1970
        if lastSync > 0 && (now - lastSync) < syncInterval {
            return
        }
        await fetch()
    }

    /// Manual sync (always fetches, ignores cooldown).
    func syncNow() async {
        await fetch()
    }

    private func fetch() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let (session, _) = LLMURLSessionFactory.make(
                providerID: "pricing",
                bypassProxy: ProxyBypassMode.current.bypassLLM
            )
            defer { session.finishTasksAndInvalidate() }

            let (data, _) = try await session.data(from: url)
            let entries = try Self.parseEntries(from: data)

            let snapshot = LLMPricingSnapshot(
                fetchedAt: Date(),
                sourceURL: url.absoluteString,
                entries: entries
            )

            LLMPricingRegistry.applyRemoteSnapshot(snapshot)
            lastSyncDate = snapshot.fetchedAt
            entryCount = entries.count
            lastSyncError = nil

            try Self.persist(snapshot, to: cacheFileURL)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSyncKey)

            // Backfill historical rows whose cost was recorded as 0 because the
            // rate was unknown at write time, then notify the dashboard to refresh.
            await HistoryStore.shared.recalculateZeroCostRecordsIfNeeded()

            // Notify after in-memory registry is active and historical 0-cost
            // records have finished recalculating.
            NotificationCenter.default.post(name: .llmPricingTableDidChange, object: nil)
        } catch {
            lastSyncError = error.localizedDescription
            NSLog("[LLMPricingSync] fetch failed: \(error)")
        }
    }

    // MARK: - Parsing

    private struct OpenRouterModelsResponse: Decodable {
        let data: [Model]

        struct Model: Decodable {
            let id: String
            let pricing: Pricing

            struct Pricing: Decodable {
                let prompt: String?
                let completion: String?
            }
        }
    }

    /// OpenRouter error response shape, used to surface human-readable messages.
    private struct OpenRouterErrorBody: Decodable {
        struct ErrorDetail: Decodable {
            let message: String?
        }
        let error: ErrorDetail?
    }

    /// Converts raw Models API payload into normalized entries.
    /// - Drops `:variant` and `~alias` IDs, entries with missing/unparseable
    ///   prices, and zero-priced entries (free variants / placeholders).
    /// - Keeps the first occurrence of duplicate keys (upstream lists newer
    ///   models first).
    /// - Throws if fewer than 50 valid entries survive, treating the response
    ///   as anomalous so an empty table can never replace the seed catalog.
    nonisolated static func parseEntries(from data: Data) throws -> [ModelPriceEntry] {
        let decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)

        var entries: [ModelPriceEntry] = []
        var seenKeys = Set<String>()
        for model in decoded.data {
            guard let key = LLMPricingNormalizer.normalizeUpstreamID(model.id) else { continue }
            guard let promptStr = model.pricing.prompt,
                  let completionStr = model.pricing.completion,
                  let prompt = Double(promptStr),
                  let completion = Double(completionStr) else { continue }
            if prompt == 0 && completion == 0 { continue }
            guard !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            entries.append(ModelPriceEntry(
                key: key,
                inputPricePerMTok: prompt * 1_000_000,
                outputPricePerMTok: completion * 1_000_000
            ))
        }

        guard entries.count >= 50 else {
            let message = (try? JSONDecoder().decode(OpenRouterErrorBody.self, from: data))?.error?.message
            let detail = message ?? "\(entries.count) valid entries"
            throw LLMPricingSyncError.anomalousUpstreamResponse(detail: detail)
        }
        return entries
    }

    private static func persist(_ snapshot: LLMPricingSnapshot, to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

}

extension Notification.Name {
    public static let llmPricingTableDidChange = Notification.Name("llmPricingTableDidChange")
}

enum LLMPricingSyncError: LocalizedError {
    case anomalousUpstreamResponse(detail: String)

    var errorDescription: String? {
        switch self {
        case .anomalousUpstreamResponse(let detail):
            return "Anomalous upstream pricing response: \(detail)"
        }
    }
}
