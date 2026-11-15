import Foundation

/// What a transcript says about its session besides the conversation: the
/// model and effort of the last answer, how full the context is, the
/// permission mode, the branch. Newer lines win.
public struct SessionFacts: Sendable, Equatable {
    /// The last answer's model id (`claude-opus-5-5`).
    public var model: String?
    /// The last answer's effort (`low` … `max`).
    public var effort: String?
    /// Tokens the last request sent: how full the context is.
    public var contextTokens: Int?
    /// The model's context, when the lines say (Codex's do).
    public var contextWindow: Int?
    /// `default`, `acceptEdits`, `plan`, `auto`, `bypassPermissions`, `dontAsk`;
    /// for Codex, when it asks: `on-request`, `never`, `untrusted`, `granular`.
    public var permissionMode: String?
    /// Codex's sandbox: `workspace-write`, `read-only`, `danger-full-access`.
    public var sandbox: String?
    /// Who answers Codex's requests: `user`, or `auto_review` (a reviewing model).
    public var reviewer: String?
    /// Codex's collaboration mode: `default` or `plan`.
    public var collaborationMode: String?
    public var gitBranch: String?
    public var cwd: String?
    /// Claude Code's version.
    public var version: String?
    /// OpenCode's agent: `build`, `plan`, or one of the person's.
    public var agent: String?
    /// The model as the agent names it (OpenCode's catalog: "GLM-5.3-Flash Free").
    public var modelName: String?
    /// Its provider, as the catalog names it ("OpenCode", "Anthropic").
    public var providerName: String?
    /// When the person last sent something, seconds since 1970.
    public var lastPromptAt: Double?
    /// The last word on `/goal`: set, checked, met or cleared.
    public var goal: GoalStatus?

    public init() {}

    /// The goal Claude works toward, if one is on.
    public var activeGoal: GoalStatus? {
        goal.flatMap { $0.isActive ? $0 : nil }
    }

    /// These facts over `older` ones: each newer value wins.
    public func over(_ older: SessionFacts) -> SessionFacts {
        var f = self
        f.model = model ?? older.model
        f.effort = effort ?? older.effort
        f.contextTokens = contextTokens ?? older.contextTokens
        f.contextWindow = contextWindow ?? older.contextWindow
        f.permissionMode = permissionMode ?? older.permissionMode
        f.sandbox = sandbox ?? older.sandbox
        f.reviewer = reviewer ?? older.reviewer
        f.collaborationMode = collaborationMode ?? older.collaborationMode
        f.gitBranch = gitBranch ?? older.gitBranch
        f.cwd = cwd ?? older.cwd
        f.version = version ?? older.version
        f.agent = agent ?? older.agent
        f.modelName = modelName ?? older.modelName
        f.providerName = providerName ?? older.providerName
        f.lastPromptAt = lastPromptAt ?? older.lastPromptAt
        f.goal = goal ?? older.goal
        return f
    }
}

/// A `/goal`: what Claude keeps working toward, and the last check of it.
/// Claude Code checks it each time Claude would stop.
public struct GoalStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Set, or still on after a compaction; not checked since.
        case set
        /// Checked: not met, so Claude goes on.
        case notMet
        case met
        /// Checked: out of reach, so the goal ends.
        case failed
        /// `/goal clear`.
        case cleared
    }

    public var condition: String
    public var state: State
    /// Why the check said so.
    public var reason: String?
    /// Once met or failed: the turns, time and tokens it took.
    public var turns: Int?
    public var milliseconds: Int?
    public var tokens: Int?

    public init(condition: String, state: State, reason: String? = nil) {
        self.condition = condition
        self.state = state
        self.reason = reason
    }

    /// Claude still works toward it.
    public var isActive: Bool { state == .set || state == .notMet }

    /// The words after `/goal` that clear it, as Claude Code takes them.
    public static let clearWords: Set<String> = ["clear", "stop", "off", "reset", "none", "cancel"]
}

