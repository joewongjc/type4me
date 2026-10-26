import Foundation
import Security

struct GitHubDeviceAuthorization: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: TimeInterval
}

struct GitHubIssueResult: Equatable, Sendable {
    let number: Int
    let url: URL
}

actor GitHubIssueReporter {
    static let shared = GitHubIssueReporter()
    static let issueWriteScope = "public_repo"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func isConnected() -> Bool {
        guard let credential = GitHubTokenStore.load() else { return false }
        guard Self.hasIssueWriteScope(credential.scopes ?? []) else {
            GitHubTokenStore.delete()
            return false
        }
        if let refreshExpiresAt = credential.refreshExpiresAt,
           refreshExpiresAt <= Date(),
           credential.accessExpiresAt?.timeIntervalSinceNow ?? 1 <= 0 {
            GitHubTokenStore.delete()
            return false
        }
        return true
    }

    func beginAuthorization() async throws -> GitHubDeviceAuthorization {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(Self.deviceAuthorizationFields())

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let payload = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        guard let verificationURL = URL(string: payload.verificationURI) else {
            throw GitHubReporterError.invalidResponse
        }
        return GitHubDeviceAuthorization(
            deviceCode: payload.deviceCode,
            userCode: payload.userCode,
            verificationURL: verificationURL,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn)),
            interval: TimeInterval(max(payload.interval, 5))
        )
    }

    func finishAuthorization(_ authorization: GitHubDeviceAuthorization) async throws {
        var interval = authorization.interval
        while Date() < authorization.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(interval))

            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody([
                "client_id": GitHubConfiguration.clientID,
                "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])

            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
            if let token = payload.accessToken {
                let credential = payload.credential(
                    accessToken: token,
                    fallbackScopes: [Self.issueWriteScope]
                )
                guard Self.hasIssueWriteScope(credential.scopes ?? []) else {
                    GitHubTokenStore.delete()
                    throw GitHubReporterError.insufficientScope
                }
                try GitHubTokenStore.save(credential)
                return
            }
            switch payload.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "access_denied":
                throw GitHubReporterError.accessDenied
            case "expired_token":
                throw GitHubReporterError.authorizationExpired
            default:
                throw GitHubReporterError.github(
                    payload.errorDescription ?? payload.error ?? "Unknown authorization error"
                )
            }
        }
        throw GitHubReporterError.authorizationExpired
    }

    func createIssue(title: String, body: String) async throws -> GitHubIssueResult {
        let token = try await validAccessToken()
        let endpoint = URL(
            string: "https://api.github.com/repos/\(GitHubConfiguration.owner)/\(GitHubConfiguration.repository)/issues"
        )!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Type4Me/\(Bundle.main.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(
            CreateIssueRequest(title: title, body: body, labels: ["bug"])
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubReporterError.invalidResponse
        }
        if http.statusCode == 401 {
            GitHubTokenStore.delete()
            throw GitHubReporterError.authorizationRevoked
        }
        if http.statusCode == 403 {
            let scopeHeader = http.value(forHTTPHeaderField: "X-OAuth-Scopes")
            if scopeHeader != nil, !Self.hasIssueWriteScope(Self.parseScopes(scopeHeader)) {
                GitHubTokenStore.delete()
                throw GitHubReporterError.insufficientScope
            }
        }
        try validate(response: response, data: data, expectedStatus: 201)
        let payload = try JSONDecoder().decode(CreateIssueResponse.self, from: data)
        guard let url = URL(string: payload.htmlURL) else {
            throw GitHubReporterError.invalidResponse
        }
        return GitHubIssueResult(number: payload.number, url: url)
    }

    func disconnect() {
        GitHubTokenStore.delete()
    }

    private func validAccessToken() async throws -> String {
        guard let credential = GitHubTokenStore.load() else {
            throw GitHubReporterError.notConnected
        }
        guard Self.hasIssueWriteScope(credential.scopes ?? []) else {
            GitHubTokenStore.delete()
            throw GitHubReporterError.insufficientScope
        }
        guard let expiresAt = credential.accessExpiresAt else {
            return credential.accessToken
        }
        if expiresAt.timeIntervalSinceNow > 60 {
            return credential.accessToken
        }
        guard let refreshToken = credential.refreshToken,
              credential.refreshExpiresAt?.timeIntervalSinceNow ?? 1 > 0 else {
            GitHubTokenStore.delete()
            throw GitHubReporterError.authorizationRevoked
        }

        var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": GitHubConfiguration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])

        let (data, response) = try await session.data(for: request)
        do {
            try validate(response: response, data: data)
            let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
            guard let accessToken = payload.accessToken else {
                throw GitHubReporterError.invalidResponse
            }
            let refreshed = payload.credential(
                accessToken: accessToken,
                fallbackScopes: credential.scopes ?? []
            )
            guard Self.hasIssueWriteScope(refreshed.scopes ?? []) else {
                throw GitHubReporterError.insufficientScope
            }
            try GitHubTokenStore.save(refreshed)
            return refreshed.accessToken
        } catch GitHubReporterError.insufficientScope {
            GitHubTokenStore.delete()
            throw GitHubReporterError.insufficientScope
        } catch {
            GitHubTokenStore.delete()
            throw GitHubReporterError.authorizationRevoked
        }
    }

    nonisolated static func deviceAuthorizationFields() -> [String: String] {
        [
            "client_id": GitHubConfiguration.clientID,
            "scope": issueWriteScope,
        ]
    }

    nonisolated static func parseScopes(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
    }

    nonisolated static func hasIssueWriteScope(_ scopes: [String]) -> Bool {
        scopes.contains(issueWriteScope) || scopes.contains("repo")
    }

    private func formBody(_ fields: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private func validate(response: URLResponse, data: Data, expectedStatus: Int = 200) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GitHubReporterError.invalidResponse
        }
        guard http.statusCode == expectedStatus else {
            let message = (try? JSONDecoder().decode(GitHubErrorResponse.self, from: data).message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GitHubReporterError.github("HTTP \(http.statusCode): \(message)")
        }
    }
}

