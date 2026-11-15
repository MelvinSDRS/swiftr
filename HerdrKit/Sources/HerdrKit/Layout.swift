import Foundation

/// Side by side (`row`) or stacked (`column`).
public enum SplitAxis: String, Sendable {
    case row
    case column
}

/// A node's share of its row or column.
public enum NodeSize: Sendable, Equatable {
    case weight(Double)
    case px(Double)

    init?(json: JSON?) {
        guard let json else { return nil }
        if let w = json["weight"]?.double { self = .weight(w) } else if let p = json["px"]?.double { self = .px(p) } else { return nil }
    }

    var json: JSON {
        switch self {
        case .weight(let w): ["weight": .double(w)]
        case .px(let p): ["px": .double(p)]
        }
    }
}

/// What a block shows.
public enum BlockContent: Sendable, Equatable {
    case terminal(String)
    case mod(String)
    case tab(String)
    case agent(String)
    case other

    init(json: JSON?) {
        if let t = json?["terminal"]?.string { self = .terminal(t) }
        else if let m = json?["mod"]?.string { self = .mod(m) }
        else if let t = json?["tab"]?.string ?? json?["context"]?.string { self = .tab(t) }
        else if let a = json?["agent"]?.string { self = .agent(a) }
        else { self = .other }
    }
}

/// A read-only view of one layout node (layout.rs in herdr-app).
public indirect enum LayoutNode: Sendable, Equatable, Identifiable {
    case block(id: String, content: BlockContent, size: NodeSize?, hidden: Bool)
    case split(id: String, axis: SplitAxis, children: [LayoutNode], size: NodeSize?, hidden: Bool)
    case stack(id: String, children: [LayoutNode], active: String?, size: NodeSize?, hidden: Bool)

    public init(json: JSON) {
        let id = json["id"]?.string ?? ""
        let size = NodeSize(json: json["size"])
        let hidden = json["hidden"]?.bool ?? false
        let children = (json["children"]?.array ?? []).map(LayoutNode.init(json:))
        switch json["type"]?.string {
        case "row": self = .split(id: id, axis: .row, children: children, size: size, hidden: hidden)
        case "column": self = .split(id: id, axis: .column, children: children, size: size, hidden: hidden)
        case "stack": self = .stack(id: id, children: children, active: json["active"]?.string, size: size, hidden: hidden)
        default: self = .block(id: id, content: BlockContent(json: json["content"]), size: size, hidden: hidden)
        }
    }

    public var id: String {
        switch self {
        case .block(let id, _, _, _), .split(let id, _, _, _, _), .stack(let id, _, _, _, _): id
        }
    }

    public var size: NodeSize? {
        switch self {
        case .block(_, _, let s, _), .split(_, _, _, let s, _), .stack(_, _, _, let s, _): s
        }
    }

    public var hidden: Bool {
        switch self {
        case .block(_, _, _, let h), .split(_, _, _, _, let h), .stack(_, _, _, _, let h): h
        }
    }

    public var children: [LayoutNode] {
        switch self {
        case .block: []
        case .split(_, _, let c, _, _), .stack(_, let c, _, _, _): c
        }
    }

    /// Blocks in tree order.
    public var blocks: [LayoutNode] {
        if case .block = self { return [self] }
        return children.flatMap(\.blocks)
    }

    /// Terminal blocks: (pane id, terminal address on its machine).
    public var terminals: [(pane: String, terminal: String)] {
        blocks.compactMap { node in
            if case .block(let id, .terminal(let t), _, _) = node { return (id, t) }
            return nil
        }
    }

    public func find(_ id: String) -> LayoutNode? {
        if self.id == id { return self }
        for c in children {
            if let f = c.find(id) { return f }
        }
        return nil
    }
}

public struct LayoutTab: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var root: LayoutNode
}

public struct LayoutSpace: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var folder: String
    public var tabs: [LayoutTab]
}

/// What removing a pane closed with it.
public enum PaneRemoval: Sendable, Equatable {
    case notFound
    case pane
    /// The pane was its tab's last: the tab went too.
    case tab(String)
    /// ...and the tab was its space's last: the space went too.
    case space(String)
}

/// One machine's `herdr-app` document: spaces, tabs and their pane trees.
/// Edits work on the JSON itself, so fields this client doesn't read stay.
public struct LayoutDocument: Sendable, Equatable {
    public private(set) var raw: JSON {
        didSet { spaces = Self.spaces(in: raw) }
    }

