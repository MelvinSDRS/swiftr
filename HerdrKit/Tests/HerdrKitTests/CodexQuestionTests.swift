import Testing
@testable import HerdrKit

/// Codex 0.169's questions (`request_user_input`) in short panes, and its
/// check before answers that leave a question out, as it drew them in a
/// 60×14, 60×11 and 50×9 terminal (2026-11-14).
struct CodexQuestionTests {
    let choices = [
        AskQuestion.Choice(label: "Red (Recommended)", detail: "Warm and loud, it draws the eye to the call to action at once."),
        AskQuestion.Choice(label: "Blue", detail: "Cool and calm, it matches the rest of the site and its logo."),
        AskQuestion.Choice(label: "Green", detail: "Fresh, it says go, but it may clash with the photos."),
    ]
    let question = [
        "",
        "  Question 1/1 (1 unanswered)",
        "  Which color do you want for the new landing page header",
        "  and its buttons?",
        "",
    ]
    let hint = ["", "  option 3/4 | tab to add notes | enter to submit answer", "  esc to interrupt", ""]

    /// The cursor down the list: options 2 to 4 in sight, 1 above them.
    @Test func listScrolledDown() throws {
        let screen = question + [
            "    2. Blue               Cool and calm, it matches the",
            "                          rest of the site and its logo.",
            "  › 3. Green              Fresh, it says go, but it may",
            "                          clash with the photos.",
            "    4. None of the above  Optionally, add details in notes",
        ] + hint
        let p = try #require(ScreenPrompt.parse(screen: screen.joined(separator: "\n")))
        #expect(p.options.map(\.label) == ["Blue", "Green", "None of the above"])
        #expect(p.options.map(\.number) == [2, 3, 4])
        #expect(p.options.first(where: \.focused)?.label == "Green")
        #expect(p.listTotal == 4)
        #expect(p.questionText == "Question 1/1 (1 unanswered)\nWhich color do you want for the new landing page header\nand its buttons?")
        #expect(p.footer == "tab to add notes | enter to submit answer")
        let whole = p.wholeList(choices)
        #expect(whole.options.map(\.label) == ["Red (Recommended)", "Blue", "Green", "None of the above"])
        #expect(whole.options.map(\.number) == [1, 2, 3, 4])
        #expect(whole.options[0].detail == choices[0].detail)
        #expect(whole.options.first(where: \.focused)?.number == 3)
        // A digit picks an option out of sight too.
        #expect(whole.keys(for: whole.options[0]) == ["1"])
    }

    /// One option in sight, the cursor's.
    @Test func oneOptionInSight() throws {
        let screen = question + [
            "  › 3. Green              Fresh, it says go, but it may",
            "                          clash with the photos.",
        ] + hint
        let p = try #require(ScreenPrompt.parse(screen: screen.joined(separator: "\n")))
        #expect(p.options.map(\.label) == ["Green"])
        #expect(p.options.first?.detail == "Fresh, it says go, but it may\nclash with the photos.")
        let whole = p.wholeList(choices)
        #expect(whole.options.map(\.label) == ["Red (Recommended)", "Blue", "Green", "None of the above"])
        #expect(whole.options[2].focused)
        #expect(whole.options[2].detail == "Fresh, it says go, but it may clash with the photos.")
    }

    /// 50×9: the question right over the first option, no blank row between.
    @Test func narrowAndShort() throws {
        let screen = [
            "",
            "  Question 1/1 (1 unanswered)",
            "  Which color do you want for the new landing",
            "  page header and its buttons?",
            "  › 1. Red (Recommended)  Warm and loud, it",
            "",
            "  option 1/4 | tab to add notes",
            "  enter to submit answer | esc to interrupt",
            "",
        ]
        let p = try #require(ScreenPrompt.parse(screen: screen.joined(separator: "\n")))
        #expect(p.options.map(\.label) == ["Red (Recommended)"])
        #expect(p.questionText.hasSuffix("page header and its buttons?"))
        #expect(p.footer == "tab to add notes")
        #expect(p.wholeList(choices).options.count == 4)
    }

    /// The cursor on the first: options 1 to 3 in sight, `None of the above` under them.
    @Test func lastOutOfSight() throws {
        let screen = question + [
            "  › 1. Red (Recommended)  Warm and loud, it draws the eye",
            "                          to the call to action at once.",
            "    2. Blue               Cool and calm, it matches the",
            "                          rest of the site and its logo.",
            "    3. Green              Fresh, it says go, but it may",
            "",
            "  option 1/4 | tab to add notes | enter to submit answer",
            "  esc to interrupt",
        ]
        let p = try #require(ScreenPrompt.parse(screen: screen.joined(separator: "\n")))
        #expect(p.options.map(\.number) == [1, 2, 3])
        let whole = p.wholeList(choices)
        #expect(whole.options.last?.label == "None of the above")
        #expect(whole.options.last?.number == 4)
        // A call that holds another count leaves the list as it shows.
        #expect(p.wholeList(Array(choices.prefix(1))).options.count == 3)
    }

    /// Answers leaving a question out: a digit only moves Codex's cursor, Enter picks.
    @Test func submitCheck() throws {
        let screen = [
            "  • Thanks, noted.",
            "",
            "› ask two",
            "",
            "",
            "",
            "  Submit with unanswered questions?",
            "  1 unanswered question",
            "",
            "  › 1. Proceed  Submit with 1 unanswered question",
            "    2. Go back  Return to the first unanswered question",
            "",
            "  Press enter to confirm or esc to go back",
        ]
        let p = try #require(ScreenPrompt.parse(screen: screen.joined(separator: "\n")))
        #expect(p.isCodexSubmitCheck)
        #expect(p.questionText == "Submit with unanswered questions?\n1 unanswered question")
        #expect(p.options.map(\.label) == ["Proceed", "Go back"])
        #expect(p.keys(for: p.options[1]) == ["2", "enter"])
        #expect(p.listTotal == nil)
    }

    /// Codex's approval takes its digit at once.
    @Test func approvalTakesDigit() throws {
        let screen = [
            "  Would you like to run the following command?",
            "",
            "  Reason: Stand-in asks to run a command",
            "",
            "  $ echo held-test",
            "",
            "",
            "› 1. Yes, proceed (y)",
            "  2. Yes, and don't ask again for commands that start with `echo held-test` (p)",
            "  3. No, and tell Codex what to do differently (esc)",
            "",
            "  Press enter to confirm or esc to cancel",
        ]
        let p = try #require(ScreenPrompt.parse(screen: screen.joined(separator: "\n")))
        #expect(!p.isCodexSubmitCheck)
        #expect(p.keys(for: p.options[0]) == ["1"])
    }

    /// The whole list in a tall pane: no window.
    @Test func wholeListShown() throws {
        let screen = [
            "  Question 1/2 (2 unanswered)",
            "  Which color do you want?",
            "",
            "  › 1. Red                Warm",
            "    2. Blue               Cool",
            "    3. None of the above  Optionally, add details in notes (tab)",
            "",
            "  tab to add notes | enter to submit answer | ←/→ to navigate questions | esc to interrupt",
        ]
        let p = try #require(ScreenPrompt.parse(screen: screen.joined(separator: "\n")))
        #expect(p.listTotal == nil)
        #expect(p.options.count == 3)
        #expect(p.wholeList([AskQuestion.Choice(label: "Red")]) == p)
    }
}
