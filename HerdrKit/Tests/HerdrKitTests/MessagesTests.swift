import Foundation
import Testing
@testable import HerdrKit

/// One transcript line from a JSON object written as Swift.
private func line(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func user(_ id: String, _ content: Any, extra: [String: Any] = [:]) -> Data {
    line(["type": "user", "uuid": id, "message": ["role": "user", "content": content]].merging(extra) { $1 })
}

private func assistant(_ id: String, _ blocks: [[String: Any]], extra: [String: Any] = [:]) -> Data {
    line(["type": "assistant", "uuid": id, "message": ["id": "msg_1", "role": "assistant", "model": "claude-opus-5-5", "content": blocks]].merging(extra) { $1 })
}

@Suite struct TranscriptTests {
    @Test func promptsAnswersAndTools() {
        var t = Transcript()
        t.append([
            user("u1", "Fix the login"),
            assistant("a1", [["type": "thinking", "thinking": "", "signature": "x"]]),
            assistant("a2", [["type": "text", "text": "Looking."]]),
            assistant("a3", [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "ls -la\nwc -l", "description": "List files"]]]),
            user("u2", [["type": "tool_result", "tool_use_id": "toolu_1", "content": "a\nb\n<system-reminder>secret</system-reminder>"]]),
            line(["type": "attachment", "uuid": "x1", "attachment": ["type": "hook_success", "content": "ok"]]),
            line(["type": "system", "uuid": "s1", "subtype": "turn_duration", "durationMs": 4200]),
        ])
        #expect(t.items.count == 4)
        #expect(t.items[0].kind == .prompt("Fix the login", images: 0))
        #expect(t.items[1].kind == .text("Looking."))
        guard case .tool(let call) = t.items[2].kind else { Issue.record("not a tool"); return }
        #expect(call.name == "Bash")
        #expect(call.summary == "List files")
        #expect(call.result?.text == "a\nb")
        #expect(call.result?.lines == 2)
        #expect(t.items[3].kind == .notice(.turnEnded(milliseconds: 4200)))
        // Empty thinking is skipped; the hook line too.
        #expect(!t.items.contains { if case .thinking = $0.kind { true } else { false } })
    }

    @Test func resultsBeforeTheirCallAfterPrepend() {
        let call = assistant("a1", [["type": "tool_use", "id": "toolu_9", "name": "Read", "input": ["file_path": "/tmp/x"]]])
        let result = user("u1", [["type": "tool_result", "tool_use_id": "toolu_9", "content": [["type": "text", "text": "body"], ["type": "image", "source": [:]]], "is_error": true]])
        var t = Transcript()
        t.append([result, assistant("a2", [["type": "text", "text": "Done"]])])
        #expect(t.items.count == 1)
        t.prepend([user("u0", "Read it"), call])
        #expect(t.items.count == 3)
        guard case .tool(let c) = t.items[1].kind else { Issue.record("not a tool"); return }
        #expect(c.result == ToolResult(text: "body", images: 1, isError: true))
        #expect(t.items[2].kind == .text("Done"))
    }

    /// A message that follows an earlier line than the last: Claude went
    /// back there (/rewind), and what came after it goes.
    @Test func rewindDropsTheBranchLeft() {
        func id(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
        let older = [
            user(id(1), "First"),
            assistant(id(2), [["type": "text", "text": "One"]], extra: ["parentUuid": id(1)]),
            // Not read, but a message may follow it.
            line(["type": "attachment", "uuid": id(3), "parentUuid": id(2), "attachment": ["type": "date"]]),
        ]
        let newer = [
            user(id(4), "Second", extra: ["parentUuid": id(3)]),
            assistant(id(5), [["type": "tool_use", "id": "toolu_1", "name": "Read", "input": ["file_path": "/a"]]], extra: ["parentUuid": id(4)]),
            assistant(id(6), [["type": "tool_use", "id": "toolu_2", "name": "Read", "input": ["file_path": "/b"]]], extra: ["parentUuid": id(5)]),
            // Parallel calls' results follow their call, not the last line: no rewind.
            user(id(7), [["type": "tool_result", "tool_use_id": "toolu_1", "content": "a"]], extra: ["parentUuid": id(5)]),
            user(id(8), [["type": "tool_result", "tool_use_id": "toolu_2", "content": "b"]], extra: ["parentUuid": id(6)]),
            assistant(id(9), [["type": "text", "text": "Two"]], extra: ["parentUuid": id(8)]),
        ]
        func words(_ t: Transcript) -> [String] {
            t.items.compactMap { item in
                switch item.kind {
                case .prompt(let s, _), .text(let s): s
                case .tool(let call): call.name
                default: nil
                }
            }
        }
        var t = Transcript()
        t.append(older + newer)
        #expect(words(t) == ["First", "One", "Second", "Read", "Read", "Two"])
        t.append([user(id(10), "Second, again", extra: ["parentUuid": id(3)])])
        #expect(words(t) == ["First", "One", "Second, again"])
        // The same once the older lines come in front of the newer ones.
        var u = Transcript()
        u.append(newer)
        u.prepend(older)
        u.append([user(id(10), "Second, again", extra: ["parentUuid": id(3)])])
        #expect(words(u) == ["First", "One", "Second, again"])
        // Going on from the last line drops nothing.
        u.append([assistant(id(11), [["type": "text", "text": "Again"]], extra: ["parentUuid": id(10)]), user(id(12), "Third", extra: ["parentUuid": id(11)])])
        #expect(words(u) == ["First", "One", "Second, again", "Again", "Third"])
    }

    @Test func commandsAndTheirOutput() {
        var t = Transcript()
        t.append([
            user("c1", "<command-name>/add-dir</command-name>\n<command-message>add-dir</command-message>\n<command-args>../shared</command-args>"),
            user("c2", "<local-command-stdout>Added ../shared as a working directory for this session</local-command-stdout>"),
            user("c3", "<local-command-caveat>Caveat</local-command-caveat>", extra: ["isMeta": true]),
            user("b1", "<bash-input>git status</bash-input>"),
            user("b2", "<bash-stdout>clean</bash-stdout><bash-stderr></bash-stderr>"),
        ])
        #expect(t.items.map(\.kind) == [
            .command("/add-dir ../shared", output: "Added ../shared as a working directory for this session"),
            .command("! git status", output: "clean"),
        ])
    }

    @Test func goalChecksAndStopHookFeedback() {
        func goal(_ id: String, _ fields: [String: Any]) -> Data {
            line(["type": "attachment", "uuid": id, "attachment": ["type": "goal_status", "condition": "tests pass"].merging(fields) { $1 }])
        }
        var t = Transcript()
        t.append([
            goal("g0", ["met": false, "sentinel": true]),
            user("g1", "<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>tests pass</command-args>"),
            user("g1o", "<local-command-stdout>Goal set: tests pass</local-command-stdout>"),
            user("g2", "A session-scoped Stop hook is now active with condition: \"tests pass\".", extra: ["isMeta": true]),
        ])
        #expect(t.items.map(\.kind) == [.command("/goal tests pass", output: "Goal set")])
        #expect(t.facts.activeGoal == GoalStatus(condition: "tests pass", state: .set))

        // Not met: the feedback the hook gave Claude becomes the check's row.
        t.append([
            user("g3", "Stop hook feedback:\n[tests pass]: Two tests still fail.", extra: ["isMeta": true]),
            goal("g4", ["met": false, "reason": "Two tests still fail."]),
        ])
        #expect(t.items.count == 2)
        #expect(t.items.last?.kind == .notice(.goal(GoalStatus(condition: "tests pass", state: .notMet, reason: "Two tests still fail."))))
        #expect(t.facts.activeGoal?.state == .notMet)

        // Met: no goal on any more, with what it took.
        t.append([goal("g5", ["met": true, "reason": "All pass.", "iterations": 2, "durationMs": 8_849_974, "tokens": 261_773])])
        guard case .notice(.goal(let met)) = t.items.last?.kind else { Issue.record("no goal row"); return }
        #expect(met.state == .met && met.turns == 2 && met.milliseconds == 8_849_974 && met.tokens == 261_773)
        #expect(t.facts.activeGoal == nil)

        // Another hook's feedback stays as it is; `/goal clear` ends a goal at once.
        t.append([
            goal("g6", ["met": false, "sentinel": true]),
            user("g7", "Stop hook feedback:\n[~/bin/check.sh]: lint first", extra: ["isMeta": true]),
            user("g8", "<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>clear</command-args>"),
        ])
        #expect(t.items.suffix(2).map(\.kind) == [.notice(.hookFeedback("[~/bin/check.sh]: lint first")), .command("/goal clear", output: nil)])
        #expect(t.facts.activeGoal == nil)
        #expect(TranscriptRow.item(t.items[1]).contains("two tests"))
    }

    @Test func summarizeFromHereTakesMessagesOutOfRewind() {
        var t = Transcript()
        t.append([
            user("p1", "first", extra: ["parentUuid": NSNull()]),
            assistant("a1", [["type": "text", "text": "one"]], extra: ["parentUuid": "p1"]),
            user("p2", "second", extra: ["parentUuid": "a1"]),
            assistant("a2", [["type": "text", "text": "two"]], extra: ["parentUuid": "p2"]),
            line(["type": "system", "subtype": "compact_boundary", "uuid": "b1", "parentUuid": NSNull(), "logicalParentUuid": "a1",
                  "compactMetadata": ["trigger": "manual", "preservedSegment": ["headUuid": "p1", "anchorUuid": "b1", "tailUuid": "a1"]]]),
            user("s1", "This session is being continued…", extra: ["isCompactSummary": true, "parentUuid": "b1"]),
            user("p3", "third", extra: ["parentUuid": "s1"]),
        ])
        #expect(t.summarized == ["p2"])
        // A plain /compact keeps every message in the list.
        var c = Transcript()
        c.append([
            user("p1", "first"),
            line(["type": "system", "subtype": "compact_boundary", "uuid": "b1", "compactMetadata": ["trigger": "manual"]]),
        ])
        #expect(c.summarized.isEmpty)
    }

    @Test func compactShowsOverItsNotice() {
        var t = Transcript()
        t.append([
            line(["type": "system", "uuid": "b1", "subtype": "compact_boundary", "content": "Conversation compacted"]),
            user("s1", "This session is being continued…", extra: ["isCompactSummary": true]),
            user("c0", "<local-command-caveat>Caveat</local-command-caveat>", extra: ["isMeta": true]),
            user("c1", "<command-name>/compact</command-name>\n<command-message>compact</command-message>\n<command-args></command-args>"),
            user("c2", "<local-command-stdout>\u{1b}[2mCompacted (ctrl+o to see full summary)\u{1b}[22m</local-command-stdout>"),
            user("e1", "<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<command-args></command-args>"),
            user("e2", "<local-command-stdout>Effort: \u{1b}[1mhigh\u{1b}[22m</local-command-stdout>"),
        ])
        #expect(t.items.map(\.kind) == [
            .command("/compact", output: ""),
            .notice(.compacted(summary: "This session is being continued…")),
            .command("/effort", output: "Effort: high"),
        ])
    }

    @Test func agentRunsFromTheirResults() {
        var t = Transcript()
        t.append([
            assistant("a1", [["type": "tool_use", "id": "t1", "name": "Agent", "input": ["description": "Find it", "subagent_type": "Explore", "prompt": "…"]],
                             ["type": "tool_use", "id": "t2", "name": "Agent", "input": ["description": "Review", "run_in_background": true, "prompt": "…"]]]),
            user("r1", [["type": "tool_result", "tool_use_id": "t1", "content": [["type": "text", "text": "Found."]]]],
                 extra: ["toolUseResult": ["status": "completed", "agentId": "a7", "agentType": "Explore", "resolvedModel": "claude-haiku-5-5",
                                           "totalDurationMs": 150_274, "totalTokens": 67_811, "totalToolUseCount": 11]]),
            user("r2", [["type": "tool_result", "tool_use_id": "t2", "content": "Launched."]],
                 extra: ["toolUseResult": ["isAsync": true, "status": "async_launched", "agentId": "a8", "resolvedModel": "claude-sonnet-5"]]),
        ])
        let runs = t.items.compactMap { item -> AgentRun? in
            if case .tool(let call) = item.kind { return call.result?.agent }
            return nil
        }
        #expect(runs == [
            AgentRun(id: "a7", type: "Explore", model: "claude-haiku-5-5", toolUses: 11, milliseconds: 150_274, tokens: 67_811),
            AgentRun(id: "a8", model: "claude-sonnet-5", background: true),
        ])
    }

    @Test func historyKeepsTheFoldersMessagesNewestFirst() {
        let objects: [[String: Any]] = [
            ["display": "first", "project": "/p", "timestamp": 1],
            ["display": "elsewhere", "project": "/q", "timestamp": 2],
            ["display": "[Pasted text #1 +2 lines] and more", "project": "/p",
             "pastedContents": ["1": ["id": 1, "type": "text", "content": "a\nb\nc"]]],
            ["display": "[Pasted text #2 +9 lines]", "project": "/p", "pastedContents": ["2": ["id": 2, "type": "text", "contentHash": "ab12"]]],
            ["display": "first", "project": "/p"],
            ["display": "  ", "project": "/p"],
        ]
        var data = Data()
        for o in objects { data += line(o) + Data("\n".utf8) }
        // Newest first, once each; a pasted text not kept stays as its mark.
        #expect(PromptHistory.entries(data, project: "/p") == ["first", "[Pasted text #2 +9 lines]", "a\nb\nc and more"])
        #expect(PromptHistory.entries(data, project: "/p", limit: 1) == ["first"])
    }

    @Test func backgroundWorkRunsUntilItsNoticeComes() {
        var t = Transcript()
        t.append([
            assistant("a1", [["type": "tool_use", "id": "t1", "name": "Agent", "input": ["description": "Review", "subagent_type": "Explore", "prompt": "…"]],
                             ["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "swift build\nswift test", "run_in_background": true]],
                             ["type": "tool_use", "id": "t3", "name": "Bash", "input": ["command": "sleep 300", "description": "Wait", "run_in_background": true]]],
                      extra: ["timestamp": "2026-11-12T04:00:00.000Z"]),
            user("r1", [["type": "tool_result", "tool_use_id": "t1", "content": "Launched."]],
                 extra: ["toolUseResult": ["isAsync": true, "status": "async_launched", "agentId": "a8", "agentType": "Explore"]]),
            user("r2", [["type": "tool_result", "tool_use_id": "t2", "content": "Command running in background with ID: b1."]],
                 extra: ["toolUseResult": ["stdout": "", "backgroundTaskId": "b1"]]),
            user("r3", [["type": "tool_result", "tool_use_id": "t3", "content": "Command running in background with ID: b2."]],
                 extra: ["toolUseResult": ["stdout": "", "backgroundTaskId": "b2"]]),
        ])
        #expect(t.backgroundJobs == [
            BackgroundJob(id: "t1", kind: .agent, title: "Review", detail: "Explore", started: 1_794_456_000, task: "a8"),
            BackgroundJob(id: "t2", kind: .shell, title: "swift build", detail: "swift build\nswift test", started: 1_794_456_000, task: "b1"),
            BackgroundJob(id: "t3", kind: .shell, title: "Wait", detail: "sleep 300", started: 1_794_456_000, task: "b2"),
        ])
        // The agent's notice names its call; the command's, its task. Claude stops the last.
        t.append([
            user("n1", "<task-notification>\n<task-id>a8</task-id>\n<tool-use-id>t1</tool-use-id>\n<status>completed</status>\n<summary>Agent \"Review\" finished</summary>\n</task-notification>",
                 extra: ["origin": ["kind": "task-notification"]]),
            user("n2", "<task-notification>\n<task-id>b1</task-id>\n<status>failed</status>\n<summary>Background command \"swift build\" failed</summary>\n</task-notification>",
                 extra: ["origin": ["kind": "task-notification"]]),
        ])
        #expect(t.backgroundJobs.map(\.id) == ["t3"])
        t.append([
            assistant("a2", [["type": "tool_use", "id": "t4", "name": "TaskStop", "input": ["task_id": "b2"]]]),
            user("r4", [["type": "tool_result", "tool_use_id": "t4", "content": "Stopped."]]),
        ])
        #expect(t.backgroundJobs.isEmpty)
    }

    /// ⌃X ⌃K twice, as Claude Code 2.1.322 writes it (tested 2026-11-12):
    /// an `agents_killed` line, then one plain note an agent stopped.
    @Test func stoppingTheAgentsEndsThemNotTheCommands() {
        var t = Transcript()
        t.append([
            assistant("a1", [["type": "tool_use", "id": "t1", "name": "Agent", "input": ["description": "Run ping", "subagent_type": "general-purpose", "prompt": "…"]],
                             ["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "sleep 300", "run_in_background": true]]]),
            user("r1", [["type": "tool_result", "tool_use_id": "t1", "content": "Launched."]],
                 extra: ["toolUseResult": ["isAsync": true, "status": "async_launched", "agentId": "a8"]]),
            user("r2", [["type": "tool_result", "tool_use_id": "t2", "content": "Command running in background with ID: b1."]],
                 extra: ["toolUseResult": ["stdout": "", "backgroundTaskId": "b1"]]),
        ])
        #expect(t.backgroundJobs.map(\.id) == ["t1", "t2"])
        t.append([
            line(["type": "system", "uuid": "s1", "subtype": "agents_killed", "isMeta": false]),
            user("n1", "Background agent \"Run ping\" was stopped by the user.", extra: ["origin": ["kind": "task-notification"]]),
            user("n2", "Something else Claude Code says.", extra: ["origin": ["kind": "task-notification"]]),
        ])
        #expect(t.backgroundJobs.map(\.id) == ["t2"])
        // Claude Code's words, never the person's: no prompt.
        let shown = t.items.suffix(3).map(\.kind)
        #expect(shown.contains { if case .prompt = $0 { true } else { false } } == false)
        // Its notice names the call that started it, by the agent's name.
        #expect(shown.contains(.notice(.task(id: "stopped-agent:Run ping", status: "stopped", summary: "Agent “Run ping” stopped", toolUse: "t1"))))
        #expect(shown.contains(.notice(.info("Something else Claude Code says."))))
        // The stop itself shows no row of its own.
        #expect(t.rows.contains { $0.id == "s1" } == false)
    }

    @Test func aSubAgentsOwnTranscriptKeepsItsSidechainLines() {
        let lines = [
            user("s1", "List the .txt files.", extra: ["isSidechain": true, "agentId": "a2d"]),
            assistant("s2", [["type": "tool_use", "id": "b1", "name": "Bash", "input": ["command": "ls *.txt", "description": "List them"]]], extra: ["isSidechain": true]),
            user("s3", [["type": "tool_result", "tool_use_id": "b1", "content": "a.txt"]], extra: ["isSidechain": true]),
            assistant("s4", [["type": "text", "text": "1 file: a.txt"]], extra: ["isSidechain": true]),
        ]
        // A session's transcript skips them; a sub-agent's keeps them.
        #expect(Transcript.parse(lines).items.isEmpty)
        let t = Transcript.parse(lines, sidechain: true)
        #expect(t.items.count == 3)
        #expect(t.items.first?.kind == .prompt("List the .txt files.", images: 0))
        #expect(t.items.last?.kind == .text("1 file: a.txt"))
        // A call still waiting, as when the sub-agent asks for permission.
        let waiting = Transcript.parse(Array(lines.prefix(2)), sidechain: true)
        #expect(waiting.openCalls.map(\.name) == ["Bash"])
    }

    @Test func metaAndSidechainLinesAreHidden() {
        var t = Transcript()
        t.append([
            user("m1", "<system-reminder>x</system-reminder>", extra: ["isMeta": true]),
            user("m2", [["type": "text", "text": "[Image: original 100x100]"]], extra: ["isMeta": true]),
            user("m3", "Hidden helper", extra: ["isSidechain": true]),
            assistant("m4", [["type": "text", "text": "Sub-agent"]], extra: ["isSidechain": true]),
        ])
        #expect(t.items.isEmpty)
    }

    @Test func interruptionsAndImages() {
        var t = Transcript()
        t.append([
            user("i1", [["type": "tool_result", "tool_use_id": "t1", "content": "The user doesn't want to proceed"], ["type": "text", "text": "[Request interrupted by user for tool use]"]]),
            user("i2", [["type": "image", "source": [:]], ["type": "text", "text": "[Image #1] what is this?"]]),
        ])
        #expect(t.items.map(\.kind) == [.notice(.interrupted), .prompt("[Image #1] what is this?", images: 1)])
    }

    @Test func compactingKeepsOneNotice() {
        var t = Transcript()
        t.append([
            line(["type": "system", "uuid": "s1", "subtype": "compact_boundary", "content": "Conversation compacted"]),
            user("u1", "This session is being continued…", extra: ["isCompactSummary": true]),
        ])
        #expect(t.items.map(\.kind) == [.notice(.compacted(summary: "This session is being continued…"))])
    }

    @Test func queuedPromptsAndTaskNotices() {
        var t = Transcript()
        let task = "<task-notification>\n<task-id>b8n</task-id>\n<status>failed</status>\n<summary>Background command \"tests\" failed</summary>\n</task-notification>"
        t.append([
            line(["type": "queue-operation", "operation": "enqueue", "content": "also check iOS"]),
            line(["type": "queue-operation", "operation": "enqueue", "content": "<task-notification>x</task-notification>"]),
        ])
        #expect(t.queued == ["also check iOS"])
        t.append([
            line(["type": "attachment", "uuid": "q1", "attachment": ["type": "queued_command", "prompt": "also check iOS", "commandMode": "prompt", "origin": ["kind": "human"]]]),
            line(["type": "queue-operation", "operation": "remove", "content": "also check iOS"]),
            line(["type": "attachment", "uuid": "q2", "attachment": ["type": "queued_command", "prompt": task, "commandMode": "task-notification", "origin": ["kind": "task-notification"]]]),
            user("q3", task, extra: ["origin": ["kind": "task-notification"]]),
        ])
        #expect(t.queued.isEmpty)
        #expect(t.items.map(\.kind) == [
            .prompt("also check iOS", images: 0),
            .notice(.task(id: "b8n", status: "failed", summary: "Background command \"tests\" failed")),
        ])
    }

    /// Claude Code frames a long paste, and the Messages field goes in as
    /// one: the person's message shows as they wrote it.
    @Test func pastesLoseTheirFrames() {
        func framed(_ id: String, _ body: String) -> String {
            "\n\n<pasted_content id=\"\(id)\">\n\(body)\n</pasted_content id=\"\(id)\">\n"
        }
        // `[Pasted text #1 +1 lines]` alone, between typed words, twice.
        #expect(Transcript.withoutPasteFrames(framed("d5a3", "Un autre souci\nSELECT 1;")) == "Un autre souci\nSELECT 1;")
        #expect(Transcript.withoutPasteFrames("see this:\n" + framed("57c5", "a\nb") + "\n\nwhat now?") == "see this:\na\nb\n\nwhat now?")
        #expect(Transcript.withoutPasteFrames("one " + framed("35c6", "x") + framed("35c6", "y") + " two") == "one xy two")
        // Trimmed (a queued message), and cut short (`slim`).
        #expect(Transcript.withoutPasteFrames("<pasted_content id=\"e322\">\nqueued\n</pasted_content id=\"e322\">") == "queued")
        #expect(Transcript.withoutPasteFrames("\n\n<pasted_content id=\"e322\">\nlong…") == "long…")
        // The tags typed or pasted: Claude Code puts a backslash in them.
        #expect(Transcript.withoutPasteFrames(#"<\/pasted_content id="d5a3"> these tags"#) == #"</pasted_content id="d5a3"> these tags"#)
        #expect(Transcript.withoutPasteFrames(framed("8d90", #"<\pasted_content id="d5a3">"# + "\nhi\n" + #"<\/pasted_content id="d5a3">"#))
            == "<pasted_content id=\"d5a3\">\nhi\n</pasted_content id=\"d5a3\">")
        // Not Claude Code's frame.
        #expect(Transcript.withoutPasteFrames("<pasted_content id=\"zz\">x") == "<pasted_content id=\"zz\">x")

        var t = Transcript()
        let queued = "<pasted_content id=\"e322\">\nlater\n</pasted_content id=\"e322\">"
        t.append([
            user("p1", framed("d5a3", "line one\nline two")),
            user("p2", [["type": "text", "text": framed("a97c", "pasted") + "\n[Image #5]"], ["type": "image", "source": [:]]]),
            line(["type": "queue-operation", "operation": "enqueue", "content": queued]),
        ])
        #expect(t.queued == ["later"])
        t.append([
            line(["type": "attachment", "uuid": "q1", "attachment": ["type": "queued_command", "prompt": queued, "commandMode": "prompt", "origin": ["kind": "human"]]]),
            line(["type": "queue-operation", "operation": "remove", "content": queued]),
        ])
        #expect(t.queued.isEmpty)
        #expect(t.items.map(\.kind) == [
            .prompt("line one\nline two", images: 0),
            .prompt("pasted\n[Image #5]", images: 1),
            .prompt("later", images: 0),
        ])
    }

    @Test func codexApprovalsSplitIntoTheirParts() throws {
        let screen = """

          Would you like to run the following command?

          Reason: Run the tests to check the fix

          $ swift test --filter GreetingTests
            --parallel

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for this command in this session (a)
          3. No, and tell Codex what to do differently (esc)

          Press enter to confirm or esc to go back
        """
        let p = try #require(ScreenPrompt.parse(screen: screen))
        #expect(p.options.map(\.label) == ["Yes, proceed (y)", "Yes, and don't ask again for this command in this session (a)", "No, and tell Codex what to do differently (esc)"])
        let a = try #require(p.codexApproval)
        #expect(a.question == "Would you like to run the following command?")
        #expect(a.reason == "Run the tests to check the fix")
        #expect(a.command == "swift test --filter GreetingTests --parallel")
        #expect(a.details.isEmpty)
        #expect(p.options.map { ScreenPrompt.withoutKeyHint($0.label) } == ["Yes, proceed", "Yes, and don't ask again for this command in this session", "No, and tell Codex what to do differently"])
        // Esc says no, as Codex's own hint does.
        #expect(p.keys(for: p.options[2]) == ["esc"])
        #expect(ScreenPrompt.withoutKeyHint("Use (beta) mode") == "Use (beta) mode")
        #expect(ScreenPrompt.withoutKeyHint("Yes, and switch to accept edits for this session (shift+tab)") == "Yes, and switch to accept edits for this session")
    }

    @Test func aBackgroundAgentsNoticeSaysHowLongAndWhatItFound() {
        let task = """
        <task-notification>
        <task-id>a2d</task-id>
        <tool-use-id>toolu_1</tool-use-id>
        <status>completed</status>
        <summary>Agent "List txt files" finished</summary>
        <result>4 .txt files: a.txt, b.txt</result>
        <usage><subagent_tokens>8897</subagent_tokens><tool_uses>1</tool_uses><duration_ms>44319</duration_ms></usage>
        </task-notification>
        """
        var t = Transcript()
        t.append([user("n1", task, extra: ["origin": ["kind": "task-notification"]])])
        #expect(t.items.map(\.kind) == [
            .notice(.task(id: "a2d", status: "completed", summary: "Agent \"List txt files\" finished",
                          milliseconds: 44319, result: "4 .txt files: a.txt, b.txt", toolUse: "toolu_1")),
        ])
    }

    @Test func peerMessagesLoseTheirFrame() {
        let body = "[Subagent hand-back] The text below is the final report. The report follows:\n  \n  # Result\n  All good."
        var t = Transcript()
        t.append([
            line(["type": "attachment", "uuid": "p1", "attachment": ["type": "queued_command", "prompt": "<agent-message from=\"a1\">\n\(body)\n</agent-message>", "commandMode": "prompt",
                                                                    "origin": ["kind": "peer", "from": "a1", "name": "general-purpose", "body": body]]]),
            user("p2", "Another Claude session sent a message:\n<agent-message from=\"a1\">\n\(body)\n</agent-message>", extra: ["isMeta": true, "origin": ["kind": "peer", "from": "a1", "name": "general-purpose", "body": body]]),
        ])
        #expect(t.items.map(\.kind) == [.notice(.message(from: "general-purpose", text: "# Result\nAll good."))])
    }

    @Test func titlesAndApiErrors() {
        var t = Transcript()
        t.append([
            line(["type": "ai-title", "aiTitle": "Fix login"]),
            assistant("e1", [["type": "text", "text": "API Error: 529 overloaded"]], extra: ["isApiErrorMessage": true, "message": ["model": "<synthetic>", "content": [["type": "text", "text": "API Error: 529 overloaded"]]]]),
        ])
        #expect(t.title == "Fix login")
        t.append([line(["type": "custom-title", "customTitle": "Login bug"])])
        #expect(t.title == "Login bug")
        #expect(t.items.map(\.kind) == [.notice(.error("API Error: 529 overloaded"))])
    }

    @Test func splitLinesKeepsAPartialLastLine() {
        let data = Data("a\n\nbb\ncc".utf8)
        let (lines, rest) = data.splitLines()
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["a", "bb"])
        #expect(String(decoding: rest, as: UTF8.self) == "cc")
        let sliced = Data("xx\nyy\n".utf8).dropFirst(3)
        let (l2, r2) = Data(sliced).splitLines()
        #expect(l2.map { String(decoding: $0, as: UTF8.self) } == ["yy"])
        #expect(r2.isEmpty)
    }

    @Test func toolSummaries() {
        #expect(ToolCall(id: "1", name: "Read", input: ["file_path": "/a/b.swift"]).summary == "/a/b.swift")
        #expect(ToolCall(id: "1", name: "Bash", input: ["command": "make\nmake test"]).summary == "make")
        #expect(ToolCall(id: "1", name: "mcp__x__y", input: ["query": "cats"]).summary == "cats")
        #expect(ToolCall(id: "1", name: "mcp__github__search_issues", input: ["q": "repo:a/b reset"]).summary == "repo:a/b reset")
        #expect(ToolCall(id: "1", name: "mcp__github__get_issue", input: ["repo": "b", "owner": "a", "issue_number": 412, "labels": ["x"]]).summary == "issue_number: 412, owner: a, repo: b")
        #expect(ToolCall(id: "1", name: "AskUserQuestion", input: ["questions": [["question": "Which one?"]]]).summary == "Which one?")
    }
}

