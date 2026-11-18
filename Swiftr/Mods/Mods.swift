import AppKit
import QuartzCore
import HerdrKit
import ModKit
import Observation

/// Mods and layouts in Swiftr: small JavaScript programs, written for
/// herdr-app or for Swiftr, whose panels Swiftr draws itself (ModKit).
///
/// They live in `~/.config/swiftr`, laid out as herdr-app's own folder:
/// `mods/<name>/`, `layouts/<name>.json`. A mod runs only once the person
/// allowed what its files say it does.
@Observable
final class Mods: ModHost {
    static let shared = Mods()

    struct Entry: Identifiable {
        let name: String
        let manifest: ModManifest
        let report: ModScan.Report
        /// The person agreed to everything it needs.
        var allowed: Bool
        /// The link it was added from, for a mod that came from one.
        var origin: String?
        var id: String { name }
    }

    struct Overlay: Identifiable {
        let id: String
        let mod: String
        var props: [String: Any]
        /// `dialog` in the window's middle, `popup` at the pointer.
        let kind: String
        let width: CGFloat
        let height: CGFloat?
        /// Where the pointer was, in the window, from its top left.
        let at: CGPoint?
    }

    /// What a mod tells the person (`notify`), shown a few seconds.
    struct Toast: Identifiable {
        let id: String
        let title: String
        let body: String
        let level: String
    }

    @ObservationIgnored weak var model: AppModel? {
        didSet { if model != nil, oldValue == nil { start() } }
    }
    @ObservationIgnored let center: ModCenter
    @ObservationIgnored let home: URL

    private(set) var entries: [Entry] = []
    private(set) var layout: WindowLayout?
    /// Changes when the layout's tree does, or a mod's files: views read it
    /// to draw again.
    private(set) var revision = 0
    /// Changes when a mod's files do, or what it may do: its views start over.
    private(set) var reloadCounts: [String: Int] = [:]

    /// Changes when that mod's files do, or what it may do: its own views
    /// start over, and no other mod's.
    func reloads(of name: String) -> Int { reloadCounts[name] ?? 0 }
    private(set) var overlays: [Overlay] = []
    private(set) var toasts: [Toast] = []
    private(set) var layoutNames: [String] = []
    /// The latest thing a mod asked for that Swiftr doesn't do yet.
    private(set) var lastUnknownCommand: String?

    /// Settings › Mods › Add from Link.
    @ObservationIgnored let linkAdd = LinkAdd()
    @ObservationIgnored private var grants: [String: Int] = [:]
    /// For a mod added from a link, the mark of the copy the person
    /// allowed (`ModFetch.token`): another copy under the same name, with
    /// another mark, asks again whatever it needs.
    @ObservationIgnored private var marks: [String: String] = [:]
    @ObservationIgnored private var keys: [(chord: Set<String>, command: String, arguments: [String: Any])] = []
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var nextOverlay = 1
    @ObservationIgnored private var saveState: DispatchWorkItem?
    @ObservationIgnored var widthNote: DispatchWorkItem?

    /// What the person chose: the layout, and what each mod may do. Kept
    /// out of the mods' own folder.
    @ObservationIgnored private let choicesFile: URL
    @ObservationIgnored private var chosenLayout: String?
    /// Mods the person keeps out of the mods' sidebar.
    @ObservationIgnored private var panelOff: Set<String> = []
    @ObservationIgnored private var started = false
    /// Tests: the home mods and their programs see, instead of the person's.
    @ObservationIgnored private let standInHome: String?

