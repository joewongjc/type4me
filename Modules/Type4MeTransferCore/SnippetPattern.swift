import Foundation

/// How a snippet trigger matches dictated text, shared by the Mac and the
/// iPhone so a synced rule behaves the same on both.
public enum SnippetPattern {
    /// Builds a regex that matches the trigger case-insensitively and space-insensitively.
    /// Strips all whitespace from trigger, then inserts `\s*` between each character.
    /// Uses ASCII-only word boundaries (not `\b`) so CJK/Latin boundaries work correctly.
    public static func flexPattern(for trigger: String) -> String {
        let chars = trigger.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return NSRegularExpression.escapedPattern(for: trigger) }
        let core = chars.map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s*")
        return "(?<![a-zA-Z0-9])" + core + "(?![a-zA-Z0-9])"
    }

    /// Runs the rules in order, each over the previous one's output, the way
    /// the Mac applies its global snippets.
    public static func apply(_ snippets: [Type4MeTransferPayload.Snippet], to text: String) -> String {
        snippets.reduce(text) { result, snippet in
            guard let regex = try? NSRegularExpression(pattern: flexPattern(for: snippet.trigger), options: [.caseInsensitive])
            else { return result }
            let range = NSRange(result.startIndex..., in: result)
            return regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: snippet.replacement)
            )
        }
    }
}
