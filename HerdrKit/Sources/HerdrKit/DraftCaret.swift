import Foundation

/// The cursor in an agent's input, where its screen shows it, and its place
/// in the draft once the draft moves to the Messages field. Claude Code,
/// Codex, OpenCode and Gemini each put the terminal's cursor where the
/// person types (measured 2026-11-14); a plain screen read has no cursor,
/// a read with colors has it.
///
/// The character under the cursor is swapped for `mark`, then the agent's
/// own reading of its input (`ClaudeBox`, `AgentInput`) finds the mark in
/// the text it reads. Words count from the end of the input: Claude's box
/// may show only the last lines of a tall draft.
public enum DraftCaret {
    /// Put where the cursor is: a character no agent draws.
    public static let mark: Character = "\u{E000}"

    /// Where the cursor sits in the input's text: how many characters other
    /// than blanks (spaces, line breaks) come after it, whether it sits on
    /// one of them, and the blanks before it back to the previous one.
    public struct Place: Equatable, Sendable {
        public var after: Int
        public var onWord: Bool
        public var blanksBefore: Int

        public init(after: Int, onWord: Bool, blanksBefore: Int) {
            self.after = after
            self.onWord = onWord
            self.blanksBefore = blanksBefore
        }
    }

    /// `lines` with character `index` of row `y` swapped for `mark`; past
    /// the row's end, the row is filled with spaces up to it. Nil when `y`
    /// is off the lines. `under`: the character swapped (a space past the end).
    public static func marked(_ lines: [String], at index: Int, row y: Int) -> (screen: String, under: Character)? {
        guard lines.indices.contains(y), index >= 0 else { return nil }
        var row = Array(lines[y])
        var under: Character = " "
        if index < row.count {
            under = row[index]
            row[index] = mark
        } else {
            row += Array(repeating: " ", count: index - row.count)
            row.append(mark)
        }
        var out = lines
        out[y] = String(row)
        return (out.joined(separator: "\n"), under)
    }

    /// `marked` with the cursor at column `x` of row `y`, a wide character
    /// taking two columns as `ClaudeBox` counts them. A screen read with
    /// colors knows each character's own columns: better its index.
    public static func marked(_ lines: [String], x: Int, y: Int) -> (screen: String, under: Character)? {
        guard lines.indices.contains(y), x >= 0 else { return nil }
        return marked(lines, at: index(ofColumn: x, in: lines[y]), row: y)
    }

    /// The index of the character under column `x` in `line`; past its
    /// end, as if spaces went on.
    static func index(ofColumn x: Int, in line: String) -> Int {
        var column = 0
        for (i, c) in line.enumerated() {
            let width = ClaudeBox.columns(String(c))
            guard width > 0 else { continue }
            if x < column + width { return i }
            column += width
        }
        return line.count + max(0, x - column)
    }

    /// The cursor's place in `text`, an input read with `mark` where the
    /// cursor is; `under`, the character the mark took the place of. Nil
    /// when the mark isn't in it: the cursor is elsewhere.
    public static func place(in text: String, under: Character) -> Place? {
        guard let at = text.firstIndex(of: mark) else { return nil }
        let after = text[text.index(after: at)...].filter { !$0.isWhitespace }.count
        let blanks = text[..<at].reversed().prefix { $0.isWhitespace }.count
        return Place(after: after + (under.isWhitespace ? 0 : 1), onWord: !under.isWhitespace, blanksBefore: blanks)
    }

    /// Where `place` is in `text`, the draft the input held, in characters
    /// from its start: before the character it sat on, else after as many
    /// blanks as it had before it, as far as `text` has them there (rows
    /// joined where the agent wrapped them may show fewer). Nil when `text`
    /// has fewer words than the screen showed after the cursor.
    public static func offset(of place: Place, in text: String) -> Int? {
        let chars = Array(text)
        let words = chars.indices.filter { !chars[$0].isWhitespace }
        guard place.after <= words.count else { return nil }
        let next = place.after > 0 ? words[words.count - place.after] : chars.count
        if place.onWord, place.after > 0 { return next }
        let previous = words.count - place.after - 1 >= 0 ? words[words.count - place.after - 1] : -1
        return previous + 1 + min(place.blanksBefore, next - previous - 1)
    }
}
