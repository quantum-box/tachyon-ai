import SwiftUI

/// Renders the Markdown an agent writes: headings, lists, code blocks, quotes, tables.
///
/// SwiftUI's own Markdown support only covers inline styles, so the block structure
/// is parsed here and each block is laid out as its own view.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ source: String) {
        blocks = MarkdownBlock.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text)).textSelection(.enabled)
        case .heading(let level, let text):
            Text(Self.inline(text))
                .zoomedFont(Self.headingSize(level), weight: level == 1 ? .bold : .semibold)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 0)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(Self.inline(text)).textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 16)
            // List items sit closer together than paragraphs.
            .padding(.top, -6)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .zoomedFont(.callout, design: .monospaced)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.28)))
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(.secondary).frame(width: 3)
                }
        case .rule:
            Divider()
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell))
                                .fontWeight(index == 0 ? .semibold : .regular)
                                .textSelection(.enabled)
                        }
                    }
                    if index == 0 {
                        Divider()
                    }
                }
            }
        }
    }

    private static func headingSize(_ level: Int) -> TextSize {
        switch level {
        case 1: return .title2
        case 2: return .title3
        default: return .body
        }
    }

    /// Bold, italics, inline code, links.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(indent: Int, marker: String, text: String)
    case code(String)
    case quote(String)
    case rule
    case table([[String]])

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [[String]] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
            if !table.isEmpty {
                blocks.append(.table(table))
                table = []
            }
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }

            if trimmed.isEmpty {
                flush()
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
            } else if trimmed.count >= 3, Set(trimmed).isSubset(of: ["-", "*", "_"]), Set(trimmed).count == 1 {
                flush()
                blocks.append(.rule)
            } else if let item = listItem(line) {
                flush()
                blocks.append(item)
            } else if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 1 {
                if table.isEmpty { flush() }
                let cells = trimmed.dropFirst().dropLast().components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // The `|---|---|` line only separates the header from the body.
                let isSeparator = cells.allSatisfy { !$0.isEmpty && Set($0).isSubset(of: ["-", ":"]) }
                if !isSeparator { table.append(cells) }
            } else {
                if !quote.isEmpty || !table.isEmpty { flush() }
                paragraph.append(trimmed)
            }
        }
        // A reply still streaming may end inside an unclosed code block.
        if let open = code {
            blocks.append(.code(open.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let body = line.dropFirst(leading.count)

        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            return .listItem(indent: indent, marker: "•", text: String(body.dropFirst(2)))
        }
        let digits = body.prefix { $0.isNumber }
        let rest = body.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 3, rest.hasPrefix(". ") || rest.hasPrefix(") ") {
            return .listItem(indent: indent, marker: "\(digits).", text: String(rest.dropFirst(2)))
        }
        return nil
    }
}
