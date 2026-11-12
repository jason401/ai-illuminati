import SwiftUI

// Chat replies in Markdown: headings, tables and rules become their own pieces, the rest stays
// inline text (bold, italics, code, links) with its line breaks. Code fences are left as written.
enum ChatMarkdown {
    enum Block: Equatable {
        case text(String)
        case heading(level: Int, text: String)
        case table(header: [String], rows: [[String]])
        case rule
    }

    static func blocks(_ source: String) -> [Block] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [Block] = []
        var text: [String] = []
        var fence: String?
        func flush() {
            while text.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { text.removeFirst() }
            while text.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { text.removeLast() }
            if !text.isEmpty { blocks.append(.text(text.joined(separator: "\n"))) }
            text = []
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                text.append(line)
                if trimmed.hasPrefix(open) && trimmed.allSatisfy({ $0 == open.first }) { fence = nil }
                i += 1; continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(while: { $0 == trimmed.first }))
                text.append(line); i += 1; continue
            }
            if let heading = heading(line) {
                flush(); blocks.append(heading); i += 1; continue
            }
            if isRule(line) {
                flush(); blocks.append(.rule); i += 1; continue
            }
            if i + 1 < lines.count, line.contains("|"), let width = separatorWidth(lines[i + 1]) {
                let header = cells(line)
                if header.count == width {
                    var rows: [[String]] = []
                    var j = i + 2
                    while j < lines.count, lines[j].contains("|"), !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                        var row = cells(lines[j])
                        if row.count < width { row += Array(repeating: "", count: width - row.count) }
                        rows.append(Array(row.prefix(width)))
                        j += 1
                    }
                    flush(); blocks.append(.table(header: header, rows: rows)); i = j; continue
                }
            }
            text.append(line); i += 1
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> Block? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let level = rest.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var body = after.trimmingCharacters(in: .whitespaces)
        // A closing run of # is decoration.
        let closing = body.reversed().prefix(while: { $0 == "#" }).count
        if closing > 0, closing == body.count || body.dropLast(closing).last == " " {
            body = String(body.dropLast(closing)).trimmingCharacters(in: .whitespaces)
        }
        return .heading(level: level, text: body)
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " && $0 != "\t" }
        guard line.prefix(while: { $0 == " " }).count <= 3, marks.count >= 3, let mark = marks.first, "-*_".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    // The |---|:---:| line under a table's header; its number of columns.
    private static func separatorWidth(_ line: String) -> Int? {
        guard line.contains("|") else { return nil }
        let parts = cells(line)
        guard !parts.isEmpty else { return nil }
        for part in parts {
            var core = Substring(part)
            if core.first == ":" { core = core.dropFirst() }
            if core.last == ":" { core = core.dropLast() }
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
        }
        return parts.count
    }

    // Splits a table line on | outside code and not escaped.
    static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = [], current = "", code = 0
        var chars = Array(row)[...]
        while let c = chars.popFirst() {
            if c == "\\", chars.first == "|" {
                current.append("|"); chars.removeFirst()
            } else if c == "`" {
                var run = 1
                while chars.first == "`" { run += 1; chars.removeFirst() }
                current += String(repeating: "`", count: run)
                code = code == 0 ? run : (code == run ? 0 : code)
            } else if c == "|" && code == 0 {
                cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else {
                current.append(c)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // One ~ alone is not strikethrough in a chat reply: "2~4GB … 10~20s" stays as written.
    // ~~ pairs still strike through, and code is left untouched.
    static func escapingSingleTildes(_ text: String) -> String {
        var out = ""
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if c == "\\", let next = chars.first {
                out.append(c); out.append(next); chars.removeFirst()
            } else if c == "`" {
                var run = 1
                while chars.first == "`" { run += 1; chars.removeFirst() }
                let ticks = String(repeating: "`", count: run)
                let rest = String(chars)
                if let close = closingTicks(rest, run: run) {
                    out += ticks + rest[..<close.lowerBound] + ticks
                    chars = Array(rest[close.upperBound...])[...]
                } else {
                    out += ticks
                }
            } else if c == "~" {
                var run = 1
                while chars.first == "~" { run += 1; chars.removeFirst() }
                out += run == 1 ? "\\~" : String(repeating: "~", count: run)
            } else {
                out.append(c)
            }
        }
        return out
    }

    // The next run of exactly `run` backticks.
    private static func closingTicks(_ text: String, run: Int) -> Range<String.Index>? {
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "`" {
                var end = index
                while end < text.endIndex && text[end] == "`" { end = text.index(after: end) }
                if text.distance(from: index, to: end) == run { return index..<end }
                index = end
            } else {
                index = text.index(after: index)
            }
        }
        return nil
    }

    // Bold, italics, code and links; line breaks are kept.
    static func inline(_ text: String) -> AttributedString {
        if let cached = inlineCache.object(forKey: text as NSString) { return cached.value }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: escapingSingleTildes(text), options: options)) ?? AttributedString(text)
        inlineCache.setObject(Parsed(parsed), forKey: text as NSString)
        return parsed
    }

    // Parsed replies are kept, so redrawing or resizing a long chat does not parse every reply again.
    // Keyed by the text itself: a reply that changes (while it streams) is simply a new entry.
    static func cachedBlocks(_ text: String) -> [Block] {
        if let cached = blockCache.object(forKey: text as NSString) { return cached.value }
        let parsed = blocks(text)
        blockCache.setObject(Parsed(parsed), forKey: text as NSString)
        return parsed
    }

    private final class Parsed<Value> {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
    private static let blockCache: NSCache<NSString, Parsed<[Block]>> = {
        let cache = NSCache<NSString, Parsed<[Block]>>()
        cache.countLimit = 500
        return cache
    }()
    private static let inlineCache: NSCache<NSString, Parsed<AttributedString>> = {
        let cache = NSCache<NSString, Parsed<AttributedString>>()
        cache.countLimit = 5000
        return cache
    }()
}

// A reply drawn from its Markdown blocks. Font, line spacing and selection come from the caller.
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 13
    var highlight = FindHighlight()   // ⌘F words

    var body: some View {
        let blocks = ChatMarkdown.cachedBlocks(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let body):
                    Text(highlight.apply(ChatMarkdown.inline(body))).frame(maxWidth: .infinity, alignment: .leading)
                case .heading(let level, let body):
                    Text(highlight.apply(ChatMarkdown.inline(body)))
                        .font(.system(size: size + CGFloat(max(0, 4 - level) * 2), weight: level <= 2 ? .bold : .semibold))
                        .padding(.top, level <= 2 ? 6 : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .table(let header, let rows):
                    table(header, rows)
                case .rule:
                    Divider().padding(.vertical, 4)
                }
            }
        }
    }

    private func table(_ header: [String], _ rows: [[String]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(ChatMarkdown.inline(cell)).fontWeight(.semibold)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(highlight.apply(ChatMarkdown.inline(cell)))
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        .cornerRadius(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
