import Foundation
import SQLite3
import Testing
@testable import HerdrKit

/// A row as `OpenCodeTranscript` hands it over.
private func row(_ id: String, _ seq: Int, _ type: String, _ data: [String: Any], window: Int? = nil, name: String? = nil) -> Data {
    var o: [String: Any] = ["id": id, "seq": seq, "type": type, "data": data]
    if let window { o["window"] = window }
    if let name { o["modelName"] = name }
    return try! JSONSerialization.data(withJSONObject: o)
}

private var model: [String: Any] { ["id": "glm-5.3-flash-free", "providerID": "opencode", "variant": "max"] }

private func step(_ content: [[String: Any]], tokens: [String: Any]? = nil, created: Int = 1_794_465_899_921, error: [String: Any]? = nil) -> [String: Any] {
    var d: [String: Any] = ["time": ["created": created], "agent": "build", "model": model, "content": content]
    if let tokens { d["tokens"] = tokens }
    if let error { d["error"] = error }
    return d
}

private func tool(_ id: String, _ name: String, _ state: [String: Any]) -> [String: Any] {
    ["type": "tool", "id": id, "name": name, "state": state]
}

@Suite struct OpenCodeTranscriptTests {
    @Test func turnWithTools() {
        let t = Transcript.parse([
            row("m1", 4, "user", ["time": ["created": 1_794_465_899_890], "text": "Run ls, then create hello.txt", "files": [], "agents": []]),
            row("m2", 7, "assistant", step([
                ["type": "reasoning", "text": "Two independent steps."],
                tool("c1", "shell", ["status": "completed", "input": ["command": "ls"], "content": [["type": "text", "text": "hello.txt\nnotes.txt\n"]], "metadata": ["exit": 0]]),
                tool("c2", "write", ["status": "completed", "input": ["path": "hello.txt", "content": "hi"], "content": [["type": "text", "text": "Created file successfully: hello.txt"]]]),
            ], tokens: ["input": 14340, "output": 27, "reasoning": 49, "cache": ["read": 0, "write": 0]]), window: 200_000, name: "GLM-5.3-Flash Free"),
            row("m3", 20, "assistant", step([["type": "text", "text": "I ran `ls` and created `hello.txt`."]],
                                            tokens: ["input": 241, "output": 12, "reasoning": 15, "cache": ["read": 16320, "write": 0]], created: 1_794_465_901_496),
                window: 200_000, name: "GLM-5.3-Flash Free"),
            row("m4", 25, "idle", ["time": ["created": 1_794_465_910_109], "outcome": "succeeded"]),
        ], format: .opencode)
        let kinds = t.items.map(\.kind)
        #expect(kinds.count == 6)
        #expect(kinds[0] == .prompt("Run ls, then create hello.txt", images: 0))
        #expect(kinds[1] == .thinking("Two independent steps."))
        guard case .tool(let shell) = kinds[2], case .tool(let write) = kinds[3] else {
            Issue.record("tools expected")
            return
        }
        #expect(shell.name == "Shell")
        #expect(shell.input["command"]?.string == "ls")
        #expect(shell.result?.text == "hello.txt\nnotes.txt")
        #expect(shell.result?.isError == false)
        #expect(write.name == "Write")
        #expect(write.input["file_path"]?.string == "hello.txt")
        #expect(kinds[4] == .text("I ran `ls` and created `hello.txt`."))
        #expect(kinds[5] == .notice(.turnEnded(milliseconds: 10219)))
        #expect(t.facts.model == "glm-5.3-flash-free")
        #expect(t.facts.effort == "max")
        #expect(t.facts.agent == "build")
        #expect(t.facts.modelName == "GLM-5.3-Flash Free")
        #expect(t.facts.contextTokens == 16588)
        #expect(t.facts.contextWindow == 200_000)
        #expect(t.openCalls.isEmpty)
    }

