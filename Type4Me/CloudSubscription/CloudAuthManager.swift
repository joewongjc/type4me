// Type4Me/Auth/CloudAuthManager.swift

import Foundation
import os

enum LoginMethod: String {
    case email
    case anonymous
}

@MainActor
final class CloudAuthManager: ObservableObject, Sendable {
    static let shared = CloudAuthManager()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var userEmail: String?
    @Published private(set) var userID: String?
    @Published private(set) var username: String?
    @Published private(set) var loginMethod: LoginMethod?

    private let logger = Logger(subsystem: "com.type4me.app", category: "CloudAuth")

    // JWT stored in UserDefaults — security is enforced by device binding,
    // not token expiry. See docs/plans/2026-04-04-account-page-design.md
    private var jwt: String? {
        get { UserDefaults.standard.string(forKey: "tf_cloud_jwt") }
        set { UserDefaults.standard.set(newValue, forKey: "tf_cloud_jwt") }
    }

    private init() {
        // Restore session from stored JWT
        if let token = jwt, !isTokenExpired(token) {
            isLoggedIn = true
            userEmail = UserDefaults.standard.string(forKey: "tf_cloud_email")
            userID = UserDefaults.standard.string(forKey: "tf_cloud_user_id")
            username = UserDefaults.standard.string(forKey: "tf_cloud_username")
            if let method = UserDefaults.standard.string(forKey: "tf_cloud_login_method") {
                loginMethod = LoginMethod(rawValue: method)
            }
        }
    }

    func sendCode(email: String) async throws {
        struct SendCodeRequest: Encodable { let email: String; let device_id: String }
        let body = try JSONEncoder().encode(SendCodeRequest(email: email, device_id: CloudAPIClient.shared.deviceID))
        let data = try await CloudAPIClient.shared.request(
            "/auth/send-code", method: "POST", body: body, requiresAuth: false
        )
        _ = data
    }

    func verify(email: String, code: String) async throws {
        struct VerifyRequest: Encodable { let email: String; let code: String; let device_id: String }
        let body = try JSONEncoder().encode(VerifyRequest(email: email, code: code, device_id: CloudAPIClient.shared.deviceID))
        let data = try await CloudAPIClient.shared.request(
            "/auth/verify", method: "POST", body: body, requiresAuth: false
        )

        struct VerifyResponse: Decodable { let token: String; let user_id: String; let email: String }
        let result = try JSONDecoder().decode(VerifyResponse.self, from: data)

        saveSession(token: result.token, userID: result.user_id,
                    email: result.email, username: nil, method: .email)
    }

    func registerAnonymous(username: String, password: String) async throws {
        struct RegisterRequest: Encodable {
            let username: String
            let password: String
            let device_id: String
        }
        let body = try JSONEncoder().encode(RegisterRequest(
            username: username, password: password,
            device_id: CloudAPIClient.shared.deviceID
        ))
        let data = try await CloudAPIClient.shared.request(
            "/auth/register", method: "POST", body: body, requiresAuth: false
        )

        struct RegisterResponse: Decodable {
            let token: String; let user_id: String; let username: String
        }
        let result = try JSONDecoder().decode(RegisterResponse.self, from: data)

        saveSession(token: result.token, userID: result.user_id,
                    email: nil, username: result.username, method: .anonymous)
    }

    func loginWithPassword(username: String, password: String) async throws {
        struct LoginRequest: Encodable {
            let username: String
            let password: String
            let device_id: String
        }
        let body = try JSONEncoder().encode(LoginRequest(
            username: username, password: password,
            device_id: CloudAPIClient.shared.deviceID
        ))
        let data = try await CloudAPIClient.shared.request(
            "/auth/login", method: "POST", body: body, requiresAuth: false
        )

        struct LoginResponse: Decodable {
            let token: String; let user_id: String; let username: String
            let email: String?
        }
        let result = try JSONDecoder().decode(LoginResponse.self, from: data)

        saveSession(token: result.token, userID: result.user_id,
                    email: result.email, username: result.username, method: .anonymous)
    }

    func accessToken() async -> String? {
        guard let token = jwt, !isTokenExpired(token) else {
            isLoggedIn = false
            return nil
        }
        return token
    }

    func signOut() async {
        jwt = nil
        for key in ["tf_cloud_email", "tf_cloud_user_id",
                    "tf_cloud_username", "tf_cloud_login_method"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        isLoggedIn = false
        userEmail = nil
        userID = nil
        username = nil
        loginMethod = nil
    }

    // MARK: - Private

    private func saveSession(token: String, userID: String,
                             email: String?, username: String?,
                             method: LoginMethod) {
        jwt = token
        UserDefaults.standard.set(email, forKey: "tf_cloud_email")
        UserDefaults.standard.set(userID, forKey: "tf_cloud_user_id")
        UserDefaults.standard.set(username, forKey: "tf_cloud_username")
        UserDefaults.standard.set(method.rawValue, forKey: "tf_cloud_login_method")
        isLoggedIn = true
        self.userEmail = email
        self.userID = userID
        self.username = username
        self.loginMethod = method
    }

    // Check JWT expiry without verifying signature (client-side only)
    private func isTokenExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let exp = payload["exp"] as? TimeInterval else {
            return true
        }
        return Date().timeIntervalSince1970 > exp
    }
}

// Base64URL decoding helper
private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}

enum CloudAuthError: Error, LocalizedError {
    case notConfigured
    case invalidCode
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Type4Me Cloud is not configured"
        case .invalidCode: return "Invalid or expired verification code"
        case .serverError(let msg): return "Server error: \(msg)"
        }
    }
}
