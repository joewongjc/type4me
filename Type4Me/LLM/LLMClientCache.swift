import Foundation

struct LLMClientCacheKey: Equatable, Sendable {
    let providerID: String
    let apiKey: String
    let model: String
    let baseURL: String
    let bypassProxy: Bool

    func invalidationReasons(comparedTo newKey: Self) -> [String] {
        var reasons: [String] = []
        if providerID != newKey.providerID { reasons.append("provider") }
        if apiKey != newKey.apiKey { reasons.append("apiKey") }
        if model != newKey.model { reasons.append("model") }
        if baseURL != newKey.baseURL { reasons.append("baseURL") }
        if bypassProxy != newKey.bypassProxy { reasons.append("proxyBypass") }
        return reasons
    }
}

struct LLMClientCache {
    private(set) var key: LLMClientCacheKey?
    private(set) var client: (any LLMClient)?

    mutating func resolve(
        key newKey: LLMClientCacheKey,
        makeClient: () -> any LLMClient
    ) -> (client: any LLMClient, reused: Bool, invalidated: (any LLMClient)?, reasons: [String]) {
        if key == newKey, let client {
            return (client, true, nil, [])
        }

        let oldClient = client
        let reasons = key?.invalidationReasons(comparedTo: newKey) ?? []
        let newClient = makeClient()
        key = newKey
        client = newClient
        return (newClient, false, oldClient, reasons)
    }

    mutating func remove() -> (any LLMClient)? {
        defer {
            key = nil
            client = nil
        }
        return client
    }
}

final class LLMURLSessionMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let providerID: String

    init(providerID: String) {
        self.providerID = providerID
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let transaction = metrics.transactionMetrics.last else { return }

        let dns = Self.duration(from: transaction.domainLookupStartDate, to: transaction.domainLookupEndDate)
        let connect = Self.duration(from: transaction.connectStartDate, to: transaction.connectEndDate)
        let tls = Self.duration(from: transaction.secureConnectionStartDate, to: transaction.secureConnectionEndDate)
        let wait = Self.duration(from: transaction.requestEndDate, to: transaction.responseStartDate)
        DebugFileLogger.log(
            "llm metrics: provider=\(providerID) dnsMs=\(dns) connectMs=\(connect) tlsMs=\(tls) responseWaitMs=\(wait) connectionReused=\(transaction.isReusedConnection)"
        )
        if transaction.isReusedConnection {
            DebugFileLogger.log("llm connection reused provider=\(providerID)")
        }
    }

    private static func duration(from start: Date?, to end: Date?) -> Int {
        guard let start, let end else { return 0 }
        return max(0, Int(end.timeIntervalSince(start) * 1_000))
    }
}

enum LLMURLSessionFactory {
    static func make(
        providerID: String,
        bypassProxy: Bool
    ) -> (session: URLSession, metricsDelegate: LLMURLSessionMetricsDelegate) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 4
        if bypassProxy {
            config.connectionProxyDictionary = [:]
        }
        let metricsDelegate = LLMURLSessionMetricsDelegate(providerID: providerID)
        let session = URLSession(
            configuration: config,
            delegate: metricsDelegate,
            delegateQueue: nil
        )
        return (session, metricsDelegate)
    }
}
