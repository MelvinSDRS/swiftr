import AppKit
import HerdrKit
import Observation

/// A machine the local core added, as `machine.list` shows it.
struct RemoteMachine: Equatable {
    let name: String
    /// The other core's permanent id: it stays when the machine is renamed.
    let id: String
    let host: String
    /// How ssh reaches it, as it was added (`vps`, `can@10.0.0.7`).
    let target: String
    /// connecting, connected, needs_login or unreachable.
    let state: String
    let why: String?
    /// Its hc version when last seen.
    let version: String

    init(json: JSON) {
        name = json["name"]?.string ?? ""
        id = json["id"]?.string ?? ""
        host = json["host"]?.string ?? ""
        target = json["target"]?.string ?? ""
        state = json["state"]?.string ?? "unreachable"
        why = json["why"]?.string
        version = json["version"]?.string ?? ""
    }

    var isConnected: Bool { state == "connected" }
}

/// Swiftr's state: the core connection, every terminal, each machine's
/// layout and what this window shows.
@Observable
final class AppModel {
    enum Link: Equatable {
        case connecting
        /// This Mac has no herdr-core: Swiftr installs it (`CoreInstall`).
        case installing
        case connected
        case failed(String)
        /// No herdr-core, and installing it failed: why.
        case installFailed(String)
    }

    /// A name being edited.
    enum Rename: Identifiable, Equatable {
        case space(Place, String)
        case tab(Place, String)
        /// A machine by the core's name for it ("" is this Mac), and the
        /// name Swiftr shows now.
        case machine(String, String)

        var id: String {
            switch self {
            case .space(let p, _): "space:" + p.key
            case .tab(let p, _): "tab:" + p.key
            case .machine(let name, _): "machine:" + name
            }
        }
    }

    /// Its `hcPath` changes once Swiftr installed herdr-core.
    private(set) var endpoint: CoreEndpoint
    let prefs = Preferences()
    let store = TerminalStore()

    private(set) var link: Link = .connecting
    /// What the local core calls itself (its host name).
    private(set) var hostName = Host.current().localizedName ?? "This Mac"
    private(set) var remotes: [RemoteMachine] = []
    /// `machine.list` answered at least once.
    private(set) var machinesKnown = false
    /// One layout per machine; "" is this Mac.
    private(set) var slots: [String: LayoutSlot] = [:]
    var view: ViewState {
        didSet {
            if view != oldValue { scheduleSave() }
            if sidebarVisible != view.sidebarVisible { sidebarVisible = view.sidebarVisible }
        }
    }
    /// `view.sidebarVisible`, apart: the window reads only this, not the
    /// whole view state, which changes at each tab switch.
    private(set) var sidebarVisible = true
    private(set) var appActive = true
    var renaming: Rename?
    var problem: String?
    /// The Add a Machine sheet, while it shows.
    var addingMachine: MachineAdder?
    /// Rises when the keyboard should go to the focused pane.
    private(set) var focusTick = 0
    /// Moves on their way to the core, shown at once: machine → its space ids,
    /// space key → its tab ids.
    var pendingSpaces: [String: PendingOrder] = [:]
    var pendingTabs: [String: PendingOrder] = [:]
    /// What was written to each Claude and not sent yet, by terminal address.
    var drafts: [String: String] = [:] {
        didSet { if drafts != oldValue { scheduleDraftSave() } }
    }
    /// Pictures put in a Claude's field and not sent yet, by terminal address (not saved).
    var draftImages: [String: [PendingImage]] = [:]
    /// Passages of the conversation quoted in a Claude's next message, by terminal address (not saved).
    var draftQuotes: [String: [String]] = [:]
    /// ⌃S: a draft set aside in each field, back once the next message went (not saved).
    var stashedDrafts: [String: String] = [:]

    /// Agents the sidebar keeps with the done ones until the pointer leaves
    /// it, by address (`keepDoneAgents`).
    private(set) var keptDone: Set<String> = []
    /// The pointer is on the sidebar.
    @ObservationIgnored var pointerOnSidebar = false

    /// Logos found in space folders this launch, by `logoKey`.
    private(set) var logos: [String: FolderLogo] = [:]
    @ObservationIgnored private var logoSearches: Set<String> = []