/// Claude models as people name them.
public enum ClaudeModel {
    /// `claude-opus-5-5` → "Opus 5.5", `claude-sonnet-4-5-20250929` → "Sonnet 4.5",
    /// `claude-opus-5-5[1m]` → "Opus 5.5 (1M)"; other ids as they are.
    public static func displayName(_ id: String) -> String {
        var s = Substring(id)
        var suffix = ""
        if let open = s.firstIndex(of: "[") {
            let tag = s[s.index(after: open)...].prefix { $0 != "]" }
            if tag.lowercased() == "1m" { suffix = " (1M)" }
            s = s[..<open]
        }
        guard s.hasPrefix("claude-") else { return id }
        var parts = s.dropFirst(7).split(separator: "-").map(String.init)
        // A date at the end: 20250929.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, family.allSatisfy(\.isLetter) else { return id }
        let numbers = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return numbers.isEmpty ? name + suffix : "\(name) \(numbers.joined(separator: "."))" + suffix
    }

    /// A model as Claude Code names it on its screen and in what `/model`
    /// prints (`Opus 5.5`, `Opus 5.5 (1M context)`, `Default (Fable 5.2)`)
    /// as its id (`claude-opus-5-5`), as the answers name it; other names
    /// (`gpt-5.5`) as they are.
    public static func id(displayName name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespaces)
        if let inner = s.wholeMatch(of: /Default \((.+)\)/) { s = String(inner.1) }
        guard let m = s.firstMatch(of: /^(Opus|Sonnet|Haiku|Fable) (\d+)(?:\.(\d+))?(?:$| )/.ignoresCase()) else { return s }
        return "claude-\(m.1.lowercased())-\(m.2)" + (m.3.map { "-\($0)" } ?? "")
    }

    /// The model's context window, in tokens: 1M for `[1m]` ids and the
    /// Claude 5 family, else 200k. `used` past the guess means 1M.
    public static func contextWindow(_ id: String?, used: Int? = nil) -> Int {
        let big = 1_000_000
        if let used, used > 200_000 { return big }
        guard let id = id?.lowercased() else { return 200_000 }
        if id.contains("[1m]") { return big }
        let parts = id.split(separator: "-")
        if parts.count >= 3, parts[0] == "claude", let major = Int(parts[2]), major >= 5 { return big }
        return 200_000
    }
}

/// One line of the agent's to-do list (TodoWrite, or TaskCreate/TaskUpdate).
public struct TodoItem: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var id: String
    public var text: String
    /// What the agent does while on it ("Running the tests").
    public var active: String?
    public var status: Status

    public init(id: String, text: String, active: String? = nil, status: Status) {
        self.id = id
        self.text = text
        self.active = active
        self.status = status
    }
}

/// A sub-agent or a command running in the background.
public struct BackgroundJob: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case agent
        case shell
    }

    /// The call that started it.
    public var id: String
    public var kind: Kind
    /// Its description, else the command's first line.
    public var title: String
    /// The sub-agent's type (`Explore`), or the whole command.
    public var detail: String?
    /// When it started, in seconds since 1970.
    public var started: Double?
    /// The agent's or the command's task id, which its notice names.
    public var task: String?

    public init(id: String, kind: Kind, title: String, detail: String? = nil, started: Double? = nil, task: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.started = started
        self.task = task
    }
}

extension Transcript {
    /// The to-do list as the last TodoWrite left it, with the Task tools'
    /// changes after it.
    public var todos: [TodoItem] {
        var list: [TodoItem] = []
        for item in items {
            guard case .tool(let call) = item.kind else { continue }
            switch call.name {
            case "TodoWrite":
                // A call that failed (Gemini without its to-do tool) changed nothing.
                guard call.result?.isError != true else { continue }
                list = (call.input["todos"]?.array ?? []).enumerated().compactMap { i, todo in
                    guard let text = todo["content"]?.string, !text.isEmpty else { return nil }
                    let status = TodoItem.Status(rawValue: todo["status"]?.string ?? "") ?? .pending
                    return TodoItem(id: todo["id"]?.string ?? "\(i)", text: text, active: todo["activeForm"]?.string, status: status)
                }
            case "TaskCreate":
                guard let text = call.input["subject"]?.string, !text.isEmpty else { continue }
                // "Task #3 created successfully: …"
                let id = call.result.flatMap { Self.taskNumber(in: $0.text) } ?? "new-\(call.id)"
                list.append(TodoItem(id: id, text: text, active: call.input["activeForm"]?.string, status: .pending))
            case "TaskUpdate":
                guard let id = call.input["taskId"]?.string ?? call.input["taskId"]?.int.map(String.init),
                      let i = list.firstIndex(where: { $0.id == id })
                else { continue }
                if let subject = call.input["subject"]?.string, !subject.isEmpty { list[i].text = subject }
                if let active = call.input["activeForm"]?.string, !active.isEmpty { list[i].active = active }
                switch call.input["status"]?.string {
                case "deleted": list.remove(at: i)
                case let s?: if let status = TodoItem.Status(rawValue: s) { list[i].status = status }
                case nil: break
                }
            default:
                continue
            }
        }
        return list
    }

