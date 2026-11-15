import Foundation
import Testing
@testable import HerdrKit

/// Gemini CLI 0.68's screens, as `hc read` gave them (long rules and
/// runs of spaces cut, the folder's path changed).
enum GeminiScreens {
    static let ask1 = """
         > Ask me a question
        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀

        ╭────────────────────────────────────────╮
        │ Answer Questions  │
        │  │
        │ Which color should the button be?  │
        │  │
        │ ● 1.  Red  │
        │       Warm and loud  │
        │   2.  Blue  │
        │       Calm  │
        │   3.  Enter a custom value  │
        │  │
        │ Enter to select · ↑/↓ to navigate · Esc to cancel  │
        ╰────────────────────────────────────────╯
        """

    static let ask3_q2b = """
         > Ask me three things
        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀

        ╭────────────────────────────────────────╮
        │ Answer Questions  │
        │  │
        │ ← ✓ Color │ ✓ Toppings │ □ Ship │ ≡ Review →  │
        │  │
        │ Which toppings do you want?  │
        │ (Select all that apply)  │
        │  │
        │ ▲  │
        │   1. [x] Cheese  │
        │          Melted  │
        │   2. [x] Olives  │
        │          Black ones  │
        │ ● 3. [x] All of the above  │
        │          Select all options  │
        │ ▼  │
        │  │
        │ Enter to select · ←/→ to switch questions · Esc to cancel  │
        ╰────────────────────────────────────────╯
        """

    /// The list whole after ⌃O (2026-11-14): `Done` under the line for
    /// one's own words, with no number.
    static let ask3_whole = """
        ╭────────────────────────────────────────╮
        │ Answer Questions  │
        │  │
        │ ← □ Color │ □ Label │ □ Toppings │ ≡ Review →  │
        │  │
        │ Which toppings do you want?  │
        │ (Select all that apply)  │
        │  │
        │ ● 1. [x] Cheese  │
        │          Melted  │
        │   2. [ ] Olives  │
        │          Black ones  │
        │   3. [ ] All of the above  │
        │          Select all options  │
        │   4. [x] abc  │
        │    Done  │
        │    Finish selection  │
        │  │
        │ Enter to select · ←/→ to switch questions · Esc to cancel  │
        ╰────────────────────────────────────────╯
        """

    /// Held to the screen again, the cursor on `Done`: the list from 3.
    static let ask3_done = """
        ╭────────────────────────────────────────╮
        │ Answer Questions  │
        │  │
        │ ← □ Color │ □ Label │ □ Toppings │ ≡ Review →  │
        │  │
        │ Which toppings do you want?  │
        │ (Select all that apply)  │
        │  │
        │ ▲  │
        │   3. [ ] All of the above  │
        │          Select all options  │
        │   4. [x] abc  │
        │ ●  Done  │
        │    Finish selection  │
        │ ▼  │
        │  │
        │ Enter to select · ←/→ to switch questions · Esc to cancel  │
        ╰────────────────────────────────────────╯
        """

    static let ask3_review = """
         > Ask me three things
        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀

        ╭────────────────────────────────────────╮
        │ Answer Questions  │
        │  │
        │ ← ✓ Color │ ✓ Toppings │ ✓ Ship │ ≡ Review →  │
        │  │
        │ Review your answers:  │
        │  │
        │ Color → Red  │
        │ Toppings → Cheese, Olives  │
        │ Ship → Yes  │
        │  │
        │ Enter to submit · Tab/Shift+Tab to edit answers · Esc to cancel  │
        ╰────────────────────────────────────────╯
        """

    static let ask_text = """
        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀

        ╭────────────────────────────────────────╮
        │ Answer Questions  │
        │  │
        │ ← □ Name │ □ Color │ ≡ Review →  │
        │  │
        │ What should the file be called?  │
        │  │
        │ > e.g. notes.txt  │
        │  │
        │  │
        │ Enter to submit · Tab/Shift+Tab to switch questions · Esc to cancel  │
        ╰────────────────────────────────────────╯
        """

    static let ask_custom = """
        ╭────────────────────────────────────────╮
        │ Answer Questions  │
        │  │
        │ ← ✓ Name │ □ Color │ ≡ Review →  │
        │  │
        │ Which color should the button be?  │
        │  │
        │   1.  Red  │
        │       Warm and loud  │
        │   2.  Blue  │
        │       Calm  │
        │ ● 3.  Enter a custom value  │
        │  │
        │ Enter to submit · Tab/Shift+Tab to switch questions · Esc to cancel  │
        ╰────────────────────────────────────────╯
        """

    static let shell_ask = """
        ✦ I'll make the file, after a pause.

        ╭────────────────────────────────────────╮
        │ ? Shell  sleep 12; touch made.txt; echo made  │
        │ ╭────────────────────────────────────────╮ │
        │ │ sleep 12; touch made.txt; echo made  │ │
        │ ╰────────────────────────────────────────╯ │
        │ Allow execution of [Shell]?  │
        │  │
        │ ● 1. Allow once  │
        │   2. Allow for this session  │
        │   3. No, suggest changes (esc)  │
        ╰────────────────────────────────────────╯
        """