@Suite struct MarkdownTests {
    @Test func blocks() {
        let text = """
        # Title
        Some **bold** text
        on two lines.

        - one
        - two
          - nested
        1. first
        2. second

        ```swift
        let x = 1
        ```

        | Name | Size |
        |:-----|-----:|
        | a \\| b | `x|y` |

        > quoted
        ---
        """
        let blocks = MarkdownBlock.parse(text)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\non two lines."),
            .list([
                MarkdownListItem(level: 0, number: nil, checked: nil, text: "one"),
                MarkdownListItem(level: 0, number: nil, checked: nil, text: "two"),
                MarkdownListItem(level: 1, number: nil, checked: nil, text: "nested"),
                MarkdownListItem(level: 0, number: 1, checked: nil, text: "first"),
                MarkdownListItem(level: 0, number: 2, checked: nil, text: "second"),
            ]),
            .code(language: "swift", text: "let x = 1"),
            .table(header: ["Name", "Size"], alignments: [.leading, .trailing], rows: [["a | b", "`x|y`"]]),
            .quote("quoted"),
            .rule,
        ])
    }

    @Test func unclosedFenceRunsToTheEnd() {
        #expect(MarkdownBlock.parse("```\na\n\nb") == [.code(language: "", text: "a\n\nb")])
    }

    @Test func checklistsAndContinuations() {
        let blocks = MarkdownBlock.parse("- [x] done\n- [ ] todo\n  more about it\n\nAfter")
        #expect(blocks == [
            .list([
                MarkdownListItem(level: 0, number: nil, checked: true, text: "done"),
                MarkdownListItem(level: 0, number: nil, checked: false, text: "todo\nmore about it"),
            ]),
            .paragraph("After"),
        ])
    }

    @Test func fenceUnderAnItem() {
        // Indented under its item, right after it: a code block all the same,
        // whose headings stay code, and the items after it a list again.
        let text = """
        - The message:
          ```
          # Selected text:

          ## Selection 1
          a line
          ```
        - **After** it
        1. Run:
           ```sh
           make
           ```
        2. Then
        """
        #expect(MarkdownBlock.parse(text) == [
            .list([MarkdownListItem(level: 0, number: nil, checked: nil, text: "The message:")]),
            .code(language: "", text: "# Selected text:\n\n## Selection 1\na line"),
            .list([
                MarkdownListItem(level: 0, number: nil, checked: nil, text: "**After** it"),
                MarkdownListItem(level: 0, number: 1, checked: nil, text: "Run:"),
            ]),
            .code(language: "sh", text: "make"),
            .list([MarkdownListItem(level: 0, number: 2, checked: nil, text: "Then")]),
        ])
    }
}

