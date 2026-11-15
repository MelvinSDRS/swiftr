import Foundation

/// Text a program drew on its screen, read back as paragraphs: the lines
/// the terminal wrapped are joined again, so a card can wrap them to its own
/// width, while what must keep its layout (paths, commands, columns) stays
/// as drawn.
public struct ScreenParagraph: Sendable, Equatable {
    public var text: String
    /// Words to read, for a proportional font. Else a path, a command or
    /// columns, kept line for line for the code font.
    public var prose: Bool

    public init(_ text: String, prose: Bool) {
        self.text = text
        self.prose = prose
    }

    /// `lines` as paragraphs; blank lines part them.
    public static func split(_ lines: [String]) -> [ScreenParagraph] {
        let lines = lines.map(withoutTrailingSpaces)
        // The box is at least as wide as its widest line.
        let widest = lines.map(\.count).max() ?? 0
        var blocks: [[String]] = [[]]
        for line in lines {
            if line.allSatisfy(\.isWhitespace) {
                if !(blocks.last?.isEmpty ?? true) { blocks.append([]) }
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks.filter { !$0.isEmpty }.map { block in
            let indent = block.map { $0.prefix { $0 == " " }.count }.min() ?? 0
            let block = block.map { String($0.dropFirst(indent)) }
            if block.contains(where: laidOut) {
                return ScreenParagraph(block.joined(separator: "\n"), prose: false)
            }
            var text = ""
            for (i, line) in block.enumerated() {
                let words = line.trimmingCharacters(in: .whitespaces)
                if i == 0 {
                    text = words
                } else if wrapped(block[i - 1].count + indent, next: words, widest: widest) {
                    text += " " + words
                } else {
                    text += "\n" + words
                }
            }
            return ScreenParagraph(text, prose: true)
        }
    }

    /// The terminal moved `next` to its own line: its first word didn't fit
    /// after a line that long. Never so for a list's next item, nor after a
    /// short line (no box is that narrow).
    static func wrapped(_ length: Int, next: String, widest: Int) -> Bool {
        guard length >= 40, let first = next.split(separator: " ").first, !startsItem(next) else { return false }
        return length + 1 + first.count > widest
    }

    /// `• `, `- `, `1. `, `a) `: the start of a list's item.
    static func startsItem(_ s: String) -> Bool {
        if let c = s.first, "•·-*–—→✓✔✗✘⎿▸›".contains(c) { return true }
        return s.firstMatch(of: #/^(\d{1,3}|[a-zA-Z])[.)] /#) != nil
    }

    /// A line whose layout matters: a path or command, columns, a box's
    /// lines, or a line indented under the others.
    static func laidOut(_ line: String) -> Bool {
        if line.first == " " { return true }
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("./") || t.hasPrefix("$ ") { return true }
        if t.contains("  ") { return true }
        if t.unicodeScalars.contains(where: { (0x2500 ... 0x259F).contains($0.value) }) { return true }
        if !t.contains(" "), t.contains(where: { "/\\=".contains($0) }) { return true }
        return false
    }

    private static func withoutTrailingSpaces(_ s: String) -> String {
        var s = s
        while s.last?.isWhitespace == true { s.removeLast() }
        return s
    }
}
