import Foundation
import CryptoKit

enum TencentCloudSigner {

    // MARK: - WebSocket HMAC-SHA1 (Realtime V2)

    /// Builds a signed WebSocket URL for Tencent Cloud Realtime ASR V2.
    static func signedWebSocketURL(
        appId: String,
        secretId: String,
        secretKey: String,
        parameters: [String: String],
        timestamp: Int,
        expiresIn: Int = 86400,
        nonce: Int,
        voiceId: String
    ) throws -> URL {
        var queryParams = parameters
        queryParams["secretid"] = secretId
        queryParams["timestamp"] = String(timestamp)
        queryParams["expired"] = String(timestamp + expiresIn)
        queryParams["nonce"] = String(nonce)
        queryParams["voice_id"] = voiceId

        // Sort keys alphabetically
        let sortedKeys = queryParams.keys.sorted()
        let plainQuery = sortedKeys.map { key in
            "\(key)=\(queryParams[key]!)"
        }.joined(separator: "&")

        let signHostAndPath = "asr.cloud.tencent.com/asr/v2/\(appId)"
        let plainText = "\(signHostAndPath)?\(plainQuery)"

        let key = SymmetricKey(data: Data(secretKey.utf8))
        let signatureData = HMAC<Insecure.SHA1>.authenticationCode(for: Data(plainText.utf8), using: key)
        let signature = Data(signatureData).base64EncodedString()

        // Encode parameters and signature for the final URL query
        var finalAllowed = CharacterSet.urlQueryAllowed
        finalAllowed.remove(charactersIn: "+/=&?")

        var finalQueryComponents: [String] = []
        for key in sortedKeys {
            let val = queryParams[key]!
            let encodedVal = val.addingPercentEncoding(withAllowedCharacters: finalAllowed) ?? val
            finalQueryComponents.append("\(key)=\(encodedVal)")
        }

        let encodedSig = signature.addingPercentEncoding(withAllowedCharacters: finalAllowed) ?? signature
        finalQueryComponents.append("signature=\(encodedSig)")

        let finalURLString = "wss://\(signHostAndPath)?\(finalQueryComponents.joined(separator: "&"))"
        guard let url = URL(string: finalURLString) else {
            throw TencentASRError.invalidURL
        }
        return url
    }

    // MARK: - API 3.0 TC3-HMAC-SHA256 (RecTask)

    static func signedAPIRequest(
        action: String,
        payload: Data,
        secretId: String,
        secretKey: String,
        timestamp: Int
    ) -> URLRequest {
        let host = "asr.tencentcloudapi.com"
        let service = "asr"
        let version = "2019-06-14"
        let url = URL(string: "https://\(host)")!

        // Date in UTC: yyyy-MM-dd
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))

        // 1. Canonical request
        let httpRequestMethod = "POST"
        let canonicalURI = "/"
        let canonicalQueryString = ""
        let canonicalHeaders = "content-type:application/json; charset=utf-8\nhost:\(host)\n"
        let signedHeaders = "content-type;host"
        let hashedRequestPayload = SHA256.hash(data: payload).hexString
        let canonicalRequest = "\(httpRequestMethod)\n\(canonicalURI)\n\(canonicalQueryString)\n\(canonicalHeaders)\n\(signedHeaders)\n\(hashedRequestPayload)"

        // 2. String to sign
        let algorithm = "TC3-HMAC-SHA256"
        let credentialScope = "\(date)/\(service)/tc3_request"
        let hashedCanonicalRequest = SHA256.hash(data: Data(canonicalRequest.utf8)).hexString
        let stringToSign = "\(algorithm)\n\(timestamp)\n\(credentialScope)\n\(hashedCanonicalRequest)"

        // 3. Derived signing key
        let secretDate = hmacSHA256(key: Data("TC3\(secretKey)".utf8), data: Data(date.utf8))
        let secretService = hmacSHA256(key: secretDate, data: Data(service.utf8))
        let secretSigning = hmacSHA256(key: secretService, data: Data("tc3_request".utf8))

        // 4. Signature
        let signature = hmacSHA256(key: secretSigning, data: Data(stringToSign.utf8)).hexString

        // 5. Authorization header
        let authorization = "\(algorithm) Credential=\(secretId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: url)
        request.httpMethod = httpRequestMethod
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = BatchASRHTTP.requestTimeout
        request.httpBody = payload
        return request
    }

    private static func hmacSHA256(key: Data, data: Data) -> Data {
        let symKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symKey)
        return Data(mac)
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
