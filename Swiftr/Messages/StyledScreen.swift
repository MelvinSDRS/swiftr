import Foundation
import HerdrKit
@preconcurrency import SwiftTerm
import Synchronization

/// An agent's screen with its colors, for what plain `terminal.read` text
/// can't tell: Claude Code shows a suggested next message dim in its empty
/// input box (Tab takes it), and as text it reads like typing.
///
/// Swiftr attaches to the terminal as a viewer that only watches (it never
/// types or resizes), feeds the core's first paint to a SwiftTerm engine
/// that draws nothing, and leaves.
struct StyledScreen {
    /// One screen row: its characters and, for each, whether it shows dim,
    /// its color, the column it starts at (a wide one takes two), and
    /// whether it shows in reverse, as Gemini draws its cursor, and its
    /// background, as Claude Code marks the tab its question shows.
    struct Row {
        var text: String
        var dim: [Bool]
        var fg: [Attribute.Color] = []
        var starts: [Int] = []
        var inverse: [Bool] = []
        var bg: [Attribute.Color] = []

        /// The index of the character under column `x`; past the row's
        /// last character, as if spaces went on.
        func index(ofColumn x: Int) -> Int {
            guard let last = starts.lastIndex(where: { $0 <= x }) else { return 0 }
            let end = starts.indices.contains(last + 1) ? starts[last + 1] : (starts[last] + 1)
            return x < end ? last : last + 1 + (x - end)
        }
    }

    var rows: [Row]
    /// Where the cursor is: column and row, from the top left.
    var cursor: (x: Int, y: Int)

