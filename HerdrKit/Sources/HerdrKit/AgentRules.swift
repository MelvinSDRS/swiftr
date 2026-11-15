import Foundation

/// What to tell the person when an agent's OSC 7501 word changes: herdr-app's
/// rule (model.rs `alert`). Needing you always alerts; finishing alerts only
/// if the person wasn't looking at that agent.
public enum AgentAlert: Sendable, Equatable {
    /// Blocked or error: it waits for the person.
    case needsYou
    /// It finished while the person wasn't looking.
    case finished

    public static func on(previous: String?, next: String?, looking: Bool) -> AgentAlert? {
        func blocked(_ w: String?) -> Bool { w == "blocked" || w == "error" }
        func busy(_ w: String?) -> Bool { w == "working" || blocked(w) }
        if blocked(next), !blocked(previous) { return .needsYou }
        if busy(previous), next != nil, !busy(next), !looking { return .finished }
        return nil
    }
}

/// Claude Code's session title, as it puts it in the terminal title.
public enum ClaudeTitle {
    /// Claude's titles before the session has one of its own.
    public static let defaults: Set<String> = ["", "Claude Code"]

    /// The title without a leading status mark ("✳ Fix login" → "Fix login"),
    /// or nil when it is not a session title yet.
    public static func clean(_ title: String) -> String? {
        // Gemini's title says whether it is ready or at work, not what about.
        if GeminiScreen.isStatusTitle(title) { return nil }
        var s = Substring(title.trimmingCharacters(in: .whitespacesAndNewlines))
        while let c = s.unicodeScalars.first, isMark(c) {
            s = s.dropFirst().drop { $0.isWhitespace }
        }
        let out = String(s)
        return defaults.contains(out) ? nil : out
    }

    private static func isMark(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: true
        default: c == "·" || c == "•"
        }
    }

    /// Any agent's session title: the one it reports (OSC 7501 `title`), else
    /// the terminal title it set, as Claude Code does. Nil while it has none,
    /// or when the terminal title is still the shell's: a folder, user@host.
    public static func session(reported: String?, terminal: String) -> String? {
        for title in [reported ?? "", terminal] {
            guard let t = clean(title), !t.hasPrefix("/"), !t.hasPrefix("~"),
                  t.range(of: #"^[\w.-]+@[\w.-]+:"#, options: .regularExpression) == nil
            else { continue }
            return t
        }
        return nil
    }
}