    static let write_new = """
        ╭────────────────────────────────────────╮
        │ ? WriteFile  Writing to fresh.txt  │
        │ ╭────────────────────────────────────────╮ │
        │ │ 1 one  │ │
        │ │ 2 two  │ │
        │ │ 3 three  │ │
        │ ╰────────────────────────────────────────╯ │
        │ Apply this change?  │
        │  │
        │ ● 1. Allow once  │
        │   2. Allow for this session  │
        │   3. Modify with external editor  │
        │   4. No, suggest changes (esc)  │
        ╰────────────────────────────────────────╯
        """

    static let edit_ask = """
        ╭────────────────────────────────────────╮
        │ ? Edit  fresh.txt: two => deux  │
        │ ╭────────────────────────────────────────╮ │
        │ │ 1   one  │ │
        │ │ 2 - two  │ │
        │ │ 2 + deux  │ │
        │ │ 3   three  │ │
        │ ╰────────────────────────────────────────╯ │
        │ Apply this change?  │
        │  │
        │ ● 1. Allow once  │
        │   2. Allow for this session  │
        │   3. Modify with external editor  │
        │   4. No, suggest changes (esc)  │
        ╰────────────────────────────────────────╯
        """

    static let queued = """
        ╰────────────────────────────────────────╯


          Queued (press ↑ to edit):
            Ask me three things

         ⠧ Thinking... (esc to cancel, 8s)  ? for shortcuts
        ────────────────────────────────────────
         Shift+Tab to accept edits
        ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
         >   Type your message or @path/to/file
        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
         workspace (/directory)                                                                                                                            sandbox                                       /model
         /Users/me/x                                                                                                                                       no sandbox                                      Auto
        """

    static let shell_working = """
        ╭────────────────────────────────────────╮
        │ ⊶  Shell sleep 12; touch made.txt; echo made  │
        │  │
        ╰────────────────────────────────────────╯


         ⠋ Thinking... (esc to cancel, 2s)  ? for shortcuts
        ────────────────────────────────────────
         Shift+Tab to accept edits
        ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
         >   Type your message or @path/to/file
        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
         workspace (/directory)                                                                                                                            sandbox                                       /model
         /Users/me/x                                                                                                                                       no sandbox                                      Auto
        """

    static let ls_done = """

          ? for shortcuts
        ────────────────────────────────────────
         Shift+Tab to accept edits
        ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
         >   Type your message or @path/to/file
        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
         workspace (/directory)                                                                                                                            sandbox                                       /model
         /Users/me/x                                                                                                                                       no sandbox                                      Auto
        """

    static let write_ask = """
        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀

        ╭────────────────────────────────────────╮
        │ ? WriteFile  Writing to hello.txt  │
        │ ╭────────────────────────────────────────╮ │
        │ │ 1 - hello again  │ │
        │ │ 1 + hello from the stand-in  │ │
        │ ╰────────────────────────────────────────╯ │
        │ Apply this change?  │
        │  │
        │ ● 1. Allow once  │
        │   2. Allow for this session  │
        │   3. Modify with external editor  │
        │   4. No, suggest changes (esc)  │
        ╰────────────────────────────────────────╯
        """

}

/// One of Gemini's chat lines.
private func line(_ o: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: o)
}

private let header = line(["sessionId": "ad87a94e-30b7", "projectHash": "2b52", "startTime": "2026-11-12T16:32:08.450Z", "lastUpdated": "2026-11-12T16:32:08.450Z", "kind": "main"])
private let context = line(["id": "d049", "timestamp": "2026-11-12T16:32:08.451Z", "type": "user", "content": [["text": "<session_context>\nThis is the Gemini CLI."]]])
private let model = "gemini-3.1-pro-preview-customtools"
private var tokens: [String: Any] { ["input": 12000, "output": 60, "cached": 0, "thoughts": 0, "tool": 0, "total": 12060] }

private func user(_ id: String, _ text: String) -> Data {
    line(["id": id, "timestamp": "2026-11-12T16:32:12.937Z", "type": "user", "content": [["text": text]]])
}

private func gemini(_ id: String, _ text: String, thoughts: [[String: Any]] = [], calls: [[String: Any]]? = nil) -> Data {
    var o: [String: Any] = ["id": id, "timestamp": "2026-11-12T16:32:12.957Z", "type": "gemini", "content": text, "thoughts": thoughts, "tokens": tokens, "model": model]
    if let calls { o["toolCalls"] = calls }
    return line(o)
}

private func call(_ id: String, _ name: String, _ args: [String: Any], status: String, output: String? = nil, error: String? = nil, display: Any? = nil) -> [String: Any] {
    var response: [String: Any] = [:]
    if let output { response["output"] = output }
    if let error { response["error"] = error }
    var c: [String: Any] = ["id": id, "name": name, "args": args, "status": status, "timestamp": "2026-11-12T16:32:31.077Z",
                            "result": [["functionResponse": ["id": id, "name": name, "response": response]]]]
    if let display { c["resultDisplay"] = display }
    return c
}

private func results(_ id: String, _ name: String, output: String) -> Data {
    line(["id": "r-" + id, "timestamp": "2026-11-12T16:32:31.079Z", "type": "user", "content": [["functionResponse": ["id": id, "name": name, "response": ["output": output]]]]])
}

private var askArgs: [String: Any] { ["questions": [
    ["question": "Which color should the button be?", "header": "Color", "type": "choice", "options": [["label": "Red", "description": "Warm and loud"], ["label": "Blue", "description": "Calm"]]],
    ["question": "Which toppings do you want?", "header": "Toppings", "type": "choice", "multiSelect": true, "options": [["label": "Cheese", "description": "Melted"], ["label": "Olives", "description": "Black ones"]]],
    ["question": "Ship it today?", "header": "Ship", "type": "yesno"],
]] }

