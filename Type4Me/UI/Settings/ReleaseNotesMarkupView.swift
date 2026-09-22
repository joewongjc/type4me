import SwiftUI

enum ReleaseNotesBlock: Equatable {
    case markdown(String)
    case image(url: URL, altText: String?)
}

enum ReleaseNotesMarkupParser {

    static func blocks(from source: String) -> [ReleaseNotesBlock] {
        let imageRegex = try? NSRegularExpression(
            pattern: #"<img\b[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = imageRegex?.matches(in: source, options: [], range: fullRange) ?? []

        var blocks: [ReleaseNotesBlock] = []
        var cursor = source.startIndex

        for match in matches {
            guard let tagRange = Range(match.range, in: source) else { continue }
            appendMarkdown(String(source[cursor..<tagRange.lowerBound]), to: &blocks)

            let tag = String(source[tagRange])
            if let url = attribute(named: "src", in: tag), let imageURL = URL(string: url) {
                blocks.append(.image(url: imageURL, altText: attribute(named: "alt", in: tag)))
            } else {
                appendMarkdown(tag, to: &blocks)
            }
            cursor = tagRange.upperBound
        }

        appendMarkdown(String(source[cursor...]), to: &blocks)
        return blocks
    }

    private static func appendMarkdown(_ source: String, to blocks: inout [ReleaseNotesBlock]) {
        let normalized = normalizeHTML(in: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        blocks.append(.markdown(normalized))
    }

    private static func attribute(named name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(src|alt)\s*=\s*([\"'])(.*?)\2"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }

        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        for match in regex.matches(in: tag, options: [], range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag),
                  String(tag[nameRange]).caseInsensitiveCompare(name) == .orderedSame,
                  let valueRange = Range(match.range(at: 3), in: tag)
            else { continue }
            return String(tag[valueRange])
        }
        return nil
    }

    private static func normalizeHTML(in source: String) -> String {
        var result = source
        let replacements: [(String, String)] = [
            (#"(?is)<br\s*/?>"#, "\n"),
            (#"(?is)<h1\b[^>]*>"#, "# "),
            (#"(?is)</h1\s*>"#, "\n\n"),
            (#"(?is)<h2\b[^>]*>"#, "## "),
            (#"(?is)</h2\s*>"#, "\n\n"),
            (#"(?is)<h3\b[^>]*>"#, "### "),
            (#"(?is)</h3\s*>"#, "\n\n"),
            (#"(?is)<p\b[^>]*>"#, ""),
            (#"(?is)</p\s*>"#, "\n\n"),
            (#"(?is)<div\b[^>]*>"#, ""),
            (#"(?is)</div\s*>"#, "\n\n"),
            (#"(?is)<li\b[^>]*>"#, "- "),
            (#"(?is)</li\s*>"#, "\n"),
            (#"(?is)<[^>]+>"#, ""),
        ]

        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }

        return decodeCommonHTMLEntities(result)
    }

    private static func decodeCommonHTMLEntities(_ source: String) -> String {
        var result = source
        let entities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&#x27;": "'",
        ]
        for (entity, value) in entities {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }
}

struct ReleaseNotesMarkupView: View {

    let markup: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ReleaseNotesMarkupParser.blocks(from: markup).enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let text):
                    markdownText(text)
                case .image(let url, let altText):
                    releaseImage(url: url, altText: altText)
                }
            }
        }
    }

    @ViewBuilder
    private func markdownText(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, rawLine in
                let line = String(rawLine)
                if line.isEmpty {
                    Spacer().frame(height: 4)
                } else if let heading = headingContent(in: line) {
                    inlineMarkdown(heading.text)
                        .font(.system(size: heading.fontSize, weight: .semibold))
                        .padding(.top, 3)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("•")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TF.settingsTextSecondary)
                        inlineMarkdown(String(line.dropFirst(2)))
                    }
                } else {
                    inlineMarkdown(line)
                }
            }
        }
    }

    private func inlineMarkdown(_ text: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextSecondary)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextSecondary)
                .textSelection(.enabled)
        }
    }

    private func headingContent(in line: String) -> (text: String, fontSize: CGFloat)? {
        if line.hasPrefix("### ") { return (String(line.dropFirst(4)), 13) }
        if line.hasPrefix("## ") { return (String(line.dropFirst(3)), 14) }
        if line.hasPrefix("# ") { return (String(line.dropFirst(2)), 15) }
        return nil
    }

    private func releaseImage(url: URL, altText: String?) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 900, maxHeight: 480)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, alignment: .center)
            case .failure:
                Text(altText ?? L("图片加载失败", "Image failed to load"))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            case .empty:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
            @unknown default:
                EmptyView()
            }
        }
    }
}
