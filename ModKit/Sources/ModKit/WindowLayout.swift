import Foundation

/// A window layout as herdr-app writes them (`layouts/<name>.json`): a tree
/// of rows, columns and stacks whose leaves are blocks, each holding a mod,
/// the shown tab, a terminal or an agent.
///
/// The tree is live: showing, hiding, resizing a part or choosing a stack's
/// child changes it here, and mods read it as it is now (`layout()`).
public final class WindowLayout {
    public enum Kind: String, Sendable {
        case block, row, column, stack
    }

    public enum Content: Equatable {
        /// A mod, by name.
        case mod(String)
        /// The shown tab's panes.
        case tab
        case terminal(String)
        case agent(String)
        case empty
    }

    public final class Item: Identifiable {
        public let id: String
        public let kind: Kind
        public fileprivate(set) var children: [Item]
        public fileprivate(set) weak var parent: Item?
        /// Every field of the file but the children: what the app doesn't
        /// read still goes back to mods, and to the file.
        fileprivate var fields: [String: Any]

        fileprivate init(id: String, kind: Kind, fields: [String: Any], children: [Item]) {
            self.id = id
            self.kind = kind
            self.fields = fields
            self.children = children
        }

        public var content: Content {
            guard let c = fields["content"] as? [String: Any] else { return .empty }
            if let name = c["mod"] as? String { return .mod(name) }
            if c["tab"] != nil { return .tab }
            if let terminal = c["terminal"] as? String { return .terminal(terminal) }
            if let agent = c["agent"] as? String { return .agent(agent) }
            return .empty
        }

        public var props: [String: Any] { (fields["content"] as? [String: Any])?["props"] as? [String: Any] ?? [:] }
        public var hidden: Bool { fields["hidden"] as? Bool ?? false }
        /// A stack's shown child.
        public var active: String? { fields["active"] as? String }
        public var px: Double? { ((fields["size"] as? [String: Any])?["px"] as? NSNumber)?.doubleValue }
        public var weight: Double { ((fields["size"] as? [String: Any])?["weight"] as? NSNumber)?.doubleValue ?? 1 }
        public var min: Double? { (fields["min"] as? NSNumber)?.doubleValue }
        public var max: Double? { (fields["max"] as? NSNumber)?.doubleValue }
        public var resizable: Bool { fields["resizable"] as? Bool ?? true }
        public var gap: Double { (fields["gap"] as? NSNumber)?.doubleValue ?? 0 }
        public var padding: Double { (fields["padding"] as? NSNumber)?.doubleValue ?? 0 }
        /// A theme color's name, or a color.
        public var background: String? { fields["background"] as? String }
        public func field(_ name: String) -> Any? { fields[name] }

        /// The child a stack shows.
        public var shownChild: Item? {
            guard kind == .stack else { return nil }
            return children.first { $0.id == active } ?? children.first
        }

        fileprivate var json: [String: Any] {
            var out = fields
            out["id"] = id
            out["type"] = kind.rawValue
            if !children.isEmpty || kind != .block { out["children"] = children.map(\.json) }
            return out
        }

        public func walk(_ visit: (Item) -> Void) {
            visit(self)
            for child in children { child.walk(visit) }
        }
    }

    public let name: String
    public let root: Item
    private var byID: [String: Item] = [:]
    /// Called after each change, for the app to draw and to tell the mods.
    public var onChange: (() -> Void)?

