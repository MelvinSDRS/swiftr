import Darwin
import Foundation
import HerdrKit
import Observation

/// Whose usage a pane shows: the account of the agent running there.
enum UsageAccount: Hashable, Sendable, Codable {
    /// A Claude Code sign-in: its Keychain entry, and the configuration
    /// folder that holds it when the Keychain doesn't.
    case claude(service: String, folder: String)
    /// A Codex home (`CODEX_HOME`, else `~/.codex`).
    case codex(home: String)

    var agent: ChatAgent {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }

    /// The account a Claude Code or Codex started without settings of its
    /// own uses: the default Keychain entry and `~/.claude`, `~/.codex`.
    static func standard(_ agent: ChatAgent, environment: [String: String] = ProcessInfo.processInfo.environment) -> UsageAccount {
        let home = NSHomeDirectory()
        if agent == .codex {
            return .codex(home: environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".codex"))
        }
        return .claude(service: ClaudeUsage.keychainService(environment: environment),
                       folder: ClaudeUsage.configFolder(environment: environment, home: home))
    }
}

/// What is known of an account's usage, and what went wrong reading it.
struct UsageState: Equatable {
    enum Problem: Equatable {
        /// No sign-in found: Claude Code isn't signed in with this account.
        case signedOut
        /// The sign-in Claude Code keeps has run out; Claude Code renews it
        /// the next time it talks to Anthropic.
        case expired
        /// The Keychain didn't give Claude Code's sign-in.
        case keychain(String)
        /// Anthropic asked to wait.
        case busy(until: Date)
        case failed(String)
    }

    var report: UsageReport?
    var problem: Problem?
    var checking = false
    /// The last read, whatever came of it.
    var triedAt: Date?
}

/// Reads the usage limits of the agents whose conversations show, on this
/// Mac: Claude's from Anthropic, as Claude Code's `/usage` does, with the
/// sign-in Claude Code keeps; Codex's from its session files and its app
/// server. Gemini's comes from its own footer (`ClaudeFooter.quota`).
@MainActor @Observable
final class UsageMonitor {
    private(set) var states: [UsageAccount: UsageState] = [:]
    /// Each account's last report, kept across launches: the limits its
    /// plan has, which Settings lists before anything is read again.
    private(set) var seen: [UsageAccount: UsageReport] = [:]

    @ObservationIgnored private unowned let model: AppModel
    /// The account of each agent process, by pid.
    @ObservationIgnored private var accounts: [Int: UsageAccount] = [:]
    /// How to start each Codex home's app server: the running Codex's program.
    @ObservationIgnored private var codexCommands: [String: [String]] = [:]
    @ObservationIgnored private var serverAskedAt: [String: Date] = [:]

    /// Claude: every 3 minutes, a minute after the last read once a turn ends.
    static let claudeEvery: TimeInterval = 180
    static let claudeAfterTurn: TimeInterval = 60
    /// Codex's files: every 2 minutes, and as a turn ends; its app server
    /// at most every 5 minutes, when the files say nothing newer.
    static let codexEvery: TimeInterval = 120
    nonisolated static let serverEvery: TimeInterval = 300

    #if DEBUG
    /// Tests: these reports and this problem instead of real reads, by
    /// `ChatAgent` raw value (Gemini's too).
    var debugReports: [String: UsageReport]?
    var debugProblem: UsageState.Problem?
    /// Tests: what the last reads did, newest last.
    @ObservationIgnored private(set) var debugLog: [String] = []
    #endif

    /// A month without a read: an account no longer used.
    static let forgetAfter: TimeInterval = 30 * 24 * 3600

    #if DEBUG
    /// Debug builds share the installed app's defaults: their test accounts
    /// stay out of its list.
    static let keptKey = "usageSeenDebug"
    #else
    static let keptKey = "usageSeen"
    #endif

    private struct Kept: Codable {
        var account: UsageAccount
        var report: UsageReport
        /// How to start a Codex home's app server.
        var command: [String]?
    }

