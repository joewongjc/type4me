import Foundation
import os

actor MagpieModelCatalog {
    static let shared = MagpieModelCatalog()

    struct Entry: Sendable, Equatable, Hashable {
        let id: String
        let label: String?
        let isGroup: Bool
        let reasoningLevels: [String]
    }

    private static let ranking: [String: Int] = [
        "none": 0,
        "minimal": 1,
        "low": 2,
        "medium": 3,
        "high": 4,
        "xhigh": 5,
        "max": 6,
    ]

    static func findLowestReasoningEffort(in levels: [String]) -> String? {
        guard !levels.isEmpty else { return nil }
        var lowest: (level: String, rank: Int)?
        for level in levels {
            let normalized = level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let rank = ranking[normalized] else { continue }
            if let current = lowest {
                if rank < current.rank {
                    lowest = (normalized, rank)
                }
            } else {
                lowest = (normalized, rank)
            }
        }
        return lowest?.level
    }

    private struct CacheState {
        var entries: [Entry] = []
        var fetchedAt: Date?
        var baseURL: String?
        var knownModels: Set<String> = []
        var overrideAllowedModels: Set<String>?
    }

    private static let stateLock = OSAllocatedUnfairLock(initialState: CacheState())

    static func isModelAllowed(_ model: String) -> Bool {
        stateLock.withLock { state in
            if let override = state.overrideAllowedModels {
                return override.contains(model)
            }
            if !state.knownModels.isEmpty {
                return state.knownModels.contains(model)
            }
            return true
        }
    }

    static func setAllowedModelsForTesting(_ models: Set<String>?) {
        stateLock.withLock { state in
            state.overrideAllowedModels = models
        }
    }

    private func updateKnownModels(_ entries: [Entry], baseURL: URL) {
        Self.stateLock.withLock { state in
            state.entries = entries
            state.fetchedAt = Date()
            state.baseURL = baseURL.absoluteString
            state.knownModels = Set(entries.map(\.id))
        }
    }

    func models(baseURL: URL, forceRefresh: Bool = false) async throws -> [Entry] {
        let now = Date()
        let cached = Self.stateLock.withLock { state -> [Entry]? in
            guard !forceRefresh,
                  let fetchedAt = state.fetchedAt,
                  now.timeIntervalSince(fetchedAt) < 600,
                  state.baseURL == baseURL.absoluteString
            else { return nil }
            return state.entries
        }

        if let cached {
            return cached
        }

        var baseString = baseURL.absoluteString
        while baseString.hasSuffix("/") {
            baseString.removeLast()
        }
        if !baseString.hasSuffix("/v1") {
            baseString += "/v1"
        }

        guard let modelsURL = URL(string: "\(baseString)/models") else {
            return []
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 3.0

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 3.0
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }

        let parsed = Self.parseModelsResponse(data)
        updateKnownModels(parsed, baseURL: baseURL)
        return parsed
    }

    func lowestReasoningEffort(model: String, baseURL: URL) async -> String? {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let entry = Self.stateLock.withLock({ state in state.entries.first(where: { $0.id == trimmedModel }) }) {
            return Self.findLowestReasoningEffort(in: entry.reasoningLevels)
        }

        // Fast path: fetch /v1/models with 300ms budget
        var baseString = baseURL.absoluteString
        while baseString.hasSuffix("/") {
            baseString.removeLast()
        }
        if !baseString.hasSuffix("/v1") {
            baseString += "/v1"
        }

        guard let modelsURL = URL(string: "\(baseString)/models") else {
            return nil
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.3

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.3
        config.timeoutIntervalForResource = 0.3
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let entries = Self.parseModelsResponse(data)
            updateKnownModels(entries, baseURL: baseURL)
            if let entry = entries.first(where: { $0.id == trimmedModel }) {
                return Self.findLowestReasoningEffort(in: entry.reasoningLevels)
            }
        } catch {
            return nil
        }

        return nil
    }

    static func parseModelsResponse(_ data: Data) -> [Entry] {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let dataList = json["data"] as? [[String: Any]]
        else {
            return []
        }

        var result: [Entry] = []
        for item in dataList {
            guard let id = item["id"] as? String else { continue }
            let magpieLabel = item["magpie_label"] as? String
            let displayName = item["display_name"] as? String
            let label = magpieLabel ?? displayName

            var reasoningLevels: [String] = []
            if let rawLevels = item["supported_reasoning_levels"] as? [[String: Any]] {
                for lvl in rawLevels {
                    if let effort = lvl["effort"] as? String {
                        reasoningLevels.append(effort)
                    }
                }
            } else if let strLevels = item["supported_reasoning_levels"] as? [String] {
                reasoningLevels = strLevels
            }

            let isGroup = id.hasPrefix("group/")
            result.append(Entry(
                id: id,
                label: label,
                isGroup: isGroup,
                reasoningLevels: reasoningLevels
            ))
        }

        return result
    }
}
