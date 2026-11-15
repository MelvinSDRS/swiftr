import Foundation

/// OpenCode's sessions (2.x) read into the items Claude Code's transcripts
/// give. OpenCode's server keeps them in SQLite, one row per message in
/// `session_message`; `OpenCodeStore` hands each row over as one line:
///
///     {"id":"msg_…","seq":20,"type":"assistant","window":200000,"modelName":"GLM-5.3-Flash Free","data":{…}}
///
/// Rows are `user` (what the person wrote), `assistant` (one step: its
/// thinking, text and tool calls, each call with its state), `compaction`
/// and `idle` (the turn's end, and how it ended). A row changes while its
/// tools run; the store reads the session again when one does.
extension Transcript {
    static func readOpenCode(_ data: Data) -> Line? {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = row["type"] as? String,
              let body = row["data"] as? [String: Any]
        else { return nil }
        var line = Line()
        line.id = row["id"] as? String ?? UUID().uuidString
        if let ms = openCodeInt((body["time"] as? [String: Any])?["created"]) { line.time = Double(ms) / 1000 }
        switch type {
        case "user":
            let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let files = body["files"] as? [[String: Any]] ?? []
            let images = files.filter { ($0["mime"] as? String ?? $0["mediaType"] as? String ?? "").hasPrefix("image/") }
            guard !text.isEmpty || !images.isEmpty else { return nil }
            line.items.append((TranscriptItem(id: line.id, kind: .prompt(text, images: images.count), pictures: images.compactMap(openCodePicture)), nil))
            line.prompted = true
        case "assistant":
            readOpenCodeStep(body, row: row, into: &line)
        case "compaction":
            let summary = (body["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            line.items.append((TranscriptItem(id: line.id, kind: .notice(.compacted(summary: summary?.isEmpty == false ? summary : nil))), nil))
        case "reverted":
            // A revert under way, as `OpenCodeTranscript` adds it after the rows still shown.
            let files = (body["files"] as? [[String: Any]] ?? []).compactMap { f -> RevertedFile? in
                guard let path = f["file"] as? String else { return nil }
                return RevertedFile(path: path, status: f["status"] as? String ?? "",
                                    additions: openCodeInt(f["additions"]) ?? 0, deletions: openCodeInt(f["deletions"]) ?? 0)
            }
            line.items.append((TranscriptItem(id: line.id, kind: .notice(.reverted(messages: openCodeInt(body["messages"]) ?? 0, files: files))), nil))
        case "idle":
            switch body["outcome"] as? String {
            case "succeeded":
                line.endedAt = line.time
            case "interrupted", "aborted":
                line.items.append((TranscriptItem(id: line.id, kind: .notice(.interrupted)), nil))
            default:
                let error = (body["error"] as? [String: Any])?["message"] as? String ?? body["error"] as? String
                if let error, !error.isEmpty {
                    line.items.append((TranscriptItem(id: line.id, kind: .notice(.error(error))), nil))
                }
            }
        default:
            return nil
        }
        return line
    }

    /// One step of the answer: its parts in order, and what it says of the model and the context.
    private static func readOpenCodeStep(_ body: [String: Any], row: [String: Any], into line: inout Line) {
        if let model = body["model"] as? [String: Any] {
            line.model = model["id"] as? String
            line.effort = model["variant"] as? String
        }
        line.agent = body["agent"] as? String
        line.modelName = row["modelName"] as? String
        line.providerName = row["providerName"] as? String
        line.contextWindow = openCodeInt(row["window"])
        // What the step sent and got: how full the context is, as OpenCode counts it.
        if let t = body["tokens"] as? [String: Any] {
            let cache = t["cache"] as? [String: Any]
            let used = [t["input"], t["output"], t["reasoning"], cache?["read"], cache?["write"]].compactMap(openCodeInt).reduce(0, +)
            if used > 0 { line.contextTokens = used }
        }
        for (i, part) in (body["content"] as? [[String: Any]] ?? []).enumerated() {
            let id = "\(line.id)/\(i)"
            switch part["type"] as? String {
            case "text":
                let text = part["text"] as? String ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    line.items.append((TranscriptItem(id: id, kind: .text(text)), nil))
                }
            case "reasoning":
                let text = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { line.items.append((TranscriptItem(id: id, kind: .thinking(text)), nil)) }
            case "tool":
                for call in openCodeCalls(part, id: id) {
                    line.items.append((TranscriptItem(id: call.id, kind: .tool(call)), nil))
                }
            default:
                continue
            }
        }
        // A stopped step (Esc, or a call refused): its turn ends here; an
        // `idle` row may follow, saying the same.
        if let error = body["error"] as? [String: Any] {
            if error["type"] as? String == "aborted" {
                line.items.append((TranscriptItem(id: line.id + "/stop", kind: .notice(.interrupted)), nil))
            } else if let message = error["message"] as? String, !message.isEmpty {
                line.items.append((TranscriptItem(id: line.id + "/error", kind: .notice(.error(message))), nil))
            }
        }
    }

    /// OpenCode's message when the person refuses a call.
    static let openCodeDeclined = "The user declined this tool call"

    /// A tool part as the calls Claude Code's would be: `shell` as Shell,
    /// `edit` as Edit with its patch, `question` as AskUserQuestion…
    static func openCodeCalls(_ part: [String: Any], id fallback: String) -> [ToolCall] {
        let id = part["id"] as? String ?? fallback
        let name = part["name"] as? String ?? "tool"
        let state = part["state"] as? [String: Any] ?? [:]
        let input = state["input"] as? [String: Any] ?? [:]
        let metadata = state["metadata"] as? [String: Any] ?? [:]
        let result = openCodeResult(state)
        func text(_ key: String) -> JSON? { (input[key] as? String).map(JSON.string) }
        func object(_ pairs: [String: JSON?]) -> JSON { .object(pairs.compactMapValues { $0 }) }
        switch name {
        case "shell", "bash":
            return [ToolCall(id: id, name: "Shell", input: object(["command": text("command"), "description": text("description"), "cwd": text("workdir")]), result: result)]
        case "read":
            return [ToolCall(id: id, name: "Read", input: object(["file_path": text("path") ?? text("filePath"), "offset": input["offset"].map(JSON.init(any:)), "limit": input["limit"].map(JSON.init(any:))]), result: result)]
        case "write":
            return [ToolCall(id: id, name: "Write", input: object(["file_path": text("path") ?? text("filePath"), "content": text("content")]), result: result)]
        case "edit", "multiedit", "patch", "apply_patch":
            // The patch OpenCode made, file by file, once done; else what it was asked.
            let files = metadata["files"] as? [[String: Any]] ?? []
            if !files.isEmpty {
                return files.enumerated().map { i, file in
                    let path = file["file"] as? String ?? file["path"] as? String ?? ""
                    let callID = files.count == 1 ? id : "\(id)#\(i)"
                    switch file["status"] as? String {
                    case "deleted":
                        return ToolCall(id: callID, name: "Delete", input: ["file_path": .string(path)], result: result)
                    default:
                        return ToolCall(id: callID, name: "Edit", input: ["file_path": .string(path), "diff": .string(file["patch"] as? String ?? "")], result: result)
                    }
                }
            }
            if let patch = input["patchText"] as? String ?? input["patch"] as? String {
                return [ToolCall(id: id, name: "Edit", input: object(["file_path": text("path"), "diff": .string(patch)]), result: result)]
            }
            return [ToolCall(id: id, name: "Edit", input: object([
                "file_path": text("path") ?? text("filePath"), "old_string": text("oldString"), "new_string": text("newString"),
            ]), result: result)]
        case "glob":
            return [ToolCall(id: id, name: "Glob", input: object(["pattern": text("pattern"), "path": text("path")]), result: result)]
        case "grep":
            return [ToolCall(id: id, name: "Grep", input: object(["pattern": text("pattern"), "path": text("path"), "glob": text("include")]), result: result)]
        case "list", "ls":
            return [ToolCall(id: id, name: "LS", input: object(["path": text("path")]), result: result)]
        case "webfetch":
            return [ToolCall(id: id, name: "WebFetch", input: object(["url": text("url")]), result: result)]
        case "websearch", "codesearch":
            return [ToolCall(id: id, name: "WebSearch", input: object(["query": text("query")]), result: result)]
        case "todowrite":
            let todos = (input["todos"] as? [[String: Any]] ?? []).map { todo -> JSON in
                // OpenCode's `cancelled` is no longer to do.
                let status = todo["status"] as? String == "cancelled" ? "completed" : todo["status"] as? String ?? "pending"
                return object(["content": (todo["content"] as? String).map(JSON.string), "status": .string(status), "id": (todo["id"] as? String).map(JSON.string)])
            }
            return [ToolCall(id: id, name: "TodoWrite", input: ["todos": .array(todos)], result: result)]
        case "task":
            return [ToolCall(id: id, name: "Task", input: object(["description": text("description"), "prompt": text("prompt"), "subagent_type": text("subagent_type")]), result: result)]
        case "question":
            let questions = (input["questions"] as? [[String: Any]] ?? []).map { q -> JSON in
                let options = (q["options"] as? [[String: Any]] ?? []).map { o in
                    object(["label": (o["label"] as? String).map(JSON.string), "description": (o["description"] as? String).map(JSON.string)])
                }
                return object([
                    "question": (q["question"] as? String).map(JSON.string), "header": (q["header"] as? String).map(JSON.string),
                    "multiSelect": .bool(q["multiple"] as? Bool ?? q["multiSelect"] as? Bool ?? false), "options": .array(options),
                ])
            }
            var answered = result
            // `answers`: each question's labels, in order.
            if answered != nil, let answers = metadata["answers"] as? [[String]] {
                let asked = (input["questions"] as? [[String: Any]] ?? []).map { $0["question"] as? String ?? "" }
                answered?.answers = zip(asked, answers).map { ToolResult.Answer(question: $0, answer: $1.joined(separator: ", ")) }
            }
            return [ToolCall(id: id, name: "AskUserQuestion", input: ["questions": .array(questions)], result: answered)]
        case "skill":
            return [ToolCall(id: id, name: "Skill", input: object(["skill": text("id") ?? text("name")]), result: result)]
        default:
            return [ToolCall(id: id, name: name, input: JSON(any: input), result: result)]
        }
    }

    /// A file part's picture: `{"type":"file","mime":"image/png","uri":"data:image/png;base64,…"}`.
    private static func openCodePicture(_ part: [String: Any]) -> TranscriptImage? {
        guard let source = part["uri"] as? String ?? part["url"] as? String ?? part["data"] as? String else { return nil }
        return TranscriptImage.from(source, mime: part["mime"] as? String ?? part["mediaType"] as? String)
    }

    /// A call's result once it is done: its text, an error, or the person's no.
    private static func openCodeResult(_ state: [String: Any]) -> ToolResult? {
        switch state["status"] as? String {
        case "completed":
            let content = state["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let images = content.filter { ($0["mime"] as? String ?? "").hasPrefix("image/") || $0["type"] as? String == "image" }
            let exit = openCodeInt((state["metadata"] as? [String: Any])?["exit"]) ?? 0
            var result = ToolResult(text: text.trimmingCharacters(in: .newlines), images: images.count, isError: exit != 0)
            result.pictures = images.compactMap(openCodePicture)
            return result
        case "error":
            let message = (state["error"] as? [String: Any])?["message"] as? String ?? state["error"] as? String ?? ""
            if let note = openCodeRefusal(message) {
                var r = ToolResult(text: "", isError: true)
                r.declined = note
                return r
            }
            return ToolResult(text: message, isError: true)
        default:
            // pending, running: not done yet.
            return nil
        }
    }

    /// The person said no: a refused call, a dismissed question (1.x
    /// starts with `Error: `). What they said to do instead, "" for
    /// nothing; nil for any other error.
    static func openCodeRefusal(_ message: String) -> String? {
        let m = message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message
        if m == openCodeDeclined || m.hasPrefix("The user dismissed this question") { return "" }
        guard m.hasPrefix("The user rejected permission") else { return nil }
        // 1.x: `… with the following feedback: <their words>`.
        guard let said = m.range(of: "following feedback:") else { return "" }
        return m[said.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func openCodeInt(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}

// MARK: - OpenCode's screen

extension ClaudeFooter {
    /// OpenCode's input box: a bar of `┃` lines, its agent line last
    /// (`Build · GLM-5.3-Flash Free OpenCode · max`; 1.x spaces them out:
    /// `Build  Big Pickle OpenCode`), the box's bottom (`╹▀▀▀…`), then a line
    /// with the folder, the context used (`16.4K (8%)`) and hints, or, while
    /// it works, its dots (`⬝⬝■■ Free usage limit reached… [retrying in 10h
    /// 31m attempt #1]  esc interrupt`). `mode` is the agent, lowercased;
    /// `effort` the variant. Nil when no input box shows, as while OpenCode
    /// asks something.
    public static func parseOpenCode(screen: String) -> ClaudeFooter? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let bottom = lines.lastIndex(where: { $0.hasPrefix("╹") && $0.contains("▀▀▀") }), bottom > 0 else { return nil }
        // The box's width, from its bottom edge: a panel beside it (OpenCode's
        // `Getting started` on a wide screen) stays out of what is typed.
        let width = lines[bottom].prefix { $0 == "╹" || $0 == "▀" }.count
        func inBox(_ line: String) -> String? {
            guard line.hasPrefix("┃") else { return nil }
            return line.prefix(max(width, 2)).dropFirst().trimmingCharacters(in: .whitespaces)
        }
        guard let agentLine = inBox(lines[bottom - 1]) else { return nil }
        let parts = agentLine.contains(" · ")
            ? agentLine.components(separatedBy: " · ")
            : agentLine.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // The agent's name is one word.
        guard parts.count >= 2, let agent = parts.first, !agent.isEmpty, !agent.contains(" ") else { return nil }
        var footer = ClaudeFooter()
        footer.mode = agent.lowercased()
        footer.model = parts[1]
        if parts.count >= 3, let variant = parts.last, !variant.contains(" ") { footer.effort = variant }
        // The text typed: the box's lines over the agent line ("Ask anything…" is its hint).
        var typed: [String] = []
        var i = bottom - 2
        while i >= 0, let text = inBox(lines[i]) {
            typed.insert(text, at: 0)
            i -= 1
        }
        let input = typed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        footer.input = input.hasPrefix("Ask anything") ? "" : input
        var status = [parts.joined(separator: " · ")]
        if bottom + 1 < lines.count {
            for part in lines[bottom + 1].components(separatedBy: "  ").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                if let first = part.unicodeScalars.first, workDots.contains(first) {
                    footer.busy = true
                    let said = String(String.UnicodeScalarView(part.unicodeScalars.drop { workDots.contains($0) || $0 == " " }))
                    if !said.isEmpty { footer.activity = openCodeActivity(said) }
                } else if part.hasPrefix("esc "), part.hasSuffix("interrupt") {
                    footer.busy = true
                } else if !part.hasPrefix("/"), !part.hasPrefix("~"), !part.hasPrefix("tab "), !part.contains("ctrl+"), !part.contains("shift+"), !part.contains("esc ") {
                    // `16.4K (8%)`, a cost: what isn't the folder or a hint.
                    status.append(part)
                }
            }
        }
        footer.statusLine = status
        return footer
    }

    /// The squares OpenCode's work dots are drawn with.
    private static let workDots: Set<Unicode.Scalar> = ["⬝", "■"]

    /// What OpenCode says beside its dots, without its own hints, the retry
    /// first: `Free usage limit reached… (click to expand) [retrying in 10h
    /// 31m attempt #1]` → `Retrying in 10h 31m (attempt 1): Free usage limit reached…`.
    static func openCodeActivity(_ text: String) -> String {
        var said = text.replacingOccurrences(of: " (click to expand)", with: "").replacingOccurrences(of: "...", with: "…")
        if let retry = said.firstMatch(of: /\s*\[retrying in ([^\]]+?) attempt #(\d+)\]\s*$/) {
            let reason = said[..<retry.range.lowerBound].trimmingCharacters(in: .whitespaces)
            said = "Retrying in \(retry.output.1) (attempt \(retry.output.2))" + (reason.isEmpty ? "" : ": " + reason)
        }
        return said
    }
}