    init(model: AppModel) {
        self.model = model
        let since = Date().addingTimeInterval(-Self.forgetAfter)
        if let data = UserDefaults.standard.data(forKey: Self.keptKey),
           let kept = try? JSONDecoder().decode([Kept].self, from: data)
        {
            for k in kept where k.report.at > since {
                seen[k.account] = k.report
                if case .codex(let home) = k.account, let command = k.command { codexCommands[home] = command }
            }
        }
    }

    private func keep() {
        let kept = seen.map { account, report in
            var command: [String]?
            if case .codex(let home) = account { command = codexCommands[home] }
            return Kept(account: account, report: report, command: command)
        }
        if let data = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(data, forKey: Self.keptKey) }
    }

    /// The account of the agent in front in `address`'s terminal, when it is
    /// Claude or Codex on this Mac.
    func account(of address: String) -> UsageAccount? {
        guard let r = model.store.model(address), r.isLive, r.machine == nil, let fg = r.foreground,
              let agent = ChatAgent(record: r), agent == .claude || agent == .codex
        else { return nil }
        if let known = accounts[fg.pid], known.agent == agent { return known }
        let account = UsageAccount.standard(agent, environment: LocalProcess.environment(of: pid_t(fg.pid)))
        if case .codex(let home) = account, let command = Self.codexCommand(pid: fg.pid, argv: fg.argv, cwd: fg.cwd) {
            codexCommands[home] = command
        }
        if accounts.count > 64 { accounts.removeAll() }
        accounts[fg.pid] = account
        return account
    }

    func state(of account: UsageAccount) -> UsageState? {
        #if DEBUG
        if let reports = debugReports {
            return UsageState(report: reports[account.agent.rawValue], problem: debugProblem, triedAt: Date())
        }
        #endif
        return states[account]
    }

    /// The freshest report of an agent's accounts, for Settings' preview.
    func latest(of agent: ChatAgent) -> UsageReport? {
        reports(of: agent).first
    }

    /// The reports of an agent's accounts, read now or kept, newest first.
    private func reports(of agent: ChatAgent) -> [UsageReport] {
        #if DEBUG
        if let reports = debugReports { return reports[agent.rawValue].map { [$0] } ?? [] }
        #endif
        var reports = seen.filter { $0.key.agent == agent }
        for (account, state) in states where account.agent == agent {
            if let report = state.report, reports[account].map({ report.at >= $0.at }) ?? true { reports[account] = report }
        }
        return reports.values.sorted { $0.at > $1.at }
    }

    /// The limits the plans of an agent's accounts have, as their last
    /// replies list them, newest first; Gemini's one quota, the day's.
    func limits(of agent: ChatAgent) -> [UsageWindow] {
        if agent == .gemini { return [UsageWindow(id: "daily", title: "Daily", used: 0, length: 24 * 3600)] }
        var out: [UsageWindow] = []
        for report in reports(of: agent) {
            for w in report.windows where !out.contains(where: { $0.id == w.id }) { out.append(w) }
        }
        return out
    }

    /// The plans of an agent's accounts: "Max 20x".
    func plans(of agent: ChatAgent) -> [String] {
        var out: [String] = []
        for plan in reports(of: agent).compactMap(\.plan) where !out.contains(plan) { out.append(plan) }
        return out
    }

    /// What reading an agent's accounts gives now: still reading, and the
    /// problems of those not read.
    func checking(_ agent: ChatAgent) -> Bool {
        states.contains { $0.key.agent == agent && $0.value.checking }
    }

    func problems(of agent: ChatAgent) -> [UsageState.Problem] {
        #if DEBUG
        if debugReports != nil { return debugProblem.map { [$0] } ?? [] }
        #endif
        return states.filter { $0.key.agent == agent && $0.value.report == nil }.compactMap(\.value.problem)
    }

    /// Settings: reads again the limits of each account of `agent` Swiftr
    /// knows, and of the one it uses by default, when it is time to.
    func check(_ agent: ChatAgent, force: Bool = false) {
        guard agent == .claude || agent == .codex else { return }
        var accounts = Set(seen.keys).union(states.keys).filter { $0.agent == agent }
        accounts.insert(.standard(agent))
        for account in accounts { refresh(account, force: force) }
    }

    /// Reads again when it is time to: `soon` once a turn ended, `force`
    /// for the Refresh button.
    func refresh(_ account: UsageAccount, soon: Bool = false, force: Bool = false) {
        #if DEBUG
        if debugReports != nil { return }
        #endif
        var state = states[account] ?? UsageState()
        guard !state.checking else { return }
        let now = Date()
        if case .busy(let until) = state.problem, until > now { return }
        switch account {
        case .claude(let service, let folder):
            let every = soon ? Self.claudeAfterTurn : Self.claudeEvery
            if !force, let at = state.triedAt, now.timeIntervalSince(at) < every { return }
            // The Keychain asked for permission or said no: not again on its own.
            if !force, case .keychain = state.problem { return }
            state.checking = true
            states[account] = state
            Task {
                let outcome = await Self.readClaude(service: service, folder: folder)
                finish(account, outcome)
            }
        case .codex(let home):
            if !force, !soon, let at = state.triedAt, now.timeIntervalSince(at) < Self.codexEvery { return }
            let askServer = (state.report.map { now.timeIntervalSince($0.at) > Self.serverEvery } ?? true)
                && (force || serverAskedAt[home].map { now.timeIntervalSince($0) > Self.serverEvery } ?? true)
            let command = codexCommands[home] ?? Self.installedCodex()
            if askServer, command != nil { serverAskedAt[home] = now }
            state.checking = true
            states[account] = state
            Task {
                let outcome = await Self.readCodex(home: home, server: askServer ? command : nil, newerThan: state.report?.at)
                finish(account, outcome)
            }
        }
    }

    private func finish(_ account: UsageAccount, _ outcome: Outcome) {
        var state = states[account] ?? UsageState()
        state.checking = false
        state.triedAt = Date()
        switch outcome {
        case .report(let report):
            // A file read may come back with what is already known, or older.
            if state.report.map({ report.at >= $0.at }) ?? true { state.report = report }
            state.problem = nil
            if let report = state.report, seen[account] != report {
                seen[account] = report
                keep()
            }
        case .problem(let problem):
            state.problem = problem
            // Signed out: the old numbers were someone else's, and so are its limits.
            if problem == .signedOut {
                state.report = nil
                if seen.removeValue(forKey: account) != nil { keep() }
            }
        case .nothing:
            break
        }
        states[account] = state
        #if DEBUG
        debugLog.append("\(Date().formatted(.iso8601)) \(account.agent.rawValue): \(outcome.summary)")
        if debugLog.count > 40 { debugLog.removeFirst(debugLog.count - 40) }
        #endif
    }

    enum Outcome: Sendable {
        case report(UsageReport)
        case problem(UsageState.Problem)
        /// Nothing new, nothing wrong.
        case nothing

        var summary: String {
            switch self {
            case .report(let r): "report " + r.windows.map { "\($0.id)=\(Int($0.used))" }.joined(separator: " ")
            case .problem(let p): "problem \(p)"
            case .nothing: "nothing"
            }
        }
    }

    // MARK: Claude

    /// Claude Code's sign-in, then Anthropic's answer. The sign-in is only
    /// read: Swiftr never renews it, which would sign Claude Code out.
    nonisolated static func readClaude(service: String, folder: String) async -> Outcome {
        let signIn: ClaudeUsage.SignIn
        switch await keychainSignIn(service: service) {
        case .found(let found):
            signIn = found
        case .missing:
            // Where Claude Code keeps it without a Keychain.
            let file = (folder as NSString).appendingPathComponent(".credentials.json")
            guard let data = FileManager.default.contents(atPath: file), let found = ClaudeUsage.signIn(fromCredentials: data) else {
                return .problem(.signedOut)
            }
            signIn = found
        case .failed(let why):
            return .problem(.keychain(why))
        }
        if signIn.expired(at: Date()) { return .problem(.expired) }
        var request = URLRequest(url: ClaudeUsage.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + signIn.token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // As the person's own status line asks, which Anthropic answers.
        request.setValue("claude-code/2.1.34 (Swiftr)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200:
                guard let windows = ClaudeUsage.windows(fromReply: data, subscription: signIn.subscription) else {
                    return .problem(.failed("Anthropic's answer had no usage in it."))
                }
                return .report(UsageReport(windows: windows, plan: signIn.plan, at: Date()))
            case 401:
                return .problem(.expired)
            case 429:
                let wait = retryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
                return .problem(.busy(until: Date().addingTimeInterval(min(3600, max(60, wait)))))
            case let code:
                return .problem(.failed("Anthropic answered \(code)" + (code == 403 ? ": this sign-in may not be allowed to read usage." : ".")))
            }
        } catch {
            return .problem(.failed(error.localizedDescription))
        }
    }

    /// Seconds a Retry-After header names, as a number or an HTTP date; 15
    /// minutes without one.
    nonisolated static func retryAfter(_ value: String?) -> TimeInterval {
        guard let value, !value.isEmpty else { return 900 }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) { return seconds }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value).map { $0.timeIntervalSinceNow } ?? 900
    }

    enum KeychainRead: Sendable {
        case found(ClaudeUsage.SignIn)
        case missing
        case failed(String)
    }

    /// Claude Code's sign-in from the Keychain, read with `security` as
    /// Claude Code itself writes and reads it, so macOS doesn't ask. Through
    /// a pipe: the sign-in never touches the disk.
    nonisolated static func keychainSignIn(service: String) async -> KeychainRead {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try process.run()
                } catch {
                    done.resume(returning: .failed("Swiftr couldn't run security: \(error.localizedDescription)"))
                    return
                }
                // A Keychain that asks for permission waits for a click: not that long.
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let said = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                if process.terminationReason == .uncaughtSignal {
                    done.resume(returning: .failed("The Keychain asked for permission and no answer came."))
                    return
                }
                switch process.terminationStatus {
                case 0:
                    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let signIn = ClaudeUsage.signIn(fromCredentials: Data(text.utf8)) ?? hexDecoded(text).flatMap(ClaudeUsage.signIn(fromCredentials:)) {
                        done.resume(returning: .found(signIn))
                    } else {
                        done.resume(returning: .failed("Claude Code's Keychain entry holds no sign-in Swiftr can read."))
                    }
                case 44:
                    // errSecItemNotFound.
                    done.resume(returning: .missing)
                default:
                    let why = String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    done.resume(returning: .failed(why.isEmpty ? "security ended with \(process.terminationStatus)." : why))
                }
            }
        }
    }

    /// `security -w` prints data that isn't text in hex.
    nonisolated static func hexDecoded(_ text: String) -> Data? {
        guard text.count.isMultiple(of: 2), !text.isEmpty, text.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: text.count / 2)
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 2)
            guard let byte = UInt8(text[i ..< j], radix: 16) else { return nil }
            data.append(byte)
            i = j
        }
        return data
    }

    // MARK: Codex

    /// The newest limits in Codex's session files; its app server's answer
    /// when asked and the files have nothing newer.
    nonisolated static func readCodex(home: String, server: [String]?, newerThan known: Date?) async -> Outcome {
        let fromFiles = await Task.detached(priority: .utility) { latestInSessions(home: home) }.value
        var best = fromFiles
        if let server, best.map({ Date().timeIntervalSince($0.at) > serverEvery }) ?? true {
            if let asked = await askServer(command: server, home: home), best.map({ asked.at > $0.at }) ?? true { best = asked }
        }
        guard let best else { return known == nil ? .problem(.failed("Codex hasn't said its limits yet: they come with its first answer.")) : .nothing }
        return .report(best)
    }

    /// The limits in the newest session files of the last week, read from
    /// their ends.
    nonisolated static func latestInSessions(home: String) -> UsageReport? {
        let fm = FileManager.default
        let calendar = Calendar.current
        var files: [(url: URL, date: Date)] = []
        for back in 0 ..< 8 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let dir = URL(filePath: home).appending(path: String(format: "sessions/%04d/%02d/%02d", y, m, d))
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let url = dir.appending(path: name)
                if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    files.append((url, date))
                }
            }
            // The newest few are enough, once some are found.
            if files.count >= 6 { break }
        }
        var best: UsageReport?
        for file in files.sorted(by: { $0.date > $1.date }).prefix(6) {
            if let best, file.date < best.at { break }
            guard let handle = try? FileHandle(forReadingFrom: file.url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
            guard let tail = try? handle.readToEnd(), let report = CodexUsage.latest(inSessionTail: tail) else { continue }
            if best.map({ report.at > $0.at }) ?? true { best = report }
        }
        return best
    }

    /// The program of the Codex running as `pid`, to start its app server
    /// with: its executable, or the runner (node) and Codex's script.
    nonisolated static func codexCommand(pid: Int, argv: [String], cwd: String) -> [String]? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
        if (path as NSString).lastPathComponent.hasPrefix("codex") { return [path] }
        guard let script = argv.dropFirst().first(where: { ($0 as NSString).lastPathComponent.hasPrefix("codex") }) else { return [path] }
        return [path, script.hasPrefix("/") ? script : (cwd as NSString).appendingPathComponent(script)]
    }

    /// Codex where its installers put it, for an account whose Codex Swiftr
    /// hasn't seen run.
    nonisolated static func installedCodex() -> [String]? {
        #if DEBUG
        // Tests: a stand-in, never the real Codex.
        if let program = ProcessInfo.processInfo.environment["SWIFTR_CODEX_PROGRAM"] { return program.split(separator: " ").map(String.init) }
        #endif
        let home = NSHomeDirectory()
        let places = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }.map { [$0] }
    }

    /// Asks `codex app-server` for the account's limits, as Codex's own
    /// clients do: initialize, then `account/rateLimits/read`.
    nonisolated static func askServer(command: [String], home: String) async -> UsageReport? {
        guard let program = command.first else { return nil }
        let process = Process()
        process.executableURL = URL(filePath: program)
        process.arguments = Array(command.dropFirst()) + ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home
        // node finds itself, and Codex its helpers, beside the program.
        let folder = (program as NSString).deletingLastPathComponent
        environment["PATH"] = [folder, environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        process.environment = environment
        process.currentDirectoryURL = URL(filePath: NSHomeDirectory())
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Writing to a server that quit must not end Swiftr.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try process.run()
                } catch {
                    done.resume(returning: nil)
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
                func send(_ message: [String: Any]) {
                    guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
                    data.append(0x0A)
                    try? input.fileHandleForWriting.write(contentsOf: data)
                }
                send(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "swiftr", "title": "Swiftr", "version": "1.0.0"]]])
                var buffer = Data()
                var result: [String: Any]?
                let reader = output.fileHandleForReading
                reading: while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex ..< newline]
                        buffer.removeSubrange(buffer.startIndex ... newline)
                        // Answers only: the server's own requests carry a method, and ids of their own.
                        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              message["method"] == nil
                        else { continue }
                        let id = (message["id"] as? NSNumber)?.intValue
                        if id == 1 {
                            send(["method": "initialized", "params": [String: Any]()])
                            send(["method": "account/rateLimits/read", "id": 2])
                        } else if id == 2 {
                            result = message["result"] as? [String: Any]
                            break reading
                        }
                    }
                }
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                // One that doesn't quit when asked.
                let kill = DispatchWorkItem { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: kill)
                process.waitUntilExit()
                kill.cancel()
                deadline.cancel()
                done.resume(returning: result.flatMap { CodexUsage.report(fromServerResult: $0, at: Date()) })
            }
        }
    }
}
