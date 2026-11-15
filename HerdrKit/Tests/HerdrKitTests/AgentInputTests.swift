import Foundation
import Testing
@testable import HerdrKit

/// Codex 0.169, OpenCode 2.3.0 and Gemini 0.68 input boxes, as their
/// screens drew them at 200 columns (2026-11-13).
@Suite struct AgentInputTests {
    private let words = "third line is much longer: " + (0 ..< 45).map { String(format: "word%02d", $0) }.joined(separator: " ") + " end"
    private func words(_ range: Range<Int>) -> String { range.map { String(format: "word%02d", $0) }.joined(separator: " ") }

    @Test func codexRowsWrapAndKeepTheirLines() throws {
        let screen = [
            "• Earlier answer.", "",
            "› first line",
            "      second line, indented",
            "  third line is much longer: " + words(0 ..< 24),
            "  " + words(24 ..< 45) + " end",
            "  pasted A", "", "  pasted D after a blank", "",
            "  fake-1 low · /tmp/work",
        ].joined(separator: "\n")
        let input = try #require(AgentInput.codex(screen: screen, columns: 200))
        #expect(input.width == 197)
        #expect(input.text == "first line\n    second line, indented\n\(words)\npasted A\n\npasted D after a blank")
        #expect(input.placeholders.isEmpty)
        // The footer reads all of it, and still the status line.
        let footer = try #require(ClaudeFooter.parseCodex(screen: screen))
        #expect(footer.input?.hasPrefix("first line\nsecond line, indented\nthird line") == true)
        #expect(footer.statusLine == ["fake-1 low · /tmp/work"])
    }

    @Test func codexTallDraftAndEmptyInput() throws {
        let thirty = (1 ... 30).map { String(format: "line %02d of the tall draft", $0) }
        let rows = ["› " + thirty[0]] + thirty.dropFirst().map { "  " + $0 }
        let tall = (["  >_ OpenAI Codex (v0.169.0)", ""] + rows + ["", "  fake-1 low · /tmp/work"]).joined(separator: "\n")
        #expect(AgentInput.codex(screen: tall, columns: 200)?.text == thirty.joined(separator: "\n"))
        #expect(ClaudeFooter.parseCodex(screen: tall)?.model == "fake-1")

        let empty = ["› Ask Codex to do anything", "", "  fake-1 low · /tmp/work", "  ← for agents · ? for shortcuts"].joined(separator: "\n")
        let none = try #require(AgentInput.codex(screen: empty, columns: 200))
        #expect(none.isEmpty)
        #expect(ClaudeFooter.parseCodex(screen: empty)?.input == "")
        #expect(AgentInput.codex(screen: "$ ls\nfile.txt", columns: 200) == nil)
    }

    @Test func openCodeBoxAndItsPastes() throws {
        let pad = String(repeating: " ", count: 63)
        let screen = [
            pad + "┃",
            pad + "┃  first line of a draft typed in Messages, long enough to wrap around",
            pad + "┃  the input box of OpenCode which is narrower here",
            pad + "┃      second line, indented",
            pad + "┃",
            pad + "┃  [Pasted ~4 lines]",
            pad + "┃",
            pad + "┃  Build · Fake One Fake",
            pad + "╹" + String(repeating: "▀", count: 74),
            pad + "/…/work  shift+tab agents  ctrl+p commands",
        ].joined(separator: "\n")
        let input = try #require(AgentInput.openCode(screen: screen))
        #expect(input.width == 70)
        #expect(input.text == "first line of a draft typed in Messages, long enough to wrap around the input box of OpenCode which is narrower here\n    second line, indented\n\n[Pasted ~4 lines]")
        #expect(input.placeholders == ["[Pasted ~4 lines]"])

        let empty = [pad + "┃", pad + "┃  Ask anything… \"What is the tech stack of this project?\"", pad + "┃", pad + "┃  Build · Fake One Fake", pad + "╹" + String(repeating: "▀", count: 74)].joined(separator: "\n")
        #expect(AgentInput.openCode(screen: empty)?.isEmpty == true)
    }

    /// A word that ends on a row's last column stays there; the space after
    /// it goes with the wrap (OpenCode 2.3.0, Codex, Claude Code 2.1.32x:
    /// `❯ aaa… bcdefg` at 198 columns of 200, then `  tail`). A word wider
    /// than a row breaks anywhere.
    @Test func fullRowsKeepTheirSpace() throws {
        let a63 = String(repeating: "a", count: 63)
        #expect(ClaudeBox.joined([a63 + " bcdefg", "tail"], width: 70) == a63 + " bcdefg tail")
        let long = String(repeating: "x", count: 100)
        #expect(ClaudeBox.joined(["hello " + long.prefix(64), String(long.dropFirst(64)) + " end"], width: 70) == "hello " + long + " end")
        #expect(ClaudeBox.joined([String(long.prefix(70)), String(long.dropFirst(70))], width: 70) == long)
        // A second space typed at the wrap starts the next row.
        #expect(ClaudeBox.joined([a63 + " bcdefg", " tail"], width: 70) == a63 + " bcdefg tail")

        let a189 = String(repeating: "a", count: 189)
        let rule = String(repeating: "─", count: 200)
        let box = try #require(ClaudeBox.parse(screen: [rule, "❯ " + a189 + " bcdefg", "  tail", rule].joined(separator: "\n")))
        #expect(box.text == a189 + " bcdefg tail")
    }

