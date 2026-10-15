import Foundation
import os

enum MagpieGateway {
    static let defaultPort = 3425

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/magpie/settings.json")
    }

    private struct SettingsCache {
        var mtime: Date?
        var size: UInt64?
        var url: URL
    }

    private static let cacheLock = OSAllocatedUnfairLock(initialState: SettingsCache(
        mtime: nil,
        size: nil,
        url: URL(string: "http://127.0.0.1:\(defaultPort)")!
    ))

    static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.lowercased() else {
            return false
        }
        let loopbacks: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
        if loopbacks.contains(host) { return true }

        var sin = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &sin) }) == 1 {
            let addr = UInt32(bigEndian: sin.s_addr)
            return (addr >> 24) == 127
        }

        var sin6 = in6_addr()
        let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if cleanHost.withCString({ inet_pton(AF_INET6, $0, &sin6) }) == 1 {
            return cleanHost == "::1"
        }

        return false
    }

    static func directBaseURL(settingsData: Data?) -> URL {
        guard let data = settingsData,
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any]
        else {
            return URL(string: "http://127.0.0.1:\(defaultPort)")!
        }

        var port: Int?
        if let portInt = dict["port"] as? Int, (1...65535).contains(portInt) {
            port = portInt
        } else if let portStr = dict["port"] as? String, let parsed = Int(portStr), (1...65535).contains(parsed) {
            port = parsed
        }

        let resolvedPort = port ?? defaultPort
        return URL(string: "http://127.0.0.1:\(resolvedPort)")!
    }

    static func directBaseURL() -> URL {
        let path = settingsURL.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            let defaultBase = URL(string: "http://127.0.0.1:\(defaultPort)")!
            cacheLock.withLock { cache in
                cache.mtime = nil
                cache.size = nil
                cache.url = defaultBase
            }
            return defaultBase
        }

        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let mtime = attrs[.modificationDate] as? Date
        let size = (attrs[.size] as? NSNumber)?.uint64Value

        if let cached = cacheLock.withLock({ $0.mtime == mtime && $0.size == size ? $0.url : nil }) {
            return cached
        }

        let data = try? Data(contentsOf: settingsURL)
        let resolved = directBaseURL(settingsData: data)

        cacheLock.withLock { cache in
            cache.mtime = mtime
            cache.size = size
            cache.url = resolved
        }
        return resolved
    }

    enum HelloResult: Equatable, Sendable {
        case magpie(version: String)
        case notMagpie
        case unreachable
    }

    static func hello(baseURL: URL) async -> HelloResult {
        var baseString = baseURL.absoluteString
        while baseString.hasSuffix("/") {
            baseString.removeLast()
        }
        if baseString.hasSuffix("/v1") {
            baseString = String(baseString.dropLast(3))
        }

        guard let helloURL = URL(string: "\(baseString)/api/hello") else {
            return .unreachable
        }

        var request = URLRequest(url: helloURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 1.5
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .unreachable
            }
            guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                return .notMagpie
            }
            if let name = json["name"] as? String, name == "magpie" {
                let version = json["version"] as? String ?? ""
                return .magpie(version: version)
            }
            return .notMagpie
        } catch {
            return .unreachable
        }
    }

    static func directIdentity(bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        bundleID == AppDataLocation.devBundleID ? "magpie-type4me-dev" : "magpie-type4me"
    }
}
