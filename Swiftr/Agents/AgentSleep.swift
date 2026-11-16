import Darwin
import Foundation
import HerdrKit
import Observation

/// Agents put to sleep. An open Claude Code holds a few hundred megabytes
/// even when it does nothing; a sleeping one holds none: Swiftr quit it,
/// kept its tab and its conversation, and starts it again on the same
/// session (`claude --resume`) when the person writes to it or asks.
///
/// Claude Code on this Mac only, started from a shell: the shell stays and
/// takes the command that wakes it.
@MainActor @Observable
final class AgentSleep {
    @ObservationIgnored private unowned let model: AppModel

    /// address → the agent asleep there.
    private(set) var asleep: [String: SleepingAgent] = [:]
    /// Those Swiftr is starting again.
    private(set) var waking: Set<String> = []

    @ObservationIgnored private var wakes: [String: Task<Void, Never>] = [:]
    /// Those Swiftr is putting to sleep (reading their screen, quitting them).
    @ObservationIgnored private var dozing: Set<String> = []
    /// address → when a wake last failed there.
    @ObservationIgnored private var failed: [String: Date] = [:]
    /// address → when Swiftr put it to sleep, this run.
    @ObservationIgnored private var sleptNow: [String: Date] = [:]
    /// What was on screen at the last look: a pane just left was seen until then.
    @ObservationIgnored private var lastVisible: Set<String>?
    /// address → when its pane was last on screen.
    @ObservationIgnored private var lastSeen: [String: Date] = [:]
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    #if DEBUG
    /// Tests: what the last sleep or wake did.
    @ObservationIgnored private(set) var log: [String] = []
    #endif

    /// How long a Claude gets to quit, and to start again.
    static let quitTime: TimeInterval = 10
    static let wakeTime: TimeInterval = 45
    /// A shell still in front this long after the wake command: it failed.
    static let startTime: TimeInterval = 12