    @Test func refusedCallAndStop() {
        let t = Transcript.parse([
            row("m1", 1, "user", ["time": ["created": 1], "text": "Run echo"]),
            row("m2", 2, "assistant", step([
                tool("c1", "shell", ["status": "error", "input": ["command": "echo swiftr-test"], "error": ["type": "aborted", "message": "The user declined this tool call"]]),
            ], error: ["type": "aborted", "message": "Step interrupted"])),
            row("m3", 3, "idle", ["time": ["created": 3], "outcome": "interrupted"]),
        ], format: .opencode)
        guard case .tool(let call) = t.items[1].kind else {
            Issue.record("a call expected")
            return
        }
        #expect(call.result?.declined == "")
        // The stop shows once, though the step and the turn's end both say it.
        #expect(t.items.count == 3)
        #expect(t.items[2].kind == .notice(.interrupted))
        // A refused call stops the step; no `idle` row may follow.
        let refused = Transcript.parse([
            row("m1", 1, "user", ["time": ["created": 1], "text": "Edit it"]),
            row("m2", 2, "assistant", step([
                tool("c1", "edit", ["status": "error", "input": ["path": "a.txt", "oldString": "x", "newString": "y"], "error": ["type": "aborted", "message": "The user declined this tool call"]]),
            ], error: ["type": "aborted", "message": "Step interrupted"])),
        ], format: .opencode)
        #expect(refused.items.last?.kind == .notice(.interrupted))
        #expect(refused.openCalls.isEmpty)
    }

    @Test func runningCallIsOpen() {
        let t = Transcript.parse([
            row("m1", 1, "user", ["time": ["created": 1], "text": "Ask me"]),
            row("m2", 2, "assistant", step([
                tool("q1", "question", ["status": "running", "input": ["questions": [
                    ["question": "Pick a fruit", "header": "Fruit", "options": [["label": "Apple", "description": "An apple"], ["label": "Pear", "description": "A pear"]]],
                    ["question": "Pick toppings", "header": "Toppings", "multiple": true, "options": [["label": "Sugar", "description": "Add sugar"]]],
                ]]]),
            ])),
        ], format: .opencode)
        let open = t.openCalls
        #expect(open.map(\.name) == ["AskUserQuestion"])
        let questions = AskQuestion.list(open[0].input)
        #expect(questions.map(\.question) == ["Pick a fruit", "Pick toppings"])
        #expect(questions.map(\.multiSelect) == [false, true])
        #expect(questions[0].options.map(\.label) == ["Apple", "Pear"])
    }

    @Test func answeredQuestionAndPatch() {
        let t = Transcript.parse([
            row("m2", 2, "assistant", step([
                tool("q1", "question", ["status": "completed", "input": ["questions": [["question": "Which color?", "header": "Color", "options": [["label": "Red"], ["label": "Blue"]]]]],
                                        "content": [["type": "text", "text": "User has answered your questions"]], "metadata": ["answers": [["Blue"]]]]),
                tool("e1", "edit", ["status": "completed", "input": ["path": "notes.txt", "oldString": "hello", "newString": "goodbye"],
                                    "content": [["type": "text", "text": "Edited notes.txt (1 replacement)"]],
                                    "metadata": ["files": [["file": "notes.txt", "patch": "--- notes.txt\n+++ notes.txt\n@@ -1,1 +1,1 @@\n-hello\n+goodbye\n", "status": "modified"]]]]),
                tool("e2", "edit", ["status": "running", "input": ["path": "a.txt", "oldString": "x", "newString": "y"]]),
            ])),
        ], format: .opencode)
        guard case .tool(let q) = t.items[0].kind, case .tool(let done) = t.items[1].kind, case .tool(let pending) = t.items[2].kind else {
            Issue.record("three calls expected")
            return
        }
        #expect(q.result?.answers == [ToolResult.Answer(question: "Which color?", answer: "Blue")])
        #expect(done.name == "Edit")
        #expect(done.input["diff"]?.string?.contains("+goodbye") == true)
        #expect(pending.input["old_string"]?.string == "x")
        #expect(pending.input["file_path"]?.string == "a.txt")
        #expect(pending.result == nil)
    }

    @Test func todosAndCompaction() {
        let t = Transcript.parse([
            row("m1", 1, "assistant", step([
                tool("t1", "todowrite", ["status": "completed", "input": ["todos": [
                    ["id": "1", "content": "Read the code", "status": "completed", "priority": "high"],
                    ["id": "2", "content": "Fix it", "status": "in_progress", "priority": "high"],
                    ["id": "3", "content": "Old idea", "status": "cancelled", "priority": "low"],
                ]]]),
            ])),
            row("m2", 2, "compaction", ["time": ["created": 5], "status": "completed", "reason": "auto", "summary": "## Objective\n- Fix it"]),
        ], format: .opencode)
        #expect(t.todos.map(\.text) == ["Read the code", "Fix it", "Old idea"])
        #expect(t.todos.map(\.status) == [.completed, .inProgress, .completed])
        #expect(t.items.last?.kind == .notice(.compacted(summary: "## Objective\n- Fix it")))
    }
}

