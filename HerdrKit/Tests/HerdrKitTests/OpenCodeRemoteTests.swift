import Foundation
import Testing
@testable import HerdrKit

/// Runs `OpenCodeRemote`'s program here, as `machine.exec` runs it there.
private func runProgram(base: String, _ arguments: [String]) throws -> Data {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/env")
    p.arguments = ["python3", "-c", OpenCodeRemote.script, base] + arguments
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}

private let hasPython = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3")
    || FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

private func write(_ object: Any, to path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: URL(filePath: path))
}

/// OpenCode 1.x's files for a turn: the person's message, then a step that runs `ls` and answers.
private func filesSession(_ base: String, directory: String, now: Int) throws {
    let s = base + "/storage"
    try write(["id": "ses_1", "directory": directory, "title": "List the folder", "time": ["created": now, "updated": now]], to: s + "/session/proj/ses_1.json")
    try write(["id": "msg_001", "sessionID": "ses_1", "role": "user", "time": ["created": now - 9000], "agent": "build",
               "model": ["providerID": "google", "modelID": "gemini-2.5-flash"]], to: s + "/message/ses_1/msg_001.json")
    try write(["id": "prt_001", "messageID": "msg_001", "type": "text", "text": "List the folder"], to: s + "/part/msg_001/prt_001.json")
    try write(["id": "prt_002", "messageID": "msg_001", "type": "text", "text": "Called the Read tool", "synthetic": true], to: s + "/part/msg_001/prt_002.json")
    try write(["id": "msg_002", "sessionID": "ses_1", "role": "assistant", "time": ["created": now - 8000, "completed": now - 1000],
               "modelID": "gemini-2.5-flash", "providerID": "google", "mode": "build", "agent": "build", "finish": "stop",
               "tokens": ["input": 1200, "output": 30, "reasoning": 0, "cache": ["read": 800, "write": 0]]], to: s + "/message/ses_1/msg_002.json")
    try write(["id": "prt_003", "messageID": "msg_002", "type": "step-start"], to: s + "/part/msg_002/prt_003.json")
    try write(["id": "prt_004", "messageID": "msg_002", "type": "reasoning", "text": "One command."], to: s + "/part/msg_002/prt_004.json")
    try write(["id": "prt_005", "messageID": "msg_002", "type": "tool", "callID": "call_1", "tool": "bash",
               "state": ["status": "completed", "input": ["command": "ls", "description": "List files"], "output": "a.txt\nb.txt\n",
                         "metadata": ["exit": 0], "time": ["start": now - 7000, "end": now - 6000]]], to: s + "/part/msg_002/prt_005.json")
    try write(["id": "prt_006", "messageID": "msg_002", "type": "text", "text": "Two files: a.txt and b.txt."], to: s + "/part/msg_002/prt_006.json")
}

