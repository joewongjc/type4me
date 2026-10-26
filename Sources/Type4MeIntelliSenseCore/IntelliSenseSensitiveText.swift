import Foundation

/// Text that looks like a credential or a one-time code. Context containing it
/// never reaches the text model, on the Mac or the iPhone.
public enum IntelliSenseSensitiveTextScanner {
    private static let expressions: [NSRegularExpression] = [
        #"(?i)\b(?:api[_-]?key|secret|access[_-]?token|refresh[_-]?token|client[_-]?secret)\b\s*[:=]"#,
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{12,}={0,2}"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
        #"-----BEGIN(?: [A-Z0-9]+)? (?:PRIVATE KEY|CERTIFICATE)-----"#,
        #"\b(?:AKIA|ASIA|AIza|ghp_|github_pat_|sk-|xox[baprs]-)[A-Za-z0-9_\-]{12,}\b"#,
        #"\b[a-fA-F0-9]{48,}\b"#,
        #"\b[A-Za-z0-9+/]{64,}={0,2}\b"#,
        #"(?i)\b(?:password|passwd|verification[_ -]?code|验证码)\b\s*[:=：]"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func containsSensitiveContent(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expressions.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}