@Suite struct OpenCodeScreenTests {
    @Test func permission() throws {
        let screen = """
             Build · GLM-5.3-Flash Free · 10.2s · 10.6 tok/s

          ┃
          ┃  ⠦ echo swiftr-test
          ┃

          ┃
          ┃  △ Permission required
          ┃
          ┃  $ echo swiftr-test
          ┃
          ┃
          ┃   Allow once   Always allow   Reject                                     ctrl+f fullscreen  ⇆ select  enter confirm
          ┃                                                                                            /…/scratchpad/octest:main
        """
        let p = try #require(ScreenPrompt.parseOpenCode(screen: screen))
        #expect(p.title == "Permission required")
        #expect(p.context == ["Permission required", "$ echo swiftr-test"])
        #expect(p.options.map(\.label) == ["Allow once", "Always allow", "Reject"])
        #expect(p.horizontal)
        #expect(p.footer == "ctrl+f fullscreen · ⇆ select · enter confirm")
        #expect(p.keys(for: p.options[0]) == ["enter"])
        #expect(p.keys(for: p.options[1]) == ["right", "enter"])
        #expect(p.keys(for: p.options[2]) == ["esc"])
        #expect(p.refusal?.label == "Reject")
    }

    @Test func editPermission() throws {
        let screen = """
          ┃  △ Permission required
          ┃    → Edit notes.txt
          ┃
          ┃  1 - hello                                                                  1 + goodbye
          ┃
          ┃
          ┃
          ┃   Allow once   Always allow   Reject                                     ctrl+f fullscreen  ⇆ select  enter confirm
        """
        let p = try #require(ScreenPrompt.parseOpenCode(screen: screen))
        #expect(p.context.first == "Permission required")
        #expect(p.context.dropFirst().first == "  → Edit notes.txt")
        #expect(p.context.contains { $0.contains("1 + goodbye") })
    }

    @Test func questions() throws {
        let screen = """
             → Asked 2 questions

          ┃
          ┃  Questions
          ┃
          ┃  Fruit  Toppings  Submit
          ┃
          ┃  Pick toppings
          ┃
          ┃  1. [✓] Sugar
          ┃         Add sugar
          ┃  2. [ ] Cream
          ┃         Add cream
          ┃  3. [ ] Type your own answer
          ┃
          ┃  ⇆ tab  ↑↓ select  enter toggle  esc dismiss
          ┃                                                                              /…/scratchpad/octest:main
        """
        let p = try #require(ScreenPrompt.parseOpenCode(screen: screen))
        #expect(p.questionText == "Pick toppings")
        #expect(p.tabs.map(\.title) == ["Fruit", "Toppings", "Submit"])
        #expect(p.options.map(\.label) == ["Sugar", "Cream", "Type your own answer"])
        #expect(p.options.map(\.checked) == [true, false, false])
        #expect(p.options[0].detail == "Add sugar")
        #expect(p.footer == "⇆ tab  ↑↓ select  enter toggle  esc dismiss")
        #expect(!p.horizontal)
        #expect(p.keys(for: p.options[1]) == ["2"])
    }

    @Test func oneQuestionAndReview() throws {
        let one = """
          ┃  Questions
          ┃
          ┃  Which color do you prefer?
          ┃
          ┃  1. Red
          ┃     You prefer red
          ┃  2. Blue
          ┃     You prefer blue
          ┃  3. Type your own answer
          ┃
          ┃  ↑↓ select  enter submit  esc dismiss
        """
        let p = try #require(ScreenPrompt.parseOpenCode(screen: one))
        #expect(p.tabs.isEmpty)
        #expect(p.questionText == "Which color do you prefer?")
        #expect(p.options.count == 3)
        #expect(!ScreenPrompt.isOpenCodeReview(screen: one))
        let review = """
          ┃  Questions
          ┃
          ┃  Fruit  Toppings  Submit
          ┃
          ┃  Fruit: Apple
          ┃  Toppings: Sugar, Honey, Maple
          ┃
          ┃  ⇆ tab  enter submit  esc dismiss
        """
        #expect(ScreenPrompt.parseOpenCode(screen: review) == nil)
        #expect(ScreenPrompt.isOpenCodeReview(screen: review))
    }