@Suite struct GeminiTranscriptTests {
    @Test func turnsWithCalls() {
        let shell = call("sh1", "run_shell_command", ["command": "sleep 12; touch made.txt; echo made", "description": "Make a file after a pause", "dir_path": "/Users/me/x"],
                         status: "success", output: "<untrusted_context>\nOutput: made\nProcess Group PGID: 47846\n</untrusted_context>")
        let ask = call("ask1", "ask_user", askArgs, status: "success", output: #"{"answers":{"0":"Red","1":"Cheese, Olives","2":"Yes"}}"#)
        let diff = "Index: hello.txt\n===================================================================\n--- hello.txt\tCurrent\n+++ hello.txt\tProposed\n@@ -1,1 +1,1 @@\n-hello from the stand-in\n+hello again\n"
        let edit = call("ed1", "replace", ["file_path": "/Users/me/x/hello.txt", "old_string": "hello from the stand-in", "new_string": "hello again", "instruction": "Change the greeting"],
                        status: "success", output: "Successfully modified file: /Users/me/x/hello.txt (1 replacements).", display: ["fileDiff": diff, "fileName": "hello.txt"])
        let t = Transcript.parse([
            header, context,
            user("u1", "Make a file after a pause"),
            gemini("g1", "I'll make the file, after a pause.", thoughts: [["subject": "Checking the folder", "description": "I should look before I touch anything.", "timestamp": "2026-11-12T16:32:12.957Z"]], calls: [shell]),
            results("sh1", "run_shell_command", output: "Output: made"),
            gemini("g2", "Made `made.txt`."),
            user("u2", "Ask me three things"),
            gemini("g3", "", calls: [ask]),
            gemini("g4", "", calls: [edit]),
        ], format: .gemini)
        let kinds = t.items.map(\.kind)
        guard kinds.count == 8 else {
            Issue.record("\(kinds)")
            return
        }
        #expect(kinds[0] == .prompt("Make a file after a pause", images: 0))
        #expect(kinds[1] == .thinking("**Checking the folder**\nI should look before I touch anything."))
        #expect(kinds[2] == .text("I'll make the file, after a pause."))
        guard case .tool(let s) = kinds[3] else { return }
        #expect(s.name == "Shell")
        #expect(s.input["command"]?.string == "sleep 12; touch made.txt; echo made")
        #expect(s.result?.text == "made")
        #expect(s.result?.isError == false)
        #expect(kinds[4] == .text("Made `made.txt`."))
        #expect(kinds[5] == .prompt("Ask me three things", images: 0))
        guard case .tool(let q) = kinds[6] else { return }
        #expect(q.name == "AskUserQuestion")
        #expect(q.input["questions"]?.array?.count == 3)
        #expect(q.input["questions"]?.array?[2]["options"]?.array?.compactMap { $0["label"]?.string } == ["Yes", "No"])
        #expect(q.input["questions"]?.array?[1]["multiSelect"] == .bool(true))
        #expect(q.result?.answers.map(\.answer) == ["Red", "Cheese, Olives", "Yes"])
        #expect(q.result?.answers.first?.question == "Which color should the button be?")
        guard case .tool(let e) = kinds[7] else { return }
        #expect(e.name == "Edit")
        #expect(e.input["diff"]?.string == "@@ -1,1 +1,1 @@\n-hello from the stand-in\n+hello again\n")
        #expect(t.facts.model == model)
        #expect(t.facts.contextTokens == 12060)
        #expect(t.facts.contextWindow == 1_048_576)
    }

    @Test func refusedAndStopped() {
        let refused = call("w1", "write_file", ["file_path": "/Users/me/x/notes.txt", "content": "first line\n"], status: "cancelled", error: "[Operation Cancelled] Reason: User denied execution.")
        let stopped = call("s1", "run_shell_command", ["command": "sleep 30", "description": "Wait a while"], status: "cancelled", error: "[Operation Cancelled] Reason: User cancelled operation")
        let t = Transcript.parse([
            gemini("g1", "", calls: [refused]),
            gemini("g2", "", calls: [stopped]),
            line(["id": "i1", "timestamp": "2026-11-12T16:33:05.797Z", "type": "info", "content": "Request cancelled."]),
            line(["id": "e1", "timestamp": "2026-11-12T16:33:06.000Z", "type": "error", "content": "Quota exceeded."]),
        ], format: .gemini)
        guard t.items.count == 4, case .tool(let w) = t.items[0].kind, case .tool(let s) = t.items[1].kind else {
            Issue.record("\(t.items.map(\.kind))")
            return
        }
        #expect(w.name == "Write")
        #expect(w.result?.declined == "")
        #expect(s.result?.text == "Stopped")
        #expect(s.result?.isError == true)
        #expect(s.result?.declined == nil)
        #expect(t.items[2].kind == .notice(.interrupted))
        #expect(t.items[3].kind == .notice(.error("Quota exceeded.")))
    }

    @Test func shellOutputs() {
        let failed = Transcript.geminiShell(ToolResult(text: "<untrusted_context>\nOutput: ls: nope: No such file or directory\nExit Code: 1\nProcess Group PGID: 3\n</untrusted_context>"))
        #expect(failed.text == "ls: nope: No such file or directory")
        #expect(failed.isError)
        let empty = Transcript.geminiShell(ToolResult(text: "Output: (empty)\nProcess Group PGID: 4"))
        #expect(empty.text == "")
        #expect(!empty.isError)
        let lines = Transcript.geminiShell(ToolResult(text: "Output: a\nb\nc\nProcess Group PGID: 5"))
        #expect(lines.text == "a\nb\nc")
    }

    @Test func todosAndOthers() {
        let todos = call("t1", "write_todos", ["todos": [["description": "Read the code", "status": "completed"], ["description": "Change it", "status": "in_progress"], ["description": "Test it", "status": "cancelled"], ["description": "Ship it", "status": "blocked"]]], status: "success", output: "ok")
        let grep = call("g1", "grep_search", ["pattern": "TODO", "dir_path": "/Users/me/x", "include_pattern": "*.swift"], status: "success", output: "Found 2 matches")
        let read = call("r1", "read_file", ["file_path": "/Users/me/x/a.swift", "start_line": 10, "end_line": 19], status: "success", output: "…")
        let t = Transcript.parse([gemini("m1", "", calls: [todos, grep, read])], format: .gemini)
        guard t.items.count == 3, case .tool(let a) = t.items[0].kind, case .tool(let b) = t.items[1].kind, case .tool(let c) = t.items[2].kind else {
            Issue.record("\(t.items.map(\.kind))")
            return
        }
        #expect(a.name == "TodoWrite")
        #expect(a.input["todos"]?.array?.compactMap { $0["status"]?.string } == ["completed", "in_progress", "completed", "pending"])
        #expect(a.input["todos"]?.array?.first?["content"]?.string == "Read the code")
        #expect(b.name == "Grep")
        #expect(b.input["glob"]?.string == "*.swift")
        #expect(c.name == "Read")
        #expect(c.input["offset"] == .int(10))
        #expect(c.input["limit"] == .int(10))
    }

    @Test func skipsWhatIsNotTheChat() {
        let t = Transcript.parse([header, context, results("x", "ls", output: "a"), line(["$set": ["lastUpdated": "2026"]])], format: .gemini)
        #expect(t.items.isEmpty)
    }
}

/// A chat file written as Gemini writes it: line by line, by `append`.
private actor ChatFile {
    let url = FileManager.default.temporaryDirectory.appending(path: "gemini-\(UUID().uuidString).jsonl")

    func append(_ lines: [Data]) throws {
        var data = Data()
        for l in lines {
            data.append(l)
            data.append(0x0A)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            try h.seekToEnd()
            try h.write(contentsOf: data)
            try h.close()
        } else {
            try data.write(to: url)
        }
    }
}

@Suite struct GeminiChatTests {
    private func ids(_ lines: [Data]) -> [String] {
        lines.compactMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["id"] as? String }
    }

