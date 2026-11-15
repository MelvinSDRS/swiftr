import CryptoKit
import Foundation

// MARK: - Where Gemini keeps its chats

/// Gemini CLI's chats (0.6x): `~/.gemini/tmp/<project>/chats/session-<time>-<id>.jsonl`,
/// `<project>` being the short name `~/.gemini/projects.json` gives the folder
/// Gemini runs in (older versions: the SHA-256 of its path). `GEMINI_CLI_HOME`
/// stands for `~` when set.
public enum GeminiFiles {
    /// `<home>/.gemini`, home being `GEMINI_CLI_HOME` when it is set.
    public static func folder(cliHome: String? = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"]) -> URL {
        let home = cliHome.flatMap { $0.isEmpty ? nil : URL(filePath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: ".gemini")
    }

    /// The `chats` folder of the project Gemini runs in from `cwd`.
    public static func chats(in gemini: URL, cwd: String) -> URL? {
        let fm = FileManager.default
        let tmp = gemini.appending(path: "tmp")
        var paths = [cwd]
        let real = (cwd as NSString).resolvingSymlinksInPath
        if real != cwd { paths.append(real) }
        var names: [String] = []
        if let data = fm.contents(atPath: gemini.appending(path: "projects.json").path),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = o["projects"] as? [String: Any]
        {
            for p in paths {
                // macOS's paths match without case, as Gemini compares them there.
                if let name = projects[p] as? String ?? projects.first(where: { $0.key.lowercased() == p.lowercased() })?.value as? String {
                    names.append(name)
                }
            }
        }
        names += paths.map(hash)
        for name in names {
            let chats = tmp.appending(path: name).appending(path: "chats")
            if fm.fileExists(atPath: chats.path) { return chats }
        }
        // Each project's folder names its own in `.project_root`.
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] {
            let root = tmp.appending(path: name).appending(path: ".project_root")
            guard let said = try? String(contentsOf: root, encoding: .utf8),
                  paths.contains(said.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            return tmp.appending(path: name).appending(path: "chats")
        }
        return nil
    }

    /// The chat written last, since `since` (a little before: Gemini writes
    /// its first lines as it starts). Sub-agents' chats, in folders, aside.
    public static func newestChat(in chats: URL, since: Date?) -> URL? {
        let fm = FileManager.default
        var best: (url: URL, date: Date)?
        for name in (try? fm.contentsOfDirectory(atPath: chats.path)) ?? [] where name.hasPrefix("session-") && name.hasSuffix(".jsonl") {
            let url = chats.appending(path: name)
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            if let since, date < since.addingTimeInterval(-2) { continue }
            if let best, best.date >= date { continue }
            best = (url, date)
        }
        return best?.url
    }

    /// A shell line that prints, on another machine, the chat of the Gemini
    /// running there as `pid` in `cwd`: the newest written since it started,
    /// in the project folder whose `.project_root` names `cwd`.
    public static func remoteLookup(pid: Int, cwd: String) -> String {
        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return #"""
        P=\#(pid); C=\#(quoted); H="${GEMINI_CLI_HOME:-$HOME}/.gemini"
        E=$(ps -o etimes= -p $P 2>/dev/null | tr -d ' ')
        [ -n "$E" ] || E=$(ps -o etime= -p $P 2>/dev/null | awk '{d=0; t=$1; if (index(t, "-")) { split(t, x, "-"); d=x[1]; t=x[2] } n=split(t, a, ":"); s=0; for (i=1; i<=n; i++) s=s*60+a[i]; print d*86400+s}')
        case "$E" in ''|*[!0-9]*) exit 0;; esac
        for d in "$H"/tmp/*/; do
          [ "$(cat "$d.project_root" 2>/dev/null)" = "$C" ] || continue
          find "$d"chats -maxdepth 1 -name 'session-*.jsonl' -mmin -$((E / 60 + 2)) 2>/dev/null
        done | tr '\n' '\0' | xargs -0 ls -t 2>/dev/null | head -n 1
        """#
    }

    /// The chat's whole session id, as its first line has it: `--resume`
    /// takes that UUID, not the short id in the file's name.
    public static func sessionID(start text: String) -> String? {
        guard let m = text.firstMatch(of: /"sessionId"\s*:\s*"([0-9A-Fa-f-]{36})"/) else { return nil }
        return String(m.output.1)
    }

    /// The whole session id of the chat file at `url`, from its first bytes.
    public static func sessionID(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 64 * 1024) else { return nil }
        return sessionID(start: String(decoding: data, as: UTF8.self))
    }

    /// `session-2026-11-12T16-32-ad87a94e.jsonl` → `ad87a94e`.
    public static func shortID(_ path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.split(separator: "-").last.map(String.init) ?? name
    }

    static func hash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - A chat's file

/// A Gemini chat file read as Gemini reads it, handed on as its messages,
/// each once, as they stand. Gemini writes a message again whole when it
/// changes (its tool calls, once done), takes messages back with
/// `$rewindTo` (a refusal, /rewind) and changes them with `$patch`: a
/// message already handed on that changes makes `readNew` ask for the chat
/// again (nil), and `openTail` then hands on what stands.
public actor GeminiChat: TranscriptSource {
    private let file: any TranscriptSource
    private var loaded = false
    /// The messages, in Gemini's order.
    private var order: [String] = []
    private var messages: [String: Message] = [:]
    /// What Gemini wrote of the chat (`summary`), and the one handed on.
    private var summary: String?
    private var summarySent: String?
    /// The messages handed on, in order, as they were then.
    private var handed: [(id: String, data: Data)] = []
    private var start = true

    private struct Message {
        var data: Data
        /// Its tool calls' ids.
        var calls: [String]
        /// No text and no thinking: only tool calls.
        var bare: Bool
    }

    /// `file`: the chat's file, here or on another machine.
    public init(file: any TranscriptSource) {
        self.file = file
    }

    public var atStart: Bool { start }

    public func openTail(lines want: Int, maxBytes: Int) async throws -> [Data] {
        if !loaded {
            try await load()
        } else if !(try await catchUp()) {
            try await load()
        }
        let all = visible()
        var keep = 0
        var bytes = 0
        for m in all.reversed() {
            if keep >= want || (keep > 0 && bytes + m.data.count > maxBytes) { break }
            keep += 1
            bytes += m.data.count
        }
        handed = Array(all.suffix(keep))
        start = keep == all.count
        summarySent = nil
        return handed.map(\.data) + summaryLine()
    }

    public func readNew() async throws -> [Data]? {
        guard loaded else { throw TranscriptSourceError.notOpen }
        // Its file replaced: everything is read again.
        guard try await catchUp() else {
            try await load()
            return nil
        }
        let all = visible()
        var at = all.count
        if let first = handed.first {
            guard let i = all.firstIndex(where: { $0.id == first.id }), all.count - i >= handed.count else { return nil }
            for (k, was) in handed.enumerated() where all[i + k].id != was.id || all[i + k].data != was.data {
                return nil
            }
            at = i + handed.count
        } else {
            at = 0
        }
        let new = Array(all[at...])
        handed += new
        return new.map(\.data) + summaryLine()
    }

    public func readEarlier(lines want: Int, maxBytes: Int) async throws -> [Data] {
        let all = visible()
        let end = handed.first.flatMap { first in all.firstIndex { $0.id == first.id } } ?? all.count
        var from = end
        var bytes = 0
        while from > 0, end - from < want {
            let size = all[from - 1].data.count
            if from < end, bytes + size > maxBytes { break }
            bytes += size
            from -= 1
        }
        handed = Array(all[from ..< end]) + handed
        start = from == 0
        return all[from ..< end].map(\.data)
    }

    /// The whole file, from its start.
    private func load() async throws {
        order = []
        messages = [:]
        summary = nil
        var lines = try await file.openTail(lines: Int.max / 4, maxBytes: Int.max / 4)
        while !(await file.atStart) {
            let earlier = try await file.readEarlier(lines: Int.max / 4, maxBytes: Int.max / 4)
            if earlier.isEmpty { break }
            lines = earlier + lines
        }
        for line in lines { take(line) }
        loaded = true
    }

    /// Reads what Gemini added; false when its file was replaced or cut.
    private func catchUp() async throws -> Bool {
        guard let lines = try await file.readNew() else { return false }
        for line in lines { take(line) }
        return true
    }

    /// The messages to show, in order. A call stopped with Esc comes twice
    /// (its message, then one with the call alone): once is enough.
    private func visible() -> [(id: String, data: Data)] {
        var seen = Set<String>()
        var out: [(id: String, data: Data)] = []
        for id in order {
            guard let m = messages[id] else { continue }
            if m.bare, !m.calls.isEmpty, m.calls.allSatisfy(seen.contains) { continue }
            seen.formUnion(m.calls)
            out.append((id, m.data))
        }
        return out
    }

    /// The chat's summary as a line of its own, when it is new.
    private func summaryLine() -> [Data] {
        guard let summary, summary != summarySent else { return [] }
        summarySent = summary
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "summary", "content": summary]) else { return [] }
        return [data]
    }

    /// One line of the file, as Gemini's own reader takes it.
    private func take(_ line: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let id = o["$rewindTo"] as? String {
            // That message and every one after it are gone.
            if let i = order.firstIndex(of: id) {
                for gone in order[i...] { messages[gone] = nil }
                order.removeSubrange(i...)
            } else {
                order = []
                messages = [:]
            }
        } else if let patch = o["$patch"] as? [String: Any] {
            if patch["id"] is String { change(patch) }
            for update in patch["updates"] as? [[String: Any]] ?? [] { change(update) }
            for id in patch["removeIds"] as? [String] ?? [] {
                messages[id] = nil
                order.removeAll { $0 == id }
            }
            if let ids = patch["orderIds"] as? [String] {
                let listed = ids.filter { messages[$0] != nil }
                let set = Set(listed)
                order = order.filter { !set.contains($0) } + listed
            }
        } else if let id = o["id"] as? String {
            put(id, o, line)
        } else if let set = o["$set"] as? [String: Any] {
            if let all = set["messages"] as? [[String: Any]] {
                order = []
                messages = [:]
                for m in all { if let id = m["id"] as? String { put(id, m, nil) } }
            }
            if let s = set["summary"] as? String { summary = Self.title(s) }
        } else if o["sessionId"] is String {
            // Older files: the whole chat in the first line.
            for m in o["messages"] as? [[String: Any]] ?? [] { if let id = m["id"] as? String { put(id, m, nil) } }
            if let s = o["summary"] as? String { summary = Self.title(s) }
        }
    }

    /// A message, new or written again (it keeps its place).
    private func put(_ id: String, _ o: [String: Any], _ line: Data?) {
        guard let data = line ?? (try? JSONSerialization.data(withJSONObject: o)) else { return }
        if messages[id] == nil { order.append(id) }
        let calls = (o["toolCalls"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let text = Transcript.geminiText(o["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let thoughts = (o["thoughts"] as? [Any])?.isEmpty == false
        messages[id] = Message(data: data, calls: calls, bare: text.isEmpty && !thoughts)
    }

    /// `$patch`'s change to one message: its content, its calls' results.
    private func change(_ patch: [String: Any]) {
        guard let id = patch["id"] as? String, let m = messages[id],
              var o = try? JSONSerialization.jsonObject(with: m.data) as? [String: Any]
        else { return }
        if let content = patch["content"], !(content is NSNull) { o["content"] = content }
        if let calls = patch["toolCalls"] as? [[String: Any]], o["type"] as? String == "gemini", var mine = o["toolCalls"] as? [[String: Any]] {
            for call in calls {
                guard let cid = call["id"] as? String, let i = mine.firstIndex(where: { $0["id"] as? String == cid }), let result = call["result"] else { continue }
                mine[i]["result"] = result
            }
            o["toolCalls"] = mine
        }
        put(id, o, nil)
    }

    /// A summary fit for a title: one line, not the model's JSON.
    static func title(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("{"), !t.hasPrefix("[") else { return nil }
        return t.split(separator: "\n", maxSplits: 1).first.map(String.init)
    }
}

// MARK: - Its messages

/// Gemini's messages read into the items Claude Code's transcripts give.
/// A message is `user` (what the person wrote, or tools' results, shown
/// with their calls), `gemini` (its thinking, text and calls, each call
/// with its result once done), or `info`, `warning`, `error` notes.
extension Transcript {
    static func readGemini(_ data: Data) -> Line? {
        guard let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = m["type"] as? String else { return nil }
        var line = Line()
        line.id = m["id"] as? String ?? UUID().uuidString
        if let t = m["timestamp"] as? String { line.time = seconds(iso: t) }
        switch type {
        case "summary":
            line.aiTitle = m["content"] as? String
        case "user":
            // What the person typed (`/command`, `@file`), else what it became.
            let parts = geminiParts(m["displayContent"] ?? m["content"])
            if parts.contains(where: { $0["functionResponse"] != nil }) { return nil }
            let text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("<session_context>") || text.hasPrefix("<hook_context>") { return nil }
            let images = parts.compactMap { part -> [String: Any]? in
                let blob = part["inlineData"] as? [String: Any] ?? part["fileData"] as? [String: Any]
                return (blob?["mimeType"] as? String ?? "").hasPrefix("image/") ? blob : nil
            }
            guard !text.isEmpty || !images.isEmpty else { return nil }
            // `inlineData` holds the bytes, `fileData` names a file.
            let pictures = images.compactMap { blob in
                (blob["data"] as? String ?? blob["fileUri"] as? String).flatMap { TranscriptImage.from($0, mime: blob["mimeType"] as? String) }
            }
            line.items.append((TranscriptItem(id: line.id, kind: .prompt(text, images: images.count), pictures: pictures), nil))
            line.prompted = true
        case "gemini":
            readGeminiAnswer(m, into: &line)
        case "info":
            let text = geminiText(m["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let notice: Notice = text == "Request cancelled." ? .interrupted : .info(text)
            line.items.append((TranscriptItem(id: line.id, kind: .notice(notice)), nil))
        case "warning":
            let text = geminiText(m["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            line.items.append((TranscriptItem(id: line.id, kind: .notice(.info(text))), nil))
        case "error":
            let text = geminiText(m["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            line.items.append((TranscriptItem(id: line.id, kind: .notice(.error(text))), nil))
        default:
            return nil
        }
        return line
    }

    /// One answer: its thinking, its text, its calls; the model and how
    /// full its context is. No turn's end: Gemini writes an answer before
    /// the calls it makes, which come into it once done.
    private static func readGeminiAnswer(_ m: [String: Any], into line: inout Line) {
        if let model = m["model"] as? String, !model.isEmpty {
            line.model = model
            line.contextWindow = model.contains("gemma-4") ? 256_000 : 1_048_576
        }
        if let t = m["tokens"] as? [String: Any] {
            let used = [t["input"], t["output"]].compactMap { ($0 as? NSNumber)?.intValue }.reduce(0, +)
            if used > 0 { line.contextTokens = used }
        }
        for (i, thought) in (m["thoughts"] as? [[String: Any]] ?? []).enumerated() {
            let subject = (thought["subject"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let said = (thought["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = [subject.isEmpty ? nil : "**\(subject)**", said.isEmpty ? nil : said].compactMap { $0 }.joined(separator: "\n")
            if !text.isEmpty { line.items.append((TranscriptItem(id: "\(line.id)/think\(i)", kind: .thinking(text)), nil)) }
        }
        let text = geminiText(m["content"])
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            line.items.append((TranscriptItem(id: line.id, kind: .text(text)), nil))
        }
        for call in m["toolCalls"] as? [[String: Any]] ?? [] {
            let c = geminiCall(call, fallback: "\(line.id)/\(line.items.count)")
            line.items.append((TranscriptItem(id: c.id, kind: .tool(c)), nil))
        }
    }

    /// A message's content as parts: a string is one text part.
    static func geminiParts(_ content: Any?) -> [[String: Any]] {
        if let s = content as? String { return [["text": s]] }
        if let parts = content as? [Any] {
            return parts.compactMap { $0 as? [String: Any] ?? ($0 as? String).map { ["text": $0] } }
        }
        if let part = content as? [String: Any] { return [part] }
        return []
    }

    /// A message's text, its thinking parts aside.
    static func geminiText(_ content: Any?) -> String {
        geminiParts(content).filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
    }

    /// Gemini's call as the one Claude Code's would be: `run_shell_command`
    /// as Shell, `replace` as Edit with its diff, `ask_user` as AskUserQuestion…
    static func geminiCall(_ call: [String: Any], fallback: String) -> ToolCall {
        let id = call["id"] as? String ?? fallback
        let name = call["name"] as? String ?? "tool"
        let args = call["args"] as? [String: Any] ?? [:]
        let display = call["resultDisplay"] as? [String: Any]
        var result = geminiResult(call)
        func text(_ key: String) -> JSON? { (args[key] as? String).map(JSON.string) }
        func object(_ pairs: [String: JSON?]) -> JSON { .object(pairs.compactMapValues { $0 }) }
        switch name {
        case "run_shell_command":
            if let r = result, r.declined == nil { result = geminiShell(r) }
            return ToolCall(id: id, name: "Shell", input: object(["command": text("command"), "description": text("description"), "cwd": text("dir_path")]), result: result)
        case "read_file":
            var input: [String: JSON?] = ["file_path": text("file_path") ?? text("absolute_path")]
            if let from = (args["start_line"] as? NSNumber)?.intValue {
                input["offset"] = .int(Int64(from))
                if let to = (args["end_line"] as? NSNumber)?.intValue, to >= from { input["limit"] = .int(Int64(to - from + 1)) }
            }
            return ToolCall(id: id, name: "Read", input: object(input), result: result)
        case "read_many_files":
            let files = (args["include"] as? [String] ?? args["paths"] as? [String] ?? []).joined(separator: ", ")
            return ToolCall(id: id, name: "Read", input: ["file_path": .string(files)], result: result)
        case "write_file":
            return ToolCall(id: id, name: "Write", input: object(["file_path": text("file_path"), "content": text("content")]), result: result)
        case "replace", "edit":
            // The change made, as a patch, once done; else what was asked.
            if let diff = (display?["fileDiff"] as? String).map(geminiPatch), !diff.isEmpty {
                return ToolCall(id: id, name: "Edit", input: object(["file_path": text("file_path"), "diff": .string(diff)]), result: result)
            }
            return ToolCall(id: id, name: "Edit", input: object(["file_path": text("file_path"), "old_string": text("old_string"), "new_string": text("new_string")]), result: result)
        case "glob":
            return ToolCall(id: id, name: "Glob", input: object(["pattern": text("pattern"), "path": text("dir_path")]), result: result)
        case "grep_search", "search_file_content", "grep":
            return ToolCall(id: id, name: "Grep", input: object(["pattern": text("pattern"), "path": text("dir_path"), "glob": text("include_pattern") ?? text("include")]), result: result)
        case "list_directory":
            return ToolCall(id: id, name: "LS", input: object(["path": text("dir_path") ?? text("path")]), result: result)
        case "web_fetch":
            let prompt = args["prompt"] as? String ?? ""
            let url = prompt.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }.map(String.init)
            return ToolCall(id: id, name: "WebFetch", input: object(["url": url.map(JSON.string), "prompt": .string(prompt)]), result: result)
        case "google_web_search":
            return ToolCall(id: id, name: "WebSearch", input: object(["query": text("query")]), result: result)
        case "write_todos":
            let todos = (args["todos"] as? [[String: Any]] ?? []).map { todo -> JSON in
                // Gemini's `cancelled` is no longer to do; `blocked` still is.
                let status = switch todo["status"] as? String {
                case "completed", "cancelled": "completed"
                case "in_progress": "in_progress"
                default: "pending"
                }
                return object(["content": (todo["description"] as? String).map(JSON.string), "status": .string(status)])
            }
            return ToolCall(id: id, name: "TodoWrite", input: ["todos": .array(todos)], result: result)
        case "ask_user":
            let asked = args["questions"] as? [[String: Any]] ?? []
            let questions = asked.map { q -> JSON in
                var options = (q["options"] as? [[String: Any]] ?? []).map { o in
                    object(["label": (o["label"] as? String).map(JSON.string), "description": (o["description"] as? String).map(JSON.string)])
                }
                if q["type"] as? String == "yesno", options.isEmpty {
                    options = [["label": "Yes"], ["label": "No"]]
                }
                return object([
                    "question": (q["question"] as? String).map(JSON.string), "header": (q["header"] as? String).map(JSON.string),
                    "multiSelect": .bool(q["multiSelect"] as? Bool ?? false), "options": .array(options),
                ])
            }
            // `{"answers":{"0":"Red","1":"Cheese, Olives"}}`: each question's answer by its place.
            if result != nil, result?.declined == nil, let said = result?.text,
               let o = try? JSONSerialization.jsonObject(with: Data(said.utf8)) as? [String: Any],
               let answers = o["answers"] as? [String: Any]
            {
                var answered = ToolResult(text: "")
                answered.answers = asked.enumerated().compactMap { i, q in
                    guard let a = answers[String(i)] as? String else { return nil }
                    return ToolResult.Answer(question: q["question"] as? String ?? "", answer: a)
                }
                result = answered
            }
            return ToolCall(id: id, name: "AskUserQuestion", input: ["questions": .array(questions)], result: result)
        case "activate_skill":
            return ToolCall(id: id, name: "Skill", input: object(["skill": text("name")]), result: result)
        case "invoke_agent":
            return ToolCall(id: id, name: "Task", input: object([
                "description": text("agent_name") ?? text("name") ?? text("description"), "prompt": text("prompt") ?? text("task") ?? text("query"),
            ]), result: result)
        default:
            return ToolCall(id: id, name: call["displayName"] as? String ?? name, input: JSON(any: args), result: result)
        }
    }

    /// A call's result once it is done: its text, an error, or the person's no.
    private static func geminiResult(_ call: [String: Any]) -> ToolResult? {
        guard let status = call["status"] as? String, ["success", "error", "cancelled"].contains(status) else { return nil }
        let responses = (call["result"] as? [[String: Any]] ?? []).compactMap { ($0["functionResponse"] as? [String: Any])?["response"] as? [String: Any] }
        let output = responses.compactMap { $0["output"] as? String }.joined(separator: "\n")
        let error = responses.compactMap { $0["error"] as? String }.joined(separator: "\n")
        switch status {
        case "success":
            return ToolResult(text: output.trimmingCharacters(in: .newlines))
        case "cancelled":
            // Refused when Gemini asked (`User denied execution.`), or stopped while it ran.
            if error.contains("User denied execution") || error.contains("denied by user") {
                var r = ToolResult(text: "", isError: true)
                r.declined = ""
                return r
            }
            return ToolResult(text: "Stopped", isError: true)
        default:
            let said = error.isEmpty ? output : error
            return ToolResult(text: said.trimmingCharacters(in: .whitespacesAndNewlines), isError: true)
        }
    }

    /// What a shell command printed, without Gemini's wrapping:
    /// `<untrusted_context>\nOutput: …\nExit Code: 1\nProcess Group PGID: …\n</untrusted_context>`.
    static func geminiShell(_ result: ToolResult) -> ToolResult {
        var t = result.text
        for tag in ["<untrusted_context>", "</untrusted_context>"] { t = t.replacingOccurrences(of: tag, with: "") }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("Output:") || t.hasPrefix("Command:") || t.hasPrefix("Error:") || t.hasPrefix("Exit Code:") else { return result }
        let keys = ["Command:", "Directory:", "Output:", "Error:", "Exit Code:", "Signal:", "Background PIDs:", "Process Group PGID:"]
        var fields: [String: [String]] = [:]
        var key: String?
        for line in t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let k = keys.first(where: { line.hasPrefix($0) }) {
                key = k
                fields[k, default: []].append(line.dropFirst(k.count).trimmingCharacters(in: .whitespaces))
            } else if let key {
                fields[key, default: []].append(line)
            }
        }
        var printed = (fields["Output:"] ?? []).joined(separator: "\n").trimmingCharacters(in: .newlines)
        if printed == "(empty)" { printed = "" }
        let error = (fields["Error:"] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let code = Int((fields["Exit Code:"] ?? []).first ?? "") ?? 0
        let signal = (fields["Signal:"] ?? []).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var text = printed
        if !error.isEmpty, error != "(none)" { text += (text.isEmpty ? "" : "\n") + error }
        if code != 0, text.isEmpty { text = "Exit code \(code)" }
        if !signal.isEmpty, signal != "(none)", text.isEmpty { text = "Signal \(signal)" }
        var out = ToolResult(text: text, isError: result.isError || code != 0 || (!error.isEmpty && error != "(none)"))
        out.declined = result.declined
        return out
    }

    /// Gemini's diff from its `Index:` and `===` lines on: from its first hunk.
    static func geminiPatch(_ diff: String) -> String {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.firstIndex(where: { $0.hasPrefix("@@") }) else { return diff }
        return lines[first...].joined(separator: "\n")
    }
}