    /// OpenCode 1.1.47: no `Questions` line, a tab bar
    /// ending in `Confirm`, and `Review` for the answers.
    @Test func questionsOfOpenCode1() throws {
        let one = """
          ┃  Ask me a question about the button
          ┃
             → Asked 1 question
             ▣  Build · fake-1
          ┃
          ┃  Which color should the button be?
          ┃
          ┃  1. Red
          ┃     Warm and loud
          ┃  2. Blue
          ┃     Calm
          ┃  3. Type your own answer
          ┃
          ┃  ↑↓ select  enter submit  esc dismiss
          ┃
          /tmp/swiftr-ocfake/x                                                                  1.1.47
        """
        let p = try #require(ScreenPrompt.parseOpenCode(screen: one))
        #expect(p.questionText == "Which color should the button be?")
        #expect(p.tabs.isEmpty)
        #expect(p.options.map(\.label) == ["Red", "Blue", "Type your own answer"])
        #expect(p.options[0].detail == "Warm and loud")
        #expect(p.keys(for: p.options[1]) == ["2"])
        #expect(!ScreenPrompt.isOpenCodeReview(screen: one))

        let several = """
             ▣  Build · fake-1
          ┃
          ┃   Color   Toppings   Confirm
          ┃
          ┃  Which toppings do you want? (select all that apply)
          ┃
          ┃  1. [✓] Cheese
          ┃     Melted
          ┃  2. [ ] Olives
          ┃     Black ones
          ┃  3. [ ] Type your own answer
          ┃
          ┃  ⇆ tab  ↑↓ select  enter toggle  esc dismiss
          ┃
        """
        let s = try #require(ScreenPrompt.parseOpenCode(screen: several))
        #expect(s.tabs.map(\.title) == ["Color", "Toppings", "Confirm"])
        #expect(s.tabs.map(\.isSubmit) == [false, false, true])
        #expect(s.questionText == "Which toppings do you want? (select all that apply)")
        #expect(s.options.map(\.checked) == [true, false, false])
        #expect(s.asks(AskQuestion(header: "Toppings", question: "Which toppings do you want?", multiSelect: true, options: [])))

        let review = """
          ┃   Color   Toppings   Confirm
          ┃
          ┃  Review
          ┃
          ┃  Color: Red
          ┃
          ┃  Toppings: Cheese, Basil
          ┃
          ┃  ⇆ tab  enter submit  esc dismiss
          ┃
        """
        #expect(ScreenPrompt.parseOpenCode(screen: review) == nil)
        #expect(ScreenPrompt.isOpenCodeReview(screen: review))
    }

    /// A screen line: `under` from the left, then `box` from column `at`.
    private func line(_ under: String, _ box: String = "", at: Int = 60) -> String {
        guard !box.isEmpty else { return under }
        return under + String(repeating: " ", count: max(0, at - under.count)) + box
    }

    /// `name` and `aside` across a box 52 wide, `aside` at its right edge.
    private func item(_ name: String, _ aside: String) -> String {
        name + String(repeating: " ", count: 52 - name.count - aside.count) + aside
    }

    @Test func modelPicker() throws {
        let screen = [
            line("     + Thought · 5.0s"),
            line("", item("Select model", "esc"), at: 60),
            line("     Build · GLM-5.3-Flash Free · 30.0s"),
            line("", "Search", at: 60),
            line("  ┃"),
            line("  ┃  $ pwd", item("Big Pickle", "Free"), at: 60),
            line("  ┃  /private/tmp/a/folder/long-enough-to-run", "● " + item("GLM-5.3-Flash Free", "Free"), at: 58),
            line("     It's a scratch folder inside", item("Iceman Free", "Free"), at: 60),
            line(""),
            line("  ┃", "View all integrations ctrl+a  Favorite ctrl+f", at: 60),
            line("  ┃  Change the word goodbye to farewell"),
            line("  ┃"),
            line(""),
            line("  ┃  Build · GLM-5.3-Flash Free OpenCode · max"),
            line("  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"),
            line("  /tmp/octest:main            16.3K (8%)  ctrl+p commands"),
        ].joined(separator: "\n")
        let p = try #require(ScreenPrompt.openCodeDialog(screen: screen))
        #expect(p.title == "Select model")
        #expect(p.searchable)
        #expect(p.options.map(\.label) == ["Big Pickle", "GLM-5.3-Flash Free", "Iceman Free"])
        #expect(p.options.map(\.detail) == ["Free", "Free", "Free"])
        #expect(p.options.map(\.checked) == [false, true, false])
        #expect(p.footer.isEmpty)

        // Searched: the field shows what was typed, the list what it finds.
        let searched = [
            line("", item("Select model", "esc"), at: 60),
            line(""),
            line("", "flash", at: 60),
            line(""),
            line("", item("GLM-5.3-Flash Free", "Free"), at: 60),
            line("", item("MiMo-V2.6-Flash Free", "Free"), at: 60),
            line(""),
            line("", "View all integrations ctrl+a  Favorite ctrl+f", at: 60),
        ].joined(separator: "\n")
        #expect(ScreenPrompt.openCodeDialog(screen: searched)?.searchable == false)
        let found = try #require(ScreenPrompt.openCodeDialog(screen: searched, query: "Flash"))
        #expect(found.options.map(\.label) == ["GLM-5.3-Flash Free", "MiMo-V2.6-Flash Free"])
    }

