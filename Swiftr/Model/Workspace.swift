import Foundation
import HerdrKit

/// Something in one machine's layout: a space, a tab or a pane. `machine` is
/// "" for this Mac. Ids stay as that machine's document has them; `key`
/// qualifies them the way addresses are (`server/tb…`).
nonisolated struct Place: Hashable, Codable, Sendable {
    var machine: String
    var id: String

    init(_ machine: String, _ id: String) {
        self.machine = machine
        self.id = id
    }

    var key: String { qualify(id, on: machine) }
}

/// `t7` on `server` is `server/t7` from here.
nonisolated func qualify(_ local: String, on machine: String) -> String {
    machine.isEmpty ? local : machine + "/" + local
}

/// The machine part of an address ("" here) and the id on that machine.
nonisolated func splitAddress(_ address: String) -> (machine: String, local: String) {
    guard let slash = address.firstIndex(of: "/") else { return ("", address) }
    return (String(address[..<slash]), String(address[address.index(after: slash)...]))
}

/// A space as the sidebar shows it.
struct SpaceItem: Identifiable, Equatable {
    let machine: String
    let space: LayoutSpace

    var id: String { place.key }
    var place: Place { Place(machine, space.id) }
    var tabs: [LayoutTab] { space.tabs }

    /// Every terminal in the space, as addresses from here.
    var addresses: [String] {
        space.tabs.flatMap { tab in tab.root.terminals.map { qualify($0.terminal, on: machine) } }
    }
}

/// An order shown before the core has it: `token` tells one move from the next.
struct PendingOrder: Equatable {
    let ids: [String]
    let token: Int
}

extension Array where Element: Identifiable, Element.ID == String {
    /// The items `order` names, in that order, then the others as they were.
    func arranged(by order: [String]) -> [Element] {
        order.compactMap { id in first { $0.id == id } } + filter { !order.contains($0.id) }
    }
}

/// The index the item at `from` ends at once put before the item now at `to`
/// (how SwiftUI's `onMove` counts).
func landing(from: Int, before to: Int) -> Int {
    to > from ? to - 1 : to
}

/// A machine and what it shows, in the sidebar's order.
struct MachineItem: Identifiable, Equatable {
    /// "" for this Mac.
    let name: String
    let title: String
    /// An SF Symbol.
    let icon: String
    /// connecting, connected, needs_login or unreachable.
    let state: String
    let why: String?
    let spaces: [SpaceItem]
    let loading: Bool
    let error: String?

    var id: String { name }
    var isConnected: Bool { state == "connected" }
}

/// The agents in one state, as the sidebar shows them.
struct AgentGroup: Identifiable {
    let attention: Attention
    let agents: [TerminalModel]

    var id: Int { attention.rawValue }

    /// What the view state keeps for it when folded.
    var key: String {
        switch attention {
        case .needsYou: "needsYou"
        case .done: "done"
        case .working: "working"
        case .idle, .none: "idle"
        }
    }

    /// The one whose status word changed last first, then the newest terminal.
    static func latestFirst(_ a: TerminalModel, _ b: TerminalModel) -> Bool {
        let (x, y) = (a.statusMs ?? 0, b.statusMs ?? 0)
        if x != y { return x > y }
        if a.createdMs != b.createdMs { return a.createdMs > b.createdMs }
        return a.address < b.address
    }
}

extension LayoutNode {
    /// The panes a person sees: hidden nodes and inactive stack children left out.
    var visibleBlocks: [LayoutNode] {
        if hidden { return [] }
        switch self {
        case .block: return [self]
        case .split(_, _, let children, _, _): return children.flatMap(\.visibleBlocks)
        case .stack(_, let children, let active, _, _):
            let shown = children.first { $0.id == active } ?? children.first
            return shown?.visibleBlocks ?? []
        }
    }

    /// The terminal this block shows, if it is a terminal block.
    var terminal: String? {
        if case .block(_, .terminal(let t), _, _) = self { return t }
        return nil
    }

    /// The container holding `id` and the index of `id` in it.
    func parent(of id: String) -> (container: LayoutNode, index: Int)? {
        for (i, child) in children.enumerated() {
            if child.id == id { return (self, i) }
            if let hit = child.parent(of: id) { return hit }
        }
        return nil
    }
}

/// A folder's short name: "~" for home, the last part otherwise.
func folderName(_ path: String, home: String = NSHomeDirectory()) -> String {
    if path.isEmpty { return "" }
    let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    if trimmed == home || trimmed == "~" { return "~" }
    if trimmed.range(of: #"^/(Users|home)/[^/]+$"#, options: .regularExpression) != nil { return "~" }
    return (trimmed as NSString).lastPathComponent
}