    @Test func rewrittenMessageReadsAgain() async throws {
        let file = ChatFile()
        try await file.append([header, context, user("u1", "List the files"), gemini("g1", "")])
        let chat = GeminiChat(file: TranscriptFile(url: file.url))
        #expect(ids(try await chat.openTail(lines: 100, maxBytes: 1 << 20)) == ["d049", "u1", "g1"])
        #expect(try await chat.readNew() == [])
        // Its calls, once done: the same message again, whole.
        let done = call("c1", "list_directory", ["dir_path": "/Users/me/x"], status: "success", output: "a\nb")
        try await file.append([gemini("g1", "", calls: [done]), results("c1", "list_directory", output: "a\nb"), line(["$set": ["lastUpdated": "now"]])])
        #expect(try await chat.readNew() == nil)
        let again = try await chat.openTail(lines: 100, maxBytes: 1 << 20)
        #expect(ids(again) == ["d049", "u1", "g1", "r-c1"])
        let t = Transcript.parse(again, format: .gemini)
        #expect(t.items.count == 2)
        // New messages come as they are written.
        try await file.append([gemini("g2", "Two files.")])
        #expect(ids(try await chat.readNew() ?? []) == ["g2"])
        try? FileManager.default.removeItem(at: file.url)
    }

    @Test func rewindAndStoppedCallOnce() async throws {
        let file = ChatFile()
        let refused = call("w1", "write_file", ["file_path": "/x/notes.txt", "content": "a"], status: "cancelled", error: "[Operation Cancelled] Reason: User denied execution.")
        try await file.append([header, user("u1", "Write some notes"), gemini("g1", ""), gemini("g1", "", calls: [refused]),
                               line(["id": "i1", "timestamp": "2026-11-12T16:24:50.426Z", "type": "info", "content": "Request cancelled."]),
                               line(["$rewindTo": "i1"]), user("u2", "ok")])
        let chat = GeminiChat(file: TranscriptFile(url: file.url))
        #expect(ids(try await chat.openTail(lines: 100, maxBytes: 1 << 20)) == ["u1", "g1", "u2"])
        // Esc on a running call: its message, then the call again alone.
        let stopped = call("s1", "run_shell_command", ["command": "sleep 30"], status: "cancelled", error: "[Operation Cancelled] Reason: User cancelled operation")
        try await file.append([gemini("g2", "", calls: [stopped]), line(["id": "i2", "timestamp": "2026-11-12T16:33:05.797Z", "type": "info", "content": "Request cancelled."]),
                               line(["id": "g3", "timestamp": "2026-11-12T16:33:05.857Z", "type": "gemini", "content": "", "toolCalls": [stopped], "thoughts": [], "model": model])])
        #expect(ids(try await chat.readNew() ?? []) == ["g2", "i2"])
        // Going back to before a message the chat showed: read again.
        try await file.append([line(["$rewindTo": "u2"])])
        #expect(try await chat.readNew() == nil)
        #expect(ids(try await chat.openTail(lines: 100, maxBytes: 1 << 20)) == ["u1", "g1"])
        try? FileManager.default.removeItem(at: file.url)
    }

