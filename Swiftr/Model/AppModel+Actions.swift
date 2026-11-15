import AppKit
import HerdrKit
import UniformTypeIdentifiers

/// Which way to move between panes.
enum PaneDirection {
    case left, right, up, down
}

extension AppModel {
    // MARK: Selection

    func select(space: SpaceItem) {
        view.activeSpace = space.id
        selectionChanged()
    }

    func select(tab: LayoutTab, in space: SpaceItem) {
        view.activeSpace = space.id
        view.activeTab[space.id] = tab.id
        selectionChanged()
    }

    func focus(pane: String, in tab: LayoutTab, of space: SpaceItem) {
        let key = tabKey(tab, in: space)
        if view.focusedPane[key] != pane {
            view.previousPane[key] = view.focusedPane[key]
            view.focusedPane[key] = pane
        }
        selectionChanged()
    }

    private func selectionChanged() {
        layoutChanged()
        requestFocus()
    }

    func selectTab(at index: Int) {
        guard let space = activeSpace, space.tabs.indices.contains(index) else { return }
        select(tab: space.tabs[index], in: space)
    }

    func selectNeighborTab(_ step: Int) {
        guard let space = activeSpace, let tab = activeTab(in: space), let i = space.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let n = space.tabs.count
        select(tab: space.tabs[((i + step) % n + n) % n], in: space)
    }

    /// The `index`th space the sidebar shows; of all of them when every
    /// machine is collapsed.
    func selectSpace(at index: Int) {
        let all = allSpaces
        let shown = all.filter { !isCollapsed($0.machine) }
        let list = shown.isEmpty ? all : shown
        guard list.indices.contains(index) else { return }
        select(space: list[index])
    }

    /// The next space the sidebar shows, after the active one even when
    /// its machine is collapsed; any space when every machine is.
    func selectNeighborSpace(_ step: Int) {
        let all = allSpaces
        guard !all.isEmpty else { return }
        let n = all.count
        let i = activeSpace.flatMap { a in all.firstIndex { $0.id == a.id } } ?? 0
        let order = (1 ... n).map { all[((i + $0 * step) % n + n) % n] }
        if let next = order.first(where: { !isCollapsed($0.machine) }) ?? order.first { select(space: next) }
    }

    /// Shows the pane of `address`, wherever it is.
    func reveal(_ address: String) {
        let (machine, local) = splitAddress(address)
        for space in spaces(on: machine) {
            for tab in space.tabs {
                if let pane = tab.root.terminals.first(where: { $0.terminal == local })?.pane {
                    view.activeSpace = space.id
                    view.activeTab[space.id] = tab.id
                    let key = tabKey(tab, in: space)
                    if let z = view.zoomedPane[key], z != pane { view.zoomedPane[key] = nil }
                    focus(pane: pane, in: tab, of: space)
                    return
                }
            }
        }
    }

    func moveFocus(_ direction: PaneDirection) {
        guard let space = activeSpace, let tab = activeTab(in: space), let pane = focusedPane(in: tab, of: space) else { return }
        let rects = LayoutGeometry.rects(of: tab.root)
        guard let from = rects[pane] else { return }
        let candidates = rects.filter { id, r in
            guard id != pane else { return false }
            switch direction {
            case .left: return r.maxX <= from.minX + 0.001 && r.maxY > from.minY && r.minY < from.maxY
            case .right: return r.minX >= from.maxX - 0.001 && r.maxY > from.minY && r.minY < from.maxY
            case .up: return r.maxY <= from.minY + 0.001 && r.maxX > from.minX && r.minX < from.maxX
            case .down: return r.minY >= from.maxY - 0.001 && r.maxX > from.minX && r.minX < from.maxX
            }
        }
        let best = candidates.min { a, b in
            func distance(_ r: CGRect) -> CGFloat {
                switch direction {
                case .left: from.minX - r.maxX
                case .right: r.minX - from.maxX
                case .up: from.minY - r.maxY
                case .down: r.minY - from.maxY
                }
            }
            let (da, db) = (distance(a.value), distance(b.value))
            if abs(da - db) > 0.001 { return da < db }
            // Same distance: the one most in line with the focused pane.
            let ca = abs(a.value.midY - from.midY) + abs(a.value.midX - from.midX)
            let cb = abs(b.value.midY - from.midY) + abs(b.value.midX - from.midX)
            return ca < cb
        }
        if let best { focus(pane: best.key, in: tab, of: space) }
    }

