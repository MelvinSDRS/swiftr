import Foundation
import Testing
@testable import HerdrKit

/// A Codex session file's line, compact as Codex writes it.
private func line(_ ordinal: Int, _ type: String, _ payload: [String: Any], at time: String = "2026-11-12T14:51:39.243Z") -> String {
    let body = try! JSONSerialization.data(withJSONObject: ["type": type, "payload": payload], options: [.sortedKeys])
    // `timestamp` and `ordinal` first, as in Codex's files.
    return "{\"timestamp\":\"\(time)\",\"ordinal\":\(ordinal)," + String(decoding: body.dropFirst(), as: UTF8.self)
}

private func meta(_ ordinal: Int, base: [String: Any]? = nil) -> String {
    var p: [String: Any] = ["id": "01a1d03c-59fc-7030-ab7c-80bfc4897063", "cwd": "/tmp/x", "cli_version": "0.167.2"]
    if let base { p["history_base"] = base }
    return line(ordinal, "session_meta", p)
}

private func prompt(_ ordinal: Int, _ text: String) -> String {
    line(ordinal, "event_msg", ["type": "item_completed", "item": ["type": "UserMessage", "id": "u\(ordinal)", "content": [["type": "text", "text": text]]]])
}

/// Writes the lines as a file in a folder of its own; returns its URL.
private func file(_ lines: [String], in dir: URL, name: String) throws -> URL {
    let url = dir.appending(path: name)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func texts(_ data: [Data]) -> [String] {
    data.map { String(decoding: $0, as: UTF8.self) }
}

@Suite struct CodexChainTests {
    @Test func baseReadFromTheFirstLine() {
        let first = meta(14, base: ["thread_id": "01a1d03e-316b-70b0-9ffc-214ea3a2770a", "end_ordinal_exclusive": 14, "end_byte_offset": 116_185])
        let base = CodexHistoryBase.parse(Data(first.utf8))
        #expect(base == CodexHistoryBase(part: "01a1d03e-316b-70b0-9ffc-214ea3a2770a", endOrdinal: 14, endByte: 116_185))
        #expect(CodexHistoryBase.parse(Data(meta(0).utf8)) == nil)
        #expect(CodexHistoryBase.parse(Data(prompt(3, "history_base").utf8)) == nil)
        #expect(CodexHistoryBase.ordinal(of: Data(first.utf8)) == 14)
    }

    /// Back to the second message: the new file names the first, cut
    /// before that message; the conversation reads as one.
    @Test func chainReadsTheKeptPartFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "codexchain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = [meta(0), prompt(1, "first"), prompt(2, "second"), prompt(3, "third")]
        let oldURL = try file(old, in: dir, name: "rollout-a-T.jsonl")
        let cut = (old[0] + "\n" + old[1] + "\n").utf8.count
        let new = [meta(2, base: ["thread_id": "T", "end_ordinal_exclusive": 2, "end_byte_offset": cut]), prompt(3, "second, again")]
        let newURL = try file(new, in: dir, name: "rollout-b-T_P.jsonl")
        let opened = OpenedParts()
        let chain = CodexChain(current: TranscriptFile(url: newURL)) { base in
            await opened.add(base.part)
            return base.part == "T" ? TranscriptFile(url: oldURL, end: UInt64(base.endByte ?? 0)) : nil
        }
        let all = try await chain.openTail(lines: 100, maxBytes: 1 << 20)
        #expect(texts(all) == [old[0], old[1]] + new)
        #expect(await chain.atStart)
        #expect(await opened.parts == ["T"])
        // New lines come from the newest file.
        #expect(try await chain.readNew() == [])
    }

    /// A short tail stays in the newest file; reading further back goes
    /// on into the file before it.
    @Test func earlierLinesComeFromTheFileBefore() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "codexchain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = [meta(0), prompt(1, "one"), prompt(2, "two"), prompt(3, "three"), prompt(4, "four")]
        let oldURL = try file(old, in: dir, name: "rollout-a-T.jsonl")
        let cut = old.prefix(4).map { $0 + "\n" }.joined().utf8.count
        let new = [meta(4, base: ["thread_id": "T", "end_ordinal_exclusive": 4, "end_byte_offset": cut]), prompt(5, "four, again"), prompt(6, "five")]
        let newURL = try file(new, in: dir, name: "rollout-b-T_P.jsonl")
        let chain = CodexChain(current: TranscriptFile(url: newURL)) { base in
            TranscriptFile(url: oldURL, end: UInt64(base.endByte ?? 0))
        }
        #expect(texts(try await chain.openTail(lines: 2, maxBytes: 1 << 20)) == [new[1], new[2]])
        #expect(await !chain.atStart)
        #expect(texts(try await chain.readEarlier(lines: 2, maxBytes: 1 << 20)) == [new[0]])
        #expect(await !chain.atStart)
        #expect(texts(try await chain.readEarlier(lines: 2, maxBytes: 1 << 20)) == [old[2], old[3]])
        #expect(texts(try await chain.readEarlier(lines: 5, maxBytes: 1 << 20)) == [old[0], old[1]])
        #expect(await chain.atStart)
        #expect(try await chain.readEarlier(lines: 5, maxBytes: 1 << 20).isEmpty)
    }

    /// The file before can't be found: what the newest holds still shows.
    @Test func missingBaseEndsTheChain() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "codexchain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let new = [meta(4, base: ["thread_id": "gone", "end_ordinal_exclusive": 4, "end_byte_offset": 10]), prompt(5, "hi")]
        let newURL = try file(new, in: dir, name: "rollout-b-T_P.jsonl")
        let chain = CodexChain(current: TranscriptFile(url: newURL)) { _ in nil }
        #expect(texts(try await chain.openTail(lines: 10, maxBytes: 1 << 20)) == new)
        #expect(await chain.atStart)
    }

    /// A `!` command reaches the file only when it ends: the working line
    /// counts from the turn's start, not from the message before.
    @Test func turnStartIsWhereWorkCounts() {
        let started = line(2, "event_msg", ["type": "task_started", "turn_id": "t2", "model_context_window": 258_400], at: "2026-11-12T15:15:28.288Z")
        let t = Transcript.parse([meta(0), prompt(1, "first"), started].map { Data($0.utf8) }, format: .codex)
        #expect(t.facts.lastPromptAt == 1_794_496_528.288)
        #expect(t.facts.contextWindow == 258_400)
        #expect(t.items.count == 1)
    }

    /// What Codex does while it works shows only on its screen.
    @Test func codexActivity() {
        let running = """
        › !sleep 30

        • Running sleep 30

        • Working (7s • esc to interrupt)

        › queued hello

          gpt-6-astra high · monthly 0% left
          tab to queue message
        """
        #expect(ClaudeFooter.parseCodex(screen: running)?.activity == "Running sleep 30")
        let output = running.replacingOccurrences(of: "• Running sleep 30\n", with: "• Running ls -la\n  └ a.txt\n    b.txt\n")
        #expect(ClaudeFooter.parseCodex(screen: output)?.activity == "Running ls -la")
        // A command done reads `Ran`: the step named shows instead.
        let step = """
        • Ran ls
          └ a.txt

        • Reading the tests (12s • esc to interrupt)

        • Queued follow-up inputs
          ↳ then lint
            ⇧← edit last queued message

        › Ask Codex to do anything

          gpt-6-astra high · monthly 0% left
          ← for agents · ? for shortcuts
        """
        #expect(ClaudeFooter.parseCodex(screen: step)?.activity == "Reading the tests")
        let idle = """
          Worked for 30s • 10:13 AM

        › Ask Codex to do anything

          gpt-6-astra high · monthly 0% left
          ← for agents · ? for shortcuts
        """
        #expect(ClaudeFooter.parseCodex(screen: idle)?.activity == nil)
        let working = idle.replacingOccurrences(of: "  Worked for 30s • 10:13 AM", with: "• Working (2s • esc to interrupt)")
        #expect(ClaudeFooter.parseCodex(screen: working)?.activity == nil)
    }

    /// ⌥. on a model without levels: Codex says so over its input only.
    @Test func codexKeyReply() {
        let before = """
          Worked for 12s • 10:18 AM

        › Ask Codex to do anything

          gpt-6-astra high · monthly 0% left
          ← for agents · ? for shortcuts
        """
        let after = """
          Worked for 12s • 10:18 AM

        • Reasoning shortcuts are unavailable for gpt-6-astra.

        › Ask Codex to do anything

          gpt-6-astra high · monthly 0% left
          ← for agents · ? for shortcuts
        """
        #expect(CodexScreen.keyReply(before: before, after: after) == "Reasoning shortcuts are unavailable for gpt-6-astra.")
        // Pressed again: one more of the same line.
        #expect(CodexScreen.keyReply(before: after, after: after) == nil)
        let twice = after.replacingOccurrences(of: "› Ask", with: "• Reasoning shortcuts are unavailable for gpt-6-astra.\n\n› Ask")
        #expect(CodexScreen.keyReply(before: after, after: twice) == "Reasoning shortcuts are unavailable for gpt-6-astra.")
        // The turn's own lines aren't a reply.
        let working = before.replacingOccurrences(of: "› Ask", with: "• Working (8s • esc to interrupt)\n\n› Ask")
        #expect(CodexScreen.keyReply(before: before, after: working) == nil)
        // Lines under it come with it.
        let long = before.replacingOccurrences(of: "› Ask", with: "• Effort set\n  └ high for this chat\n\n› Ask")
        #expect(CodexScreen.keyReply(before: before, after: long) == "Effort set\n└ high for this chat")
    }

    /// ⌥T on Haiku: Claude Code says so right-aligned over its input box.
    @Test func claudeKeyReply() {
        let rule = String(repeating: "─", count: 60)
        func screen(_ note: String) -> String {
            "\n" + String(repeating: " ", count: 40) + note + "\n" + rule + "\n❯ Try \"how does <filepath> work?\"\n" + rule + "\n  ⏸ manual mode on · ? for shortcuts"
        }
        let before = screen("◐ medium · /effort")
        let after = screen("Thinking can't be turned off for Haiku 5.5")
        #expect(ClaudeFooter.keyReply(before: before, after: after) == "Thinking can't be turned off for Haiku 5.5")
        #expect(ClaudeFooter.keyReply(before: after, after: after) == nil)
        #expect(ClaudeFooter.keyReply(before: after, after: before) == nil)
        // Claude's own last line, against the left edge, isn't a note.
        let text = "\nDone.\n" + rule + "\n❯ \n" + rule + "\n  ? for shortcuts"
        #expect(ClaudeFooter.keyReply(before: before, after: text) == nil)
    }

    /// Codex browsing its transcript to go back (Esc Esc), and the
    /// messages it holds for the turn's end (Tab).
    @Test func codexBrowsingAndQueue() {
        let browsing = """
        › first test message, reply ok
        ■ The 'gpt-6-astra' model is not supported when using Codex with a ChatGPT account.

        › Ask Codex to do anything

          gpt-6-astra high · monthly 0% left
          Browsing transcript · ↑↓/jk scroll · ←→/hl prompts · ⌃t details · ↵ rewind · esc back
        """
        let b = ClaudeFooter.parseCodex(screen: browsing)
        #expect(b?.browsing == true)
        #expect(b?.statusLine == ["gpt-6-astra high · monthly 0% left"])
        #expect(b?.shown == "Ask Codex to do anything")
        #expect(b?.input == "")

        let queued = """
        • Running sleep 25

        • Working (8s • esc to interrupt)

        • Queued follow-up inputs
          ↳ queued hello
          ↳ run the tests
            and the linter
            ⇧← edit last queued message

        › Ask Codex to do anything

          gpt-6-astra high · monthly 0% left
          esc again to edit previous message
        """
        let q = ClaudeFooter.parseCodex(screen: queued)
        #expect(q?.queued == ["queued hello", "run the tests\nand the linter"])
        #expect(q?.browsing == false)
        #expect(q?.statusLine == ["gpt-6-astra high · monthly 0% left"])

        // A list further up, with the conversation after it, is old text.
        let old = """
        • Queued follow-up inputs
          ↳ queued hello
        › queued hello
        ■ The 'gpt-6-astra' model is not supported when using Codex with a ChatGPT account.

        › steer now

          gpt-6-astra high · monthly 0% left
        """
        let o = ClaudeFooter.parseCodex(screen: old)
        #expect(o?.queued == [])
        #expect(o?.shown == "steer now")
        // No `? for shortcuts` under it: typed, not Codex's hint.
        #expect(o?.input == "steer now")
        #expect(q?.input == "")

        // Codex shows three lines of a message, then `…`: the list says it's cut.
        let cut = """
        • Working (3s • esc to interrupt)

        • Queued follow-up inputs
          ↳ one
            two
            three
            …
            ⇧← edit last queued message

        › Ask Codex to do anything

          ← for agents · ? for shortcuts
        """
        #expect(ClaudeFooter.parseCodex(screen: cut)?.queued == ["one\ntwo\nthree\n…"])
    }
}

private actor OpenedParts {
    var parts: [String] = []
    func add(_ part: String) { parts.append(part) }
}