    @Test func earlierAndSummary() async throws {
        let file = ChatFile()
        try await file.append([header] + (1 ... 6).map { user("u\($0)", "Message \($0)") } + [line(["$set": ["summary": "Fix the login page"]])])
        let chat = GeminiChat(file: TranscriptFile(url: file.url))
        let tail = try await chat.openTail(lines: 2, maxBytes: 1 << 20)
        #expect(ids(tail).filter { $0.hasPrefix("u") } == ["u5", "u6"])
        #expect(Transcript.parse(tail, format: .gemini).title == "Fix the login page")
        #expect(await chat.atStart == false)
        #expect(ids(try await chat.readEarlier(lines: 3, maxBytes: 1 << 20)) == ["u2", "u3", "u4"])
        #expect(ids(try await chat.readEarlier(lines: 3, maxBytes: 1 << 20)) == ["u1"])
        #expect(await chat.atStart)
        try? FileManager.default.removeItem(at: file.url)
    }

    @Test func patchChangesAMessage() async throws {
        let file = ChatFile()
        try await file.append([header, user("u1", "Hi"), gemini("g1", "Hello")])
        let chat = GeminiChat(file: TranscriptFile(url: file.url))
        _ = try await chat.openTail(lines: 100, maxBytes: 1 << 20)
        try await file.append([line(["$patch": ["updates": [["id": "g1", "content": "Hello there"]]]])])
        #expect(try await chat.readNew() == nil)
        let t = Transcript.parse(try await chat.openTail(lines: 100, maxBytes: 1 << 20), format: .gemini)
        #expect(t.items.last?.kind == .text("Hello there"))
        try? FileManager.default.removeItem(at: file.url)
    }
}

