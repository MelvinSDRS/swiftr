import Foundation

/// What Codex, OpenCode or Gemini holds in its input, as its screen draws
/// it row by row: the person's draft, for the Messages field to take.
/// Claude Code's box is a `ClaudeBox`.
public struct AgentInput: Sendable, Equatable {
    /// Each row's text, without the agent's sign or indent.
    public var rows: [String]
    /// The columns a row's text takes at most.
    public var width: Int
    /// Gemini moves a word that would end on the last column to the next row.
    public var early = false
    /// The box shows only some of its rows: Gemini's shows 10 and scrolls.
    public var cut = false

    public init(rows: [String], width: Int, early: Bool = false, cut: Bool = false) {
        self.rows = rows
        self.width = width
        self.early = early
        self.cut = cut
    }

    public var isEmpty: Bool { rows.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// The text typed, its rows joined where the agent wrapped them.
    public var text: String { ClaudeBox.joined(rows, width: width, early: early) }

    /// Marks for what the agent holds but doesn't show: `[Pasted Content
    /// 1200 chars]`, `[Pasted ~4 lines]`, `[Pasted Text: 8 lines]`, `[Image #1]`.
    public var placeholders: [String] { ClaudeBox.placeholders(in: rows.joined(separator: "\n")) }

    // MARK: Codex

    /// Codex's input: `› ` before the first row, two spaces before the
    /// others, then a blank row and its status line and hints:
    ///
    ///     › first row of the draft
    ///       second row
    ///
    ///       gpt-6-luna low · ~/project
    ///       ← for agents · ? for shortcuts
    ///
    /// Rows hold `columns - 3` columns. Empty while the hints say `? for
    /// shortcuts` (its dim example then fills the row) or while Codex
    /// browses its transcript. Nil when no input shows.
    public static func codex(screen: String, columns: Int) -> AgentInput? {
        let lines = codexLines(screen)
        guard let (first, below) = codexBounds(lines) else { return nil }
        let hints = lines[below...].map { $0.trimmingCharacters(in: .whitespaces) }
        if hints.contains(where: codexEmptyHint) { return AgentInput(rows: [""], width: max(10, columns - 3)) }
        // `› ` and the indent are two columns each.
        let rows = lines[first ..< below].map { String($0.dropFirst(2)) }
        return AgentInput(rows: trimmed(rows), width: max(10, columns - 3))
    }

    /// Codex's screen lines, without the braille dots its pet and ambient
    /// drawing put over them.
    static func codexLines(_ screen: String) -> [String] {
        screen.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(String.UnicodeScalarView(line.unicodeScalars.filter { !(0x2800 ... 0x28FF).contains($0.value) }))
        }
    }

