import Foundation

enum MarkdownRenderer {
    static func attributedString(from markdown: String) -> AttributedString {
        let displayMarkdown = preserveSoftLineBreaks(in: markdown)
        do {
            return try AttributedString(
                markdown: displayMarkdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full
                )
            )
        } catch {
            return AttributedString(markdown)
        }
    }

    static func preserveSoftLineBreaks(in markdown: String) -> String {
        var result: [String] = []
        let lines = markdown.components(separatedBy: "\n")
        var inFence = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            let isLast = index == lines.count - 1

            result.append(line)

            if isFence {
                inFence.toggle()
            }

            guard !isLast else { continue }
            if inFence || isFence || trimmed.isEmpty || lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }

            if !line.hasSuffix("  ") {
                result[result.count - 1] += "  "
            }
        }

        return result.joined(separator: "\n")
    }

    static func displayBlocks(from markdown: String) -> [String] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let rawBlocks = normalized.components(separatedBy: "\n\n")
        var blocks: [String] = []
        for block in rawBlocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            blocks.append(contentsOf: splitLongPlainParagraph(trimmed))
        }
        return blocks
    }

    private static func splitLongPlainParagraph(_ paragraph: String) -> [String] {
        guard paragraph.count > 120, !isMarkdownStructure(paragraph) else {
            return [paragraph]
        }

        var blocks: [String] = []
        var current = ""
        for char in paragraph {
            current.append(char)
            if "。！？!?；;".contains(char), current.count >= 48 {
                blocks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            blocks.append(tail)
        }
        return blocks.isEmpty ? [paragraph] : blocks
    }

    private static func isMarkdownStructure(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("#")
                || trimmed.hasPrefix("- ")
                || trimmed.hasPrefix("* ")
                || trimmed.hasPrefix("> ")
                || trimmed.hasPrefix("```")
                || trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
        }
    }
}
