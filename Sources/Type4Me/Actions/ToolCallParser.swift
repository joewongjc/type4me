import Foundation

struct ParsedToolCall: Equatable {
    let name: String
    let arguments: [String: Any]

    static func == (lhs: ParsedToolCall, rhs: ParsedToolCall) -> Bool {
        guard lhs.name == rhs.name else { return false }
        let lhsData = try? JSONSerialization.data(withJSONObject: lhs.arguments)
        let rhsData = try? JSONSerialization.data(withJSONObject: rhs.arguments)
        return lhsData == rhsData
    }
}

/// Extracts a `<tool_call>{...}</tool_call>` block from raw LLM output and decodes the JSON.
///
/// Handles a few common variants:
/// - Standard: `<tool_call>{"name": "x", "arguments": {...}}</tool_call>`
/// - Wrapped in a fenced code block (```json ... ```)
/// - Bare JSON when the model omits the XML tags
enum ToolCallParser {

    static func parse(_ rawLLMOutput: String) -> ParsedToolCall? {
        let cleaned = rawLLMOutput.strippingThinkTags()

        // Standard form: <tool_call>{...}</tool_call>
        if let between = extractBetween(cleaned, start: "<tool_call>", end: "</tool_call>"),
           let parsed = parseJSON(between) {
            return parsed
        }

        // Tolerant form: <tool_call>{...}  (LLM omits the closing tag)
        if let openRange = cleaned.range(of: "<tool_call>") {
            let after = String(cleaned[openRange.upperBound...])
            if let parsed = parseJSONPrefix(after) {
                return parsed
            }
        }

        if let fenced = extractCodeFenceJSON(cleaned),
           let parsed = parseJSON(fenced) {
            return parsed
        }

        // Bare JSON fallback: trim and try the whole reply.
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let parsed = parseJSONPrefix(trimmed) {
            return parsed
        }

        return nil
    }

    // MARK: - Helpers

    private static func extractBetween(_ text: String, start: String, end: String) -> String? {
        guard let startRange = text.range(of: start),
              let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex)
        else { return nil }
        return String(text[startRange.upperBound..<endRange.lowerBound])
    }

    private static func extractCodeFenceJSON(_ text: String) -> String? {
        // Match ```json ... ``` or ``` ... ``` blocks
        let pattern = #"```(?:json)?\s*([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func parseJSON(_ jsonText: String) -> ParsedToolCall? {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String, !name.isEmpty
        else { return nil }
        let args = (object["arguments"] as? [String: Any]) ?? [:]
        return ParsedToolCall(name: name, arguments: args)
    }

    /// Parse a JSON object from the start of the string, ignoring trailing junk.
    /// Walks the input character-by-character tracking brace depth and string-literal
    /// boundaries (with escape handling), then hands the matched substring to JSONSerialization.
    /// Used when the LLM omits the closing `</tool_call>` tag.
    private static func parseJSONPrefix(_ text: String) -> ParsedToolCall? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        var endIndex: String.Index? = nil

        for idx in trimmed.indices {
            let ch = trimmed[idx]
            if escape {
                escape = false
                continue
            }
            if inString {
                if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    endIndex = trimmed.index(after: idx)
                    break
                }
            }
        }

        guard let end = endIndex else { return nil }
        return parseJSON(String(trimmed[trimmed.startIndex..<end]))
    }
}