@Suite struct ScreenPromptTests {
    @Test func permissionPrompt() {
        let screen = """
        ⏺ Bash(ls -la)

        ────────────────────────────────────────────────────────
         Bash command

           ls -la
           List files

         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for ls commands in /Users/me/project
           3. No, and tell Claude what to do differently (esc)

         Esc to cancel · Tab to amend
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.options.map(\.number) == [1, 2, 3])
        #expect(p?.options.first?.focused == true)
        #expect(p?.options[1].label == "Yes, and don't ask again for ls commands in /Users/me/project")
        #expect(p?.question == ["Bash command", "", "  ls -la", "  List files", "", "Do you want to proceed?"])
        #expect(p?.footer == "Esc to cancel · Tab to amend")
        #expect(p.map { $0.keys(for: $0.options[0]) } == ["1"])
        #expect(p.map { $0.keys(for: $0.options[2]) } == ["esc"])
    }

    @Test func boxedQuestionWithDescriptions() {
        let screen = """
        ╭──────────────────────────────────────╮
        │ Which approach?                      │
        │                                      │
        │ ❯ 1. Fast                            │
        │      Less code, more risk            │
        │   2. Safe                            │
        │      More code                       │
        ╰──────────────────────────────────────╯
          Enter to select · Esc to cancel
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.question == ["Which approach?"])
        #expect(p?.options.map(\.label) == ["Fast", "Safe"])
        #expect(p?.options.map(\.detail) == ["Less code, more risk", "More code"])
        #expect(p?.footer == "Enter to select · Esc to cancel")
    }

    @Test func noPromptOnAPlainScreen() {
        #expect(ScreenPrompt.parse(screen: "$ ls\nfoo bar\n$ ") == nil)
        // A list in Claude's answer that doesn't start at 1.
        #expect(ScreenPrompt.parse(screen: "2. second\n3. third") == nil)
    }
}

@Suite struct SlimTests {
    /// The decoded value of `s` written as a JSON string, cut by `slim`.
    private func slimmed(_ jsonString: String, limit: Int) -> String? {
        let line = Data("{\"a\":1,\"s\":\"\(jsonString)\",\"b\":\"end\"}".utf8)
        let out = Transcript.slim(line, limit: limit)
        guard let object = try? JSONSerialization.jsonObject(with: out) as? [String: Any], object["b"] as? String == "end" else { return nil }
        return object["s"] as? String
    }

    @Test func cutsLongStringsAndKeepsJSONValid() {
        let limit = 64
        let tails = ["\\n", "\\\"", "\\\\", "\\u00e9", "\\ud83d\\ude00", "é", "😀", "abc"]
        for tail in tails {
            for pad in 50 ..< 70 {
                let raw = String(repeating: "x", count: pad) + tail + String(repeating: "y", count: 40)
                let original = try! JSONSerialization.jsonObject(with: Data("\"\(raw)\"".utf8), options: .fragmentsAllowed) as! String
                guard let value = slimmed(raw, limit: limit) else {
                    Issue.record("invalid JSON for tail \(tail) pad \(pad)")
                    continue
                }
                #expect(value.hasSuffix("…"))
                #expect(original.hasPrefix(String(value.dropLast())), "tail \(tail) pad \(pad)")
            }
        }
    }

    @Test func leavesShortLinesAlone() {
        let line = Data("{\"s\":\"short\",\"t\":\"also \\\" short\"}".utf8)
        #expect(Transcript.slim(line, limit: 8) != line) // "also \" short" is longer than 8
        #expect(Transcript.slim(line, limit: 64) == line)
    }

    @Test func bigPicturesDoNotSlowParsing() {
        let picture = String(repeating: "QUJD", count: 500_000)
        let line = Data("{\"type\":\"user\",\"uuid\":\"u\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"\(picture)\"}}]}]}}".utf8)
        let slim = Transcript.slim(line)
        #expect(slim.count < Transcript.longString + 300)
        var t = Transcript()
        t.append([Data("{\"type\":\"assistant\",\"uuid\":\"a\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"Read\",\"input\":{}}]}}".utf8), line])
        guard case .tool(let call) = t.items.first?.kind else { Issue.record("no tool"); return }
        #expect(call.result?.images == 1)
    }
}

