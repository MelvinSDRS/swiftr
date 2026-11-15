import AppKit
import HerdrKit
import Observation

/// The + menu's agents: which ones each machine has, asked as herdr-app's
/// `knownAgents` asks (programs.rs), and where the menu is open.
@Observable
final class AgentLauncher {
    /// The + that shows the menu.
    enum MenuPlace {
        case tabStrip
        case toolbar
    }

    var menu: MenuPlace?

    /// Agents found on each machine (by `lookKey`), as `Programs` keys.
    /// Kept between launches, so the menu lists them before it asks again.
    private(set) var installed: [String: Set<String>]
    /// Machines being asked now, and those whose last answer failed.
    private(set) var checking: Set<String> = []
    private(set) var failed: Set<String> = []

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var checkedAt: [String: Date] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let defaultsKey = "installedAgents"

    init(model: AppModel) {
        self.model = model
        let saved = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] ?? [:]
        installed = saved.mapValues(Set.init)
        #if DEBUG
        AgentDebug.install(model)
        #endif
    }

    /// This Mac's login shell, which terminals start in.
    static let localShell: String = {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell, case let path = String(cString: shell), !path.isEmpty {
            return path
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }()

    /// What `terminal.run` starts for `command` on `machine` ("" is this Mac).
    static func argv(_ command: [String], on machine: String) -> [String] {
        AgentLaunch.start(command, shell: machine.isEmpty ? localShell : nil)
    }

    /// The agents `machine` has, if it was ever asked.
    func installed(on machine: String) -> Set<String>? {
        installed[model.lookKey(ofMachine: machine)]
    }

    func isChecking(_ machine: String) -> Bool {
        checking.contains(model.lookKey(ofMachine: machine))
    }

    func checkFailed(_ machine: String) -> Bool {
        failed.contains(model.lookKey(ofMachine: machine))
    }

    /// Asks `machine` which agents it has, in the shell they start in; as
    /// herdr-app, at most once a minute, and again after a failure.
    func check(_ machine: String, force: Bool = false) {
        let key = model.lookKey(ofMachine: machine)
        guard !checking.contains(key), let c = model.connection else { return }
        if !force, !failed.contains(key), let at = checkedAt[key], at.timeIntervalSinceNow > -60 { return }
        let agents = Programs.startable.compactMap { p in p.run?.first.map { (key: p.key, command: $0) } }
        let argv = AgentLaunch.check(agents.map(\.command), shell: machine.isEmpty ? Self.localShell : nil)
        var params: JSON = ["argv": .array(argv.map { .string($0) }), "timeout": 30]
        if machine.isEmpty { params["cwd"] = .string(NSHomeDirectory()) } else { params["on"] = .string(machine) }
        checking.insert(key)
        Task {
            defer { checking.remove(key) }
            let r = try? await c.call("machine.exec", params, timeout: .seconds(40))
            let output = r?["stdout"]?.string.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
            guard let found = output.flatMap(AgentLaunch.installed(in:)) else {
                failed.insert(key)
                return
            }
            failed.remove(key)
            checkedAt[key] = Date()
            let keys = Set(agents.filter { found.contains($0.command) }.map(\.key))
            if installed[key] != keys {
                installed[key] = keys
                defaults.set(installed.mapValues { $0.sorted() }, forKey: Self.defaultsKey)
            }
        }
    }

    #if DEBUG
    /// Tests: says `machine` has these agents, until it is asked again.
    func pretend(_ keys: Set<String>, on machine: String) {
        installed[model.lookKey(ofMachine: machine)] = keys
    }
    #endif

    /// The agents to list for `machine`, as herdr-app's menu: the installed
    /// ones, most picked first, then two it lacks, to show what exists.
    func choices(on machine: String) -> [AgentChoice] {
        guard let found = installed(on: machine) else { return [] }
        let picks = model.prefs.agentPicks
        // The table's order among equals.
        let ordered = Programs.startable.enumerated().sorted { a, b in
            let (pa, pb) = (picks[a.element.key] ?? 0, picks[b.element.key] ?? 0)
            return pa != pb ? pa > pb : a.offset < b.offset
        }.map { $0.element }
        let have = ordered.filter { found.contains($0.key) }.map { AgentChoice(agent: $0, installed: true) }
        if checkFailed(machine) { return have }
        return have + ordered.filter { !found.contains($0.key) }.prefix(2).map { AgentChoice(agent: $0, installed: false) }
    }
}

/// An agent the + menu lists.
struct AgentChoice {
    let agent: Programs.Program
    let installed: Bool
}