    /// Reads `address`'s screen at its own size; nil when the attach fails
    /// or nothing comes within `seconds`.
    @MainActor
    static func read(_ address: String, connection: CoreConnection, cols: Int, rows: Int, seconds: Double = 1.5) async -> StyledScreen? {
        guard cols > 0, rows > 0 else { return nil }
        let sink = Collector()
        guard let a = try? await connection.attach(address, cols: cols, rows: rows, history: 0, observe: true, sink: sink) else { return nil }
        // The first paint comes at once: wait for it, then for a quiet moment.
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(60))
            if let last = sink.last.withLock({ $0 }), Date().timeIntervalSince(last) > 0.12 { break }
        }
        connection.detach(a.channel)
        let bytes = sink.bytes.withLock { $0 }
        guard !bytes.isEmpty else { return nil }
        let quiet = Quiet()
        let t = Terminal(delegate: quiet, options: TerminalOptions(cols: cols, rows: rows, scrollback: 0))
        t.feed(byteArray: bytes)
        var shown: [Row] = []
        for y in 0 ..< t.rows {
            var row = Row(text: "", dim: [])
            guard let line = t.getLine(row: y) else { shown.append(row); continue }
            for x in 0 ..< min(line.count, t.cols) {
                let cell = line[x]
                // The second half of a wide character holds nothing.
                guard cell.width > 0 else { continue }
                let c = cell.getCharacter()
                row.text.append(c == "\u{0}" ? " " : c)
                row.dim.append(cell.attribute.style.contains(.dim) || Self.isGrey(cell.attribute.fg))
                row.fg.append(cell.attribute.fg)
                row.starts.append(x)
                row.inverse.append(cell.attribute.style.contains(.inverse))
                row.bg.append(cell.attribute.bg)
            }
            shown.append(row)
        }
        let at = t.getCursorLocation()
        return StyledScreen(rows: shown, cursor: (at.x, at.y))
    }

    /// The greys Claude Code's themes draw dim text in (an ANSI grey, or a
    /// true colour whose three parts are close, neither black nor white).
    private static func isGrey(_ color: Attribute.Color) -> Bool {
        switch color {
        case .ansi256(let code): return code == 8 || (code >= 240 && code <= 250)
        case .trueColor(let r, let g, let b):
            let parts = [Int(r), Int(g), Int(b)]
            guard let low = parts.min(), let high = parts.max() else { return false }
            return high - low <= 16 && low >= 90 && high <= 175
        default: return false
        }
    }

    /// Claude Code's input box: the text after `❯` when all of it shows dim,
    /// with the cursor before it. That is a suggestion, not typing.
    var suggestion: String? {
        func rule(_ r: Row) -> Bool { ScreenPrompt.isRule(r.text) && !ScreenPrompt.isDashed(r.text) }
        guard let bottom = rows.lastIndex(where: { rule($0) }), bottom > 0,
              let top = rows[..<bottom].lastIndex(where: { ScreenPrompt.isBoxTop($0.text) }), bottom - top >= 2
        else { return nil }
        let first = rows[top + 1]
        guard let sign = first.text.firstIndex(where: { "❯>".contains($0) }) else { return nil }
        let start = first.text.distance(from: first.text.startIndex, to: sign) + 1
        var words = ""
        var allDim = true
        for y in top + 1 ..< bottom {
            let row = rows[y]
            let from = y == top + 1 ? start : 0
            for (i, c) in row.text.enumerated() where i >= from && !c.isWhitespace {
                if !row.dim[i] { allDim = false }
            }
            let part = String(row.text.dropFirst(from)).trimmingCharacters(in: .whitespaces)
            if !part.isEmpty { words += (words.isEmpty ? "" : "\n") + part }
        }
        guard !words.isEmpty, allDim else { return nil }
        // Typing leaves the cursor after the text; a suggestion keeps it at the start.
        guard cursor.y == top + 1, cursor.x <= start + 1 else { return nil }
        return words
    }

    /// Claude's question: the tab its bar (`←  ☐ Color  ☒ Pets  ✔ Submit  →`)
    /// shows as open, from the first, Submit last. Claude Code draws that
    /// one on a background of its own; the text alone can't tell.
    var shownTab: Int? {
        for row in rows where row.text.contains("☐") || row.text.contains("☒") {
            let chars = Array(row.text)
            guard chars.count == row.bg.count, chars.contains("←") || chars.contains("→") || row.text.contains("Submit") else { continue }
            let marks = chars.indices.filter { "☐☒✔".contains(chars[$0]) }
            if let open = marks.firstIndex(where: { row.bg[$0] != .defaultColor }) { return open }
        }
        return nil
    }

    /// Claude's question beside previews: its notes show open for typing.
    /// Closed, Claude Code draws their words dim; open, in the text's own
    /// color (the last row with `Notes:` is theirs, under the previews).
    var notesShowOpen: Bool {
        guard let row = rows.last(where: { $0.text.contains("Notes:") }), let r = row.text.range(of: "Notes:") else { return false }
        let chars = Array(row.text)
        let from = row.text.distance(from: row.text.startIndex, to: r.upperBound)
        let words = (from ..< chars.count).filter { !chars[$0].isWhitespace && row.dim.indices.contains($0) }
        return !words.isEmpty && !words.allSatisfy { row.dim[$0] }
    }

    /// OpenCode's question: the option its cursor is on, which only colors
    /// tell: its number (`10.`) in the box's accent, the others' grey. The
    /// rows under the box's last `Questions`; nil when no number differs
    /// from the rest (fewer than three in sight, the cursor's cut off).
    var openCodeCursor: Int? {
        // `┃  Questions`, maybe the side column of a wide pane after it.
        let top = rows.lastIndex { row in
            let rest = row.text.drop { $0 == " " }
            return rest.first == "┃" && ScreenPrompt.openCodeMain(String(rest.dropFirst())).trimmingCharacters(in: .whitespaces) == "Questions"
        } ?? -1
        var numbers: [(n: Int, color: Attribute.Color)] = []
        for row in rows[(top + 1)...] {
            let chars = Array(row.text)
            // `┃  10. Choice 10`: the bar, spaces, digits and a period.
            guard let bar = chars.firstIndex(of: "┃"), chars[..<bar].allSatisfy({ $0 == " " }) else { continue }
            var i = bar + 1
            while i < chars.count, chars[i] == " " { i += 1 }
            // Two spaces after the bar; further right is the side column's.
            guard i - bar <= 4 else { continue }
            let start = i
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
            guard i > start, i < chars.count, chars[i] == ".", let n = Int(String(chars[start ..< i])), row.fg.indices.contains(start) else { continue }
            numbers.append((n, row.fg[start]))
        }
        guard numbers.count >= 3 else { return nil }
        let odd = numbers.filter { a in numbers.filter { $0.color == a.color }.count == 1 }
        return odd.count == 1 ? odd[0].n : nil
    }

    /// Gemini's question: whether `words`, on its field's row (`> e.g.
    /// notes.txt`) or on its option for one's own words, are a hint of the
    /// question's own. Gemini draws a hint in the color of the keys line
    /// under it (`Enter to submit · …`), typing in the plain one. The first
    /// letter doesn't count: the cursor may show on it.
    func isGeminiHint(_ words: String) -> Bool {
        let probe = Array(words.prefix(24))
        guard probe.count > 1,
              let keys = rows.last(where: { $0.text.contains("Esc to cancel") }),
              let shown = rows.last(where: { $0.text.contains(String(probe)) })
        else { return false }
        func start(of part: [Character], in row: Row) -> Int? {
            let chars = Array(row.text)
            guard chars.count >= part.count else { return nil }
            return (0 ... chars.count - part.count).last { Array(chars[$0 ..< $0 + part.count]) == part }
        }
        guard let k = start(of: Array("Enter to"), in: keys) ?? start(of: Array("Esc to cancel"), in: keys),
              keys.fg.indices.contains(k), let at = start(of: probe, in: shown)
        else { return false }
        let hint = keys.fg[k]
        let letters = Array(shown.text)
        let cells = (at + 1 ..< at + probe.count).filter { shown.fg.indices.contains($0) && !letters[$0].isWhitespace }
        return !cells.isEmpty && cells.allSatisfy { shown.fg[$0] == hint }
    }
}

/// The bytes of one attach stream, credited as they come.
private nonisolated final class Collector: StreamSink, @unchecked Sendable {
    let bytes = Mutex<[UInt8]>([])
    let last = Mutex<Date?>(nil)
    // Reader thread only.
    private var channel: UInt32 = 0
    private weak var connection: CoreConnection?

    func streamOpened(channel: UInt32, connection: CoreConnection, result: JSON) {
        self.channel = channel
        self.connection = connection
    }

    func streamData(_ data: UnsafeRawBufferPointer) {
        bytes.withLock { $0.append(contentsOf: data) }
        last.withLock { $0 = Date() }
        connection?.credit(channel, data.count)
    }

    func streamResize(cols: Int, rows: Int) {}
    func streamClosed(reason: JSON?) {}
}

/// A SwiftTerm engine's delegate that answers nothing: the viewer only watches.
private final class Quiet: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