@Suite struct ClaudeProjectTests {
    @Test func folderNames() {
        #expect(ClaudeProject.folderName(for: "/Users/me/shop/shop-backend") == "-Users-me-shop-shop-backend")
        #expect(ClaudeProject.folderName(for: "/tmp/é x") == "-tmp---x")
        let long = "/" + String(repeating: "a", count: 210)
        let name = ClaudeProject.folderName(for: long)
        #expect(name.hasPrefix("-" + String(repeating: "a", count: 199) + "-"))
        // JavaScript: Math.abs(h).toString(36) with h = the string's 32-bit hash.
        var h: Int32 = 0
        for u in long.utf16 { h = (h &<< 5) &- h &+ Int32(u) }
        #expect(name.hasSuffix("-" + String(abs(Int64(h)), radix: 36)))
    }

    @Test func rowsGroupToolRuns() {
        var t = Transcript()
        t.append([
            Data(#"{"type":"user","uuid":"u1","message":{"content":"go"}}"#.utf8),
            Data(#"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#.utf8),
            Data(#"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}"#.utf8),
            Data(#"{"type":"assistant","uuid":"a3","message":{"content":[{"type":"text","text":"done"}]}}"#.utf8),
        ])
        let rows = t.rows
        #expect(rows.count == 3)
        if case .activity(_, let items) = rows[1] { #expect(items.count == 3) } else { Issue.record("no activity row") }
    }
}

/// Screens Claude Code 2.1.322 drew (2026-11-11), the rules shortened.
@Suite struct ClaudeScreenTests {
    private let rule = String(repeating: "─", count: 60)
    private let dashes = String(repeating: "╌", count: 60)
    private let top = String(repeating: "▔", count: 60)

    /// `/memory` in 2.1.322: options without numbers, a link between them and the hint.
    @Test func memoryMenu() {
        let screen = """
        ✻ Sautéed for 9s · done 12:33 AM
        \(top)
           Memory

           ❯ Auto-memory  false
             off in safe mode · restart without --safe-mode to re-enable

           ❯ User instructions      Saved in ~/.claude/CLAUDE.md
             Project instructions   Checked in at ./CLAUDE.md
             Open auto-memory folder

           Learn more: https://code.claude.com/docs/en/memory

           Enter to confirm · Esc to cancel
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.numbered == false)
        #expect(p?.options.map(\.label) == ["User instructions", "Project instructions", "Open auto-memory folder"])
        #expect(p?.options.first?.detail == "Saved in ~/.claude/CLAUDE.md")
        #expect(p?.options.first?.focused == true)
        #expect(p?.footer == "Enter to confirm · Esc to cancel")
        #expect(p.map { $0.keys(for: $0.options[1]) } == ["down", "enter"])
    }

    /// A screen of Claude Code's own that offers nothing to pick: its text and the way out.
    @Test func panelWithoutOptions() {
        let screen = """
        ⏺ Done.
        \(top)
          Status   Config   Usage

          Version: 2.1.322
          Model: claude-haiku-5-5

          Esc to close
        """
        #expect(ScreenPrompt.parse(screen: screen) == nil)
        let p = ScreenPrompt.panel(screen: screen)
        #expect(p?.title == "Status   Config   Usage")
        #expect(p?.context.contains("Model: claude-haiku-5-5") == true)
        #expect(p?.footer == "Esc to close")
        #expect(p?.options.isEmpty == true)
        // Claude at work says `esc to interrupt`: no panel.
        #expect(ScreenPrompt.panel(screen: "\(top)\n✻ Thinking… (esc to interrupt)\n") == nil)
    }

    @Test func askUserQuestionFirstOfTwo() {
        let screen = """
        ❯ Use the AskUserQuestion tool…
        \(rule)
        ←  ☐ Color  ☐ Pets  ✔ Submit  →

        Which color do you prefer?

        ❯ 1. Red (warm)
             A warm red tone
          2. Blue (cool)
             A cool blue tone
          3. Green (natural)
             A natural green tone
          4. Type something.
        \(rule)
          5. Chat about this

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.options.map(\.label) == ["Red (warm)", "Blue (cool)", "Green (natural)", "Type something.", "Chat about this"])
        #expect(p?.options.first?.detail == "A warm red tone")
        #expect(p?.options.first?.focused == true)
        #expect(p?.tabs.map(\.title) == ["Color", "Pets", "Submit"])
        #expect(p?.tabs.map(\.answered) == [false, false, false])
        #expect(p?.tabs.last?.isSubmit == true)
        #expect(p?.questionText == "Which color do you prefer?")
        #expect(p?.isMultiSelect == false)
        #expect(p?.isReview == false)
        #expect(p?.option(labelled: "type something")?.number == 4)
    }

    @Test func askUserQuestionMultiSelect() {
        let screen = """
        \(rule)
        ←  ☒ Color  ☐ Pets  ✔ Submit  →

        Which pets do you have?

          1. [✔] Cat
                 A cat
          2. [ ] Dog
                 A dog
          3. [✔] Fish
                 A fish
          4. [ ] Type something
        ❯    Submit
        \(rule)
          5. Chat about this

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.options.map(\.label) == ["Cat", "Dog", "Fish", "Type something", "Chat about this"])
        #expect(p?.options.map(\.checked) == [true, false, true, false, nil])
        #expect(p?.options[3].detail == "")
        #expect(p?.hasSubmitLine == true)
        #expect(p?.submitFocused == true)
        #expect(p?.isMultiSelect == true)
        #expect(p?.tabs.map(\.answered) == [true, false, false])
    }

    @Test func askUserQuestionReview() {
        let screen = """
        \(rule)
        ←  ☒ Color  ☒ Pets  ✔ Submit  →

        Review your answers

         ● Which color do you prefer?
           → Red (warm)
         ● Which pets do you have?
           → Cat, Fish

        Ready to submit your answers?

        ❯ 1. Submit answers
          2. Cancel
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.isReview == true)
        #expect(p?.options.map(\.label) == ["Submit answers", "Cancel"])
        #expect(p.map { $0.keys(for: $0.options[0]) } == ["1"])
    }

    @Test func bashPermission() {
        let screen = """
        ❯ Run the shell command: ls -la /tmp | head -3
          ⎿  $ ls -la /tmp | head -3
        \(rule)
         Bash command
         Tip: auto mode handles these prompts for you — choose "switch to auto mode" below

         List first entries of /tmp
        \(dashes)
         ls -la /tmp | head -3
        \(dashes)
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, allow reading from /private/tmp from this project
           3. Yes, and switch to auto mode · auto mode handles these prompts for you
           4. No

         Esc to cancel · Tab to amend
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.question == ["Do you want to proceed?"])
        #expect(p?.title == "Bash command")
        #expect(p?.context.contains("ls -la /tmp | head -3") == true)
        #expect(p?.options.count == 4)
        #expect(p?.options.last?.label == "No")
        #expect(p?.canAmend == true)
        #expect(p.map { $0.moves(to: $0.options[3]) } == ["down", "down", "down"])
    }

    @Test func planApproval() {
        let screen = """
          \(rule)
           Ready to code?

           Here is Claude's plan:
          \(dashes)
           Plan: Append "world" to notes.txt
          \(dashes)
          \(rule)

           Claude has written up a plan and is ready to execute. Would you like to proceed?

           ❯ 1. Yes, and use auto mode
             2. Yes, manually approve edits
             3. Tell Claude what to change
                shift+tab to approve with this feedback

           ctrl+g to edit in VS Code · ~/.claude/plans/humble-discovering-lantern.md
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.options.map(\.label) == ["Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"])
        #expect(p?.options[2].detail == "shift+tab to approve with this feedback")
        #expect(p?.footer == "ctrl+g to edit in VS Code · ~/.claude/plans/humble-discovering-lantern.md")
        #expect(p?.questionText == "Claude has written up a plan and is ready to execute. Would you like to proceed?")
    }

    /// `/rewind` in 2.1.322: the messages apart by blank lines, `(current)` last.
    @Test func rewindList() {
        let list = """
        ⏺ Fruit: Mango.
        \(top)
           Rewind

           Restore the code and/or conversation to the point before…

             Write the numbers 1 to 80, one per line, nothing else. No tools.
             No code changes

             /plan
             No code changes

             [Image #1] [Image #2]What colors are these two squares? Answer in five words or fewer.
             No code changes

             Call AskUserQuestion with exactly one question, 'Which fruit?', header Fruit, options Apple and Pear. After I answer, h…
             2 files changed

           ❯ (current)



           Enter to continue · Esc to cancel
        """
        let p = ScreenPrompt.parse(screen: list)
        #expect(p?.numbered == false)
        #expect(p?.options.map(\.label) == [
            "Write the numbers 1 to 80, one per line, nothing else. No tools.", "/plan",
            "[Image #1] [Image #2]What colors are these two squares? Answer in five words or fewer.",
            "Call AskUserQuestion with exactly one question, 'Which fruit?', header Fruit, options Apple and Pear. After I answer, h…",
            "(current)",
        ])
        #expect(p?.options.map(\.detail) == ["No code changes", "No code changes", "No code changes", "2 files changed", ""])
        #expect(p?.options.last?.focused == true)
        #expect(p?.footer == "Enter to continue · Esc to cancel")
        #expect(p?.heading == "Rewind")
        #expect(p?.isRewindList == true)
        #expect(p.map { $0.keys(for: $0.options[1]) } == ["up", "up", "up", "enter"])
        // The cursor on a message: its line and the one under it are one option.
        let moved = list
            .replacingOccurrences(of: "     Call AskUserQuestion", with: "   ❯ Call AskUserQuestion")
            .replacingOccurrences(of: "   ❯ (current)", with: "     (current)")
        let q = ScreenPrompt.parse(screen: moved)
        #expect(q?.options.count == 5)
        #expect(q?.options.firstIndex(where: \.focused) == 3)
        #expect(q?.isRewindList == true)
        #expect(q.map { $0.keys(for: $0.options[4]) } == ["down", "enter"])
    }

    /// A rewind list longer than the screen: `↑ 5 more` over the first
    /// message it shows (2.1.325, 2026-11-13) is no option.
    @Test func rewindListScrolled() {
        let list = """
        ⏺ kiwi
        \(top)
           Rewind

           Restore the code and/or conversation to the point before…

             ↑ 5 more
             log line 0: all good…
             No code changes

           ❯ (current)

           Enter to continue · Esc to cancel
        """
        let p = ScreenPrompt.parse(screen: list)
        #expect(p?.options.map(\.label) == ["log line 0: all good…", "(current)"])
        #expect(p?.options.first?.detail == "No code changes")
        #expect(p?.isRewindList == true)
        #expect(p?.questionText.contains("more") == false)
        #expect(p.map { $0.keys(for: $0.options[0]) } == ["up", "enter"])
        // The cursor on the first message shown: the mark stays out of the question.
        let moved = list
            .replacingOccurrences(of: "     log line 0", with: "   ❯ log line 0")
            .replacingOccurrences(of: "   ❯ (current)", with: "     (current)")
        let q = ScreenPrompt.parse(screen: moved)
        #expect(q?.options.map(\.label) == ["log line 0: all good…", "(current)"])
        #expect(q?.options.first?.focused == true)
        #expect(q?.question.contains { $0.contains("more") } == false)
        // The mark on a line of its own.
        let apart = ScreenPrompt.parse(screen: list.replacingOccurrences(of: "↑ 5 more\n", with: "↑ 5 more\n\n"))
        #expect(apart?.options.map(\.label) == ["log line 0: all good…", "(current)"])
    }