    /// The spaces, read from the JSON once per change: the views ask for
    /// them many times each time the window updates.
    public private(set) var spaces: [LayoutSpace] = []

    public init(_ raw: JSON?) {
        if let raw, raw.object != nil { self.raw = raw } else { self.raw = ["spaces": []] }
        if self.raw["spaces"]?.array == nil { self.raw["spaces"] = [] }
        spaces = Self.spaces(in: self.raw)
    }

    public static func == (a: LayoutDocument, b: LayoutDocument) -> Bool {
        a.raw == b.raw
    }

    private static func spaces(in raw: JSON) -> [LayoutSpace] {
        (raw["spaces"]?.array ?? []).map { s in
            LayoutSpace(
                id: s["id"]?.string ?? "",
                name: s["name"]?.string ?? "",
                folder: s["folder"]?.string ?? "",
                tabs: (s["tabs"]?.array ?? []).map { t in
                    LayoutTab(id: t["id"]?.string ?? "", name: t["name"]?.string ?? "", root: LayoutNode(json: t["root"] ?? ["id": t["id"] ?? "", "type": "row", "children": []]))
                }
            )
        }
    }

    // MARK: Building blocks

    /// A fresh id like herdr-app's: the prefix, then 32 hex digits.
    public static func freshID(_ prefix: String) -> String {
        prefix + String(format: "%016llx%016llx", UInt64.random(in: .min ... .max), UInt64.random(in: .min ... .max))
    }

    public static func pane(id: String, terminal: String) -> JSON {
        ["id": .string(id), "type": "block", "content": ["terminal": .string(terminal)]]
    }

    /// A tab whose root row holds one pane (model.rs `Tab::with_pane`).
    public static func tab(id: String, name: String, pane: JSON) -> JSON {
        ["id": .string(id), "name": .string(name), "root": ["id": .string(id), "type": "row", "children": [pane]]]
    }

    public static func space(id: String, name: String, folder: String, tabs: [JSON]) -> JSON {
        ["id": .string(id), "name": .string(name), "folder": .string(folder), "tabs": .array(tabs)]
    }

    // MARK: Lookups

    public func space(_ id: String) -> LayoutSpace? { spaces.first { $0.id == id } }

    /// Where a pane (or any node) lives.
    public func location(of nodeID: String) -> (space: String, tab: String)? {
        for s in spaces {
            for t in s.tabs where t.root.find(nodeID) != nil {
                return (s.id, t.id)
            }
        }
        return nil
    }

    public func location(ofTab tabID: String) -> String? {
        spaces.first { $0.tabs.contains { $0.id == tabID } }?.id
    }

    /// The pane showing `terminal` (an address on this document's machine).
    public func pane(showing terminal: String) -> String? {
        for s in spaces {
            for t in s.tabs {
                if let hit = t.root.terminals.first(where: { $0.terminal == terminal }) { return hit.pane }
            }
        }
        return nil
    }

    // MARK: Spaces

    public mutating func addSpace(_ space: JSON, at index: Int? = nil) {
        var list = raw["spaces"]?.array ?? []
        let i = min(index ?? list.count, list.count)
        list.insert(space, at: i)
        raw["spaces"] = .array(list)
    }

    @discardableResult
    public mutating func removeSpace(_ id: String) -> JSON? {
        var list = raw["spaces"]?.array ?? []
        guard let i = list.firstIndex(where: { $0["id"]?.string == id }) else { return nil }
        let removed = list.remove(at: i)
        raw["spaces"] = .array(list)
        return removed
    }

    @discardableResult
    public mutating func renameSpace(_ id: String, to name: String) -> Bool {
        editSpace(id) { $0["name"] = .string(name) }
    }

    @discardableResult
    public mutating func moveSpace(_ id: String, to index: Int) -> Bool {
        var list = raw["spaces"]?.array ?? []
        guard let i = list.firstIndex(where: { $0["id"]?.string == id }) else { return false }
        let s = list.remove(at: i)
        list.insert(s, at: max(0, min(index, list.count)))
        raw["spaces"] = .array(list)
        return true
    }

    private mutating func editSpace(_ id: String, _ edit: (inout JSON) -> Void) -> Bool {
        var list = raw["spaces"]?.array ?? []
        guard let i = list.firstIndex(where: { $0["id"]?.string == id }) else { return false }
        edit(&list[i])
        raw["spaces"] = .array(list)
        return true
    }

