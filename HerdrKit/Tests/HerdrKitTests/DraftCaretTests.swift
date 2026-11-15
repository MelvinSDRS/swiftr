import Foundation
import Testing
@testable import HerdrKit

/// The cursor in each agent's input, as their screens drew `hello world
/// foo` with ← pressed four times (Claude Code 2.1.325, Codex 0.169,
/// OpenCode 2.3.0, Gemini 0.68; 2026-11-14), and its place in the draft.
@Suite struct DraftCaretTests {
    private let rule = String(repeating: "─", count: 200)

    /// The cursor's place in the input read from `lines` with the cursor
    /// at `x`, `y`, then in `text`.
    private func offset(_ lines: [String], x: Int, y: Int, in text: String, read: (String) -> String?) -> Int? {
        guard let (screen, under) = DraftCaret.marked(lines, x: x, y: y), let shown = read(screen),
              let place = DraftCaret.place(in: shown, under: under)
        else { return nil }
        return DraftCaret.offset(of: place, in: text)
    }

    private func claude(_ screen: String) -> String? { ClaudeBox.parse(screen: screen)?.text }

    @Test func eachAgentShowsItsCursorWhereThePersonTypes() {
        let text = "hello world foo"
        // Claude: `❯`, a no-break space, the text; the cursor on the space before `foo`.
        #expect(offset([rule, "❯\u{a0}hello world foo", rule], x: 13, y: 1, in: text, read: claude) == 11)
        // Codex: `› ` then the text; its hints show only while it's empty.
        let codex = ["› hello world foo", "", "  fake-1 low · /tmp/work"]
        #expect(offset(codex, x: 13, y: 0, in: text) { AgentInput.codex(screen: $0, columns: 200)?.text } == 11)
        // OpenCode: its box in the middle of the screen, `┃` and two spaces.
        let pad = String(repeating: " ", count: 63)
        let openCode = [pad + "┃", pad + "┃  hello world foo", pad + "┃", pad + "┃  Build · Fake One Fake", pad + "╹" + String(repeating: "▀", count: 74)]
        #expect(offset(openCode, x: 77, y: 1, in: text) { AgentInput.openCode(screen: $0)?.text } == 11)
        // Gemini: ` > ` between its edges.
        let gemini = [String(repeating: "▄", count: 109), " > hello world foo", String(repeating: "▀", count: 109)]
        #expect(offset(gemini, x: 14, y: 1, in: text) { AgentInput.gemini(screen: $0)?.text } == 11)
    }

    @Test func onALetterAtTheEndAndOnAnotherLine() {
        let row = "❯\u{a0}hello world foo"
        // On `w`: before it.
        #expect(offset([rule, row, rule], x: 8, y: 1, in: "hello world foo", read: claude) == 6)
        // Past the last letter: the end.
        #expect(offset([rule, row, rule], x: 17, y: 1, in: "hello world foo", read: claude) == 15)
        // Typed spaces at the end stay before the cursor; the rows read drop them.
        #expect(offset([rule, "❯\u{a0}hello ", rule], x: 8, y: 1, in: "hello ", read: claude) == 6)
        // On the second line's `line`.
        #expect(offset([rule, "❯\u{a0}first line", "  second line", rule], x: 9, y: 2, in: "first line\nsecond line", read: claude) == 18)
        // On an empty line: between the two line breaks.
        #expect(offset([rule, "❯\u{a0}abc", "", "  def", rule], x: 2, y: 2, in: "abc\n\ndef", read: claude) == 4)
        // Between two of four spaces.
        #expect(offset([rule, "❯\u{a0}ab    cd", rule], x: 6, y: 1, in: "ab    cd", read: claude) == 4)
    }

    @Test func wrappedRowsAndATallDraftCountFromTheEnd() {
        // A wrap: the next row's first letter, whatever spaces the wrap ate.
        let narrow = String(repeating: "─", count: 10)
        #expect(offset([narrow, "❯\u{a0}hello", "  world", narrow], x: 2, y: 2, in: "hello world", read: claude) == 6)
        // Claude shows only the last lines of a tall draft: its history has all of it.
        #expect(offset([rule, "❯\u{a0}c", "  d", rule], x: 2, y: 2, in: "a\nb\nc\nd", read: claude) == 6)
    }

    @Test func aWideCharacterTakesTwoColumns() {
        // `日本` takes columns 2 to 5: column 4 is `本`.
        #expect(offset([rule, "❯\u{a0}日本 go", rule], x: 4, y: 1, in: "日本 go", read: claude) == 1)
        #expect(offset([rule, "❯\u{a0}日本 go", rule], x: 6, y: 1, in: "日本 go", read: claude) == 2)
        // By index, as a screen read with colors gives it: `👍🏽` is one character.
        let (screen, under) = try! #require(DraftCaret.marked([rule, "❯\u{a0}go 👍🏽 ok", rule], at: 5, row: 1))
        #expect(under == "👍🏽")
        let place = try! #require(DraftCaret.place(in: claude(screen) ?? "", under: under))
        #expect(DraftCaret.offset(of: place, in: "go 👍🏽 ok") == 3)
        // Past the row's end: spaces, then the mark.
        #expect(DraftCaret.marked(["ab"], at: 4, row: 0)?.screen == "ab  \u{E000}")
    }

    @Test func noPlaceWhenTheCursorIsElsewhere() {
        // On the footer, out of the box: the mark isn't in the input.
        let lines = [rule, "❯\u{a0}hello", rule, "  ⏵⏵ auto mode on"]
        let (screen, under) = try! #require(DraftCaret.marked(lines, x: 4, y: 3))
        #expect(DraftCaret.place(in: claude(screen) ?? "", under: under) == nil)
        #expect(DraftCaret.marked(lines, x: 0, y: 9) == nil)
        // More words after the cursor than the draft has: no place.
        #expect(DraftCaret.offset(of: DraftCaret.Place(after: 9, onWord: true, blanksBefore: 0), in: "two words") == nil)
    }
}