    @Test func timelineOfOneDotOne() throws {
        // OpenCode 1.1.47's /timeline: two blank lines between its search and its list.
        let screen = [
            line("     ▣  Build · fake-1 · 239ms"),
            line(""),
            line("", item("Timeline", "esc"), at: 64),
            line(""),
            line("", "Search", at: 64),
            line(""),
            line(""),
            line("", item("say hi again", "1:07 PM"), at: 64),
            line("", item("write a file now", "1:07 PM"), at: 64),
            line(""),
            line(""),
            line("  ┃"),
            line("  ┃  Build  Stand-in 1 Stand-in"),
        ].joined(separator: "\n")
        let p = try #require(ScreenPrompt.openCodeDialog(screen: screen))
        #expect(p.title == "Timeline")
        #expect(p.searchable)
        #expect(p.options.map(\.label) == ["say hi again", "write a file now"])
        #expect(p.options.map(\.detail) == ["1:07 PM", "1:07 PM"])
    }

    @Test func timelinePickByTime() throws {
        // Searched for `say hi`: the older message first, as OpenCode 2.2.7 sorts it.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let sent = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 13, minute: 16)))
        #expect(Rewind.openCodePick(times: ["12:30 PM", "1:16 PM"], sent: sent, calendar: calendar) == 1)
        #expect(Rewind.openCodePick(times: ["13:16", "12:30"], sent: sent, calendar: calendar) == 0)
        #expect(Rewind.openCodePick(times: ["9:16 AM"], sent: sent, calendar: calendar) == 0)
        // Same minute: no telling which.
        #expect(Rewind.openCodePick(times: ["1:16 PM", "1:16 PM"], sent: sent, calendar: calendar) == nil)
        // On a machine five hours off: the minutes tell.
        #expect(Rewind.openCodePick(times: ["5:30 PM", "6:16 PM"], sent: sent, calendar: calendar) == 1)
        #expect(Rewind.openCodePick(times: ["Search", "x"], sent: sent, calendar: calendar) == nil)
        #expect(Rewind.minutes("12:05 AM") == 5)
        #expect(Rewind.minutes("13 h 16") == 796)
    }

    @Test func agentPickerAndPanel() throws {
        let screen = [
            line("", item("Select agent", "esc"), at: 60),
            line(""),
            line("", "Search", at: 60),
            line(""),
            line("ects-swiftr/976dbc05-", "● build The default agent. Executes tools", at: 58),
            line("", "plan Read-only agent for exploring the codebase", at: 60),
            line(""),
            line("ects-swiftr/976dbc05-"),
            line(""),
            line(""),
            line("  ┃  Build · GLM-5.3-Flash Free OpenCode · max"),
        ].joined(separator: "\n")
        let p = try #require(ScreenPrompt.openCodeDialog(screen: screen))
        #expect(p.options.map(\.label) == ["build", "plan"])
        #expect(p.options.map(\.detail) == ["The default agent. Executes tools", "Read-only agent for exploring the codebase"])
        #expect(p.options.first?.checked == true)

        // No search: a panel, its text to read.
        let panel = [
            line("", item("Status", "esc"), at: 60),
            line(""),
            line("", "2 MCP Servers", at: 60),
            line("", "• context7 Connected", at: 60),
            line(""),
            line(""),
            line("  ┃  Build · GLM-5.3-Flash Free OpenCode · max"),
        ].joined(separator: "\n")
        let shown = try #require(ScreenPrompt.openCodeDialog(screen: panel))
        #expect(!shown.searchable)
        #expect(shown.options.isEmpty)
        #expect(shown.context == ["Status", "2 MCP Servers", "• context7 Connected"])

        // The conversation alone shows no box.
        #expect(ScreenPrompt.openCodeDialog(screen: "  ┃  Build · GLM-5.3-Flash Free OpenCode · max\n  /tmp:main  16.3K (8%)  ctrl+p commands") == nil)
    }