    /// Where Codex's input starts (its `›` row) and where the status line
    /// and hints under it start: the last rows with text, under a blank
    /// row. The rows between are the input's, indented or blank.
    static func codexBounds(_ lines: [String]) -> (first: Int, below: Int)? {
        func blank(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).isEmpty }
        guard var below = lines.indices.last(where: { !blank($0) }) else { return nil }
        let end = below
        while below > 0, !blank(below - 1) { below -= 1 }
        guard below > 0, end - below < 4 else { return nil }
        var first = below - 1
        while first >= 0, !lines[first].hasPrefix("›") {
            guard blank(first) || lines[first].hasPrefix("  "), below - first <= 80 else { return nil }
            first -= 1
        }
        guard first >= 0, ScreenPrompt.option(lines[first]) == nil else { return nil }
        return (first, below)
    }

    /// Hints Codex shows under an empty input (its dim example fills the row).
    static func codexEmptyHint(_ line: String) -> Bool {
        line.contains("for shortcuts") || line.hasPrefix("esc again") || line.hasPrefix("Browsing transcript")
    }

    /// The notes Codex's question takes with the option under its cursor
    /// (Tab opens them): under the options, over its hint, a blank row
    /// around them; `› ` before the first row, four spaces before the others:
    ///
    ///       › 3. None of the above  Optionally, add details in notes (tab)
    ///
    ///       › first row of the notes
    ///         second row
    ///
    ///       tab or esc to clear notes | enter to submit answer
    ///
    /// Rows hold `columns - 5` columns. Empty while they show their hint
    /// (`Add notes`); nil when no notes are open.
    public static func codexNotes(screen: String, columns: Int) -> AgentInput? {
        let lines = codexLines(screen)
        guard let hint = lines.lastIndex(where: { $0.contains("to clear notes") }),
              let first = lines[..<hint].lastIndex(where: { $0.hasPrefix("  › ") })
        else { return nil }
        let rows = trimmed(lines[first ..< hint].map { String($0.dropFirst(4)) })
        return AgentInput(rows: rows == ["Add notes"] ? [""] : rows, width: max(10, columns - 5))
    }

    // MARK: OpenCode

    /// OpenCode's input box: rows behind a `┃` bar, its agent line last
    /// (`Build · Fake One Fake`), then its bottom edge `╹▀▀▀…`, whose
    /// width gives the rows' (5 columns less). A blank row pads the text
    /// above and below; its hint (`Ask anything…`) fills an empty box.
    public static func openCode(screen: String) -> AgentInput? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let bottom = lines.lastIndex(where: { $0.hasPrefix("╹") && $0.contains("▀▀▀") }), bottom > 1,
              lines[bottom - 1].hasPrefix("┃")
        else { return nil }
        let edge = lines[bottom].prefix { $0 == "╹" || $0 == "▀" }.count
        // The box's own columns: a panel beside it stays out.
        func row(_ line: String) -> String? {
            guard line.hasPrefix("┃") else { return nil }
            var r = Substring(line.prefix(max(edge, 2))).dropFirst()
            for _ in 0 ..< 2 where r.first == " " { r = r.dropFirst() }
            return String(r)
        }
        var rows: [String] = []
        var i = bottom - 2
        while i >= 0, let r = row(lines[i]) {
            rows.insert(r, at: 0)
            i -= 1
        }
        rows = trimmed(rows)
        if rows.count == 1, rows[0].hasPrefix("Ask anything") { rows = [""] }
        return AgentInput(rows: rows, width: max(10, edge - 5))
    }

    // MARK: Gemini

    /// Gemini's input box: rows between a row of `▄` and a row of `▀`,
    /// ` > ` before the first shown, three spaces before the others. Rows
    /// hold 6 columns less than the edges. The box shows 10 rows at most
    /// and scrolls: then it may hold more than it shows (`cut`). Its hint
    /// (`Type your message or @path/to/file`) fills an empty box.
    public static func gemini(screen: String) -> AgentInput? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func edge(_ line: String, of mark: Character) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.count >= 8 && t.allSatisfy { $0 == mark }
        }
        guard let bottom = lines.lastIndex(where: { edge($0, of: "▀") }),
              let top = lines[..<bottom].lastIndex(where: { edge($0, of: "▄") }),
              bottom - top >= 2, bottom - top <= 12
        else { return nil }
        let width = lines[bottom].trimmingCharacters(in: .whitespaces).count - 6
        var rows = lines[(top + 1) ..< bottom].map { line -> String in
            var r = Substring(line)
            if r.hasPrefix(" > ") || r.hasPrefix(" ! ") || r.hasPrefix(" * ") { return String(r.dropFirst(3)).trimmingTrailingSpaces }
            for _ in 0 ..< 3 where r.first == " " { r = r.dropFirst() }
            return String(r).trimmingTrailingSpaces
        }
        rows = trimmed(rows)
        if rows.count == 1, rows[0].trimmingCharacters(in: .whitespaces) == "Type your message or @path/to/file" { rows = [""] }
        return AgentInput(rows: rows, width: max(10, width), early: true, cut: bottom - top - 1 >= 10)
    }

    /// Rows without the blank ones before and after the text, nor trailing spaces.
    private static func trimmed(_ rows: [String]) -> [String] {
        var rows = rows.map(\.trimmingTrailingSpaces)
        while rows.count > 1, rows.last?.isEmpty == true { rows.removeLast() }
        while rows.count > 1, rows.first?.isEmpty == true { rows.removeFirst() }
        return rows.isEmpty ? [""] : rows
    }
}

private extension String {
    var trimmingTrailingSpaces: String {
        var s = Substring(self)
        while let last = s.last, last == " " || last == "\u{a0}" { s = s.dropLast() }
        return String(s)
    }
}
