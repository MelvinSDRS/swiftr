import Foundation

/// Codex's session files (`~/.codex/sessions/YYYY/MM/DD/rollout-….jsonl`, as
/// Codex 0.16x writes them) read into the items Claude Code's transcripts
/// give. Codex writes each item once it is done (`item_completed`): what the
/// person wrote, its answers, commands, patches, tool calls; and the turns'
/// events (`task_complete`, `turn_aborted`, `token_count`).
extension Transcript {
    /// The records worth reading, by their type near the line's start; the
    /// others (`response_item`, `world_state`, `compacted`…) say what the
    /// model saw, often at length.
    private static let codexTypes: [Data] = ["\"type\":\"event_msg\"", "\"type\":\"turn_context\"", "\"type\":\"session_meta\""].map { Data($0.utf8) }
    /// Among what the model saw, the questions Codex asks (Plan mode's
    /// `request_user_input`) and their answers: no event tells them.
    private static let responseItem = Data("\"type\":\"response_item\"".utf8)
    private static let askCall = Data("\"name\":\"request_user_input\"".utf8)
    private static let askAnswers = Data("\"output\":\"{\\\"answers\\\"".utf8)

    static func isWantedCodex(_ line: Data) -> Bool {
        let head = line.prefix(200)
        if codexTypes.contains(where: { head.range(of: $0) != nil }) { return true }
        guard head.range(of: responseItem) != nil else { return false }
        let start = line.prefix(400)
        return start.range(of: askCall) != nil || start.range(of: askAnswers) != nil
    }

    static func readCodex(_ data: Data) -> Line? {
        guard data.count > 2, isWantedCodex(data),
              let object = try? JSONSerialization.jsonObject(with: slim(data)) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        var line = Line()
        line.id = (object["ordinal"] as? NSNumber).map { "cx\($0)" } ?? UUID().uuidString
        if let t = object["timestamp"] as? String { line.time = seconds(iso: t) }
        switch object["type"] as? String {
        case "session_meta":
            line.cwd = payload["cwd"] as? String
            line.version = payload["cli_version"] as? String
            line.contextWindow = number(payload["context_window"])
            if let git = payload["git"] as? [String: Any] { line.gitBranch = git["branch"] as? String }
        case "turn_context":
            line.cwd = payload["cwd"] as? String
            line.model = payload["model"] as? String
            line.effort = payload["effort"] as? String
                ?? ((payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any])?["reasoning_effort"] as? String
            line.permissionMode = approval(payload["approval_policy"])
            line.sandbox = (payload["sandbox_policy"] as? [String: Any])?["type"] as? String
            line.reviewer = payload["approvals_reviewer"] as? String
            line.collaborationMode = (payload["collaboration_mode"] as? [String: Any])?["mode"] as? String
        case "event_msg":
            readCodexEvent(payload, into: &line)
        case "response_item":
            readCodexAsk(payload, into: &line)
        default:
            return nil
        }
        return line
    }

    /// Codex's questions (`request_user_input`) as Claude's AskUserQuestion,
    /// and their answers, which Codex gives by question id
    /// (`{"answers":{"color":{"answers":["Blue"]}}}`); `attach` puts the
    /// questions' words back on them.
    private static func readCodexAsk(_ p: [String: Any], into line: inout Line) {
        func object(_ pairs: [String: JSON?]) -> JSON { .object(pairs.compactMapValues { $0 }) }
        switch p["type"] as? String {
        case "function_call" where p["name"] as? String == "request_user_input":
            guard let id = p["call_id"] as? String,
                  let args = (p["arguments"] as? String).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
            else { return }
            let questions = (args["questions"] as? [[String: Any]] ?? []).map { q -> JSON in
                let options = (q["options"] as? [[String: Any]] ?? []).map { o in
                    object(["label": (o["label"] as? String).map(JSON.string), "description": (o["description"] as? String).map(JSON.string)])
                }
                return object([
                    "id": (q["id"] as? String).map(JSON.string), "question": (q["question"] as? String).map(JSON.string),
                    "header": (q["header"] as? String).map(JSON.string), "options": .array(options),
                ])
            }
            let call = ToolCall(id: id, name: "AskUserQuestion", input: ["questions": .array(questions)], result: nil)
            line.items.append((TranscriptItem(id: id, kind: .tool(call)), nil))
        case "function_call_output":
            guard let id = p["call_id"] as? String, let output = p["output"] as? String,
                  let o = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
                  let answers = o["answers"] as? [String: Any]
            else { return }
            var result = ToolResult(text: "")
            result.answers = answers.keys.sorted().map { key in
                let said = (answers[key] as? [String: Any])?["answers"] as? [String] ?? []
                // Words typed under an option come as `user_note: …`.
                let words = said.map { $0.hasPrefix(codexNote) ? String($0.dropFirst(codexNote.count)) : $0 }
                return ToolResult.Answer(question: key, answer: words.filter { !$0.isEmpty }.joined(separator: " — "))
            }
            line.results.append((id, result))
        default:
            break
        }
    }