@Suite struct GeminiScreenTests {
    @Test func singleQuestion() throws {
        let p = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.ask1))
        #expect(p.title == "Answer Questions")
        #expect(p.questionText == "Which color should the button be?")
        #expect(p.options.map(\.label) == ["Red", "Blue", "Enter a custom value"])
        #expect(p.options.map(\.detail) == ["Warm and loud", "Calm", ""])
        #expect(p.options.first?.focused == true)
        #expect(p.footer == "Enter to select · ↑/↓ to navigate · Esc to cancel")
        #expect(p.keys(for: p.options[1]) == ["2"])
        #expect(p.tabs.isEmpty)
        #expect(ClaudeFooter.parseGemini(screen: GeminiScreens.ask1) == nil)
    }

    @Test func manyChoicesWithTabs() throws {
        let p = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.ask3_q2b))
        #expect(p.tabs.map(\.title) == ["Color", "Toppings", "Ship", "Review"])
        #expect(p.tabs.map(\.answered) == [true, true, false, false])
        #expect(p.tabs.last?.isSubmit == true)
        #expect(p.question == ["Which toppings do you want?", "(Select all that apply)"])
        #expect(p.options.map(\.label) == ["Cheese", "Olives", "All of the above"])
        #expect(p.options.map(\.checked) == [true, true, true])
        #expect(p.options.map(\.focused) == [false, false, true])
        #expect(p.options[0].detail == "Melted")
    }

    /// ⌃O draws Gemini's list whole (0.68, 2026-11-14): `Done` ends it,
    /// with no number. Held to the screen, it may start lower down, under
    /// its `▲`.
    @Test func wholeListAndDone() throws {
        let whole = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.ask3_whole))
        #expect(whole.options.map(\.label) == ["Cheese", "Olives", "All of the above", "abc"])
        #expect(whole.options.map(\.checked) == [true, false, false, true])
        #expect(whole.options[3].detail == "")
        #expect(!whole.listScrolls)
        #expect(whole.customOption == 4)
        #expect(whole.typedWords == "abc")
        #expect(whole.hasSubmitLine)
        #expect(!whole.submitFocused)
        #expect(whole.doneNumber == 5)
        let window = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.ask3_done))
        #expect(window.listScrolls)
        #expect(window.question == ["Which toppings do you want?", "(Select all that apply)"])
        #expect(window.options.map(\.number) == [3, 4])
        #expect(window.options.allSatisfy { !$0.focused })
        #expect(window.customOption == 4)
        #expect(window.submitFocused)
        #expect(window.doneNumber == 5)
        // From `Done` the cursor goes up to the line for one's own words.
        #expect(window.moves(to: window.options[1]) == ["up"])
        #expect(window.keys(for: window.options[0]) == ["3"])
        // At its top, `Done` out of sight: the last row shown isn't sure to take words.
        let top = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.ask3_q2b))
        #expect(top.listScrolls)
        #expect(!top.hasSubmitLine)
        #expect(top.doneNumber == nil)
        #expect(top.customOption == nil)
        #expect(whole.geminiTopWalk == nil)
        #expect(window.geminiTopWalk == nil)
    }

    /// The list grown by ⌃O keeps where its window started (2026-11-14):
    /// rows from 5 to the end, no arrows. The cursor goes to the first row
    /// and back, the shorter way.
    @Test func grownListKeepsItsStart() throws {
        func box(_ rows: [String]) -> String {
            (["╭────────────────────────────────────────╮", "│ Answer Questions  │", "│  │"] + rows.map { "│ \($0)  │" }
                + ["╰────────────────────────────────────────╯"]).joined(separator: "\n")
        }
        let rows = ["Which sides do you want?", "(Select all that apply)", "", "  5. [ ] All of the above", "         Select all options",
                    "  6. [ ] Enter a custom value", "●  Done", "   Finish selection", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
        let p = try #require(ScreenPrompt.parseGemini(screen: box(rows)))
        #expect(p.question == ["Which sides do you want?", "(Select all that apply)"])
        #expect(p.options.map(\.number) == [5, 6])
        #expect(!p.listScrolls)
        #expect(p.customOption == 6)
        #expect(p.doneNumber == 7)
        #expect(p.geminiCursor == 7)
        let walk = try #require(p.geminiTopWalk)
        #expect(walk.there == ["down"])
        #expect(walk.back == ["up"])
        let onAll = try #require(ScreenPrompt.parseGemini(screen: box(rows.map {
            $0 == "  5. [ ] All of the above" ? "● 5. [ ] All of the above" : $0 == "●  Done" ? "   Done" : $0
        })))
        #expect(onAll.geminiCursor == 5)
        #expect(onAll.geminiTopWalk?.there == ["down", "down", "down"])
        #expect(onAll.geminiTopWalk?.back == ["up", "up", "up"])
    }

    @Test func review() throws {
        let p = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.ask3_review))
        #expect(p.question == ["Review your answers:", "", "Color → Red", "Toppings → Cheese, Olives", "Ship → Yes"])
        #expect(p.options.map(\.label) == ["Submit answers"])
        #expect(p.keys(for: p.options[0]) == ["enter"])
        #expect(p.tabs.allSatisfy { $0.answered || $0.isSubmit })
    }

    @Test func questionInWords() throws {
        let p = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.ask_text))
        #expect(p.takesText)
        #expect(p.options.isEmpty)
        #expect(p.questionText == "What should the file be called?")
        #expect(p.footer.hasPrefix("Enter to submit"))
        let custom = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.ask_custom))
        #expect(custom.options.last?.label == "Enter a custom value")
        #expect(custom.options.last?.focused == true)
        #expect(!custom.takesText)
    }

    /// Words typed on Gemini 0.68's question (2026-11-14): on its last
    /// option (`teal ✓` once left), or in its field for words; its hints
    /// read as nothing typed.
    @Test func wordsTyped() throws {
        func box(_ rows: [String]) -> String {
            (["╭────────────────────────────────────────╮", "│ Answer Questions  │", "│  │"] + rows.map { "│ \($0)  │" }
                + ["╰────────────────────────────────────────╯"]).joined(separator: "\n")
        }
        let options = ["Which color should the button be?", "", "● 1.  Red", "      Warm", "  2.  Blue", "      Calm"]
        let chosen = try #require(ScreenPrompt.parseGemini(screen: box(options + ["  3.  teal ✓", "", "Enter to select · ←/→ to switch questions · Esc to cancel"])))
        #expect(chosen.customOption == 3)
        #expect(chosen.typedWords == "teal")
        let typing = try #require(ScreenPrompt.parseGemini(screen: box(options + ["  3.  magenta blue", "", "Enter to submit · Tab/Shift+Tab to switch questions · Esc to cancel"])))
        #expect(typing.typedWords == "magenta blue")
        let empty = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.ask_custom))
        #expect(empty.customOption == 3)
        #expect(empty.typedWords == "")
        // A list that scrolls: its last option shown isn't sure to be the one for words.
        let cut = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.ask3_q2b))
        #expect(cut.customOption == nil)
        #expect(cut.typedWords == "")
        let field = ["What should the button say?", "", "> go now", "", "Enter to submit · Tab/Shift+Tab to switch questions · Esc to cancel"]
        let words = try #require(ScreenPrompt.parseGemini(screen: box(field)))
        #expect(words.takesText)
        #expect(words.typedWords == "go now")
        #expect(words.customOption == nil)
        let hint = try #require(ScreenPrompt.parseGemini(screen: box(field.map { $0 == "> go now" ? "> Enter your response" : $0 })))
        #expect(hint.typedWords == "")
    }

    @Test func shellPermission() throws {
        let p = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.shell_ask))
        #expect(p.title == "Shell command")
        #expect(p.questionText == "Allow execution of [Shell]?")
        #expect(p.options.map(\.label) == ["Allow once", "Allow for this session", "No, suggest changes (esc)"])
        #expect(p.call?.name == "Shell")
        #expect(p.call?.input["command"]?.string == "sleep 12; touch made.txt; echo made")
        #expect(p.keys(for: p.options[2]) == ["esc"])
        #expect(p.refusal?.label == "No, suggest changes (esc)")
    }

    @Test func filePermissions() throws {
        let new = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.write_new))
        #expect(new.title == "Create file")
        #expect(new.call?.name == "Write")
        #expect(new.call?.input["file_path"]?.string == "fresh.txt")
        #expect(new.call?.input["content"]?.string == "one\ntwo\nthree\n")
        // `Modify with external editor` left out; `No` keeps its digit.
        #expect(new.options.map(\.number) == [1, 2, 4])
        let edit = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.edit_ask))
        #expect(edit.title == "Edit file")
        #expect(edit.call?.name == "Edit")
        #expect(edit.call?.input["file_path"]?.string == "fresh.txt")
        #expect(edit.call?.input["diff"]?.string == " one\n-two\n+deux\n three")
        let over = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.write_ask))
        #expect(over.title == "Write file")
        #expect(over.call?.input["diff"]?.string == "-hello again\n+hello from the stand-in")
    }

    @Test func inputBox() throws {
        let idle = try #require(ClaudeFooter.parseGemini(screen: GeminiScreens.ls_done))
        #expect(idle.input == "")
        #expect(idle.mode == "default")
        #expect(!idle.busy)
        #expect(idle.model == "Auto")
        #expect(idle.statusLine == [])
        let working = try #require(ClaudeFooter.parseGemini(screen: GeminiScreens.shell_working))
        #expect(working.busy)
        #expect(working.activity == "Thinking…")
        let queued = try #require(ClaudeFooter.parseGemini(screen: GeminiScreens.queued))
        #expect(queued.queued == ["Ask me three things"])
        #expect(queued.busy)
        #expect(ScreenPrompt.parseGemini(screen: GeminiScreens.ls_done) == nil)
        #expect(ScreenPrompt.parseGemini(screen: GeminiScreens.shell_working) == nil)
    }

    @Test func modesAndTyping() throws {
        let typed = GeminiScreens.ls_done.replacingOccurrences(of: ">   Type your message or @path/to/file", with: "> hi there")
        #expect(ClaudeFooter.parseGemini(screen: typed)?.input == "hi there")
        let plan = GeminiScreens.ls_done.replacingOccurrences(of: " Shift+Tab to accept edits", with: " plan Shift+Tab to manual")
        #expect(ClaudeFooter.parseGemini(screen: plan)?.mode == "plan")
        let auto = GeminiScreens.ls_done.replacingOccurrences(of: " Shift+Tab to accept edits", with: " auto-accept edits Shift+Tab to plan")
        #expect(ClaudeFooter.parseGemini(screen: auto)?.mode == "acceptEdits")
        let yolo = GeminiScreens.ls_done.replacingOccurrences(of: " Shift+Tab to accept edits", with: " YOLO Ctrl+Y")
        #expect(ClaudeFooter.parseGemini(screen: yolo)?.mode == "bypassPermissions")
    }

    @Test func titles() {
        #expect(GeminiScreen.status(title: "◇  Ready (x)                ")?.state == "idle")
        #expect(GeminiScreen.status(title: "✋  Action Required (x)")?.state == "blocked")
        let working = GeminiScreen.status(title: "✦  Working… (x)   ")
        #expect(working?.state == "working")
        #expect(working?.message == nil)
        #expect(GeminiScreen.status(title: "✦  Checking the folder (my app)")?.message == "Checking the folder")
        #expect(GeminiScreen.status(title: "⏲  Working… (x)")?.state == "working")
        #expect(GeminiScreen.status(title: "Gemini CLI (x)") == nil)
    }
}

