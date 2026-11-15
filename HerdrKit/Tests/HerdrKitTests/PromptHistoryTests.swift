import Foundation
import Testing
@testable import HerdrKit

@Suite struct PromptHistoryTests {
    private func lines(_ objects: [[String: Any]], endsWithBreak: Bool = true) -> Data {
        let text = objects.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        return Data((text + (endsWithBreak ? "\n" : "")).utf8)
    }

    @Test func claudeKeepsOneFolder() {
        let data = lines([
            ["display": "older", "project": "/p", "pastedContents": [:]],
            ["display": "elsewhere", "project": "/q", "pastedContents": [:]],
            ["display": "Run [Pasted text #1 +2 lines]", "project": "/p", "pastedContents": ["1": ["type": "text", "content": "a\nb\nc"]]],
        ])
        #expect(PromptHistory.entries(data, project: "/p") == ["Run a\nb\nc", "older"])
    }

    @Test func codexNewestFirstEachOnce() {
        let data = lines([
            ["session_id": "s1", "ts": 1, "text": "fix the build"],
            ["session_id": "s1", "ts": 2, "text": "  run the tests \n"],
            ["session_id": "s2", "ts": 3, "text": "fix the build"],
            ["session_id": "s2", "ts": 4, "text": "   "],
        ], endsWithBreak: false)
        #expect(PromptHistory.codexEntries(data) == ["fix the build", "run the tests"])
        #expect(PromptHistory.codexEntries(data, limit: 1) == ["fix the build"])
    }

    @Test func openCodePutsPastesBackAndSkipsShell() {
        let pasted = "line one\nline two"
        let data = lines([
            ["text": "Explain [Pasted ~2 lines] please", "mode": "normal", "files": [], "agents": [], "skills": [],
             "pasted": [["text": pasted, "source": ["start": 8, "end": 25, "text": "[Pasted ~2 lines]"]]]],
            ["text": "ls -la", "mode": "shell", "pasted": []],
            ["text": "[Pasted ~1 lines] and [Pasted ~1 lines]", "mode": "normal",
             "pasted": [["text": "A", "source": ["start": 0, "end": 17, "text": "[Pasted ~1 lines]"]],
                        ["text": "B", "source": ["start": 22, "end": 39, "text": "[Pasted ~1 lines]"]]]],
        ])
        #expect(PromptHistory.openCodeEntries(data) == ["A and B", "Explain line one\nline two please"])
    }

    @Test func openCodeFindsAMarkThatMoved() {
        // Places off by one (an emoji before it, counted otherwise): the mark is looked for.
        let data = lines([
            ["text": "x [Pasted ~3 lines]", "mode": "normal",
             "pasted": [["text": "1\n2\n3", "source": ["start": 1, "end": 18, "text": "[Pasted ~3 lines]"]]]],
        ])
        #expect(PromptHistory.openCodeEntries(data) == ["x 1\n2\n3"])
    }

    @Test func geminiUserMessagesByTime() {
        let list: [[String: Any]] = [
            ["sessionId": "a", "messageId": 0, "type": "user", "message": "first", "timestamp": "2026-11-15T10:00:00.000Z"],
            ["sessionId": "b", "messageId": 0, "type": "user", "message": "third", "timestamp": "2026-11-15T12:00:00.000Z"],
            ["sessionId": "a", "messageId": 1, "type": "gemini", "message": "an answer", "timestamp": "2026-11-15T10:00:01.000Z"],
            ["sessionId": "a", "messageId": 2, "type": "user", "message": "second", "timestamp": "2026-11-15T11:00:00.000Z"],
            ["sessionId": "b", "messageId": 1, "type": "user", "message": "first", "timestamp": "2026-11-15T09:00:00.000Z"],
        ]
        let data = try! JSONSerialization.data(withJSONObject: list)
        #expect(PromptHistory.geminiEntries(data) == ["third", "second", "first"])
        #expect(PromptHistory.geminiEntries(Data("not json".utf8)).isEmpty)
    }

    @Test func remoteLines() {
        #expect(PromptHistory.codexRemoteLine(home: "/home/m/.codex", tailBytes: 10)
            == "tail -c 10 '/home/m/.codex/history.jsonl' 2>/dev/null | tail -n 500")
        #expect(PromptHistory.openCodeRemoteLine(tailBytes: 10)
            == #"tail -c 10 "${XDG_STATE_HOME:-$HOME/.local/state}/opencode/prompt-history.jsonl" 2>/dev/null | tail -n 300"#)
        #expect(PromptHistory.geminiRemoteLine(project: ".gemini/tmp/it's", maxBytes: 5)
            == #"head -c 5 '.gemini/tmp/it'\''s/logs.json' 2>/dev/null"#)
    }
}
