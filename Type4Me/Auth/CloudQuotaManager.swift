import Foundation
import os

@MainActor
final class CloudQuotaManager: ObservableObject {
    static let shared = CloudQuotaManager()

    @Published private(set) var plan: String = "free"
    @Published private(set) var isPaid: Bool = false
    @Published private(set) var freeCharsRemaining: Int = 0
    @Published private(set) var expiresAt: Date?
    @Published private(set) var weekChars: Int = 0
    @Published private(set) var totalChars: Int = 0

    private let logger = Logger(subsystem: "com.type4me.app", category: "CloudQuota")
    private var lastFetched: Date?

    private init() {
        // Restore cached quota from UserDefaults
        freeCharsRemaining = UserDefaults.standard.integer(forKey: "tf_cloud_free_chars_remaining")
        if freeCharsRemaining == 0 && !UserDefaults.standard.bool(forKey: "tf_cloud_quota_fetched") {
            // Never fetched before: use optimistic default
            freeCharsRemaining = 2000
        }
    }

    /// Refresh quota and usage data from the server.
    /// Skips if fetched less than 30 seconds ago unless `force` is true.
    func refresh(force: Bool = false) async {
        if !force, let last = lastFetched, Date().timeIntervalSince(last) < 30 { return }

        // Fetch quota
        do {
            let data = try await CloudAPIClient.shared.request("/api/quota")
            struct QuotaResponse: Decodable {
                let plan: String
                let is_paid: Bool
                let remaining_chars: Int
                let expires_at: String?
            }
            let r = try JSONDecoder().decode(QuotaResponse.self, from: data)
            plan = r.plan
            isPaid = r.is_paid
            freeCharsRemaining = r.remaining_chars
            if let e = r.expires_at {
                expiresAt = ISO8601DateFormatter().date(from: e)
            }
            // Persist for next launch
            UserDefaults.standard.set(r.remaining_chars, forKey: "tf_cloud_free_chars_remaining")
            UserDefaults.standard.set(true, forKey: "tf_cloud_quota_fetched")
        } catch {
            logger.error("Quota fetch failed: \(error)")
        }

        // Fetch usage
        do {
            let data = try await CloudAPIClient.shared.request("/api/usage")
            struct UsageResponse: Decodable {
                let total_chars: Int
                let week_chars: Int
            }
            let r = try JSONDecoder().decode(UsageResponse.self, from: data)
            weekChars = r.week_chars
            totalChars = r.total_chars
        } catch {
            logger.error("Usage fetch failed: \(error)")
        }

        lastFetched = Date()
    }

    /// Check if the user can still use cloud services.
    func canUse() async -> Bool {
        await refresh()
        return isPaid || freeCharsRemaining > 0
    }

    /// Optimistically deduct characters locally (server is authoritative).
    func deductLocal(chars: Int) {
        if !isPaid {
            freeCharsRemaining = max(0, freeCharsRemaining - chars)
            UserDefaults.standard.set(freeCharsRemaining, forKey: "tf_cloud_free_chars_remaining")
        }
        weekChars += chars
        totalChars += chars
    }

    /// Report usage to server. Used after cloud ASR sessions where the server
    /// doesn't independently track character counts (e.g. direct mode without LLM).
    func reportUsage(chars: Int, mode: String) async {
        guard chars > 0 else { return }
        guard let token = await CloudAuthManager.shared.accessToken() else { return }

        let endpoint = CloudConfig.apiEndpoint + "/api/report-usage"
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        struct ReportRequest: Encodable {
            let char_count: Int
            let mode: String
        }
        req.httpBody = try? JSONEncoder().encode(ReportRequest(char_count: chars, mode: mode))

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct ReportResponse: Decodable {
                let remaining: Int
            }
            if let r = try? JSONDecoder().decode(ReportResponse.self, from: data) {
                freeCharsRemaining = r.remaining
                UserDefaults.standard.set(r.remaining, forKey: "tf_cloud_free_chars_remaining")
            }
        } catch {
            logger.error("Report usage failed: \(error)")
        }
    }
}