@Suite struct GeminiFilesTests {
    @Test func findsTheProjectsChats() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "gemhome-\(UUID().uuidString)")
        let gemini = home.appending(path: ".gemini")
        let chats = gemini.appending(path: "tmp/x/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        try Data(#"{"projects":{"/Users/me/x":"x"}}"#.utf8).write(to: gemini.appending(path: "projects.json"))
        #expect(GeminiFiles.folder(cliHome: home.path) == gemini)
        #expect(GeminiFiles.chats(in: gemini, cwd: "/Users/me/x") == chats)
        #expect(GeminiFiles.chats(in: gemini, cwd: "/Users/me/y") == nil)
        // Without projects.json: the folder that names it.
        try FileManager.default.removeItem(at: gemini.appending(path: "projects.json"))
        try Data("/Users/me/x".utf8).write(to: gemini.appending(path: "tmp/x/.project_root"))
        #expect(GeminiFiles.chats(in: gemini, cwd: "/Users/me/x") == chats)
        let old = chats.appending(path: "session-2026-11-12T16-20-30f0f638.jsonl")
        let new = chats.appending(path: "session-2026-11-12T16-24-d3eff6d4.jsonl")
        try Data("{}\n".utf8).write(to: old)
        try Data("{}\n".utf8).write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: old.path)
        #expect(GeminiFiles.newestChat(in: chats, since: nil)?.lastPathComponent == new.lastPathComponent)
        #expect(GeminiFiles.newestChat(in: chats, since: Date().addingTimeInterval(60)) == nil)
        #expect(GeminiFiles.shortID(new.path) == "d3eff6d4")
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite struct GeminiCommandTests {
    @Test func tomlCommand() {
        let text = #"""
        # Made by hand.
        description = "Writes a \"commit\" message"
        prompt = """
        Write a commit message for:
        {{args}}
        """
        """#
        let c = SlashCommand.from(toml: text, name: "git/commit", source: .personal)
        #expect(c?.name == "git:commit")
        #expect(c?.summary == #"Writes a "commit" message"#)
        #expect(c?.argumentHint == "[args]")
        #expect(c?.source == .personal)
    }

    @Test func tomlWithoutDescription() {
        let text = "prompt = '''\nReview the staged changes.\nBe brief.'''\n"
        let c = SlashCommand.from(toml: text, name: "review", source: .project)
        #expect(c?.summary == "Review the staged changes.")
        #expect(c?.argumentHint == "")
    }

    @Test func linesInsideStringsAreNoKeys() {
        let text = "prompt = \"\"\"\ndescription = \"no\"\n[table]\n\"\"\"\ndescription = 'yes'\n[after]\ndescription = \"late\"\n"
        #expect(SlashCommand.tomlString("description", in: text) == "yes")
        #expect(SlashCommand.tomlString("missing", in: text) == nil)
    }

    @Test func builtInsHaveCompress() {
        let found = SlashCommand.matching("compact", in: SlashCommand.geminiBuiltIns)
        #expect(found.first?.name == "compress")
    }
}

extension GeminiScreens {
    static let rewindList = """
        ╭────────────────────────────────────────╮
        │  │
        │ > Rewind  │
        │  │
        │   <session_context>  │
        │   This is the Gemini CLI. We are setting up the context for our chat....  │
        │   No files have been changed  │
        │  │
        │   Ask me two things  │
        │   No files have been changed  │
        │  │
        │   Write a fresh file  │
        │   1 file changed +3  │
        │  │
        │   Translate two  │
        │   1 file changed +1 -1  │
        │  │
        │ ● Stay at current position  │
        │   Cancel rewind and stay here  │
        │  │
        │  │
        │ (Use Enter to select a message, Esc to close, Right/Left to expand/collapse)  │
        │  │
        ╰────────────────────────────────────────╯
        """

    static let rewindConfirm = """
        ╭────────────────────────────────────────╮
        │  │
        │ Confirm Rewind  │
        │  │
        │ No code changes to revert. (7m 49s ago)  │
        │  │
        │ Select an action:  │
        │  │
        │ ● 1. Rewind conversation  │
        │   2. Do nothing (esc)  │
        │  │
        ╰────────────────────────────────────────╯
        """
}

@Suite struct GeminiRewindTests {
    @Test func list() throws {
        let p = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.rewindList))
        #expect(p.context == ["Rewind"])
        #expect(!p.numbered)
        #expect(p.options.map(\.label) == ["The session's start", "Ask me two things", "Write a fresh file", "Translate two", "Stay at current position"])
        #expect(p.options[2].detail == "1 file changed +3")
        #expect(p.options.last?.focused == true)
        #expect(p.footer.hasPrefix("Use Enter to select a message"))
        // Up twice from the last, then Enter.
        #expect(p.keys(for: p.options[2]) == ["up", "up", "enter"])
        #expect(!p.isRewindList)
    }

    @Test func confirm() throws {
        let p = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.rewindConfirm))
        #expect(p.options.map(\.label) == ["Rewind conversation", "Do nothing (esc)"])
        #expect(p.question.first == "Confirm Rewind")
        #expect(p.keys(for: p.options[0]) == ["1"])
        #expect(p.keys(for: p.options[1]) == ["esc"])
    }
}

@Suite struct GeminiTitleTests {
    @Test func statusTitlesAreNoSessionTitles() {
        for title in ["◇  Ready (x)", "✦  Working… (x)", "✦  Checking the folder (x)", "✋  Action Required (x)", "Gemini CLI (x)"] {
            #expect(GeminiScreen.isStatusTitle(title), "\(title)")
            #expect(ClaudeTitle.clean(title) == nil, "\(title)")
        }
        #expect(ClaudeTitle.clean("✳ Fix login") == "Fix login")
        #expect(!GeminiScreen.isStatusTitle("Fix login (bug)"))
    }
}

extension GeminiScreens {
    static let rewindConfirmFiles = """
        ╭────────────────────────────────────────╮
        │  │
        │ Confirm Rewind  │
        │  │
        │ ┌──────────────────────────────┐ │
        │ │ File: five.txt  │ │
        │ │ Lines added: 3 Lines removed: 1 (4m 27s ago)  │ │
        │ │  │ │
        │ │ ℹ Rewinding does not affect files edited manually or by the shell tool.  │ │
        │ └──────────────────────────────┘ │
        │  │
        │ Select an action:  │
        │  │
        │ ● 1. Rewind conversation and revert code changes  │
        │   2. Rewind conversation  │
        │   3. Revert code changes  │
        │   4. Do nothing (esc)  │
        │  │
        ╰────────────────────────────────────────╯
        """
}

@Suite struct GeminiConfirmTests {
    @Test func innerBoxLosesItsFrame() throws {
        let p = try #require(ScreenPrompt.parseGemini(screen: GeminiScreens.rewindConfirmFiles))
        #expect(p.heading == "Confirm Rewind")
        #expect(p.question.contains("File: five.txt"))
        #expect(p.question.contains("Lines added: 3 Lines removed: 1 (4m 27s ago)"))
        #expect(!p.question.contains { $0.contains("┌") || $0.contains("└") || $0.hasPrefix("│") })
        #expect(p.options.map(\.label) == ["Rewind conversation and revert code changes", "Rewind conversation", "Revert code changes", "Do nothing (esc)"])
    }
}