    /// `/rewind`'s second step, its list cut by a short screen (`↓`), a warning under it.
    @Test func rewindConfirm() {
        let screen = """
        ⏺ Left square: red. Right square: blue.
        \(top)
           Rewind

           Confirm you want to restore to the point before you sent this message:

           │ Call AskUserQuestion with exactly one question, 'Which fruit?', header Fruit.
           │ (2h ago)

           This message and everything after it will be removed.
           The code will be restored -14 in plan.md and hello.txt.

           ❯ 1. Restore code and conversation
             2. Restore conversation
             3. Restore code
             4. Summarize from here
           ↓ 5. Summarize up to here

           ⚠ Restored files go back whole, losing later changes by anyone. Bash changes to other files are not undone.
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.numbered == true)
        #expect(p?.options.map(\.label) == ["Restore code and conversation", "Restore conversation", "Restore code", "Summarize from here", "Summarize up to here"])
        #expect(p?.options.first?.focused == true)
        #expect(p?.options.last?.focused == false)
        #expect(p?.footer.hasPrefix("⚠ Restored files go back whole") == true)
        #expect(p?.isRewindConfirm == true)
        #expect(p?.isRewindList == false)
        #expect(p?.question.contains { $0.contains("This message and everything after it will be removed.") } == true)
        #expect(p.map { $0.keys(for: $0.options[1]) } == ["2"])
        #expect(p?.rewindDetails == ScreenPrompt.RewindDetails(
            intro: "Confirm you want to restore to the point before you sent this message:",
            message: ["Call AskUserQuestion with exactly one question, 'Which fruit?', header Fruit."],
            ago: "2h ago",
            notes: ["This message and everything after it will be removed.", "The code will be restored -14 in plan.md and hello.txt."]))
    }

    /// The list's lines matched with the transcript's prompts, from the end.
    @Test func rewindMatchesPrompts() {
        let labels = ["Fix it", "Write the numbers 1 to 80…", "Fix it", "[Image #1] What colors…", "First line", "(current)"]
        let prompts: [(id: String, text: String)] = [
            ("p0", "Fix it"), ("p1", "Write the numbers 1 to 80, one per line"), ("c1", "/effort xhigh"),
            ("p2", "Fix it"), ("p3", "[Image #1] What colors are these?"), ("p4", "First line\nsecond line"),
        ]
        #expect(Rewind.prompt(for: 0, labels: labels, in: prompts) == "p0")
        #expect(Rewind.prompt(for: 1, labels: labels, in: prompts) == "p1")
        #expect(Rewind.prompt(for: 2, labels: labels, in: prompts) == "p2")
        #expect(Rewind.prompt(for: 3, labels: labels, in: prompts) == "p3")
        #expect(Rewind.prompt(for: 4, labels: labels, in: prompts) == "p4")
        #expect(Rewind.prompt(for: 5, labels: labels, in: prompts) == nil)
        // Not cut: a longer prompt with the same start isn't it.
        #expect(Rewind.prompt(for: 0, labels: ["Fix", "(current)"], in: [("a", "Fix it")]) == nil)
    }

    @Test func trustDialogWithoutNumbers() {
        let screen = """
        \(rule)
         Accessing workspace:

         /private/tmp/cctest

         Quick safety check: Is this a project you created or one you trust?

         ❯ No, exit
           Yes, I trust this folder

         Enter to confirm · Esc to cancel
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.numbered == false)
        #expect(p?.options.map(\.label) == ["No, exit", "Yes, I trust this folder"])
        #expect(p.map { $0.keys(for: $0.options[1]) } == ["down", "enter"])
    }

    @Test func idleScreenIsNoPrompt() {
        let screen = """
        ⏺ Your answers:
          1. Red
          2. Blue
        \(rule)
        ❯ 
        \(rule)
          ⏸ manual mode on · ? for shortcuts
        """
        #expect(ScreenPrompt.parse(screen: screen) == nil)
    }

    @Test func footerModesAndStatusLine() {
        let idle = """
                                                                 ◐ medium · /effort
        \(rule)
        ❯ Try "edit <filepath> to..."
        \(rule)
          ⏸ manual mode on · ? for shortcuts · ← 3 agents
        """
        let f = ClaudeFooter.parse(screen: idle)
        #expect(f?.mode == "default")
        #expect(f?.effort == "medium")
        #expect(f?.statusLine == [])
        let custom = """
        \(rule)
        ❯ 
        \(rule)
          lessss | Opus 5.5 · xhigh | context: 80% left
          Max 5x | current: 100% left | weekly: 85% left (tuesday 10pm)
          ⏵⏵ auto mode on
        """
        let g = ClaudeFooter.parse(screen: custom)
        #expect(g?.mode == "auto")
        #expect(g?.statusLine == ["lessss | Opus 5.5 · xhigh | context: 80% left", "Max 5x | current: 100% left | weekly: 85% left (tuesday 10pm)"])
        #expect(g?.input == "")
        #expect(ClaudeFooter.parse(screen: "\(rule)\n❯ x\n\(rule)\n  ⏵⏵ accept edits on (shift+tab to cycle)")?.mode == "acceptEdits")
        #expect(ClaudeFooter.parse(screen: "\(rule)\n❯ x\n\(rule)\n  ⏸ plan mode on (shift+tab to cycle)")?.mode == "plan")
    }

    /// A new session's header, before any answer names the model.
    @Test func headerNamesModelAndEffort() {
        let fresh = """
         ▐▛███▛█   Claude Code v2.1.323
        ▝▜██████▀  Opus 5.5 with xhigh effort · Claude Team
         ▝▝   ▝▝   ~/Projects/swiftr · /rc

        \(rule)
        ❯ Try "fix lint errors"
        \(rule)
          ⏵⏵ auto mode on (shift+tab to cycle) · ← 3 agents
        """
        let f = ClaudeFooter.parse(screen: fresh)
        #expect(f?.headerModel == "claude-opus-5-5")
        #expect(f?.headerEffort == "xhigh")
        let plain = ClaudeFooter.parse(screen: "  Claude Code v2.1.323\n  Sonnet 5.5 · API Usage Billing\n\(rule)\n❯ \n\(rule)")
        #expect(plain?.headerModel == "claude-sonnet-5-5")
        #expect(plain?.headerEffort == nil)
        // Cut short on a narrow screen.
        let cut = ClaudeFooter.parse(screen: "Claude Code v2.1.323\nFable 5.2 with xhigh eff…\n\(rule)\n❯ \n\(rule)")
        #expect(cut?.headerModel == "claude-fable-5-2")
        #expect(cut?.headerEffort == nil)
        // Scrolled away.
        #expect(ClaudeFooter.parse(screen: "\(rule)\n❯ x\n\(rule)\n  ⏵⏵ auto mode on")?.headerModel == nil)
    }
}

@Suite struct SessionFactsTests {
    @Test func factsFromLines() {
        var t = Transcript()
        t.append([
            line(["type": "user", "uuid": "u1", "timestamp": "2026-11-12T04:42:12.038Z", "gitBranch": "main", "cwd": "/p", "version": "2.1.322",
                  "message": ["role": "user", "content": "go"]]),
            line(["type": "permission-mode", "permissionMode": "plan", "sessionId": "s"]),
            line(["type": "assistant", "uuid": "a1", "effort": "xhigh", "timestamp": "2026-11-12T04:42:15Z",
                  "message": ["model": "claude-opus-5-5", "content": [["type": "text", "text": "ok"]],
                              "usage": ["input_tokens": 2, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 197_043, "output_tokens": 50]]]),
        ])
        #expect(t.facts.model == "claude-opus-5-5")
        #expect(t.facts.effort == "xhigh")
        #expect(t.facts.contextTokens == 198_045)
        #expect(t.facts.permissionMode == "plan")
        #expect(t.facts.gitBranch == "main")
        #expect(t.facts.version == "2.1.322")
        #expect(t.facts.lastPromptAt == 1_794_458_532.038)
        #expect(t.items.first?.time == 1_794_458_532.038)
        #expect(t.items.last?.time == 1_794_458_535)
        #expect(ClaudeModel.contextWindow(t.facts.model) == 1_000_000)
    }

    @Test func modelIDFromItsName() {
        #expect(ClaudeModel.id(displayName: "Opus 5.5") == "claude-opus-5-5")
        #expect(ClaudeModel.id(displayName: "Opus 5.5 (1M context)") == "claude-opus-5-5")
        #expect(ClaudeModel.id(displayName: "Default (Fable 5.2)") == "claude-fable-5-2")
        #expect(ClaudeModel.id(displayName: "Opus 5") == "claude-opus-5")
        #expect(ClaudeModel.id(displayName: "gpt-5.5") == "gpt-5.5")
        #expect(ClaudeModel.displayName(ClaudeModel.id(displayName: "Haiku 4.5")) == "Haiku 4.5")
    }

    /// `/model` and `/effort` change them before the next answer does.
    @Test func modelAndEffortCommandsChangeFacts() {
        var t = Transcript()
        t.append([
            line(["type": "assistant", "uuid": "a1", "effort": "xhigh",
                  "message": ["model": "claude-opus-5-5", "content": [["type": "text", "text": "ok"]]]]),
            line(["type": "user", "uuid": "u2", "parentUuid": "a1",
                  "message": ["role": "user", "content": "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>"]]),
            line(["type": "user", "uuid": "u3", "parentUuid": "u2",
                  "message": ["role": "user", "content": "<local-command-stdout>Set model to `Fable 5.2` and saved as your default for new sessions · `max` effort for this session only</local-command-stdout>"]]),
        ])
        #expect(t.facts.model == "claude-fable-5-2")
        #expect(t.facts.effort == "max")
        t.append([line(["type": "system", "subtype": "local_command", "uuid": "s4", "parentUuid": "u3",
                        "content": "<local-command-stdout>Set effort level to high (this session only): Comprehensive implementation</local-command-stdout>"])])
        #expect(t.facts.effort == "high")
        #expect(t.facts.model == "claude-fable-5-2")
        // Words that only look alike change nothing.
        t.append([line(["type": "user", "uuid": "u5", "parentUuid": "s4", "message": ["role": "user", "content": "<local-command-stdout>Current model: Opus 5.5</local-command-stdout>"]])])
        #expect(t.facts.model == "claude-fable-5-2")
    }

    /// The chips under the field show the model and effort: their commands
    /// make no row, unless what they print is news (an error, a warning).
    @Test func modelAndEffortCommandsShowNoRow() {
        func command(_ id: String, _ name: String, _ args: String = "") -> Data {
            user(id, "<command-name>/\(name)</command-name>\n<command-message>\(name)</command-message>\n<command-args>\(args)</command-args>")
        }
        func printed(_ id: String, _ text: String) -> Data { user(id, "<local-command-stdout>\(text)</local-command-stdout>") }
        var t = Transcript()
        t.append([
            command("m1", "model"), printed("m2", "Kept model as `Opus 5.5`"),
            command("m3", "model"), printed("m4", "Set model to `Fable 5.2` and saved as your default for new sessions"),
            command("e1", "effort"), printed("e2", "Cancelled"),
            command("e3", "effort", "max"), printed("e4", "Set effort level to max (this session only): Maximum capability with deepest reasoning"),
            // A change told without its command.
            line(["type": "system", "subtype": "local_command", "uuid": "e5",
                  "content": "<local-command-stdout>Set effort level to high (this session only): Comprehensive implementation</local-command-stdout>"]),
            user("p1", "Go on"),
        ])
        #expect(t.items.map(\.kind) == [.prompt("Go on", images: 0)])
        #expect(t.facts.model == "claude-fable-5-2")
        #expect(t.facts.effort == "high")
        // The command waits for what it prints, which decides.
        t.append([command("m5", "model", "opus-9")])
        #expect(t.items.count == 1)
        t.append([printed("m6", "Model 'opus-9' not found")])
        #expect(t.items.last?.kind == .command("/model opus-9", output: "Model 'opus-9' not found"))
        t.append([command("e6", "effort", "fast"), printed("e7", "Invalid argument: fast. Valid options are: low, medium, high, xhigh, max, auto")])
        #expect(t.items.last?.kind == .command("/effort fast", output: "Invalid argument: fast. Valid options are: low, medium, high, xhigh, max, auto"))
        #expect(t.items.count == 3)
    }

    /// Switched with ⇧⇥, the mode shows only on the messages sent after.
    @Test func modeOfTheLastMessageSent() {
        var t = Transcript()
        t.append([
            line(["type": "permission-mode", "permissionMode": "auto", "sessionId": "s"]),
            line(["type": "user", "uuid": "u1", "permissionMode": "auto", "message": ["role": "user", "content": "go"]]),
            line(["type": "permission-mode", "permissionMode": "auto", "sessionId": "s"]),
            line(["type": "user", "uuid": "u2", "parentUuid": "u1", "permissionMode": "default", "message": ["role": "user", "content": "again"]]),
        ])
        #expect(t.facts.permissionMode == "default")
    }

