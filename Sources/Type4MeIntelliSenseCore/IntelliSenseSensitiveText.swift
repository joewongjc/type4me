import Foundation

/// Text that looks like a credential, a one-time code or a payment card
/// number. Context containing it
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
        // A one-time code: 4 to 8 digits near the word for it, either side.
        // Lookarounds instead of \b, which finds no edge between a digit
        // and a Chinese character.
        #"(?i)(?:验证码|校验码|动态码|动态密码|确认码|verification code|security code|one[- ]time (?:code|password)|\bOTP\b|\bcode\b)[^0-9\n]{0,12}(?<!\d)\d{4,8}(?!\d)"#,
        #"(?i)(?<!\d)\d{4,8}(?!\d)[^0-9\n]{0,12}(?:验证码|校验码|动态码|动态密码|确认码|verification code|security code|one[- ]time (?:code|password)|\bOTP\b|\bcode\b)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// 13 to 19 digits, optionally grouped by spaces or hyphens.
    private static let cardCandidate = try? NSRegularExpression(pattern: #"(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)"#)

    public static func containsSensitiveContent(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if expressions.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return true }
        return containsCardNumber(text, range: range)
    }

    /// A payment card number: a run of digits that passes the Luhn check,
    /// so order numbers and phone numbers mostly don't count.
    private static func containsCardNumber(_ text: String, range: NSRange) -> Bool {
        guard let cardCandidate else { return false }
        return cardCandidate.matches(in: text, range: range).contains { match in
            guard let span = Range(match.range, in: text) else { return false }
            let digits = text[span].compactMap(\.wholeNumberValue)
            return (13...19).contains(digits.count) && passesLuhn(digits)
        }
    }

    private static func passesLuhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }
}