@Suite struct OpenCodeRemoteTests {
    @Test func filesMessagesReadAsRows() throws {
        let now = 1_794_465_900_000
        let base = NSTemporaryDirectory() + "swiftr-octest-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: base) }
        try filesSession(base, directory: "/work", now: now)
        func entry(_ name: String, seq: Int) throws -> [String: Any] {
            let s = base + "/storage"
            let m = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: "\(s)/message/ses_1/\(name).json"))) as! [String: Any]
            let parts = try FileManager.default.contentsOfDirectory(atPath: "\(s)/part/\(name)").sorted().map {
                try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: "\(s)/part/\(name)/\($0)"))) as! [String: Any]
            }
            return ["message": m, "parts": parts, "seq": seq]
        }
        let models = ["google/gemini-2.5-flash": OpenCodeRemote.Model(name: "Gemini 2.5 Flash", window: 1_048_576, provider: "Google")]
        let lines = try OpenCodeRemote.lines(entry("msg_001", seq: 0), models: models) + OpenCodeRemote.lines(entry("msg_002", seq: 1), models: models)
        #expect(lines.count == 3)
        let t = Transcript.parse(lines, format: .opencode)
        let kinds = t.items.map(\.kind)
        #expect(kinds.count == 5)
        #expect(kinds.first == .prompt("List the folder", images: 0))
        #expect(kinds.count > 1 && kinds[1] == .thinking("One command."))
        guard kinds.count == 5, case .tool(let shell) = kinds[2] else {
            Issue.record("a call expected")
            return
        }
        #expect(shell.name == "Shell")
        #expect(shell.input["command"]?.string == "ls")
        #expect(shell.result?.text == "a.txt\nb.txt")
        #expect(kinds[3] == .text("Two files: a.txt and b.txt."))
        #expect(kinds[4] == .notice(.turnEnded(milliseconds: 8000)))
        #expect(t.facts.modelName == "Gemini 2.5 Flash")
        #expect(t.facts.contextWindow == 1_048_576)
        #expect(t.facts.contextTokens == 2030)
        #expect(t.facts.agent == "build")
    }

    @Test(.enabled(if: hasPython)) func programReadsOpenCodeFiles() throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let base = NSTemporaryDirectory() + "swiftr-octest-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: base) }
        try filesSession(base, directory: "/work", now: now)
        // This test's own process started before the session changed.
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let found = OpenCodeRemote.read(try runProgram(base: base, ["find", "/work", pid, "0"]))
        #expect(found.done)
        #expect(found.session == "ses_1")
        #expect(found.title == "List the folder")
        #expect(OpenCodeRemote.read(try runProgram(base: base, ["find", "/elsewhere", pid, "1"])).session == nil)

        let tail = OpenCodeRemote.read(try runProgram(base: base, ["tail", "ses_1", "50"]))
        #expect(tail.done)
        #expect(tail.start == true)
        #expect(tail.rows.map(\.seq) == [0, 1])
        #expect(tail.rows.map(\.lines.count) == [1, 2])
        let changed = tail.rows.map(\.updated).max() ?? 0
        #expect(OpenCodeRemote.read(try runProgram(base: base, ["new", "ses_1", "1", String(changed)])).rows.isEmpty)

        // The next message comes.
        try write(["id": "msg_003", "sessionID": "ses_1", "role": "user", "time": ["created": now]], to: base + "/storage/message/ses_1/msg_003.json")
        try write(["id": "prt_007", "messageID": "msg_003", "type": "text", "text": "Thanks"], to: base + "/storage/part/msg_003/prt_007.json")
        let next = OpenCodeRemote.read(try runProgram(base: base, ["new", "ses_1", "1", String(changed)]))
        #expect(next.rows.map(\.seq) == [2])
        let earlier = OpenCodeRemote.read(try runProgram(base: base, ["earlier", "ses_1", "2", "1"]))
        #expect(earlier.rows.map(\.seq) == [1])
        #expect(earlier.start == false)
    }

    @Test(.enabled(if: hasPython)) func programHidesARevertInFiles() throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let base = NSTemporaryDirectory() + "swiftr-octest-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: base) }
        try filesSession(base, directory: "/work", now: now)
        let before = OpenCodeRemote.read(try runProgram(base: base, ["tail", "ses_1", "50"]))
        #expect(before.revertMark == nil)
        #expect(before.revertLine == nil)
        // The timeline's Revert at the first message: the session's file says so.
        try write(["id": "ses_1", "directory": "/work", "title": "List the folder", "time": ["created": now, "updated": now],
                   "revert": ["messageID": "msg_001", "snapshot": "abc"]], to: base + "/storage/session/proj/ses_1.json")
        let tail = OpenCodeRemote.read(try runProgram(base: base, ["tail", "ses_1", "50"]))
        #expect(tail.rows.isEmpty)
        #expect(tail.revertMark != nil)
        let line = try #require(tail.revertLine)
        #expect(Transcript.parse([line], format: .opencode).items.map(\.kind) == [.notice(.reverted(messages: 1, files: []))])
        #expect(OpenCodeRemote.read(try runProgram(base: base, ["new", "ses_1", "-1", "0"])).rows.isEmpty)
    }

    @Test(.enabled(if: hasPython)) func programReadsOpenCodesDatabase() throws {
        let base = NSTemporaryDirectory() + "swiftr-octest-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let user = #"{"time":{"created":\#(now - 5000)},"text":"Say hi","files":[]}"#
        let step = #"{"time":{"created":\#(now - 4000)},"agent":"build","model":{"id":"glm-5","providerID":"opencode"},"content":[{"type":"text","text":"Hi!"}]}"#
        let catalog = #"{"body":{"opencode":{"name":"OpenCode Zen","models":{"glm-5":{"name":"GLM-5","limit":{"context":200000}}}}}}"#
        // The tables as OpenCode 2.x has them, with the columns read.
        let make = """
        import sqlite3, sys
        con = sqlite3.connect(sys.argv[1] + "/opencode.db")
        con.execute("create table session_v2 (id text, directory text, parent_id text, time_archived integer, time_updated integer, title text)")
        con.execute("create table session_message (id text, session_id text, seq integer, type text, time_updated integer, data text)")
        con.execute("create table kv (key text, value text)")
        con.execute("insert into session_v2 values ('ses_9', '/work', null, null, ?, 'Hello')", (\(now),))
        con.execute("insert into session_message values ('m1', 'ses_9', 1, 'user', ?, ?)", (\(now), sys.argv[2]))
        con.execute("insert into session_message values ('m2', 'ses_9', 2, 'assistant', ?, ?)", (\(now), sys.argv[3]))
        con.execute("insert into kv values ('models-dev:v2:catalog', ?)", (sys.argv[4],))
        con.commit()
        """
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/env")
        p.arguments = ["python3", "-c", make, base, user, step, catalog]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)

        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let found = OpenCodeRemote.read(try runProgram(base: base, ["find", "/work", pid, "1"]))
        #expect(found.session == "ses_9")
        #expect(found.title == "Hello")
        let tail = OpenCodeRemote.read(try runProgram(base: base, ["tail", "ses_9", "50"]))
        #expect(tail.done)
        #expect(tail.start == true)
        #expect(tail.models["opencode/glm-5"] == OpenCodeRemote.Model(name: "GLM-5", window: 200_000, provider: "OpenCode Zen"))
        let t = Transcript.parse(tail.rows.flatMap(\.lines), format: .opencode)
        #expect(t.items.map(\.kind) == [.prompt("Say hi", images: 0), .text("Hi!")])
        #expect(t.facts.modelName == "GLM-5")
        #expect(OpenCodeRemote.read(try runProgram(base: base, ["new", "ses_9", "2", String(now)])).rows.isEmpty)
    }

    @Test(.enabled(if: hasPython)) func programSaysWhenThereIsNothing() throws {
        let out = OpenCodeRemote.read(try runProgram(base: "/nonexistent-swiftr", ["tail", "x", "5"]))
        #expect(out.done)
        #expect(out.error?.hasPrefix("No OpenCode sessions") == true)
        // Without Python, nothing at all comes: the source says so.
        #expect(OpenCodeRemote.read(Data()).done == false)
    }

    /// 1.1.47 writes `Error: The user rejected permission to use this specific tool call.`
    @Test func refusedCallReadsAsDeclined() {
        let message: [String: Any] = ["role": "assistant", "time": ["created": 1, "completed": 2]]
        let refused: [String: Any] = ["type": "tool", "callID": "call_1", "tool": "write",
                                      "state": ["status": "error", "input": ["filePath": "/x/hello.txt", "content": "hi"],
                                                "error": "Error: The user rejected permission to use this specific tool call."]]
        let rows = OpenCodeRemote.filesRows(message: message, parts: [refused])
        let content = rows.first?.data["content"] as? [[String: Any]]
        let state = content?.first?["state"] as? [String: Any]
        #expect(state?["error"] as? String == Transcript.openCodeDeclined)
    }

    /// Refusals read as such, in 1.x's words and 2.x's.
    @Test func refusalsInTheirWords() {
        #expect(Transcript.openCodeRefusal("Error: The user dismissed this question") == "")
        #expect(Transcript.openCodeRefusal(Transcript.openCodeDeclined) == "")
        #expect(Transcript.openCodeRefusal("Error: The user rejected permission to use this specific tool call.") == "")
        #expect(Transcript.openCodeRefusal("The user rejected permission to use this specific tool call with the following feedback: use rm -i") == "use rm -i")
        #expect(Transcript.openCodeRefusal("Error: File not found") == nil)
    }

    @Test func sessionNamedOnTheCommandLine() {
        #expect(OpenCodeRemote.named(in: ["opencode", "--session", "ses_1"]) == "ses_1")
        #expect(OpenCodeRemote.named(in: ["opencode", "--session=ses_2"]) == "ses_2")
        #expect(OpenCodeRemote.named(in: ["opencode", "-c"]) == nil)
        #expect(OpenCodeRemote.findArguments(argv: ["opencode", "-c"], directory: "/w", pid: 7) == ["find", "/w", "7", "1"])
        #expect(OpenCodeRemote.line(base: nil, ["tail", "it's"]).hasSuffix(#" '' 'tail' 'it'\''s'"#))
    }
}
