import Foundation
import Observation

/// What a program reported through OSC 7501 (`idle`, `working`, `done`, `blocked`, `error`...).
public struct AgentStatus: Sendable, Equatable {
    public var state: String
    public var app: String?
    public var message: String?
    public var title: String?
    public var progress: Int?
    /// What a blocked program waits for: permission, question or auth.
    public var kind: String?

    public init(state: String, message: String? = nil, kind: String? = nil) {
        self.state = state
        self.message = message
        self.kind = kind
    }

    public init?(json: JSON?) {
        guard let json, let state = json["state"]?.string else { return nil }
        self.state = state
        app = json["app"]?.string
        message = json["msg"]?.string
        title = json["title"]?.string
        progress = json["progress"]?.int
        kind = json["kind"]?.string
    }
}

/// The foreground process group's leader and its folder.
public struct ForegroundProcess: Sendable, Equatable {
    public var pid: Int
    public var name: String
    public var argv: [String]
    public var cwd: String

    public init?(json: JSON?) {
        guard let json, let pid = json["pid"]?.int else { return nil }
        self.pid = pid
        name = json["name"]?.string ?? ""
        argv = json["argv"]?.stringArray ?? []
        cwd = json["cwd"]?.string ?? ""
    }

    /// The program's own name (`claude`, `zsh`...).
    public var program: String {
        let first = argv.first.map { ($0 as NSString).lastPathComponent } ?? ""
        return first.isEmpty ? name : first
    }
}

/// How an agent shows, from most to least urgent (docs/labels.md in herdr-app).
public enum Attention: Int, Sendable, Comparable, CaseIterable {
    case none = 0
    case idle = 1
    case working = 2
    case done = 3
    case needsYou = 4

    public static func < (a: Attention, b: Attention) -> Bool { a.rawValue < b.rawValue }
}

/// How events change a terminal record (schema/README.md, "Events").
public enum TerminalEvents {
    /// Applies one event to `record`. Returns false for events this client ignores.
    /// `nowMs`: the time, ms since 1970, for what the event leaves out.
    @discardableResult
    public static func apply(type: String, data: JSON, to record: inout JSON, nowMs: Int64 = TerminalEvents.currentMs()) -> Bool {
        func set(_ keys: [String]) {
            for k in keys { record[k] = data[k] ?? .null }
        }
        switch type {
        case "finished", "lost":
            set(["reason", "exit_code", "signal", "finished_ms"])
            record["state"] = .string(type == "lost" ? "live" : "finished")
            if type == "lost" { record["pid"] = .null }
            record["foreground"] = nil
        case "status":
            let word = record["status"]?["state"]?.string
            set(["status", "records", "reported"])
            // The record says when the word last changed; the event doesn't.
            if let ms = data["status_ms"], !ms.isNull {
                record["status_ms"] = ms
            } else if record["status"]?["state"]?.string != word {
                record["status_ms"] = .int(nowMs)
            }
        case "turn":
            set(["turn"])
        case "title":
            set(["title"])
        case "labels":
            set(["labels"])
        case "keep":
            set(["keep"])
        case "size":
            set(["cols", "rows"])
        case "foreground":
            record["foreground"] = data.isNull ? nil : data
        default:
            return false
        }
        return true
    }

    /// Now, in ms since 1970, as the core counts time.
    public static func currentMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}

/// One terminal, kept up to date by events. Views watch only the fields they read.
@MainActor @Observable
public final class TerminalModel: Identifiable {
    public nonisolated let address: String
    public nonisolated var id: String { address }

    public private(set) var record: JSON = .null
    public private(set) var state = ""
    public private(set) var title = ""
    public private(set) var status: AgentStatus?
    /// When the status word last changed, ms since 1970; nil if it never said.
    public private(set) var statusMs: Int64?
    public private(set) var turn = 0
    public private(set) var labels: [String: String] = [:]
    public private(set) var foreground: ForegroundProcess?
    public private(set) var cols = 0
    public private(set) var rows = 0
    public private(set) var cwd = ""
    public private(set) var argv: [String] = []
    public private(set) var keep = false
    public private(set) var parent: String?
    public private(set) var pid: Int?
    public private(set) var reason: String?
    public private(set) var createdMs: Int64 = 0
    public private(set) var name: String?

    public init(record: JSON) {
        address = record["address"]?.string ?? ""
        replace(record)
    }