    func toggleZoom() {
        guard let space = activeSpace, let tab = activeTab(in: space), let pane = focusedPane(in: tab, of: space) else { return }
        let key = tabKey(tab, in: space)
        view.zoomedPane[key] = view.zoomedPane[key] == nil && tab.root.visibleBlocks.count > 1 ? pane : nil
        selectionChanged()
    }

    // MARK: Making terminals

    /// The display facts new terminals start with.
    private var startDisplay: JSON {
        let theme = prefs.theme
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let (w, h) = CellMetrics.pixels(for: prefs.font, scale: scale)
        return ["fg": .string(RGB(hex: theme.foreground)?.hex ?? "#ffffff"), "bg": .string(RGB(hex: theme.background)?.hex ?? "#000000"),
                "cursor": .string(RGB(hex: theme.cursor ?? theme.foreground)?.hex ?? "#ffffff"), "cell": [JSON(w), JSON(h)]]
    }

    /// Starts the machine's shell for a pane, labeled with where it goes
    /// (docs/labels.md in herdr-app), and returns its address. With
    /// `command`, the shell runs it first (`AgentLauncher.argv`).
    private func runShell(on machine: String, space: String, tab: String, folder: String?, size: (Int, Int)?, command: [String]? = nil) async throws -> String {
        guard let c = connection else { throw CoreError(kind: "lost", message: "Swiftr isn't connected to herdr-core.") }
        let argv = command.map { AgentLauncher.argv($0, on: machine) } ?? []
        var params: JSON = [
            "argv": .array(argv.map { .string($0) }),
            "env": ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "herdr"],
            "labels": ["herdr.space": .string(space), "herdr.tab": .string(tab), "herdr.seen": "0"],
            "keep": true,
            "display": startDisplay,
        ]
        // Unknown folder: home (a remote machine starts there by itself).
        if let folder, !folder.isEmpty {
            params["cwd"] = .string(folder)
        } else if machine.isEmpty {
            params["cwd"] = .string(NSHomeDirectory())
        }
        if !machine.isEmpty { params["on"] = .string(machine) }
        if let (cols, rows) = size, cols > 1, rows > 0 { params["size"] = ["cols": JSON(cols), "rows": JSON(rows)] }
        let r = try await c.call("terminal.run", params, timeout: .seconds(60))
        guard let address = r["address"]?.string else {
            throw CoreError(kind: "protocol", message: "terminal.run gave no address.")
        }
        born[address] = Date()
        busy.insert(address)
        return address
    }

    /// Where a new terminal starts: where the focused one is now.
    private func startFolder(in space: SpaceItem) -> String? {
        if let tab = activeTab(in: space), let pane = focusedPane(in: tab, of: space), let t = tab.root.find(pane)?.terminal,
           let m = store.model(qualify(t, on: space.machine)), !m.currentFolder.isEmpty
        {
            return m.currentFolder
        }
        return space.space.folder.isEmpty ? nil : space.space.folder
    }

    /// The grid of the focused pane, so a new tab starts at its final size.
    private var focusedGrid: (Int, Int)? {
        guard let a = focusedAddress, let s = pool.existing(a), s.view.window != nil else { return nil }
        let d = s.view.terminalDimensions
        return (d.cols, d.rows)
    }

    /// A new tab in the shown space (a new space without one): a shell, or
    /// `agent` in the login shell, named after it, as herdr-app's + menu
    /// starts one.
    func newTab(agent: Programs.Program? = nil) {
        if let agent { prefs.picked(agent: agent.key) }
        newTab(command: agent?.run, name: agent?.name ?? "")
    }

    func newTab(command: [String]?, name: String) {
        guard let space = activeSpace else {
            newSpace(on: "", command: command, tabName: name)
            return
        }
        guard connection != nil, slots[space.machine] != nil else { return }
        let after = activeTab(in: space)?.id
        let folder = startFolder(in: space)
        let size = focusedGrid
        Task {
            do {
                try await addTab(to: space, folder: folder, name: name, after: after, size: size, command: command)
            } catch {
                report(error)
            }
        }
    }

    func newSpace(on machine: String, folder: String? = nil, command: [String]? = nil, tabName: String = "") {
        guard connection != nil, slots[machine] != nil else { return }
        let index = activeSpace.flatMap { a in a.machine == machine ? spaces(on: machine).firstIndex { $0.id == a.id }.map { $0 + 1 } : nil }
        Task {
            do {
                try await addSpace(on: machine, folder: folder, tabName: tabName, at: index, command: command)
            } catch {
                report(error)
            }
        }
    }

    private var notConnected: CoreError {
        CoreError(kind: "lost", message: "Swiftr isn't connected to herdr-core.")
    }

    /// Adds the machine ssh reaches as `target` (`vps`, `can@10.0.0.7`, a
    /// Host from ~/.ssh/config), as `hc machine add` does, then lists it.
    /// The core's errors say why not: unreachable, hc_missing,
    /// incompatible, already_added, name_taken.
    func addMachine(_ target: String) async throws {
        guard let c = connection else { throw notConnected }
        // ssh may take its time to answer, or to give up.
        _ = try await c.call("machine.add", ["target": .string(target)], timeout: .seconds(120))
        await refreshMachines()
    }

    /// Runs `command` in a new tab on this Mac, and shows it: in the shown
    /// space when it is on this Mac, else in this Mac's first space, else
    /// in a new one.
    func newLocalTab(command: [String], name: String) {
        let here = activeSpace.flatMap { $0.machine.isEmpty ? $0 : nil } ?? spaces(on: "").first
        guard let space = here else {
            newSpace(on: "", command: command, tabName: name)
            return
        }
        let after = space.id == activeSpace?.id ? activeTab(in: space)?.id : space.tabs.last?.id
        Task {
            do {
                try await addTab(to: space, folder: nil, name: name, after: after, size: focusedGrid, command: command)
            } catch {
                report(error)
            }
        }
    }

    /// Starts a shell in a new tab of `space`, shows it and returns its address.
    @discardableResult
    func addTab(to space: SpaceItem, folder: String?, name: String = "", after: String?, size: (Int, Int)?, command: [String]? = nil) async throws -> String {
        guard let c = connection, let slot = slots[space.machine] else { throw notConnected }
        let tabID = LayoutDocument.freshID("tb")
        let paneID = LayoutDocument.freshID("p")
        let address = try await runShell(on: space.machine, space: space.space.id, tab: tabID, folder: folder, size: size, command: command)
        defer { busy.remove(address) }
        let local = splitAddress(address).local
        try await slot.update(c) { doc in
            guard doc.pane(showing: local) == nil, doc.space(space.space.id) != nil else { return false }
            return doc.addTab(LayoutDocument.tab(id: tabID, name: name, pane: LayoutDocument.pane(id: paneID, terminal: local)), toSpace: space.space.id, after: after)
        }
        view.activeSpace = space.id
        view.activeTab[space.id] = tabID
        view.focusedPane[Place(space.machine, tabID).key] = paneID
        selectionChanged()
        return address
    }

    /// Starts a shell in a new space on `machine`, shows it and returns its address.
    @discardableResult
    func addSpace(on machine: String, folder: String?, name: String = "", tabName: String = "", at index: Int?, command: [String]? = nil) async throws -> String {
        guard let c = connection, let slot = slots[machine] else { throw notConnected }
        let spaceID = LayoutDocument.freshID("sp")
        let tabID = LayoutDocument.freshID("tb")
        let paneID = LayoutDocument.freshID("p")
        let address = try await runShell(on: machine, space: spaceID, tab: tabID, folder: folder, size: nil, command: command)
        defer { busy.remove(address) }
        let local = splitAddress(address).local
        let start = folder ?? store.model(address)?.cwd ?? (machine.isEmpty ? NSHomeDirectory() : "")
        try await slot.update(c) { doc in
            guard doc.pane(showing: local) == nil else { return false }
            let tab = LayoutDocument.tab(id: tabID, name: tabName, pane: LayoutDocument.pane(id: paneID, terminal: local))
            doc.addSpace(LayoutDocument.space(id: spaceID, name: name, folder: start, tabs: [tab]), at: index)
            return true
        }
        let key = Place(machine, spaceID).key
        view.activeSpace = key
        view.activeTab[key] = tabID
        view.focusedPane[Place(machine, tabID).key] = paneID
        // A new space shows in the sidebar.
        if isCollapsed(machine) { setCollapsed(false, machine: machine) }
        selectionChanged()
        return address
    }

    /// ⇧⌘T: brings back the last closed tab in its space (made again if it
    /// closed too), folder and name, and resumes its agent's session.
    func reopenClosedTab() {
        guard let record = claude.popClosedTab() else {
            NSSound.beep()
            return
        }
        let machine = record.machine ?? ""
        guard connection != nil, machineReady(machine) else {
            claude.push(record)
            problem = machine.isEmpty
                ? "Swiftr isn't connected to herdr-core: the tab stays in the list of closed tabs."
                : "\(title(ofMachine: machine)) is unreachable: the tab stays in the list of closed tabs."
            return
        }
        let size = focusedGrid
        Task {
            let address: String
            do {
                let spaceID = record.space.map { splitAddress($0).local }
                if let spaceID, let space = spaces(on: machine).first(where: { $0.space.id == spaceID }) {
                    address = try await addTab(to: space, folder: record.cwd, name: record.ownTabName ?? "", after: nil, size: size)
                } else {
                    address = try await addSpace(on: machine, folder: record.cwd, name: record.ownSpaceName ?? "", tabName: record.ownTabName ?? "", at: nil)
                }
            } catch {
                claude.push(record)
                report(error)
                return
            }
            guard let session = record.session, let agent = record.agent, let c = connection,
                  let command = await ClaudeWatch.resumeCommand(agent: agent, session: session, machine: record.machine)
            else { return }
            do {
                _ = try await c.call("terminal.send", ["terminal": .string(address), "text": .string(command)], timeout: .seconds(90))
            } catch {
                report(error)
            }
        }
    }

    func split(_ axis: SplitAxis) {
        guard let space = activeSpace, let tab = activeTab(in: space), let pane = focusedPane(in: tab, of: space) else {
            newTab()
            return
        }
        guard let c = connection, let slot = slots[space.machine] else { return }
        let folder = startFolder(in: space)
        let key = tabKey(tab, in: space)
        Task {
            let paneID = LayoutDocument.freshID("p")
            let containerID = LayoutDocument.freshID("s")
            do {
                let address = try await runShell(on: space.machine, space: space.space.id, tab: tab.id, folder: folder, size: nil)
                defer { busy.remove(address) }
                let local = splitAddress(address).local
                try await slot.update(c) { doc in
                    guard doc.pane(showing: local) == nil else { return false }
                    return doc.split(pane, axis: axis, newPane: LayoutDocument.pane(id: paneID, terminal: local), containerID: containerID)
                }
                view.zoomedPane[key] = nil
                view.previousPane[key] = pane
                view.focusedPane[key] = paneID
                selectionChanged()
            } catch {
                report(error)
            }
        }
    }

    // MARK: Closing

    /// Ends a terminal. Already gone counts as done.
    private func kill(_ address: String) async throws {
        guard let c = connection else { throw CoreError(kind: "lost", message: "Swiftr isn't connected to herdr-core.") }
        do {
            _ = try await c.call("terminal.kill", ["terminal": .string(address)])
        } catch let e as CoreError where e.kind == "not_found" || e.kind == "finished" {}
    }

    /// Programs other than a shell still running among `addresses`.
    private func busyPrograms(_ addresses: [String]) -> [String] {
        let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "nu", "tcsh", "csh", "ksh", "-zsh", "-bash", "login"]
        return addresses.compactMap { a in
            guard let m = store.model(a), m.isLive, let p = m.foreground?.program, !p.isEmpty, !shells.contains(p) else { return nil }
            return p
        }
    }

    /// `stopAsking`: the prompt shows a "Don't ask again" box, and runs this
    /// when the person ticks it and closes.
    private func confirmClose(_ what: String, addresses: [String], stopAsking: (() -> Void)? = nil) -> Bool {
        let running = busyPrograms(addresses)
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Close \(what)?"
        let list = Array(Set(running)).sorted().joined(separator: ", ")
        alert.informativeText = running.count == 1
            ? "\(list) is still running. Closing stops it."
            : "\(running.count) programs are still running (\(list)). Closing stops them."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if stopAsking != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
        }
        let closes = alert.runModal() == .alertFirstButtonReturn
        if closes, alert.suppressionButton?.state == .on { stopAsking?() }
        return closes
    }

    /// Closes a pane: its terminal first, then the pane (herdr-app does the same).
    func closePane(_ paneID: String? = nil) {
        guard let space = activeSpace, let tab = activeTab(in: space), let pane = paneID ?? focusedPane(in: tab, of: space),
              let c = connection, let slot = slots[space.machine] else { return }
        let address = tab.root.find(pane)?.terminal.map { qualify($0, on: space.machine) }
        if let address, !confirmClose("this pane", addresses: [address]) { return }
        let key = tabKey(tab, in: space)
        let fallback = view.previousPane[key]
        Task {
            do {
                if let address {
                    busy.insert(address)
                    defer { busy.remove(address) }
                    try await kill(address)
                }
                try await slot.update(c) { doc in doc.removePane(pane) != .notFound }
                if let address { pool.drop(address) }
                if view.focusedPane[key] == pane { view.focusedPane[key] = fallback }
                if view.zoomedPane[key] == pane { view.zoomedPane[key] = nil }
                selectionChanged()
            } catch {
                report(error)
            }
        }
    }

    /// Closes a tab of the shown space, or of `other` (from the sidebar),
    /// without showing it.
    func closeTab(_ tabID: String? = nil, in other: SpaceItem? = nil) {
        // As it is now: the row that asked may be older.
        let space = other.map { o in allSpaces.first { $0.id == o.id } } ?? activeSpace
        // A tab named and gone: nothing, rather than the shown one.
        let tab = tabID.map { id in space?.tabs.first { $0.id == id } } ?? space.flatMap(activeTab(in:))
        guard let space, let tab, let c = connection, let slot = slots[space.machine] else { return }
        let addresses = addresses(of: tab, in: space)
        if prefs.confirmsTabClose,
           !confirmClose("this tab", addresses: addresses, stopAsking: { [prefs] in prefs.confirmsTabClose = false }) { return }
        let index = space.tabs.firstIndex { $0.id == tab.id } ?? 0
        Task {
            do {
                busy.formUnion(addresses)
                defer { busy.subtract(addresses) }
                for a in addresses { try await kill(a) }
                try await slot.update(c) { doc in doc.removeTab(tab.id) != .notFound }
                for a in addresses { pool.drop(a) }
                if view.activeTab[space.id] == tab.id {
                    let rest = space.tabs.filter { $0.id != tab.id }
                    view.activeTab[space.id] = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
                }
                selectionChanged()
            } catch {
                report(error)
            }
        }
    }

    func closeSpace(_ space: SpaceItem) {
        guard let c = connection, let slot = slots[space.machine] else { return }
        let addresses = space.addresses
        if !confirmClose("the space “\(title(of: space))”", addresses: addresses) { return }
        Task {
            do {
                busy.formUnion(addresses)
                defer { busy.subtract(addresses) }
                for a in addresses { try await kill(a) }
                try await slot.update(c) { doc in doc.removeSpace(space.space.id) != nil }
                for a in addresses { pool.drop(a) }
                if view.activeSpace == space.id { view.activeSpace = nil }
                selectionChanged()
            } catch {
                report(error)
            }
        }
    }

    // MARK: Names and sizes

    func rename(_ target: Rename, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .space(let place, let old):
            guard name != old, let c = connection, let slot = slots[place.machine] else { return }
            Task {
                do { try await slot.update(c) { $0.renameSpace(place.id, to: name) } } catch { report(error) }
            }
        case .tab(let place, let old):
            guard name != old, let c = connection, let slot = slots[place.machine] else { return }
            Task {
                do { try await slot.update(c) { $0.renameTab(place.id, to: name) } } catch { report(error) }
            }
        case .machine(let machine, let old):
            // Swiftr's name only: the core's would change the machine's addresses.
            guard name != old else { return }
            let core = coreTitle(ofMachine: machine)
            changeLook(ofMachine: machine) { $0.name = name.isEmpty || name == core ? nil : name }
        }
    }

    /// Gives a machine an icon in Swiftr; nil or its default icon goes back
    /// to the default.
    func setIcon(_ icon: String?, ofMachine machine: String) {
        let standard = defaultIcon(ofMachine: machine)
        changeLook(ofMachine: machine) { $0.icon = icon == standard ? nil : icon }
    }

    /// Hides or shows a machine's spaces in the sidebar: Swiftr only.
    func setCollapsed(_ collapsed: Bool, machine: String) {
        let key = lookKey(ofMachine: machine)
        var keys = view.collapsedMachines ?? []
        if collapsed { keys.insert(key) } else { keys.remove(key) }
        view.collapsedMachines = keys.isEmpty ? nil : keys
    }

    /// Lists a space's tabs under it in the sidebar, or hides them: Swiftr only.
    func setExpanded(_ expanded: Bool, space: SpaceItem) {
        var keys = view.expandedSpaces ?? []
        if expanded { keys.insert(space.id) } else { keys.remove(space.id) }
        view.expandedSpaces = keys.isEmpty ? nil : keys
    }

    /// Hides or shows the agents' rows in the sidebar.
    func setAgentsCollapsed(_ collapsed: Bool) {
        view.agentsCollapsed = collapsed ? true : nil
    }

    /// Hides or shows the spaces' list in the sidebar.
    func setSpacesCollapsed(_ collapsed: Bool) {
        view.spacesCollapsed = collapsed ? true : nil
    }

    /// The agents' share of the sidebar's height, from 0 to 1, once the line
    /// above them is dragged.
    func setAgentsShare(_ share: Double) {
        view.agentsShare = min(max(share, 0), 1)
    }

    /// Hides or shows the rows of one group of agents (`AgentGroup.key`).
    func setFolded(_ folded: Bool, agentGroup key: String) {
        var keys = view.foldedAgentGroups ?? []
        if folded { keys.insert(key) } else { keys.remove(key) }
        view.foldedAgentGroups = keys.isEmpty ? nil : keys
    }

    /// Gives a space an icon in Swiftr; nil goes back to the automatic one.
    func setIcon(_ icon: SpaceIcon?, of space: SpaceItem) {
        var icons = view.spaceIcons ?? [:]
        let old = icons[space.id]
        icons[space.id] = icon
        view.spaceIcons = icons.isEmpty ? nil : icons
        if let file = old?.image, file != icon?.image { IconImages.remove([file]) }
    }

    /// Asks for an image on this Mac and gives a copy of it to the space.
    func chooseIconImage(for space: SpaceItem) {
        defer { requestFocus() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Image for the space “\(title(of: space))”"
        panel.prompt = "Choose"
        if space.machine.isEmpty, !space.space.folder.isEmpty { panel.directoryURL = URL(filePath: space.space.folder) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let name = IconImages.save(from: url) else {
            problem = "Swiftr can't read “\(url.lastPathComponent)” as an image."
            return
        }
        setIcon(SpaceIcon(image: name), of: space)
    }

    private func changeLook(ofMachine machine: String, _ change: (inout MachineLook) -> Void) {
        let key = lookKey(ofMachine: machine)
        var looks = view.machineLooks ?? [:]
        var look = looks[key] ?? MachineLook()
        change(&look)
        looks[key] = look.isEmpty ? nil : look
        view.machineLooks = looks.isEmpty ? nil : looks
    }

    func startRenamingTab() {
        guard let space = activeSpace, let tab = activeTab(in: space) else { return }
        renaming = .tab(Place(space.machine, tab.id), tab.name)
    }

    func startRenamingSpace() {
        guard let space = activeSpace else { return }
        renaming = .space(space.place, space.space.name)
    }

    /// A divider was dragged: the new shares of a row's or column's children.
    func setWeights(_ weights: [String: Double], container: String, on machine: String) {
        guard let c = connection, let slot = slots[machine] else { return }
        Task {
            do { try await slot.update(c) { $0.setWeights(weights, inContainer: container) } } catch { report(error) }
        }
    }

    // MARK: Order

    /// Puts a space at `index` among its machine's spaces, for herdr-app too.
    func moveSpace(_ space: SpaceItem, to index: Int) {
        guard let c = connection, let slot = slots[space.machine] else { return }
        let shown = spaces(on: space.machine).map(\.space.id)
        guard let order = moved(space.space.id, in: shown, to: index) else { return }
        let token = nextMove()
        pendingSpaces[space.machine] = PendingOrder(ids: order.ids, token: token)
        Task {
            do { try await slot.update(c) { $0.moveSpace(space.space.id, to: order.index) } } catch { report(error) }
            if pendingSpaces[space.machine]?.token == token { pendingSpaces[space.machine] = nil }
        }
    }

    /// Puts a tab at `index` in its space, for herdr-app too.
    func moveTab(_ tabID: String, in space: SpaceItem, to index: Int) {
        guard let c = connection, let slot = slots[space.machine] else { return }
        let shown = (spaces(on: space.machine).first { $0.id == space.id } ?? space).tabs.map(\.id)
        guard let order = moved(tabID, in: shown, to: index) else { return }
        let token = nextMove()
        pendingTabs[space.id] = PendingOrder(ids: order.ids, token: token)
        Task {
            do { try await slot.update(c) { $0.moveTab(tabID, to: order.index) } } catch { report(error) }
            if pendingTabs[space.id]?.token == token { pendingTabs[space.id] = nil }
        }
    }

    /// Puts a machine at `index` in the sidebar: Swiftr's order only.
    func moveMachine(_ name: String, to index: Int) {
        let names = machineNames
        guard let order = moved(name, in: names, to: index) else { return }
        // Machines gone for now keep their place for when they come back.
        view.machineOrder = order.ids + (view.machineOrder ?? []).filter { !names.contains($0) }
    }

    /// `ids` once `id` moved to `index` (kept inside the list), and that
    /// index; nil when it doesn't move.
    private func moved(_ id: String, in ids: [String], to index: Int) -> (ids: [String], index: Int)? {
        guard let from = ids.firstIndex(of: id) else { return nil }
        let to = max(0, min(index, ids.count - 1))
        guard to != from else { return nil }
        var out = ids
        out.insert(out.remove(at: from), at: to)
        return (out, to)
    }

    private func nextMove() -> Int {
        lastMove += 1
        return lastMove
    }
}

/// Where panes sit in their tab, in a unit square.
enum LayoutGeometry {
    static func rects(of root: LayoutNode) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        place(root, in: CGRect(x: 0, y: 0, width: 1, height: 1), into: &out)
        return out
    }

    private static func place(_ node: LayoutNode, in rect: CGRect, into out: inout [String: CGRect]) {
        if node.hidden { return }
        switch node {
        case .block(let id, _, _, _):
            out[id] = rect
        case .stack(_, let children, let active, _, _):
            if let shown = children.first(where: { $0.id == active }) ?? children.first { place(shown, in: rect, into: &out) }
        case .split(_, let axis, let children, _, _):
            let shown = children.filter { !$0.hidden }
            let weights = shown.map { child -> Double in
                if case .weight(let w) = child.size { return max(w, 0.0001) }
                return 1
            }
            let total = weights.reduce(0, +)
            var offset = 0.0
            for (child, w) in zip(shown, weights) {
                let share = w / total
                let r = axis == .row
                    ? CGRect(x: rect.minX + rect.width * offset, y: rect.minY, width: rect.width * share, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + rect.height * offset, width: rect.width, height: rect.height * share)
                place(child, in: r, into: &out)
                offset += share
            }
        }
    }
}