    /// What runs in the background: sub-agents launched to run on their own
    /// and commands sent there, until their notice says they ended or
    /// Claude stops them. Oldest first.
    public var backgroundJobs: [BackgroundJob] {
        var running: [BackgroundJob] = []
        var ended = Set<String>()
        for item in items {
            switch item.kind {
            case .tool(let call):
                func text(_ key: String) -> String? {
                    guard let s = call.input[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
                    return s
                }
                if let r = call.result {
                    if let run = r.agent, run.background {
                        running.append(BackgroundJob(id: call.id, kind: .agent, title: text("description") ?? "Agent",
                                                      detail: run.type ?? text("subagent_type"), started: item.time, task: run.id))
                    } else if let task = r.backgroundTask {
                        let command = text("command")
                        let first = command?.split(separator: "\n", maxSplits: 1).first.map(String.init)
                        running.append(BackgroundJob(id: call.id, kind: .shell, title: text("description") ?? first ?? "Command",
                                                      detail: command, started: item.time, task: task))
                    }
                }
                // Claude stopped one (`TaskStop`, `KillShell` before it).
                if ["TaskStop", "KillShell", "KillBash"].contains(call.name), call.result?.isError != true,
                   let id = text("task_id") ?? text("shell_id") ?? text("taskId") ?? text("id")
                {
                    ended.insert(id)
                }
            case .notice(.task(let id, _, _, _, _, let use)):
                ended.insert(id)
                if let use { ended.insert(use) }
            case .notice(.agentsStopped):
                // ⌃X ⌃K twice: every sub-agent so far, not the commands.
                for job in running where job.kind == .agent { ended.insert(job.id) }
            default:
                continue
            }
        }
        return running.filter { !ended.contains($0.id) && !($0.task.map(ended.contains) ?? false) }
    }

    /// The tool calls of the last turn with no result yet, in order: those
    /// Claude waits on, one of which may be what it asks about.
    public var openCalls: [ToolCall] {
        var out: [ToolCall] = []
        for item in items.reversed().prefix(200) {
            switch item.kind {
            case .tool(let call):
                if call.result == nil { out.insert(call, at: 0) }
            case .thinking, .text:
                continue
            case .notice(.turnEnded), .notice(.interrupted), .prompt, .command:
                return out
            case .notice:
                continue
            }
        }
        return out
    }

    /// "Task #12 created" → "12".
    static func taskNumber(in text: String) -> String? {
        guard let hash = text.firstIndex(of: "#") else { return nil }
        let digits = text[text.index(after: hash)...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// `2026-11-12T04:42:23.105Z` in seconds since 1970.
    static func seconds(iso s: String) -> Double? {
        let u = Array(s.utf8)
        guard u.count >= 19, u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54 || u[10] == 0x20, u[13] == 0x3A, u[16] == 0x3A else { return nil }
        func num(_ from: Int, _ count: Int) -> Int? {
            var n = 0
            for i in from ..< from + count {
                let d = Int(u[i]) - 48
                guard d >= 0, d <= 9 else { return nil }
                n = n * 10 + d
            }
            return n
        }
        guard let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
              (1 ... 12).contains(month), (1 ... 31).contains(day)
        else { return nil }
        var fraction = 0.0
        var i = 19
        if i < u.count, u[i] == 0x2E {
            i += 1
            var scale = 0.1
            while i < u.count, u[i] >= 0x30, u[i] <= 0x39 {
                fraction += Double(u[i] - 0x30) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < u.count, u[i] == 0x2B || u[i] == 0x2D, i + 5 < u.count + 1 {
            let sign = u[i] == 0x2B ? 1 : -1
            if let h = num(i + 1, 2) {
                let m = i + 3 < u.count && u[i + 3] == 0x3A ? num(i + 4, 2) ?? 0 : (i + 4 < u.count ? num(i + 3, 2) ?? 0 : 0)
                offset = sign * (h * 3600 + m * 60)
            }
        }
        // Days from the civil date (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Double(days * 86400 + hour * 3600 + minute * 60 + second - offset) + fraction
    }
}
