import AppKit
import Foundation
import HerdrKit
import Observation

/// Whether a Claude pane shows its terminal or its conversation.
enum PaneMode: String, Codable, CaseIterable, Identifiable {
    case terminal
    case messages

    var id: String { rawValue }
}

/// Where a running Claude keeps its session's transcript, or a Codex its
/// session file.
nonisolated struct ClaudeSession: Equatable, Sendable {
    let id: String
    let pid: Int
    /// nil: this Mac.
    let machine: String?
    /// Absolute on this Mac; from the home folder on another machine.
    let path: String
    var format: Transcript.Format = .claude
}

/// What the Messages view shows of a transcript.
nonisolated struct TranscriptSnapshot: Sendable {
    var rows: [TranscriptRow] = []
    var title: String?
    var queued: [String] = []
    var facts = SessionFacts()
    var todos: [TodoItem] = []
    /// Tool calls Claude waits on: what it asks about, when blocked.
    var openCalls: [ToolCall] = []
    /// Sub-agents and commands still running in the background.
    var background: [BackgroundJob] = []
    /// What the person wrote, oldest first: ↑ in the field brings it back.
    var history: [String] = []
    /// Messages a "Summarize from here" replaced: /rewind no longer lists them.
    var summarized: Set<String> = []
}

/// Builds the transcript off the main thread, one change after another.
private actor TranscriptBuilder {
    private var transcript = Transcript()

    private var snapshot: TranscriptSnapshot {
        var history: [String] = []
        for item in transcript.items.reversed() where history.count < 100 {
            guard case .prompt(let said, let images) = item.kind else { continue }
            let text = images > 0 ? Transcript.withoutImageTags(said) : said
            if !text.isEmpty, history.last != text { history.append(text) }
        }
        return TranscriptSnapshot(
            rows: transcript.rows, title: transcript.title, queued: transcript.queued,
            facts: transcript.facts, todos: transcript.todos, openCalls: transcript.openCalls,
            background: transcript.backgroundJobs, history: history.reversed(),
            summarized: transcript.summarized
        )
    }

    func reset(_ lines: [Data], format: Transcript.Format) -> TranscriptSnapshot {
        transcript = Transcript.parse(lines, format: format)
        return snapshot
    }

    func append(_ lines: [Data]) -> TranscriptSnapshot {
        transcript.append(lines)
        return snapshot
    }

    func prepend(_ lines: [Data]) -> TranscriptSnapshot {
        transcript.prepend(Transcript.parse(lines))
        return snapshot
    }
}

/// One terminal's Claude conversation, read from its transcript and kept up
/// to date while a pane shows it: the file is watched on this Mac, read
/// through the core every second or few on another machine.
@MainActor @Observable
final class TranscriptFeed {
    enum Phase: Equatable {
        /// Waiting for Claude in this terminal, or for its session file.
        case looking
        case loading
        case ready
        /// Claude's session has no transcript yet (nothing sent).
        case empty
    }

    let address: String
    private(set) var phase: Phase = .looking
    private(set) var rows: [TranscriptRow] = []
    private(set) var title: String?
    /// Prompts typed while Claude works, which it takes after this turn.
    private(set) var queued: [String] = []
    /// The messages Swiftr gave Codex to hold for the turn's end, whole:
    /// its screen shows each in three lines at most.
    @ObservationIgnored var codexQueuedHere: [String] = []
    private(set) var session: ClaudeSession?
    /// Nothing older to load.
    private(set) var atStart = true
    private(set) var loadingEarlier = false
    /// What Claude asks while blocked, read from its screen.
    var prompt: ScreenPrompt?
    /// The screen was read since Claude blocked (so no prompt means none was found).
    var promptRead = false
    /// Model, effort, context, mode and branch, from the transcript.
    private(set) var facts = SessionFacts()
    /// Claude's to-do list as it last left it.
    private(set) var todos: [TodoItem] = []
    /// Tool calls Claude waits on (what it asks about when blocked).
    private(set) var openCalls: [ToolCall] = []
    /// ⌃O: every step's details shown, as Claude Code's ⌃O shows them in full.
    var showsDetails = false
    /// ⌃T: the to-do list open over the field.
    var todosOpen = false

    /// A command or an agent runs and holds the turn: ⌃B can send it to the background.
    var runsInForeground: Bool {
        openCalls.contains { Self.canRunInBackground($0) && $0.result == nil }
    }

    /// Claude Code sends these to the background with ⌃B while they run.
    static func canRunInBackground(_ call: ToolCall) -> Bool {
        ["Bash", "Task", "Agent"].contains(call.name) && call.input["run_in_background"]?.bool != true
    }
    /// Sub-agents and commands the transcript says run in the background.
    private(set) var background: [BackgroundJob] = []
    /// When the agent's process started (this Mac only): what an earlier
    /// run left in the background ended with it.
    @ObservationIgnored private var processStarted: Date?
    /// What the person wrote, oldest first.
    private(set) var history: [String] = []
    /// Messages a "Summarize from here" replaced: no Rewind for them.
    private(set) var summarized: Set<String> = []
    /// What shows under Claude Code's input box: the mode, the status line.
    var footer: ClaudeFooter?
    /// The text last checked in Claude's input box, whether it was its dim
    /// suggestion, and when: a check attaches to the terminal.
    @ObservationIgnored var suggestionCheck: (text: String, dim: Bool, at: Date)?
    /// Sub-agents found by the Agent call that started them: call id → agent id.
    @ObservationIgnored var subagentIDs: [String: String] = [:]
    /// A menu of Claude Code's own on its screen while it isn't blocked
    /// (`/model`'s list, "Switch model?").
    var dialog: ScreenPrompt?
    /// Keys are being pressed on Claude's screen for the person.
    var acting = false
    /// The key that switches Claude's permission mode, from its keybindings; nil when none does.
    private(set) var modeKey: String?
    /// What went wrong answering Claude from here.
    var actionError: String?
    /// The prompt /rewind's list was asked to go back to, until its second step says how.
    @ObservationIgnored var rewindTarget: String?
    /// What the agent's input holds that the field couldn't take: a paste
    /// or a picture typed in its terminal, or words typed there while it
    /// works (Esc would stop Claude). It goes first with the next message.
    var heldInBox: String?
    /// The input shows only some of what it holds (Gemini's last 10 rows):
    /// it can't move to the field.
    var heldCut = false
    /// How many messages `send` is typing into the agent's input: there each
    /// shows a moment before the agent takes it, no draft of the person's.
    /// A question that comes right after hides the input until it's
    /// answered, and such a reading would stay over its card (`boxRead`).
    @ObservationIgnored var typingMessages = 0
    /// How many of them start a turn: Esc pressed before the turn shows
    /// stops it as soon as it began (`interrupt`).
    @ObservationIgnored var startingTurn = 0
    /// When the last of them went: its row may not show yet.
    @ObservationIgnored var turnSentAt: Date?
    /// Esc is stopping a turn, and seeing what the agent does with its
    /// message: another Esc meanwhile would act on what comes back.
    @ObservationIgnored var stopping = false
    /// Esc belongs to a turn that doesn't show as work yet, or to the stop
    /// under way (Claude Code; the other agents' Esc is as it was).
    var stopsUnseenTurn: Bool { agent == .claude && (startingTurn > 0 || stopping) }
    /// The input's words wait for the agent's turn to end, then move to the field.
    @ObservationIgnored var takeBackWhenIdle = false
    /// The field's words wait for the question the agent asks in its
    /// terminal to be answered there, then go into its input.
    @ObservationIgnored var handOffWaiting: Task<Void, Never>?
    /// Pictures the field handed to the agent's input with its words, where
    /// they show as `[Image #1]`: back in the field with the words while the
    /// input shows their marks and no other.
    var handedPictures: [HandedPicture] = []
    /// The draft is moving between the field and the agent's input.
    @ObservationIgnored var movingDraft = false
    /// Where the field's cursor is, as the field last told: UTF-16 offset,
    /// and the length of the text it was in.
    @ObservationIgnored var fieldCaret: (offset: Int, length: Int)?
    /// Where the field's cursor goes once it holds `text` (the draft taken
    /// back from the agent's input, its cursor where the agent's was).
    var caretAsk: CaretAsk?
    @ObservationIgnored var caretTick = 0
    /// Keys for the agent's own menu, pressed one after the other (`menuKey`).
    @ObservationIgnored var menuKeys: [String] = []
    @ObservationIgnored var menuDraining = false
    /// The field's Esc Esc is opening the rewind list: keys wait for it.
    @ObservationIgnored var menuOpening = false
    /// Claude Code's `/effort`, `/model` and `/resume` menus, driven from their cards.
    @ObservationIgnored lazy var menus = ClaudeMenuDriver(feed: self)
    /// The answers chosen in a question's card, by its call: they stay when
    /// the pane shows its terminal and comes back.
    var askAnswers: [String: [AskAnswer]] = [:]
    /// The card's answers are being read from Claude's screen.
    @ObservationIgnored var readingAnswers = false
    /// The card's answers as last read from the screen, with their call:
    /// OpenCode's field for one's own words, left open there, stays open
    /// when the card is still the same.
    @ObservationIgnored var answersRead: (call: String, answers: [AskAnswer])?
    /// Words typed in the field under Codex's or Gemini's question card,
    /// by the question (`cardWordsKey`): they go onto its screen when the
    /// pane shows the terminal, and come back. Gone once it asks no more.
    var cardWords: [String: String] = [:]
    /// Claude's question: the tab its screen shows as open, read from its
    /// colors, with the tab bar and question it was read for
    /// (`questionTabKey`). The last key read, whatever came of it.
    var questionTab: (key: String, index: Int)?
    @ObservationIgnored var questionTabRead: String?
    /// The option a note in `cardWords` goes with on Codex's question, by
    /// its label, when not `None of the above`: notes typed in its terminal
    /// under that option.
    var cardNoteOn: [String: String] = [:]
    /// Gemini's words as last read from its screen, by the question, and
    /// whether they were a hint of its own: each read once. Words read
    /// there and emptied in the field leave its screen too.
    @ObservationIgnored var cardWordsRead: [String: (words: String, hint: Bool)] = [:]
    /// Swiftr had Gemini draw its question's list whole (⌃O, then the
    /// cursor to the first row and back): once while it asks, as another
    /// ⌃O would scroll it again (`showWholeGeminiList`).
    @ObservationIgnored var geminiListShown = false
    /// The words an OpenCode revert put back in the field: its Restore
    /// takes them out again, if the field still holds just them.
    @ObservationIgnored var revertedWords: String?
    /// Rows of the branch a rewind left, out of sight until the transcript
    /// drops them (at the next message, which follows an earlier line).
    @ObservationIgnored private var hiddenRows: Set<String> = []
    /// Goes up when lines come at the end, so the list can follow.
    private(set) var appended = 0
    /// Goes up when older lines come in front.
    private(set) var prepended = 0
    /// Goes up each time the conversation shows, out of sight or not.
    private(set) var shows = 0
    @ObservationIgnored private(set) var lastError: String?
    /// Why the conversation can't show here, when it can't.
    private(set) var unavailable: String?

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let builder = TranscriptBuilder()
    @ObservationIgnored private var source: (any TranscriptSource)?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var stepping = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var sessionCheckedAt: Date?
    @ObservationIgnored private var openTriedAt: Date?
    @ObservationIgnored private var shownCount = 0
    @ObservationIgnored private var screenReadAt: Date?
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private(set) var lastShown = Date()

