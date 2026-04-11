import Foundation
import os

enum CloudAPIError: Error, LocalizedError {
    case deviceConflict
    case tokenExpired
    case invalidCredentials
    case usernameTaken
    case serverError(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .deviceConflict: return L("账户已在其他设备登录", "Account logged in on another device")
        case .tokenExpired: return L("登录已过期，请重新登录", "Session expired, please log in again")
        case .invalidCredentials: return L("用户名或密码错误", "Invalid username or password")
        case .usernameTaken: return L("用户名已被占用", "Username already exists")
        case .serverError(let msg): return msg
        case .networkError(let err): return err.localizedDescription
        }
    }
}

@MainActor
final class CloudAPIClient {
    static let shared = CloudAPIClient()

    let deviceID: String
    private let logger = Logger(subsystem: "com.type4me.app", category: "CloudAPI")

    private init() {
        deviceID = DeviceIdentifier.deviceID
    }

    func request(
        _ endpoint: String,
        method: String = "GET",
        body: Data? = nil,
        requiresAuth: Bool = true
    ) async throws -> Data {
        let url = URL(string: CloudConfig.apiEndpoint + endpoint)!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")

        if requiresAuth {
            guard let token = await CloudAuthManager.shared.accessToken() else {
                throw CloudAPIError.tokenExpired
            }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            req.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CloudAPIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.serverError("Invalid response")
        }

        if http.statusCode == 401 {
            try await handleUnauthorized(data)
        }

        if http.statusCode == 409 {
            if let errBody = try? JSONDecoder().decode(ErrorResponse.self, from: data),
               errBody.error == "username_taken" {
                throw CloudAPIError.usernameTaken
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudAPIError.serverError("HTTP \(http.statusCode): \(body)")
        }

        return data
    }

    private func handleUnauthorized(_ data: Data) async throws -> Never {
        let errBody = try? JSONDecoder().decode(ErrorResponse.self, from: data)

        switch errBody?.error {
        case "device_conflict":
            await CloudAuthManager.shared.signOut()
            NotificationCenter.default.post(name: .cloudDeviceConflict, object: nil)
            throw CloudAPIError.deviceConflict

        case "invalid_credentials":
            throw CloudAPIError.invalidCredentials

        default:
            await CloudAuthManager.shared.signOut()
            throw CloudAPIError.tokenExpired
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String
        let message: String?
    }
}

extension Notification.Name {
    static let cloudDeviceConflict = Notification.Name("cloudDeviceConflict")
}