    @Test func geminiBoxWrapsEarlyAndScrolls() throws {
        let top = String(repeating: "▄", count: 200)
        let bottom = String(repeating: "▀", count: 200)
        let screen = [
            " Shift+Tab to accept edits", top,
            " > third line is much longer: " + words(0 ..< 23),
            "   " + words(23 ..< 45) + " end",
            "",
            "   [Pasted Text: 12 lines]",
            bottom, " workspace (/directory)",
        ].joined(separator: "\n")
        let input = try #require(AgentInput.gemini(screen: screen))
        #expect(input.width == 194)
        // `word22 word23` would end on the last column: Gemini moved word23.
        #expect(input.text == "\(words)\n\n[Pasted Text: 12 lines]")
        #expect(!input.cut)
        #expect(input.placeholders == ["[Pasted Text: 12 lines]"])

        let tall = ([top] + (21 ... 30).map { ($0 == 21 ? " > " : "   ") + String(format: "line %02d of the tall draft", $0) } + [bottom]).joined(separator: "\n")
        let shown = try #require(AgentInput.gemini(screen: tall))
        #expect(shown.cut)
        #expect(shown.rows.first == "line 21 of the tall draft")

        let empty = [top, " >   Type your message or @path/to/file", bottom].joined(separator: "\n")
        #expect(AgentInput.gemini(screen: empty)?.isEmpty == true)
    }

    /// Notes on Codex 0.169's question (Tab on an option), as its screen
    /// showed them at 200 columns (2026-11-14).
    @Test func codexNotes() throws {
        let options = [
            "  Question 1/2 (2 unanswered)", "  Which color do you want?", "",
            "    1. Red                Warm", "    2. Blue               Cool",
            "  › 3. None of the above  Optionally, add details in notes (tab)", "",
        ]
        let hint = ["", "  tab or esc to clear notes | enter to submit answer", ""]
        let two = try #require(AgentInput.codexNotes(screen: (options + ["  › abc1", "    second line  with  spaces"] + hint).joined(separator: "\n"), columns: 200))
        #expect(two.text == "abc1\nsecond line  with  spaces")
        #expect(two.width == 195)
        let empty = try #require(AgentInput.codexNotes(screen: (options + ["  › Add notes"] + hint).joined(separator: "\n"), columns: 200))
        #expect(empty.text == "")
        // Rows the notes wrapped join again: the first holds what fits in 195 columns.
        let list = (1 ... 40).map { "word\($0)" }
        var row = ""
        for w in list where row.count + 1 + w.count <= 195 { row += row.isEmpty ? w : " " + w }
        let rest = list.dropFirst(row.split(separator: " ").count).joined(separator: " ")
        let wrapped = try #require(AgentInput.codexNotes(screen: (options + ["  › " + row, "    " + rest] + hint).joined(separator: "\n"), columns: 200))
        #expect(wrapped.text == list.joined(separator: " "))
        // Closed: the question's own hints.
        let closed = options + ["", "  tab to add notes | enter to submit answer | ←/→ to navigate questions | esc to interrupt"]
        #expect(AgentInput.codexNotes(screen: closed.joined(separator: "\n"), columns: 200) == nil)
    }

    /// A picture's file pasted in the input: Claude Code 2.1.325 shows
    /// `[Image #11]` (no space after), Codex 0.169 `[Image #1] `, OpenCode
    /// 2.3.0 `[Image 1] `, Gemini 0.68 the file's name (2026-11-13).
    @Test func pictureMarks() throws {
        let top = String(repeating: "▄", count: 120)
        let bottom = String(repeating: "▀", count: 120)
        let screen = [top, " > [Image pic_test-2.png] [Image pic_test-3.png] two pictures", bottom].joined(separator: "\n")
        let input = try #require(AgentInput.gemini(screen: screen))
        #expect(input.placeholders == ["[Image pic_test-2.png]", "[Image pic_test-3.png]"])
        #expect(ClaudeBox.placeholders(in: "[Image #11]look [Image 2] and [Image my shot.jpeg]") == ["[Image #11]", "[Image 2]", "[Image my shot.jpeg]"])
        // Words in brackets are no picture.
        #expect(ClaudeBox.placeholders(in: "[Image of a cat] and [Image] here").isEmpty)
    }
}