    /// The first read: about this many lines from the end, at most this many bytes.
    static let tailLines = 1500
    static let tailBytes = 48 << 20
    /// Each "older messages" read.
    static let earlierLines = 1500

    init(address: String, model: AppModel) {
        self.address = address
        self.model = model
    }

    var isShown: Bool { shownCount > 0 }

    func show() {
        shownCount += 1
        shows += 1
        lastShown = Date()
        if loop == nil { startLoop() }
        poke()
    }

    func hide() {
        shownCount = max(0, shownCount - 1)
        lastShown = Date()
        // Out of sight, nothing to look for: `show` starts the loop again.
        if shownCount == 0 {
            loop?.cancel()
            loop = nil
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        following?.cancel()
        following = nil
        watcher?.cancel()
        watcher = nil
    }

    /// The connection changed: transcripts read through the old one open again.
    func reconnected() {
        if session?.machine != nil { source = nil }
        poke()
    }

    /// Look now: Claude's status changed, it started or stopped, lines came.
    func poke() {
        guard isShown else { return }
        Task { await step() }
    }

    var record: TerminalModel? { model.store.model(address) }
    var connection: CoreConnection? { model.connection }

    /// What the Messages field holds for this terminal.
    var fieldDraft: String {
        get { model.drafts[address] ?? "" }
        set { model.drafts[address] = newValue.isEmpty ? nil : newValue }
    }

    /// The pictures that wait in the field to go with the text.
    var fieldPictures: [PendingImage] {
        get { model.draftImages[address] ?? [] }
        set { model.draftImages[address] = newValue.isEmpty ? nil : newValue }
    }

    /// The pane shows this conversation, not the terminal.
    var paneShowsMessages: Bool { model.showsMessages(address) }

    /// The agent sleeps (`AgentSleep`): its shell is in front, nothing takes its keys.
    var isAsleep: Bool { model.sleepers.isAsleep(address) }

    /// This terminal's stream in Swiftr, attached or not.
    var terminalSession: TerminalSession? { model.pool.existing(address) }

    /// The core's word on the agent. It has none for an OpenCode it can't
    /// follow (1.x, as on another machine): there its screen says, waiting
    /// while it asks, at work while its dots run.
    var status: AgentStatus? {
        if let core = record?.status { return core }
        guard followsScreen else { return nil }
        // Gemini's title says ready, at work, or waiting; its screen says for what.
        if isGemini, var s = record.flatMap({ GeminiScreen.status(title: $0.title) }) {
            if s.state == "blocked" { s.kind = prompt?.title == "Answer Questions" ? "question" : "permission" }
            if s.state == "working", s.message == nil { s.message = footer?.activity }
            return s
        }
        if prompt != nil { return AgentStatus(state: "blocked") }
        guard let footer else { return nil }
        return footer.busy ? AgentStatus(state: "working", message: footer.activity) : AgentStatus(state: "idle")
    }

    /// An OpenCode or a Gemini the core gives no status: what it asks is read from its screen.
    var followsScreen: Bool {
        guard isOpenCode || isGemini, let r = record, r.isLive, r.runsChatAgent else { return false }
        return r.status == nil
    }

    /// The agents whose conversations show here.
    enum Agent {
        case claude
        case codex
        case opencode
        case gemini
    }

    /// The agent that runs here, or whose conversation shows.
    var agent: Agent {
        if let r = record, r.runsChatAgent { return r.isCodex ? .codex : r.isOpenCode ? .opencode : r.isGemini ? .gemini : .claude }
        switch session?.format {
        case .codex: return .codex
        case .opencode: return .opencode
        case .gemini: return .gemini
        default: return .claude
        }
    }

    var isCodex: Bool { agent == .codex }
    var isOpenCode: Bool { agent == .opencode }
    var isGemini: Bool { agent == .gemini }

    /// Messages waiting for the agent: Claude Code's, from its transcript;
    /// Codex's and Gemini's, from the list over their input.
    var waiting: [String] { isCodex || isGemini ? footer?.queued ?? [] : queued }

    /// Codex browses its transcript for a message to go back to (Esc Esc).
    var codexBrowsing: Bool { isCodex && footer?.browsing == true }

    /// What still runs in the background: none once the agent quit, and
    /// none an earlier run of it left (it ended with that run).
    var runningInBackground: [BackgroundJob] {
        guard !background.isEmpty, let r = record, r.isLive, r.runsChatAgent, r.foreground?.pid == session?.pid else { return [] }
        guard let since = processStarted?.timeIntervalSince1970 else { return background }
        return background.filter { ($0.started ?? since) >= since - 5 }
    }

    /// "Claude", "Codex", "OpenCode" or "Gemini", for what the view says.
    var agentName: String {
        switch agent {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .gemini: "Gemini"
        }
    }

    /// What the agent asks, read from its screen.
    func parsePrompt(_ screen: String) -> ScreenPrompt? {
        switch agent {
        case .opencode: ScreenPrompt.parseOpenCode(screen: screen)
        case .gemini: ScreenPrompt.parseGemini(screen: screen)
        case .codex: ScreenPrompt.parse(screen: screen).map(wholeCodexList)
        case .claude: ScreenPrompt.parse(screen: screen)
        }
    }

    /// The agent's input box and what is around it, read from its screen.
    func parseFooter(_ screen: String) -> ClaudeFooter? {
        switch agent {
        case .codex: ClaudeFooter.parseCodex(screen: screen)
        case .opencode: ClaudeFooter.parseOpenCode(screen: screen)
        case .gemini: ClaudeFooter.parseGemini(screen: screen)
        case .claude: ClaudeFooter.parse(screen: screen)
        }
    }

    /// How long to wait between looks while shown.
    private var interval: Duration {
        let state = status?.state
        if state == "blocked" { return .seconds(1) }
        if session?.machine != nil { return state == "working" ? .seconds(1) : .seconds(3) }
        return .seconds(3)
    }

    private func startLoop() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isShown { await self.step() }
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    private func step() async {
        if stepping {
            again = true
            return
        }
        stepping = true
        defer { stepping = false }
        repeat {
            again = false
            await refreshSession()
            await readNew()
            await refreshScreen()
        } while again && !Task.isCancelled
    }

    // MARK: Finding the session

    private func refreshSession() async {
        guard let m = record, m.isLive, m.runsChatAgent, let fg = m.foreground else {
            // An agent asleep here: its conversation, from the session it wakes on.
            if let sleeper = model.sleepers.asleep[address], sleeper.agent == .claude, session?.id != sleeper.session {
                if let at = sessionCheckedAt, Date().timeIntervalSince(at) < 5 { return }
                sessionCheckedAt = Date()
                let id = sleeper.session
                if let url = await Task.detached(priority: .userInitiated, operation: { ClaudeWatch.transcript(of: id) }).value {
                    await open(ClaudeSession(id: id, pid: sleeper.pid, machine: nil, path: url.path))
                    return
                }
            }
            // No Claude now: keep what was read; it is shown until one comes.
            if session == nil, phase != .looking { phase = .looking }
            return
        }
        let filesHere = m.isCodex || m.isOpenCode || m.isGemini
        // Only the reader of an OpenCode on another machine says why it can't read.
        if unavailable != nil, !(m.isOpenCode && m.machine != nil) { unavailable = nil }
        let every: TimeInterval = m.machine == nil ? 5 : 15
        if let s = session, s.pid == fg.pid, let at = sessionCheckedAt, Date().timeIntervalSince(at) < every { return }
        // No session yet: look each time, so the first message's shows at once
        // (on another machine, every 3 s: each look runs a command there).
        if session == nil, filesHere, let at = sessionCheckedAt, Date().timeIntervalSince(at) < (m.machine == nil ? 1 : 3) { return }
        sessionCheckedAt = Date()
        var lookup: ClaudeSession?
        if m.isCodex {
            lookup = await Self.findCodexSession(pid: fg.pid, cwd: fg.cwd, machine: m.machine, connection: model.connection)
        } else if m.isOpenCode, let machine = m.machine {
            let found = await Self.findRemoteOpenCodeSession(pid: fg.pid, argv: fg.argv, cwd: fg.cwd, machine: machine, connection: model.connection)
            if unavailable != found.problem { unavailable = found.problem }
            lookup = found.session
        } else if m.isOpenCode {
            lookup = await Self.findOpenCodeSession(pid: fg.pid, argv: fg.argv, cwd: fg.cwd)
        } else if m.isGemini {
            lookup = await Self.findGeminiSession(pid: fg.pid, cwd: fg.cwd, machine: m.machine, connection: model.connection)
        } else {
            lookup = await Self.findSession(pid: fg.pid, machine: m.machine, connection: model.connection)
            // Resumed on the conversation shown (it slept and woke): Claude
            // writes its session file only with its first prompt.
            if lookup == nil, let s = session, s.format == .claude, s.machine == m.machine,
               ResumableAgent.claude.resumedSession(fg.argv) == s.id
            {
                lookup = ClaudeSession(id: s.id, pid: fg.pid, machine: s.machine, path: s.path)
            }
        }
        if filesHere, let found = lookup {
            if found.id == putAway { lookup = nil } else { putAway = nil }
        }
        guard let found = lookup else {
            if filesHere {
                // Codex and OpenCode write a chat with its first message (Gemini as it starts):
                // until then, a new chat, the last one's put away.
                if let s = session, s.pid != fg.pid { forget() }
                if session == nil, phase != .empty { phase = .empty }
            } else if session?.pid != fg.pid, phase != .looking {
                phase = .looking
            }
            return
        }
        // The same conversation under a new process (it slept and woke): what was read stands.
        if let s = session, source != nil, s.format == .claude, found.format == .claude,
           found.id == s.id, found.path == s.path, found.machine == s.machine, found.pid != s.pid
        {
            session = found
            processStarted = found.machine == nil ? CodexFiles.startTime(pid: found.pid) : nil
            if phase != .ready { phase = .ready }
            return
        }
        // Claude started another session (/clear, /resume), or another Claude runs.
        if found != session { await open(found) }
    }

    /// Where a Claude keeps its session: `sessions/<pid>.json` under its
    /// configuration folder, then the transcript under `projects`.
    nonisolated static func findSession(pid: Int, machine: String?, connection: CoreConnection?) async -> ClaudeSession? {
        if let machine {
            guard let c = connection,
                  let r = try? await c.call("file.read", ["on": .string(machine), "path": .string("\(ClaudeWatch.remoteConfig)/sessions/\(pid).json")]),
                  let info = r["text"]?.string.flatMap(ClaudeWatch.SessionFile.init(json:)),
                  info.id.allSatisfy({ $0.isHexDigit || $0 == "-" })
            else { return nil }
            let config = ClaudeWatch.remoteConfig
            var path = "\(config)/projects/\(ClaudeProject.folderName(for: info.cwd))/\(info.id).jsonl"
            let there = try? await c.call("file.read", ["on": .string(machine), "path": .string(path), "offset": 1, "limit": 0])
            if there == nil,
               let r = try? await c.call("machine.exec", ["on": .string(machine), "line": .string("ls -t \(config)/projects/*/\(info.id).jsonl 2>/dev/null | head -1"), "timeout": 10]),
               let out = r["stdout"]?.string.flatMap({ Data(base64Encoded: $0) }),
               case let found = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), !found.isEmpty
            {
                path = found
            }
            return ClaudeSession(id: info.id, pid: pid, machine: machine, path: path)
        }
        return await Task.detached(priority: .userInitiated) { () -> ClaudeSession? in
            guard let (info, folder) = ClaudeWatch.localSessionAndFolder(pid: pid) else { return nil }
            var url = folder.appending(path: "projects/\(ClaudeProject.folderName(for: info.cwd))/\(info.id).jsonl")
            if !FileManager.default.fileExists(atPath: url.path), let found = ClaudeWatch.transcript(of: info.id) { url = found }
            return ClaudeSession(id: info.id, pid: pid, machine: nil, path: url.path)
        }.value
    }

