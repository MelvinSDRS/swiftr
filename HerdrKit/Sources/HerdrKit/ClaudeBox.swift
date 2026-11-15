import Foundation

/// Claude Code's input box as its screen draws it, row by row: what the
/// person typed there, for the Messages field to take.
///
///     ────────────────────────────────────────
///     ❯ first line of a draft, long enough to
///       wrap
///         second line, indented
///     ────────────────────────────────────────
///
/// The first row starts with the box's sign (`❯`, `!` in shell mode) and a
/// space; the rows under it are indented by two columns. Claude Code wraps
/// at word ends, `width` columns from the sign's space on.
public struct ClaudeBox: Sendable, Equatable {
    /// `❯`, or `!` while the box is in shell mode.
    public var sign: Character
    /// Each row's text, without the sign or the indent.
    public var rows: [String]
    /// The columns a row's text takes at most.
    public var width: Int

    public init(sign: Character, rows: [String], width: Int) {
        self.sign = sign
        self.rows = rows
        self.width = width
    }

    /// The box at the bottom of `screen`; nil when none shows.
    public static func parse(screen: String) -> ClaudeBox? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        guard let bottom = lines.lastIndex(where: { ScreenPrompt.isRule($0) && !ScreenPrompt.isDashed($0) }), bottom > 0,
              let top = lines[..<bottom].lastIndex(where: ScreenPrompt.isBoxTop),
              bottom - top >= 2, bottom - top <= 30
        else { return nil }
        var first = Substring(lines[top + 1]).drop { $0 == " " }
        guard let sign = first.first, "❯>!".contains(sign) else { return nil }
        first = first.dropFirst()
        if let space = first.first, space == " " || space == "\u{a0}" { first = first.dropFirst() }
        var rows = [String(first)]
        for line in lines[(top + 2) ..< bottom] {
            var row = Substring(line)
            for _ in 0 ..< 2 where row.first == " " || row.first == "\u{a0}" { row = row.dropFirst() }
            rows.append(String(row))
        }
        rows = rows.map { row in
            var r = Substring(row)
            while let last = r.last, last == " " || last == "\u{a0}" { r = r.dropLast() }
            return String(r)
        }
        while rows.count > 1, rows.last?.isEmpty == true { rows.removeLast() }
        let columns = lines[bottom].trimmingCharacters(in: .whitespaces).count
        return ClaudeBox(sign: sign, rows: rows, width: max(10, columns - 4))
    }

    public var isEmpty: Bool { rows.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// Shell mode: what is typed runs as a command (`!` in front of it).
    public var isShell: Bool { sign == "!" }

    /// The text typed, as far as the rows tell (`joined`). Shell mode puts
    /// its `!` in front.
    public var text: String {
        (isShell ? "!" : "") + Self.joined(rows, width: width)
    }

    /// Rows joined into the text they show: a row that is full, or that the
    /// next row's first word wouldn't have fit on, went on in the next (a
    /// wrap: its spaces show as one); any other row ended a line. `early`:
    /// the agent moves a word that would end on the last column (Gemini).
    /// A word may end on a full row's last column: the space after it goes
    /// with the wrap (Claude Code 2.1.32x, Codex, OpenCode). Only a word
    /// wider than a row breaks anywhere.
    public static func joined(_ rows: [String], width: Int, early: Bool = false) -> String {
        var out = rows.first ?? ""
        for i in rows.indices.dropFirst() {
            let previous = rows[i - 1]
            let next = rows[i]
            let word = next.prefix { !$0.isWhitespace }
            if columns(previous) >= width {
                let last = previous.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? previous
                // Two words that would fit a row together: a wrap, not a word broken.
                out += !word.isEmpty && columns(last) + columns(String(word)) <= width ? " " + next : next
            } else if !word.isEmpty, columns(previous) + 1 + columns(String(word)) > (early ? width - 1 : width) {
                out += " " + next
            } else {
                out += "\n" + next
            }
        }
        return out
    }

    /// `[Pasted text #1 +29 lines]`, `[Image #2]`, `[...Truncated text #3 +40 lines...]`:
    /// marks the box shows for what it holds but doesn't show.
    public var placeholders: [String] {
        Self.placeholders(in: rows.joined(separator: "\n"))
    }

    /// Also Codex's `[Pasted Content 1200 chars]`, OpenCode's `[Pasted ~4
    /// lines]`, `[Image 1]` and `[SVG: name]`, Gemini's `[Pasted Text: 8
    /// lines]` (`… chars]`, ` #2]` for the next) and `[Image shot.png]` (a
    /// picture's file name).
    public static func placeholders(in text: String) -> [String] {
        text.matches(of: /\[(?:Pasted text #\d+(?: \+\d+ lines)?|Image #?\d+|Image [^\]\n]+\.[A-Za-z0-9]{2,5}|\.\.\.Truncated text #\d+ \+\d+ lines\.\.\.|Pasted Content \d+ chars|Pasted ~\d+ lines|SVG: [^\]]+|Pasted Text: \d+ (?:lines|chars)(?: #\d+)?)\]/).map { String($0.output) }
    }

    /// The columns `s` takes: two for wide characters.
    static func columns(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { n, scalar in
            let v = scalar.value
            let wide = (0x1100 ... 0x115F).contains(v) || (0x2E80 ... 0xA4CF).contains(v) || (0xAC00 ... 0xD7A3).contains(v)
                || (0xF900 ... 0xFAFF).contains(v) || (0xFE30 ... 0xFE4F).contains(v) || (0xFF00 ... 0xFF60).contains(v)
                || (0xFFE0 ... 0xFFE6).contains(v) || (0x1F300 ... 0x1FAFF).contains(v) || (0x20000 ... 0x3FFFD).contains(v)
            let none = scalar.properties.generalCategory == .nonspacingMark || v == 0x200D || (0xFE00 ... 0xFE0F).contains(v)
            return n + (none ? 0 : wide ? 2 : 1)
        }
    }

    /// Text without its spaces and line breaks, to compare what a screen
    /// wraps with what was typed.
    public static func squeezed(_ s: String) -> String {
        s.filter { !$0.isWhitespace }
    }
}