    @Test func searchKeys() {
        #expect(ScreenPrompt.searchKeys("GLM-5.3 Free") == ["g", "l", "m", "-", "5", ".", "3", "space", "f", "r", "e", "e"])
        #expect(ScreenPrompt.searchText("Claude (Opus) 5/x") == "claude opus 5x")
    }

    @Test func footer() throws {
        let screen = """
             Build · GLM-5.3-Flash Free · 41.5s · 16.7 tok/s

          ┃
          ┃
          ┃
          ┃  Plan · GLM-5.3-Flash Free OpenCode · max
          ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
          /private/tmp/octest:main            16.4K (8%)  ctrl+p commands    /…/octest:main
        """
        let f = try #require(ClaudeFooter.parseOpenCode(screen: screen))
        #expect(f.mode == "plan")
        #expect(f.effort == "max")
        #expect(f.statusLine == ["Plan · GLM-5.3-Flash Free OpenCode · max", "16.4K (8%)"])
        #expect(f.model == "GLM-5.3-Flash Free OpenCode")
        // The default variant: none shown.
        let plain = try #require(ClaudeFooter.parseOpenCode(screen: screen.replacingOccurrences(of: "OpenCode · max", with: "OpenCode")))
        #expect(plain.model == "GLM-5.3-Flash Free OpenCode")
        #expect(plain.effort == nil)
        #expect(f.input == "")
        // At work: no input box shows a mode line.
        let working = screen.replacingOccurrences(of: "/private/tmp/octest:main            16.4K", with: "   ⬝⬝⬝⬝⬝⬝⬝⬝  esc interrupt     16.4K")
        let w = try #require(ClaudeFooter.parseOpenCode(screen: working))
        #expect(w.mode == "plan")
        #expect(w.busy)
        #expect(w.activity == nil)
        #expect(w.statusLine == ["Plan · GLM-5.3-Flash Free OpenCode · max", "16.4K (8%)"])
        #expect(!f.busy)
        // A question: no input box.
        #expect(ClaudeFooter.parseOpenCode(screen: "  ┃  Questions\n  ┃  1. Red\n  ┃  2. Blue") == nil)
    }

    /// OpenCode 1.1.47: the agent line spaced out,
    /// other hints, and while it waits to try again, why.
    @Test func footerOne() throws {
        let screen = """
              ┃
              ┃  Ask anything... "What is the tech stack of this project?"
              ┃
              ┃  Build  Big Pickle OpenCode
              ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
                                       ctrl+t variants  tab agents  ctrl+p commands
          /tmp/swiftr-ocreal/x                                                             1.1.47
        """
        let f = try #require(ClaudeFooter.parseOpenCode(screen: screen))
        #expect(f.mode == "build")
        #expect(f.model == "Big Pickle OpenCode")
        #expect(f.effort == nil)
        #expect(f.input == "")
        #expect(f.statusLine == ["Build · Big Pickle OpenCode"])
        #expect(!f.busy)
        let typed = try #require(ClaudeFooter.parseOpenCode(screen: screen.replacingOccurrences(of: #"Ask anything... "What is the tech stack of this project?""#, with: "Say hi in one word.")))
        #expect(typed.input == "Say hi in one word.")
        let retrying = screen.replacingOccurrences(
            of: "ctrl+t variants  tab agents  ctrl+p commands",
            with: "■■⬝⬝⬝⬝⬝⬝ Free usage limit reached. Free models work in OpenCode (https://opencode.ai); su... (click to expand) [retrying in 10h 31m attempt #1]          esc interrupt")
        let r = try #require(ClaudeFooter.parseOpenCode(screen: retrying))
        #expect(r.busy)
        #expect(r.activity == "Retrying in 10h 31m (attempt 1): Free usage limit reached. Free models work in OpenCode (https://opencode.ai); su…")
        #expect(r.statusLine == ["Build · Big Pickle OpenCode"])
        // Its first Esc asks for a second.
        let again = screen.replacingOccurrences(of: "ctrl+t variants  tab agents  ctrl+p commands", with: "⬝⬝⬝⬝⬝⬝⬝⬝          esc again to interrupt")
        #expect(ClaudeFooter.parseOpenCode(screen: again)?.busy == true)
        // A line of typing is no agent line.
        #expect(ClaudeFooter.parseOpenCode(screen: "  ┃  Hello\n  ╹▀▀▀▀▀▀▀▀") == nil)
    }