    /// The session file a Codex writes, on this Mac or on `machine`.
    nonisolated static func findCodexSession(pid: Int, cwd: String, machine: String?, connection: CoreConnection?) async -> ClaudeSession? {
        if let machine {
            guard let c = connection,
                  let r = try? await c.call("machine.exec", ["on": .string(machine), "line": .string(CodexFiles.remoteLookup(pid: pid, cwd: cwd)), "timeout": 10]),
                  let out = r["stdout"]?.string.flatMap({ Data(base64Encoded: $0) }),
                  case let path = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                  CodexFiles.isRollout(path)
            else { return nil }
            return ClaudeSession(id: CodexFiles.threadID(path), pid: pid, machine: machine, path: path, format: .codex)
        }
        return await Task.detached(priority: .userInitiated) { () -> ClaudeSession? in
            guard let path = CodexFiles.session(pid: pid, cwd: cwd) else { return nil }
            return ClaudeSession(id: CodexFiles.threadID(path), pid: pid, machine: nil, path: path, format: .codex)
        }.value
    }

    /// The chat file a Gemini writes, on this Mac or on `machine`: the
    /// newest in its folder's project written since it started.
    nonisolated static func findGeminiSession(pid: Int, cwd: String, machine: String?, connection: CoreConnection?) async -> ClaudeSession? {
        if let machine {
            guard let c = connection,
                  let r = try? await c.call("machine.exec", ["on": .string(machine), "line": .string(GeminiFiles.remoteLookup(pid: pid, cwd: cwd)), "timeout": 10]),
                  let out = r["stdout"]?.string.flatMap({ Data(base64Encoded: $0) }),
                  case let path = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                  path.hasSuffix(".jsonl"), path.contains("/chats/session-")
            else { return nil }
            return ClaudeSession(id: GeminiFiles.shortID(path), pid: pid, machine: machine, path: path, format: .gemini)
        }
        return await Task.detached(priority: .userInitiated) { () -> ClaudeSession? in
            guard let chats = GeminiFiles.chats(in: geminiFolder(pid: pid), cwd: cwd),
                  let url = GeminiFiles.newestChat(in: chats, since: CodexFiles.startTime(pid: pid))
            else { return nil }
            return ClaudeSession(id: GeminiFiles.shortID(url.path), pid: pid, machine: nil, path: url.path, format: .gemini)
        }.value
    }