    @Test func modelNames() {
        #expect(ClaudeModel.displayName("claude-opus-5-5") == "Opus 5.5")
        #expect(ClaudeModel.displayName("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(ClaudeModel.displayName("claude-opus-5-5[1m]") == "Opus 5.5 (1M)")
        #expect(ClaudeModel.displayName("claude-haiku-5-5") == "Haiku 5.5")
        #expect(ClaudeModel.displayName("gpt-5-codex") == "gpt-5-codex")
        #expect(ClaudeModel.contextWindow("claude-sonnet-4-5") == 200_000)
        #expect(ClaudeModel.contextWindow("claude-sonnet-4-5[1m]") == 1_000_000)
    }

    @Test func isoDates() {
        #expect(Transcript.seconds(iso: "1970-01-01T00:00:00Z") == 0)
        #expect(Transcript.seconds(iso: "2026-11-12T04:42:23.5Z") == 1_794_458_543.5)
        #expect(Transcript.seconds(iso: "2026-11-11T23:42:23-05:00") == 1_794_458_543)
        #expect(Transcript.seconds(iso: "nope") == nil)
    }

    @Test func answersAndDeclines() {
        var t = Transcript()
        t.append([
            line(["type": "assistant", "uuid": "a1", "message": ["model": "claude-haiku-5-5", "content": [
                ["type": "tool_use", "id": "q1", "name": "AskUserQuestion", "input": ["questions": [
                    ["header": "Color", "question": "Which color?", "multiSelect": false, "options": [["label": "Red", "description": "warm"]]],
                ]]],
                ["type": "tool_use", "id": "b1", "name": "Bash", "input": ["command": "rm -rf /tmp/x"]],
            ]]]),
            line(["type": "user", "uuid": "u1", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "q1", "content": "The user answered: \"Which color?\"=\"Red\"."],
            ]], "toolUseResult": ["questions": [["question": "Which color?"]], "answers": ["Which color?": "Red"]]]),
            line(["type": "user", "uuid": "u2", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "b1", "is_error": true,
                 "content": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). To tell you how to proceed, the user said:\nUse ls instead"],
            ]]]),
        ])
        guard case .tool(let ask) = t.items[0].kind, case .tool(let bash) = t.items[1].kind else { Issue.record("no tools"); return }
        #expect(ask.result?.answers == [ToolResult.Answer(question: "Which color?", answer: "Red")])
        #expect(bash.result?.declined == "Use ls instead")
        #expect(ask.result?.declined == nil)
    }

    @Test func todosFromTodoWriteAndTasks() {
        var t = Transcript()
        t.append([
            line(["type": "assistant", "uuid": "a1", "message": ["content": [
                ["type": "tool_use", "id": "w1", "name": "TodoWrite", "input": ["todos": [
                    ["content": "Read the code", "status": "completed", "activeForm": "Reading the code"],
                    ["content": "Write tests", "status": "in_progress", "activeForm": "Writing tests"],
                ]]],
                ["type": "tool_use", "id": "c1", "name": "TaskCreate", "input": ["subject": "Ship it", "activeForm": "Shipping it"]],
            ]]]),
            line(["type": "user", "uuid": "u1", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "c1", "content": "Task #7 created successfully: Ship it"],
            ]]]),
            line(["type": "assistant", "uuid": "a2", "message": ["content": [
                ["type": "tool_use", "id": "u7", "name": "TaskUpdate", "input": ["taskId": "7", "status": "in_progress"]],
            ]]]),
        ])
        let todos = t.todos
        #expect(todos.map(\.text) == ["Read the code", "Write tests", "Ship it"])
        #expect(todos.map(\.status) == [.completed, .inProgress, .inProgress])
        #expect(todos.last?.id == "7")
        #expect(todos.last?.active == "Shipping it")
    }
}

@Suite struct AskUserTests {
    private let rule = String(repeating: "─", count: 60)

    private var pets: AskQuestion {
        AskQuestion(header: "Pets", question: "Which pets do you have?", multiSelect: true,
                    options: [.init(label: "Cat", detail: "A cat"), .init(label: "Dog", detail: "A dog"), .init(label: "Fish", detail: "A fish")])
    }

    @Test func questionsFromInput() throws {
        let input = try JSON(text: """
        {"questions":[{"header":"Color","question":"Which color do you prefer?","multiSelect":false,
          "options":[{"label":"Red (warm)","description":"A warm red tone"},{"label":"Blue (cool)","description":"A cool blue tone"}]},
          {"header":"Pets","question":"Which pets do you have?","multiSelect":true,"options":[{"label":"Cat"},{"label":"Dog"}]}]}
        """)
        let qs = AskQuestion.list(input)
        #expect(qs.count == 2)
        #expect(qs[0].header == "Color")
        #expect(qs[0].options.map(\.label) == ["Red (warm)", "Blue (cool)"])
        #expect(qs[0].options[1].detail == "A cool blue tone")
        #expect(qs[0].typeNumber == 3)
        #expect(qs[0].chatNumber == 4)
        #expect(qs[1].multiSelect)
    }

