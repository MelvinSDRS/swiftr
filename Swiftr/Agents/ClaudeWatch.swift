import Darwin
import Foundation
import HerdrKit
import Observation

/// Agents in the core's terminals:
/// - tabs take Claude's session title;
/// - closed tabs go on a stack that ⇧⌘T takes back, with the session of the
///   agent that ran there (Claude, Codex, OpenCode or Gemini);
/// - when the core makes a lost terminal again, that agent is resumed in it.
@MainActor @Observable
final class ClaudeWatch {
    @ObservationIgnored private unowned let model: AppModel

    /// address → the agent session last seen running there.
    @ObservationIgnored private var sessions: [String: AgentSession] = [:]
    @ObservationIgnored private var lookedUp: [String: Date] = [:]
    @ObservationIgnored private var lookingUp: Set<String> = []
    /// Terminals running an agent, kept across restarts (agent-terminals.json).
    @ObservationIgnored private var runs: [String: ResumableRun] = [:]
    @ObservationIgnored private var runsLoaded = false
    /// address → when a shell this terminal didn't have came in front.
    @ObservationIgnored private var shellSince: [String: Date] = [:]
    @ObservationIgnored private var resuming: Set<String> = []
    /// address → the last folder seen.
    @ObservationIgnored private var folders: [String: String] = [:]
    /// address → the last session title Claude showed there.
    @ObservationIgnored private var titles: [String: String] = [:]
    /// tab key → its terminals that ended lately.
    @ObservationIgnored private var ended: [String: [(at: Date, tab: ClosedTab)]] = [:]
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    /// How many closed tabs the stack keeps.
    static let maxClosed = 20
    /// Terminals of one tab that end this close together were closed together.
    static let together: TimeInterval = 5
    /// A new shell gets this long to start before the agent is typed into it.
    static let shellSettle: TimeInterval = 3

    init(model: AppModel) {
        self.model = model
    }

    private var isDefaultCore: Bool { model.endpoint.session == "default" }

