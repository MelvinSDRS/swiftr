import HerdrKit
import SwiftUI

/// The agents whose panes can show as a conversation. Each has its own pane
/// in Settings: how its panes open, and the usage under its field.
enum ChatAgent: String, CaseIterable, Identifiable {
    case claude
    case codex
    case opencode
    case gemini

    /// Its `Programs` key.
    var id: String { rawValue }

    init(_ agent: TranscriptFeed.Agent) {
        switch agent {
        case .claude: self = .claude
        case .codex: self = .codex
        case .opencode: self = .opencode
        case .gemini: self = .gemini
        }
    }

    /// The agent running in front in a terminal, if it is one of these.
    init?(record: TerminalModel) {
        if record.isCodex { self = .codex } else if record.isOpenCode { self = .opencode } else if record.isGemini { self = .gemini } else if record.isClaude { self = .claude } else { return nil }
    }

    /// As its pane in Settings names it.
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .gemini: "Gemini"
        }
    }

    /// As sentences name it: "Claude panes open as".
    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .gemini: "Gemini"
        }
    }

    /// It has limits Swiftr can read: all but OpenCode, whose providers
    /// count their own.
    var hasUsage: Bool { self != .opencode }

    /// It draws a status line under its input that Messages can show:
    /// OpenCode's says what the chips say.
    var hasStatusLine: Bool { self != .opencode }
}

/// What the usage under an agent's field shows. The limits themselves come
/// from each account's own reply (`UsageMonitor.limits(of:)`): only those its
/// plan has.
struct UsageSettings: Equatable {
    var shown = true
    /// The person's order, by `UsageWindow` id. Limits not in it follow, in
    /// the order the agent gives them.
    var order: [String] = []
    /// Limits the person turned on or off. The others show, but for credits.
    var choices: [String: Bool] = [:]
    /// "45% left" rather than "55% used".
    var countsLeft = true
    /// When each limit starts over: "2h 5m".
    var showsResets = true

    init() {}

    init(plist: [String: Any], agent: ChatAgent) {
        shown = plist["shown"] as? Bool ?? true
        order = plist["order"] as? [String] ?? []
        choices = plist["choices"] as? [String: Bool] ?? [:]
        countsLeft = plist["countsLeft"] as? Bool ?? true
        showsResets = plist["showsResets"] as? Bool ?? true
        // Before, `limits` held those shown among a list fixed for each agent.
        if plist["order"] == nil, plist["choices"] == nil, let picked = plist["limits"] as? [String] {
            let listed = Self.listedBefore(agent)
            order = picked + listed.filter { !picked.contains($0) }
            for id in listed { choices[id] = picked.contains(id) }
        }
    }

    /// The limits Settings listed for each agent until 2026-11-14.
    private static func listedBefore(_ agent: ChatAgent) -> [String] {
        switch agent {
        case .claude: ["session", "weekly", "model:fable", "model:sonnet", "model:opus", "credits"]
        case .codex: ["session", "daily", "weekly", "monthly"]
        case .gemini: ["daily"]
        case .opencode: []
        }
    }

    var plist: [String: Any] {
        ["shown": shown, "order": order, "choices": choices, "countsLeft": countsLeft, "showsResets": showsResets]
    }

    /// Credits stay hidden until the person picks them.
    func shows(_ id: String) -> Bool {
        choices[id] ?? !UsageWindow.isCredit(id)
    }

    /// `windows` in the person's order: those shown, or `all` of them.
    func arrange(_ windows: [UsageWindow], all: Bool = false) -> [UsageWindow] {
        var rank: [String: Int] = [:]
        for (i, id) in order.enumerated() where rank[id] == nil { rank[id] = i }
        let sorted = windows.enumerated().sorted { a, b in
            switch (rank[a.element.id], rank[b.element.id]) {
            case let (x?, y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
        return all ? sorted : sorted.filter { shows($0.id) }
    }

    /// Moves a limit one place up (-1) or down (1) among `listed`, the
    /// limits Settings shows in their order.
    mutating func move(_ id: String, by step: Int, among listed: [String]) {
        guard let i = listed.firstIndex(of: id), listed.indices.contains(i + step) else { return }
        var ids = listed
        ids.swapAt(i, i + step)
        order = ids + order.filter { !ids.contains($0) }
    }
}
