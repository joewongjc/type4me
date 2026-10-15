import Foundation
import os

struct MagpieAgentFile: Equatable, Sendable {
    let model: String
    let baseURL: URL
    let apiKey: String

    enum LoadResult: Equatable, Sendable {
        case absent                 // 文件不存在，或三个键都缺失
        case incomplete             // 有部分键（Magpie 写入中途或被手动修改）
        case managed(MagpieAgentFile)
        case unreadable             // 存在但不是 JSON 对象
        case nonLoopback(String)    // baseURL 不是回环地址
    }

    static var defaultURL: URL {
        AppDataLocation.profileDirectory.appendingPathComponent("magpie-agent.json")
    }

    private struct CacheKey: Hashable {
        let path: String
    }

    private struct CacheEntry {
        let modificationDate: Date?
        let fileSize: UInt64?
        let fileNumber: UInt64?
        let result: LoadResult
    }

    private static let cacheLock = OSAllocatedUnfairLock(initialState: [CacheKey: CacheEntry]())

    static func clearCache() {
        cacheLock.withLock { cache in
            cache.removeAll()
        }
    }

    static func parse(_ data: Data) -> LoadResult {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any]
        else {
            return .unreadable
        }

        let rawModel = (dict["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBaseURL = (dict["baseURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAPIKey = (dict["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let model = (rawModel?.isEmpty == false) ? rawModel : nil
        let baseURLStr = (rawBaseURL?.isEmpty == false) ? rawBaseURL : nil
        let apiKey = (rawAPIKey?.isEmpty == false) ? rawAPIKey : nil

        if model == nil && baseURLStr == nil && apiKey == nil {
            return .absent
        }

        guard let model, let baseURLStr, let apiKey else {
            return .incomplete
        }

        var normalizedBase = baseURLStr
        while normalizedBase.hasSuffix("/") {
            normalizedBase.removeLast()
        }

        guard let url = URL(string: normalizedBase), MagpieGateway.isLoopback(url) else {
            return .nonLoopback(normalizedBase)
        }

        return .managed(MagpieAgentFile(model: model, baseURL: url, apiKey: apiKey))
    }

    static func load(from url: URL = defaultURL) -> LoadResult {
        let path = url.path
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: path) else {
            _ = cacheLock.withLock { cache in
                cache.removeValue(forKey: CacheKey(path: path))
            }
            return .absent
        }

        let attrs = (try? fileManager.attributesOfItem(atPath: path)) ?? [:]
        let mtime = attrs[.modificationDate] as? Date
        let size = (attrs[.size] as? NSNumber)?.uint64Value
        let fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value

        let key = CacheKey(path: path)
        if let entry = cacheLock.withLock({ $0[key] }) {
            if entry.modificationDate == mtime && entry.fileSize == size && entry.fileNumber == fileNumber {
                return entry.result
            }
        }

        guard let data = try? Data(contentsOf: url) else {
            return .unreadable
        }

        let result = parse(data)
        let newEntry = CacheEntry(
            modificationDate: mtime,
            fileSize: size,
            fileNumber: fileNumber,
            result: result
        )
        cacheLock.withLock { cache in
            cache[key] = newEntry
        }
        return result
    }
}
