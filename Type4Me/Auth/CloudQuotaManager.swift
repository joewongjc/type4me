import Foundation
import os

// MARK: - Subscription Info

struct CloudSubscription: Codable, Sendable {
    let plan: String              // "free" or "pro"
    let isActive: Bool            // subscription currently active
    let expiresAt: Date?          // nil for free, next billing date for pro
    let freeCharsRemaining: Int?  // only for free tier: remaining trial characters
}

// MARK: - Subscription Errors

enum CloudSubscriptionError: LocalizedError, Sendable {
    case notAuthenticated
    case fetchFailed(String)
    case subscriptionExpired
    case freeTrialExhausted

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "未登录"
        case .fetchFailed(let msg): "查询失败: \(msg)"
        case .subscriptionExpired: "订阅已过期"
        case .freeTrialExhausted: "免费体验额度已用完"
        }
    }
}

// MARK: - Cloud Subscription Manager

actor CloudSubscriptionManager {
    static let shared = CloudSubscriptionManager()

    private let logger = Logger(subsystem: "com.type4me", category: "CloudSub")

    private var cached: CloudSubscription?
    private var lastFetchTime: Date?

    private let staleDuration: TimeInterval = 60

    // MARK: - Proxy URL

    private var proxyURL: String { CloudConfig.proxyURL }

    // MARK: - Public API

    /// Check if user can use cloud ASR right now.
    func canUse() async throws -> Bool {
        let sub = try await subscription()
        if sub.plan == "pro" && sub.isActive {
            return true
        }
        // Free tier: check remaining trial characters
        if let remaining = sub.freeCharsRemaining, remaining > 0 {
            return true
        }
        return false
    }

    /// Fetch subscription status from server.
    func subscription() async throws -> CloudSubscription {
        if let cached, let fetchTime = lastFetchTime,
           Date.now.timeIntervalSince(fetchTime) < staleDuration {
            return cached
        }
        return try await fetchSubscription()
    }

    /// Force refresh subscription status.
    func refresh() async throws -> CloudSubscription {
        return try await fetchSubscription()
    }

    /// Deduct free trial characters locally after a session.
    func deductFreeChars(_ count: Int) {
        guard let current = cached, current.plan == "free" else { return }
        let newRemaining = max(0, (current.freeCharsRemaining ?? 0) - count)
        cached = CloudSubscription(
            plan: current.plan,
            isActive: current.isActive,
            expiresAt: current.expiresAt,
            freeCharsRemaining: newRemaining
        )
        logger.info("Free trial deduct \(count) chars, remaining ~\(newRemaining)")
    }

    /// Invalidate cache.
    func invalidateCache() {
        cached = nil
        lastFetchTime = nil
    }

    // MARK: - Fetch

    private func fetchSubscription() async throws -> CloudSubscription {
        let token = try await CloudAuthManager.shared.accessToken()

        let url = URL(string: "\(proxyURL)/api/subscription")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 {
            throw CloudSubscriptionError.notAuthenticated
        }

        guard status >= 200, status < 300 else {
            let message = parseErrorMessage(from: data) ?? "HTTP \(status)"
            logger.error("Subscription fetch failed: \(message)")
            throw CloudSubscriptionError.fetchFailed(message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let sub = try decoder.decode(CloudSubscription.self, from: data)

        cached = sub
        lastFetchTime = Date.now
        logger.info("Subscription: plan=\(sub.plan) active=\(sub.isActive)")
        return sub
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error"] as? String ?? json["message"] as? String
    }
}
