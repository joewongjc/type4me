import Foundation
import CommonCrypto
import os

/// Manages Volcengine boosting tables (hotword lists) via REST API.
/// Auth: IAM AK/SK with HMAC-SHA256 signing.
/// Docs: https://www.volcengine.com/docs/6561/1742791
actor VolcBoostingTableManager {

    static let shared = VolcBoostingTableManager()

    private let logger = Logger(subsystem: "com.type4me.hotwords", category: "VolcBoostingTableManager")

    private let host = "open.volcengineapi.com"
    private let region = "cn-north-1"
    private let service = "speech_saas_prod"
    private let apiVersion = "2022-08-30"

    // MARK: - Credentials

    struct IAMCredentials: Sendable {
        let accessKeyId: String
        let secretAccessKey: String
        let appID: String  // same as VolcanoASRConfig.appKey
    }

    /// Load IAM credentials from Volcano ASR credential store.
    nonisolated func loadCredentials() -> IAMCredentials? {
        guard let values = KeychainService.loadASRCredentials(for: .volcano),
              let ak = values["iamAccessKeyId"], !ak.isEmpty,
              let sk = values["iamSecretAccessKey"], !sk.isEmpty,
              let appKey = values["appKey"], !appKey.isEmpty
        else { return nil }
        return IAMCredentials(accessKeyId: ak, secretAccessKey: sk, appID: appKey)
    }

    // MARK: - Public API

    struct BoostingTable: Sendable {
        let tableID: String
        let tableName: String
        let wordCount: Int
        let preview: [String]
    }

    func listTables(credentials: IAMCredentials) async throws -> [BoostingTable] {
        let body: [String: Any] = [
            "Action": "ListBoostingTable",
            "Version": apiVersion,
            "AppID": Int(credentials.appID) ?? 0,
            "PageNumber": 1,
            "PageSize": 100,
            "PreviewSize": 5,
        ]
        let data = try await signedRequest(
            action: "ListBoostingTable",
            credentials: credentials,
            body: body
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["Result"] as? [String: Any],
              let tables = result["BoostingTables"] as? [[String: Any]]
        else { return [] }

        return tables.compactMap { dict in
            guard let id = dict["BoostingTableID"] as? String,
                  let name = dict["BoostingTableName"] as? String
            else { return nil }
            return BoostingTable(
                tableID: id,
                tableName: name,
                wordCount: dict["WordCount"] as? Int ?? 0,
                preview: dict["Preview"] as? [String] ?? []
            )
        }
    }

    /// Create a new boosting table. Returns the table ID.
    func createTable(
        credentials: IAMCredentials,
        name: String,
        words: [String]
    ) async throws -> String {
        let fileContent = words.joined(separator: "\n")
        let data = try await multipartRequest(
            action: "CreateBoostingTable",
            credentials: credentials,
            fields: [
                "AppID": String(credentials.appID),
                "BoostingTableName": name,
            ],
            fileContent: fileContent
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["Result"] as? [String: Any],
              let tableID = result["BoostingTableID"] as? String
        else {
            throw VolcHotwordError.invalidResponse
        }
        logger.info("Created boosting table: \(tableID, privacy: .public) with \(words.count) words")
        return tableID
    }

    /// Update an existing boosting table (full replacement).
    func updateTable(
        credentials: IAMCredentials,
        tableID: String,
        words: [String]
    ) async throws {
        let fileContent = words.joined(separator: "\n")
        _ = try await multipartRequest(
            action: "UpdateBoostingTable",
            credentials: credentials,
            fields: [
                "AppID": String(credentials.appID),
                "BoostingTableID": tableID,
            ],
            fileContent: fileContent
        )
        logger.info("Updated boosting table \(tableID, privacy: .public) with \(words.count) words")
    }

    // MARK: - Signing

    private func signedRequest(
        action: String,
        credentials: IAMCredentials,
        body: [String: Any]
    ) async throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let payloadString = String(data: payload, encoding: .utf8)!
        let query = "Action=\(action)&Version=\(apiVersion)"
        let contentType = "application/json; charset=utf-8"

        let now = Date()
        let dateStamp = Self.formatDate(now, format: "yyyyMMdd")
        let dateTime = Self.formatDate(now, format: "yyyyMMdd'T'HHmmss'Z'")

        let payloadHash = Self.sha256Hex(payloadString)
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\nx-content-sha256:\nx-date:\(dateTime)\n"
        let signedHeaders = "content-type;host;x-content-sha256;x-date"

        let canonicalRequest = "POST\n/\n\(query)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let credentialScope = "\(dateStamp)/\(region)/\(service)/request"
        let stringToSign = "HMAC-SHA256\n\(dateTime)\n\(credentialScope)\n\(Self.sha256Hex(canonicalRequest))"

        let signingKey = Self.deriveSigningKey(
            secret: credentials.secretAccessKey,
            date: dateStamp,
            region: region,
            service: service
        )
        let signature = Self.hmacSHA256Hex(key: signingKey, data: stringToSign)

        let authorization = "HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: URL(string: "https://\(host)/?\(query)")!)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(dateTime, forHTTPHeaderField: "X-Date")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkResponse(data: data, response: response, action: action)
        return data
    }

    private func multipartRequest(
        action: String,
        credentials: IAMCredentials,
        fields: [String: String],
        fileContent: String
    ) async throws -> Data {
        let boundary = "----Type4MeBoundary\(UUID().uuidString)"
        var parts: [String] = []

        // Action and Version as form fields
        let allFields = fields.merging(["Action": action, "Version": apiVersion]) { current, _ in current }
        for (name, value) in allFields {
            parts.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)")
        }

        // File part
        parts.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"File\"; filename=\"hotwords.txt\"\r\nContent-Type: text/plain\r\n\r\n\(fileContent)")
        parts.append("--\(boundary)--")

        let bodyString = parts.joined(separator: "\r\n")
        let bodyData = bodyString.data(using: .utf8)!
        let contentType = "multipart/form-data; boundary=\(boundary)"

        let query = "Action=\(action)&Version=\(apiVersion)"

        let now = Date()
        let dateStamp = Self.formatDate(now, format: "yyyyMMdd")
        let dateTime = Self.formatDate(now, format: "yyyyMMdd'T'HHmmss'Z'")

        let payloadHash = Self.sha256HexData(bodyData)
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\nx-content-sha256:\nx-date:\(dateTime)\n"
        let signedHeaders = "content-type;host;x-content-sha256;x-date"

        let canonicalRequest = "POST\n/\n\(query)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let credentialScope = "\(dateStamp)/\(region)/\(service)/request"
        let stringToSign = "HMAC-SHA256\n\(dateTime)\n\(credentialScope)\n\(Self.sha256Hex(canonicalRequest))"

        let signingKey = Self.deriveSigningKey(
            secret: credentials.secretAccessKey,
            date: dateStamp,
            region: region,
            service: service
        )
        let signature = Self.hmacSHA256Hex(key: signingKey, data: stringToSign)
        let authorization = "HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: URL(string: "https://\(host)/?\(query)")!)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(dateTime, forHTTPHeaderField: "X-Date")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkResponse(data: data, response: response, action: action)
        return data
    }

    // MARK: - Crypto helpers

    private static func hmacSHA256(key: Data, data: String) -> Data {
        let dataBytes = Array(data.utf8)
        var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyPtr.baseAddress, key.count, dataBytes, dataBytes.count, &result)
        }
        return Data(result)
    }

    private static func hmacSHA256Hex(key: Data, data: String) -> String {
        hmacSHA256(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ string: String) -> String {
        sha256HexData(Data(string.utf8))
    }

    private static func sha256HexData(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func deriveSigningKey(secret: String, date: String, region: String, service: String) -> Data {
        let kDate = hmacSHA256(key: Data(secret.utf8), data: date)
        let kRegion = hmacSHA256(key: kDate, data: region)
        let kService = hmacSHA256(key: kRegion, data: service)
        return hmacSHA256(key: kService, data: "request")
    }

    private static func formatDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    // MARK: - Response handling

    private static func checkResponse(data: Data, response: URLResponse, action: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VolcHotwordError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var message = "HTTP \(http.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let meta = json["ResponseMetadata"] as? [String: Any],
               let error = meta["Error"] as? [String: Any] {
                let code = error["Code"] as? String ?? "Unknown"
                let msg = error["Message"] as? String ?? ""
                message = "\(code): \(msg)"
            }
            throw VolcHotwordError.apiError(action: action, message: message)
        }
    }
}

enum VolcHotwordError: Error, LocalizedError {
    case noCredentials
    case invalidResponse
    case apiError(action: String, message: String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return L("未配置火山引擎 IAM 凭证", "Volcengine IAM credentials not configured")
        case .invalidResponse:
            return L("火山引擎 API 返回无效", "Invalid response from Volcengine API")
        case .apiError(let action, let message):
            return L("\(action) 失败：\(message)", "\(action) failed: \(message)")
        }
    }
}
