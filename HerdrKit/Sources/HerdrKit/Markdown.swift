import Foundation

/// Markdown cut into the blocks a chat draws one by one. Inline marks
/// (`**bold**`, `` `code` ``, links) stay in each block's text.
public enum MarkdownBlock: Sendable, Equatable {
    /// Lines of one paragraph, kept apart: Claude breaks lines on purpose.
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String, text: String)
    case list([MarkdownListItem])
    case quote(String)
    case table(header: [String], alignments: [MarkdownAlignment], rows: [[String]])
    case rule

    /// Blocks of `text`.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var parser = MarkdownParser(lines: text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        })
        return parser.run()
    }
}

public struct MarkdownListItem: Sendable, Equatable {
    /// 0 for the outer list, 1 for items under it...
    public var level: Int
    /// The number for numbered items (as written), nil for bullets.
    public var number: Int?
    /// [x] or [ ] items.
    public var checked: Bool?
    public var text: String
}

public enum MarkdownAlignment: Sendable, Equatable {
    case leading, center, trailing
}

private struct MarkdownParser {
    let lines: [String]
    var i = 0
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []

    init(lines: [String]) {
        self.lines = lines
    }

    mutating func run() -> [MarkdownBlock] {
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                i += 1
            } else if let fence = Self.fence(trimmed) {
                flush()
                code(fence: fence, indent: line.prefix { $0 == " " }.count)
            } else if let heading = Self.heading(trimmed) {
                flush()
                blocks.append(heading)
                i += 1
            } else if Self.isRule(trimmed) {
                flush()
                blocks.append(.rule)
                i += 1
            } else if trimmed.contains("|"), i + 1 < lines.count, lines[i + 1].contains("|"), Self.alignments(lines[i + 1]) != nil {
                flush()
                table()
            } else if Self.listMarker(line) != nil {
                flush()
                list()
            } else if trimmed.hasPrefix(">") {
                flush()
                quote()
            } else {
                paragraph.append(trimmed)
                i += 1
            }
        }
        flush()
        return blocks
    }

    mutating func flush() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        paragraph = []
    }

    // MARK: Code

    static func fence(_ trimmed: String) -> (marker: Character, count: Int, language: String)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        let language = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if first == "`", language.contains("`") { return nil }
        return (first, count, language.split(separator: " ").first.map(String.init) ?? "")
    }

    mutating func code(fence: (marker: Character, count: Int, language: String), indent: Int) {
        i += 1
        var body: [String] = []
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.first == fence.marker, trimmed.prefix(while: { $0 == fence.marker }).count >= fence.count,
               trimmed.allSatisfy({ $0 == fence.marker })
            {
                i += 1
                break
            }
            var line = Substring(lines[i])
            var drop = indent
            while drop > 0, line.first == " " {
                line = line.dropFirst()
                drop -= 1
            }
            body.append(String(line))
            i += 1
        }
        blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
    }

    // MARK: Headings and rules

    static func heading(_ trimmed: String) -> MarkdownBlock? {
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1 ... 6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #.
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*_".contains(first) else { return false }
        let marks = trimmed.filter { $0 != " " }
        return marks.count >= 3 && marks.allSatisfy { $0 == first }
    }

    // MARK: Tables

    /// The alignment row under a table's header (`| --- | :-: |`), nil if `line` isn't one.
    static func alignments(_ line: String) -> [MarkdownAlignment]? {
        let cells = cells(line)
        guard !cells.isEmpty, line.contains("-") else { return nil }
        var out: [MarkdownAlignment] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): out.append(.center)
            case (false, true): out.append(.trailing)
            default: out.append(.leading)
            }
        }
        return out
    }

    /// A table row's cells; `\|` stays a bar inside a cell, and so does a bar inside `code`.
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for c in t {
            if escaped {
                current.append(c == "|" ? "|" : "\\\(c)")
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "`" {
                inCode.toggle()
                current.append(c)
            } else if c == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    mutating func table() {
        let header = Self.cells(lines[i])
        var aligns = Self.alignments(lines[i + 1]) ?? []
        i += 2
        var rows: [[String]] = []
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.contains("|") else { break }
            var row = Self.cells(lines[i])
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            rows.append(Array(row.prefix(header.count)))
            i += 1
        }
        if aligns.count < header.count { aligns += Array(repeating: .leading, count: header.count - aligns.count) }
        blocks.append(.table(header: header, alignments: Array(aligns.prefix(header.count)), rows: rows))
    }

    // MARK: Lists

    /// The indent, number (nil: bullet) and text of a list item line.
    static func listMarker(_ line: String) -> (indent: Int, number: Int?, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { return nil }
        if "-*+•".contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            return (indent, nil, after.trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
        return (indent, Int(digits), after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    mutating func list() {
        var items: [MarkdownListItem] = []
        var indents: [Int] = []
        while i < lines.count {
            let line = lines[i]
            if let (indent, number, text) = Self.listMarker(line) {
                // The level: how many open items are less indented.
                while let last = indents.last, last > indent { indents.removeLast() }
                if indents.last != indent {
                    if let last = indents.last, indent < last + 2 {
                        // Barely more indented: the same level.
                    } else {
                        indents.append(indent)
                    }
                }
                var text = text
                var checked: Bool?
                if text.hasPrefix("[ ] ") || text == "[ ]" {
                    checked = false
                    text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                } else if text.lowercased().hasPrefix("[x] ") || text.lowercased() == "[x]" {
                    checked = true
                    text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                items.append(MarkdownListItem(level: max(0, indents.count - 1), number: number, checked: checked, text: text))
                i += 1
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !items.isEmpty else { break }
                // A blank line then an item: the same list. A blank line then
                // anything else ends it, as does a new block.
                let indent = line.prefix { $0 == " " }.count
                // A fence ends it too, even one indented under its item: taken
                // as the item's words, it would leave its closing fence to open
                // a code block that runs to the end of the message.
                if Self.fence(trimmed) != nil { break }
                if indent == 0, Self.heading(trimmed) != nil || trimmed.hasPrefix(">") || trimmed.hasPrefix("|") {
                    break
                }
                if indent == 0, i > 0, lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty { break }
                items[items.count - 1].text += "\n" + trimmed
                i += 1
            }
            // Blank lines between items of one list.
            var j = i
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
            if j > i, j < lines.count, Self.listMarker(lines[j]) != nil { i = j }
        }
        blocks.append(.list(items))
    }

    // MARK: Quotes

    mutating func quote() {
        var body: [String] = []
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            body.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
            i += 1
        }
        blocks.append(.quote(body.joined(separator: "\n")))
    }
}