    @ObservationIgnored private(set) var connection: CoreConnection?
    @ObservationIgnored private(set) var pool: TerminalPool!
    /// Sounds and notifications about agents.
    @ObservationIgnored private(set) var alerts: AgentAlerts!
    /// Tab titles, closed tabs and resuming, for Claude Code.
    @ObservationIgnored private(set) var claude: ClaudeWatch!
    /// Transcripts of the Claude panes shown as conversations.
    @ObservationIgnored private(set) var feeds: MessageFeeds!
    /// The agents the + menu offers, and where it is open.
    @ObservationIgnored private(set) var launcher: AgentLauncher!
    /// herdr-core's latest release, and updates to it.
    @ObservationIgnored private(set) var updates: CoreUpdates!
    /// The usage limits of the agents whose conversations show.
    @ObservationIgnored private(set) var usage: UsageMonitor!
    @ObservationIgnored private var generation = 0
    /// Events that came before the snapshot they follow.
    @ObservationIgnored private var early: [JSON]?
    @ObservationIgnored var born: [String: Date] = [:]
    /// Terminals being made, closed, checked or adopted.
    @ObservationIgnored var busy: Set<String> = []
    @ObservationIgnored private var seenSent: [String: Int] = [:]
    @ObservationIgnored var lastMove = 0
    @ObservationIgnored var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(endpoint: CoreEndpoint = .local()) {
        self.endpoint = endpoint
        view = ViewState.load(session: endpoint.session)
        sidebarVisible = view.sidebarVisible
        drafts = Drafts.load(session: endpoint.session)
        pool = TerminalPool(model: self)
        alerts = AgentAlerts(model: self)
        claude = ClaudeWatch(model: self)
        feeds = MessageFeeds(model: self)
        launcher = AgentLauncher(model: self)
        updates = CoreUpdates(model: self)
        usage = UsageMonitor(model: self)
        store.onChange = { [unowned self] change in self.storeChanged(change) }
    }

    // MARK: Connection

    #if DEBUG
    /// Tests: acts as if Swiftr came to the front or left it.
    func debugSetActive(_ active: Bool) {
        appActive = active
        if active { markSeen() }
    }
    #endif