    // MARK: Tabs

    /// Adds `tab` to a space, after `after` (else at the end).
    @discardableResult
    public mutating func addTab(_ tab: JSON, toSpace spaceID: String, after: String? = nil) -> Bool {
        editSpace(spaceID) { s in
            var tabs = s["tabs"]?.array ?? []
            let at = after.flatMap { a in tabs.firstIndex { $0["id"]?.string == a } }.map { $0 + 1 } ?? tabs.count
            tabs.insert(tab, at: at)
            s["tabs"] = .array(tabs)
        }
    }

    /// Removes a tab; a space left without tabs goes too.
    @discardableResult
    public mutating func removeTab(_ tabID: String) -> PaneRemoval {
        guard let spaceID = location(ofTab: tabID) else { return .notFound }
        var emptied = false
        _ = editSpace(spaceID) { s in
            var tabs = s["tabs"]?.array ?? []
            tabs.removeAll { $0["id"]?.string == tabID }
            emptied = tabs.isEmpty
            s["tabs"] = .array(tabs)
        }
        if emptied {
            removeSpace(spaceID)
            return .space(spaceID)
        }
        return .tab(tabID)
    }

    @discardableResult
    public mutating func renameTab(_ tabID: String, to name: String) -> Bool {
        editTab(tabID) { $0["name"] = .string(name) }
    }

    @discardableResult
    public mutating func moveTab(_ tabID: String, to index: Int) -> Bool {
        guard let spaceID = location(ofTab: tabID) else { return false }
        return editSpace(spaceID) { s in
            var tabs = s["tabs"]?.array ?? []
            guard let i = tabs.firstIndex(where: { $0["id"]?.string == tabID }) else { return }
            let t = tabs.remove(at: i)
            tabs.insert(t, at: max(0, min(index, tabs.count)))
            s["tabs"] = .array(tabs)
        }
    }

    private mutating func editTab(_ tabID: String, _ edit: (inout JSON) -> Void) -> Bool {
        guard let spaceID = location(ofTab: tabID) else { return false }
        return editSpace(spaceID) { s in
            var tabs = s["tabs"]?.array ?? []
            guard let i = tabs.firstIndex(where: { $0["id"]?.string == tabID }) else { return }
            edit(&tabs[i])
            s["tabs"] = .array(tabs)
        }
    }

    private mutating func editRoot(ofTab tabID: String, _ edit: (inout JSON) -> Bool) -> Bool {
        var changed = false
        _ = editTab(tabID) { t in
            var root = t["root"] ?? ["id": t["id"] ?? "", "type": "row", "children": []]
            changed = edit(&root)
            if changed { t["root"] = root }
        }
        return changed
    }

    // MARK: Panes

    /// Puts `newPane` after `target` along `axis`: into the parent if it runs
    /// that way (taking half the target's share), else wrapping the target
    /// in a new container `containerID` (layout.rs `split`).
    @discardableResult
    public mutating func split(_ target: String, axis: SplitAxis, newPane: JSON, containerID: String) -> Bool {
        guard let tabID = location(of: target)?.tab else { return false }
        return editRoot(ofTab: tabID) { root in Self.split(&root, target: target, axis: axis, newPane: newPane, containerID: containerID) }
    }

    private static func split(_ node: inout JSON, target: String, axis: SplitAxis, newPane: JSON, containerID: String) -> Bool {
        guard var children = node["children"]?.array else { return false }
        if let i = children.firstIndex(where: { $0["id"]?.string == target }) {
            if node["type"]?.string == axis.rawValue {
                let share: Double = switch NodeSize(json: children[i]["size"]) {
                case .weight(let w): w
                default: 1.0
                }
                if case .px = NodeSize(json: children[i]["size"]) {} else {
                    children[i]["size"] = NodeSize.weight(share / 2).json
                }
                var new = newPane
                new["size"] = NodeSize.weight(share / 2).json
                children.insert(new, at: i + 1)
            } else {
                var old = children[i]
                let slot = old["size"]
                old["size"] = nil
                var new = newPane
                new["size"] = nil
                var wrapper: JSON = ["id": .string(containerID), "type": .string(axis.rawValue), "children": [old, new]]
                if let slot, !slot.isNull { wrapper["size"] = slot }
                children[i] = wrapper
            }
            node["children"] = .array(children)
            return true
        }
        for i in children.indices where split(&children[i], target: target, axis: axis, newPane: newPane, containerID: containerID) {
            node["children"] = .array(children)
            return true
        }
        return false
    }