    @Test func panelBesideTheBoxIsNotTyped() throws {
        // A wide screen: OpenCode's `Getting started` panel sits right of its input box.
        let pad = String(repeating: " ", count: 60)
        let screen = [
            "  ┃" + pad + "        Claude, GPT, Gemini etc",
            "  ┃",
            "  ┃" + pad + "        Connect provider        /connect",
            "  ┃  Build · Stand-in 1 Stand-in",
            "  ╹" + String(repeating: "▀", count: 58),
            "  /tmp/x:main              1.2K (1%)  ctrl+p commands",
        ].joined(separator: "\n")
        let footer = try #require(ClaudeFooter.parseOpenCode(screen: screen))
        #expect(footer.input == "")
        #expect(footer.mode == "build")
        #expect(footer.model == "Stand-in 1 Stand-in")
    }
}

@Suite struct OpenCodeStoreTests {
    /// A database shaped as OpenCode 2.2's, with a session of three rows.
    private func database() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "opencode-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let catalog = #"{"opencode":{"id":"opencode","name":"OpenCode","models":{"glm-5.3-flash-free":{"name":"GLM-5.3-Flash Free","limit":{"context":200000,"output":32000}}}}}"#
        let value = try String(decoding: JSONSerialization.data(withJSONObject: ["updatedAt": 1, "body": catalog]), as: UTF8.self)
        let sql = """
        create table session_v2 (id text primary key, project_id text, parent_id text, slug text, directory text, title text, version text,
          time_created integer, time_updated integer, time_archived integer);
        create table session_message (id text primary key, session_id text, type text, seq integer, time_created integer, time_updated integer, data text);
        create table kv (key text primary key, value text);
        insert into session_v2 values ('ses_old', 'p', null, 's', '/work', 'Older', '2', 1000, 1000, null);
        insert into session_v2 values ('ses_new', 'p', null, 's', '/work', 'Newer', '2', 5000, 9000, null);
        insert into session_v2 values ('ses_child', 'p', 'ses_new', 's', '/work', 'Sub-agent', '2', 9500, 9900, null);
        insert into session_message values ('m1', 'ses_new', 'user', 4, 5000, 5000, '{"time":{"created":5000},"text":"Hello"}');
        insert into session_message values ('m2', 'ses_new', 'assistant', 7, 5100, 5200, '{"time":{"created":5100},"agent":"build","model":{"id":"glm-5.3-flash-free","providerID":"opencode","variant":"max"},"content":[{"type":"text","text":"Hi"}],"tokens":{"input":10,"output":2,"reasoning":0,"cache":{"read":0,"write":0}}}');
        insert into session_message values ('m3', 'ses_new', 'idle', 9, 5300, 5300, '{"time":{"created":5300},"outcome":"succeeded"}');
        """
        let insert = "insert into kv values ('models-dev:v2:catalog', '\(value.replacingOccurrences(of: "'", with: "''"))');"
        #expect(sqlite3_exec(db, sql + insert, nil, nil, nil) == SQLITE_OK)
        return url
    }

    private func exec(_ url: URL, _ sql: String) {
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func findsTheSession() throws {
        let url = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(OpenCodeStore.session(argv: ["opencode"], directory: "/work", started: Date(timeIntervalSince1970: 4), db: url) == "ses_new")
        // Started after the last change: a new session, not written yet.
        #expect(OpenCodeStore.session(argv: ["opencode"], directory: "/work", started: Date(timeIntervalSince1970: 60), db: url) == nil)
        #expect(OpenCodeStore.session(argv: ["opencode", "-c"], directory: "/work", started: Date(timeIntervalSince1970: 60), db: url) == "ses_new")
        #expect(OpenCodeStore.session(argv: ["opencode", "--session", "ses_old"], directory: "/work", started: nil, db: url) == "ses_old")
        #expect(OpenCodeStore.session(argv: ["opencode"], directory: "/elsewhere", started: nil, db: url) == nil)
        #expect(OpenCodeStore.title(of: "ses_new", db: url) == "Newer")
    }

    @Test func readsAndFollows() async throws {
        let url = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = OpenCodeTranscript(db: url, session: "ses_new")
        let lines = try await source.openTail(lines: 100, maxBytes: 1 << 20)
        #expect(lines.count == 3)
        #expect(await source.atStart)
        var t = Transcript.parse(lines, format: .opencode)
        #expect(t.items.map(\.kind) == [.prompt("Hello", images: 0), .text("Hi"), .notice(.turnEnded(milliseconds: 300))])
        #expect(t.facts.contextWindow == 200_000)
        #expect(t.facts.modelName == "GLM-5.3-Flash Free")
        #expect(t.facts.providerName == "OpenCode")
        #expect(t.facts.contextTokens == 12)
        // Nothing new.
        #expect(try await source.readNew() == [])
        // A new row comes.
        exec(url, #"insert into session_message values ('m4', 'ses_new', 'user', 12, 6000, 6000, '{"time":{"created":6000},"text":"Again"}');"#)
        let more = try #require(try await source.readNew())
        #expect(more.count == 1)
        t.append(more)
        #expect(t.items.last?.kind == .prompt("Again", images: 0))
        // A row already read changes: read the session again.
        exec(url, #"update session_message set time_updated = 7000, data = '{"time":{"created":5100},"content":[{"type":"text","text":"Hi there"}]}' where id = 'm2';"#)
        #expect(try await source.readNew() == nil)
    }

    @Test func idleAgainIsNoSecondEnd() async throws {
        let url = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        // After a /redo, OpenCode writes another idle row.
        exec(url, #"insert into session_message values ('m4', 'ses_new', 'idle', 12, 9000, 9000, '{"time":{"created":9000},"outcome":"succeeded"}');"#)
        let source = OpenCodeTranscript(db: url, session: "ses_new")
        let t = Transcript.parse(try await source.openTail(lines: 100, maxBytes: 1 << 20), format: .opencode)
        #expect(t.items.map(\.kind) == [.prompt("Hello", images: 0), .text("Hi"), .notice(.turnEnded(milliseconds: 300))])
    }

    @Test func revertHidesLaterRows() async throws {
        let url = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        exec(url, """
        alter table session_v2 add column revert text;
        insert into session_message values ('m4', 'ses_new', 'user', 12, 6000, 6000, '{"time":{"created":6000},"text":"Write it"}');
        insert into session_message values ('m5', 'ses_new', 'assistant', 13, 6100, 6100, '{"time":{"created":6100},"content":[{"type":"text","text":"Wrote it"}]}');
        """)
        let source = OpenCodeTranscript(db: url, session: "ses_new")
        var t = Transcript.parse(try await source.openTail(lines: 100, maxBytes: 1 << 20), format: .opencode)
        #expect(t.items.last?.kind == .text("Wrote it"))
        // The timeline's Revert at "Write it": it and what follows go out of sight.
        exec(url, #"update session_v2 set revert = '{"messageID":"m4","snapshot":"abc","files":[{"file":"hello.txt","status":"deleted","additions":0,"deletions":1}]}' where id = 'ses_new';"#)
        #expect(try await source.readNew() == nil)
        t = Transcript.parse(try await source.openTail(lines: 100, maxBytes: 1 << 20), format: .opencode)
        #expect(!t.items.contains { $0.kind == .prompt("Write it", images: 0) })
        #expect(t.items.last?.kind == .notice(.reverted(messages: 1, files: [RevertedFile(path: "hello.txt", status: "deleted", additions: 0, deletions: 1)])))
        #expect(try await source.readNew() == [])
        // /redo: all of it back.
        exec(url, "update session_v2 set revert = null where id = 'ses_new';")
        #expect(try await source.readNew() == nil)
        t = Transcript.parse(try await source.openTail(lines: 100, maxBytes: 1 << 20), format: .opencode)
        #expect(t.items.last?.kind == .text("Wrote it"))
    }

    @Test func earlierRows() async throws {
        let url = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = OpenCodeTranscript(db: url, session: "ses_new")
        let tail = try await source.openTail(lines: 2, maxBytes: 1 << 20)
        #expect(tail.count == 2)
        #expect(await source.atStart == false)
        let earlier = try await source.readEarlier(lines: 10, maxBytes: 1 << 20)
        #expect(earlier.count == 1)
        #expect(await source.atStart)
    }
}