private enum GitHubConfiguration {
    // Device Flow client identifiers are public by design. This is the same
    // owner-controlled OAuth client currently used by SelectX diagnostics.
    static let clientID = "Iv23li1q2ypCWYacmiEF"
    static let owner = "joewongjc"
    static let repository = "type4me"
}

private struct StoredGitHubCredential: Codable {
    let accessToken: String
    let accessExpiresAt: Date?
    let refreshToken: String?
    let refreshExpiresAt: Date?
    let scopes: [String]?
}

private enum GitHubTokenStore {
    static let service = "com.type4me.app.github"
    static let account = "issue-reporter"

    static func load() -> StoredGitHubCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredGitHubCredential.self, from: data)
    }

    static func save(_ credential: StoredGitHubCredential) throws {
        delete()
        let data: Data
        do {
            data = try JSONEncoder().encode(credential)
        } catch {
            throw GitHubReporterError.keychainFailure(errSecParam)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GitHubReporterError.keychainFailure(status)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let expiresIn: Int?
    let refreshToken: String?
    let refreshTokenExpiresIn: Int?
    let scope: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case scope
        case error
        case errorDescription = "error_description"
    }

    func credential(
        accessToken: String,
        now: Date = Date(),
        fallbackScopes: [String] = []
    ) -> StoredGitHubCredential {
        let scopes = GitHubIssueReporter.parseScopes(scope)
        return StoredGitHubCredential(
            accessToken: accessToken,
            accessExpiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            refreshToken: refreshToken,
            refreshExpiresAt: refreshTokenExpiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            scopes: scopes.isEmpty ? fallbackScopes : scopes
        )
    }
}

private struct CreateIssueRequest: Encodable {
    let title: String
    let body: String
    let labels: [String]
}

private struct CreateIssueResponse: Decodable {
    let number: Int
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case number
        case htmlURL = "html_url"
    }
}

private struct GitHubErrorResponse: Decodable {
    let message: String
}

enum GitHubReporterError: LocalizedError {
    case notConnected
    case accessDenied
    case authorizationExpired
    case authorizationRevoked
    case insufficientScope
    case invalidResponse
    case keychainFailure(OSStatus)
    case github(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return L("请先连接 GitHub", "Connect GitHub first")
        case .accessDenied: return L("GitHub 授权已取消", "GitHub authorization was cancelled")
        case .authorizationExpired: return L("GitHub 授权码已过期，请重试", "GitHub authorization expired; try again")
        case .authorizationRevoked: return L("GitHub 授权已失效，请重新连接", "GitHub authorization expired; reconnect")
        case .insufficientScope:
            return L(
                "GitHub 授权缺少提交 Issue 的权限，请重新授权",
                "GitHub authorization cannot create issues; authorize again"
            )
        case .invalidResponse: return L("GitHub 返回了无法识别的数据", "GitHub returned an invalid response")
        case .keychainFailure(let status):
            return L("无法把 GitHub token 保存到钥匙串（\(status)）", "Could not save the GitHub token in Keychain (\(status))")
        case .github(let message): return "GitHub: \(message)"
        }
    }
}

private extension Bundle {
    var appVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