    /// Nil when the JSON isn't a layout.
    public init?(name: String, json: [String: Any]) {
        var counter = 0
        func make(_ raw: [String: Any]) -> Item? {
            guard let kind = (raw["type"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
            counter += 1
            var fields = raw
            fields["children"] = nil
            fields["type"] = nil
            fields["id"] = nil
            let children = (raw["children"] as? [[String: Any]] ?? []).compactMap(make)
            let item = Item(id: raw["id"] as? String ?? "\(kind.rawValue)-\(counter)", kind: kind, fields: fields, children: children)
            for child in children { child.parent = item }
            return item
        }
        guard let root = make(json) else { return nil }
        self.name = name
        self.root = root
        root.walk { byID[$0.id] = $0 }
    }

    public convenience init?(file: URL) {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.init(name: file.deletingPathExtension().lastPathComponent, json: json)
    }

    /// Swiftr's own layout, for mods no layout file places: the shown tab,
    /// and a panel on its right that stacks them. Its ids are the ones
    /// herdr-app's main layout gives its side panel, so a mod's
    /// `layout.toggle {id: "panel"}` works here too. Nil without mods.
    public static func own(mods: [String], width: Double = 340) -> WindowLayout? {
        guard !mods.isEmpty else { return nil }
        let blocks: [[String: Any]] = mods.map { ["id": $0, "type": "block", "content": ["mod": $0]] }
        return WindowLayout(name: "", json: [
            "id": "root", "type": "row",
            "children": [
                ["id": "main", "type": "block", "content": ["tab": "active"]],
                [
                    "id": panelID, "type": "column", "size": ["px": width], "min": 220, "max": 900,
                    "children": [["id": panelStackID, "type": "stack", "children": blocks]],
                ],
            ],
        ])
    }

    public static let panelID = "panel"
    public static let panelStackID = "panel-body"

    /// Swiftr's own, built from the person's mods rather than read from a file.
    public var isOwn: Bool { name.isEmpty }

    /// A stack that would open on a mod the person doesn't have (herdr-app's
    /// Files, a mod not added) opens on the first one they have.
    public func settle(has: (String) -> Bool) {
        func drawn(_ item: Item) -> Bool {
            if case .mod(let name) = item.content { return has(name) }
            return Self.shows(item)
        }
        root.walk { item in
            guard item.kind == .stack, let shown = item.shownChild, !drawn(shown),
                  let other = item.children.first(where: drawn) else { return }
            item.fields["active"] = other.id
        }
    }

    /// True when a mod the layout puts outside its stacks (a bar, a band)
    /// isn't among the person's: it may be the one that switches the
    /// stacks, so Swiftr then draws a switch of its own.
    public func lacksLooseMod(has: (String) -> Bool) -> Bool {
        var lacks = false
        func visit(_ item: Item, stacked: Bool) {
            if case .mod(let name) = item.content, !stacked, !Self.shipped.contains(name), !has(name) { lacks = true }
            for child in item.children { visit(child, stacked: stacked || item.kind == .stack) }
        }
        visit(root, stacked: false)
        return lacks
    }

    /// The tree as mods read it, and as it is saved.
    public var json: [String: Any] { root.json }

    public func find(_ id: String) -> Item? { byID[id] }

    // MARK: What `layout.*` commands do

    public func setHidden(_ hidden: Bool, id: String) {
        guard let item = byID[id], item.hidden != hidden else { return }
        item.fields["hidden"] = hidden
        onChange?()
    }

    public func toggle(id: String) {
        guard let item = byID[id] else { return }
        setHidden(!item.hidden, id: id)
    }

    public func select(stack: String, child: String) {
        guard let item = byID[stack], item.kind == .stack, item.children.contains(where: { $0.id == child }), item.active != child else { return }
        item.fields["active"] = child
        onChange?()
    }

    public func resize(id: String, px: Double?, weight: Double? = nil) {
        guard let item = byID[id] else { return }
        if var px {
            if let min = item.min { px = Swift.max(px, min) }
            if let max = item.max { px = Swift.min(px, max) }
            guard item.px != px else { return }
            item.fields["size"] = ["px": px]
        } else if let weight {
            item.fields["size"] = ["weight": weight]
        } else { return }
        onChange?()
    }

    /// Runs a `layout.*` command a mod or a key asked for. False when the
    /// name isn't one this knows.
    @discardableResult
    public func run(_ command: String, _ arguments: [String: Any]) -> Bool {
        let id = arguments["id"] as? String ?? ""
        switch command {
        case "layout.show": setHidden(false, id: id)
        case "layout.hide": setHidden(true, id: id)
        case "layout.toggle": toggle(id: id)
        case "layout.select":
            if let stack = arguments["stack"] as? String, let child = arguments["child"] as? String { select(stack: stack, child: child) }
        case "layout.resize":
            resize(id: id, px: (arguments["px"] as? NSNumber)?.doubleValue, weight: (arguments["weight"] as? NSNumber)?.doubleValue)
        default: return false
        }
        return true
    }

    // MARK: What the person changed, kept apart from the shared file

    /// Hidden parts, stacks' choices and sizes, by id.
    public var state: [String: Any] {
        var out: [String: Any] = [:]
        root.walk { item in
            var own: [String: Any] = [:]
            if item.fields["hidden"] != nil { own["hidden"] = item.hidden }
            if let active = item.active { own["active"] = active }
            if let px = item.px { own["px"] = px }
            if !own.isEmpty { out[item.id] = own }
        }
        return out
    }

    public func restore(_ state: [String: Any]) {
        for (id, value) in state {
            guard let item = byID[id], let own = value as? [String: Any] else { continue }
            if let hidden = own["hidden"] as? Bool { item.fields["hidden"] = hidden }
            if let active = own["active"] as? String, item.children.contains(where: { $0.id == active }) { item.fields["active"] = active }
            if let px = (own["px"] as? NSNumber)?.doubleValue, item.px != nil { item.fields["size"] = ["px": px] }
        }
    }

    // MARK: What Swiftr shows of it

    /// herdr-app's own mods: Swiftr has its own sidebar, tabs and status for
    /// those, and never runs herdr-app's scripts for them. (`changes` is
    /// not here: Swiftr draws a panel of its own under that name.)
    public nonisolated static let shipped: Set<String> = [
        "spaces", "agents", "tabs", "workspace-chrome", "workspace-status", "pane", "files",
        "menu", "new-menu", "settings", "palette", "toast", "preview", "terminal-menu", "updates", "feedback",
    ]

    /// Shipped panels Swiftr has nothing for yet: a block that holds one
    /// says so, where a stack would show it.
    public static let missing: Set<String> = ["files"]

    /// Whether anything under the item is Swiftr's to draw: the shown tab,
    /// or a mod that isn't herdr-app's own.
    public static func shows(_ item: Item) -> Bool {
        switch item.kind {
        case .block:
            switch item.content {
            case .tab: return true
            case .mod(let name): return !shipped.contains(name)
            default: return false
            }
        default:
            return item.children.contains(where: shows)
        }
    }

    /// The mods the layout names that aren't herdr-app's own.
    public var mods: [String] {
        var out: [String] = []
        root.walk { item in
            if case .mod(let name) = item.content, !Self.shipped.contains(name), !out.contains(name) { out.append(name) }
        }
        return out
    }
}

/// What a mod's files say it does, read without running it: for the list
/// shown before a mod is allowed.
public nonisolated enum ModScan {
    public struct Report: Sendable {
        public var needs: ModCapabilities
        /// The programs it names (`exec("git", …)`), where they are plain text.
        public var programs: [String]
        /// Sites it names in `fetch("https://…")`, and hosts in
        /// `WebSocket.connect("ws://…")` and `connect("host", port)`.
        public var sites: [String]
        public var files: Int
        public var lines: Int
    }

    private static func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }

    public static func report(folder: URL) -> Report {
        var needs: ModCapabilities = []
        var programs = Set<String>(), sites = Set<String>()
        var files = 0, lines = 0
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard ["js", "mjs"].contains(url.pathExtension), !url.path.contains("/node_modules/"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files += 1
            lines += text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
            // What it takes from "herdr", and what it calls.
            let imported = matches(#"import\s*\{([^}]*)\}\s*from\s*["']herdr["']"#, in: text).joined(separator: ",")
            let whole = text.contains(#"* as "#) && text.range(of: #"from\s*["']herdr["']"#, options: .regularExpression) != nil
            func uses(_ name: String) -> Bool {
                whole && text.contains("." + name + "(") || imported.range(of: "\\b\(name)\\b", options: .regularExpression) != nil
            }
            if uses("exec") || uses("hc") || text.contains("process.run(") {
                needs.insert(.programs)
                for name in matches(#"\bexec\(\s*["'`]([^"'`$]+)["'`]"#, in: text) { programs.insert(name) }
                if uses("hc") { programs.insert("hc") }
            }
            if uses("readTextFile") || uses("watchFolder") || text.range(of: #"\b(readFile|readdir|stat)\("#, options: .regularExpression) != nil { needs.insert(.readFiles) }
            // Files it hands to a drag can end up anywhere: outside its own
            // folder that takes the leave to read.
            if text.contains(".drag_paths(") { needs.insert(.readFiles) }
            if uses("writeTextFile") || text.range(of: #"\b(writeFile|mkdir|rename|unlink|rm)\("#, options: .regularExpression) != nil { needs.insert(.writeFiles) }
            // `net` and `websocket` open sockets: the network too, and not
            // only web pages.
            let sockets = text.range(of: #"(?:from\s*|import\(\s*)["'](?:node:)?(?:net|websocket)["']"#, options: .regularExpression) != nil
            if sockets || text.range(of: #"\bfetch\("#, options: .regularExpression) != nil {
                needs.insert(.network)
                for site in matches(#"(?:https?|wss?)://([A-Za-z0-9.-]+)"#, in: text) { sites.insert(site) }
                if sockets { for host in matches(#"\bconnect\(\s*["'`]([A-Za-z0-9.-]+)["'`]\s*,"#, in: text) { sites.insert(host) } }
            }
            if uses("run") || uses("setAgentOrder") { needs.insert(.commands) }
        }
        return Report(needs: needs, programs: programs.sorted(), sites: sites.sorted(), files: files, lines: lines)
    }
}

/// `mod.json`: where a mod goes and how it opens.
public nonisolated struct ModManifest: Sendable {
    public var title: String
    public var place: String?
    public var overlayKind: String?
    public var overlayWidth: Double?
    public var overlayHeight: Double?
    public var focusable: Bool

    public init(folder: URL) {
        let json = (try? Data(contentsOf: folder.appending(path: "mod.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let name = folder.lastPathComponent
        title = json["title"] as? String ?? name.prefix(1).uppercased() + name.dropFirst()
        place = json["place"] as? String
        let overlay = json["overlay"] as? [String: Any]
        overlayKind = overlay?["kind"] as? String
        overlayWidth = (overlay?["width"] as? NSNumber)?.doubleValue
        overlayHeight = (overlay?["height"] as? NSNumber)?.doubleValue
        focusable = json["focusable"] as? Bool ?? false
    }
}