    /// Removes a pane; its share goes to the neighbor it was split from.
    /// Rows and columns left with one child give way to it; a tab left
    /// without panes closes, and a space left without tabs too.
    @discardableResult
    public mutating func removePane(_ paneID: String) -> PaneRemoval {
        guard let tabID = location(of: paneID)?.tab else { return .notFound }
        var empty = false
        _ = editRoot(ofTab: tabID) { root in
            guard Self.remove(&root, id: paneID) else { return false }
            Self.collapse(&root)
            empty = LayoutNode(json: root).blocks.isEmpty
            return true
        }
        return empty ? removeTab(tabID) : .pane
    }

    private static func remove(_ node: inout JSON, id: String) -> Bool {
        guard var children = node["children"]?.array else { return false }
        if let i = children.firstIndex(where: { $0["id"]?.string == id }) {
            let removed = children.remove(at: i)
            let type = node["type"]?.string
            if type == "row" || type == "column" {
                func weight(_ s: JSON?) -> Double? {
                    switch NodeSize(json: s) {
                    case .weight(let w): w
                    case .none: 1.0
                    case .px: nil
                    }
                }
                let n = i > 0 ? i - 1 : 0
                if let gone = weight(removed["size"]), children.indices.contains(n), let w = weight(children[n]["size"]) {
                    children[n]["size"] = NodeSize.weight(w + gone).json
                }
            }
            if type == "stack", node["active"]?.string == id {
                node["active"] = (children.indices.contains(i) ? children[i] : children.last)?["id"] ?? .null
            }
            node["children"] = .array(children)
            return true
        }
        for i in children.indices where remove(&children[i], id: id) {
            node["children"] = .array(children)
            return true
        }
        return false
    }

    private static func collapse(_ node: inout JSON) {
        guard var children = node["children"]?.array else { return }
        for i in children.indices { collapse(&children[i]) }
        if node["type"]?.string != "stack" {
            let isLine = { (n: JSON) -> Bool in n["type"]?.string == "row" || n["type"]?.string == "column" }
            children.removeAll { isLine($0) && ($0["children"]?.array ?? []).isEmpty }
            for i in children.indices where isLine(children[i]) && (children[i]["children"]?.array ?? []).count == 1 {
                let size = children[i]["size"]
                var only = children[i]["children"]![0]!
                only["size"] = (size?.isNull ?? true) ? nil : size
                children[i] = only
            }
        }
        node["children"] = .array(children)
    }

    /// Sets the weights of a container's children (a divider drag).
    @discardableResult
    public mutating func setWeights(_ weights: [String: Double], inContainer containerID: String) -> Bool {
        guard let tabID = location(of: containerID)?.tab else { return false }
        return editRoot(ofTab: tabID) { root in Self.setWeights(&root, container: containerID, weights: weights) }
    }

    private static func setWeights(_ node: inout JSON, container: String, weights: [String: Double]) -> Bool {
        guard var children = node["children"]?.array else { return false }
        if node["id"]?.string == container {
            for i in children.indices {
                if let id = children[i]["id"]?.string, let w = weights[id] {
                    children[i]["size"] = NodeSize.weight(w).json
                }
            }
            node["children"] = .array(children)
            return true
        }
        for i in children.indices where setWeights(&children[i], container: container, weights: weights) {
            node["children"] = .array(children)
            return true
        }
        return false
    }

    /// Changes which terminal a pane shows.
    @discardableResult
    public mutating func setTerminal(_ terminal: String, ofPane paneID: String) -> Bool {
        guard let tabID = location(of: paneID)?.tab else { return false }
        return editRoot(ofTab: tabID) { root in Self.edit(&root, id: paneID) { $0["content"] = ["terminal": .string(terminal)] } }
    }

    private static func edit(_ node: inout JSON, id: String, _ change: (inout JSON) -> Void) -> Bool {
        if node["id"]?.string == id {
            change(&node)
            return true
        }
        guard var children = node["children"]?.array else { return false }
        for i in children.indices where edit(&children[i], id: id, change) {
            node["children"] = .array(children)
            return true
        }
        return false
    }
}