/// The agents whose sessions Swiftr brings back, after ⇧⌘T or when the core
/// makes a lost terminal again: each with its own resume command. Raw values
/// are their `Programs` keys.
public enum ResumableAgent: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case opencode
    case gemini

    /// The command that brings `session` back; nil for an id that isn't safe
    /// to type into a shell.
    public func resumeCommand(session: String) -> String? {
        guard Self.isSafe(session) else { return nil }
        switch self {
        case .claude: return "claude --resume \(session)"
        // As Swiftr starts Codex (`Programs`): its session file stays its own.
        case .codex: return "codex resume --no-daemon \(session)"
        case .opencode: return "opencode --session \(session)"
        case .gemini: return "gemini --resume \(session)"
        }
    }

    /// `claude --resume <session>`, keeping the session's model when it isn't
    /// the default model's family, and its effort.
    public static func claudeCommand(session: String, model: String?, effort: String?, defaultModel: String?) -> String? {
        guard var cmd = ResumableAgent.claude.resumeCommand(session: session) else { return nil }
        if let model, isSafe(model), family(model) != family(defaultModel ?? "opus") {
            cmd += " --model \(model)"
        }
        if let effort, isSafe(effort) {
            cmd += " --effort \(effort)"
        }
        return cmd
    }

    /// The session the agent was started on, from its arguments: until it
    /// writes its own files (Claude's sessions/<pid>.json waits for its first
    /// prompt), they are the only place that says it.
    public func resumedSession(_ argv: [String]) -> String? {
        let found: String?
        switch self {
        case .claude:
            found = Self.value(of: ["--resume", "-r"], in: argv)
        case .codex:
            // `codex resume [options] <id>`: the id is a UUID or a name; only a UUID is sure.
            found = argv.firstIndex(of: "resume").flatMap { i in argv[(i + 1)...].first(where: Self.isUUID) }
        case .opencode:
            found = OpenCodeRemote.named(in: argv)
        case .gemini:
            // `--resume` also takes `latest` or a number, which don't name one session.
            found = Self.value(of: ["--resume", "-r"], in: argv).flatMap { Self.isUUID($0) ? $0 : nil }
        }
        return found.flatMap { Self.isSafe($0) ? $0 : nil }
    }

    /// The value after one of `flags`, or in `--flag=value`.
    static func value(of flags: [String], in argv: [String]) -> String? {
        for (i, arg) in argv.enumerated() {
            if flags.contains(arg), i + 1 < argv.count { return argv[i + 1] }
            for flag in flags where flag.hasPrefix("--") && arg.hasPrefix(flag + "=") {
                return String(arg.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    /// Letters, digits, `-` and `_` only: what session ids and model names
    /// are made of, and nothing a shell reads as more.
    static func isSafe(_ word: String) -> Bool {
        !word.isEmpty && word.count <= 128
            && word.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    static func isUUID(_ word: String) -> Bool {
        UUID(uuidString: word) != nil
    }

    /// opus, sonnet, haiku, fable… from a model id or alias ("claude-opus-5-5", "opus[1m]").
    static func family(_ model: String) -> String {
        let lower = model.lowercased()
        for f in ["opus", "sonnet", "haiku", "fable"] where lower.contains(f) { return f }
        return lower
    }
}

/// A terminal running an agent, as Swiftr keeps it in `agent-terminals.json`:
/// enough to tell, when a shell shows again, whether the agent quit or the
/// terminal was made again.
public struct ResumableRun: Codable, Sendable, Equatable {
    public var agent: ResumableAgent
    public var session: String
    /// The agent's pid.
    public var pid: Int
    /// The shell that started the agent.
    public var shell: Int
    /// The terminal's `created_ms`: another value means another terminal.
    public var created: Int64?

    public init(agent: ResumableAgent, session: String, pid: Int, shell: Int, created: Int64?) {
        self.agent = agent
        self.session = session
        self.pid = pid
        self.shell = shell
        self.created = created
    }

    /// Shells, by process name or program.
    public static let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "sh", "fish"]

    public enum Check: Sendable, Equatable {
        /// Not a shell in front: nothing to decide.
        case none
        /// Another terminal now has this address.
        case otherTerminal
        /// The shell that started the agent is back: the agent quit.
        case agentQuit
        /// A shell this terminal didn't have: the core made the terminal again.
        case newShell
    }

    /// What a shell in front of this terminal means.
    public func check(foregroundName: String?, foregroundProgram: String?, foregroundPid: Int?, created: Int64?) -> Check {
        guard let pid = foregroundPid,
              Self.shells.contains(foregroundName ?? "") || Self.shells.contains(foregroundProgram ?? "")
        else { return .none }
        if let created, let mine = self.created, created != 0, mine != 0, created != mine { return .otherTerminal }
        return pid == shell ? .agentQuit : .newShell
    }
}

/// A closed tab, as Swiftr keeps it in `closed-tabs.json` for ⇧⌘T.
public struct ClosedTab: Codable, Sendable, Equatable {
    /// nil: this Mac.
    public var machine: String?
    /// The space's id, qualified as addresses are (`server/sp…`).
    public var space: String?
    public var spaceName: String
    /// The tab's name; empty or a number: it had none.
    public var tab: String
    public var cwd: String?
    /// The agent session that ran in it.
    public var session: String?
    /// Whose session it is.
    public var agent: ResumableAgent?
    /// Seconds since 1970.
    public var closedAt: Int

    enum CodingKeys: String, CodingKey {
        case machine, space, tab, cwd, session, agent
        case spaceName = "space_name"
        case closedAt = "closed_at"
    }

    public init(machine: String?, space: String?, spaceName: String, tab: String, cwd: String?, session: String?, agent: ResumableAgent? = nil, closedAt: Int) {
        self.machine = machine
        self.space = space
        self.spaceName = spaceName
        self.tab = tab
        self.cwd = cwd
        self.session = session
        self.agent = agent
        self.closedAt = closedAt
    }

    // Missing values are written as null, not left out.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(machine, forKey: .machine)
        try c.encode(space, forKey: .space)
        try c.encode(spaceName, forKey: .spaceName)
        try c.encode(tab, forKey: .tab)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(session, forKey: .session)
        try c.encode(agent, forKey: .agent)
        try c.encode(closedAt, forKey: .closedAt)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try c.decodeIfPresent(String.self, forKey: .machine)
        space = try c.decodeIfPresent(String.self, forKey: .space)
        spaceName = try c.decodeIfPresent(String.self, forKey: .spaceName) ?? ""
        tab = try c.decodeIfPresent(String.self, forKey: .tab) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        // A session kept before Swiftr resumed other agents is Claude's.
        let named = try c.decodeIfPresent(String.self, forKey: .agent).flatMap(ResumableAgent.init(rawValue:))
        agent = named ?? (session == nil ? nil : .claude)
        closedAt = try c.decodeIfPresent(Int.self, forKey: .closedAt) ?? 0
    }

    /// The tab's own name, if it had one (a number is herdr-app's stand-in).
    public var ownTabName: String? {
        tab.isEmpty || tab.allSatisfy(\.isNumber) ? nil : tab
    }

    /// The space's own name, if it had one rather than its folder's.
    public var ownSpaceName: String? {
        guard !spaceName.isEmpty, spaceName != "~" else { return nil }
        if let cwd, spaceName == (cwd as NSString).lastPathComponent { return nil }
        return spaceName
    }

    /// Of the terminals of one tab that ended together, the one to bring back:
    /// the one with an agent's session, else the last one.
    public static func pick(_ group: [ClosedTab]) -> ClosedTab? {
        let withFolder = group.filter { !($0.cwd ?? "").isEmpty }
        return withFolder.first { $0.session != nil } ?? withFolder.last
    }
}
