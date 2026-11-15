import Foundation
import Testing
@testable import HerdrKit

/// Claude Code's input box and question tabs, as screens of Claude Code
/// 2.1.325 drew them (200 columns).
@Suite struct ClaudeBoxTests {
    private let rule = String(repeating: "─", count: 200)

    @Test func rowsWrapAtWordEndsAndKeepTheirLines() throws {
        let copy = "first line of a draft typed in the terminal, long enough to wrap"
        let screen = [
            "⏺ apple",
            "",
            rule,
            "❯\u{a0}\(copy) \(copy) \(copy)",
            "  \(copy)",
            "    second line, indented",
            "  [Pasted text #1 +29 lines] tail words",
            rule,
            "  paste again to expand",
        ].joined(separator: "\n")
        let box = try #require(ClaudeBox.parse(screen: screen))
        #expect(box.width == 196)
        #expect(box.rows.count == 4)
        #expect(box.text == "\(copy) \(copy) \(copy) \(copy)\n  second line, indented\n[Pasted text #1 +29 lines] tail words")
        #expect(box.placeholders == ["[Pasted text #1 +29 lines]"])
        #expect(!box.isShell)
    }

    @Test func aLongWordWrapsAnywhere() throws {
        let word = String(repeating: "abcdefghij0123456789", count: 13)
        let screen = [rule, "❯\u{a0}" + word.prefix(196), "  " + word.dropFirst(196), rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")
        let box = try #require(ClaudeBox.parse(screen: screen))
        #expect(box.text == word)
        #expect(box.placeholders.isEmpty)
    }

    /// Claude Code writes the session's title at the end of the box's top
    /// rule, a hint at its start: a long title, or a narrow pane, leaves
    /// few dashes in it.
    @Test func titledTopRules() throws {
        let narrow = String(repeating: "─", count: 100)
        let titled = String(repeating: "─", count: 64) + " Devis Migration Hostinger Leslie ─"
        let screen = [
            "⏺ Here are the steps:",
            "  1. Copy the files",
            "  2. Point the domain",
            "",
            titled,
            "❯\u{a0}first line typed in Messages",
            "  second line",
            narrow,
            "  lessss | Opus 5.5 · xhigh | context: 80% left",
            "  ⏵⏵ auto mode on",
        ].joined(separator: "\n")
        let box = try #require(ClaudeBox.parse(screen: screen))
        #expect(box.text == "first line typed in Messages\nsecond line")
        #expect(box.width == 96)
        let footer = try #require(ClaudeFooter.parse(screen: screen))
        #expect(footer.input == "first line typed in Messages\nsecond line")
        #expect(footer.mode == "auto")
        // The answer's list above the box is no question.
        #expect(ScreenPrompt.parse(screen: screen) == nil)

        let long = String(repeating: "─", count: 145) + " SPFX-1469 · Review SPFX-1469 Merge Readiness ─"
        #expect(ScreenPrompt.isBoxTop(long))
        #expect(!ScreenPrompt.isRule(long))
        let empty = try #require(ClaudeBox.parse(screen: [long, "❯ ", rule, "  ⏵⏵ auto mode on"].joined(separator: "\n")))
        #expect(empty.isEmpty)
        let hint = "─── ctrl+r to search history " + String(repeating: "─", count: 71)
        #expect(ClaudeBox.parse(screen: [hint, "❯ draft", narrow].joined(separator: "\n"))?.text == "draft")

        #expect(!ScreenPrompt.isBoxTop("── a heading ──"))
        #expect(!ScreenPrompt.isBoxTop("plain words"))
        #expect(!ScreenPrompt.isBoxTop("╌╌╌╌╌╌╌╌╌╌╌╌"))
    }

    @Test func emptyAndShellBoxes() throws {
        let empty = try #require(ClaudeBox.parse(screen: [rule, "❯ ", rule].joined(separator: "\n")))
        #expect(empty.isEmpty)
        let shell = try #require(ClaudeBox.parse(screen: [rule, "! ls -la", rule].joined(separator: "\n")))
        #expect(shell.isShell)
        #expect(shell.text == "!ls -la")
        #expect(ClaudeBox.parse(screen: "no box here") == nil)
    }

    @Test func questionsShowTheirAnswers() throws {
        let color = AskQuestion(header: "Color", question: "What is your favorite color?", options: [.init(label: "Red"), .init(label: "Blue"), .init(label: "Green")])
        let pets = AskQuestion(header: "Pets", question: "Which pets do you like?", multiSelect: true, options: [.init(label: "Cat"), .init(label: "Dog"), .init(label: "Fish")])
        let revisited = [
            rule,
            "←  ☒ Color  ☒ Pets  ✔ Submit  →",
            "What is your favorite color?",
            "❯ 1. Red",
            "     Red as your favorite color",
            "  2. Blue",
            "     Blue as your favorite color",
            "  3. Green",
            "     Green as your favorite color",
            "  4. my own color ✔",
            rule,
            "  5. Chat about this",
            "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
        ].joined(separator: "\n")
        let p = try #require(ScreenPrompt.parse(screen: revisited))
        #expect(p.questionIndex(in: [color, pets]) == 0)
        #expect(p.shownAnswer(for: color) == AskAnswer(chosen: [], other: "my own color"))
        let blue = revisited.replacingOccurrences(of: "  2. Blue", with: "  2. Blue ✔").replacingOccurrences(of: "my own color ✔", with: "Type something.")
        #expect(try #require(ScreenPrompt.parse(screen: blue)).shownAnswer(for: color) == AskAnswer(chosen: ["Blue"]))
        let boxes = [
            rule,
            "←  ☒ Color  ☒ Pets  ✔ Submit  →",
            "Which pets do you like?",
            "  1. [ ] Cat",
            "         Cats",
            "  2. [✔] Dog",
            "         Dogs",
            "  3. [ ] Fish",
            "         Fish",
            "❯ 4. [✔] hamster",
            "     Submit",
            rule,
            "  5. Chat about this",
            "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
        ].joined(separator: "\n")
        let q = try #require(ScreenPrompt.parse(screen: boxes))
        #expect(q.questionIndex(in: [color, pets]) == 1)
        #expect(q.shownAnswer(for: pets) == AskAnswer(chosen: ["Dog"], other: "hamster"))
        #expect(q.tabs.map(\.answered) == [true, true, false])
    }

    /// OpenCode 2.3.0's question box, its tabs revisited with ← (2026-11-14).
    @Test func openCodeQuestionsShowTheirAnswers() throws {
        let color = AskQuestion(header: "Color", question: "Which color do you want?", options: [.init(label: "Red"), .init(label: "Blue"), .init(label: "Green")])
        let toppings = AskQuestion(header: "Toppings", question: "Which toppings do you want?", multiSelect: true, options: [.init(label: "Cheese"), .init(label: "Olives"), .init(label: "Basil")])
        func box(_ lines: [String]) -> String {
            (["  ┃  Questions", "  ┃", "  ┃  Color  Toppings  Submit", "  ┃"] + lines.map { "  ┃  " + $0 } + ["  ┃", "  ┃  ⇆ tab  ↑↓ select  enter confirm  esc dismiss", "  ┃"]).joined(separator: "\n")
        }
        let red = box(["Which color do you want?", "", "1. Red ✓", "   A warm color", "2. Blue", "   A cool color", "3. Green", "   A calm color", "4. Type your own answer"])
        let p = try #require(ScreenPrompt.parseOpenCode(screen: red))
        #expect(p.questionIndex(in: [color, toppings]) == 0)
        #expect(p.shownAnswer(for: color) == AskAnswer(chosen: ["Red"]))
        #expect(p.tabs.map(\.title) == ["Color", "Toppings", "Submit"])
        let own = red.replacingOccurrences(of: "1. Red ✓", with: "1. Red").replacingOccurrences(of: "4. Type your own answer", with: "4. my own color✓")
        #expect(try #require(ScreenPrompt.parseOpenCode(screen: own)).shownAnswer(for: color) == AskAnswer(other: "my own color"))
        let none = red.replacingOccurrences(of: "1. Red ✓", with: "1. Red")
        #expect(try #require(ScreenPrompt.parseOpenCode(screen: none)).shownAnswer(for: color).isEmpty)
        let boxes = box(["Which toppings do you want?", "", "1. [✓] Cheese", "       Melted", "2. [ ] Olives", "       Black ones", "3. [✓] Basil", "       Fresh", "4. [✓] anchovies, lots"])
        let q = try #require(ScreenPrompt.parseOpenCode(screen: boxes))
        #expect(q.questionIndex(in: [color, toppings]) == 1)
        #expect(q.shownAnswer(for: toppings) == AskAnswer(chosen: ["Cheese", "Basil"], other: "anchovies, lots"))
        let review = (["  ┃  Questions", "  ┃", "  ┃  Color  Toppings  Submit", "  ┃", "  ┃  Color: my own color", "  ┃  Toppings: Cheese, Basil", "  ┃", "  ┃  ⇆ tab  enter submit  esc dismiss"]).joined(separator: "\n")
        #expect(ScreenPrompt.isOpenCodeReview(screen: review))
        #expect(!ScreenPrompt.isOpenCodeReview(screen: boxes))
    }
}
