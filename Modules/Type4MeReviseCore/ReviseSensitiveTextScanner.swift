import Foundation

public enum ReviseSensitiveTextScanner {
    private static let sensitivePatterns = [
        #"(?i)\b(?:api[_-]?key|secret|access[_-]?token|password|auth[_-]?token)\b\s*[:=]\s*[^\s]+"#,
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{12,}={0,2}"#,
        #"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----"#,
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{36}\b"#,
        #"\bsk-(?:proj-|live-)?[A-Za-z0-9]{32,}\b"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
    ]

    public static func containsSensitiveContent(_ text: String) -> Bool {
        for pattern in sensitivePatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
}