    init(model: AppModel) {
        self.model = model
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: SleepingAgent].self, from: data) {
            asleep = saved
        }
    }

    func start() {
        guard tickTask == nil else { return }
        fillRowTimes()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.tick()
            }
        }
    }

    /// Records written before the row's time was kept: the time of the
    /// conversation's last message stands for it.
    private func fillRowTimes() {
        let missing = asleep.filter { $0.value.lastActive == nil }.mapValues(\.session)
        guard !missing.isEmpty else { return }
        Task {
            let found = await Task.detached(priority: .utility) { missing.compactMapValues(Self.lastMessageMs) }.value
            var changed = false
            for (address, ms) in found where asleep[address]?.lastActive == nil && asleep[address]?.session == missing[address] {
                asleep[address]?.lastActive = ms
                changed = true
            }
            if changed { save() }
        }
    }

    /// The last `timestamp` in a conversation's file, in milliseconds since 1970.
    nonisolated static func lastMessageMs(session: String) -> Int64? {
        guard let url = ClaudeWatch.transcript(of: session), let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        guard let data = try? file.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let stamp = text.matches(of: /"timestamp":"([0-9T:.\-]+Z)"/).last?.output.1 else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = withFraction.date(from: String(stamp)) ?? ISO8601DateFormatter().date(from: String(stamp)) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    func isAsleep(_ address: String) -> Bool { asleep[address] != nil }
    func isWaking(_ address: String) -> Bool { waking.contains(address) }

    /// A tab holds a sleeping agent.
    func anyAsleep(_ addresses: [String]) -> Bool {
        !asleep.isEmpty && addresses.contains { asleep[$0] != nil }
    }

    // MARK: Going to sleep

    /// Why this terminal's agent can't sleep now; nil when it can.
    func whyNot(_ address: String) -> String? {
        guard let m = model.store.model(address), m.isLive, let fg = m.foreground, m.runsChatAgent else { return "No agent runs here." }
        guard asleep[address] == nil else { return "It is asleep already." }
        guard m.isClaude else { return "Only Claude Code can sleep for now." }
        guard m.machine == nil else { return "Only agents on this Mac can sleep for now." }
        switch m.status?.state {
        case "working": return "Claude is at work. It can sleep once it is done."
        case "blocked", "error": return "Claude waits for an answer. It can sleep after."
        default: break
        }
        guard ClaudeWatch.parentShell(of: fg.pid) != nil else {
            return "This Claude wasn't started from a shell: quitting it would close its tab."
        }
        return nil
    }

    func canSleep(_ address: String) -> Bool { whyNot(address) == nil }

    /// The tab's menu: every agent in it that can sleep does.
    func sleep(_ addresses: [String]) {
        for address in addresses where canSleep(address) {
            Task { await sleep(address, asked: true) }
        }
    }

    /// Every idle agent out of sight goes to sleep.
    func sleepIdle() {
        let all = idle
        // One after another: each quit takes memory to give memory back.
        Task {
            for address in all { await sleep(address, asked: false) }
        }
    }

    /// Those that may sleep without being asked one by one: idle, out of
    /// sight, and with no answer the person hasn't seen yet (asleep, its
    /// Done mark would be gone with it).
    var idle: [String] {
        let visible = Set(model.visibleAddresses)
        return model.store.all.filter { !visible.contains($0.address) && $0.attention != .done && canSleep($0.address) }.map(\.address)
    }

    /// Quits the agent and keeps what wakes it. `asked`: the person chose
    /// this one, so words left in its input box move to the Messages field;
    /// else such words, or a command still running, leave it awake.
    @discardableResult
    func sleep(_ address: String, asked: Bool) async -> Bool {
        if let why = whyNot(address) {
            if asked { model.problem = why }
            return false
        }
        guard !dozing.contains(address), let m = model.store.model(address), let fg = m.foreground else { return false }
        dozing.insert(address)
        defer { dozing.remove(address) }
        let pid = fg.pid
        // The session it runs now: `/clear` and `/resume` change it.
        let info = await Task.detached(priority: .userInitiated) { ClaudeWatch.localSession(pid: pid) }.value
        guard let session = info?.id ?? ResumableAgent.claude.resumedSession(fg.argv) else {
            if asked { model.problem = "This Claude has no conversation to come back to yet." }
            return false
        }
        // Told which API or key to use: from the shell's own setup, or for
        // that start only (an alias)? The shell's environment can't be read,
        // so a wake might bring back another Claude. It stays awake.
        if let name = Self.ownSetting(pid) {
            if asked { model.problem = "This Claude was started with \(name) set. Swiftr can't tell whether a wake would set it again, so it stays awake." }
            return note(address, "own settings")
        }
        // A command it started in the background would end with it.
        if Self.runsCommands(pid) {
            if asked { model.problem = "Claude still runs a command in the background, which sleep would end. Stop it first." }
            return note(address, "commands still run")
        }
        // Words typed in its input box and not sent.
        if let box = await boxDraft(address, record: m) {
            if !box.isEmpty {
                guard asked else { return note(address, "words wait in its box") }
                let field = model.drafts[address] ?? ""
                if !field.contains(box) { model.drafts[address] = field.isEmpty ? box : field + "\n" + box }
            }
        } else if !asked {
            // No input box: one of its menus is open.
            return note(address, "no input box")
        }
        // It may have started a turn, or quit, meanwhile.
        guard whyNot(address) == nil, model.store.model(address)?.foreground?.pid == pid else {
            if asked, let why = whyNot(address) { model.problem = why }
            return false
        }
        asleep[address] = SleepingAgent(agent: .claude, session: session, pid: pid, created: m.createdMs,
                                        sleptAt: Int(Date().timeIntervalSince1970), flags: SleepingAgent.keptFlags(fg.argv),
                                        lastActive: m.statusMs)
        sleptNow[address] = Date()
        save()
        // As closing its terminal would ask: it ends its session and leaves.
        kill(pid_t(pid), SIGTERM)
        let end = Date().addingTimeInterval(Self.quitTime)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(100))
            if kill(pid_t(pid), 0) != 0, errno == ESRCH {
                model.feeds.existing(address)?.poke()
                return note(address, "asleep", true)
            }
        }
        // Slow to leave (a busy Mac): it was asked to and will. The record
        // stays: it alone knows which conversation to come back to.
        return note(address, "slow to quit", true)
    }

    /// The first variable in its environment that says which API, key or
    /// model to use (`ANTHROPIC_…`, `CLAUDE_CODE_USE_…`), if any.
    nonisolated static func ownSetting(_ pid: Int) -> String? {
        #if DEBUG
        // Tests run a Claude on a made-up key.
        if ProcessInfo.processInfo.environment["SWIFTR_SLEEP_OWN_SETTINGS"] == "1" { return nil }
        #endif
        return LocalProcess.environment(of: pid_t(pid)).keys.filter { $0.hasPrefix("ANTHROPIC_") || $0.hasPrefix("CLAUDE_CODE_USE_") }.sorted().first
    }

    private func note(_ address: String, _ what: String, _ result: Bool = false) -> Bool {
        #if DEBUG
        log.append("\(address): \(what)")
        if log.count > 40 { log.removeFirst(log.count - 40) }
        #endif
        return result
    }

    /// The text in Claude's input box: "" when empty or only its dim
    /// suggestion, nil when no box shows.
    private func boxDraft(_ address: String, record m: TerminalModel) async -> String? {
        guard let c = model.connection, let r = try? await c.call("terminal.read", ["terminal": .string(address)]),
              let input = ClaudeFooter.parse(screen: r["text"]?.string ?? "")?.input
        else { return nil }
        guard !input.isEmpty else { return "" }
        let words = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        if let styled = await StyledScreen.read(address, connection: c, cols: m.cols, rows: m.rows),
           let suggestion = styled.suggestion, words(suggestion) == words(input) { return "" }
        // A new session's example.
        if input.wholeMatch(of: /Try ".*"/) != nil { return "" }
        return input
    }

    /// A shell among its children: a command it started still runs.
    nonisolated static func runsCommands(_ pid: Int) -> Bool {
        LocalProcess.children(of: pid_t(pid)).contains { child in
            LocalProcess.processName(child).map { ResumableRun.shells.contains($0) } ?? false
        }
    }

    // MARK: Waking

    /// Starts the agent again, unless that is under way.
    func wake(_ address: String) {
        guard asleep[address] != nil, wakes[address] == nil else { return }
        failed[address] = nil
        waking.insert(address)
        wakes[address] = Task {
            await runWake(address)
            waking.remove(address)
            wakes[address] = nil
            model.feeds.existing(address)?.poke()
        }
    }

    /// Words came into its Messages field: awake by the time they are
    /// sent. Not the words Swiftr itself moved there as it fell asleep.
    func typed(_ address: String) {
        if let at = sleptNow[address], Date().timeIntervalSince(at) < 1.5 { return }
        wakeUnasked(address)
    }

    /// A wake nobody asked for by name: not again right after one failed,
    /// each try types a command into the shell.
    private func wakeUnasked(_ address: String) {
        if let at = failed[address], Date().timeIntervalSince(at) < 60 { return }
        wake(address)
    }

    /// Wakes the agent and returns once its input box is drawn (or the wake failed).
    @discardableResult
    func awake(_ address: String) async -> Bool {
        // The wake a send just waited for failed: not typed a second time.
        if wakes[address] == nil, let at = failed[address], Date().timeIntervalSince(at) < 5 { return !isAsleep(address) }
        wake(address)
        await wakes[address]?.value
        return !isAsleep(address)
    }

    private func runWake(_ address: String) async {
        guard let record = asleep[address], let c = model.connection else { return }
        // Its shell in front: the agent may still be quitting.
        var end = Date().addingTimeInterval(Self.quitTime)
        while true {
            guard let m = model.store.model(address), m.isLive else { return drop(address) }
            if m.runsChatAgent, m.foreground?.pid != record.pid { return drop(address) }
            if Self.isShell(m.foreground) { break }
            guard Date() < end else {
                // The same Claude still in front: it never quit, so it never slept.
                if m.runsChatAgent, kill(pid_t(record.pid), 0) == 0 { return drop(address) }
                return wakeFailed(address, "Another program runs in this terminal. Wake Claude once it is done.")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // A shell just back takes a moment to draw its prompt.
        if Date().timeIntervalSince1970 - Double(record.sleptAt) < 3 { try? await Task.sleep(for: .milliseconds(500)) }
        let session = record.session
        let found = await Task.detached(priority: .userInitiated) { ClaudeWatch.lastModelAndEffort(session: session) }.value
        guard let command = record.wakeCommand(model: found.model, effort: found.effort, defaultModel: found.defaultModel) else {
            return drop(address)
        }
        _ = note(address, "wake: \(command)")
        // The core answers a send only once a turn starts, or seconds later.
        Task { _ = try? await c.call("terminal.send", ["terminal": .string(address), "text": .string(command)], timeout: .seconds(90)) }
        // Claude in front, its input box drawn (or a question of its own).
        let typed = Date()
        end = typed.addingTimeInterval(Self.wakeTime)
        var started = false
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(150))
            guard let m = model.store.model(address), m.isLive else { return drop(address) }
            guard m.runsChatAgent, m.foreground?.pid != record.pid else {
                // The shell still in front long after the command: it failed there.
                if !started, Self.isShell(m.foreground), Date().timeIntervalSince(typed) > Self.startTime { break }
                continue
            }
            started = true
            if m.status?.state == "blocked" { break }
            if let r = try? await c.call("terminal.read", ["terminal": .string(address)]),
               record.isDrawn(r["text"]?.string ?? "") { break }
        }
        // Awake: it runs again, drawn or slow to draw.
        if started { return drop(address) }
        // It never came. The record stays: it alone knows the conversation.
        wakeFailed(address, "Claude didn't start again in this terminal. Its terminal shows why; Wake tries again.")
    }

    private func wakeFailed(_ address: String, _ why: String) {
        failed[address] = Date()
        _ = note(address, "wake failed: \(why)")
        if model.visibleAddresses.contains(address) { model.problem = why }
    }

    nonisolated static func isShell(_ fg: ForegroundProcess?) -> Bool {
        ResumableRun.shells.contains(fg?.name ?? "") || ResumableRun.shells.contains(fg?.program ?? "")
    }

    private func drop(_ address: String) {
        sleptNow[address] = nil
        guard asleep[address] != nil else { return }
        asleep[address] = nil
        save()
    }

    // MARK: Events

    /// One terminal event, already applied to the store.
    func event(_ type: String, _ address: String) {
        guard let record = asleep[address] else { return }
        switch type {
        case "removed", "finished":
            wakes[address]?.cancel()
            drop(address)
        case "foreground", "restarted", "created":
            // Swiftr's own wake says when it is done.
            guard !waking.contains(address), let m = model.store.model(address) else { return }
            if record.check(agentInFront: m.runsChatAgent, foregroundPid: m.foreground?.pid, created: m.createdMs) != .asleep {
                drop(address)
            }
        default:
            break
        }
    }

    /// A fresh snapshot: sleepers whose terminal is gone, or runs an agent again.
    func snapshot() {
        guard model.link == .connected else { return }
        for (address, record) in asleep where !waking.contains(address) {
            guard let m = model.store.model(address) else {
                // A remote one may only be out of reach.
                if !address.contains("/") { drop(address) }
                continue
            }
            if !m.isLive || record.check(agentInFront: m.runsChatAgent, foregroundPid: m.foreground?.pid, created: m.createdMs) != .asleep {
                drop(address)
            }
        }
    }

    /// What is on screen changed, or may have: what the person looks at, or
    /// just left, isn't idle yet. A look wakes nothing: a sleeping agent's
    /// conversation reads as well asleep, and it wakes for the first word.
    func lookedAround() {
        let visible = Set(model.visibleAddresses)
        let now = Date()
        for address in visible.union(lastVisible ?? []) { lastSeen[address] = now }
        lastVisible = visible
    }

    // MARK: By itself

    /// Idle agents out of sight go to sleep after the time the person set.
    private func tick(after: TimeInterval? = nil) async {
        guard model.link == .connected else { return }
        // Asked to quit a minute ago and still in front: it never slept.
        let nowSeconds = Int(Date().timeIntervalSince1970)
        for (address, record) in asleep where !waking.contains(address) && !dozing.contains(address) && nowSeconds - record.sleptAt > 60 {
            if let m = model.store.model(address), m.runsChatAgent, m.foreground?.pid == record.pid { drop(address) }
        }
        let after = after ?? model.prefs.sleepAfter.seconds
        guard after > 0 else { return }
        let visible = Set(model.visibleAddresses)
        let now = Date()
        for address in visible { lastSeen[address] = now }
        for m in model.store.all where m.attention != .done && canSleep(m.address) {
            guard let fg = m.foreground else { continue }
            var active = m.statusMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? CodexFiles.startTime(pid: fg.pid) ?? now
            if let seen = lastSeen[m.address], seen > active { active = seen }
            let draft = !(model.drafts[m.address] ?? "").isEmpty || !(model.draftImages[m.address] ?? []).isEmpty
            let facts = SleepRules.Facts(state: m.status?.state, lastActive: active, visible: visible.contains(m.address),
                                         draft: draft, runsCommands: Self.runsCommands(fg.pid))
            guard SleepRules.sleepsNow(facts, after: after, now: now) else { continue }
            await sleep(m.address, asked: false)
        }
    }

    // MARK: File

    private var file: URL {
        let own = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Swiftr")
        let folder = model.endpoint.session == "default" ? own : own.appending(path: model.endpoint.session)
        return folder.appending(path: "sleeping-agents.json")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(asleep) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    #if DEBUG
    var debugState: [String: Any] {
        ["asleep": asleep.mapValues { "\($0.agent.rawValue) \($0.session) pid=\($0.pid) flags=\($0.flags.joined(separator: " "))" },
         "waking": waking.sorted(), "log": log, "after": model.prefs.sleepAfter.rawValue, "idle": idle,
         "file": file.path]
    }

    /// Tests: `sleep`, `wake` (the focused terminal's agent, or `:t3`'s),
    /// `sleep-idle`, `sleep-tick` (the minute's check, now; `sleep-tick:5` as
    /// if the setting were 5 seconds), `sleep-after:<hours>`.
    func debug(_ command: String, _ argument: String) {
        let address = argument.isEmpty ? model.focusedAddress : argument
        switch command {
        case "sleep": if let address { Task { await sleep(address, asked: true) } }
        case "wake": if let address { wake(address) }
        case "sleep-idle": sleepIdle()
        case "sleep-tick": Task { await tick(after: Double(argument)) }
        case "sleep-after": model.prefs.sleepAfter = SleepAfter(rawValue: Int(argument) ?? 0) ?? .never
        default: break
        }
    }
    #endif
}