    private static let codexNote = "user_note: "

    /// `on-request`, `never`…; `granular` for a policy given rule by rule.
    private static func approval(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let o = value as? [String: Any], let key = o.keys.first { return key }
        return nil
    }

    private static func number(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func readCodexEvent(_ p: [String: Any], into line: inout Line) {
        switch p["type"] as? String {
        case "item_completed":
            guard let item = p["item"] as? [String: Any] else { return }
            if let ms = number(p["started_at_ms"]) ?? number(p["completed_at_ms"]) { line.time = Double(ms) / 1000 }
            readCodexItem(item, into: &line)
        case "task_started":
            line.contextWindow = number(p["model_context_window"])
            // The turn's start, which the working line counts from: a `!`
            // command reaches the file only when it ends.
            line.prompted = true
        case "task_complete":
            let turn = p["turn_id"] as? String ?? line.id
            if let error = (p["error"] as? [String: Any])?["message"] as? String, !error.isEmpty {
                line.items.append((TranscriptItem(id: turn + "/error", kind: .notice(.error(error))), nil))
            }
            // A turn that ends without an answer (an error, a `!` command) says "done" in nothing.
            if let ms = number(p["duration_ms"]), let answer = p["last_agent_message"] as? String, !answer.isEmpty {
                line.items.append((TranscriptItem(id: turn + "/end", kind: .notice(.turnEnded(milliseconds: ms))), nil))
            }
        case "turn_aborted":
            let turn = p["turn_id"] as? String ?? line.id
            let reason = p["reason"] as? String ?? ""
            let notice: Notice = reason == "interrupted" || reason.isEmpty ? .interrupted : .info("Turn ended: \(reason)")
            line.items.append((TranscriptItem(id: turn + "/aborted", kind: .notice(notice)), nil))
        case "token_count":
            guard let info = p["info"] as? [String: Any] else { return }
            if let last = info["last_token_usage"] as? [String: Any], let total = number(last["total_tokens"]) { line.contextTokens = total }
            line.contextWindow = number(info["model_context_window"])
        case "thread_settings_applied":
            guard let s = p["thread_settings"] as? [String: Any] else { return }
            line.model = s["model"] as? String
            line.permissionMode = approval(s["approval_policy"])
            line.reviewer = s["approvals_reviewer"] as? String
        case "error":
            if let message = p["message"] as? String, !message.isEmpty {
                line.items.append((TranscriptItem(id: line.id, kind: .notice(.error(message))), nil))
            }
        default:
            break
        }
    }

    private static func readCodexItem(_ item: [String: Any], into line: inout Line) {
        let id = item["id"] as? String ?? line.id
        func add(_ kind: TranscriptItem.Kind, id: String = id, pictures: [TranscriptImage] = []) {
            line.items.append((TranscriptItem(id: id, kind: kind, pictures: pictures), nil))
        }
        switch item["type"] as? String {
        case "UserMessage":
            var texts: [String] = []
            var images = 0
            var pictures: [TranscriptImage] = []
            for part in item["content"] as? [[String: Any]] ?? [] {
                if part["type"] as? String == "text" {
                    if let t = part["text"] as? String { texts.append(t) }
                } else {
                    images += 1
                    // `{"type":"image","image_url":"data:image/png;base64,…"}`, or a file Codex was given.
                    if let url = part["image_url"] as? String ?? part["url"] as? String, let picture = TranscriptImage.from(url) {
                        pictures.append(picture)
                    } else if let path = part["path"] as? String, !path.isEmpty {
                        pictures.append(TranscriptImage(url: URL(filePath: localPath(path))))
                    }
                }
            }
            let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || images > 0 else { return }
            add(.prompt(text, images: images), pictures: pictures)
            line.prompted = true
        case "AgentMessage":
            let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.text(text)) }
        case "Reasoning":
            let words = ((item["summary_text"] as? [String] ?? []) + (item["raw_content"] as? [String] ?? []))
                .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { add(.thinking(words)) }
        case "CommandExecution" where item["source"] as? String == "user_shell":
            // `!ls`: the person's own command, as Claude Code's `!` lines show.
            let output = (item["aggregated_output"] as? String ?? "").trimmingCharacters(in: .newlines)
            add(.command("! " + codexCommand(item["command"]), output: output))
            line.prompted = true
        case "CommandExecution":
            var input: [String: JSON] = ["command": .string(codexCommand(item["command"]))]
            if let cwd = (item["cwd"] as? String).map(localPath), !cwd.isEmpty { input["cwd"] = .string(cwd) }
            let status = item["status"] as? String ?? ""
            var result: ToolResult?
            if status != "in_progress" {
                let output = item["aggregated_output"] as? String ?? item["formatted_output"] as? String ?? ""
                let exit = number(item["exit_code"]) ?? 0
                result = ToolResult(text: output.trimmingCharacters(in: .newlines), isError: status == "failed" || exit != 0)
                if status == "declined" { result?.declined = "" }
            }
            add(.tool(ToolCall(id: id, name: "Shell", input: .object(input), result: result)))
        case "FileChange":
            let status = item["status"] as? String ?? ""
            var result: ToolResult?
            if status != "in_progress" {
                result = ToolResult(text: status == "failed" ? (item["stderr"] as? String ?? "") : "", isError: status == "failed")
                if status == "declined" { result?.declined = "" }
            }
            let changes = (item["changes"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
            for (i, (path, value)) in changes.enumerated() {
                let change = value as? [String: Any] ?? [:]
                let kind = change["type"] as? String ?? "update"
                let call: ToolCall
                switch kind {
                case "add":
                    let content = change["content"] as? String ?? change["unified_diff"] as? String ?? ""
                    call = ToolCall(id: "\(id)#\(i)", name: "Write", input: ["file_path": .string(path), "content": .string(content)], result: result)
                case "delete":
                    call = ToolCall(id: "\(id)#\(i)", name: "Delete", input: ["file_path": .string(path)], result: result)
                default:
                    var input: [String: JSON] = ["file_path": .string(path), "diff": .string(change["unified_diff"] as? String ?? "")]
                    if let moved = change["move_path"] as? String { input["move_path"] = .string(moved) }
                    call = ToolCall(id: "\(id)#\(i)", name: "Edit", input: .object(input), result: result)
                }
                add(.tool(call), id: call.id)
            }
        case "McpToolCall":
            let server = item["server"] as? String ?? "mcp"
            let tool = item["tool"] as? String ?? "tool"
            let arguments = (item["arguments"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { try? JSON(data: $0) } ?? .object([:])
            let status = item["status"] as? String ?? ""
            var result: ToolResult?
            if status != "in_progress" {
                let content = ((item["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let images = content.filter { $0["type"] as? String == "image" }
                let error = (item["error"] as? [String: Any])?["message"] as? String ?? item["error"] as? String
                result = ToolResult(text: error ?? text, images: images.count, isError: status == "failed" || error != nil)
                // MCP's `{"type":"image","data":…,"mimeType":…}`.
                result?.pictures = images.compactMap { block in
                    (block["data"] as? String).flatMap { TranscriptImage.from($0, mime: block["mimeType"] as? String) }
                }
            }
            add(.tool(ToolCall(id: id, name: "mcp__\(server)__\(tool)", input: arguments, result: result)))
        case "WebSearch":
            add(.tool(ToolCall(id: id, name: "WebSearch", input: ["query": .string(item["query"] as? String ?? "")], result: ToolResult(text: ""))))
        case "Extension":
            let kind = item["kind"] as? String ?? ""
            if kind == "web.search" {
                let query = item["query"] as? String ?? ((item["action"] as? [String: Any])?["queries"] as? [String])?.first ?? ""
                add(.tool(ToolCall(id: id, name: "WebSearch", input: ["query": .string(query)], result: ToolResult(text: ""))))
            }
        case "ImageView":
            let path = (item["path"] as? String).map(localPath) ?? ""
            var result = ToolResult(text: "", images: 1)
            if !path.isEmpty { result.pictures = [TranscriptImage(url: URL(filePath: path))] }
            add(.tool(ToolCall(id: id, name: "ViewImage", input: ["file_path": .string(path)], result: result)))
        case "ContextCompaction":
            add(.notice(.compacted(summary: nil)))
        case "SubAgentActivity":
            let path = item["agent_path"] as? String ?? ""
            let name = path.split(separator: "/").last.map(String.init) ?? path
            switch item["kind"] as? String {
            case "started": add(.notice(.info("Started agent \(name)")))
            case "completed": add(.notice(.info("Agent \(name) is done")))
            default: break
            }
        case "EnteredReviewMode":
            add(.notice(.info("Review started")))
        case "ExitedReviewMode":
            add(.notice(.info("Review ended")))
        default:
            break
        }
    }

    /// `["/bin/zsh", "-lc", "git status"]` → `git status`.
    static func codexCommand(_ value: Any?) -> String {
        if let s = value as? String { return s }
        let argv = value as? [String] ?? []
        if argv.count == 3, ["-lc", "-c", "-l"].contains(argv[1]) { return argv[2] }
        return argv.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }

    /// `file:///Users/me/x` → `/Users/me/x`; a path as it is.
    static func localPath(_ s: String) -> String {
        guard s.hasPrefix("file://") else { return s }
        return URL(string: s)?.path(percentEncoded: false) ?? String(s.dropFirst(7))
    }
}

// MARK: - Codex's screen

extension ClaudeFooter {
    /// Under Codex's input (`› Ask Codex to do anything`): the status line it
    /// draws (`gpt-6-luna low · Context 100% left · …`), then its hints. Nil
    /// when the screen shows no input, as while Codex asks something.
    public static func parseCodex(screen: String) -> ClaudeFooter? {
        let lines = AgentInput.codexLines(screen)
        let filled = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        // The input: its `›` row over its other rows (`AgentInput`), else
        // the last `›` line among the last few with text.
        let input: Int
        let below: [Int]
        if let (first, under) = AgentInput.codexBounds(lines) {
            input = first
            below = filled.filter { $0 >= under }
        } else {
            guard let last = filled.suffix(8).last(where: { i in
                lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("›") && ScreenPrompt.option(lines[i]) == nil
            }) else { return nil }
            input = last
            below = filled.filter { $0 > last }
            guard below.count <= 6 else { return nil }
        }
        var footer = ClaudeFooter()
        let hints = below.map { lines[$0].trimmingCharacters(in: .whitespaces) }
        footer.browsing = hints.contains { $0.hasPrefix("Browsing transcript") }
        // The hints come last: `? for shortcuts`, `esc to …`, `tab to queue message`.
        footer.statusLine = hints.filter { line in
            !line.contains("for shortcuts") && !line.localizedCaseInsensitiveContains("esc to") && !line.hasPrefix("⚠")
                && !line.hasPrefix("Browsing transcript") && !line.hasPrefix("esc again") && !line.hasPrefix("tab to queue")
        }
        if let shown = CodexScreen.model(statusLine: footer.statusLine) {
            footer.model = shown.model
            footer.effort = shown.effort
        }
        // Codex's dim hint in an empty input reads as text; but its key
        // hints under the status line (`? for shortcuts`) show only then.
        // A draft of several lines: all its rows, one a line.
        var rows = [String(lines[input].trimmingCharacters(in: .whitespaces).dropFirst())]
        rows += lines[(input + 1) ..< max(input + 1, below.first ?? input + 1)].map { String($0) }
        footer.shown = rows.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let empty = hints.contains(where: AgentInput.codexEmptyHint)
        footer.input = empty ? "" : footer.shown
        footer.queued = queuedInputs(lines[..<input])
        footer.activity = codexActivity(lines[..<input])
        return footer
    }

    /// What Codex does now, as its screen says over the input while it
    /// works: a command running (`• Running npm test`), else the step it
    /// names in place of Working (`• Reading the tests (12s • esc to
    /// interrupt)`). Nil when idle, or when it only says Working.
    static func codexActivity(_ lines: ArraySlice<String>) -> String? {
        // The timer line, near the input; the queue's list may come between.
        guard let timer = lines.indices.reversed().prefix(40).first(where: { i in
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("• ") && t.hasSuffix("esc to interrupt)")
        }) else { return nil }
        let line = lines[timer].trimmingCharacters(in: .whitespaces).dropFirst(2)
        let step = line.range(of: " (", options: .backwards).map { String(line[..<$0.lowerBound]) } ?? String(line)
        // A command still running shows over it, its output indented under it.
        var i = timer - 1
        while i >= lines.startIndex, lines[i].trimmingCharacters(in: .whitespaces).isEmpty || lines[i].hasPrefix(" ") {
            i -= 1
        }
        if i >= lines.startIndex, lines[i].hasPrefix("• Running ") {
            return String(lines[i].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return step == "Working" || step.isEmpty ? nil : step
    }

    /// Codex's list of messages held for the turn's end, above its input:
    ///
    ///     • Queued follow-up inputs
    ///       ↳ run the tests next
    ///         and the linter
    ///         ⇧← edit last queued message
    /// The list runs down to the input; one further up is old text.
    static func queuedInputs(_ lines: ArraySlice<String>) -> [String] {
        guard let head = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("• Queued follow-up") }),
              lines.endIndex - head <= 60
        else { return [] }
        var out: [String] = []
        for line in lines[(head + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("↳") {
                out.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if t.isEmpty || t.contains("edit last queued") {
                continue
            } else if out.isEmpty || t.hasPrefix("•") || t.hasPrefix("›") || t.hasPrefix("■") {
                return []
            } else {
                out[out.count - 1] += "\n" + t
            }
        }
        return out
    }
}

/// What Codex's screen shows that its session file doesn't.
public enum CodexScreen {
    /// Commands that start a turn, open a menu or a new chat: what they
    /// print, if anything, isn't their answer.
    public static let notPrinting: Set<String> = [
        "agents", "app", "apps", "clear", "compact", "copy", "delete", "experimental", "feedback", "fork", "goal",
        "hooks", "import", "init", "keymap", "logout", "memories", "model", "new", "permissions", "pets", "plan",
        "plugins", "presets", "quit", "exit", "recap", "resume", "review", "side", "btw", "skills", "statusline",
        "subagents", "theme", "title", "usage", "warnings", "worktree",
    ]

    /// What Codex's status line says that the chips under the field don't:
    /// its parts (` · ` between them, or wide gaps) less the model and
    /// effort, the folder, the context left and the mode (`Plan mode
    /// (⇧tab to cycle)`). What the person added with /statusline stays.
    public static func statusExtras(_ lines: [String], model: String?) -> [String] {
        lines.compactMap { line in
            let parts = line.replacingOccurrences(of: #"\s+·\s+|\s{3,}"#, with: "\u{1F}", options: .regularExpression)
                .split(separator: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { part in
                    if part.isEmpty || part.hasPrefix("/") || part.hasPrefix("~") { return false }
                    if let model, !model.isEmpty, part == model || part.hasPrefix(model + " ") { return false }
                    if part.range(of: #"^(?:context )?\d+% (?:context )?(?:left|used)$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
                    return part.range(of: #"mode \(⇧tab to cycle\)$"#, options: .regularExpression) == nil
                }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// The model and effort Codex's status line starts with (`fake-1 low ·
    /// ~/x`), which a new chat's session file doesn't have yet. Nil when its
    /// first part isn't a model name: a folder, or no digit or dash in it.
    public static func model(statusLine lines: [String]) -> (model: String, effort: String?)? {
        guard let first = lines.first?.replacingOccurrences(of: #"\s+·\s+|\s{3,}"#, with: "\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}").first?.trimmingCharacters(in: .whitespaces),
            let m = first.wholeMatch(of: /([^\s~\/%][^\s%]*)(?: (none|minimal|low|medium|high|xhigh|max))?/),
            m.1.contains(where: { $0.isNumber || $0 == "-" })
        else { return nil }
        return (String(m.1), m.2.map(String.init))
    }

    /// Whether `/name …` prints its answer on Codex's screen only (`/status`, `/diff`).
    public static func prints(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/"), let name = t.dropFirst().split(whereSeparator: \.isWhitespace).first, !name.isEmpty else { return false }
        return !notPrinting.contains(name.lowercased())
    }

    /// What Codex printed for `command`: the lines under its echo (the
    /// command alone at the line's start), above the input. Nil until both show.
    public static func output(of command: String, screen: String) -> String? {
        let want = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard want.hasPrefix("/") else { return nil }
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(String.UnicodeScalarView(line.unicodeScalars.filter { !(0x2800 ... 0x28FF).contains($0.value) }))
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        // The echo: unindented, unlike the commands Codex lists on start.
        guard let echo = lines.lastIndex(where: { $0 == want || ($0.hasPrefix("/") && want.hasPrefix($0) && $0.count > 1) }) else { return nil }
        let isInput = { (line: String) in line.trimmingCharacters(in: .whitespaces).hasPrefix("›") && ScreenPrompt.option(line) == nil }
        guard let input = lines.indices.last(where: { $0 > echo && isInput(lines[$0]) }) else { return nil }
        var body = Array(lines[(echo + 1) ..< input])
        // A message or another command sent since ends what the command printed.
        if let next = body.firstIndex(where: { isInput($0) || $0.hasPrefix("/") }) { body = Array(body[..<next]) }
        while body.first?.isEmpty == true { body.removeFirst() }
        while body.last?.isEmpty == true { body.removeLast() }
        guard !body.isEmpty else { return nil }
        let indent = body.filter { !$0.isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return body.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")
    }

    /// What Codex printed back to a key (`⌥.`: "Reasoning shortcuts are
    /// unavailable for …"): the `•` lines right above its input, shown more
    /// often than in `before`. Nil when there are none, or they're the
    /// turn's own (Working…, the queue, a `!` command running).
    public static func keyReply(before: String, after: String) -> String? {
        func clean(_ screen: String) -> [String] {
            screen.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                String(String.UnicodeScalarView(line.unicodeScalars.filter { !(0x2800 ... 0x28FF).contains($0.value) }))
                    .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
        }
        let lines = clean(after)
        let isInput = { (line: String) in line.trimmingCharacters(in: .whitespaces).hasPrefix("›") && ScreenPrompt.option(line) == nil }
        guard let input = lines.lastIndex(where: isInput) else { return nil }
        var end = input - 1
        while end >= 0, lines[end].isEmpty { end -= 1 }
        var start = end
        // Lines under a `•` one are indented.
        while start >= 0, !lines[start].hasPrefix("• ") {
            guard lines[start].hasPrefix("  ") else { return nil }
            start -= 1
        }
        guard start >= 0 else { return nil }
        let first = String(lines[start].dropFirst(2))
        for turn in ["Working (", "Queued follow-up inputs", "Running ", "Conversation reverted"] where first.hasPrefix(turn) {
            return nil
        }
        guard lines.filter({ $0 == lines[start] }).count > clean(before).filter({ $0 == lines[start] }).count else { return nil }
        let rest = end > start ? lines[(start + 1) ... end].map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 } : []
        return ([first] + rest).joined(separator: "\n")
    }
}
