import Foundation

/// How a Markdown table shares out its width, and what it gives the
/// pasteboard.
public enum MarkdownTable {
    /// Each column's width when the table is `width` wide, `gap` between
    /// columns; the widest lines when `width` is nil. `widest` is each
    /// column's widest line, `narrowest` its widest word.
    ///
    /// As a web page shares a table's width: room to spare goes to each
    /// column in proportion to its text, so short columns stay short. When
    /// the text is too wide, each column keeps its widest word and gives
    /// up the same share of the rest it would need to keep its lines whole,
    /// so the longest text wraps first. Narrower than the widest words,
    /// all shrink alike and words break.
    public static func widths(widest: [Double], narrowest: [Double], width: Double?, gap: Double) -> [Double] {
        let count = widest.count
        guard let width, width.isFinite, count > 0 else { return widest }
        let narrowest = narrowest.count == count ? zip(narrowest, widest).map { min($0, $1) } : widest
        let text = max(0, width - gap * Double(count - 1))
        let most = widest.reduce(0, +)
        let least = narrowest.reduce(0, +)
        if text >= most {
            guard most > 0 else { return Array(repeating: text / Double(count), count: count) }
            return widest.map { $0 + (text - most) * $0 / most }
        }
        if text > least {
            let share = (text - least) / (most - least)
            return zip(narrowest, widest).map { $0 + ($1 - $0) * share }
        }
        guard least > 0 else { return Array(repeating: text / Double(count), count: count) }
        return narrowest.map { $0 * text / least }
    }

    /// What a cell shows: `<br>` breaks the line, as on GitHub.
    public static func shown(_ cell: String) -> String {
        cell.replacing(/<br\s*\/?>/.ignoresCase(), with: "\n")
    }

    /// The table as Markdown, as `MarkdownBlock.parse` reads it back: bars
    /// in cells escaped, the alignment row as written.
    public static func markdown(header: [String], alignments: [MarkdownAlignment], rows: [[String]]) -> String {
        func line(_ cells: [String]) -> String {
            "| " + header.indices.map { c in
                (cells.indices.contains(c) ? cells[c] : "").replacingOccurrences(of: "|", with: "\\|")
            }.joined(separator: " | ") + " |"
        }
        let marks = header.indices.map { c in
            switch alignments.indices.contains(c) ? alignments[c] : .leading {
            case .leading: "---"
            case .center: ":---:"
            case .trailing: "---:"
            }
        }
        return ([line(header), "| " + marks.joined(separator: " | ") + " |"] + rows.map(line)).joined(separator: "\n")
    }

    /// The table as HTML, for apps that paste tables (Notes, Mail, Pages,
    /// Numbers): its cells' bold, italics, code, struck text, links and
    /// line breaks kept.
    public static func html(header: [String], alignments: [MarkdownAlignment], rows: [[String]]) -> String {
        func cells(_ row: [String], tag: String) -> String {
            header.indices.map { c in
                let align = switch alignments.indices.contains(c) ? alignments[c] : .leading {
                case .leading: ""
                case .center: " align=\"center\""
                case .trailing: " align=\"right\""
                }
                return "<\(tag)\(align)>\(html(row.indices.contains(c) ? row[c] : ""))</\(tag)>"
            }.joined()
        }
        let body = rows.map { "<tr>\(cells($0, tag: "td"))</tr>" }.joined()
        return "<table><thead><tr>\(cells(header, tag: "th"))</tr></thead><tbody>\(body)</tbody></table>"
    }

    /// One cell's Markdown as HTML.
    static func html(_ cell: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let text = shown(cell)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        var out = ""
        for run in parsed.runs {
            var piece = escape(String(parsed[run.range].characters)).replacingOccurrences(of: "\n", with: "<br>")
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { piece = "<code>\(piece)</code>" }
            if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
            if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
            if intent.contains(.strikethrough) { piece = "<del>\(piece)</del>" }
            if let link = run.link { piece = "<a href=\"\(escape(link.absoluteString))\">\(piece)</a>" }
            out += piece
        }
        return out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