    /// The `.gemini` folder of the Gemini running as `pid`: under its
    /// `GEMINI_CLI_HOME` when it has one, else under the home folder.
    nonisolated static func geminiFolder(pid: Int) -> URL {
        let own = LocalProcess.environment(of: pid_t(pid))["GEMINI_CLI_HOME"]
        return GeminiFiles.folder(cliHome: own ?? ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"])
    }

    /// The session an OpenCode on this Mac shows, in OpenCode's database
    /// (the session's path is the database's).
    nonisolated static func findOpenCodeSession(pid: Int, argv: [String], cwd: String) async -> ClaudeSession? {
        await Task.detached(priority: .userInitiated) { () -> ClaudeSession? in
            let db = OpenCodeStore.database
            guard let id = OpenCodeStore.session(argv: argv, directory: cwd, started: CodexFiles.startTime(pid: pid), db: db) else { return nil }
            return ClaudeSession(id: id, pid: pid, machine: nil, path: db.path, format: .opencode)
        }.value
    }

    /// The session an OpenCode on `machine` shows, read there by
    /// `OpenCodeRemote`'s program; or why it can't be read there.
    nonisolated static func findRemoteOpenCodeSession(pid: Int, argv: [String], cwd: String, machine: String, connection: CoreConnection?) async -> (session: ClaudeSession?, problem: String?) {
        guard let c = connection else { return (nil, nil) }
        let base = remoteOpenCodeBase
        if let named = OpenCodeRemote.named(in: argv) {
            return (ClaudeSession(id: named, pid: pid, machine: machine, path: base ?? "", format: .opencode), nil)
        }
        guard let r = try? await c.call("machine.exec", ["on": .string(machine), "line": .string(OpenCodeRemote.line(base: base, OpenCodeRemote.findArguments(argv: argv, directory: cwd, pid: pid))), "timeout": 20], timeout: .seconds(30)),
              let printed = r["stdout"]?.string.flatMap({ Data(base64Encoded: $0) })
        else { return (nil, nil) }
        let out = OpenCodeRemote.read(printed)
        guard out.done else { return (nil, "Swiftr reads OpenCode's conversations on \(machine) with python3, which it can't run there.") }
        guard let id = out.session else { return (nil, nil) }
        return (ClaudeSession(id: id, pid: pid, machine: machine, path: base ?? "", format: .opencode), nil)
    }

    /// OpenCode's data folder on other machines: nil for its own default; a test's folder.
    nonisolated static var remoteOpenCodeBase: String? {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["SWIFTR_REMOTE_OPENCODE_DIR"], !dir.isEmpty { return dir }
        #endif
        return nil
    }

    // MARK: What Codex prints on its screen

    /// What Codex printed for a command it answers on its screen only (`/status`).
    struct CommandOutput: Equatable {
        let command: String
        let text: String
        /// A key's reply (`⌥.`) shows a keyboard, a command's a slash.
        var symbol = "slash.circle"
    }

    private(set) var commandOutput: CommandOutput?

    /// What the agent printed back to a key pressed from here, over the field.
    func showReply(_ text: String, to key: String) {
        commandOutput = CommandOutput(command: key, text: text, symbol: "keyboard")
    }
    /// Counts what was sent: a capture started for an older send keeps quiet.
    @ObservationIgnored private var sends = 0
    /// The session a `/new` or `/clear` sent from here put away: Codex and
    /// OpenCode write the new chat only with its first message.
    @ObservationIgnored private var putAway: String?

    func closeCommandOutput() {
        commandOutput = nil
    }

    /// Reads Codex's screen until what `command` printed shows, settled, for
    /// 3 s at most; the history above the screen too when it isn't there.
    private func captureOutput(of command: String, send: Int) async {
        guard let c = model.connection else { return }
        let end = Date().addingTimeInterval(3)
        var last: String?
        while Date() < end, !Task.isCancelled, send == sends {
            try? await Task.sleep(for: .milliseconds(300))
            let lines = Date().addingTimeInterval(0.6) >= end ? 200 : 0
            guard let r = try? await c.call("terminal.read", ["terminal": .string(address), "lines": .int(Int64(lines))]),
                  let screen = r["text"]?.string,
                  let text = CodexScreen.output(of: command, screen: screen)
            else { continue }
            if text == last { break }
            last = text
        }
        if let last, send == sends { commandOutput = CommandOutput(command: command.trimmingCharacters(in: .whitespacesAndNewlines), text: last) }
    }

    // MARK: Reading

    /// Drops the session read, for one that has no file yet.
    private func forget() {
        watcher?.cancel()
        watcher = nil
        source = nil
        session = nil
        rows = []
        title = nil
        queued = []
        prompt = nil
        facts = SessionFacts()
        todos = []
        openCalls = []
        background = []
        history = []
        commandOutput = nil
        atStart = true
    }

    private func open(_ s: ClaudeSession) async {
        watcher?.cancel()
        watcher = nil
        // A Gemini chat already read keeps what it read: it asks to be opened again when a message changes.
        let kept = s == session ? source as? GeminiChat : nil
        source = nil
        let fresh = s.id != session?.id || s.machine != session?.machine
        session = s
        openTriedAt = Date()
        if fresh {
            rows = []
            title = nil
            queued = []
            prompt = nil
            facts = SessionFacts()
            todos = []
            openCalls = []
            background = []
            history = []
        }
        processStarted = s.machine == nil ? CodexFiles.startTime(pid: s.pid) : nil
        if rows.isEmpty { phase = .loading }
        if fresh, s.format == .claude { Task { await loadModeKey(s) } }
        let src: any TranscriptSource
        if let machine = s.machine, s.format == .opencode {
            guard let c = model.connection else { return }
            let base = s.path.isEmpty ? nil : s.path
            src = RemoteOpenCodeTranscript(session: s.id) { arguments in
                let r = try await c.call("machine.exec", ["on": .string(machine), "line": .string(OpenCodeRemote.line(base: base, arguments)), "timeout": 20], timeout: .seconds(30))
                return r["stdout"]?.string.flatMap { Data(base64Encoded: $0) } ?? Data()
            }
        } else if let kept {
            src = kept
        } else if let machine = s.machine {
            guard let c = model.connection else { return }
            let file = RemoteTranscript(machine: machine, path: s.path) { method, params in
                try await c.call(method, params, timeout: .seconds(60))
            }
            switch s.format {
            case .codex: src = Self.codexChain(file, machine: machine, connection: c)
            case .gemini: src = GeminiChat(file: file)
            default: src = file
            }
        } else if s.format == .gemini {
            src = GeminiChat(file: TranscriptFile(url: URL(filePath: s.path)))
        } else if s.format == .opencode {
            src = OpenCodeTranscript(db: URL(filePath: s.path), session: s.id)
        } else {
            let file = TranscriptFile(url: URL(filePath: s.path))
            src = s.format == .codex ? Self.codexChain(file, near: s.path) : file
        }
        do {
            let lines = try await src.openTail(lines: Self.tailLines, maxBytes: Self.tailBytes)
            guard session == s else { return }
            apply(await builder.reset(lines, format: s.format))
            source = src
            atStart = await src.atStart
            phase = .ready
            appended += 1
            lastError = nil
            // OpenCode writes its database's log first.
            if s.machine == nil { watch(s.format == .opencode ? s.path + "-wal" : s.path) }
        } catch {
            guard session == s else { return }
            lastError = "\(error)"
            // A new session writes its file with its first message.
            apply(await builder.reset([], format: s.format))
            atStart = true
            phase = .empty
        }
    }

    /// A Codex conversation across its files: once the person went back to
    /// an earlier message, the file before holds what came first.
    nonisolated static func codexChain(_ file: TranscriptFile, near path: String) -> CodexChain {
        CodexChain(current: file) { base in
            guard let found = CodexFiles.rollout(part: base.part, near: path) else { return nil }
            let end = base.endByte.map { UInt64($0) } ?? byteOffset(ofOrdinal: base.endOrdinal, in: found)
            return TranscriptFile(url: URL(filePath: found), end: end)
        }
    }

    /// The same on another machine: the file found there, read to the
    /// line before the cut (line numbers there count from the file's first
    /// `ordinal`).
    nonisolated static func codexChain(_ file: RemoteTranscript, machine: String, connection c: CoreConnection) -> CodexChain {
        CodexChain(current: file) { base in
            let r = try await c.call("machine.exec", ["on": .string(machine), "line": .string(CodexFiles.remoteRollout(part: base.part)), "timeout": 15])
            let out = r["stdout"]?.string.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let path = lines.first, !path.isEmpty else { return nil }
            let first = lines.dropFirst().first.flatMap { Int($0) } ?? 0
            return RemoteTranscript(machine: machine, path: path, lastLine: max(0, base.endOrdinal - first)) { method, params in
                try await c.call(method, params, timeout: .seconds(60))
            }
        }
    }

    /// Where the line with `ordinal` starts in a Codex file; its end when none does.
    nonisolated static func byteOffset(ofOrdinal ordinal: Int, in path: String) -> UInt64? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var offset = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if let n = CodexHistoryBase.ordinal(of: Data(line)), n >= ordinal { return UInt64(offset) }
            offset += line.count + 1
        }
        return UInt64(data.count)
    }

    /// Looks for the session file again now, and again in a moment: Codex
    /// starts a new one when it goes back to an earlier message.
    func recheckSession() {
        sessionCheckedAt = nil
        poke()
        Task { [weak self] in
            for wait in [600, 1500] {
                try? await Task.sleep(for: .milliseconds(wait))
                self?.sessionCheckedAt = nil
                self?.poke()
            }
        }
    }

    /// After a command sent to Claude from here. Claude keeps its pid when
    /// it changes sessions (`/clear`, `/resume`, `/branch`) and names the
    /// new one in its session file at once; some commands open a screen of
    /// their own (`/resume`'s list). Looks for the session and reads the
    /// screen every 300 ms for 5 s, then every second while that screen
    /// shows and for 5 s after it goes (a session chosen in the terminal),
    /// 2 minutes at most; done once the session changes.
    func followCommand() {
        let before = session?.id
        following?.cancel()
        following = Task { [weak self] in
            let start = Date()
            var end = start.addingTimeInterval(5)
            while !Task.isCancelled {
                let early = Date().timeIntervalSince(start) < 5
                try? await Task.sleep(for: .milliseconds(early ? 300 : 1000))
                guard let self, !Task.isCancelled, self.isShown else { return }
                self.sessionCheckedAt = nil
                self.screenReadAt = nil
                await self.step()
                if self.session?.id != before { return }
                let now = Date()
                if self.dialog != nil { end = max(end, now.addingTimeInterval(5)) }
                if now >= end || now.timeIntervalSince(start) > 120 { return }
            }
        }
    }

    private func readNew() async {
        guard let s = session else { return }
        guard let src = source else {
            // Not open: no transcript yet, or the connection changed.
            if let at = openTriedAt, Date().timeIntervalSince(at) < 2 { return }
            await open(s)
            return
        }
        do {
            guard let lines = try await src.readNew() else {
                await open(s)
                return
            }
            guard !lines.isEmpty, session == s else { return }
            apply(await builder.append(lines))
            appended += 1
        } catch {
            lastError = "\(error)"
            source = nil
        }
    }

    /// Older lines in front of what is shown.
    func loadEarlier() async {
        guard !loadingEarlier, let src = source, let s = session else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        guard let lines = try? await src.readEarlier(lines: Self.earlierLines, maxBytes: Self.tailBytes), session == s else { return }
        apply(await builder.prepend(lines))
        atStart = await src.atStart
        prepended += 1
    }

    private func apply(_ snapshot: TranscriptSnapshot) {
        if hiddenRows.isEmpty {
            rows = snapshot.rows
        } else {
            let kept = snapshot.rows.filter { !hiddenRows.contains($0.id) }
            // The transcript dropped them itself.
            if kept.count == snapshot.rows.count { hiddenRows = [] }
            rows = kept
        }
        if title != snapshot.title { title = snapshot.title }
        if queued != snapshot.queued { queued = snapshot.queued }
        if facts != snapshot.facts {
            // A mode the transcript tells of is newer than the screen's, which
            // hides the mode line while Claude asks something.
            if let mode = snapshot.facts.permissionMode, mode != facts.permissionMode, footer != nil { footer?.mode = mode }
            facts = snapshot.facts
        }
        if todos != snapshot.todos { todos = snapshot.todos }
        if openCalls != snapshot.openCalls { openCalls = snapshot.openCalls }
        if background != snapshot.background { background = snapshot.background }
        if history != snapshot.history { history = snapshot.history }
        if summarized != snapshot.summarized { summarized = snapshot.summarized }
    }

    /// On this Mac, a change to the file is seen at once.
    private func watch(_ path: String) {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poke() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    /// Reads which key cycles Claude's mode from the keybindings beside its
    /// session's configuration folder.
    private func loadModeKey(_ s: ClaudeSession) async {
        // <config>/projects/<folder>/<session>.jsonl
        let config = ((((s.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent) as NSString).deletingLastPathComponent
        let path = config + "/keybindings.json"
        var json: JSON?
        if let machine = s.machine {
            if let r = try? await model.connection?.call("file.read", ["on": .string(machine), "path": .string(path)]), let text = r["text"]?.string {
                json = try? JSON(text: text)
            }
        } else {
            json = await Task.detached { (try? Data(contentsOf: URL(filePath: path))).flatMap { try? JSON(data: $0) } }.value
        }
        guard session == s else { return }
        modeKey = ClaudeKeys.cycleMode(bindings: json)
    }

    // MARK: Claude's screen

    /// What Claude asks while blocked; else, every few seconds, the footer
    /// under its input box (mode, status line) or a menu of its own.
    func refreshScreen() async {
        guard let m = record, m.isLive, m.runsChatAgent, let c = model.connection else {
            if prompt != nil { prompt = nil }
            if promptRead { promptRead = false }
            if dialog != nil { dialog = nil }
            // Asleep, its input box is gone, with what it held.
            if heldInBox != nil, model.sleepers.isAsleep(address) { heldInBox = nil }
            return
        }
        // Keys are being pressed: the steps read the screen themselves.
        guard !acting else { return }
        if status?.state != "blocked", !cardWords.isEmpty || !cardNoteOn.isEmpty || !cardWordsRead.isEmpty || geminiListShown || questionTabRead != nil {
            cardWords = [:]
            cardNoteOn = [:]
            cardWordsRead = [:]
            geminiListShown = false
            questionTab = nil
            questionTabRead = nil
        }
        let blocked = m.status?.state == "blocked"
        let unfollowed = followsScreen
        if !blocked {
            if !unfollowed {
                if prompt != nil { prompt = nil }
                if promptRead { promptRead = false }
            }
            if !(unfollowed && prompt != nil), let at = screenReadAt, Date().timeIntervalSince(at) < 2 { return }
        }
        let readAt = Date()
        screenReadAt = readAt
        guard let r = try? await c.call("terminal.read", ["terminal": .string(address)]), !acting else { return }
        let screen = r["text"]?.string ?? ""
        // A menu's card reads Claude's screen too: a read older than its, or one redraw, leaves it be.
        if record?.status?.state != "blocked", menus.holds(screen, readAt: readAt) { return }
        if record?.status?.state == "blocked" {
            var found = parsePrompt(screen)
            if isGemini, let p = found, let whole = await showWholeGeminiList(p) { found = whole }
            if found != prompt { prompt = found }
            if !promptRead { promptRead = true }
            if dialog != nil { dialog = nil }
            if isGemini, let found { await readGeminiWords(found) }
            if agent == .claude, let found { await readQuestionTab(found) }
            return
        }
        if followsScreen {
            // What it asks shows where its input box was.
            var found = parseFooter(screen) == nil ? parsePrompt(screen) : nil
            // Gemini's own lists (its rewind list, a picker) come while its
            // title says it is ready: a menu of its own, not a question.
            if isGemini, let found, record.flatMap({ GeminiScreen.status(title: $0.title) })?.state != "blocked" {
                if prompt != nil { prompt = nil }
                if promptRead { promptRead = false }
                if dialog != found { dialog = found }
                return
            }
            if isGemini, let p = found, let whole = await showWholeGeminiList(p) { found = whole }
            if found != prompt { prompt = found }
            if promptRead != (found != nil) { promptRead = found != nil }
            if let found {
                if dialog != nil { dialog = nil }
                if isGemini { await readGeminiWords(found) }
                return
            }
        }
        if m.isOpenCode, let shown = ScreenPrompt.openCodeDialog(screen: screen) {
            // A picker (`/models`…) or a panel drawn over the conversation.
            if dialog != shown { dialog = shown }
        } else if var f = parseFooter(screen) {
            // Claude Code shows the effort a while after it changes; keep it after.
            // (OpenCode shows none for the default variant.)
            if f.effort == nil, !m.isOpenCode, !m.isGemini { f.effort = footer?.effort }
            // Claude Code's dim suggestion reads like typing: its colors tell.
            if !m.isCodex, !m.isOpenCode, !m.isGemini, let text = f.input, !text.isEmpty, await isSuggestion(text) {
                guard !acting else { return }
                // A new session's example (`Try "how do I log an error?"`) is no suggestion: Tab doesn't take it.
                if text.wholeMatch(of: /Try ".*"/) == nil { f.suggestion = text }
                f.input = ""
            }
            // A menu's card may have read a newer screen meanwhile.
            if menus.isStale(readAt) { return }
            if f != footer { footer = f }
            if dialog != nil { dialog = nil }
            boxRead(f.input ?? "", screen: screen, status: m.status?.state)
        } else if m.isOpenCode {
            // No input box: one of OpenCode's own screens is up (a picker, a dialog).
            let shown = ScreenPrompt(question: [], options: [], footer: "Esc closes it", context: ["OpenCode shows one of its screens"], numbered: false)
            if dialog != shown { dialog = shown }
        } else if m.isGemini {
            // No input box: one of Gemini's own screens (`/model`, `/settings`): a choice, else a panel.
            let shown = ScreenPrompt.parseGemini(screen: screen)
                ?? ScreenPrompt(question: [], options: [], footer: "Esc closes it", context: ["Gemini shows one of its screens"], numbered: false)
            if dialog != shown { dialog = shown }
        } else {
            // No input box: one of Claude Code's own screens is up, a menu
            // to choose in or a panel to read and leave.
            let menu = ScreenPrompt.parse(screen: screen).flatMap { Self.isMenu($0) ? $0 : nil } ?? ScreenPrompt.panel(screen: screen)
            if menu != dialog { dialog = menu }
        }
    }

    /// A choice that says which keys make it, as Claude Code's menus do, or
    /// shows its cursor on one (`/rewind`'s second step says nothing); or
    /// its effort scale, or its list of conversations to resume.
    nonisolated static func isMenu(_ p: ScreenPrompt) -> Bool {
        if p.effortMenu != nil || p.resumeMenu != nil { return true }
        let hint = p.footer.lowercased()
        return p.options.count >= 2 && (hint.contains("esc") || hint.contains("enter") || p.options.contains(where: \.focused))
    }

    // MARK: Rewind

    /// The person's messages shown, oldest first: what /rewind's list can name.
    var rewindable: [(id: String, text: String)] {
        rows.compactMap { row in
            guard case .item(let item) = row, !summarized.contains(item.id) else { return nil }
            switch item.kind {
            case .prompt(let text, _): return (item.id, text)
            case .command(let name, _): return (item.id, name)
            default: return nil
            }
        }
    }

    /// The prompt /rewind went back to, with the rows after it: they go out
    /// of sight now. Its words and pictures; nil when it isn't shown.
    func rewound(to id: String) -> (text: String, images: Int)? {
        guard let i = rows.firstIndex(where: { $0.id == id }), let words = said(id) else { return nil }
        hiddenRows.formUnion(rows[i...].map(\.id))
        rows.removeSubrange(i...)
        return words
    }

    /// The words and pictures of the prompt `id`, as shown.
    func said(_ id: String) -> (text: String, images: Int)? {
        guard let row = rows.first(where: { $0.id == id }), case .item(let item) = row else { return nil }
        switch item.kind {
        case .prompt(let text, let images): return (images > 0 ? Transcript.withoutImageTags(text) : text, images)
        case .command(let name, _): return (name, 0)
        default: return nil
        }
    }

    /// `text` in the Messages field, to change and send again; after what
    /// the field already holds, if anything.
    func putInField(_ text: String) {
        let draft = model.drafts[address] ?? ""
        model.drafts[address] = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft + "\n\n" + text
        model.requestFocus()
    }

    /// Empties the field if it holds just `text`.
    func takeOutOfField(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.drafts[address]?.trimmingCharacters(in: .whitespacesAndNewlines) == words { model.drafts[address] = "" }
    }

    /// Reads the screen again soon, whatever the time since the last read.
    func rereadScreen() {
        screenReadAt = nil
        poke()
    }

    // MARK: Acting

    /// Types `text` into Claude (or Codex) and presses Enter, once it is sure
    /// the agent is what listens: never into a shell, never into a question.
    /// `pictures`: paths Codex and OpenCode take as images, pasted first
    /// (Claude's go first in the same paste as `text`; Gemini's too, each as `@path`).
    func send(_ text: String, pictures: [String] = []) async throws {
        // Asleep: it wakes first, and the message goes once its input box is drawn.
        if isAsleep {
            await model.sleepers.awake(address)
            // Still asleep: its shell is in front, and the message stays here.
            guard !isAsleep else { throw CoreError(kind: "asleep", message: "\(agentName) didn't wake, so the message stays here. Its terminal shows why.") }
        }
        if isGemini, !pictures.isEmpty {
            let named = pictures.map { "@" + $0.replacingOccurrences(of: " ", with: "\\ ") }
            return try await send((named + (text.isEmpty ? [] : [text])).joined(separator: " "))
        }
        // A message starts a turn, which shows at once; a command may start
        // none, and its moment of work shows only if it lasts.
        let startsTurn = !text.hasPrefix("/") && !text.hasPrefix("!")
        // Claude takes a picture's path pasted at the start of a message.
        let claudePictures = agent == .claude ? pictures : []
        let text = claudePictures.isEmpty ? text : (claudePictures + (text.isEmpty ? [] : [text])).joined(separator: "\n")
        let pictures = claudePictures.isEmpty ? pictures : []
        let (c, working) = try await listening()
        if startsTurn { model.store.expectWork(address) }
        typingMessages += 1
        if startsTurn { startingTurn += 1 }
        defer {
            typingMessages -= 1
            if startsTurn {
                startingTurn -= 1
                turnSentAt = Date()
            }
        }
        // What the agent's input holds from its terminal goes first, in the
        // same message, as there; Claude's own menu closes for the message.
        // (Codex's and OpenCode's pictures go in through their input: there
        // the message comes after them.)
        if agent == .claude || pictures.isEmpty {
            let held = try await inputForMessage()
            if !held.isEmpty {
                commandOutput = nil
                actionError = nil
                sends += 1
                if agent == .claude {
                    try await sendAfterBox(text, pictures: claudePictures)
                } else {
                    try await sendAfterInput(text, working: working)
                }
                if session == nil { sessionCheckedAt = nil }
                poke()
                return
            }
        }
        commandOutput = nil
        actionError = nil
        sends += 1
        let send = sends
        if pictures.isEmpty {
            // From now: the core answers once the agent starts a turn, up to
            // 5 s later for a command that starts none (`/resume`).
            if agent == .claude, claudePictures.isEmpty, text.hasPrefix("/") {
                menus.expect(text)
                followCommand()
            }
            if agent == .claude, claudePictures.isEmpty, let kind = ClaudeMenuKind(command: text) {
                // `/effort`, `/model`, `/resume` start no turn: once the menu
                // shows, the message went, and the field is free at once.
                let sent = Task { try await c.call("terminal.send", ["terminal": .string(address), "text": .string(text)], timeout: .seconds(90)) }
                if await menus.opens(kind) {
                    if session == nil { sessionCheckedAt = nil }
                    poke()
                    return
                }
                _ = try await sent.value
            } else {
                _ = try await c.call("terminal.send", ["terminal": .string(address), "text": .string(text)], timeout: .seconds(90))
            }
            if agent == .claude { try await claudeEnterIfLeft(text, pictures: claudePictures, working: working) }
            if isOpenCode || isGemini { try await enterIfLeft(text) }
            if isCodex, working { try await queueIfLeft(text) }
            if isOpenCode, !working, !text.hasPrefix("/"), !text.hasPrefix("!") {
                Task { await keptOrBack(text, send: send) }
            }
        } else {
            // The core's send waits while the input holds something, as the
            // pictures now: the text goes in as a paste too, then Enter.
            // What the input held goes with it, the pictures handed too.
            handedPictures = []
            let terminal = try await pastePictures(pictures)
            if !text.isEmpty {
                terminal.view.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
                try await Task.sleep(for: .milliseconds(300))
            }
            _ = try await c.call("terminal.keys", ["terminal": .string(address), "keys": .array([.string("enter")])], timeout: .seconds(30))
        }
        // The first message makes the session: look for it right away.
        if session == nil { sessionCheckedAt = nil }
        poke()
        guard isCodex || isOpenCode || isGemini else { return }
        if isCodex, CodexScreen.prints(text) {
            Task { await captureOutput(of: text, send: send) }
        } else if ["/new", "/clear"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()), let s = session {
            // A new chat: the last one stays the newest until the next message.
            putAway = s.id
            forget()
            phase = .empty
        }
    }

    /// The core, once sure the agent is what listens and can take a message:
    /// never a shell, never a question, never Codex's list of messages to
    /// go back to. `working`: the agent is in a turn.
    private func listening() async throws -> (connection: CoreConnection, working: Bool) {
        guard let c = model.connection else { throw CoreError(kind: "lost", message: "Swiftr isn't connected to the core.") }
        let r = try await c.call("terminal.get", ["terminal": .string(address)])
        let name = agentName
        let fg = ForegroundProcess(json: r["foreground"])
        let listening = fg.map { fg in
            switch agent {
            case .claude: fg.program == "claude" || fg.name == "claude"
            case .codex: Programs.key(app: nil, argv: fg.argv, name: fg.name) == "codex"
            case .opencode: Programs.key(app: nil, argv: fg.argv, name: fg.name) == "opencode"
            case .gemini: Programs.key(app: nil, argv: fg.argv, name: fg.name) == "gemini"
            }
        } ?? false
        guard listening else {
            throw CoreError(kind: "not_claude", message: "\(name) is no longer running in this terminal.")
        }
        // Gemini's title says it waits, as the core does for the others.
        let said = AgentStatus(json: r["status"]) ?? (isGemini ? r["title"]?.string.flatMap { GeminiScreen.status(title: $0) } : nil)
        if said?.state == "blocked" || (followsScreen && prompt != nil) {
            throw CoreError(kind: "blocked", message: "\(name) is waiting for an answer first.")
        }
        if codexBrowsing {
            throw CoreError(kind: "blocked", message: "Codex is choosing a message to go back to: pick one above, or Cancel.")
        }
        return (c, said?.state == "working")
    }

    /// OpenCode 1.x (and Gemini, now and then) can miss the Enter right
    /// after a paste, as for a new session's first message: the text then
    /// waits in its input box. Enter again.
    private func enterIfLeft(_ text: String) async throws {
        guard let c = model.connection else { return }
        func squeezed(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        let sent = squeezed(text)
        for _ in 0 ..< 3 {
            try await Task.sleep(for: .milliseconds(500))
            let screen = try await c.call("terminal.read", ["terminal": .string(address)])["text"]?.string ?? ""
            guard let typed = parseFooter(screen)?.input.map(squeezed) else { return }
            if typed.isEmpty { return }
            // A long text wraps in the box: its start is enough.
            if !sent.isEmpty, sent.hasPrefix(typed) || typed.hasPrefix(sent) {
                _ = try await c.call("terminal.keys", ["terminal": .string(address), "keys": .array([.string("enter")])], timeout: .seconds(30))
                return
            }
        }
    }

    /// Claude Code misses the Enter that comes while it reads a picture whose
    /// path the paste holds: the message then waits in its input box, once
    /// read, until someone presses Enter. Enter again once the box shows it,
    /// its pictures read (`[Image #n]`). A message that stays there goes back
    /// to the field when Claude is idle, the box emptied (`not_taken`); while
    /// it works, it stays in the box (`kept`).
    private func claudeEnterIfLeft(_ text: String, pictures: [String], working: Bool) async throws {
        let start = Date()
        let end = start.addingTimeInterval(pictures.isEmpty ? 8 : 20)
        // A picture's path starts with a slash too.
        let command = pictures.isEmpty && (text.hasPrefix("/") || text.hasPrefix("!"))
        var enters = 0
        var emptySince: Date?
        func turnStarted() -> Bool {
            guard !working, let state = record?.status?.state else { return false }
            return state == "working" || state == "blocked"
        }
        while Date() < end {
            try await Task.sleep(for: .milliseconds(250))
            if turnStarted() { return }
            // A menu or a question shows in place of the box: it went.
            guard let box = await boxText(try await readScreen()) else { return }
            if box.isEmpty || box.hasPrefix("Press up to edit queued") {
                // Gone, unless its pictures are still being read: the paste
                // lands once they are. When Claude was idle, the turn it
                // starts says it went; a command starts none.
                let quiet: Double = pictures.isEmpty ? (working || command ? 1.2 : 2.5) : 6
                if emptySince == nil { emptySince = Date() }
                if Date().timeIntervalSince(emptySince!) >= quiet { return }
                continue
            }
            emptySince = nil
            // Someone else's words: not this message's to send.
            guard Self.claudeHolds(box, text, pictures: pictures) else { return }
            if box.matches(of: /\[Image #\d+\]/).count < pictures.count, Date().timeIntervalSince(start) < 10 { continue }
            guard enters < 3 else { break }
            enters += 1
            try await press(["enter"])
        }
        guard let box = await boxText(try await readScreen()), !box.isEmpty, Self.claudeHolds(box, text, pictures: pictures) else { return }
        if !turnStarted(), record?.status?.state != "working", try await emptyBox() {
            throw CoreError(kind: "not_taken", message: "Claude didn't take the message, so it's back in the field: send it again.")
        }
        throw CoreError(kind: "kept", message: "Claude keeps the message in its input box: press Return in its terminal, or clear it there.")
    }

    /// Whether Claude's input box holds `text`, which pasted `pictures`
    /// first: their paths turn into `[Image #n]` there, the box wraps the
    /// rest, and a long paste shows as `[Pasted text #n …]`.
    nonisolated static func claudeHolds(_ box: String, _ text: String, pictures: [String]) -> Bool {
        if box.contains("[Pasted text") { return true }
        var typed = squeezed(box.replacing(/\[Image #\d+\]/, with: ""))
        var sent = squeezed(text)
        for path in pictures.map(squeezed) {
            typed = typed.replacingOccurrences(of: path, with: "")
            sent = sent.replacingOccurrences(of: path, with: "")
        }
        // Pictures alone: their marks are all the box holds.
        guard !sent.isEmpty else { return typed.isEmpty && box.contains("[Image #") }
        guard !typed.isEmpty else { return false }
        let n = min(typed.count, sent.count, 40)
        return typed.prefix(n) == sent.prefix(n)
    }

    /// OpenCode 1.x once took a message right after starting and lost it:
    /// no chat made, nothing left in its input box, nothing on its screen.
    /// A message neither its record nor its screen shows after a while
    /// comes back to the field, with a word on why.
    private func keptOrBack(_ text: String, send: Int) async {
        let words = String(Self.squeezed(text).prefix(24))
        guard !words.isEmpty else { return }
        func kept() -> Bool {
            rows.suffix(30).contains { row in
                guard case .item(let item) = row, case .prompt(let said, _) = item.kind else { return false }
                return Self.squeezed(said).hasPrefix(words)
            }
        }
        for _ in 0 ..< 40 {
            try? await Task.sleep(for: .milliseconds(500))
            // Another message since, the pane out of sight, OpenCode gone: leave it.
            guard sends == send, isShown, record?.isOpenCode == true else { return }
            if kept() { return }
        }
        guard status?.state != "working", let c = model.connection,
              let screen = try? await c.call("terminal.read", ["terminal": .string(address)])["text"]?.string,
              !Self.squeezed(screen).contains(words), sends == send, !kept()
        else { return }
        actionError = "OpenCode didn't keep “\(text.prefix(60))”: it's back in the field to send again."
        if !(model.drafts[address] ?? "").contains(text) { putInField(text) }
    }

    /// Text without its spaces and box lines, to find words a screen wraps.
    nonisolated static func squeezed(_ s: String) -> String {
        s.filter { !$0.isWhitespace && !"┃│▌".contains($0) }
    }

    /// Codex keeps a message sent with Enter in its input when it can't
    /// hand it to the turn under way (a `!` command runs): Tab then holds
    /// it for the turn's end, as Codex's own list does.
    private func queueIfLeft(_ text: String) async throws {
        guard let c = model.connection else { return }
        try await Task.sleep(for: .milliseconds(700))
        let screen = try await c.call("terminal.read", ["terminal": .string(address)])["text"]?.string ?? ""
        guard let typed = ClaudeFooter.parseCodex(screen: screen)?.input, Self.codexHolds(typed, text) else { return }
        _ = try await c.call("terminal.keys", ["terminal": .string(address), "keys": .array([.string("tab")])], timeout: .seconds(30))
        codexQueuedHere = Array((codexQueuedHere + [text]).suffix(20))
        rereadScreen()
    }

    /// Whether Codex's input line, as read, starts with `text`'s words:
    /// what was typed there, not its hint.
    nonisolated static func codexHolds(_ shown: String, _ text: String) -> Bool {
        let a = shown.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let b = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !a.isEmpty, !b.isEmpty else { return false }
        let n = min(a.count, b.count, 24)
        return a.prefix(n) == b.prefix(n)
    }

    /// Tab in the field while Codex works: the message waits in Codex's
    /// list for the turn's end instead of reaching it at once (Enter).
    /// Pasted through the terminal's own stream, then Tab, as a person would.
    /// Tab before Codex shows the paste does nothing: it waits for the text.
    func queue(_ text: String) async throws {
        if agent == .claude { return try await queueForClaude(text) }
        guard isCodex else { return try await send(text) }
        let (c, working) = try await listening()
        guard working else { return try await send(text) }
        func shown() async throws -> ClaudeFooter? {
            ClaudeFooter.parseCodex(screen: try await c.call("terminal.read", ["terminal": .string(address)])["text"]?.string ?? "")
        }
        let before = try await shown()
        let held = before?.queued.count ?? 0
        // What its input holds from its terminal: the message goes after
        // it, on a line of its own, one message as when both are typed there.
        let typed = before?.input ?? ""
        let terminal = try await attachedTerminal(for: "the message")
        actionError = nil
        if !typed.isEmpty {
            heldInBox = nil
            heldCut = false
            handedPictures = []
        }
        terminal.view.send(txt: "\u{1b}[200~" + (typed.isEmpty ? "" : "\n") + text + "\u{1b}[201~")
        // A long paste shows as `[Pasted Content …]`: any new text there is it.
        var pasted = false
        for _ in 0 ..< 20 {
            try await Task.sleep(for: .milliseconds(150))
            if let now = try await shown()?.input, !now.isEmpty, now != typed {
                pasted = true
                break
            }
        }
        guard pasted else {
            throw CoreError(kind: "paste", message: "Codex didn't show the message in its input: nothing was queued.")
        }
        for _ in 0 ..< 2 {
            _ = try await c.call("terminal.keys", ["terminal": .string(address), "keys": .array([.string("tab")])], timeout: .seconds(30))
            for _ in 0 ..< 5 {
                try await Task.sleep(for: .milliseconds(200))
                guard let f = try await shown() else { continue }
                if f.queued.count > held || f.input?.isEmpty == true {
                    codexQueuedHere = Array((codexQueuedHere + [text]).suffix(20))
                    rereadScreen()
                    return
                }
            }
        }
        // Out of Codex's input again: the field gets it back. After words
        // typed in its terminal, both stay there, one message.
        guard typed.isEmpty else {
            rereadScreen()
            throw CoreError(kind: "kept", message: "Codex didn't queue the message: it waits in Codex's input, after what you typed there. Tab in its terminal queues it.")
        }
        try await emptyCodexInput(text)
        rereadScreen()
        throw CoreError(kind: "queue", message: "Codex didn't queue the message: Tab again, or ↩ to send it now.")
    }

    /// ⌃X ↩ while Claude works: the message pasted in its input box, then
    /// Claude Code's own ⌃X ↩ sends it.
    private func queueForClaude(_ text: String) async throws {
        let (c, working) = try await listening()
        guard working else { return try await send(text) }
        // Words typed in its terminal go first, on their own line, as there.
        // (Its dim hint while messages wait isn't text.)
        let held = try await inputForMessage()
        let terminal = try await attachedTerminal(for: "the message")
        actionError = nil
        heldInBox = nil
        // What the box holds goes with the message, the pictures handed too.
        handedPictures = []
        if !held.isEmpty { terminal.view.send(txt: "\n") }
        terminal.view.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        // A long paste shows as `[Pasted text #n …]`.
        let pastes = held.matches(of: /\[Pasted text #/).count
        var pasted = false
        for _ in 0 ..< 20 {
            try await Task.sleep(for: .milliseconds(150))
            let typed = parseFooter(try await readScreen())?.input ?? ""
            if ClaudeBox.squeezed(typed).hasSuffix(String(ClaudeBox.squeezed(text).suffix(40))) || typed.matches(of: /\[Pasted text #/).count > pastes {
                pasted = true
                break
            }
        }
        guard pasted else {
            throw CoreError(kind: "paste", message: "Claude didn't show the message in its input box: nothing was sent.")
        }
        _ = try await c.call("terminal.keys", ["terminal": .string(address), "keys": .array([.string("ctrl+x"), .string("enter")])], timeout: .seconds(30))
        rereadScreen()
    }

    /// The terminal's own stream, open: what the core can't type goes in there.
    func attachedTerminal(for what: String) async throws -> TerminalSession {
        let terminal = model.pool.session(address)
        terminal.attach()
        let attached = Date().addingTimeInterval(5)
        while terminal.phase != .attached {
            guard Date() < attached else { throw CoreError(kind: "attach", message: "Swiftr couldn't reach \(agentName)'s input for \(what).") }
            try await Task.sleep(for: .milliseconds(100))
        }
        return terminal
    }

    /// Codex and OpenCode take a picture as its path pasted alone in their
    /// input, where they then show `[Image #n]` (OpenCode `[Image n]`). The
    /// core pastes only with Enter after, so the path goes in through the
    /// terminal's own stream, as a paste.
    @discardableResult
    private func pastePictures(_ paths: [String]) async throws -> TerminalSession {
        let terminal = try await attachedTerminal(for: "the pictures")
        guard let c = model.connection else { throw CoreError(kind: "lost", message: "Swiftr isn't connected to the core.") }
        func screen() async throws -> String {
            try await c.call("terminal.read", ["terminal": .string(address)])["text"]?.string ?? ""
        }
        // Pictures already there (typed in the terminal) keep their numbers.
        let before = try await screen().matches(of: /\[Image #?\d+\]/).count
        for (i, path) in paths.enumerated() {
            terminal.view.send(txt: "\u{1b}[200~" + path + "\u{1b}[201~")
            let shown = isCodex ? "[Image #\(before + i + 1)]" : "[Image \(before + i + 1)]"
            let end = Date().addingTimeInterval(4)
            while try await !screen().contains(shown) {
                guard Date() < end else {
                    throw CoreError(kind: "picture", message: "\(agentName) didn't take \((path as NSString).lastPathComponent) as a picture.")
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        return terminal
    }

    /// Puts a picture beside Claude's terminal, on its machine, and returns
    /// its path there. Pasted at the start of a message, a path becomes an image.
    func attach(_ data: Data, name: String) async throws -> String {
        guard let c = model.connection else { throw CoreError(kind: "lost", message: "Swiftr isn't connected to the core.") }
        let r = try await c.call("terminal.put", ["terminal": .string(address), "name": .string(name), "data": .string(data.base64EncodedString())], timeout: .seconds(60))
        guard let path = r["path"]?.string else { throw CoreError(kind: "put", message: "The core didn't say where the picture went.") }
        return path
    }

    /// Esc: stops the agent's turn. Pressed while a message is still on its
    /// way, it stops the turn that message starts, once it began: sooner,
    /// Esc would land in the input beside the words. Claude Code gives back
    /// a message stopped before any answer (`takeBackStopped`).
    func interrupt() async {
        guard let c = model.connection else { return }
        if agent == .claude {
            guard !stopping else { return }
            stopping = true
        }
        defer { stopping = false }
        if agent == .claude, startingTurn > 0 {
            let end = Date().addingTimeInterval(12)
            while startingTurn > 0, Date() < end {
                try? await Task.sleep(for: .milliseconds(30))
            }
            // The message didn't go, or started no turn: nothing to stop.
            guard status?.state == "working" else { return }
        }
        // Claude Code gives a message back only to an empty input box, with none waiting behind it.
        let justSent = turnSentAt.map { Date().timeIntervalSince($0) < 3 } ?? false
        let givesBack = agent == .claude && heldInBox == nil && queued.isEmpty && (justSent || lastPromptUnanswered)
        if isGemini {
            _ = try? await c.call("terminal.keys", ["terminal": .string(address), "keys": .array([.string("esc")])], timeout: .seconds(15))
            poke()
            return
        }
        let held = await heldForTurnEnd()
        _ = try? await c.call("terminal.interrupt", ["terminal": .string(address)], timeout: .seconds(15))
        // OpenCode 1.x stops at a second Esc only, pressed soon after: its
        // screen asks for it a moment later (on another machine, later still).
        if isOpenCode {
            for _ in 0 ..< 10 {
                try? await Task.sleep(for: .milliseconds(150))
                guard let screen = try? await c.call("terminal.read", ["terminal": .string(address)])["text"]?.string else { break }
                if screen.contains("esc again to interrupt") {
                    _ = try? await c.call("terminal.keys", ["terminal": .string(address), "keys": .array([.string("esc")])], timeout: .seconds(15))
                    break
                }
                if ClaudeFooter.parseOpenCode(screen: screen)?.busy != true { break }
            }
        }
        poke()
        if !held.isEmpty { await takeBack(held) }
        if givesBack { await takeBackStopped() }
    }

    #if DEBUG
    var debugState: [String: Any] {
        var out: [String: Any] = [
            "phase": "\(phase)", "rows": rows.count, "title": title ?? "-", "queued": queued, "atStart": atStart,
            "session": session.map { "\($0.machine ?? "-") \($0.path) pid=\($0.pid)" } ?? "-", "shown": isShown,
            "error": lastError ?? "-", "promptRead": promptRead,
        ]
        if let p = prompt {
            out["prompt"] = ["question": p.question, "options": p.options.map { "\($0.focused ? ">" : " ")\($0.number). \($0.label)" }, "footer": p.footer]
        }
        if isGemini, let p = prompt {
            out["geminiList"] = [
                "checked": p.options.map { $0.checked.map { $0 ? "x" : " " } ?? "-" }, "custom": p.customOption ?? -1,
                "done": p.doneNumber ?? -1, "doneFocused": p.submitFocused, "scrolls": p.listScrolls, "shown": geminiListShown,
            ]
        }
        if let d = dialog {
            var shown: [String: Any] = ["title": d.title ?? "-", "options": d.options.map { "\($0.focused ? ">" : " ")\($0.number). \($0.label)" }, "footer": d.footer]
            if let e = d.effortMenu {
                shown["effort"] = "\(e.levels.indices.contains(e.current) ? e.levels[e.current] : "?") ultracode=\(e.ultracode.map { $0 ? "on" : "off" } ?? "-") caption=\(e.caption.joined(separator: " "))"
            }
            if let r = d.resumeMenu {
                shown["resume"] = ["search": r.search, "entries": r.entries.map { "\($0.focused ? ">" : " ")\($0.title) | \($0.details)" }, "all": r.allProjects,
                                   "branchOnly": r.branchOnly.map { "\($0)" } ?? "-", "empty": r.empty ?? "-", "searching": r.searching]
            }
            out["dialog"] = shown
        }
        if agent == .claude { out["menus"] = menus.debugState }
        if let f = footer {
            out["footer"] = ["mode": f.mode ?? "-", "effort": f.effort ?? "-", "statusLine": f.statusLine, "input": f.input ?? "-", "suggestion": f.suggestion ?? "-"]
        }
        out["facts"] = [
            "model": facts.model ?? "-", "effort": facts.effort ?? "-", "contextTokens": facts.contextTokens ?? -1,
            "mode": facts.permissionMode ?? "-", "branch": facts.gitBranch ?? "-",
        ]
        out["todos"] = todos.map { "\($0.status.rawValue): \($0.text)" }
        out["openCalls"] = openCalls.map(\.name)
        out["background"] = background.map { "\($0.kind == .agent ? "agent" : "shell") \($0.title) since=\(Int($0.started ?? 0))" }
        out["runningInBackground"] = runningInBackground.map(\.title)
        out["modeKey"] = modeKey ?? "-"
        out["history"] = history.count
        out["acting"] = acting
        out["list"] = MessageListProbe.lines[address] ?? []
        out["actionError"] = actionError ?? "-"
        out["heldInBox"] = heldInBox ?? "-"
        out["takeBackWhenIdle"] = takeBackWhenIdle
        out["stopping"] = stopping
        out["startingTurn"] = startingTurn
        out["handOffWaiting"] = handOffWaiting != nil
        out["movingDraft"] = movingDraft
        out["menuOpening"] = menuOpening
        out["askAnswers"] = askAnswers.mapValues { $0.map { "\($0.chosen.joined(separator: "+"))|\($0.other)" } }
        out["fieldDraft"] = fieldDraft
        out["fieldCaret"] = fieldCaret.map { "\($0.offset)/\($0.length)" } ?? "-"
        out["fieldPictures"] = fieldPictures.map(\.name)
        out["handedPictures"] = handedPictures.map { "\($0.mark) \($0.picture.name)" }
        out["cardWords"] = cardWords
        out["cardNoteOn"] = cardNoteOn
        out["cardWordsRead"] = cardWordsRead.mapValues { $0.hint ? "hint: \($0.words)" : $0.words }
        out["lastTyped"] = terminalSession?.lastTyped.map { Date().timeIntervalSince($0) } ?? -1
        out["lastRows"] = rows.suffix(4).map { row -> String in
            switch row {
            case .item(let item): String(describing: item.kind).prefix(120).description
            case .activity(_, let items): "activity \(items.count)"
            }
        }
        return out
    }
    #endif
}

/// The feeds of the Messages panes, and their views, kept a while after
/// they leave the screen.
@MainActor
final class MessageFeeds {
    private(set) var feeds: [String: TranscriptFeed] = [:]
    /// Each conversation's view (`ConversationHost`), kept with its feed.
    private var views: [String: NSView] = [:]
    private unowned let model: AppModel

    /// A feed not shown for this long stops.
    static let keep: TimeInterval = 300
    /// The views out of sight kept at most, the last ones shown.
    static let keptViews = 8

    init(model: AppModel) {
        self.model = model
    }

    func feed(_ address: String) -> TranscriptFeed {
        if let f = feeds[address] { return f }
        let f = TranscriptFeed(address: address, model: model)
        feeds[address] = f
        return f
    }

    func existing(_ address: String) -> TranscriptFeed? { feeds[address] }

    func keptView(_ address: String) -> NSView? { views[address] }

    func keep(_ view: NSView, for address: String) {
        views[address] = view
    }

    /// A terminal event: the feed following it looks again.
    func event(_ type: String, _ address: String) {
        guard let f = feeds[address] else { return }
        switch type {
        case "removed":
            f.stop()
            feeds[address] = nil
            // Shown, its container lets it go when the pane goes.
            if let view = views[address], view.isHidden { view.removeFromSuperview() }
            views[address] = nil
        case "status", "foreground", "restarted", "finished", "lost", "turn":
            f.poke()
        case "title":
            if f.isGemini { f.poke() }
        default:
            break
        }
    }

    func reconnected() {
        for f in feeds.values { f.reconnected() }
    }

    func prune() {
        let now = Date()
        for (address, f) in feeds where !f.isShown && now.timeIntervalSince(f.lastShown) > Self.keep {
            f.stop()
            feeds[address] = nil
        }
        // Out of sight, only the views shown last stay, and only with their feed.
        let hidden = views.keys.filter { feeds[$0]?.isShown != true }
            .sorted { (feeds[$0]?.lastShown ?? .distantPast) > (feeds[$1]?.lastShown ?? .distantPast) }
        for (i, address) in hidden.enumerated() where i >= Self.keptViews || feeds[address] == nil {
            views[address]?.removeFromSuperview()
            views[address] = nil
        }
    }
}
