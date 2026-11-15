import Testing
@testable import HerdrKit

/// OpenCode 2.3.0's questions as it drew them in narrow panes (2026-11-14).
struct OpenCodeQuestionTests {
    /// Descriptions wrapped over ten rows at 50 columns: still a question.
    @Test func longDescriptions() throws {
        let long = (1 ... 3).flatMap { n in
            [
                "  ┃  \(n). Choice \(n)",
                "  ┃     A long description that goes on and",
                "  ┃     on about choice \(n), A long description",
                "  ┃     that goes on and on about choice \(n), A",
                "  ┃     long description that goes on and on",
                "  ┃     about choice \(n), A long description",
                "  ┃     that goes on and on about choice \(n), A",
                "  ┃     long description that goes on and on",
                "  ┃     about choice \(n), A long description",
                "  ┃     that goes on and on about choice \(n),",
                "  ┃     Option \(n)",
            ]
        }
        let screen = [
            "",
            "     → Asked 1 question",
            "",
            "  ┃",
            "  ┃  Questions",
            "  ┃",
            "  ┃  Which one do you want?",
            "  ┃",
        ] + long + [
            "  ┃  4. Type your own answer",
            "  ┃",
            "  ┃  ↑↓ select  enter submit  esc dismiss",
            "  ┃",
        ]
        let p = try #require(ScreenPrompt.parseOpenCode(screen: screen.joined(separator: "\n")))
        #expect(p.options.map(\.label) == ["Choice 1", "Choice 2", "Choice 3", "Type your own answer"])
        #expect(p.options[1].detail.split(separator: "\n").count == 10)
        #expect(p.questionText == "Which one do you want?")
        let q = AskQuestion(question: "Which one do you want?", options: (1 ... 3).map { AskQuestion.Choice(label: "Choice \($0)") })
        #expect(p.asks(q))
        // The same text outside OpenCode's box stays text, not a question.
        #expect(ScreenPrompt.parse(screen: screen.map { $0.replacingOccurrences(of: "┃", with: " ") }.joined(separator: "\n")) == nil)
    }

    /// A wide pane (200 columns): OpenCode's side column shares the rows
    /// of its question box, from column 164.
    @Test func sideColumn() throws {
        func row(_ box: String, _ side: String = "") -> String {
            side.isEmpty ? box : box.padding(toLength: 164, withPad: " ", startingAt: 0) + side
        }
        let review = [
            String(repeating: " ", count: 162) + "⬖ Getting started                ✕",
            "",
            String(repeating: " ", count: 164) + "OpenCode includes free models so",
            "  ┃",
            row("  ┃  Questions", "Connect from 75+ providers to"),
            row("  ┃", "use other models, including"),
            row("  ┃  Pick  Submit", "Claude, GPT, Gemini etc"),
            "  ┃",
            row("  ┃  Pick: Choice 2, Choice 10", "Connect provider        /connect"),
            "  ┃",
            "  ┃  ⇆ tab  enter submit  esc dismiss",
            row("  ┃", "/…/65b29fc9-c67f-4…/scratchpad/oc/work"),
        ]
        #expect(ScreenPrompt.isOpenCodeReview(screen: review.joined(separator: "\n")))
        let question = [
            "  ┃",
            row("  ┃  Questions", "Connect from 75+ providers to"),
            row("  ┃", "use other models, including"),
            row("  ┃  Color  Toppings  Submit", "Claude, GPT, Gemini etc"),
            "  ┃",
            row("  ┃  Which color do you want?", "Connect provider        /connect"),
            "  ┃",
            row("  ┃  1. Red", "Context"),
            row("  ┃     A warm color", "12,4K tokens"),
            "  ┃  2. Blue",
            "  ┃     A cool color",
            "  ┃  3. Type your own answer",
            "  ┃",
            "  ┃  ⇆ tab  ↑↓ select  enter confirm  esc dismiss",
        ]
        let p = try #require(ScreenPrompt.parseOpenCode(screen: question.joined(separator: "\n")))
        #expect(p.options.map(\.label) == ["Red", "Blue", "Type your own answer"])
        #expect(p.options[0].detail == "A warm color")
        #expect(p.tabs.map(\.title) == ["Color", "Toppings", "Submit"])
        #expect(p.questionText == "Which color do you want?")
        #expect(!ScreenPrompt.isOpenCodeReview(screen: question.joined(separator: "\n")))
    }

    /// Eleven options, then its own: numbers past 9, which no key names.
    @Test func manyOptions() throws {
        let rows = (1 ... 11).flatMap { ["  ┃  \($0). Choice \($0)", "  ┃     Option \($0)"] }
        let screen = ["  ┃  Questions", "  ┃", "  ┃  Which one do you want?", "  ┃"] + rows
            + ["  ┃  12. Type your own answer", "  ┃", "  ┃  ↑↓ select  enter submit  esc dismiss", "  ┃"]
        let p = try #require(ScreenPrompt.parseOpenCode(screen: screen.joined(separator: "\n")))
        #expect(p.options.count == 12)
        #expect(p.options.last?.label == "Type your own answer")
        let q = AskQuestion(question: "Which one do you want?", options: (1 ... 11).map { AskQuestion.Choice(label: "Choice \($0)") })
        #expect(q.typeNumber == 12)
    }
}
