import Foundation
import CryptoKit
import os

// MARK: - Cloud Session

struct CloudSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userEmail: String
    let userID: String

    var isExpired: Bool {
        Date.now >= expiresAt
    }

    /// Consider expired 60s before actual expiry to avoid edge cases.
    var needsRefresh: Bool {
        Date.now >= expiresAt.addingTimeInterval(-60)
    }
}

// MARK: - Auth Errors

enum CloudAuthError: LocalizedError, Sendable {
    case noSession
    case magicLinkFailed(String)
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case signOutFailed(String)
    case invalidCallbackURL
    case missingPKCE

    var errorDescription: String? {
        switch self {
        case .noSession: "未登录"
        case .magicLinkFailed(let msg): "Magic Link 发送失败: \(msg)"
        case .tokenExchangeFailed(let msg): "登录验证失败: \(msg)"
        case .refreshFailed(let msg): "Token 刷新失败: \(msg)"
        case .signOutFailed(let msg): "登出失败: \(msg)"
        case .invalidCallbackURL: "回调 URL 格式错误"
        case .missingPKCE: "PKCE 验证信息丢失，请重新登录"
        }
    }
}

// MARK: - Cloud Auth Manager

actor CloudAuthManager {
    static let shared = CloudAuthManager()

    private let logger = Logger(subsystem: "com.type4me", category: "CloudAuth")

    // Keychain keys
    private enum Keys {
        static let accessToken = "tf_cloud_access_token"
        static let refreshToken = "tf_cloud_refresh_token"
        static let expiresAt = "tf_cloud_expires_at"
        static let userEmail = "tf_cloud_user_email"
        static let userID = "tf_cloud_user_id"
    }

    // PKCE state (lives only in memory, one flow at a time)
    private var pendingCodeVerifier: String?

    private var cachedSession: CloudSession?

    // MARK: - Supabase Config

    private var supabaseURL: String { CloudConfig.supabaseURL }
    private var supabaseAnonKey: String { CloudConfig.supabaseAnonKey }

    // MARK: - Public API

    var isLoggedIn: Bool {
        get async {
            await currentSession() != nil
        }
    }

    /// Send a Magic Link email. Starts the PKCE flow.
    func sendMagicLink(email: String) async throws {
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        pendingCodeVerifier = verifier

        let url = URL(string: "\(supabaseURL)/auth/v1/otp")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body: [String: Any] = [
            "email": email,
            "create_user": true,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status < 200 || status >= 300 {
            let message = parseErrorMessage(from: data) ?? "HTTP \(status)"
            logger.error("Magic link failed: \(message)")
            throw CloudAuthError.magicLinkFailed(message)
        }

        logger.info("Magic link sent to \(email)")
    }

    /// Handle the callback URL from the Magic Link.
    /// Expected: `type4me://auth/callback?code=...`
    func handleCallback(url: URL) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw CloudAuthError.invalidCallbackURL
        }

        guard let verifier = pendingCodeVerifier else {
            throw CloudAuthError.missingPKCE
        }
        pendingCodeVerifier = nil

        let session = try await exchangeCodeForSession(code: code, codeVerifier: verifier)
        try saveSession(session)
        cachedSession = session
        logger.info("Logged in as \(session.userEmail)")
    }

    /// Returns a valid access token, refreshing if needed.
    func accessToken() async throws -> String {
        guard var session = await currentSession() else {
            throw CloudAuthError.noSession
        }

        if session.needsRefresh {
            session = try await refreshSession(session)
            try saveSession(session)
            cachedSession = session
        }

        return session.accessToken
    }

    /// Returns the current session if valid, or nil.
    func currentSession() async -> CloudSession? {
        if let cached = cachedSession, !cached.isExpired {
            return cached
        }

        // Try loading from keychain
        guard let session = loadSession() else { return nil }

        if session.isExpired {
            // Try refreshing
            do {
                let refreshed = try await refreshSession(session)
                try saveSession(refreshed)
                cachedSession = refreshed
                return refreshed
            } catch {
                logger.warning("Session expired and refresh failed: \(error.localizedDescription)")
                clearSession()
                return nil
            }
        }

        cachedSession = session
        return session
    }

    /// Sign out and clear all stored credentials.
    func signOut() async throws {
        if let token = loadSession()?.accessToken {
            // Best-effort server sign out
            let url = URL(string: "\(supabaseURL)/auth/v1/logout")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status >= 400 {
                    logger.warning("Server sign out returned \(status), proceeding with local cleanup")
                }
            } catch {
                logger.warning("Server sign out failed: \(error.localizedDescription), proceeding with local cleanup")
            }
        }

        clearSession()
        logger.info("Signed out")
    }

    // MARK: - Token Exchange

    private func exchangeCodeForSession(code: String, codeVerifier: String) async throws -> CloudSession {
        let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=pkce")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body: [String: String] = [
            "auth_code": code,
            "code_verifier": codeVerifier,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard status >= 200, status < 300 else {
            let message = parseErrorMessage(from: data) ?? "HTTP \(status)"
            throw CloudAuthError.tokenExchangeFailed(message)
        }

        return try parseSessionResponse(data)
    }

    // MARK: - Token Refresh

    private func refreshSession(_ session: CloudSession) async throws -> CloudSession {
        let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=refresh_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body = ["refresh_token": session.refreshToken]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard status >= 200, status < 300 else {
            let message = parseErrorMessage(from: data) ?? "HTTP \(status)"
            logger.error("Token refresh failed: \(message)")
            throw CloudAuthError.refreshFailed(message)
        }

        logger.info("Token refreshed successfully")
        return try parseSessionResponse(data)
    }

    // MARK: - Response Parsing

    private func parseSessionResponse(_ data: Data) throws -> CloudSession {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Int,
              let user = json["user"] as? [String: Any],
              let userID = user["id"] as? String
        else {
            throw CloudAuthError.tokenExchangeFailed("Unexpected response format")
        }

        let email = user["email"] as? String ?? ""
        let expiresAt = Date.now.addingTimeInterval(TimeInterval(expiresIn))

        return CloudSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            userEmail: email,
            userID: userID
        )
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error_description"] as? String
            ?? json["msg"] as? String
            ?? json["message"] as? String
            ?? json["error"] as? String
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }

    // MARK: - Session Persistence (Keychain)

    private func saveSession(_ session: CloudSession) throws {
        try KeychainService.save(key: Keys.accessToken, value: session.accessToken)
        try KeychainService.save(key: Keys.refreshToken, value: session.refreshToken)
        try KeychainService.save(key: Keys.expiresAt, value: String(session.expiresAt.timeIntervalSince1970))
        try KeychainService.save(key: Keys.userEmail, value: session.userEmail)
        try KeychainService.save(key: Keys.userID, value: session.userID)
    }

    private func loadSession() -> CloudSession? {
        guard let accessToken = KeychainService.load(key: Keys.accessToken),
              let refreshToken = KeychainService.load(key: Keys.refreshToken),
              let expiresAtStr = KeychainService.load(key: Keys.expiresAt),
              let expiresAtInterval = Double(expiresAtStr),
              let userID = KeychainService.load(key: Keys.userID)
        else { return nil }

        let email = KeychainService.load(key: Keys.userEmail) ?? ""

        return CloudSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: expiresAtInterval),
            userEmail: email,
            userID: userID
        )
    }

    private func clearSession() {
        cachedSession = nil
        KeychainService.delete(key: Keys.accessToken)
        KeychainService.delete(key: Keys.refreshToken)
        KeychainService.delete(key: Keys.expiresAt)
        KeychainService.delete(key: Keys.userEmail)
        KeychainService.delete(key: Keys.userID)
    }
}

// MARK: - Base64 URL Encoding

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Cloud Auth State (SwiftUI Observable)

@Observable @MainActor
final class CloudAuthState {
    private(set) var isLoggedIn = false
    private(set) var userEmail: String?
    private(set) var isLoading = false

    private let auth = CloudAuthManager.shared

    /// Call on app launch to restore session state.
    func restore() {
        isLoading = true
        Task {
            let session = await auth.currentSession()
            self.isLoggedIn = session != nil
            self.userEmail = session?.userEmail
            self.isLoading = false
        }
    }

    func sendMagicLink(email: String) async throws {
        isLoading = true
        defer { isLoading = false }
        try await auth.sendMagicLink(email: email)
    }

    func handleCallback(url: URL) async throws {
        isLoading = true
        defer { isLoading = false }
        try await auth.handleCallback(url: url)
        let session = await auth.currentSession()
        isLoggedIn = session != nil
        userEmail = session?.userEmail
    }

    func signOut() async throws {
        isLoading = true
        defer { isLoading = false }
        try await auth.signOut()
        isLoggedIn = false
        userEmail = nil
    }
}