    @Test func screenAsksTheQuestionAndTogglesBoxes() {
        let screen = """
        \(rule)
        ←  ☒ Color  ☐ Pets  ✔ Submit  →

        Which pets do you
        have?

        ❯ 1. [✔] Cat
                 A cat
          2. [ ] Dog
                 A dog
          3. [ ] Fish
                 A fish
          4. [ ] Type something
             Submit
        \(rule)
          5. Chat about this

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
        let p = try! #require(ScreenPrompt.parse(screen: screen))
        #expect(p.asks(pets))
        #expect(!p.asks(AskQuestion(question: "Which color do you prefer?", options: [])))
        #expect(p.toggles(toMatch: ["Dog", "Fish"], in: pets) == ["1", "2", "3"])
        #expect(p.toggles(toMatch: ["Cat"], in: pets) == [])
        #expect(p.downsToSubmit == 4)
    }

    @Test func reviewAsksNothing() {
        let review = ScreenPrompt(question: ["Review your answers", "", " ● Which pets do you have?", "   → Cat, Fish", "", "Ready to submit your answers?"],
                                  options: [.init(number: 1, label: "Submit answers", focused: true), .init(number: 2, label: "Cancel")], footer: "")
        #expect(review.isReview)
        #expect(!review.asks(pets))
    }

    @Test func refusalAndRevise() {
        let permission = ScreenPrompt(question: ["Do you want to proceed?"], options: [
            .init(number: 1, label: "Yes", focused: true),
            .init(number: 2, label: "Yes, and don't ask again for ls commands"),
            .init(number: 3, label: "No"),
        ], footer: "Esc to cancel · Tab to amend")
        #expect(permission.refusal?.number == 3)
        #expect(permission.canAmend)
        #expect(permission.moves(to: permission.refusal!) == ["down", "down"])
        let plan = ScreenPrompt(question: ["Would you like to proceed?"], options: [
            .init(number: 1, label: "Yes, and use auto mode"),
            .init(number: 2, label: "Yes, manually approve edits"),
            .init(number: 3, label: "Tell Claude what to change"),
        ], footer: "")
        #expect(plan.reviseOption?.number == 3)
    }

    @Test func openCallsOfTheLastTurn() {
        func line(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
        let t = Transcript.parse([
            line(["type": "user", "uuid": "u1", "message": ["role": "user", "content": "go"]]),
            line(["type": "assistant", "uuid": "a1", "message": ["model": "claude-opus-5-5", "content": [
                ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/a"]],
            ]]]),
            line(["type": "user", "uuid": "u2", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "x"]]]]),
            line(["type": "assistant", "uuid": "a2", "message": ["model": "claude-opus-5-5", "content": [
                ["type": "text", "text": "Now asking."],
                ["type": "tool_use", "id": "t2", "name": "AskUserQuestion", "input": ["questions": []]],
            ]]]),
        ])
        #expect(t.openCalls.map(\.id) == ["t2"])
        let done = Transcript.parse([
            line(["type": "assistant", "uuid": "a1", "message": ["model": "claude-opus-5-5", "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": [:]]]]]),
            line(["type": "user", "uuid": "u1", "message": ["role": "user", "content": "next"]]),
        ])
        #expect(done.openCalls.isEmpty)
    }
}

@Suite struct SlashCommandTests {
    @Test func frontMatter() {
        let text = """
        ---
        name: 'rodin'
        description: "Asks \\"why\\" a lot"
        argument-hint: [topic]
        ---

        # Body
        """
        let f = SlashCommand.frontMatter(text)
        #expect(f["name"] == "rodin")
        #expect(f["description"] == "Asks \"why\" a lot")
        #expect(f["argument-hint"] == "[topic]")
        #expect(SlashCommand.frontMatter("# No front matter").isEmpty)
    }

    @Test func commandsFromFiles() {
        let skill = SlashCommand.from(file: "---\nname: gh\ndescription: GitHub CLI patterns\n---\nBody", name: "gh-dir", source: .personal, isSkill: true)
        #expect(skill?.name == "gh")
        #expect(skill?.isSkill == true)
        let plugin = SlashCommand.from(file: "Start a session\nmore", name: "q-begin", source: .plugin, isSkill: false, plugin: "huntkit")
        #expect(plugin?.name == "huntkit:q-begin")
        #expect(plugin?.summary == "Start a session")
        let nested = SlashCommand.from(file: "", name: "frontend/review", source: .project, isSkill: false)
        #expect(nested?.name == "frontend:review")
        #expect(SlashCommand.from(file: "---\nuser-invocable: false\n---\n", name: "x", source: .personal, isSkill: true) == nil)
    }

    @Test func matchingRanksPrefixesFirst() {
        let all = SlashCommand.builtIns + [SlashCommand("huntkit:q-begin", "Start", source: .plugin), SlashCommand("modelling", "Mine", source: .personal)]
        let m = SlashCommand.matching("mod", in: all)
        #expect(m.first?.name == "model")
        #expect(m.prefix(3).map(\.name).contains("modelling"))
        #expect(SlashCommand.matching("q-b", in: all).first?.name == "huntkit:q-begin")
        #expect(SlashCommand.matching("quit", in: all).first?.name == "exit")
        // Two letters: only names that start with them, or have a word that does.
        let mo = SlashCommand.matching("mo", in: all + [SlashCommand("lemo-opuscar", "Films", source: .personal, isSkill: true)])
        #expect(mo.contains { $0.name == "model" })
        #expect(!mo.contains { $0.name == "lemo-opuscar" || $0.name == "memory" })
        // Descriptions count only when no name matches.
        #expect(SlashCommand.matching("conversation", in: all).isEmpty == false)
        #expect(!SlashCommand.matching("mode", in: all).contains { !$0.name.contains("mode") })
        #expect(SlashCommand.typedName("/mo") == "mo")
        #expect(SlashCommand.typedName("/model opus") == nil)
        #expect(SlashCommand.typedName("hello") == nil)
        let merged = SlashCommand.merged([[SlashCommand("model", "Mine", source: .personal)], SlashCommand.builtIns])
        #expect(merged.filter { $0.name == "model" }.count == 1)
        #expect(merged.first { $0.name == "model" }?.source == .personal)
    }
}

@Suite struct StandAloneRowTests {
    @Test func imageTagsLeaveTheWords() {
        #expect(Transcript.withoutImageTags("[Image #1] [Image #2]What colors?") == "What colors?")
        #expect(Transcript.withoutImageTags("See [Image #3] here") == "See here")
        #expect(Transcript.withoutImageTags("[Image #1]") == "")
        // Sent by another program through `hc send`.
        let sent = Transcript.sentWithHC(#"<hc from="my-mac/ppid:15337">Reply with one word: ok</hc>"#)
        #expect(sent?.words == "Reply with one word: ok")
        #expect(sent?.sender == "a program on my-mac")
        #expect(Transcript.sentWithHC("<hc from=\"t3\">Two\nlines</hc>")?.sender == "t3")
        #expect(Transcript.sentWithHC("<hc from=\"t3\">Two\nlines</hc>")?.words == "Two\nlines")
        #expect(Transcript.sentWithHC("Plain words") == nil)
        // OpenCode's, without the #.
        #expect(Transcript.withoutImageTags("[Image 1] What color is this square?") == "What color is this square?")
    }

    @Test func questionsAndPlansAreRowsOfTheirOwn() {
        func line(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
        let asked = line(["type": "assistant", "uuid": "a1", "message": ["model": "claude-opus-5-5", "content": [
            ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/a"]],
            ["type": "tool_use", "id": "t2", "name": "AskUserQuestion", "input": ["questions": []]],
            ["type": "tool_use", "id": "t3", "name": "Bash", "input": ["command": "ls"]],
        ]]])
        // Waiting for its answer, the question shows in its card only.
        #expect(Transcript.parse([asked]).rows.count == 1)
        let answered = line(["type": "user", "uuid": "u2", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t2", "content": "User has answered your questions: \"Q\"=\"A\""],
        ]]])
        let t = Transcript.parse([asked, answered])
        #expect(t.rows.count == 3)
        if case .item(let item) = t.rows[1], case .tool(let call) = item.kind { #expect(call.name == "AskUserQuestion") } else { Issue.record("not alone") }
    }
}

@Suite struct CodexTranscriptTests {
    /// As Codex writes them: the record's type before its payload.
    private func line(_ type: String, _ payload: [String: Any], ordinal: Int) -> Data {
        let body = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        return Data("{\"timestamp\":\"2026-11-12T05:52:18.000Z\",\"ordinal\":\(ordinal),\"type\":\"\(type)\",\"payload\":\(body)}".utf8)
    }

    private func item(_ item: [String: Any], ordinal: Int) -> Data {
        line("event_msg", ["type": "item_completed", "thread_id": "th", "turn_id": "t1", "item": item, "started_at_ms": 1_794_462_738_000], ordinal: ordinal)
    }

    /// A function call as Codex writes it: its name before its arguments.
    private func call(_ name: String, _ arguments: String, id: String, ordinal: Int) -> Data {
        let quoted = String(decoding: try! JSONEncoder().encode(arguments), as: UTF8.self)
        let body = "{\"type\":\"function_call\",\"name\":\"\(name)\",\"arguments\":\(quoted),\"call_id\":\"\(id)\"}"
        return Data("{\"timestamp\":\"2026-11-12T05:52:18.000Z\",\"ordinal\":\(ordinal),\"type\":\"response_item\",\"payload\":\(body)}".utf8)
    }

    @Test func turnReadAsItems() {
        let lines = [
            line("session_meta", ["id": "th", "cwd": "/tmp/p", "cli_version": "0.167.2", "context_window": 258_400, "base_instructions": ["text": "…"]], ordinal: 0),
            line("turn_context", [
                "turn_id": "t1", "cwd": "/tmp/p", "model": "gpt-6-luna", "effort": "low",
                "approval_policy": ["granular": ["sandbox_approval": false]],
                "sandbox_policy": ["type": "workspace-write", "network_access": false],
                "collaboration_mode": ["mode": "default", "settings": ["reasoning_effort": "low"]],
            ], ordinal: 1),
            line("event_msg", ["type": "task_started", "turn_id": "t1", "model_context_window": 258_400], ordinal: 2),
            line("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "# AGENTS.md instructions"]]], ordinal: 3),
            item(["type": "UserMessage", "id": "u1", "content": [["type": "text", "text": "List the files", "text_elements": []]]], ordinal: 4),
            item(["type": "Reasoning", "id": "r1", "summary_text": [], "raw_content": []], ordinal: 5),
            item(["type": "AgentMessage", "id": "a1", "content": [["type": "Text", "text": "Looking."]], "phase": "commentary"], ordinal: 6),
            item(["type": "CommandExecution", "id": "c1", "command": ["/bin/zsh", "-lc", "ls -la"], "cwd": "file:///tmp/p", "status": "completed",
                  "aggregated_output": "a.txt\nb.txt\n", "exit_code": 0], ordinal: 7),
            item(["type": "CommandExecution", "id": "c2", "command": ["/bin/zsh", "-lc", "false"], "status": "failed", "aggregated_output": "", "exit_code": 1], ordinal: 8),
            item(["type": "CommandExecution", "id": "c3", "command": ["/bin/zsh", "-lc", "ls"], "source": "user_shell", "status": "completed",
                  "aggregated_output": "a.txt\n", "exit_code": 0], ordinal: 80),
            item(["type": "FileChange", "id": "f1", "status": "completed", "changes": [
                "/tmp/p/a.txt": ["type": "update", "unified_diff": "@@ -1 +1 @@\n-old\n+new\n"],
                "/tmp/p/c.txt": ["type": "add", "content": "hello\n"],
            ]], ordinal: 9),
            item(["type": "McpToolCall", "id": "m1", "server": "docs", "tool": "search", "arguments": ["query": "swift"], "status": "completed",
                  "result": ["content": [["type": "text", "text": "3 pages"]]]], ordinal: 10),
            line("event_msg", ["type": "token_count", "info": ["last_token_usage": ["total_tokens": 30000], "model_context_window": 258_400]], ordinal: 11),
            item(["type": "AgentMessage", "id": "a2", "content": [["type": "Text", "text": "Two files."]], "phase": "final_answer"], ordinal: 12),
            line("event_msg", ["type": "task_complete", "turn_id": "t1", "duration_ms": 5216, "last_agent_message": "Two files."], ordinal: 13),
            line("event_msg", ["type": "turn_aborted", "turn_id": "t2", "reason": "interrupted", "duration_ms": 1174], ordinal: 14),
            line("event_msg", ["type": "task_complete", "turn_id": "t3", "error": ["message": "Usage limit reached."]], ordinal: 15),
        ]
        let t = Transcript.parse(lines, format: .codex)
        let kinds = t.items.map { item -> String in
            switch item.kind {
            case .prompt(let text, _): "prompt:\(text)"
            case .text(let text): "text:\(text)"
            case .thinking: "thinking"
            case .tool(let call): "tool:\(call.name):\(call.summary)"
            case .notice(let n): "notice:\(n)"
            case .command(let c, _): "command:\(c)"
            }
        }
        #expect(kinds == [
            "prompt:List the files", "text:Looking.", "tool:Shell:ls -la", "tool:Shell:false", "command:! ls",
            "tool:Edit:/tmp/p/a.txt", "tool:Write:/tmp/p/c.txt", "tool:mcp__docs__search:swift", "text:Two files.",
            "notice:turnEnded(milliseconds: 5216)", "notice:interrupted", "notice:error(\"Usage limit reached.\")",
        ])
        guard case .tool(let ls) = t.items[2].kind, case .tool(let failed) = t.items[3].kind, case .tool(let edit) = t.items[5].kind else {
            Issue.record("no tools")
            return
        }
        #expect(ls.result?.text == "a.txt\nb.txt")
        #expect(ls.result?.isError == false)
        #expect(ls.input["cwd"]?.string == "/tmp/p")
        #expect(failed.result?.isError == true)
        if case .command(_, let output) = t.items[4].kind { #expect(output == "a.txt") } else { Issue.record("no ! command") }
        #expect(edit.input["diff"]?.string?.contains("+new") == true)
        #expect(t.facts.model == "gpt-6-luna")
        #expect(t.facts.effort == "low")
        #expect(t.facts.permissionMode == "granular")
        #expect(t.facts.sandbox == "workspace-write")
        #expect(t.facts.collaborationMode == "default")
        #expect(t.facts.contextTokens == 30000)
        #expect(t.facts.contextWindow == 258_400)
        #expect(t.facts.version == "0.167.2")
        #expect(t.facts.lastPromptAt != nil)
        // Older lines in front keep the format.
        var later = Transcript.parse(Array(lines[12...]), format: .codex)
        later.prepend(Array(lines[..<12]))
        #expect(later.items.count == t.items.count)
    }

    /// Plan mode's questions are only in what the model saw: the call, then
    /// its output with the answers by question id.
    @Test func questionsAndAnswers() {
        let args = #"{"questions":[{"id":"color","header":"Color","question":"Which color should the button be?","options":[{"label":"Blue","description":"The usual one"},{"label":"Red","description":"Louder"}]},{"id":"size","header":"Size","question":"How big?","options":[{"label":"Small","description":"a"}]}]}"#
        let answers = #"{"answers":{"color":{"answers":["Blue"]},"size":{"answers":["None of the above","user_note: medium, please"]}}}"#
        let lines = [
            item(["type": "UserMessage", "id": "u1", "content": [["type": "text", "text": "ask me"]]], ordinal: 1),
            call("request_user_input", args, id: "call_9", ordinal: 2),
            call("exec_command", #"{"cmd":"ls"}"#, id: "call_8", ordinal: 3),
            line("response_item", ["type": "function_call_output", "call_id": "call_8", "output": "a.txt"], ordinal: 4),
            line("response_item", ["type": "function_call_output", "call_id": "call_9", "output": answers], ordinal: 5),
        ]
        let t = Transcript.parse(lines, format: .codex)
        #expect(t.items.count == 2)
        guard case .tool(let ask) = t.items.last?.kind else {
            Issue.record("no question")
            return
        }
        #expect(ask.name == "AskUserQuestion")
        #expect(AskQuestion.list(ask.input).map(\.question) == ["Which color should the button be?", "How big?"])
        #expect(ask.result?.answers == [
            ToolResult.Answer(question: "Which color should the button be?", answer: "Blue"),
            ToolResult.Answer(question: "How big?", answer: "None of the above — medium, please"),
        ])
    }

    @Test func commandsAndPaths() {
        #expect(Transcript.codexCommand(["/bin/zsh", "-lc", "git status"]) == "git status")
        #expect(Transcript.codexCommand(["rg", "-n", "a b"]) == "rg -n 'a b'")
        #expect(Transcript.localPath("file:///Users/me/My%20Folder") == "/Users/me/My Folder")
        #expect(Transcript.localPath("/tmp/x") == "/tmp/x")
    }

    /// Codex 0.167's screen at rest, its pet's dots over it.
    /// Lines a card leaves out: keys for the terminal, Codex's question
    /// count, and the parts of its status line the chips already show.
    @Test func codexCardTrims() {
        #expect(ScreenPrompt.isKeyHint("tab to add notes | enter to submit answer | esc to interrupt"))
        #expect(ScreenPrompt.isKeyHint("tab or esc to clear notes | enter to submit answer"))
        #expect(ScreenPrompt.isKeyHint("Esc to cancel · Tab to amend"))
        #expect(ScreenPrompt.isKeyHint("Press enter to confirm or esc to go back"))
        #expect(ScreenPrompt.isKeyHint("↑↓ select  enter submit  esc dismiss"))
        #expect(!ScreenPrompt.isKeyHint("This undoes 3 file changes"))
        #expect(!ScreenPrompt.isKeyHint(""))
        let count = ScreenPrompt.codexQuestionCount("  Question 1/2 (2 unanswered)")
        #expect(count?.index == 1 && count?.total == 2)
        #expect(ScreenPrompt.codexQuestionCount("Question 2/2")?.index == 2)
        #expect(ScreenPrompt.codexQuestionCount("Which color should the button be?") == nil)
        #expect(ScreenPrompt.withoutKeyHint("Optionally, add details in notes (tab)") == "Optionally, add details in notes")
        let line = "fake-1 medium · /private/tmp/cxwork                                             Plan mode (⇧tab to cycle)"
        #expect(CodexScreen.statusExtras([line], model: "fake-1").isEmpty)
        #expect(CodexScreen.statusExtras(["gpt-6-luna low · Context 100% left · ~/p · main · 5h 80% left"], model: "gpt-6-luna") == ["main · 5h 80% left"])
    }

    @Test func codexFooter() {
        let screen = """
        ⠁   ⠈         ⠄          ⢀
        ›⠁Ask Codex to do anything   ⠈       ⠂  ⠁
                ⠐        ⠄
          gpt-6-astra low · Context 100% left · monthly 0% left
          ← for agents · ? for shortcuts                                ⚠ 1 warning · f2 to view
        """
        let f = ClaudeFooter.parseCodex(screen: screen)
        #expect(f?.statusLine == ["gpt-6-astra low · Context 100% left · monthly 0% left"])
        #expect(f?.mode == nil)
        #expect(f?.model == "gpt-6-astra")
        #expect(f?.effort == "low")
        // A new chat: the model and effort only the screen tells.
        let fresh = ClaudeFooter.parseCodex(screen: "› Ask Codex to do anything\n  fake-1 low · /private/tmp/x\n  ← for agents · ? for shortcuts")
        #expect(fresh?.model == "fake-1")
        #expect(fresh?.effort == "low")
        #expect(CodexScreen.model(statusLine: ["~/p · main"]) == nil)
        #expect(CodexScreen.model(statusLine: ["main · ~/p"]) == nil)
        #expect(CodexScreen.model(statusLine: ["o3   ~/p"])?.model == "o3")
        #expect(CodexScreen.model(statusLine: []) == nil)
    }

    /// Codex's menus: `›` on the chosen line, a description in a second column.
    @Test func codexMenu() {
        let screen = """
        ■ The 'gpt-6-astra' model is not supported when using Codex with a ChatGPT account.

          Approaching rate limits
          Switch to gpt-6-luna for lower credit usage?

        › 1. Switch to gpt-6-luna                   Fast and affordable model for easier tasks.
          2. Keep current model
          3. Keep current model (never show again)  Hide future rate limit reminders about switching models

          enter select · esc back
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.options.map(\.label) == ["Switch to gpt-6-luna", "Keep current model", "Keep current model (never show again)"])
        #expect(p?.options.first?.detail == "Fast and affordable model for easier tasks.")
        #expect(p?.options.last?.detail == "Hide future rate limit reminders about switching models")
        #expect(p?.options.first?.focused == true)
        #expect(p?.footer == "enter select · esc back")
        #expect(p?.questionText.contains("Switch to gpt-6-luna for lower credit usage?") == true)
        #expect(ClaudeFooter.parseCodex(screen: screen) == nil)
    }

    @Test func codexCommandsFound() {
        #expect(SlashCommand.matching("perm", in: SlashCommand.codexBuiltIns).first?.name == "permissions")
        #expect(SlashCommand.matching("exit", in: SlashCommand.codexBuiltIns).first?.name == "quit")
    }

    /// Codex asking before it runs a command: a numbered list under the question.
    @Test func codexApproval() {
        let screen = """
        • I'll clean the build folder first.

          Would you like to run the following command?

          $ rm -rf build

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for this command in this session (a)
          3. No, and tell Codex what to do differently (esc)

          enter to confirm · esc to cancel
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.options.map(\.label) == [
            "Yes, proceed (y)", "Yes, and don't ask again for this command in this session (a)", "No, and tell Codex what to do differently (esc)",
        ])
        #expect(p?.options.first?.focused == true)
        #expect(p?.questionText.contains("Would you like to run the following command?") == true)
        #expect(p?.questionText.contains("$ rm -rf build") == true)
        #expect(ClaudeFooter.parseCodex(screen: screen) == nil)
    }

    /// `/status` prints on Codex's screen only: the lines under its echo.
    @Test func codexCommandOutput() {
        let screen = """
          >_ OpenAI Codex (v0.167.2)

          To get started, describe a task or try one of these commands:

          /init - create an AGENTS.md file with instructions for Codex
          /status - show current session configuration

        › Reply with the single word: ready


        ■ The 'gpt-6-astra' model is not supported when using Codex with a ChatGPT account.

        /status

          >_ OpenAI Codex (v0.167.2)

          Model:               gpt-6-astra (reasoning low, summaries auto)
          Permissions:         Workspace (granular)   \u{2801}
          Monthly limit:       [░░░░░░░░░░░░░░░░░░░░] 0% left (resets 3:50 PM on 16 Nov)



        › Ask Codex to do anything \u{2808}   \u{2802}

          gpt-6-astra low · Context 100% left · monthly 0% left
          ← for agents · ? for shortcuts
        """
        #expect(CodexScreen.output(of: "/status", screen: screen) == """
        >_ OpenAI Codex (v0.167.2)

        Model:               gpt-6-astra (reasoning low, summaries auto)
        Permissions:         Workspace (granular)
        Monthly limit:       [░░░░░░░░░░░░░░░░░░░░] 0% left (resets 3:50 PM on 16 Nov)
        """)
        // Not run yet: only the list Codex shows on start names it.
        #expect(CodexScreen.output(of: "/init", screen: screen) == nil)
        // Another command sent since: each gets its own lines.
        let two = """
        /status

          Model:  gpt-6-astra

        /pwd

          Current working directory: /tmp/p

        › Ask Codex to do anything
        """
        #expect(CodexScreen.output(of: "/status", screen: two) == "Model:  gpt-6-astra")
        #expect(CodexScreen.output(of: "/pwd", screen: two) == "Current working directory: /tmp/p")
        #expect(CodexScreen.prints("/status"))
        #expect(CodexScreen.prints("/diff"))
        #expect(!CodexScreen.prints("/model"))
        #expect(!CodexScreen.prints("/review look at main"))
        #expect(!CodexScreen.prints("hello"))
    }
}

@Suite struct TimeMarkTests {
    private func row(_ id: String, _ time: Double?) -> TranscriptRow {
        .item(TranscriptItem(id: id, kind: .text(id), time: time))
    }

    @Test func marks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        // 2026-11-11 22:00 Toronto = 2026-11-12 03:00 UTC.
        let evening = 1_794_452_400.0
        let rows = [
            row("a", evening),
            row("b", evening + 60),
            row("c", nil),
            row("d", evening + 60 + 31 * 60),  // half an hour later
            row("e", evening + 2 * 3600 + 60),  // past midnight, 30 min after d
            row("f", evening + 2 * 3600 + 120),
            .activity(id: "g", items: [TranscriptItem(id: "g1", kind: .text("x"), time: evening + 3 * 3600)]),
        ]
        let marks = TranscriptRow.timeMarks(rows, calendar: calendar)
        #expect(marks == ["a", "d", "e", "g"])
        #expect(TranscriptRow.timeMarks([row("x", nil)], calendar: calendar).isEmpty)
    }
}

@Suite struct TurnPieceTests {
    private func item(_ id: String, _ kind: TranscriptItem.Kind, _ time: Double?) -> TranscriptRow {
        .item(TranscriptItem(id: id, kind: kind, time: time))
    }

    private func steps(_ id: String, _ time: Double?) -> TranscriptRow {
        let call = ToolCall(id: id + "c", name: "Bash", input: .object(["command": .string("ls")]), result: ToolResult(text: "a"))
        return .activity(id: id, items: [TranscriptItem(id: id + "c", kind: .tool(call), time: time)])
    }

    private func question(_ id: String, _ time: Double?) -> TranscriptRow {
        var call = ToolCall(id: id, name: "AskUserQuestion", input: .object([:]))
        call.result = ToolResult(text: "answered")
        return item(id, .tool(call), time)
    }

    @Test func finishedTurnFolds() {
        let rows = [
            item("p", .prompt("Fix it", images: 0), 100),
            steps("s1", 101),
            item("t1", .text("Looking at the sidebar first."), 105),
            steps("s2", 106),
            item("t2", .text("Fixed."), 150),
            item("e", .notice(.turnEnded(milliseconds: 51_000)), 151),
        ]
        let pieces = TranscriptRow.pieces(rows, openEnd: false)
        #expect(pieces == [.row(rows[0]), .turn(TurnFold(rows: Array(rows[1 ... 3]), answer: rows[4], milliseconds: 51_000))])
        // While the agent is on it, the turn stays open until it ends.
        let going = Array(rows.dropLast())
        #expect(TranscriptRow.pieces(going, openEnd: true) == going.map(TurnPiece.row))
        // Ended: the agent at work again is on another turn.
        #expect(TranscriptRow.pieces(rows, openEnd: true) == pieces)
    }

    @Test func anotherSessionsMessageStartsATurnOfItsOwn() {
        let rows = [
            item("p", .prompt("Add glass", images: 0), 100),
            steps("s1", 101),
            item("t1", .text("Done, and installed."), 900),
            item("e1", .notice(.turnEnded(milliseconds: 800_000)), 901),
            item("m", .notice(.message(from: "Focus fix", text: "I committed my line.")), 1000),
            steps("s2", 1001),
            item("t2", .text("Noted: only my edits are left."), 1007),
            item("e2", .notice(.turnEnded(milliseconds: 7_000)), 1008),
        ]
        // The first answer stays in sight, under its own time; the message shows.
        #expect(TranscriptRow.pieces(rows, openEnd: false) == [
            .row(rows[0]),
            .turn(TurnFold(rows: [rows[1]], answer: rows[2], milliseconds: 800_000)),
            .row(rows[4]),
            .turn(TurnFold(rows: [rows[5]], answer: rows[6], milliseconds: 7_000)),
        ])
        // While the agent answers the message, that turn stays open.
        let going = Array(rows[0 ... 5])
        #expect(TranscriptRow.pieces(going, openEnd: true) == [
            .row(rows[0]),
            .turn(TurnFold(rows: [rows[1]], answer: rows[2], milliseconds: 800_000)),
            .row(rows[4]), .row(rows[5]),
        ])
    }

    @Test func picturesTheToolsShowedGoOverTheAnswer() {
        func read(_ id: String, _ files: [String]) -> TranscriptItem {
            var result = ToolResult(text: "", images: files.count)
            result.pictures = files.map { TranscriptImage(url: URL(filePath: "/tmp/\($0)")) }
            let call = ToolCall(id: id, name: "Read", input: .object(["file_path": .string("/tmp/\(files.first ?? "")")]), result: result)
            return TranscriptItem(id: id, kind: .tool(call), time: 2)
        }
        let rows: [TranscriptRow] = [
            .activity(id: "s1", items: [read("r1", ["a.png"]), read("r2", ["b.png", "a.png"])]),
            .item(read("r3", ["c.png"])),
            item("t1", .text("Looking."), 3),
        ]
        let fold = TurnFold(rows: rows, answer: item("t2", .text("Here."), 4), milliseconds: nil)
        #expect(fold.pictures.map(\.url.lastPathComponent) == ["a.png", "b.png", "c.png"])
        #expect(TurnFold(rows: [steps("s", 1)], answer: rows[2], milliseconds: nil).pictures.isEmpty)
    }

    @Test func turnsWithoutAnAnswerStayOpen() {
        let stopped = [item("p", .prompt("Go", images: 0), 1), steps("s", 2), item("i", .notice(.interrupted), 3)]
        #expect(TranscriptRow.pieces(stopped, openEnd: false) == stopped.map(TurnPiece.row))
        // The start of the conversation, before its first message, isn't folded.
        let cut = [steps("s", 2), item("t", .text("Done."), 3)]
        #expect(TranscriptRow.pieces(cut, openEnd: false) == cut.map(TurnPiece.row))
    }

    @Test func answeredQuestionStartsTheWorkAfterIt() {
        let rows = [
            item("p", .prompt("Add a test", images: 0), 100),
            steps("s1", 101),
            question("q", 102),
            steps("s2", 400),
            item("t", .text("Added."), 430),
            item("g", .notice(.info("note")), 431),
            item("e", .notice(.turnEnded(milliseconds: 331_000)), 432),
        ]
        // Not the turn's time: the person took a while to answer.
        #expect(TranscriptRow.pieces(rows, openEnd: false) == [
            .row(rows[0]), .row(rows[1]), .row(rows[2]),
            .turn(TurnFold(rows: [rows[3]], answer: rows[4], milliseconds: 30_000)),
            .row(rows[5]),
        ])
    }

    @Test func quickAnswerKeepsItsTime() {
        let rows = [item("p", .prompt("Hi", images: 0), nil), item("t", .text("Hello."), nil), item("e", .notice(.turnEnded(milliseconds: 2_000)), nil)]
        #expect(TranscriptRow.pieces(rows, openEnd: false) == [.row(rows[0]), .turn(TurnFold(rows: [], answer: rows[1], milliseconds: 2_000))])
    }
}

@Suite struct FindTests {
    @Test func rowsHoldWords() {
        let prompt = TranscriptRow.item(TranscriptItem(id: "p", kind: .prompt("Fix the Café menu", images: 0)))
        let text = TranscriptRow.item(TranscriptItem(id: "t", kind: .text("Done: the **menu** opens.")))
        let call = ToolCall(id: "c", name: "Bash", input: JSON.object(["command": .string("swift test --filter Menu")]),
                            result: ToolResult(text: "Test run with 12 tests passed", isError: false))
        let tools = TranscriptRow.activity(id: "a", items: [TranscriptItem(id: "c", kind: .tool(call))])
        #expect(prompt.contains("cafe"))
        #expect(prompt.contains("MENU"))
        #expect(text.contains("menu"))
        #expect(tools.contains("--filter"))
        #expect(tools.contains("12 tests"))
        #expect(!tools.contains("cafe"))
        #expect(!prompt.contains(""))
    }
}
