import Foundation

/// One thing a chat shows from a Claude Code transcript.
public struct TranscriptItem: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// What the person wrote, or sent while Claude worked.
        case prompt(String, images: Int)
        /// A slash command or a `!` shell line, and what it printed.
        case command(String, output: String?)
        /// Claude's answer, in Markdown.
        case text(String)
        /// Claude's thinking, when the transcript keeps its words.
        case thinking(String)
        case tool(ToolCall)
        case notice(Notice)
    }

    public let id: String
    public var kind: Kind
    /// When it was written, in seconds since 1970; nil when the line said nothing.
    public var time: Double?
    /// A prompt's pictures, as files; fewer than its `images` when some
    /// couldn't be kept.
    public var pictures: [TranscriptImage]

    public init(id: String, kind: Kind, time: Double? = nil, pictures: [TranscriptImage] = []) {
        self.id = id
        self.kind = kind
        self.time = time
        self.pictures = pictures
    }
}

/// A tool Claude called, and what came back once it has.
public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let input: JSON
    public var result: ToolResult?

    public init(id: String, name: String, input: JSON, result: ToolResult? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.result = result
    }

    /// The input that says most about the call: a command, a file, a pattern...
    public var summary: String {
        func field(_ key: String) -> String? {
            guard let s = input[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        func firstLine(_ s: String?) -> String? {
            s.map { $0.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? $0 }
        }
        let found: String? = switch name {
        case "Bash", "PowerShell": field("description") ?? firstLine(field("command"))
        case "Read", "Write", "Edit", "MultiEdit": field("file_path")
        case "NotebookEdit": field("notebook_path")
        case "Grep", "Glob": field("pattern")
        case "WebFetch": field("url")
        case "WebSearch", "ToolSearch": field("query")
        case "Agent", "Task": field("description") ?? firstLine(field("prompt"))
        case "Skill": field("skill")
        case "AskUserQuestion": input["questions"]?.array?.first?["question"]?.string
        case "TodoWrite": Self.todoSummary(input["todos"]?.array ?? [])
        default: nil
        }
        if let found { return found }
        for key in ["description", "command", "query", "file_path", "path", "url", "name", "pattern", "prompt", "title"] {
            if let s = firstLine(field(key)) { return s }
        }
        return Self.arguments(input)
    }

    /// Other tools' plain arguments, as Claude Code lists an MCP call's
    /// (`owner: acme, repo: app`), in key order; a lone one by its value.
    static func arguments(_ input: JSON) -> String {
        guard case .object(let fields) = input else { return "" }
        let pairs: [(key: String, value: String)] = fields.keys.sorted().compactMap { key in
            let value: String? = switch fields[key] {
            case .string(let s): s.split(separator: "\n", omittingEmptySubsequences: true).first.map { $0.trimmingCharacters(in: .whitespaces) }
            case .int(let i): String(i)
            case .double(let d): String(d)
            case .bool(let b): b ? "true" : "false"
            default: nil
            }
            guard let value, !value.isEmpty else { return nil }
            return (key, value)
        }
        if pairs.count == 1 { return pairs[0].value }
        return pairs.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    }

    /// A to-do list as one line: how far it got, and the step under way
    /// as Claude names it (`2 of 4 done · Adding a test`).
    static func todoSummary(_ todos: [JSON]) -> String? {
        guard !todos.isEmpty else { return nil }
        let done = todos.filter { $0["status"]?.string == "completed" }.count
        if done == todos.count { return todos.count == 1 ? "Done" : "All \(todos.count) done" }
        let doing = todos.first { $0["status"]?.string == "in_progress" }
        let step = doing?["activeForm"]?.string ?? doing?["content"]?.string
        return ["\(done) of \(todos.count) done", step].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A sub-agent's run (the Agent tool), as its result tells it.
public struct AgentRun: Sendable, Equatable {
    /// Its id: `subagents/agent-<id>.jsonl` beside the session's transcript holds its steps.
    public var id: String?
    /// `Explore`, `general-purpose`, one of the person's.
    public var type: String?
    public var model: String?
    /// Launched to run on its own: the result came at once.
    public var background = false
    public var toolUses: Int?
    public var milliseconds: Int?
    public var tokens: Int?

    public init(id: String? = nil, type: String? = nil, model: String? = nil, background: Bool = false, toolUses: Int? = nil, milliseconds: Int? = nil, tokens: Int? = nil) {
        self.id = id
        self.type = type
        self.model = model
        self.background = background
        self.toolUses = toolUses
        self.milliseconds = milliseconds
        self.tokens = tokens
    }
}

public struct ToolResult: Sendable, Equatable {
    /// The text, cut after `ToolResult.maxText` bytes.
    public var text: String
    /// Lines in the whole text.
    public var lines: Int
    public var images: Int
    /// The pictures, as files; fewer than `images` when some couldn't be kept.
    public var pictures: [TranscriptImage] = []
    public var isError: Bool
    /// AskUserQuestion: each question and the answer given.
    public var answers: [Answer] = []
    /// The person said no to this call: what they said to do instead ("" for nothing).
    public var declined: String?
    /// The Agent tool: how its sub-agent's run went.
    public var agent: AgentRun?
    /// A command that went on in the background (`run_in_background`, or
    /// moved there after its timeout): its task's id (`b8fs7fgjs`).
    public var backgroundTask: String?

    public struct Answer: Sendable, Equatable {
        public var question: String
        public var answer: String

        public init(question: String, answer: String) {
            self.question = question
            self.answer = answer
        }
    }

    public static let maxText = 20_000

    public init(text: String, images: Int = 0, isError: Bool = false) {
        var text = text
        let utf8 = text.utf8
        lines = utf8.isEmpty ? 0 : utf8.reduce(into: 1) { n, b in if b == 0x0A { n += 1 } }
        if utf8.count > Self.maxText {
            // Cut on a character's first byte.
            var end = utf8.index(utf8.startIndex, offsetBy: Self.maxText)
            while end > utf8.startIndex, utf8[end] & 0xC0 == 0x80 { end = utf8.index(before: end) }
            text = String(decoding: utf8[..<end], as: UTF8.self) + "…"
        }
        self.text = text
        self.images = images
        self.isError = isError
    }
}

/// Something that happened in the session, outside the conversation.
public enum Notice: Sendable, Equatable {
    /// The conversation was compacted; the summary, once it comes.
    case compacted(summary: String?)
    case interrupted
    /// A background task ended (`<task-notification>`): a command, or a
    /// sub-agent's run (its call's id in `toolUse`), how long it took and
    /// what it found.
    case task(id: String, status: String, summary: String, milliseconds: Int? = nil, result: String? = nil, toolUse: String? = nil)
    /// A message from another agent (a sub-agent's report, a peer session).
    case message(from: String, text: String)
    case error(String)
    case info(String)
    /// A turn took this long.
    case turnEnded(milliseconds: Int)
    /// `/goal`: Claude stopped and its goal was checked.
    case goal(GoalStatus)
    /// A Stop hook sent Claude back to work, and what it said.
    case hookFeedback(String)
    /// ⌃X ⌃K twice: Claude Code stopped every sub-agent running in the
    /// background. Not shown: the line naming each one shows.
    case agentsStopped
    /// OpenCode went back to before a message (its timeline's Revert,
    /// `/undo`): that many of the person's messages are out of sight, and
    /// these files were put back. `/redo` brings them back; the next
    /// message drops them.
    case reverted(messages: Int, files: [RevertedFile])
}

/// A file OpenCode put back as it was: `hello.txt`, `deleted`, +0 −1.
public struct RevertedFile: Sendable, Equatable {
    public let path: String
    /// `added`, `deleted`, `modified`.
    public let status: String
    public let additions: Int
    public let deletions: Int

    public init(path: String, status: String, additions: Int, deletions: Int) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

/// A Claude Code transcript (`<config>/projects/<folder>/<session>.jsonl`),
/// or a Codex session file (`~/.codex/sessions/…/rollout-….jsonl`), read
/// into what a chat shows. Lines come in order with `append`; older ones
/// can be added in front with `prepend`.
public struct Transcript: Sendable {
    /// Whose lines these are.
    public enum Format: Sendable, Equatable {
        case claude
        case codex
        /// Rows of OpenCode's database, as `OpenCodeStore` hands them over.
        case opencode
        /// Gemini CLI's messages, as `GeminiChat` hands them over.
        case gemini
    }

    public let format: Format
    /// A sub-agent's own transcript (`subagents/agent-<id>.jsonl`): its
    /// lines are all `isSidechain`, which a session's transcript skips.
    public let sidechain: Bool
    public private(set) var items: [TranscriptItem] = []
    public private(set) var aiTitle: String?
    public private(set) var customTitle: String?
    /// Prompts typed while Claude worked, not taken yet.
    public private(set) var queued: [String] = []
    /// The model, effort, context, mode and branch the lines tell of.
    public private(set) var facts = SessionFacts()

    /// Tool call id → its item's index.
    private var tools: [String: Int] = [:]
    /// Results whose call isn't loaded.
    private var loose: [String: ToolResult] = [:]
    /// Notices already shown (a task's or a message's), which come twice.
    private var shown: Set<String> = []
    /// Item index → its notice's key in `shown`.
    private var noticeKeys: [Int: String] = [:]
    /// Line uuid → how many items there were once it was read: where the
    /// conversation stood after it (Claude's lines), to go back there.
    private var after: [String: Int] = [:]
    /// "Summarize from here" summaries: the line before the first message
    /// summarized, and where the summary's line came (items before it).
    private var summaries: [(tail: String, end: Int)] = []
    /// A `/model` or `/effort` waiting for what it printed: it shows only
    /// when that isn't the change itself (an error, a warning).
    private var heldSetting: TranscriptItem?

    public init(format: Format = .claude, sidechain: Bool = false) {
        self.format = format
        self.sidechain = sidechain
    }

    /// The title the person gave (/rename), else Claude's.
    public var title: String? { customTitle ?? aiTitle }

    public mutating func append(_ lines: some Sequence<Data>) {
        for line in lines {
            let read = switch format {
            case .claude: Self.read(line, sidechain: sidechain)
            case .codex: Self.readCodex(line)
            case .opencode: Self.readOpenCode(line)
            case .gemini: Self.readGemini(line)
            }
            if let read { apply(read) }
            if format == .claude, let id = read?.uuid ?? Self.uuid(in: line) { after[id] = items.count }
        }
    }

    /// `lines` read into a new transcript.
    public static func parse(_ lines: some Sequence<Data>, format: Format = .claude, sidechain: Bool = false) -> Transcript {
        var t = Transcript(format: format, sidechain: sidechain)
        t.append(lines)
        return t
    }

    /// Lines from before everything read so far.
    public mutating func prepend(_ lines: some Sequence<Data>) {
        prepend(Transcript.parse(lines, format: format, sidechain: sidechain))
    }

    /// A transcript of the lines before this one's.
    public mutating func prepend(_ older: Transcript) {
        var merged = Transcript(format: format)
        merged.aiTitle = aiTitle ?? older.aiTitle
        merged.customTitle = customTitle ?? older.customTitle
        merged.queued = queued
        merged.heldSetting = heldSetting
        merged.facts = facts.over(older.facts)
        // Each side's item index → where it lands in the merged list.
        var olderAt: [Int] = []
        for (i, item) in older.items.enumerated() {
            olderAt.append(merged.items.count)
            if let key = older.noticeKeys[i], shown.contains(key) { continue }
            merged.add(item, key: older.noticeKeys[i])
        }
        olderAt.append(merged.items.count)
        // This side's results for calls the older lines brought.
        for (id, result) in loose { merged.attach(result, to: id) }
        var newerAt: [Int] = []
        for (i, item) in items.enumerated() {
            newerAt.append(merged.items.count)
            merged.add(item, key: noticeKeys[i])
        }
        newerAt.append(merged.items.count)
        for (id, result) in older.loose where merged.tools[id] == nil { merged.loose[id] = result }
        for (id, n) in older.after { merged.after[id] = olderAt[n] }
        for (id, n) in after { merged.after[id] = newerAt[n] }
        merged.summaries = older.summaries.map { ($0.tail, olderAt[$0.end]) } + summaries.map { ($0.tail, newerAt[$0.end]) }
        self = merged
    }

    /// Forgets the items from `cut` on: a branch Claude left.
    private mutating func drop(from cut: Int) {
        items.removeSubrange(cut...)
        tools = tools.filter { $0.value < cut }
        for (i, key) in noticeKeys where i >= cut {
            noticeKeys[i] = nil
            shown.remove(key)
        }
        after = after.filter { $0.value <= cut }
        summaries = summaries.filter { $0.end <= cut }
    }

    /// The person's messages a "Summarize from here" replaced: Claude's
    /// /rewind no longer lists them.
    public var summarized: Set<String> {
        var out = Set<String>()
        for (tail, end) in summaries {
            guard let start = after[tail], start < end, end <= items.count else { continue }
            for item in items[start..<end] where Self.isPersons(item) { out.insert(item.id) }
        }
        return out
    }

    /// A message of the person's own: a prompt, a command.
    private static func isPersons(_ item: TranscriptItem) -> Bool {
        switch item.kind {
        case .prompt, .command: true
        default: false
        }
    }

    private static let uuidKey = Array(#""uuid":""#.utf8)

    /// A line's own uuid, found without parsing it: Claude Code's lines
    /// hold one `"uuid":"` each.
    static func uuid(in line: Data) -> String? {
        line.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress,
                  let hit = uuidKey.withUnsafeBytes({ k in memmem(base, raw.count, k.baseAddress, k.count) })
            else { return nil }
            let start = base.distance(to: UnsafeRawPointer(hit)) + uuidKey.count
            guard start + 36 < raw.count, raw[start + 36] == UInt8(ascii: "\"") else { return nil }
            return String(decoding: raw[start ..< start + 36], as: UTF8.self)
        }
    }

    // MARK: Applying lines

    private mutating func add(_ item: TranscriptItem, key: String? = nil) {
        if let key {
            guard !shown.contains(key) else { return }
            shown.insert(key)
            noticeKeys[items.count] = key
        }
        if case .tool(let call) = item.kind {
            tools[call.id] = items.count
            var item = item
            if call.result == nil, let result = loose.removeValue(forKey: call.id) {
                var call = call
                call.result = Self.named(result, for: call)
                item.kind = .tool(call)
            }
            items.append(item)
            return
        }
        items.append(item)
    }

    private mutating func attach(_ result: ToolResult, to id: String) {
        guard let i = tools[id], case .tool(var call) = items[i].kind else {
            loose[id] = result
            return
        }
        call.result = Self.named(result, for: call)
        items[i].kind = .tool(call)
    }

    /// Answers given by question id (Codex's): with the questions' words,
    /// which the rows match them by.
    static func named(_ result: ToolResult, for call: ToolCall) -> ToolResult {
        guard !result.answers.isEmpty, let asked = call.input["questions"]?.array else { return result }
        var words: [String: String] = [:]
        for q in asked {
            if let key = q["id"]?.string, let text = q["question"]?.string { words[key] = text }
        }
        guard !words.isEmpty else { return result }
        var named = result
        named.answers = result.answers.map { a in words[a.question].map { ToolResult.Answer(question: $0, answer: a.answer) } ?? a }
        return named
    }

    private mutating func apply(_ line: Line) {
        // A message of the person's that follows an earlier line than the
        // last one: Claude went back there (/rewind), what came after is gone.
        if let parent = line.parent, let cut = after[parent], cut < items.count,
           line.items.contains(where: { Self.isPersons($0.0) }), items[cut...].contains(where: Self.isPersons) {
            drop(from: cut)
        }
        line.facts(into: &facts)
        if let tail = line.summarizedAfter { summaries.append((tail, items.count)) }
        if let t = line.aiTitle { aiTitle = t }
        if let t = line.customTitle { customTitle = t.isEmpty ? nil : t }
        switch line.queue {
        case .enqueue(let text): queued.append(text)
        case .dequeue: if !queued.isEmpty { queued.removeFirst() }
        case .remove(let text):
            if let i = queued.firstIndex(of: text) { queued.remove(at: i) }
        case .clear: queued.removeAll()
        case nil: break
        }
        for (id, result) in line.results { attach(result, to: id) }
        let held = heldSetting
        if line.output != nil || !line.items.isEmpty { heldSetting = nil }
        if let output = line.output, let held, case .command(let name, nil) = held.kind {
            // The model and effort chips show the change: no row, as in the Codex app.
            if !Self.isSettingsNote(output) {
                add(TranscriptItem(id: held.id, kind: .command(name, output: Self.output(output, of: name)), time: held.time))
            }
        } else if let output = line.output {
            // `/compact`'s command shows over the notice its summary made.
            let at = items.indices.last.map { i -> Int in
                if i > 0, case .notice(.compacted) = items[i].kind, case .command(_, nil) = items[i - 1].kind { return i - 1 }
                return i
            }
            if let last = at, case .command(let name, nil) = items[last].kind {
                items[last].kind = .command(name, output: Self.output(output, of: name))
            } else if !output.isEmpty, !Self.isSettingsNote(output, alone: true) {
                // (A change told without its command shows no more than with it.)
                add(TranscriptItem(id: line.id + "/out", kind: .notice(.info(output)), time: line.time))
            }
        }
        if let summary = line.compactSummary {
            if let last = items.indices.last, case .notice(.compacted(nil)) = items[last].kind {
                items[last].kind = .notice(.compacted(summary: summary))
            } else {
                add(TranscriptItem(id: line.id, kind: .notice(.compacted(summary: summary)), time: line.time))
            }
        }
        for (item, key) in line.items {
            var item = item
            if item.time == nil { item.time = line.time }
            if case .command(let name, nil) = item.kind, Self.isSettingsCommand(name) {
                heldSetting = item
                continue
            }
            // `/compact` comes after the summary it made: it shows first.
            if case .command(let name, nil) = item.kind, name == "/compact" || name.hasPrefix("/compact "),
               let last = items.indices.last, case .notice(.compacted) = items[last].kind {
                let notice = items[last]
                items[last] = item
                add(notice)
                continue
            }
            // A stop said once is enough.
            if item.kind == .notice(.interrupted), items.last?.kind == .notice(.interrupted) { continue }
            // An agent stopped by its name: the last Agent call so described started it.
            if case .notice(.task(let id, let status, let summary, let ms, let result, nil)) = item.kind, id.hasPrefix(Self.stoppedAgent) {
                let name = String(id.dropFirst(Self.stoppedAgent.count))
                let call = items.reversed().lazy.compactMap { i -> ToolCall? in
                    guard case .tool(let c) = i.kind, ["Agent", "Task"].contains(c.name), c.input["description"]?.string == name else { return nil }
                    return c
                }.first
                if let call { item.kind = .notice(.task(id: id, status: status, summary: summary, milliseconds: ms, result: result, toolUse: call.id)) }
            }
            // The goal's check says what the Stop hook's feedback before it said.
            if case .notice(.goal) = item.kind, let last = items.indices.last, case .notice(.hookFeedback) = items[last].kind {
                items[last].kind = item.kind
                continue
            }
            add(item, key: key)
        }
        // One end per turn: OpenCode goes idle again after a /redo, nothing new said.
        var endShown = false
        if case .notice(.turnEnded)? = items.last?.kind { endShown = true }
        if let end = line.endedAt, let start = facts.lastPromptAt, end >= start, !endShown {
            add(TranscriptItem(id: line.id + "/end", kind: .notice(.turnEnded(milliseconds: Int(((end - start) * 1000).rounded()))), time: end))
        }
    }

    /// What a command printed, less what only repeats it: `/goal <x>`
    /// prints "Goal set: <x>".
    static func output(_ output: String, of command: String) -> String {
        // The notice under it says so, and ctrl+o is the terminal's.
        if command == "/compact" || command.hasPrefix("/compact "), output.hasPrefix("Compacted") { return "" }
        if command.hasPrefix("/goal "), output.hasPrefix("Goal set:"),
           output.dropFirst(9).trimmingCharacters(in: .whitespacesAndNewlines) == command.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines) {
            return "Goal set"
        }
        return output
    }

    /// Text without the terminal's escape sequences (`\u{1b}[2m` dims).
    static func withoutEscapes(_ s: String) -> String {
        guard s.contains("\u{1b}") else { return s }
        return s.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1b}", with: "")
    }

    // MARK: Reading one line

    /// What one line brings.
    struct Line {
        enum Queue {
            case enqueue(String)
            case dequeue
            case remove(String)
            case clear
        }

        var id = ""
        /// Claude's lines: the line's uuid, and the one it follows.
        var uuid: String?
        var parent: String?
        var items: [(TranscriptItem, String?)] = []
        var results: [(String, ToolResult)] = []
        /// What the last command printed.
        var output: String?
        var compactSummary: String?
        var aiTitle: String?
        var customTitle: String?
        var queue: Queue?
        /// Seconds since 1970.
        var time: Double?
        var model: String?
        var effort: String?
        var contextTokens: Int?
        var contextWindow: Int?
        var permissionMode: String?
        var sandbox: String?
        var reviewer: String?
        var collaborationMode: String?
        var gitBranch: String?
        var cwd: String?
        var version: String?
        /// OpenCode's agent (`build`, `plan`), its model's name and context.
        var agent: String?
        var modelName: String?
        var providerName: String?
        /// A turn ended here, in seconds since 1970: it lasted since the last prompt.
        var endedAt: Double?
        /// A person's prompt starts a turn here.
        var prompted = false
        /// `/goal`: set, checked, met or cleared here.
        var goal: GoalStatus?
        /// A "Summarize from here": the last line it kept.
        var summarizedAfter: String?

        func facts(into f: inout SessionFacts) {
            if let model { f.model = model }
            if let effort { f.effort = effort }
            if let contextTokens { f.contextTokens = contextTokens }
            if let contextWindow { f.contextWindow = contextWindow }
            if let permissionMode { f.permissionMode = permissionMode }
            if let sandbox { f.sandbox = sandbox }
            if let reviewer { f.reviewer = reviewer }
            if let collaborationMode { f.collaborationMode = collaborationMode }
            if let gitBranch, !gitBranch.isEmpty { f.gitBranch = gitBranch }
            if let cwd, !cwd.isEmpty { f.cwd = cwd }
            if let version, !version.isEmpty { f.version = version }
            if let agent, !agent.isEmpty { f.agent = agent }
            if let modelName, !modelName.isEmpty { f.modelName = modelName }
            if let providerName, !providerName.isEmpty { f.providerName = providerName }
            if prompted, let time { f.lastPromptAt = time }
            if let goal { f.goal = goal }
        }
    }

    /// Lines worth parsing have one of these after a `"type":"`; the rest
    /// (hooks, API records, file history...) are skipped without parsing.
    private static let wantedTypes: [[UInt8]] = [
        "user\"", "assistant\"", "system\"", "queued_command\"", "ai-title\"", "custom-title\"", "queue-operation\"",
        "permission-mode\"", "goal_status\"",
    ].map { Array($0.utf8) }

    private static let typeKey = Array(#""type":""#.utf8)

    static func isWanted(_ line: Data) -> Bool {
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            let n = raw.count
            var i = 0
            while i < n {
                let hit = typeKey.withUnsafeBytes { k in memmem(base + i, n - i, k.baseAddress, k.count) }
                guard let hit else { return false }
                let at = base.distance(to: UnsafeRawPointer(hit)) + typeKey.count
                for name in wantedTypes where at + name.count <= n {
                    if name.withUnsafeBytes({ memcmp(base + at, $0.baseAddress, name.count) }) == 0 { return true }
                }
                i = at
            }
            return false
        }
    }

    static func read(_ data: Data, sidechain: Bool = false) -> Line? {
        guard data.count > 2, isWanted(data),
              let object = try? JSONSerialization.jsonObject(with: slim(data)) as? [String: Any]
        else { return nil }
        if object["isSidechain"] as? Bool == true, !sidechain { return nil }
        var line = Line()
        line.uuid = object["uuid"] as? String
        line.parent = object["parentUuid"] as? String
        line.id = line.uuid ?? UUID().uuidString
        if let t = object["timestamp"] as? String { line.time = seconds(iso: t) }
        line.gitBranch = object["gitBranch"] as? String
        line.cwd = object["cwd"] as? String
        line.version = object["version"] as? String
        switch object["type"] as? String {
        case "user":
            readUser(object, into: &line)
            // The mode it was sent in: newer than the last `permission-mode`
            // line once the mode changed with ⇧⇥ (Claude Code 2.1.317).
            line.permissionMode = object["permissionMode"] as? String
        case "assistant": readAssistant(object, into: &line)
        case "system": readSystem(object, into: &line)
        case "attachment": readAttachment(object, into: &line)
        case "ai-title": line.aiTitle = object["aiTitle"] as? String
        case "custom-title": line.customTitle = object["customTitle"] as? String
        case "permission-mode": line.permissionMode = object["permissionMode"] as? String
        case "queue-operation":
            let content = object["content"] as? String
            switch object["operation"] as? String {
            case "enqueue": if let content, !isSystemText(content) { line.queue = .enqueue(withoutPasteFrames(content)) }
            case "dequeue": line.queue = .dequeue
            case "remove": if let content { line.queue = .remove(withoutPasteFrames(content)) }
            case "popAll", "clear": line.queue = .clear
            default: break
            }
        default: return nil
        }
        return line
    }

    private static func readUser(_ object: [String: Any], into line: inout Line) {
        guard let message = object["message"] as? [String: Any] else { return }
        let isMeta = object["isMeta"] as? Bool ?? false
        let origin = object["origin"] as? [String: Any]
        let content = message["content"]
        if object["isCompactSummary"] as? Bool == true {
            line.compactSummary = text(of: content)
            return
        }
        if origin?["kind"] as? String == "peer" {
            let body = origin?["body"] as? String ?? text(of: content)
            let from = origin?["name"] as? String ?? origin?["from"] as? String ?? ""
            line.items.append((TranscriptItem(id: line.id, kind: .notice(.message(from: from, text: unwrapAgentMessage(body)))), "peer:" + key(body)))
            return
        }
        if origin?["kind"] as? String == "task-notification" {
            let t = text(of: content).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("<task-notification>") {
                if let (item, key) = taskNotice(t, id: line.id) { line.items.append((item, key)) }
            } else if let stopped = t.wholeMatch(of: /Background agent "(.*)" was stopped by the user\./) {
                // Claude Code's word in plain text, after ⌃X ⌃K: never the person's.
                let notice = Notice.task(id: Self.stoppedAgent + stopped.output.1, status: "stopped", summary: "Agent “\(stopped.output.1)” stopped")
                line.items.append((TranscriptItem(id: line.id, kind: .notice(notice)), "task-stopped:" + key(t)))
            } else if !t.isEmpty {
                line.items.append((TranscriptItem(id: line.id, kind: .notice(.info(t))), "task-note:" + key(t)))
            }
            return
        }
        if let s = content as? String {
            if isMeta {
                // A Stop hook that blocked: what it told Claude.
                if s.hasPrefix(Self.hookFeedback) {
                    let text = s.dropFirst(Self.hookFeedback.count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { line.items.append((TranscriptItem(id: line.id, kind: .notice(.hookFeedback(text))), nil)) }
                }
                return
            }
            readUserText(s, into: &line)
            return
        }
        guard let blocks = content as? [[String: Any]] else { return }
        var words: [String] = []
        var images = 0
        var pictures: [TranscriptImage] = []
        // AskUserQuestion's answers, beside its result.
        let structured = object["toolUseResult"] as? [String: Any]
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result":
                guard let id = block["tool_use_id"] as? String else { continue }
                var result = toolResult(block)
                if let r = structured, r["agentId"] != nil || r["totalToolUseCount"] != nil {
                    func n(_ key: String) -> Int? { (r[key] as? NSNumber)?.intValue }
                    result.agent = AgentRun(id: r["agentId"] as? String, type: r["agentType"] as? String, model: r["resolvedModel"] as? String,
                                            background: r["isAsync"] as? Bool == true || r["status"] as? String == "async_launched",
                                            toolUses: n("totalToolUseCount"), milliseconds: n("totalDurationMs"), tokens: n("totalTokens"))
                }
                if let task = structured?["backgroundTaskId"] as? String, !task.isEmpty { result.backgroundTask = task }
                if let answers = structured?["answers"] as? [String: Any] {
                    let order = (structured?["questions"] as? [[String: Any]])?.compactMap { $0["question"] as? String } ?? []
                    let keys = order.filter { answers[$0] != nil } + answers.keys.filter { !order.contains($0) }.sorted()
                    result.answers = keys.map { ToolResult.Answer(question: $0, answer: "\(answers[$0].map { "\($0)" } ?? "")") }
                }
                line.results.append((id, result))
            case "text":
                guard !isMeta, let s = block["text"] as? String else { continue }
                if s.hasPrefix("[Request interrupted by user") {
                    line.items.append((TranscriptItem(id: line.id + "/int", kind: .notice(.interrupted)), nil))
                } else if !isSystemText(s) {
                    words.append(withoutPasteFrames(s))
                }
            case "image":
                guard !isMeta else { continue }
                images += 1
                if let picture = picture(block) { pictures.append(picture) }
            default:
                break
            }
        }
        let text = words.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty || images > 0 {
            line.items.append((TranscriptItem(id: line.id, kind: .prompt(text, images: images), pictures: pictures), nil))
            line.prompted = true
        }
    }

    /// An image block's picture: `{"type":"image","source":{"type":"base64","media_type":…,"data":…}}`.
    static func picture(_ block: [String: Any]) -> TranscriptImage? {
        guard let source = block["source"] as? [String: Any] else { return nil }
        if let data = source["data"] as? String { return TranscriptImage.from(data, mime: source["media_type"] as? String) }
        if let url = source["url"] as? String, url.hasPrefix("file://") { return TranscriptImage.from(url) }
        return nil
    }

    /// `/model` or `/effort`, with or without what follows it.
    static func isSettingsCommand(_ command: String) -> Bool {
        let word = command.split(separator: " ", maxSplits: 1).first ?? ""
        return word == "/model" || word == "/effort"
    }

    /// What `/model` and `/effort` print when they did what was asked, or
    /// when the person left the menu: one line the chips under the field
    /// already show. Anything else (an error, a warning, more lines) is
    /// news. `alone`: printed with no command before it, where only the
    /// words of a change count.
    static func isSettingsNote(_ out: String, alone: Bool = false) -> Bool {
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !alone, t.isEmpty || t == "Cancelled" { return true }
        guard !t.contains("\n") else { return false }
        return ["Set model to ", "Kept model as ", "Set effort level to ", "Effort level set to auto",
                "Ultracode on (this session only)", "Ultracode off. Effort stays"].contains { t.hasPrefix($0) }
    }

    /// What `/model` and `/effort` print: the model and effort from then on,
    /// before an answer tells them.
    ///
    ///     Set model to `Opus 5.5` and saved as your default for new sessions · `max` effort for this session only
    ///     Set effort level to max (this session only): Maximum capability with deepest reasoning…
    static func readSettingsChange(_ out: String, into line: inout Line) {
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = t.firstMatch(of: /^(?:Set model to|Kept model as) `([^`]+)`/) {
            line.model = ClaudeModel.id(displayName: String(m.1))
            if let e = t.firstMatch(of: /`(\w+)` effort/) { line.effort = String(e.1) }
        } else if let m = t.firstMatch(of: /^(?:Set effort level to|Effort level set to) (\w+)/) ?? t.firstMatch(of: /; set to '(\w+)' instead/) {
            line.effort = String(m.1)
        }
    }

    private static func readUserText(_ s: String, into line: inout Line) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("<command-name>") || t.hasPrefix("<command-message>") {
            let name = tag("command-name", in: t) ?? "/" + (tag("command-message", in: t) ?? "")
            let args = tag("command-args", in: t) ?? ""
            line.items.append((TranscriptItem(id: line.id, kind: .command(args.isEmpty ? name : "\(name) \(args)", output: nil)), nil))
            // `/goal clear` ends the goal now; its mark comes a turn later.
            if name == "/goal", GoalStatus.clearWords.contains(args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                line.goal = GoalStatus(condition: "", state: .cleared)
            }
        } else if t.hasPrefix("<local-command-stdout>") || t.hasPrefix("<local-command-stderr>") {
            line.output = [tag("local-command-stdout", in: t), tag("local-command-stderr", in: t)]
                .compactMap { $0.map(withoutEscapes) }.filter { !$0.isEmpty }.joined(separator: "\n")
            if let out = tag("local-command-stdout", in: t).map(withoutEscapes) { readSettingsChange(out, into: &line) }
        } else if t.hasPrefix("<bash-input>") {
            line.items.append((TranscriptItem(id: line.id, kind: .command("! " + (tag("bash-input", in: t) ?? ""), output: nil)), nil))
        } else if t.hasPrefix("<bash-stdout>") || t.hasPrefix("<bash-stderr>") {
            line.output = [tag("bash-stdout", in: t), tag("bash-stderr", in: t)]
                .compactMap { $0.map(withoutEscapes) }.filter { !$0.isEmpty }.joined(separator: "\n")
        } else if t.hasPrefix("<task-notification>") {
            if let (item, key) = taskNotice(t, id: line.id) { line.items.append((item, key)) }
        } else if t.hasPrefix("[Request interrupted by user") {
            line.items.append((TranscriptItem(id: line.id, kind: .notice(.interrupted)), nil))
        } else if !isSystemText(t) {
            let said = withoutPasteFrames(t).trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty {
                line.items.append((TranscriptItem(id: line.id, kind: .prompt(said, images: 0)), nil))
                line.prompted = true
            }
        }
    }

    private static func readAssistant(_ object: [String: Any], into line: inout Line) {
        guard let message = object["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { return }
        let synthetic = message["model"] as? String == "<synthetic>"
        let apiError = object["isApiErrorMessage"] as? Bool == true
        if !synthetic, !apiError {
            if let model = message["model"] as? String, !model.isEmpty { line.model = model }
            if let effort = object["effort"] as? String, !effort.isEmpty { line.effort = effort }
            if let usage = message["usage"] as? [String: Any] {
                func n(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
                let sent = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
                if sent > 0 { line.contextTokens = sent }
            }
        }
        for (i, block) in blocks.enumerated() {
            let id = "\(line.id)/\(i)"
            switch block["type"] as? String {
            case "text":
                let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                if apiError {
                    line.items.append((TranscriptItem(id: id, kind: .notice(.error(t))), nil))
                } else if synthetic {
                    if t != "No response requested." { line.items.append((TranscriptItem(id: id, kind: .notice(.info(t))), nil)) }
                } else {
                    line.items.append((TranscriptItem(id: id, kind: .text(t)), nil))
                }
            case "thinking":
                let t = (block["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { line.items.append((TranscriptItem(id: id, kind: .thinking(t)), nil)) }
            case "tool_use", "server_tool_use":
                guard let callID = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"].map(JSON.init(any:)) ?? .object([:])
                line.items.append((TranscriptItem(id: id, kind: .tool(ToolCall(id: callID, name: name, input: input))), nil))
            default:
                continue
            }
        }
    }

    private static func readSystem(_ object: [String: Any], into line: inout Line) {
        let content = object["content"] as? String ?? ""
        switch object["subtype"] as? String {
        case "compact_boundary":
            line.items.append((TranscriptItem(id: line.id, kind: .notice(.compacted(summary: nil))), nil))
            // A part summarized: what came before it stays.
            let kept = (object["compactMetadata"] as? [String: Any])?["preservedSegment"] as? [String: Any]
            line.summarizedAfter = kept?["tailUuid"] as? String
        case "turn_duration":
            if let ms = object["durationMs"] as? Int {
                line.items.append((TranscriptItem(id: line.id, kind: .notice(.turnEnded(milliseconds: ms))), nil))
            }
        case "local_command":
            readUserText(content, into: &line)
        case "away_summary":
            if !content.isEmpty { line.items.append((TranscriptItem(id: line.id, kind: .notice(.info(content))), nil)) }
        case "agents_killed":
            line.items.append((TranscriptItem(id: line.id, kind: .notice(.agentsStopped)), nil))
        case "api_error":
            let error = (object["error"] as? [String: Any])?["message"] as? String
            line.items.append((TranscriptItem(id: line.id, kind: .notice(.error(error ?? content))), nil))
        default:
            if object["level"] as? String == "error", !content.isEmpty {
                line.items.append((TranscriptItem(id: line.id, kind: .notice(.error(content))), nil))
            }
        }
    }

    private static let hookFeedback = "Stop hook feedback:"

    private static func readAttachment(_ object: [String: Any], into line: inout Line) {
        guard let attachment = object["attachment"] as? [String: Any] else { return }
        if attachment["type"] as? String == "goal_status" {
            readGoal(attachment, into: &line)
            return
        }
        guard attachment["type"] as? String == "queued_command" else { return }
        var origin = attachment["origin"] as? [String: Any]
        if origin == nil, let s = attachment["origin"] as? String {
            origin = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
        }
        let prompt = attachment["prompt"]
        let text = (prompt as? String) ?? Self.text(of: prompt)
        switch origin?["kind"] as? String {
        case "peer":
            let body = origin?["body"] as? String ?? text
            let from = origin?["name"] as? String ?? origin?["from"] as? String ?? ""
            line.items.append((TranscriptItem(id: line.id, kind: .notice(.message(from: from, text: unwrapAgentMessage(body)))), "peer:" + key(body)))
        case "human", nil:
            if attachment["commandMode"] as? String == "task-notification" || text.hasPrefix("<task-notification>") {
                if let (item, key) = taskNotice(text, id: line.id) { line.items.append((item, key)) }
                return
            }
            guard attachment["commandMode"] as? String ?? "prompt" == "prompt", !isSystemText(text) else { return }
            let blocks = (prompt as? [[String: Any]] ?? []).filter { $0["type"] as? String == "image" }
            let t = withoutPasteFrames(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty || !blocks.isEmpty {
                line.items.append((TranscriptItem(id: line.id, kind: .prompt(t, images: blocks.count), pictures: blocks.compactMap(picture)), nil))
            }
        case "task-notification":
            if let (item, key) = taskNotice(text, id: line.id) { line.items.append((item, key)) }
        default:
            break
        }
    }


    /// `/goal`'s marks: set (or still on after a compaction) and cleared,
    /// which show nothing; and each check when Claude stops, which shows.
    private static func readGoal(_ a: [String: Any], into line: inout Line) {
        guard let condition = a["condition"] as? String, !condition.isEmpty else { return }
        let met = a["met"] as? Bool ?? false
        let mark = a["sentinel"] as? Bool ?? false
        let state: GoalStatus.State = mark ? (met ? .cleared : .set) : a["failed"] as? Bool == true ? .failed : met ? .met : .notMet
        var goal = GoalStatus(condition: condition, state: state)
        if let reason = (a["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty { goal.reason = reason }
        goal.turns = (a["iterations"] as? NSNumber)?.intValue
        goal.milliseconds = (a["durationMs"] as? NSNumber)?.intValue
        goal.tokens = (a["tokens"] as? NSNumber)?.intValue
        line.goal = goal
        if !mark { line.items.append((TranscriptItem(id: line.id, kind: .notice(.goal(goal))), nil)) }
    }

    // MARK: Long strings

    /// Strings longer than this many bytes are cut before a line is parsed:
    /// pictures in base64 and whole files would cost far more to parse than
    /// what a chat shows of them.
    public static let longString = 32 * 1024

    /// `line` with every string longer than `limit` bytes cut, and ended
    /// with "…". The JSON stays valid: no escape or character is split. A
    /// picture's base64 goes to a file instead (`TranscriptImage`), and its
    /// string becomes a mark naming that file.
    public static func slim(_ line: Data, limit: Int = longString) -> Data {
        guard line.count > limit else { return line }
        return line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return line }
            let n = raw.count
            var out = Data()
            var copied = 0
            var i = 0
            var changed = false
            while i < n {
                // The next string's opening quote.
                guard let q = memchr(base + i, 0x22, n - i) else { break }
                let open = base.distance(to: q.assumingMemoryBound(to: UInt8.self))
                // Its closing quote: the next one not escaped.
                var close = open + 1
                while close < n {
                    guard let c = memchr(base + close, 0x22, n - close) else { close = n; break }
                    let at = base.distance(to: c.assumingMemoryBound(to: UInt8.self))
                    var slashes = 0
                    while at - 1 - slashes > open, base[at - 1 - slashes] == 0x5C { slashes += 1 }
                    if slashes % 2 == 0 { close = at; break }
                    close = at + 1
                }
                guard close < n else { break }
                if close - open - 1 > limit,
                   let name = TranscriptImage.saved(UnsafeRawBufferPointer(start: base + open + 1, count: close - open - 1)) {
                    // A picture: saved to a file, and named in its place.
                    out.append(base + copied, count: open + 1 - copied)
                    out.append(contentsOf: Array((TranscriptImage.mark + name).utf8))
                    copied = close
                    changed = true
                } else if close - open - 1 > limit {
                    let cut = safeCut(base, from: open + 1, limit: limit)
                    out.append(base + copied, count: cut - copied)
                    out.append(contentsOf: [0xE2, 0x80, 0xA6]) // …
                    copied = close
                    changed = true
                }
                i = close + 1
            }
            guard changed else { return line }
            out.append(base + copied, count: n - copied)
            return out
        }
    }

    /// Where to cut a string that starts at `start` so it keeps at most
    /// `limit` bytes, without splitting an escape, a surrogate pair or a
    /// UTF-8 character.
    private static func safeCut(_ base: UnsafePointer<UInt8>, from start: Int, limit: Int) -> Int {
        var cut = start + limit
        // Not inside a UTF-8 character.
        while cut > start, base[cut] & 0xC0 == 0x80 { cut -= 1 }
        // Not inside an escape: find the escape that starts nearest before the cut.
        var j = cut - 1
        while j >= start, j >= cut - 12 {
            if base[j] == 0x5C {
                var slashes = 0
                while j - 1 - slashes >= start, base[j - 1 - slashes] == 0x5C { slashes += 1 }
                if slashes % 2 == 0 {
                    // An escape starts at j.
                    let length = base[j + 1] == 0x75 ? 6 : 2
                    if j + length > cut { cut = j }
                    break
                }
            }
            j -= 1
        }
        // A high surrogate (\uD800–\uDBFF) needs the escape after it.
        if cut - 6 >= start, base[cut - 6] == 0x5C, base[cut - 5] == 0x75, base[cut - 4] | 0x20 == 0x64 {
            let third = base[cut - 3] | 0x20
            if third == 0x38 || third == 0x39 || third == 0x61 || third == 0x62 {
                var slashes = 0
                while cut - 7 - slashes >= start, base[cut - 7 - slashes] == 0x5C { slashes += 1 }
                if slashes % 2 == 0 { cut -= 6 }
            }
        }
        return cut
    }

    // MARK: Pieces

    /// Text Claude Code adds for the model, never typed by a person.
    static func isSystemText(_ s: String) -> Bool {
        let t = s.drop { $0 == " " || $0 == "\n" }
        for prefix in ["<system-reminder>", "<local-command-caveat>", "<command-name>", "<command-message>", "<local-command-stdout>",
                       "<task-notification>", "<user-prompt-submit-hook>", "Caveat: The messages below were generated"]
            where t.hasPrefix(prefix)
        {
            return true
        }
        return false
    }

    private static func toolResult(_ block: [String: Any]) -> ToolResult {
        var parts: [String] = []
        var images = 0
        var pictures: [TranscriptImage] = []
        switch block["content"] {
        case let s as String:
            parts.append(s)
        case let list as [[String: Any]]:
            for x in list {
                switch x["type"] as? String {
                case "text": parts.append(x["text"] as? String ?? "")
                case "image":
                    images += 1
                    if let picture = picture(x) { pictures.append(picture) }
                case "tool_reference": if let name = x["tool_name"] as? String { parts.append(name) }
                default: break
                }
            }
        default:
            break
        }
        let text = withoutReminders(parts.joined(separator: "\n")).trimmingCharacters(in: .newlines)
        var result = ToolResult(text: text, images: images, isError: block["is_error"] as? Bool ?? false)
        result.pictures = pictures
        result.declined = declined(text)
        return result
    }

    /// The person said no to a tool call: what they said to do instead, "" for nothing.
    static func declined(_ text: String) -> String? {
        let t = text.hasPrefix("Error: ") ? String(text.dropFirst(7)) : text
        if t.hasPrefix("The user doesn't want to proceed with this tool use") {
            guard let said = t.range(of: "the user said:") else { return "" }
            return t[said.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.hasPrefix("The user doesn't want to take this action right now") || t.hasPrefix("[Request interrupted by user for tool use]") {
            return ""
        }
        return nil
    }

    /// The text of a message's content: a string, or its text blocks.
    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    /// The id of the notice that an agent was stopped, before its name.
    static let stoppedAgent = "stopped-agent:"

    private static func taskNotice(_ s: String, id: String) -> (TranscriptItem, String)? {
        guard let task = tag("task-id", in: s) else { return nil }
        let status = tag("status", in: s) ?? ""
        let summary = tag("summary", in: s) ?? ""
        let ms = tag("duration_ms", in: s).flatMap { Int($0) }
        let result = tag("result", in: s)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notice = Notice.task(id: task, status: status, summary: summary, milliseconds: ms,
                                 result: result.flatMap { $0.isEmpty ? nil : $0 }, toolUse: tag("tool-use-id", in: s))
        return (TranscriptItem(id: id, kind: .notice(notice)), "task:\(task):\(status)")
    }

    /// The report inside `<agent-message from=…>…</agent-message>`, without
    /// the frame Claude Code puts around sub-agents' reports.
    static func unwrapAgentMessage(_ s: String) -> String {
        var body = s
        if let open = body.range(of: "<agent-message"), let end = body.range(of: ">", range: open.upperBound ..< body.endIndex) {
            body = String(body[end.upperBound...])
            if let close = body.range(of: "</agent-message>", options: .backwards) { body = String(body[..<close.lowerBound]) }
        }
        if body.hasPrefix("\n[Subagent hand-back]") || body.hasPrefix("[Subagent hand-back]"),
           let start = body.range(of: "The report follows:")
        {
            body = String(body[start.upperBound...])
            // The harness indents every line of the report.
            body = body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : String($0) }
                .joined(separator: "\n")
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A short key for a long text, to tell when it comes twice.
    private static func key(_ s: String) -> String {
        "\(s.count):\(s.prefix(80))"
    }

    /// The text between `<name>` and `</name>`.
    static func tag(_ name: String, in s: String) -> String? {
        guard let open = s.range(of: "<\(name)>") else { return nil }
        let rest = s[open.upperBound...]
        guard let close = rest.range(of: "</\(name)>") else { return String(rest).trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text without `<system-reminder>` blocks.
    static func withoutReminders(_ s: String) -> String {
        guard s.contains("<system-reminder>") else { return s }
        var out = ""
        var rest = s[...]
        while let open = rest.range(of: "<system-reminder>") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "</system-reminder>", range: open.upperBound ..< rest.endIndex) else {
                rest = ""
                break
            }
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }

    /// The person's words as they sent them. Claude Code writes a long
    /// paste (`[Pasted text #1 +5 lines]` in its input box) into the
    /// transcript as `\n\n<pasted_content id="3f2a">\n…\n</pasted_content id="3f2a">\n`,
    /// and these tags typed or pasted as `<\pasted_content`, `<\/pasted_content`.
    /// Swiftr sends its field as a paste: a long message comes back framed.
    /// Without the frames and those backslashes, as `history.jsonl` gives
    /// the message back. A frame cut open (`slim`) runs to the end.
    static func withoutPasteFrames(_ s: String) -> String {
        guard s.contains("pasted_content") else { return s }
        let b = Array(s.utf8)
        let opening = Array(#"<pasted_content id=""#.utf8)
        let newline = UInt8(ascii: "\n")
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        // Copied up to `done`; the next frame looked for from `from`.
        var done = 0
        var from = 0
        while let open = b[from...].firstRange(of: opening) {
            // Claude Code's ids: four of 0-9 a-f, then `">` and a line break.
            let id = open.upperBound
            guard id + 7 <= b.count, b[id ..< id + 4].allSatisfy({ (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }),
                  b[id + 4] == UInt8(ascii: "\""), b[id + 5] == UInt8(ascii: ">"), b[id + 6] == newline
            else {
                from = id
                continue
            }
            // The two line breaks the frame puts before it.
            var start = open.lowerBound
            while start > done, open.lowerBound - start < 2, b[start - 1] == newline { start -= 1 }
            out += b[done ..< start]
            let body = id + 7
            var closing = [newline]
            closing += #"</pasted_content id=""#.utf8
            closing += b[id ..< id + 4]
            closing += #"">"#.utf8
            // From the opening tag's line break, for an empty paste.
            guard let close = b[(body - 1)...].firstRange(of: closing) else {
                out += b[body...]
                done = b.count
                break
            }
            if close.lowerBound > body { out += b[body ..< close.lowerBound] }
            // And the one after it.
            done = close.upperBound < b.count && b[close.upperBound] == newline ? close.upperBound + 1 : close.upperBound
            from = done
        }
        out += b[done...]
        return String(decoding: out, as: UTF8.self)
            .replacingOccurrences(of: #"<\/pasted_content"#, with: "</pasted_content")
            .replacingOccurrences(of: #"<\pasted_content"#, with: "<pasted_content")
    }
}

extension Data {
    /// Complete lines (each without its newline), and the bytes after the
    /// last newline, which may be a line still being written.
    public func splitLines() -> (lines: [Data], rest: Data) {
        let ranges: [Range<Int>] = withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return [] }
            var out: [Range<Int>] = []
            var start = 0
            while start < raw.count, let hit = memchr(base + start, 0x0A, raw.count - start) {
                let nl = base.distance(to: UnsafeRawPointer(hit))
                if nl > start { out.append(start ..< nl) }
                start = nl + 1
            }
            out.append(start ..< raw.count)
            return out
        }
        let lines = ranges.dropLast().map { self[(startIndex + $0.lowerBound) ..< (startIndex + $0.upperBound)] }
        let tail = ranges.last.map { self[(startIndex + $0.lowerBound) ..< (startIndex + $0.upperBound)] } ?? Data()
        return (lines, tail)
    }
}

// MARK: - Rows

/// What a chat lists: an item, or a run of tool calls and thinking between two answers.
public enum TranscriptRow: Identifiable, Sendable, Equatable {
    case item(TranscriptItem)
    case activity(id: String, items: [TranscriptItem])

    public var id: String {
        switch self {
        case .item(let item): item.id
        case .activity(let id, _): id
        }
    }

    /// Whether the tool call `id` is this row's, or one of its run's.
    public func holdsCall(_ id: String) -> Bool {
        func has(_ item: TranscriptItem) -> Bool {
            if case .tool(let call) = item.kind { return call.id == id }
            return false
        }
        switch self {
        case .item(let item): return has(item)
        case .activity(_, let items): return items.contains(where: has)
        }
    }

    /// When the row's first item was written, in seconds since 1970.
    public var time: Double? {
        switch self {
        case .item(let item): item.time
        case .activity(_, let items): items.lazy.compactMap(\.time).first
        }
    }

    /// Whether the row's words hold `query`, whatever the case and accents:
    /// what was written, the agent's text and thinking, a tool's name, what
    /// it was about and what came back, a command and its output, a notice.
    public func contains(_ query: String) -> Bool {
        guard !query.isEmpty else { return false }
        func has(_ s: String?) -> Bool {
            s?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        func holds(_ item: TranscriptItem) -> Bool {
            switch item.kind {
            case .prompt(let text, _): return has(text)
            case .command(let name, let output): return has(name) || has(output)
            case .text(let text), .thinking(let text): return has(text)
            case .tool(let call): return has(call.name) || has(call.summary) || has(call.result?.text)
            case .notice(let notice):
                switch notice {
                case .compacted(let summary): return has(summary)
                case .task(_, _, let summary, _, let result, _): return has(summary) || has(result ?? "")
                case .message(let from, let text): return has(from) || has(text)
                case .error(let text), .info(let text), .hookFeedback(let text): return has(text)
                case .goal(let goal): return has(goal.condition) || has(goal.reason)
                case .reverted(_, let files): return files.contains { has($0.path) }
                case .interrupted, .turnEnded, .agentsStopped: return false
                }
            }
        }
        switch self {
        case .item(let item): return holds(item)
        case .activity(_, let items): return items.contains(where: holds)
        }
    }

    /// The rows over which the time shows: the first with a time, then each
    /// that comes `gap` seconds or more after the row before it, or on
    /// another day.
    public static func timeMarks(_ rows: some Collection<TranscriptRow>, gap: Double = 30 * 60, calendar: Calendar = .current) -> Set<String> {
        var marks = Set<String>()
        var last: Double?
        for row in rows {
            guard let time = row.time else { continue }
            if let last {
                let day = calendar.isDate(Date(timeIntervalSince1970: time), inSameDayAs: Date(timeIntervalSince1970: last))
                if time - last >= gap || !day { marks.insert(row.id) }
            } else {
                marks.insert(row.id)
            }
            last = time
        }
        return marks
    }
}

// MARK: - Turns

/// A finished turn as the Codex app shows it: its work folded under one
/// line ("Worked for 1m 5s"), then the agent's last answer.
public struct TurnFold: Sendable, Equatable, Identifiable {
    /// The steps and the words between them, folded away; empty when the
    /// agent answered at once.
    public let rows: [TranscriptRow]
    /// The turn's last answer.
    public let answer: TranscriptRow
    /// How long the agent worked, when the transcript tells.
    public let milliseconds: Int?

    public init(rows: [TranscriptRow], answer: TranscriptRow, milliseconds: Int?) {
        self.rows = rows
        self.answer = answer
        self.milliseconds = milliseconds
    }

    public var id: String { "turn:" + answer.id }

    /// What the agent's tools showed it in this turn (a screenshot read, an
    /// image viewed), in order, each once: the Codex app shows them over
    /// the answer, out of the fold.
    public var pictures: [TranscriptImage] {
        var seen = Set<URL>()
        var found: [TranscriptImage] = []
        func add(_ item: TranscriptItem) {
            guard case .tool(let call) = item.kind, let result = call.result else { return }
            for picture in result.pictures where seen.insert(picture.url).inserted {
                found.append(picture)
            }
        }
        for row in rows {
            switch row {
            case .item(let item): add(item)
            case .activity(_, let items): items.forEach(add)
            }
        }
        return found
    }

    /// Whether row `id` is among those folded away.
    public func holds(_ id: String?) -> Bool {
        guard let id else { return false }
        return rows.contains { $0.id == id }
    }
}

/// What a chat lists once finished turns are folded.
public enum TurnPiece: Sendable, Equatable, Identifiable {
    case row(TranscriptRow)
    case turn(TurnFold)

    public var id: String {
        switch self {
        case .row(let row): row.id
        case .turn(let turn): turn.id
        }
    }
}

extension TranscriptRow {
    /// What sets the agent to work: the person's message or command, or
    /// their answer to its question or plan.
    var startsWork: Bool {
        guard case .item(let item) = self else { return false }
        switch item.kind {
        case .prompt, .command: return true
        case .tool(let call): return Transcript.standsAlone(call.name)
        default: return false
        }
    }

    private var isAnswer: Bool {
        if case .item(let item) = self, case .text = item.kind { return true }
        return false
    }

    private var notice: Notice? {
        if case .item(let item) = self, case .notice(let notice) = item.kind { return notice }
        return nil
    }

    /// The rows with each finished turn folded: what came between what set
    /// the agent to work and its last answer, when only notices follow
    /// that answer. A turn ends at the next message, or at the line saying
    /// it ended: what comes after that line is a turn of its own, which
    /// something else started (another session's message, a task that
    /// ended), shown first. A turn that ends without an answer (a question,
    /// a stop) stays open, as does the last one while the agent is on it
    /// (`openEnd`) and it hasn't ended. How long a folded turn took goes in
    /// its fold, not in a row of its own.
    public static func pieces(_ rows: some Collection<TranscriptRow>, openEnd: Bool) -> [TurnPiece] {
        let rows = Array(rows)
        var pieces: [TurnPiece] = []
        var i = 0
        // Rows before the first message: the start of the conversation isn't loaded.
        while i < rows.count, !rows[i].startsWork {
            pieces.append(.row(rows[i]))
            i += 1
        }
        while i < rows.count {
            let start = i
            var end = start + 1
            var closed = false
            while end < rows.count, !rows[end].startsWork {
                end += 1
                if case .turnEnded = rows[end - 1].notice {
                    closed = true
                    break
                }
            }
            // What started it shows: the person's message, or the notices
            // that came before the agent went back to work.
            let byPerson = rows[start].startsWork
            var body = start + 1
            if !byPerson {
                body = start
                while body < end, rows[body].notice != nil { body += 1 }
            }
            for row in rows[start ..< body] { pieces.append(.row(row)) }
            var last = end - 1
            while last >= body, rows[last].notice != nil { last -= 1 }
            if last >= body, rows[last].isAnswer, closed || !(openEnd && end == rows.count) {
                let trailing = rows[(last + 1) ..< end]
                let ended = trailing.compactMap { row -> Int? in
                    if case .turnEnded(let ms) = row.notice { return ms }
                    return nil
                }.last
                // The time a turn took counts from what started it; after an
                // answered question, from the first step after it.
                let afterQuestion = if case .item(let item) = rows[start], case .tool = item.kind { true } else { false }
                let began = afterQuestion ? rows[body].time : rows[start].time
                let worked = (afterQuestion ? nil : ended) ?? Self.milliseconds(from: began, to: rows[last].time)
                pieces.append(.turn(TurnFold(rows: Array(rows[body ..< last]), answer: rows[last], milliseconds: worked)))
                for row in trailing {
                    if case .turnEnded = row.notice { continue }
                    pieces.append(.row(row))
                }
            } else {
                for row in rows[body ..< end] { pieces.append(.row(row)) }
            }
            i = end
        }
        return pieces
    }

    private static func milliseconds(from start: Double?, to end: Double?) -> Int? {
        guard let start, let end, end >= start else { return nil }
        return Int(((end - start) * 1000).rounded())
    }
}

extension Transcript {
    /// `[Image #1] [Image #2]What colors…`: the words of a prompt sent with
    /// pictures, without the marks Claude Code and Codex (`[Image #1]`) or
    /// OpenCode (`[Image 1]`) put where they went.
    public static func withoutImageTags(_ text: String) -> String {
        text.replacing(/\[Image #?\d+\] ?/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A message another program sent with `hc send`, which wraps it:
    /// `<hc from="my-mac/ppid:15337">Reply with one word</hc>`. Its words,
    /// and who sent it (`a program on my-mac`, or the terminal it ran in).
    public static func sentWithHC(_ text: String) -> (words: String, sender: String)? {
        guard let m = text.wholeMatch(of: /\s*<hc from="([^"]*)">(.*)<\/hc>\s*/.dotMatchesNewlines()) else { return nil }
        let from = String(m.output.1)
        let words = String(m.output.2).trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = from.range(of: "/ppid:") {
            let machine = from[..<slash.lowerBound]
            return (words, machine.isEmpty ? "another program" : "a program on \(machine)")
        }
        return (words, from.isEmpty ? "another program" : from)
    }

    /// Tools shown as rows of their own, not folded with the others.
    public static func standsAlone(_ tool: String) -> Bool {
        tool == "AskUserQuestion" || tool == "ExitPlanMode"
    }

    /// The items, with each run of tool calls and thinking in one row.
    public var rows: [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var run: [TranscriptItem] = []
        func close() {
            if let first = run.first { rows.append(.activity(id: "run:" + first.id, items: run)) }
            run = []
        }
        let lastPrompt = items.lastIndex { if case .prompt = $0.kind { true } else { false } } ?? -1
        for (i, item) in items.enumerated() {
            switch item.kind {
            case .notice(.agentsStopped):
                // Each agent's own line says it.
                continue
            case .tool(let call) where call.name == "AskUserQuestion" && call.result == nil && i > lastPrompt:
                // A question waiting for its answer shows in its card, under
                // the conversation; it comes here once answered.
                continue
            case .tool(let call) where Self.standsAlone(call.name):
                // A question or a plan reads as part of the conversation.
                close()
                rows.append(.item(item))
            case .tool, .thinking:
                run.append(item)
            default:
                close()
                rows.append(.item(item))
            }
        }
        close()
        return rows
    }
}

// MARK: - Where Claude Code keeps a session

public enum ClaudeProject {
    /// The folder under `<config>/projects` for sessions started in `cwd`:
    /// every character but ASCII letters and digits becomes "-", and long
    /// names are cut and given a hash (Claude Code's own rule).
    public static func folderName(for cwd: String) -> String {
        let units = Array(cwd.utf16)
        var name = String()
        name.reserveCapacity(units.count)
        for u in units {
            let ascii = u < 128 ? UInt8(u) : 0
            let keep = (ascii >= 0x30 && ascii <= 0x39) || (ascii >= 0x41 && ascii <= 0x5A) || (ascii >= 0x61 && ascii <= 0x7A)
            name.append(keep ? Character(UnicodeScalar(ascii)) : "-")
        }
        guard units.count > 200 else { return name }
        var h: Int32 = 0
        for u in units { h = (h &<< 5) &- h &+ Int32(u) }
        return String(name.prefix(200)) + "-" + String(abs(Int64(h)), radix: 36)
    }
}
