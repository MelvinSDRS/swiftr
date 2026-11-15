import Foundation

/// What this window shows: private to Swiftr, unlike the shared layout.
/// Keys are qualified ids (`Place.key`).
struct ViewState: Codable, Equatable {
    var activeSpace: String?
    /// Space key → the tab shown in it (that machine's tab id).
    var activeTab: [String: String] = [:]
    /// Tab key → the focused pane (that machine's pane id).
    var focusedPane: [String: String] = [:]
    /// Tab key → the pane focused before it, for going back after a close.
    var previousPane: [String: String] = [:]
    /// Tab key → the pane filling the tab.
    var zoomedPane: [String: String] = [:]
    var sidebarVisible = true
    /// Terminal address → how its Claude pane shows, when not the default.
    var paneModes: [String: PaneMode]?
    /// The sidebar's machines, as moved in Swiftr ("" is this Mac). herdr-app
    /// keeps its own order: this Mac, then machines by name.
    var machineOrder: [String]?
    /// Names and icons given to machines in Swiftr, by the other core's id
    /// ("" is this Mac), so they stay when herdr-app renames a machine.
    /// herdr-app and hc keep the core's names.
    var machineLooks: [String: MachineLook]?
    /// Machines whose spaces the sidebar hides, by the same key as their
    /// look, so they stay collapsed when herdr-app renames them.
    var collapsedMachines: Set<String>?
    /// The sidebar hides the agents' rows.
    var agentsCollapsed: Bool?
    /// The sidebar hides the spaces' list, every machine in it.
    var spacesCollapsed: Bool?
    /// Groups of agents whose rows the sidebar hides, by `AgentGroup.key`.
    var foldedAgentGroups: Set<String>?
    /// The agents' share of the sidebar's height, as dragged: herdr-app keeps
    /// its lists' weights too. nil for half.
    var agentsShare: Double?
    /// Space key → the icon given to it in Swiftr, instead of the automatic one.
    var spaceIcons: [String: SpaceIcon]?
    /// Spaces whose tabs the sidebar lists under them, by space key.
    var expandedSpaces: Set<String>?

    static func url(session: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = session == "default" ? "view.json" : "view-\(session).json"
        return base.appending(path: "Swiftr").appending(path: name)
    }

    static func load(session: String) -> ViewState {
        guard let data = try? Data(contentsOf: url(session: session)),
              let state = try? JSONDecoder().decode(ViewState.self, from: data)
        else { return ViewState() }
        return state
    }

    func save(session: String) {
        let url = Self.url(session: session)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Forgets what points at spaces, tabs and panes that no longer exist.
    mutating func prune(spaces: Set<String>, tabs: Set<String>) {
        if let a = activeSpace, !spaces.contains(a) { activeSpace = nil }
        activeTab = activeTab.filter { spaces.contains($0.key) }
        focusedPane = focusedPane.filter { tabs.contains($0.key) }
        previousPane = previousPane.filter { tabs.contains($0.key) }
        zoomedPane = zoomedPane.filter { tabs.contains($0.key) }
        if let icons = spaceIcons?.filter({ spaces.contains($0.key) }) { spaceIcons = icons.isEmpty ? nil : icons }
        if let open = expandedSpaces?.filter({ spaces.contains($0) }) { expandedSpaces = open.isEmpty ? nil : open }
    }
}

/// A machine's own name and icon in Swiftr; nil keeps the default.
struct MachineLook: Codable, Equatable {
    var name: String?
    /// An SF Symbol.
    var icon: String?

    var isEmpty: Bool { name == nil && icon == nil }
}

/// A space's icon in Swiftr: an SF Symbol, an image from disk, or the logo
/// in one of its folders.
struct SpaceIcon: Codable, Equatable {
    var symbol: String?
    /// A file in `SpaceIcons.folder`, a copy of the image chosen.
    var image: String?
    /// A folder on the space's machine, whose logo it shows.
    var folder: String?
}

/// What was written to each Claude and not sent yet, by terminal address:
/// kept when its pane leaves the screen, and when Swiftr quits. Not in
/// `ViewState`: it changes at each key, and every view reads that one.
enum Drafts {
    static func url(session: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = session == "default" ? "drafts.json" : "drafts-\(session).json"
        return base.appending(path: "Swiftr").appending(path: name)
    }

    static func load(session: String) -> [String: String] {
        guard let data = try? Data(contentsOf: url(session: session)),
              let drafts = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return drafts
    }

    static func save(_ drafts: [String: String], session: String) {
        let url = url(session: session)
        guard !drafts.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(drafts) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