    func replace(_ record: JSON) {
        self.record = record
        if state != (record["state"]?.string ?? "") { state = record["state"]?.string ?? "" }
        if title != (record["title"]?.string ?? "") { title = record["title"]?.string ?? "" }
        let status = AgentStatus(json: record["status"])
        if self.status != status { self.status = status }
        let statusMs = record["status_ms"]?.int64
        if self.statusMs != statusMs { self.statusMs = statusMs }
        let turn = record["turn"]?.int ?? 0
        if self.turn != turn { self.turn = turn }
        let labels = record["labels"]?.stringMap ?? [:]
        if self.labels != labels { self.labels = labels }
        let fg = ForegroundProcess(json: record["foreground"])
        if foreground != fg { foreground = fg }
        let cols = record["cols"]?.int ?? 0
        if self.cols != cols { self.cols = cols }
        let rows = record["rows"]?.int ?? 0
        if self.rows != rows { self.rows = rows }
        let cwd = record["cwd"]?.string ?? ""
        if self.cwd != cwd { self.cwd = cwd }
        let argv = record["argv"]?.stringArray ?? []
        if self.argv != argv { self.argv = argv }
        let keep = record["keep"]?.bool ?? false
        if self.keep != keep { self.keep = keep }
        let parent = record["parent"]?.string
        if self.parent != parent { self.parent = parent }
        let pid = record["pid"]?.int
        if self.pid != pid { self.pid = pid }
        let reason = record["reason"]?.string
        if self.reason != reason { self.reason = reason }
        let created = record["created_ms"]?.int64 ?? 0
        if createdMs != created { createdMs = created }
        let name = record["name"]?.string
        if self.name != name { self.name = name }
    }

    public var isLive: Bool { state == "live" }

    /// The machine this terminal runs on, as this core names it; nil here.
    public nonisolated var machine: String? {
        address.firstIndex(of: "/").map { String(address[..<$0]) }
    }

    /// The address on its own machine (`t7` for `server/t7`).
    public nonisolated var localID: String {
        address.firstIndex(of: "/").map { String(address[address.index(after: $0)...]) } ?? address
    }

    /// The last turn a person looked at, on any client (`herdr.seen`).
    public var seen: Int? { labels["herdr.seen"].flatMap { Int($0) } }

    public var isAgent: Bool { status != nil }

    public var isClaude: Bool {
        guard let fg = foreground else { return false }
        return fg.program == "claude" || fg.name == "claude"
    }

    /// blocked/error > done (finished since last looked) > working > idle.
    public var attention: Attention {
        guard let status else { return .none }
        switch status.state {
        case "blocked", "error": return .needsYou
        case "working": return .working
        default:
            if let seen { return turn > seen ? .done : .idle }
            return status.state == "done" ? .done : .idle
        }
    }

    /// The folder now: the foreground program's, else the terminal's start folder.
    public var currentFolder: String {
        if let fg = foreground, !fg.cwd.isEmpty { return fg.cwd }
        return cwd
    }
}

/// Every terminal the event stream describes (local and relayed remote ones).
@MainActor @Observable
public final class TerminalStore {
    public enum Change: Sendable {
        /// A fresh snapshot replaced everything (subscribe or `missed`).
        case reset
        /// One event, applied; `previous` is the record before it.
        case event(type: String, address: String, data: JSON, previous: JSON?)
        /// A layout or other document changed on a machine (nil: this one).
        case document(name: String, machine: String?, version: Int64)
    }

    /// Addresses in the core's order. Changes only when terminals come or go.
    public private(set) var order: [String] = []
    @ObservationIgnored public private(set) var models: [String: TerminalModel] = [:]
    @ObservationIgnored public private(set) var seq: Int64 = 0
    @ObservationIgnored public var onChange: ((Change) -> Void)?
    /// A "working" from rest shows once it has lasted this long. A command
    /// that starts no turn can make an agent say working for a moment
    /// (Claude Code as /model's menu closes, while hooks run): its row
    /// would jump to Working and back.
    @ObservationIgnored public var workingHold: Duration = .seconds(1)
    /// Each terminal's "working" still in its hold: the event, when it came,
    /// and the timer that shows it.
    @ObservationIgnored private var held: [String: (params: JSON, ms: Int64, timer: Task<Void, Never>)] = [:]
    /// When a message last went to a terminal: the turn it starts shows at once.
    @ObservationIgnored private var expecting: [String: ContinuousClock.Instant] = [:]

    public init() {}

    /// A message went to `address`: its next "working" shows at once.
    public func expectWork(_ address: String) {
        expecting[address] = .now
    }