    func start() async {
        guard !started else { return }
        started = true
        #if DEBUG
        DebugHooks.install(self)
        #endif
        appActive = NSApp.isActive
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated {
                self.appActive = true
                self.markSeen()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { self.appActive = false }
        })
        alerts.start()
        claude.start()
        await connectLoop()
    }

    private func connectLoop() async {
        var delay = 0.5
        while true {
            do {
                try await connect()
                return
            } catch {
                // No core answered, and this Mac has no hc to start one.
                if CoreEndpoint.installedHC(environment: endpoint.environment) == nil {
                    if await installCore() { continue }
                    await pause(seconds: 30)
                    continue
                }
                link = .failed(error.localizedDescription)
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 10)
            }
        }
    }

    /// Installs herdr-core; false when that failed, and `link` says why.
    private func installCore() async -> Bool {
        link = .installing
        // Not what says Swiftr was opened from a terminal of another core.
        let environment = endpoint.environment.filter { !["HC_TERMINAL_ID", "HC_TERMINAL_SOCKET", "HC_SCOPE"].contains($0.key) }
        do {
            try await CoreInstall.run(environment: environment)
        } catch {
            link = .installFailed((error as? CoreError)?.message ?? error.localizedDescription)
            return false
        }
        guard let hc = CoreEndpoint.installedHC(environment: endpoint.environment) else {
            link = .installFailed("The installer ran, but Swiftr can't find hc.")
            return false
        }
        endpoint.hcPath = hc
        link = .connecting
        return true
    }

    @ObservationIgnored private var retryRequested = false

    /// Try Again, after installing herdr-core failed: ends the wait.
    func retryNow() {
        retryRequested = true
    }

    private func pause(seconds: Double) async {
        let end = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < end, !retryRequested {
            try? await Task.sleep(for: .milliseconds(200))
        }
        retryRequested = false
    }

    private func connect() async throws {
        generation += 1
        let gen = generation
        let c = try await CoreConnection.connect(to: endpoint)
        guard gen == generation else {
            c.close()
            return
        }
        connection = c
        c.onLost { why in onMain { self.lost(why, generation: gen) } }
        // Subscribe before reading documents (schema/README.md, "Documents").
        early = []
        let feed = EventFeed(
            deliver: { batch in onMain { self.deliver(batch, generation: gen) } },
            ended: { _ in }
        )
        let snapshot = try await c.subscribe(sink: feed)
        guard gen == generation else { return }
        store.reset(seq: snapshot["seq"]?.int64 ?? 0, terminals: snapshot["terminals"]?.array ?? [])
        let pending = early ?? []
        early = nil
        if !pending.isEmpty { store.apply(pending) }
        if !c.coreName.isEmpty { hostName = c.coreName }
        link = .connected
        await refreshMachines()
        await loadDocuments()
        pool.reconnected()
        feeds.reconnected()
        pollMachines(generation: gen)
        layoutChanged()
    }

    private func deliver(_ batch: [JSON], generation gen: Int) {
        guard gen == generation else { return }
        if early != nil {
            early?.append(contentsOf: batch)
            return
        }
        store.apply(batch)
    }

    private func lost(_ why: String, generation gen: Int) {
        guard gen == generation else { return }
        connection = nil
        link = .connecting
        pollTask?.cancel()
        pool.connectionLost()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await connectLoop()
        }
    }

    /// Machine states have no events: ask now and then.
    private func pollMachines(generation gen: Int) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled, gen == generation {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, gen == generation else { return }
                await refreshMachines()
            }
        }
    }

    func refreshMachines() async {
        guard let c = connection else { return }
        guard let r = try? await c.call("machine.list") else { return }
        let list = (r["machines"]?.array ?? []).map(RemoteMachine.init(json:)).filter { !$0.name.isEmpty }
        machinesKnown = true
        let before = remotes
        if list != remotes { remotes = list }
        var next = slots
        if next[""] == nil { next[""] = LayoutSlot(machine: nil) }
        for m in list where next[m.name] == nil { next[m.name] = LayoutSlot(machine: m.name) }
        for key in next.keys where !key.isEmpty && !list.contains(where: { $0.name == key }) { next[key] = nil }
        if Set(next.keys) != Set(slots.keys) { slots = next }
        var reloaded = false
        for m in list {
            guard let slot = slots[m.name] else { continue }
            let was = before.first { $0.name == m.name }?.isConnected ?? false
            if !m.isConnected {
                if slot.isReady { slot.reset(error: m.why ?? m.state) }
            } else if !slot.isReady || !was {
                await slot.reload(c)
                reloaded = true
            }
        }
        if reloaded || list != before { layoutChanged() }
    }

    /// Reads every reachable machine's layout.
    func loadDocuments() async {
        guard let c = connection else { return }
        for (key, slot) in slots where key.isEmpty || remotes.first(where: { $0.name == key })?.isConnected == true {
            await slot.reload(c)
        }
    }

    // MARK: Events

    private func storeChanged(_ change: TerminalStore.Change) {
        switch change {
        case .reset:
            // A fresh snapshot (or a remote reconnect): documents may have moved.
            guard early == nil, link == .connected else { return }
            claude.snapshot()
            Task {
                await refreshMachines()
                await loadDocuments()
                layoutChanged()
            }
        case .event(let type, let address, let data, let previous):
            if type == "status" { alerts.statusChanged(address, previous: previous) }
            claude.event(type, address, data: data, previous: previous)
            feeds.event(type, address)
            switch type {
            case "restarted":
                pool.existing(address)?.reattach()
                scheduleReconcile()
            case "removed":
                pool.drop(address)
                scheduleReconcile()
            case "created", "finished", "labels", "lost":
                scheduleReconcile()
            case "turn", "status":
                markSeen()
            default:
                break
            }
        case .document(let name, let machine, let version):
            guard name == LayoutSlot.documentName, let slot = slots[machine ?? ""], let c = connection else { return }
            Task {
                await slot.changed(to: version, c)
                layoutChanged()
            }
        }
    }

    /// After any layout or selection change: what to attach, what was seen,
    /// what to reconcile.
    func layoutChanged() {
        fixSelection()
        keepSessions()
        feeds.prune()
        markSeen()
        scheduleReconcile()
    }

    // MARK: What is shown

    /// Machine names in the sidebar's order ("" is this Mac): the order moved
    /// in Swiftr, then machines it doesn't place yet, this Mac first.
    var machineNames: [String] {
        let known = [""] + remotes.map(\.name)
        let placed = (view.machineOrder ?? []).filter { known.contains($0) }
        return placed + known.filter { !placed.contains($0) }
    }

    /// Machines and their spaces, in the sidebar's order.
    var machineItems: [MachineItem] {
        machineNames.compactMap { name in
            if name.isEmpty {
                return MachineItem(
                    name: "", title: title(ofMachine: ""), icon: icon(ofMachine: ""),
                    state: link == .connected ? "connected" : "connecting", why: nil,
                    spaces: spaces(on: ""), loading: slots[""]?.loading ?? (link != .connected), error: slots[""]?.error
                )
            }
            guard let m = remotes.first(where: { $0.name == name }) else { return nil }
            return MachineItem(
                name: m.name, title: title(ofMachine: m.name), icon: icon(ofMachine: m.name), state: m.state, why: m.why,
                spaces: spaces(on: m.name), loading: slots[m.name]?.loading ?? false, error: slots[m.name]?.error
            )
        }
    }

    /// What Swiftr calls a machine ("" is this Mac): the name given in
    /// Swiftr, else the core's.
    func title(ofMachine name: String) -> String {
        look(ofMachine: name)?.name ?? coreTitle(ofMachine: name)
    }

    /// The core's name for a machine: this Mac's host name, or the name
    /// its addresses start with.
    func coreTitle(ofMachine name: String) -> String {
        name.isEmpty ? hostName : name
    }

    func icon(ofMachine name: String) -> String {
        look(ofMachine: name)?.icon ?? defaultIcon(ofMachine: name)
    }

    func defaultIcon(ofMachine name: String) -> String {
        name.isEmpty ? "laptopcomputer" : "server.rack"
    }

    private func look(ofMachine name: String) -> MachineLook? {
        view.machineLooks?[lookKey(ofMachine: name)]
    }

    /// Where a machine's look is kept: the other core's id, which stays when
    /// the machine is renamed; "" for this Mac.
    func lookKey(ofMachine name: String) -> String {
        guard !name.isEmpty, let id = remotes.first(where: { $0.name == name })?.id, !id.isEmpty else { return name }
        return id
    }

    /// A machine's spaces, with moves still on their way already in place.
    func spaces(on machine: String) -> [SpaceItem] {
        var list = slots[machine]?.document?.spaces ?? []
        if let order = pendingSpaces[machine] { list = list.arranged(by: order.ids) }
        return list.map { space in
            var space = space
            if let order = pendingTabs[Place(machine, space.id).key] { space.tabs = space.tabs.arranged(by: order.ids) }
            return SpaceItem(machine: machine, space: space)
        }
    }

    /// Every space, in the sidebar's order.
    var allSpaces: [SpaceItem] {
        machineNames.flatMap { spaces(on: $0) }
    }

    /// A machine whose spaces the sidebar hides ("" is this Mac).
    func isCollapsed(_ machine: String) -> Bool {
        view.collapsedMachines?.contains(lookKey(ofMachine: machine)) == true
    }

    /// The sidebar lists this space's tabs under it.
    func isExpanded(_ space: SpaceItem) -> Bool {
        view.expandedSpaces?.contains(space.id) == true
    }

    /// The sidebar hides the agents' rows.
    var agentsCollapsed: Bool { view.agentsCollapsed == true }

    /// The sidebar hides the spaces' list.
    var spacesCollapsed: Bool { view.spacesCollapsed == true }

    /// The sidebar hides this group's rows.
    func isFolded(_ group: AgentGroup) -> Bool {
        view.foldedAgentGroups?.contains(group.key) == true
    }

    /// The first space the sidebar shows, else the first of all.
    private func firstShown(_ all: [SpaceItem]) -> SpaceItem? {
        all.first { !isCollapsed($0.machine) } ?? all.first
    }

    var activeSpace: SpaceItem? {
        let all = allSpaces
        if let key = view.activeSpace {
            if let s = all.first(where: { $0.id == key }) { return s }
            // Its machine should answer soon: wait for it rather than show
            // another space for a moment (and attach that space's terminals).
            if machineLoading(splitAddress(key).machine) { return nil }
        }
        return firstShown(all)
    }

    /// A machine whose layout should come soon: the list of machines or its
    /// line is on the way, or its layout is loading.
    func machineLoading(_ machine: String) -> Bool {
        guard link == .connected else { return true }
        if machine.isEmpty { return slots[""]?.isReady != true }
        guard machinesKnown else { return true }
        guard let r = remotes.first(where: { $0.name == machine }) else { return false }
        return r.state == "connecting" || (r.isConnected && slots[machine]?.isReady != true)
    }

    func activeTab(in space: SpaceItem) -> LayoutTab? {
        let id = view.activeTab[space.id]
        return space.tabs.first { $0.id == id } ?? space.tabs.first
    }

    func tabKey(_ tab: LayoutTab, in space: SpaceItem) -> String {
        Place(space.machine, tab.id).key
    }

    func focusedPane(in tab: LayoutTab, of space: SpaceItem) -> String? {
        let blocks = tab.root.visibleBlocks
        if let id = view.focusedPane[tabKey(tab, in: space)], blocks.contains(where: { $0.id == id }) { return id }
        return blocks.first?.id
    }

    func zoomedPane(in tab: LayoutTab, of space: SpaceItem) -> String? {
        guard let id = view.zoomedPane[tabKey(tab, in: space)], tab.root.find(id) != nil else { return nil }
        return id
    }

    /// The terminal of the focused pane in the shown tab.
    var focusedAddress: String? {
        activeSpace.flatMap(focusedAddress(in:))
    }

    /// The terminal of the focused pane in a space's shown tab.
    func focusedAddress(in space: SpaceItem) -> String? {
        activeTab(in: space).flatMap { focusedAddress(in: $0, of: space) }
    }

    /// The terminal of the focused pane in one of a space's tabs.
    func focusedAddress(in tab: LayoutTab, of space: SpaceItem) -> String? {
        guard let pane = focusedPane(in: tab, of: space), let t = tab.root.find(pane)?.terminal else { return nil }
        return qualify(t, on: space.machine)
    }

    /// Terminals on screen now.
    var visibleAddresses: [String] {
        guard let space = activeSpace, let tab = activeTab(in: space) else { return [] }
        if let z = zoomedPane(in: tab, of: space), let t = tab.root.find(z)?.terminal { return [qualify(t, on: space.machine)] }
        return tab.root.visibleBlocks.compactMap(\.terminal).map { qualify($0, on: space.machine) }
    }

    /// Where a terminal shows, in any machine's layout.
    func place(of address: String) -> TerminalPlace? {
        let (machine, local) = splitAddress(address)
        for space in spaces(on: machine) {
            for (index, tab) in space.tabs.enumerated() {
                if let pane = tab.root.terminals.first(where: { $0.terminal == local })?.pane {
                    return TerminalPlace(space: space, tab: tab, index: index, pane: pane)
                }
            }
        }
        return nil
    }

    /// A tab by its id on a machine.
    func place(ofTab tabID: String, on machine: String) -> TerminalPlace? {
        for space in spaces(on: machine) {
            if let index = space.tabs.firstIndex(where: { $0.id == tabID }) {
                let tab = space.tabs[index]
                return TerminalPlace(space: space, tab: tab, index: index, pane: tab.root.visibleBlocks.first?.id ?? "")
            }
        }
        return nil
    }

    /// The person sees this terminal now: on screen in Swiftr, in front.
    func isLooking(at address: String) -> Bool {
        guard appActive, visibleAddresses.contains(address) else { return false }
        let window = NSApp.windows.first { AppDelegate.isMainWindow($0) }
        return window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
    }

    /// Brings Swiftr to the front on a terminal's pane (a notification was clicked).
    func show(_ address: String) {
        reveal(address)
        if let window = NSApp.windows.first(where: { AppDelegate.isMainWindow($0) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    /// Herdr.app, the new herdr-app (not the old herdr, `so.pen.herdr-gpui`).
    static let herdrAppID = "dev.herdr.app"

    /// Herdr's way: the space's name, else the folder of its first terminal.
    func title(of space: SpaceItem) -> String {
        if !space.space.name.isEmpty { return space.space.name }
        let folder = shownFolder(of: space)
        return folder.isEmpty ? "Space" : folderName(folder)
    }

    /// The folder a space stands for: its own, or for an unnamed space, the
    /// one its first terminal is in, which names it.
    func shownFolder(of space: SpaceItem) -> String {
        if space.space.name.isEmpty, let first = space.addresses.first, let m = store.model(first), !m.currentFolder.isEmpty {
            return m.currentFolder
        }
        return space.space.folder
    }

    /// The icon picked for a space, else its folder's logo, a house for a
    /// home folder, or the first letter of its title.
    func look(of space: SpaceItem) -> SpaceLook {
        if let icon = view.spaceIcons?[space.id] {
            if let name = icon.image, let image = IconImages.image(name) { return .image(image) }
            if let folder = icon.folder {
                if case .image(let image, _)? = logos[logoKey(space.machine, folder)] { return .image(image) }
                return .symbol(SpaceIcons.standard)
            }
            return .symbol(icon.symbol ?? SpaceIcons.standard)
        }
        let folder = shownFolder(of: space)
        if folderName(folder) == "~" { return .symbol("house") }
        switch logos[logoKey(space.machine, folder)] {
        case .image(let image, _)?: return .image(image)
        // Still looking: the folder, rather than a letter for a moment.
        case nil where !folder.isEmpty: return .symbol(SpaceIcons.standard)
        default: break
        }
        let title = title(of: space)
        guard let first = title.first(where: { $0.isLetter || $0.isNumber }) else { return .symbol(SpaceIcons.standard) }
        return .letter(String(first).uppercased(), hash: ProjectLogo.hash(of: title))
    }

    /// Where `logos` keeps what a folder on a machine has.
    private func logoKey(_ machine: String, _ folder: String) -> String {
        machine + "\n" + folder
    }

    /// The folders whose logo a space can show, each once: the one it
    /// stands for, its own, where its terminals are, and the one its icon
    /// was picked from. Home folders have none.
    func logoFolders(of space: SpaceItem) -> [String] {
        var folders = [shownFolder(of: space), space.space.folder]
        folders += space.addresses.compactMap { store.model($0)?.currentFolder }
        if let picked = view.spaceIcons?[space.id]?.folder { folders.append(picked) }
        var seen: Set<String> = []
        return folders.filter { !$0.isEmpty && folderName($0) != "~" && seen.insert($0).inserted }
    }

    /// The logos found in a space's folders, each file once: what “Icon”
    /// offers besides the automatic one.
    func logoChoices(of space: SpaceItem) -> [LogoChoice] {
        let picked = view.spaceIcons?[space.id]?.folder
        var choices: [(choice: LogoChoice, file: String)] = []
        for folder in logoFolders(of: space) {
            guard case .image(let image, let file)? = logos[logoKey(space.machine, folder)] else { continue }
            if let i = choices.firstIndex(where: { $0.file == file }) {
                // Two folders, one file: keep the one picked.
                if folder == picked { choices[i].choice = LogoChoice(folder: folder, image: image) }
                continue
            }
            choices.append((LogoChoice(folder: folder, image: image), file))
        }
        return choices.map(\.choice)
    }

    /// Looks for the logo in each of a space's folders, once per folder and
    /// launch. Each search belongs to the model, so it ends even when the
    /// row goes away.
    func findLogos(for space: SpaceItem) {
        let machine = space.machine
        for folder in logoFolders(of: space) {
            let key = logoKey(machine, folder)
            guard logos[key] == nil, !logoSearches.contains(key) else { continue }
            logoSearches.insert(key)
            Task {
                defer { logoSearches.remove(key) }
                if let logo = await searchLogo(on: machine, in: folder) { logos[key] = logo }
            }
        }
    }

    /// The logo in `folder`; nil when the machine can't tell now, to look
    /// again later. On another machine, only SVGs at the usual places.
    private func searchLogo(on machine: String, in folder: String) async -> FolderLogo? {
        func logo(_ png: Data, file: String) -> FolderLogo {
            guard let image = NSImage(data: png) else { return .none }
            // The size menus show it at; the sidebar fits it to its own.
            image.size = NSSize(width: 16, height: 16)
            return .image(image, file: file)
        }
        if machine.isEmpty {
            let found = await Task.detached(priority: .utility) { await ProjectLogo.find(in: folder) }.value
            return found.map { logo($0.png, file: $0.file) } ?? FolderLogo.none
        }
        guard let c = connection else { return nil }
        for path in ProjectLogo.remotePaths {
            let file = (folder as NSString).appendingPathComponent(path)
            do {
                let r = try await c.call("file.read", ["path": .string(file), "on": .string(machine)], timeout: .seconds(10))
                if let text = r["text"]?.string, let image = NSImage(data: Data(text.utf8)), let png = ProjectLogo.thumbnail(of: image) {
                    return logo(png, file: file)
                }
            } catch let e as CoreError where ["not_found", "not_text", "io", "invalid_params"].contains(e.kind) {
                continue
            } catch let e as CoreError where e.kind == "needs_update" {
                break
            } catch {
                // The machine went: look again next time.
                return nil
            }
        }
        return FolderLogo.none
    }

    func title(of tab: LayoutTab, index: Int) -> String {
        tab.name.isEmpty ? "\(index + 1)" : tab.name
    }

    /// What runs in a tab, for unnamed tabs: its focused terminal's title or program.
    func subtitle(of tab: LayoutTab, in space: SpaceItem) -> String {
        let pane = focusedPane(in: tab, of: space)
        let t = pane.flatMap { tab.root.find($0)?.terminal } ?? tab.root.terminals.first?.terminal
        guard let t, let m = store.model(qualify(t, on: space.machine)) else { return "" }
        // Gemini's title is its status (`◇  Ready (x)`): its name says more.
        if GeminiScreen.isStatusTitle(m.title) { return Programs.name(m.programKey) ?? "Gemini" }
        if !m.title.isEmpty { return m.title }
        return m.foreground?.program ?? ""
    }

    func attention(of addresses: [String]) -> Attention {
        addresses.compactMap { store.model($0)?.attention }.max() ?? .none
    }

    func addresses(of tab: LayoutTab, in space: SpaceItem) -> [String] {
        tab.root.terminals.map { qualify($0.terminal, on: space.machine) }
    }

    /// The program a tab shows (a `Programs` key), as herdr-app picks it:
    /// its first agent, else its first terminal; nil without a terminal.
    func programKey(of tab: LayoutTab, in space: SpaceItem) -> String? {
        let keys = addresses(of: tab, in: space).compactMap { store.model($0)?.programKey }
        return keys.first(where: Programs.isAgent) ?? keys.first
    }

    /// Agents that report a status and have a pane, by state from the most
    /// urgent, as herdr-app groups them; in each group, the latest change first.
    var agentGroups: [AgentGroup] {
        let placed = Set(allSpaces.flatMap(\.addresses))
        let agents = store.all.filter { $0.isAgent && $0.isLive && placed.contains($0.address) }
        // A kept agent seen since stays with the done ones.
        let group = { (a: TerminalModel) in a.attention == .idle && self.keptDone.contains(a.address) ? Attention.done : a.attention }
        return Dictionary(grouping: agents, by: group)
            .map { AgentGroup(attention: $0.key, agents: $0.value.sorted(by: AgentGroup.latestFirst)) }
            .sorted { $0.attention > $1.attention }
    }

    /// The pointer is on the sidebar, or clicked a row there: the agents done
    /// now stay in their group even once seen. Looking at an agent turns it
    /// idle, and its row would jump from under the pointer to the idle ones.
    func keepDoneAgents() {
        let done = Set(store.all.filter { $0.isAgent && $0.attention == .done }.map(\.address))
        if !done.isSubset(of: keptDone) { keptDone.formUnion(done) }
    }

    /// The pointer left the sidebar: each agent goes to its own group.
    func releaseDoneAgents() {
        if !keptDone.isEmpty { keptDone = [] }
    }

    func machineReady(_ machine: String) -> Bool {
        guard link == .connected, slots[machine]?.isReady == true else { return false }
        return machine.isEmpty || remotes.first(where: { $0.name == machine })?.isConnected == true
    }

    // MARK: Upkeep

    /// Points the selection at things that exist.
    private func fixSelection() {
        let all = allSpaces
        guard !all.isEmpty else { return }
        var v = view
        if v.activeSpace == nil || !all.contains(where: { $0.id == v.activeSpace }) {
            // Only once the machine it was on answered: a slow line keeps it.
            let machine = v.activeSpace.map { splitAddress($0).machine } ?? ""
            if v.activeSpace == nil || (machinesKnown && (machineReady(machine) || !slots.keys.contains(machine))) {
                v.activeSpace = firstShown(all)?.id
            }
        }
        let ready = all.filter { machineReady($0.machine) }
        let readyMachines = Set(ready.map(\.machine))
        let spaceKeys = Set(all.map(\.id))
        let tabKeys = Set(all.flatMap { s in s.tabs.map { Place(s.machine, $0.id).key } })
        // Forget only what machines that answered no longer have.
        var keepSpaces = spaceKeys
        var keepTabs = tabKeys
        for key in v.activeTab.keys where !readyMachines.contains(splitAddress(key).machine) { keepSpaces.insert(key) }
        for key in (v.spaceIcons ?? [:]).keys where !readyMachines.contains(splitAddress(key).machine) { keepSpaces.insert(key) }
        for key in v.expandedSpaces ?? [] where !readyMachines.contains(splitAddress(key).machine) { keepSpaces.insert(key) }
        for key in v.focusedPane.keys where !readyMachines.contains(splitAddress(key).machine) { keepTabs.insert(key) }
        for key in v.zoomedPane.keys where !readyMachines.contains(splitAddress(key).machine) { keepTabs.insert(key) }
        let active = v.activeSpace
        v.prune(spaces: keepSpaces, tabs: keepTabs)
        if v.activeSpace == nil { v.activeSpace = active }
        // Pane modes of terminals gone from machines that answered.
        if let modes = v.paneModes {
            let kept = modes.filter { store.model($0.key) != nil || !readyMachines.contains(splitAddress($0.key).machine) }
            v.paneModes = kept.isEmpty ? nil : kept
        }
        // The copies of images that closed spaces had as icons.
        let images = { (v: ViewState) in Set((v.spaceIcons ?? [:]).values.compactMap(\.image)) }
        IconImages.remove(images(view).subtracting(images(v)))
        if v != view { view = v }
        // Drafts too.
        let keptDrafts = drafts.filter { store.model($0.key) != nil || !readyMachines.contains(splitAddress($0.key).machine) }
        if keptDrafts.count != drafts.count { drafts = keptDrafts }
        let keptImages = draftImages.filter { store.model($0.key) != nil || !readyMachines.contains(splitAddress($0.key).machine) }
        if keptImages.count != draftImages.count { draftImages = keptImages }
        let keptQuotes = draftQuotes.filter { store.model($0.key) != nil || !readyMachines.contains(splitAddress($0.key).machine) }
        if keptQuotes.count != draftQuotes.count { draftQuotes = keptQuotes }
    }

    private func keepSessions() {
        guard let space = activeSpace else { return }
        let onScreen = Set(visibleAddresses)
        let background = Set(space.addresses)
        pool.keep(onScreen: onScreen, background: background)
    }

    /// Marks what is on screen as seen (`herdr.seen`): once per turn, only up.
    func markSeen() {
        guard appActive, link == .connected, let c = connection else { return }
        let visible = visibleAddresses
        alerts.looked(at: visible)
        for address in visible {
            guard let m = store.model(address), m.turn > 0, m.turn > (m.seen ?? 0), seenSent[address] != m.turn else { continue }
            seenSent[address] = m.turn
            let turn = m.turn
            // Here and now, not when the label comes back: a turn that ends
            // on screen goes straight to idle, its row never under Done.
            store.noteSeen(address, turn: turn)
            Task {
                _ = try? await c.call("terminal.label", ["terminal": .string(address), "labels": ["herdr.seen": .string(String(turn))]])
            }
        }
    }

    func sessionClosed(_ session: TerminalSession) {
        scheduleReconcile()
    }

    /// A terminal took the keyboard: its pane becomes the focused one.
    func terminalFocused(_ address: String) {
        guard let space = activeSpace, let tab = activeTab(in: space) else { return }
        let (machine, local) = splitAddress(address)
        guard machine == space.machine, let pane = tab.root.terminals.first(where: { $0.terminal == local })?.pane else { return }
        let key = tabKey(tab, in: space)
        if view.focusedPane[key] != pane {
            view.previousPane[key] = view.focusedPane[key]
            view.focusedPane[key] = pane
        }
    }

    /// Asks the focused pane to take the keyboard.
    func requestFocus() {
        focusTick &+= 1
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            view.save(session: endpoint.session)
        }
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            Drafts.save(drafts, session: endpoint.session)
        }
    }

    func report(_ error: Error) {
        problem = (error as? CoreError)?.message ?? error.localizedDescription
    }
}