    private init() {
        let environment = ProcessInfo.processInfo.environment
        standInHome = environment["SWIFTR_MODS_USER_HOME"]
        if let folder = environment["SWIFTR_MODS_HOME"] {
            // A test's folder, with its own choices beside it.
            home = URL(fileURLWithPath: folder)
            choicesFile = home.deletingLastPathComponent().appending(path: "swiftr-mods-choices.json")
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/swiftr")
            choicesFile = URL.applicationSupportDirectory.appending(path: "Swiftr/mods.json")
        }
        center = ModCenter(home: home, userHome: standInHome)
        center.host = self
        if let data = try? Data(contentsOf: choicesFile), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            grants = json["allowed"] as? [String: Int] ?? [:]
            marks = json["marks"] as? [String: String] ?? [:]
            chosenLayout = json["layout"] as? String
            panelOff = Set(json["panelOff"] as? [String] ?? [])
            sidebarStyle = (json["sidebarStyle"] as? String).flatMap(ModSidebarStyle.init) ?? .floating
            changesShare = json["changesShare"] as? Double
        }
    }

    private func saveChoices() {
        var json: [String: Any] = ["allowed": grants]
        if !marks.isEmpty { json["marks"] = marks }
        if let name = chosenLayout { json["layout"] = name }
        if !panelOff.isEmpty { json["panelOff"] = panelOff.sorted() }
        json["sidebarStyle"] = sidebarStyle.rawValue
        if let changesShare { json["changesShare"] = changesShare }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: choicesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: choicesFile, options: .atomic)
    }

    // MARK: Start

    private func start() {
        for folder in ["mods", "layouts", "themes"] {
            try? FileManager.default.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }
        if let model {
            var environment = ProcessInfo.processInfo.environment.merging(model.endpoint.environment) { _, new in new }
            // `hc` first: mods call it by name.
            let folder = (model.endpoint.hcPath as NSString).deletingLastPathComponent
            environment["PATH"] = folder + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            // Tests: stand-ins for the programs mods call.
            if let first = environment["SWIFTR_MODS_PATH"] { environment["PATH"] = first + ":" + (environment["PATH"] ?? "") }
            if let standInHome { environment["HOME"] = standInHome }
            ModProcess.environment = environment
        }
        center.onReload = { [weak self] name in
            self?.rescan()
            self?.reloadCounts[name, default: 0] += 1
        }
        center.watchMods()
        rescan()
        started = true
        writeGuide()
        loadLayout(named: chosenLayout)
        loadKeys()
        track()
        // Titles and statuses change without the lists changing.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        #if DEBUG
        ModDebug.install(self)
        #endif
    }

    /// Reads the mods folder again.
    func rescan() {
        entries = center.installed().map { name in
            let folder = center.modsFolder.appending(path: name)
            let report = ModScan.report(folder: folder)
            let granted = ModCapabilities(rawValue: grants[name] ?? 0)
            // A copy that came from a link is allowed by its own mark: the
            // OK given to another mod of this name is not one for it.
            let mark = ModFetch.token(of: folder)
            let allowed = grants[name] != nil && granted.isSuperset(of: report.needs) && (mark == nil || marks[name] == mark)
            center.setGrant(allowed ? report.needs : [], for: name)
            return Entry(name: name, manifest: ModManifest(folder: folder), report: report, allowed: allowed, origin: ModFetch.origin(of: folder))
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: home.appending(path: "layouts").path)) ?? []
        layoutNames = files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        previews = [:]
        guard started else { return }
        if layout?.isOwn ?? true {
            // Swiftr's own layout holds the mods there are now.
            if layout?.mods ?? [] != panelMods { useOwnLayout() }
        } else if let layout, modNames != settledFor {
            // Only when a mod came or went: a save or an OK leaves what the
            // person picked.
            settle(layout)
            revision += 1
            publishLayout()
        }
    }

    /// The mods there were when the layout's stacks were last settled.
    @ObservationIgnored private var settledFor: Set<String> = []

    private func settle(_ layout: WindowLayout) {
        let names = modNames
        settledFor = names
        layout.settle { names.contains($0) }
    }

    func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    /// The person read what the mod does and agreed.
    func allow(_ name: String) {
        guard let entry = entry(name) else { return }
        grants[name] = entry.report.needs.rawValue
        marks[name] = ModFetch.token(of: center.modsFolder.appending(path: name))
        saveChoices()
        rescan()
        center.reload(name)
    }

    func disallow(_ name: String) {
        grants[name] = nil
        marks[name] = nil
        saveChoices()
        overlays.removeAll { $0.mod == name }
        rescan()
        center.reload(name)
    }

    /// Moves the mod to the Trash.
    func remove(_ name: String) {
        disallow(name)
        panelOff.remove(name)
        try? FileManager.default.trashItem(at: center.modsFolder.appending(path: name), resultingItemURL: nil)
        rescan()
        reloadCounts[name, default: 0] += 1
    }

    // MARK: Layouts

    /// The layout file in use; nil with Swiftr's own.
    var layoutName: String? { layout.flatMap { $0.isOwn ? nil : $0.name } }

    func loadLayout(named name: String?) {
        saveLayoutState()
        var loaded: WindowLayout?
        if let name, !name.isEmpty {
            loaded = WindowLayout(file: home.appending(path: "layouts/\(name).json"))
        }
        guard let loaded else {
            let changed = chosenLayout != nil
            chosenLayout = nil
            if changed { saveChoices() }
            useOwnLayout()
            return
        }
        restore(loaded)
        settle(loaded)
        let changed = loaded.name != chosenLayout
        chosenLayout = loaded.name
        show(loaded)
        if changed { saveChoices() }
    }

    private func show(_ loaded: WindowLayout?) {
        layout = loaded
        // The mods' colors follow where the layout draws them.
        publish()
        loaded?.onChange = { [weak self] in self?.layoutChanged() }
        revision += 1
        publishLayout()
    }

    /// False when the layout was never used: nothing was kept for it.
    @discardableResult private func restore(_ loaded: WindowLayout) -> Bool {
        guard let data = try? Data(contentsOf: stateFile(loaded.name)),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        loaded.restore(state)
        return true
    }

    private func stateFile(_ name: String) -> URL {
        home.appending(path: name.isEmpty ? "data/own-layout.json" : "data/layout-\(name).json")
    }

    // MARK: Swiftr's own layout

    /// The mods Swiftr's own layout stacks in the mods' sidebar: every mod the
    /// person has and didn't take out of it.
    var panelMods: [String] { (Self.builtIn + entries.map(\.name)).filter { !panelOff.contains($0) } }

    func isInPanel(_ name: String) -> Bool { !panelOff.contains(name) }

    func setInPanel(_ name: String, _ on: Bool) {
        if on { panelOff.remove(name) } else { panelOff.insert(name) }
        saveChoices()
        if layout?.isOwn ?? true { useOwnLayout() }
    }

    /// Without a layout file: the tab, and the person's mods in a panel on
    /// its right. What they chose there (its width, the mod shown) stays.
    private func useOwnLayout() {
        let old = layout?.isOwn == true ? layout?.state : nil
        if old != nil { saveLayoutState() }
        let own = WindowLayout.own(mods: panelMods)
        if let own {
            if let old {
                own.restore(old)
            } else if !restore(own), entries.isEmpty {
                // Never used, and no mod asks for it: the sidebar waits
                // behind its button, and the terminals keep their width.
                own.setHidden(true, id: WindowLayout.panelID)
            }
        }
        show(own)
    }

    /// The side panel of the layout in use: Swiftr's own, or a layout
    /// file's part named as herdr-app names its own.
    var panel: WindowLayout.Item? { layout?.find(WindowLayout.panelID) }

    var panelShown: Bool {
        // The tree changes in place: `revision` tells who reads this.
        _ = revision
        return panel.map { !$0.hidden } ?? false
    }

    func togglePanel() { layout?.toggle(id: WindowLayout.panelID) }

    /// The panels Swiftr draws itself, under the names herdr-app gives its
    /// own: a layout that names one gets Swiftr's.
    static let builtIn = ["changes"]

    /// Whether the person has this mod, or Swiftr has it built in.
    func has(_ name: String) -> Bool { Self.builtIn.contains(name) || entry(name) != nil }

    /// Every name a layout may show: the built-in panels and the person's mods.
    private var modNames: Set<String> { Set(Self.builtIn + entries.map(\.name)) }

    /// A mod's name as shown.
    func title(of name: String) -> String {
        if name == "changes" { return "Changes" }
        return entry(name)?.manifest.title ?? name
    }

    /// The sidebar's width at launch: the one it was left at.
    var sidebarWidth: CGFloat {
        let px = layout.flatMap { $0.isOwn ? $0.find(WindowLayout.panelID)?.px : nil } ?? 320
        return min(max(CGFloat(px), ModSidebar.minWidth), ModSidebar.maxWidth)
    }

    /// The sidebar's edge was dragged: its width is kept with the layout.
    func noteSidebar(width: CGFloat) {
        // Only while the column shows. Once it has shown, the window keeps
        // it at its last width and tells that width again whenever the
        // floating panel is sized: the panel went back to it.
        guard sidebarShown else { return }
        columnWidth = width
        widthNote?.cancel()
        // Not while the style changes: the column comes in at its last
        // width, and is put at the panel's once it rests (`pick(style:)`).
        guard !crossing else { return }
        // Once the drag rests: each step would tell every mod.
        let note = DispatchWorkItem { [weak self] in
            guard let self, let layout, layout.isOwn, sidebarShown, width >= ModSidebar.minWidth, width <= ModSidebar.maxWidth,
                  abs(width - sidebarWidth) >= 1 else { return }
            layout.resize(id: WindowLayout.panelID, px: Double(width.rounded()))
        }
        widthNote = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: note)
    }

    /// The floating sidebar's edge was let go: its width, kept at once.
    func setSidebar(width: CGFloat) {
        widthNote?.cancel()
        guard let layout, layout.isOwn else { return }
        layout.resize(id: WindowLayout.panelID, px: Double(min(max(width, ModSidebar.minWidth), ModSidebar.maxWidth).rounded()))
    }

    /// Swiftr's own layout shows its mods in a sidebar on the window's
    /// right: whether that sidebar shows as a column of the window, its
    /// mods on a card.
    var sidebarShown: Bool { layout?.isOwn == true && panelShown && sidebarStyle == .card }

    /// The same sidebar as a panel on the terminals' card.
    var floatingShown: Bool { layout?.isOwn == true && panelShown && sidebarStyle == .floating }

    /// The width the column is put at once it has slid in after a change
    /// of style (`pick(style:)`): the window opens it at its last width,
    /// not the one the panel had since (`ModColumnWidth`).
    var sidebarPin: CGFloat?

    /// While the style changes with the sidebar in sight: the window
    /// slides the column in or out, and the floating panel stays where it
    /// is in the window, fading as the column covers it
    /// (`FloatingModSidebar`).
    var crossing = false
    /// What tells how far the column has come: the terminals' card's
    /// width and the column's own, at rest, then as the change of style
    /// began: the card's with no column beside it, and the column's.
    @ObservationIgnored var cardWidth: CGFloat = 0
    @ObservationIgnored var columnWidth: CGFloat = 0
    @ObservationIgnored var cardFull: CGFloat = 0
    @ObservationIgnored var crossColumn: CGFloat = 0
    /// The style asked for while one change was under way: taken up once
    /// that one is done.
    @ObservationIgnored var crossNext: ModSidebarStyle?

    /// How the sidebar shows: kept with the person's other choices.
    var sidebarStyle = ModSidebarStyle.floating {
        didSet {
            guard sidebarStyle != oldValue else { return }
            saveChoices()
            publish()
        }
    }

    /// The Changes panel's list of files, as a share of the panel's height:
    /// nil until the line under it is dragged.
    var changesShare: Double? {
        didSet { if changesShare != oldValue { saveChoices() } }
    }

    /// The window's column says it opened or closed. Not while the sidebar
    /// floats: the column closes then, and the sidebar still shows.
    func setSidebar(shown: Bool) {
        guard let layout, layout.isOwn, sidebarStyle != .floating else { return }
        layout.setHidden(!shown, id: WindowLayout.panelID)
    }

    /// Shows a mod in the mods' sidebar, the sidebar too.
    func showInPanel(_ name: String) {
        guard let layout, let stack = layout.find(WindowLayout.panelStackID),
              let child = stack.children.first(where: { $0.content == .mod(name) }) else { return }
        layout.select(stack: stack.id, child: child.id)
        layout.setHidden(false, id: WindowLayout.panelID)
    }

    /// Where a mod shows, in a few words, for Settings.
    func place(of name: String) -> String {
        guard let layout, !layout.isOwn else { return isInPanel(name) ? "Mods sidebar" : "Not shown" }
        return layout.mods.contains(name) ? "In \(layout.name)" : "Not in \(layout.name)"
    }

    /// A layout file as it is shared, for its picture in Settings.
    func preview(layout name: String) -> WindowLayout? {
        if let hit = previews[name] { return hit }
        let loaded = WindowLayout(file: home.appending(path: "layouts/\(name).json"))
        loaded?.settle { [entries] name in entries.contains { $0.name == name } }
        previews[name] = loaded
        return loaded
    }

    @ObservationIgnored private var previews: [String: WindowLayout] = [:]

    /// Moves a layout's file to the Trash.
    func remove(layout name: String) {
        if layoutName == name { loadLayout(named: nil) }
        try? FileManager.default.trashItem(at: home.appending(path: "layouts/\(name).json"), resultingItemURL: nil)
        try? FileManager.default.removeItem(at: stateFile(name))
        rescan()
    }

    private func layoutChanged() {
        revision += 1
        publishLayout()
        // What was hidden, chosen or resized comes back at the next launch;
        // the layout's own file stays as it was shared.
        saveState?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveLayoutState() }
        saveState = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveLayoutState() {
        guard let layout, let data = try? JSONSerialization.data(withJSONObject: layout.state, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: home.appending(path: "data"), withIntermediateDirectories: true)
        try? data.write(to: stateFile(layout.name), options: .atomic)
    }

    private func publishLayout() {
        center.setData("layout", layout?.json ?? NSNull())
        center.setData("layouts", layoutNames)
    }

    // MARK: What mods read

    /// How many times the lists were built for mods, and the time that took.
    @ObservationIgnored private(set) var publishes = 0
    @ObservationIgnored private(set) var publishSeconds = 0.0
    @ObservationIgnored private var publishWaits = false

    /// A mod's script, loaded on first use. The lists it reads are built
    /// first: they aren't kept up while no mod runs.
    func runtime(for name: String) throws -> ModRuntime {
        if !center.isRunning {
            starting = true
            if tracking { publish() } else { track() }
            starting = false
        }
        return try center.runtime(for: name)
    }

    @ObservationIgnored private var starting = false
    /// True while a change to the model will build the lists again.
    @ObservationIgnored private var tracking = false

    private func track() {
        tracking = starting || center.isRunning
        withObservationTracking {
            let started = CACurrentMediaTime()
            publish()
            if tracking {
                publishes += 1
                publishSeconds += CACurrentMediaTime() - started
            }
        } onChange: { [weak self] in
            // At most ten times a second: an agent that writes changes its
            // title and state far more often than a panel needs to hear.
            DispatchQueue.main.async {
                guard let self, !self.publishWaits else { return }
                self.publishWaits = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.publishWaits = false
                    self.track()
                }
            }
        }
    }

    private func status(_ terminal: TerminalModel?) -> Any {
        guard let terminal, terminal.isAgent else { return NSNull() }
        switch terminal.attention {
        case .needsYou: return "blocked"
        case .working: return "working"
        case .done: return "done"
        case .idle, .none: return "idle"
        }
    }

    private func program(_ terminal: TerminalModel?) -> [String: Any] {
        let key = terminal?.programKey ?? "shell"
        let agent = Programs.isAgent(key)
        return ["key": key, "name": Programs.name(key) ?? key, "icon": NSNull(), "tint": true, "tile": NSNull(), "color": NSNull(), "shell": !agent && terminal?.foreground == nil, "agent": agent]
    }

    private func any(_ json: JSON) -> Any {
        switch json {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .array(let list): list.map(any)
        case .object(let fields): fields.mapValues(any)
        }
    }

    /// Hands the mods the app's state as herdr-app's does: spaces, tabs,
    /// panes, agents, the focus, the theme.
    private func publish() {
        // Nothing to tell while no mod's script is loaded: the app pays
        // nothing for mods it doesn't have or doesn't show. `runtime(for:)`
        // brings this back when one loads.
        guard starting || center.isRunning, let model else { return }
        let active = model.activeSpace
        let activeTab = active.flatMap { model.activeTab(in: $0) }
        let focusedPane = active.flatMap { space in activeTab.flatMap { model.focusedPane(in: $0, of: space) } }
        let focusedAddress = model.focusedAddress
        var spaces: [[String: Any]] = [], panes: [[String: Any]] = [], agents: [[String: Any]] = []
        for (spaceIndex, space) in model.allSpaces.enumerated() {
            let shownTab = model.activeTab(in: space)
            var tabs: [[String: Any]] = []
            var worst = Attention.none
            for (tabIndex, tab) in space.tabs.enumerated() {
                let terminals = tab.root.terminals
                var attention = Attention.none
                for (pane, local) in terminals {
                    let address = qualify(local, on: space.machine)
                    let terminal = model.store.model(address)
                    attention = max(attention, terminal?.attention ?? .none)
                    let isFocused = space.id == active?.id && tab.id == activeTab?.id && pane == focusedPane
                    panes.append([
                        "pane": pane, "terminal": address, "tab": tab.id, "title": terminal?.title ?? "",
                        "cwd": terminal.map { $0.currentFolder as Any } ?? NSNull(), "branch": NSNull(), "status": status(terminal),
                        "app": terminal?.foreground?.program as Any? ?? NSNull(), "program": program(terminal),
                        "focused": isFocused, "zoomed": model.zoomedPane(in: tab, of: space) == pane, "movable": true,
                    ])
                    if let terminal, terminal.isAgent, terminal.isLive {
                        agents.append([
                            "address": address, "pane": pane, "space": space.id, "space_name": model.title(of: space), "tab": tab.id,
                            "tab_index": tabIndex + 1, "tab_name": tab.name, "status": status(terminal), "app": terminal.foreground?.program as Any? ?? NSNull(),
                            "program": program(terminal), "title": terminal.title, "seq": terminal.turn, "pinned": false, "focused": address == focusedAddress,
                        ])
                    }
                }
                worst = max(worst, attention)
                tabs.append([
                    "id": tab.id, "index": tabIndex + 1, "name": tab.name.isEmpty ? "tb\(tabIndex + 1)" : tab.name, "named": !tab.name.isEmpty,
                    "active": tab.id == shownTab?.id, "status": statusName(attention), "panes": terminals.count,
                    "zoomed": model.zoomedPane(in: tab, of: space) != nil, "settled": true,
                    "settled_at": NSNull(), "changed_at": NSNull(), "working_since": NSNull(),
                ])
            }
            spaces.append([
                "id": space.id, "index": spaceIndex + 1, "name": model.title(of: space), "named": !space.space.name.isEmpty,
                "folder": space.space.folder, "machine": space.machine.isEmpty ? NSNull() : space.machine as Any, "branch": NSNull(),
                "active": space.id == active?.id, "status": statusName(worst), "tabs": tabs,
            ])
        }
        center.setData("spaces", spaces)
        center.setData("panes", panes)
        center.setData("agents", agents)
        center.setData("terminals", model.store.all.map { any($0.record) })
        var machines: [[String: Any]] = [["name": NSNull(), "layout": model.slots[""]?.isReady == true ? "ready" : "loading"]]
        for remote in model.remotes {
            machines.append(["name": remote.name, "layout": !remote.isConnected ? "unavailable" : model.slots[remote.name]?.isReady == true ? "ready" : "loading"])
        }
        center.setData("machines", machines)
        if let active, let activeTab {
            let terminal = focusedAddress.flatMap { model.store.model($0) }
            center.setData("focused", [
                "space": active.id, "tab": activeTab.id, "pane": focusedPane as Any? ?? NSNull(), "terminal": focusedAddress as Any? ?? NSNull(),
                "shown": focusedAddress as Any? ?? NSNull(), "agent": terminal?.isAgent == true ? focusedAddress as Any : NSNull(),
                "cwd": terminal.map { $0.currentFolder as Any } ?? NSNull(),
            ] as [String: Any])
        } else {
            center.setData("focused", NSNull())
        }
        let theme = model.prefs.theme
        // Mods draw in the terminals' colors: on a card of that color, or
        // on the floating panel, whose surface is a shade off it.
        let own = layout?.isOwn ?? true
        let dark = theme.isDark
        var file: [String: Any] = ["background": theme.background, "foreground": theme.foreground, "ansi": theme.ansi]
        if own, sidebarStyle == .floating, dark { file["background"] = ModTheme.mix(theme.background, "#ffffff", 0.09) }
        if let selection = theme.selection { file["selection"] = selection }
        if let cursor = theme.cursor { file["cursor"] = cursor }
        var colors = ModTheme.colors(from: file)
        if let accent = theme.accent { colors["accent"] = accent }
        center.setData("theme", colors)
        center.setData("settings", [
            "zoom": 1, "dark": dark, "theme": model.prefs.themeName, "font_family": model.prefs.fontName, "font_size": model.prefs.fontSize,
        ] as [String: Any])
        center.setData("window", [
            "platform": "macos", "titlebar": "system", "buttons": false, "maximized": false,
            "fullscreen": NSApp.mainWindow?.styleMask.contains(.fullScreen) ?? false, "active": NSApp.isActive,
        ] as [String: Any])
        ModFonts.monoFamily = model.prefs.fontName
    }

    private func statusName(_ attention: Attention) -> Any {
        switch attention {
        case .needsYou: "blocked"
        case .working: "working"
        case .done: "done"
        case .idle: "idle"
        case .none: NSNull()
        }
    }

    // MARK: What mods ask for

    func modRun(command: String, arguments: [String: Any], from copy: ModCopy?) {
        guard let model else { return }
        if layout?.run(command, arguments) == true { return }
        let id = arguments["id"] as? String
        func space(_ key: String?) -> SpaceItem? { key.flatMap { key in model.allSpaces.first { $0.id == key } } ?? model.activeSpace }
        func tab(_ id: String?) -> (SpaceItem, LayoutTab)? {
            guard let id else { return nil }
            for space in model.allSpaces { if let tab = space.tabs.first(where: { $0.id == id }) { return (space, tab) } }
            return nil
        }
        switch command {
        case "tab.select":
            if let (space, tab) = tab(id) { model.select(space: space); model.select(tab: tab, in: space) }
        case "tab.new": model.newTab()
        case "tab.close": if let (space, tab) = tab(id) { model.closeTab(tab.id, in: space) } else { model.closeTab() }
        case "tab.next": model.selectNeighborTab(1)
        case "tab.prev": model.selectNeighborTab(-1)
        case "tab.rename":
            if let (space, tab) = tab(id) { model.select(tab: tab, in: space) }
            model.startRenamingTab()
        case "tab.move":
            if let (space, tab) = tab(id), let index = (arguments["index"] as? NSNumber)?.intValue { model.moveTab(tab.id, in: space, to: max(0, index - 1)) }
        case "space.select": if let found = space(id), id != nil { model.select(space: found) }
        case "space.new": model.newSpace(on: "")
        case "space.next": model.selectNeighborSpace(1)
        case "space.prev": model.selectNeighborSpace(-1)
        case "pane.focus":
            let pane = arguments["pane"] as? String ?? id
            for space in model.allSpaces {
                for tab in space.tabs where tab.root.terminals.contains(where: { $0.pane == pane }) {
                    model.select(space: space)
                    model.select(tab: tab, in: space)
                    if let pane { model.focus(pane: pane, in: tab, of: space) }
                    return
                }
            }
        case "agent.focus", "terminal.focus":
            if let address = arguments["address"] as? String ?? arguments["terminal"] as? String ?? id { model.reveal(address) }
        case "pane.split": model.split((arguments["direction"] as? String) == "down" ? .column : .row)
        case "pane.close": model.closePane()
        case "pane.zoom": model.toggleZoom()
        case "mod.open":
            if let name = arguments["mod"] as? String ?? arguments["name"] as? String ?? id { open(mod: name, props: arguments["props"] as? [String: Any] ?? [:]) }
        case "mod.close": if let name = arguments["mod"] as? String ?? id { overlays.removeAll { $0.mod == name } }
        case "layout.switch": loadLayout(named: arguments["name"] as? String)
        case "window.minimize": NSApp.mainWindow?.miniaturize(nil)
        case "window.maximize": NSApp.mainWindow?.zoom(nil)
        case "window.close": NSApp.mainWindow?.performClose(nil)
        case "app.settings": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        default:
            lastUnknownCommand = command
            copy?.runtime.noteUnsupportedCommand(command)
        }
    }

    /// Opens a mod over the window, as its `mod.json` says (`mod.open:<name>`).
    func open(mod name: String, props: [String: Any] = [:]) {
        // A second press closes it.
        if let shown = overlays.first(where: { $0.mod == name && $0.kind == "dialog" }) {
            modCloseOverlay(shown.id)
            return
        }
        let manifest = entry(name)?.manifest
        _ = modOpenOverlay([
            "mod": name, "props": props, "kind": manifest?.overlayKind ?? "dialog",
            "width": manifest?.overlayWidth ?? 560, "height": manifest?.overlayHeight as Any? ?? NSNull(),
        ], from: nil)
    }

    func modOpenOverlay(_ spec: [String: Any], from copy: ModCopy?) -> String {
        guard let name = spec["mod"] as? String else { return "" }
        // herdr-app's own menus have no script here.
        guard !WindowLayout.shipped.contains(name), entry(name) != nil else {
            lastUnknownCommand = "openOverlay(\(name))"
            return ""
        }
        let id = "overlay-\(nextOverlay)"
        nextOverlay += 1
        var props = spec["props"] as? [String: Any] ?? [:]
        props["overlay"] = id
        var at: CGPoint?
        if let window = NSApp.mainWindow, (spec["at"] as? String) == "pointer" || spec["kind"] as? String == "popup" {
            let point = window.mouseLocationOutsideOfEventStream
            at = CGPoint(x: point.x, y: (window.contentView?.bounds.height ?? window.frame.height) - point.y)
        }
        if let key = spec["key"] as? String { overlays.removeAll { $0.id == key } }
        overlays.append(Overlay(
            id: id, mod: name, props: props, kind: spec["kind"] as? String ?? "dialog",
            width: CGFloat((spec["width"] as? NSNumber)?.doubleValue ?? 480),
            height: (spec["height"] as? NSNumber).map { CGFloat($0.doubleValue) }, at: at
        ))
        return id
    }

    func modCloseOverlay(_ id: String?) {
        if let id { overlays.removeAll { $0.id == id } } else if !overlays.isEmpty { overlays.removeLast() }
        model?.requestFocus()
    }

    func modNotify(_ notification: [String: Any]) -> String {
        let id = "note-\(nextOverlay)"
        nextOverlay += 1
        let toast = Toast(id: id, title: notification["title"] as? String ?? "", body: notification["body"] as? String ?? "", level: notification["level"] as? String ?? "info")
        toasts.append(toast)
        let seconds = ((notification["timeout"] as? NSNumber)?.doubleValue).map { $0 > 100 ? $0 / 1000 : $0 } ?? 5
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 1.5)) { [weak self] in self?.toasts.removeAll { $0.id == id } }
        return id
    }

    func dismiss(toast id: String) { toasts.removeAll { $0.id == id } }

    func modPlaySound(_ sound: String) {
        if let named = NSSound(named: NSSound.Name(sound)) { named.play() } else { NSSound.beep() }
    }

    /// The last programs mods ran, newest last: what a mod really does,
    /// beside what its files say.
    @ObservationIgnored private(set) var ran: [String] = []

    private func note(_ line: String) {
        ran.append(String(line.prefix(300)))
        if ran.count > 200 { ran.removeFirst(ran.count - 200) }
    }

    func modExec(_ request: ModExecRequest) async throws -> ModExecResult {
        guard let machine = request.machine, !machine.isEmpty else {
            note(([request.command] + request.arguments).joined(separator: " "))
            return try await ModProcess.run(request)
        }
        // On another machine: through the core, as one shell line.
        func quote(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var line = ([request.command] + request.arguments).map(quote).joined(separator: " ")
        if let cwd = request.cwd, !cwd.isEmpty { line = "cd \(quote(cwd)) && " + line }
        return try await modCore(["exec", "--on", machine, line])
    }

    func modCore(_ arguments: [String]) async throws -> ModExecResult {
        // By name: Swiftr's own hc is first in the mods' PATH.
        note((["hc"] + arguments).joined(separator: " "))
        return try await ModProcess.run(ModExecRequest(command: "hc", arguments: arguments, timeout: 60_000))
    }

    func modPickFolder(prompt: String?) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if let prompt { panel.prompt = prompt }
        return await panel.begin() == .OK ? panel.url?.path : nil
    }

    // MARK: Keys

    /// `keys.json` in the mods' home: `{"cmd-shift-y": "mod.open:vault"}`.
    private func loadKeys() {
        keys = []
        guard let data = try? Data(contentsOf: home.appending(path: "keys.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (chord, value) in json {
            guard let command = value as? String ?? (value as? [String: Any])?["command"] as? String else { continue }
            let arguments = (value as? [String: Any])?["args"] as? [String: Any] ?? [:]
            keys.append((Set(chord.lowercased().split(separator: "-").map(String.init)), command, arguments))
        }
        guard keyMonitor == nil, !keys.isEmpty else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === NSApp.mainWindow || event.window == nil else { return event }
            var pressed: Set<String> = [(event.charactersIgnoringModifiers ?? "").lowercased()]
            let flags = event.modifierFlags
            if flags.contains(.command) { pressed.insert("cmd") }
            if flags.contains(.shift) { pressed.insert("shift") }
            if flags.contains(.option) { pressed.insert("alt") }
            if flags.contains(.control) { pressed.insert("ctrl") }
            guard pressed.count > 1, let hit = self.keys.first(where: { $0.chord == pressed }) else { return event }
            self.run(keyCommand: hit.command, arguments: hit.arguments)
            return nil
        }
    }

    /// `mod.open:vault`, `vault.refresh`, or one of the commands above.
    func run(keyCommand: String, arguments: [String: Any] = [:]) {
        if keyCommand.hasPrefix("mod.open:") {
            open(mod: String(keyCommand.dropFirst("mod.open:".count)))
        } else if !center.deliver(command: keyCommand) {
            modRun(command: keyCommand, arguments: arguments, from: nil)
        }
    }

    // MARK: Bringing mods over from herdr-app

    /// The mods of the person's herdr-app that aren't herdr-app's own, and
    /// aren't here yet.
    /// herdr-app's mods folder (a test's stand-in home has its own).
    private var herdrMods: URL {
        (standInHome.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser).appending(path: ".config/herdr-app/mods")
    }

    var importable: [String] {
        let source = herdrMods
        let names = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
        let here = Set(entries.map(\.name))
        return names.filter { name in
            !WindowLayout.shipped.contains(name) && !Self.builtIn.contains(name) && !here.contains(name) && !name.hasPrefix(".")
                && FileManager.default.fileExists(atPath: source.appending(path: "\(name)/main.js").path)
        }.sorted()
    }

    /// Copies a mod folder into Swiftr's. It isn't allowed anything until
    /// the person says so.
    @discardableResult
    func add(folder: URL) -> String? {
        let name = folder.lastPathComponent
        guard FileManager.default.fileExists(atPath: folder.appending(path: "main.js").path) else { return nil }
        let target = center.modsFolder.appending(path: name)
        // New code under a name already allowed: it asks again.
        grants[name] = nil
        saveChoices()
        try? FileManager.default.removeItem(at: target)
        do { try FileManager.default.copyItem(at: folder, to: target) } catch { return nil }
        rescan()
        center.reload(name)
        // In sight at once, where the person allows it.
        showInPanel(name)
        return name
    }

    func importFromHerdr(_ name: String) {
        add(folder: herdrMods.appending(path: name))
    }

    /// What a link holds (a herdr.dev gallery page, a folder on GitHub),
    /// copied into Swiftr's: mods that stay off until the person allows
    /// them, layouts they can then pick. Nothing they have is replaced.
    func add(link: String) async -> Result<ModFetch.Added, ModFetch.Failure> {
        let home = home
        do {
            let added = try await Task.detached { try await ModFetch.add(link: link, to: home) }.value
            rescan()
            for name in added.mods { center.reload(name) }
            // In sight at once, where the person allows it.
            if let first = added.mods.first, layout?.isOwn == true { showInPanel(first) }
            return .success(added)
        } catch let failure as ModFetch.Failure {
            return .failure(failure)
        } catch {
            return .failure(ModFetch.Failure(error.localizedDescription))
        }
    }

    /// The guide for the person's coding agent, its list of names and the
    /// tool's launcher, in the mods' home (`ModGuide`): what lets someone
    /// ask their agent for a mod.
    private func writeGuide() {
        #if DEBUG
        // A build from Xcode or a test must not point the person's own
        // launcher at itself: only a test's own home gets them.
        guard ProcessInfo.processInfo.environment["SWIFTR_MODS_HOME"] != nil else { return }
        #endif
        guard let program = Bundle.main.executablePath else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        ModGuide.write(home: home, program: program, version: version)
    }

    /// Copies a layout file into Swiftr's and shows it.
    func add(layout file: URL) {
        let target = home.appending(path: "layouts/\(file.lastPathComponent)")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: file, to: target)
        rescan()
        loadLayout(named: file.deletingPathExtension().lastPathComponent)
    }
}
