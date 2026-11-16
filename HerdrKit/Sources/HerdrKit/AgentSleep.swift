import Foundation

/// An agent put to sleep: Swiftr quit it to give its memory back, kept its
/// tab, and starts it again on the same conversation when the person comes
/// back. As Swiftr keeps it in `sleeping-agents.json`.
public struct SleepingAgent: Codable, Sendable, Equatable {
    public var agent: ResumableAgent
    public var session: String
    /// The agent's pid when it was put to sleep: an agent in front under
    /// another pid was started since.
    public var pid: Int
    /// The terminal's `created_ms`: another value means another terminal.
    public var created: Int64?
    /// Seconds since 1970.
    public var sleptAt: Int
    /// What it was started with that a resume must keep (`keptFlags`).
    public var flags: [String]
    /// When it last worked or answered, in milliseconds since 1970: the time
    /// its row showed, which the core forgets when the agent quits.
    public var lastActive: Int64?

    public init(agent: ResumableAgent, session: String, pid: Int, created: Int64?, sleptAt: Int, flags: [String], lastActive: Int64? = nil) {
        self.lastActive = lastActive
        self.agent = agent
        self.session = session
        self.pid = pid
        self.created = created
        self.sleptAt = sleptAt
        self.flags = flags
    }

    /// Flags that say how far a Claude may act without asking, and what it
    /// is given to work with.
    static let plainFlags: Set<String> = [
        "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--strict-mcp-config", "--chrome", "--no-chrome", "--ide",
    ]
    /// The same, with one value: `--flag value` or `--flag=value`.
    static let valueFlags: Set<String> = ["--permission-mode", "--mcp-config", "--add-dir"]

    /// The flags of a Claude's start that its conversation doesn't keep.
    /// Anything else (a prompt given as an argument, above all) must not
    /// run again; the model and effort come from the conversation.
    public static func keptFlags(_ argv: [String]) -> [String] {
        var kept: [String] = []
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            i += 1
            if plainFlags.contains(arg) {
                if !kept.contains(arg) { kept.append(arg) }
            } else if valueFlags.contains(arg) {
                if i < argv.count, isFlagWord(argv[i]), !argv[i].hasPrefix("-") { kept += [arg, argv[i]] }
                i += 1
            } else if let eq = arg.firstIndex(of: "="), valueFlags.contains(String(arg[..<eq])), isFlagWord(arg) {
                kept.append(arg)
            }
        }
        return kept
    }

    /// The command that wakes it: the agent's resume command, with the
    /// session's model and effort for Claude, and the flags kept.
    public func wakeCommand(model: String? = nil, effort: String? = nil, defaultModel: String? = nil) -> String? {
        let base = agent == .claude
            ? ResumableAgent.claudeCommand(session: session, model: model, effort: effort, defaultModel: defaultModel)
            : agent.resumeCommand(session: session)
        guard var cmd = base else { return nil }
        // The file may have been written by hand: nothing a shell reads as more.
        guard flags.allSatisfy(Self.isFlagWord) else { return cmd }
        for word in flags { cmd += " " + word }
        return cmd
    }

    /// A flag or its value, a path at most: letters, digits and `-_=/.`,
    /// nothing a shell reads as more.
    static func isFlagWord(_ word: String) -> Bool {
        !word.isEmpty && word.count <= 256
            && word.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_=/.".unicodeScalars.contains($0)) }
    }

    /// Claude's screen holds its input box or a question, drawn since the
    /// wake command was typed: an older box may still stand above that line.
    public func isDrawn(_ screen: String) -> Bool {
        guard ClaudeFooter.parse(screen: screen) != nil || ScreenPrompt.parse(screen: screen) != nil else { return false }
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        guard let typed = lines.lastIndex(where: { $0.contains("--resume \(session)") }) else { return true }
        return lines[typed...].contains { ScreenPrompt.isRule($0) }
    }

    /// The time its row shows: when it last worked, else when it fell asleep.
    public var rowTime: Int64 { lastActive ?? Int64(sleptAt) * 1000 }

    /// What the terminal's foreground says of a sleeping agent.
    public enum Check: Sendable, Equatable {
        /// Still asleep: its shell waits, or the agent is still quitting.
        case asleep
        /// Another terminal has this address now.
        case otherTerminal
        /// An agent runs there again, started by the person or by Swiftr.
        case awake
    }

    public func check(agentInFront: Bool, foregroundPid: Int?, created: Int64?) -> Check {
        if let created, let mine = self.created, created != 0, mine != 0, created != mine { return .otherTerminal }
        return agentInFront && foregroundPid != pid ? .awake : .asleep
    }
}

/// When an idle agent goes to sleep by itself.
public enum SleepRules {
    /// What Swiftr knows of an agent when it decides.
    public struct Facts: Sendable {
        /// The core's word on it: `idle`, `done`, `working`, `blocked`…
        public var state: String?
        /// When it last worked, answered or was looked at.
        public var lastActive: Date
        /// Its pane is on screen.
        public var visible: Bool
        /// Words or pictures wait in its Messages field.
        public var draft: Bool
        /// Commands it started still run.
        public var runsCommands: Bool

        public init(state: String?, lastActive: Date, visible: Bool, draft: Bool, runsCommands: Bool) {
            self.state = state
            self.lastActive = lastActive
            self.visible = visible
            self.draft = draft
            self.runsCommands = runsCommands
        }
    }

    /// Idle for `after` seconds, out of sight, with nothing a sleep would lose.
    public static func sleepsNow(_ facts: Facts, after: TimeInterval, now: Date = Date()) -> Bool {
        guard after > 0, !facts.visible, !facts.draft, !facts.runsCommands else { return false }
        if let state = facts.state, state != "idle", state != "done" { return false }
        return now.timeIntervalSince(facts.lastActive) >= after
    }

    /// "3 h", "20 min", "2 d": how long it has slept.
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "a moment" }
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 60 * 24 { return "\(minutes / 60) h" }
        return "\(minutes / (60 * 24)) d"
    }
}