    /// `turn` was seen here (`herdr.seen`): it shows so at once, before the
    /// core sends the label back. Even a moment of work ends a turn, and its
    /// row would sit under Done until then.
    public func noteSeen(_ address: String, turn: Int) {
        guard let m = models[address], turn > (m.seen ?? 0) else { return }
        var record = m.record
        var labels = record["labels"] ?? .object([:])
        labels["herdr.seen"] = .string(String(turn))
        record["labels"] = labels
        m.replace(record)
    }

    public func model(_ address: String) -> TerminalModel? { models[address] }

    public var all: [TerminalModel] { order.compactMap { models[$0] } }

    public func reset(seq: Int64, terminals: [JSON]) {
        self.seq = seq
        for address in held.keys { dropHeld(address) }
        var next: [String: TerminalModel] = [:]
        var order: [String] = []
        for record in terminals {
            guard let address = record["address"]?.string else { continue }
            if let m = models[address] {
                m.replace(record)
                next[address] = m
            } else {
                next[address] = TerminalModel(record: record)
            }
            order.append(address)
        }
        models = next
        if self.order != order { self.order = order }
        onChange?(.reset)
    }

    /// Applies event-stream messages (`event`, `missed`, `heartbeat`).
    public func apply(_ messages: [JSON]) {
        for message in messages {
            let params = message["params"] ?? .null
            switch message["method"]?.string {
            case "missed":
                reset(seq: params["seq"]?.int64 ?? seq, terminals: params["terminals"]?.array ?? [])
            case "event":
                if let s = params["seq"]?.int64 {
                    if s <= seq { continue }
                    seq = s
                }
                applyEvent(params)
            default:
                break
            }
        }
    }

    private func applyEvent(_ params: JSON) {
        let type = params["type"]?.string ?? ""
        var data = params["data"] ?? .null
        if type == "doc" {
            onChange?(.document(name: data["name"]?.string ?? "", machine: params["machine"]?.string, version: data["version"]?.int64 ?? 0))
            return
        }
        guard let address = params["terminal"]?.string ?? data["address"]?.string else { return }
        if type == "status" {
            switch hold(params, word: data["status"]?["state"]?.string, address: address) {
            case .waits:
                return
            case .ended:
                // As far as views go the word never changed, so neither did
                // when: the row keeps its place among the agents, and its time.
                if let ms = models[address]?.record["status_ms"], !ms.isNull { data["status_ms"] = ms }
            case .shows:
                break
            }
        }
        if ["created", "restarted", "removed", "finished", "lost"].contains(type) { dropHeld(address) }
        applyNow(type: type, data: data, address: address)
    }

    private enum Hold {
        case waits, shows
        /// Back at rest within the hold: it never worked as far as views go.
        case ended
    }

    /// What becomes of this status event: a "working" from rest waits, and
    /// a newer word for one that waits takes its place, unless a message
    /// just went there.
    private func hold(_ params: JSON, word: String?, address: String) -> Hold {
        if held[address] != nil {
            if word == "working" {
                held[address]?.params = params
                return .waits
            }
            dropHeld(address)
            return word == nil || ["blocked", "error"].contains(word) ? .shows : .ended
        }
        guard word == "working", let m = models[address], !["working", "blocked", "error"].contains(m.status?.state) else { return .shows }
        if let sent = expecting.removeValue(forKey: address), sent.duration(to: .now) < .seconds(30) { return .shows }
        let hold = workingHold
        let timer = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled, let self, let event = self.held.removeValue(forKey: address) else { return }
            let data = event.params["data"] ?? .null
            self.applyNow(type: "status", data: data, address: address, nowMs: event.ms)
        }
        held[address] = (params, TerminalEvents.currentMs(), timer)
        return .waits
    }

    private func dropHeld(_ address: String) {
        held.removeValue(forKey: address)?.timer.cancel()
    }

    private func applyNow(type: String, data: JSON, address: String, nowMs: Int64 = TerminalEvents.currentMs()) {
        let previous = models[address]?.record
        let whole: JSON? = switch type {
        case "created", "restarted": data
        case "labels": data["record"]
        default: nil
        }
        if let whole, !whole.isNull {
            if let m = models[address] {
                m.replace(whole)
            } else {
                models[address] = TerminalModel(record: whole)
                order.append(address)
            }
        } else if type == "removed" {
            guard models.removeValue(forKey: address) != nil else { return }
            order.removeAll { $0 == address }
        } else if let m = models[address] {
            var record = m.record
            guard TerminalEvents.apply(type: type, data: data, to: &record, nowMs: nowMs) else { return }
            m.replace(record)
        } else {
            return
        }
        onChange?(.event(type: type, address: address, data: data, previous: previous))
    }
}