    func start() {
        guard tickTask == nil else { return }
        tick()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                let pending = !(self?.shellSince.isEmpty ?? true)
                try? await Task.sleep(for: .seconds(pending ? 1 : 5))
                self?.tick()
            }
        }
    }

    // MARK: Events

    /// A fresh snapshot: every terminal may have changed.
    func snapshot() {
        for m in model.store.all where m.isLive && !m.currentFolder.isEmpty {
            folders[m.address] = m.currentFolder
        }
        tick()
    }

    /// One event, already applied to the store.
    func event(_ type: String, _ address: String, data: JSON, previous: JSON?) {
        if type == "removed" {
            forget(address)
            return
        }
        guard let m = model.store.model(address) else { return }
        if m.isLive, !m.currentFolder.isEmpty { folders[address] = m.currentFolder }
        switch type {
        case "title":
            titleChanged(m)
        case "foreground", "restarted", "created", "lost":
            // A new program: look up its session soon.
            if m.foreground?.pid != previous?["foreground"]?["pid"]?.int { lookedUp[address] = nil }
            checkRuns()
        case "finished":
            finished(m)
        default:
            break
        }
    }

    private func tick() {
        guard model.link == .connected else { return }
        refreshSessions()
        checkRuns()
    }

    private func forget(_ address: String) {
        sessions[address] = nil
        lookedUp[address] = nil
        folders[address] = nil
        titles[address] = nil
        shellSince[address] = nil
    }

    // MARK: Tab titles

    /// A title set while Claude is in front is Claude's: a new session title
    /// names the tab, even one named by hand; the same title again (another
    /// status mark) leaves the tab's name alone. A title set while the shell
    /// is in front is the shell's, never a tab name.
    private func titleChanged(_ m: TerminalModel) {
        guard m.isClaude, let title = ClaudeTitle.clean(m.title) else { return }
        let before = titles.updateValue(title, forKey: m.address)
        guard before != title, let place = model.place(of: m.address) else { return }
        rename(place, to: title)
    }

    /// Claude's session file gave its title: a tab without a name of its
    /// own takes it, the first time (Swiftr starting, a Claude just found).
    private func seedTitle(_ name: String?, of address: String) {
        guard let name, let title = ClaudeTitle.clean(name), titles[address] == nil else { return }
        titles[address] = title
        guard let place = model.place(of: address),
              place.tab.name.isEmpty || place.tab.name.allSatisfy(\.isNumber)
        else { return }
        rename(place, to: title)
    }

    private func rename(_ place: TerminalPlace, to title: String) {
        guard place.tab.name != title, let c = model.connection, let slot = model.slots[place.space.machine] else { return }
        let tabID = place.tab.id
        Task {
            _ = try? await slot.update(c) { doc in doc.renameTab(tabID, to: title) }
        }
    }

    // MARK: Agent sessions

    /// Looks up the session of each agent Swiftr can resume, now and then.
    private func refreshSessions() {
        guard let c = model.connection else { return }
        let now = Date()
        for m in model.store.all where m.isLive {
            guard let agent = Self.resumable(m), let fg = m.foreground, !lookingUp.contains(m.address) else { continue }
            // On other machines, the other agents are looked up by running a program there: less often.
            let every: TimeInterval = m.machine == nil ? 10 : agent == .claude ? 30 : 60
            if let at = lookedUp[m.address], now.timeIntervalSince(at) < every { continue }
            lookedUp[m.address] = now
            lookingUp.insert(m.address)
            let address = m.address
            let machine = m.machine
            Task {
                let result = await Self.lookUp(agent, pid: fg.pid, argv: fg.argv, cwd: fg.cwd, machine: machine, connection: c)
                lookingUp.remove(address)
                if agent == .claude { seedTitle(result.title, of: address) }
                if let id = result.id ?? agent.resumedSession(fg.argv) {
                    found(AgentSession(agent: agent, id: id), in: address, pid: fg.pid)
                }
            }
        }
    }

    /// The agent running in front, if Swiftr can resume it.
    static func resumable(_ m: TerminalModel) -> ResumableAgent? {
        ChatAgent(record: m).flatMap { ResumableAgent(rawValue: $0.rawValue) }
    }

    /// The session an agent runs, from its own files, and Claude's title.
    nonisolated static func lookUp(_ agent: ResumableAgent, pid: Int, argv: [String], cwd: String, machine: String?,
                                   connection c: CoreConnection) async -> (id: String?, title: String?) {
        switch agent {
        case .claude:
            if let machine {
                let r = try? await c.call("file.read", ["on": .string(machine), "path": .string("\(remoteConfig)/sessions/\(pid).json")])
                let info = r?["text"]?.string.flatMap(SessionFile.init(json:))
                return (info?.id, info?.name)
            }
            let info = await Task.detached(priority: .utility) { localSession(pid: pid) }.value
            return (info?.id, info?.name)
        case .codex:
            return (await TranscriptFeed.findCodexSession(pid: pid, cwd: cwd, machine: machine, connection: c)?.id, nil)
        case .opencode:
            if let machine {
                return (await TranscriptFeed.findRemoteOpenCodeSession(pid: pid, argv: argv, cwd: cwd, machine: machine, connection: c).session?.id, nil)
            }
            return (await TranscriptFeed.findOpenCodeSession(pid: pid, argv: argv, cwd: cwd)?.id, nil)
        case .gemini:
            // The chat file's name holds a short id; `--resume` wants the whole one, inside.
            guard let chat = await TranscriptFeed.findGeminiSession(pid: pid, cwd: cwd, machine: machine, connection: c) else { return (nil, nil) }
            if let machine {
                let r = try? await c.call("file.read", ["on": .string(machine), "path": .string(chat.path), "offset": 1, "limit": 1])
                return (r?["text"]?.string.flatMap(GeminiFiles.sessionID(start:)), nil)
            }
            let path = chat.path
            return (await Task.detached(priority: .utility) { GeminiFiles.sessionID(of: URL(filePath: path)) }.value, nil)
        }
    }

    private func found(_ session: AgentSession, in address: String, pid: Int) {
        sessions[address] = session
        guard let m = model.store.model(address), m.foreground?.pid == pid else { return }
        loadRunsIfNeeded()
        if let run = runs[address], run.agent == session.agent, run.session == session.id, run.pid == pid { return }
        let shell = m.machine == nil ? Self.parentShell(of: pid) ?? m.pid : m.pid
        guard let shell else { return }
        runs[address] = ResumableRun(agent: session.agent, session: session.id, pid: pid, shell: shell, created: m.createdMs)
        saveRuns()
    }

    // MARK: Resuming agents

    /// A shell in front where an agent ran: the agent quit, or the core made
    /// the terminal again after a loss and the agent should come back.
    private func checkRuns() {
        guard model.link == .connected else { return }
        loadRunsIfNeeded()
        let now = Date()
        var changed = false
        for (address, run) in runs {
            guard let m = model.store.model(address) else {
                // Gone from this core while nothing watched; a remote one may only be out of reach.
                if !address.contains("/") {
                    runs[address] = nil
                    changed = true
                }
                continue
            }
            guard m.isLive else { continue }
            let fg = m.foreground
            switch run.check(foregroundName: fg?.name, foregroundProgram: fg?.program, foregroundPid: fg?.pid, created: m.createdMs) {
            case .none:
                shellSince[address] = nil
            case .otherTerminal, .agentQuit:
                shellSince[address] = nil
                runs[address] = nil
                changed = true
            case .newShell:
                let since = shellSince[address] ?? now
                shellSince[address] = since
                if now.timeIntervalSince(since) >= Self.shellSettle {
                    shellSince[address] = nil
                    runs[address] = nil // recorded again once the agent runs
                    changed = true
                    resume(run, in: address)
                }
            }
        }
        if changed { saveRuns() }
    }

    private func resume(_ run: ResumableRun, in address: String) {
        guard !resuming.contains(address), let c = model.connection else { return }
        resuming.insert(address)
        let machine = model.store.model(address)?.machine
        Task {
            defer { resuming.remove(address) }
            // Another copy of Swiftr may have done it already.
            guard let r = try? await c.call("terminal.get", ["terminal": .string(address)]),
                  ResumableRun.shells.contains(r["foreground"]?["name"]?.string ?? ""),
                  let command = await Self.resumeCommand(agent: run.agent, session: run.session, machine: machine)
            else { return }
            _ = try? await c.call("terminal.send", ["terminal": .string(address), "text": .string(command)], timeout: .seconds(90))
        }
    }

    /// The command that resumes an agent's session; Claude's keeps the
    /// session's model and effort when known (this Mac only).
    nonisolated static func resumeCommand(agent: ResumableAgent, session: String, machine: String?) async -> String? {
        guard agent == .claude, machine == nil else { return agent.resumeCommand(session: session) }
        return await Task.detached(priority: .userInitiated) {
            let found = lastModelAndEffort(session: session)
            return ResumableAgent.claudeCommand(session: session, model: found.model, effort: found.effort, defaultModel: found.defaultModel)
        }.value
    }

    // MARK: Closed tabs

    private func finished(_ m: TerminalModel) {
        let address = m.address
        let reason = m.reason ?? ""
        // Closed by a person or its program; other ends (core stopped, holder lost) bring it back.
        guard reason == "killed" || reason == "exited" else { return }
        defer { forget(address) }
        loadRunsIfNeeded()
        if runs.removeValue(forKey: address) != nil { saveRuns() }
        guard let tabID = m.labels["herdr.tab"], !tabID.isEmpty else { return }
        let key = qualify(tabID, on: m.machine ?? "")
        let now = Date()
        var group = (ended[key] ?? []).filter { now.timeIntervalSince($0.at) < Self.together }
        group.append((now, closedTab(m, tabID: tabID, at: now)))
        ended[key] = group
        // A split closed: the tab stays.
        if model.store.all.contains(where: { $0.isLive && $0.machine == m.machine && $0.labels["herdr.tab"] == tabID }) { return }
        ended[key] = nil
        if let pick = ClosedTab.pick(group.map(\.tab)) { push(pick) }
    }

    private func closedTab(_ m: TerminalModel, tabID: String, at date: Date) -> ClosedTab {
        let machine = m.machine ?? ""
        var spaceName = ""
        var tabName = ""
        if let place = model.place(ofTab: tabID, on: machine) {
            spaceName = place.space.space.name
            tabName = place.tab.name
        } else if let at = m.labels["where"]?.range(of: " / ") {
            // Already out of the layout: herdr-app's label ("Space / Tab").
            let label = m.labels["where"] ?? ""
            spaceName = String(label[..<at.lowerBound])
            tabName = String(label[at.upperBound...])
        }
        let folder = folders[m.address] ?? (m.cwd.isEmpty ? nil : m.cwd)
        let session = sessions[m.address]
        return ClosedTab(machine: m.machine, space: m.labels["herdr.space"].map { qualify($0, on: machine) },
                         spaceName: spaceName, tab: tabName, cwd: folder, session: session?.id, agent: session?.agent,
                         closedAt: Int(date.timeIntervalSince1970))
    }

    // MARK: Files

    /// Swiftr's own folder; a test core gets one of its own inside it.
    private var stateFolder: URL {
        let own = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Swiftr")
        return isDefaultCore ? own : own.appending(path: model.endpoint.session)
    }

    private var stackFile: URL { stateFolder.appending(path: "closed-tabs.json") }
    private var runsFile: URL { stateFolder.appending(path: "agent-terminals.json") }

    func closedTabs() -> [ClosedTab] {
        guard let data = try? Data(contentsOf: stackFile) else { return [] }
        return (try? JSONDecoder().decode([ClosedTab].self, from: data)) ?? []
    }

    private func saveStack(_ stack: [ClosedTab]) {
        write(Array(stack.suffix(Self.maxClosed)), to: stackFile)
    }

    func push(_ tab: ClosedTab) {
        saveStack(closedTabs() + [tab])
    }

    /// Takes the last closed tab off the stack.
    func popClosedTab() -> ClosedTab? {
        var stack = closedTabs()
        guard let last = stack.popLast() else { return nil }
        saveStack(stack)
        return last
    }

    private func loadRunsIfNeeded() {
        guard !runsLoaded else { return }
        runsLoaded = true
        if let data = try? Data(contentsOf: runsFile), let saved = try? JSONDecoder().decode([String: ResumableRun].self, from: data) {
            runs = saved
        } else {
            runs = [:]
        }
    }

    private func saveRuns() {
        write(runs, to: runsFile)
    }

    private func write(_ value: some Encodable, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    #if DEBUG
    var debugState: [String: Any] {
        ["sessions": sessions.mapValues { "\($0.agent.rawValue) \($0.id)" }, "titles": titles,
         "runs": runs.mapValues { "\($0.agent.rawValue) \($0.session) pid=\($0.pid) shell=\($0.shell)" },
         "shellSince": shellSince.mapValues { -$0.timeIntervalSinceNow },
         "stack": closedTabs().map { "\($0.machine ?? "-") \($0.space ?? "-") '\($0.spaceName)' '\($0.tab)' \($0.cwd ?? "-") \($0.agent?.rawValue ?? "-") \($0.session ?? "-")" },
         "stateFolder": stateFolder.path]
    }
    #endif

    // MARK: This Mac's processes and files

    /// Claude's configuration folder on other machines, from the home folder.
    nonisolated static var remoteConfig: String {
        #if DEBUG
        // Tests point it at a scratch folder.
        if let dir = ProcessInfo.processInfo.environment["SWIFTR_REMOTE_CLAUDE_DIR"], !dir.isEmpty { return dir }
        #endif
        return ".claude"
    }

    /// Claude's configuration folders: ~/.claude and cswap's accounts.
    nonisolated static var configFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var folders = [home.appending(path: ".claude")]
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            folders.insert(URL(filePath: env), at: 0)
        }
        let swap = home.appending(path: ".claude-swap-backup/sessions")
        folders += (try? FileManager.default.contentsOfDirectory(at: swap, includingPropertiesForKeys: nil)) ?? []
        return folders
    }

    /// What a running Claude says of itself in `<config>/sessions/<pid>.json`.
    nonisolated struct SessionFile: Sendable {
        let id: String
        /// The session's title (auto-title hook, /rename), if it has one.
        let name: String?
        /// Where the session started: its transcript is under this folder's name.
        let cwd: String

        init?(json text: String) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let id = object["sessionId"] as? String
            else { return nil }
            self.id = id
            name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            cwd = object["cwd"] as? String ?? ""
        }
    }

    /// The session a local Claude runs.
    nonisolated static func localSession(pid: Int) -> SessionFile? {
        localSessionAndFolder(pid: pid)?.session
    }

    /// The session a local Claude runs, and the configuration folder that keeps it.
    nonisolated static func localSessionAndFolder(pid: Int) -> (session: SessionFile, folder: URL)? {
        for folder in configFolders {
            if let data = try? Data(contentsOf: folder.appending(path: "sessions/\(pid).json")),
               let info = SessionFile(json: String(decoding: data, as: UTF8.self))
            {
                return (info, folder)
            }
        }
        return nil
    }

    /// Claude's parent, when it is a shell.
    nonisolated static func parentShell(of pid: Int) -> Int? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = Int32(info.pbi_ppid)
        guard let name = LocalProcess.processName(parent) else { return nil }
        return ResumableRun.shells.contains(name) ? Int(parent) : nil
    }

    /// A session's newest transcript on this Mac, in any configuration folder.
    nonisolated static func transcript(of session: String) -> URL? {
        transcriptAndFolder(of: session)?.url
    }

    nonisolated static func transcriptAndFolder(of session: String) -> (url: URL, folder: URL)? {
        let fm = FileManager.default
        var best: (url: URL, date: Date, folder: URL)?
        for folder in configFolders {
            let projects = folder.appending(path: "projects")
            for project in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                let file = project.appending(path: "\(session).jsonl")
                guard let date = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { continue }
                if best == nil || date > best!.date { best = (file, date, folder) }
            }
        }
        return best.map { ($0.url, $0.folder) }
    }

    /// The session's last model and effort, from its newest transcript, and
    /// the model that account starts with.
    nonisolated static func lastModelAndEffort(session: String) -> (model: String?, effort: String?, defaultModel: String?) {
        guard let best = transcriptAndFolder(of: session), let data = try? Data(contentsOf: best.url, options: .mappedIfSafe) else { return (nil, nil, nil) }
        var defaultModel: String?
        if let settings = try? Data(contentsOf: best.folder.appending(path: "settings.json")),
           let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any]
        {
            defaultModel = object["model"] as? String
        }
        // From the end: the last values win.
        var model: String?
        var effort: String?
        let modelKey = Data(#""model":""#.utf8)
        let effortKey = Data(#""effort":""#.utf8)
        var end = data.endIndex
        while end > data.startIndex, model == nil || effort == nil {
            let start = data[..<end].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.startIndex
            let line = data[start ..< end]
            end = start > data.startIndex ? start - 1 : data.startIndex
            guard line.range(of: modelKey) != nil || line.range(of: effortKey) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            if effort == nil, let e = object["effort"] as? String { effort = e }
            if model == nil, let message = object["message"] as? [String: Any], let m = message["model"] as? String, m != "<synthetic>" {
                model = m
            }
        }
        return (model, effort, defaultModel)
    }
}

/// Where a terminal shows: its space, tab (and the tab's index) and pane.
struct TerminalPlace {
    let space: SpaceItem
    let tab: LayoutTab
    let index: Int
    let pane: String
}

/// An agent's session, as found running in a terminal.
struct AgentSession: Equatable {
    let agent: ResumableAgent
    let id: String
}
