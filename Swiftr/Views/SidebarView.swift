import AppKit
import HerdrKit
import SwiftUI

/// The sidebar: the spaces, by machine, over the agents (or under them, as
/// the settings say), each list scrolling on its own, as in herdr-app. The
/// line between them moves: its place is kept as the agents' share.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Rises at each click on a row, so the lists show the model's selection
    /// again even when the click changed nothing (the shown space, the
    /// focused agent): otherwise the other selected row stays unmarked.
    @State private var clicks = 0
    /// The rows a click marks, shown until the model shows them too.
    @State private var clicked: Set<String>?
    /// While the line between the lists is dragged: the agents' height when
    /// it was pressed, and now.
    @State private var resizeFrom: CGFloat?
    @State private var resizedTo: CGFloat?

    /// The least height each list keeps, as in herdr-app.
    static let minHeight: CGFloat = 90
    /// The band between the lists: a line in its middle, and room to grab it.
    static let dividerBand: CGFloat = 7

    var body: some View {
        let _ = clicks
        let marks = clicked ?? Self.selectionKeys(model)
        let groups = model.agentGroups
        let onTop = model.prefs.agentsPlace == .top
        // Both folded, each title keeps its end of the sidebar: the room
        // between them stays empty, over the line.
        let bothFolded = model.spacesCollapsed && model.agentsCollapsed
        GeometryReader { box in
            let total = box.size.height
            let height = agentsHeight(in: total)
            VStack(spacing: 0) {
                if onTop, !groups.isEmpty {
                    agentsPane(groups, height: height)
                    if bothFolded { Spacer(minLength: 0) }
                    divider(total: total, height: height, onTop: true)
                }
                spacesPane
                if !onTop, !groups.isEmpty {
                    if bothFolded { Spacer(minLength: 0) }
                    divider(total: total, height: height, onTop: false)
                    agentsPane(groups, height: height)
                }
                if groups.isEmpty, model.spacesCollapsed { Spacer(minLength: 0) }
            }
        }
        .environment(\.sidebarMarks, marks)
        // Over the sidebar's glass: one surface with the card's frame.
        .background { SidebarMaterial().ignoresSafeArea() }
        // Done rows don't move under the pointer: they go once it's gone.
        .onHover { Self.pointer($0, model: model) }
    }

    /// The agents' list and title: the share dragged, half at first, but
    /// never less than either list's least.
    private func agentsHeight(in total: CGFloat) -> CGFloat {
        Self.clamp(resizedTo ?? total * CGFloat(model.view.agentsShare ?? 0.5), in: total)
    }

    static func clamp(_ height: CGFloat, in total: CGFloat) -> CGFloat {
        min(max(height, minHeight), max(minHeight, total - dividerBand - minHeight))
    }

    /// The line between the lists. Dragged, it moves the agents' edge; with
    /// either list folded, it only parts them.
    private func divider(total: CGFloat, height: CGFloat, onTop: Bool) -> some View {
        Divider()
            .frame(height: Self.dividerBand)
            .overlay {
                if !model.agentsCollapsed, !model.spacesCollapsed {
                    SplitHandle { down in
                        let from = resizeFrom ?? height
                        resizeFrom = from
                        resizedTo = Self.clamp(from + (onTop ? down : -down), in: total)
                    } ended: {
                        if let to = resizedTo, total > 0 { model.setAgentsShare(Double(to / total)) }
                        resizeFrom = nil
                        resizedTo = nil
                    }
                }
            }
    }

    /// Each machine under its header, its spaces under it; over them, a
    /// title that folds them all to itself, as the agents' does.
    private var spacesPane: some View {
        let collapsed = model.spacesCollapsed
        return VStack(spacing: 0) {
            ListTitle(title: "Spaces") {
                // Collapsed, the title tells what the spaces' rows would.
                if collapsed {
                    AttentionDot(attention: model.attention(of: model.allSpaces.flatMap(\.addresses)))
                }
                // Spaced as a machine's + and chevron, which sit under these.
                HStack(spacing: 8) {
                    addMachineButton
                    FoldChevron(collapsed: collapsed, title: "spaces") {
                        Self.foldSpaces(!collapsed, model: model)
                    }
                }
            }
            .debugMark("spaces-title")
            if !collapsed { spacesList }
        }
    }

    /// The + on the title adds a machine; each machine's header has its own
    /// + for a new space there.
    private var addMachineButton: some View {
        Button {
            model.addingMachine = MachineAdder()
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Add a machine you reach with ssh")
        .disabled(model.link != .connected)
    }

    private var spacesList: some View {
        List(selection: selection(agents: false)) {
            ForEach(model.machineItems) { machine in
                Section {
                    // Collapsed, a machine shows its header only.
                    if !model.isCollapsed(machine.name) {
                        ForEach(Array(machine.spaces.enumerated()), id: \.element.id) { index, space in
                            // Open, a space lists its tabs under it, as a folder its files.
                            DisclosureGroup(isExpanded: expansion(of: space)) {
                                ForEach(Array(space.tabs.enumerated()), id: \.element.id) { i, tab in
                                    TabRow(space: space, tab: tab, index: i)
                                        .tag(Self.tabKey(tab, in: space))
                                        .listRowBackground(SelectionPill(key: Self.tabKey(tab, in: space)))
                                }
                                // Within its space only, as herdr moves tabs.
                                .onMove { from, to in
                                    guard from.count == 1, let i = from.first, space.tabs.indices.contains(i) else { return }
                                    let tab = space.tabs[i]
                                    DispatchQueue.main.async { model.moveTab(tab.id, in: space, to: landing(from: i, before: to)) }
                                }
                            } label: {
                                SpaceRow(space: space, index: index, count: machine.spaces.count)
                                    .tag(space.id)
                                    .listRowBackground(SelectionPill(key: space.id))
                            }
                        }
                        // Within its machine only: a space's terminals stay on it.
                        .onMove { from, to in
                            guard from.count == 1, let i = from.first, machine.spaces.indices.contains(i) else { return }
                            let space = machine.spaces[i]
                            // After the list's own update, like the selection.
                            DispatchQueue.main.async { model.moveSpace(space, to: landing(from: i, before: to)) }
                        }
                        if !machine.isConnected && machine.name != "" {
                            Text(machineNote(machine))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let error = machine.error, machine.spaces.isEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    MachineHeader(machine: machine)
                }
            }
        }
        .listStyle(.sidebar)
        .background(SidebarTable(list: "spaces"))
    }

    /// A group per state, under its own header, which folds it; over them,
    /// a title that folds them all to itself.
    private func agentsPane(_ groups: [AgentGroup], height: CGFloat) -> some View {
        let collapsed = model.agentsCollapsed
        return VStack(spacing: 0) {
            ListTitle(title: "Agents") {
                // Collapsed, the title tells what the agents' rows would:
                // the most urgent state, a kept agent's own.
                if collapsed {
                    AttentionDot(attention: groups.flatMap(\.agents).map(\.attention).max() ?? .none)
                }
                FoldChevron(collapsed: collapsed, title: "agents") {
                    Self.foldAgents(!collapsed, model: model)
                }
            }
            .debugMark("agents-title")
            if !collapsed {
                List(selection: selection(agents: true)) {
                    ForEach(groups) { group in
                        let folded = model.isFolded(group)
                        // A section, so its header takes a header's height,
                        // not an agent's two lines: the first sits close
                        // under the title, as a machine under "Spaces".
                        Section {
                            if !folded {
                                ForEach(group.agents) { agent in
                                    AgentRow(agent: agent)
                                        .tag(Self.agentKey(agent.address))
                                        .listRowBackground(SelectionPill(key: Self.agentKey(agent.address)))
                                }
                            }
                        } header: {
                            AgentGroupHeader(group: group, folded: folded) {
                                Self.foldGroup(group.key, !folded, model: model)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .background(SidebarTable(list: "agents"))
            }
        }
        // Collapsed, its title alone: the spaces take the rest. With the
        // spaces collapsed, the agents do.
        .frame(height: collapsed || model.spacesCollapsed ? nil : height)
    }

    /// The pointer came onto the sidebar or left it. On it, the agents done
    /// keep their row (`AppModel.keepDoneAgents`); off it, they slide to their group.
    static func pointer(_ inside: Bool, model: AppModel) {
        model.pointerOnSidebar = inside
        if inside {
            model.keepDoneAgents()
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { model.releaseDoneAgents() }
        }
    }

    /// Hides or shows the agents' rows: they slide while the chevron turns.
    static func foldAgents(_ collapsed: Bool, model: AppModel) {
        withAnimation(FoldChevron.animation) { model.setAgentsCollapsed(collapsed) }
    }

    /// The same for the spaces' list, every machine in it.
    static func foldSpaces(_ collapsed: Bool, model: AppModel) {
        withAnimation(FoldChevron.animation) { model.setSpacesCollapsed(collapsed) }
    }

    /// The same for one group of agents (`AgentGroup.key`).
    static func foldGroup(_ key: String, _ folded: Bool, model: AppModel) {
        withAnimation(FoldChevron.animation) { model.setFolded(folded, agentGroup: key) }
    }

    /// An agent's row in the selection.
    static func agentKey(_ address: String) -> String {
        "agent:" + address
    }

    /// A tab's row in the selection.
    static func tabKey(_ tab: LayoutTab, in space: SpaceItem) -> String {
        "tab:" + Place(space.machine, tab.id).key
    }

    /// The tab a `tabKey` stands for, and its space.
    static func tabPlace(_ key: String, _ model: AppModel) -> TerminalPlace? {
        guard key.hasPrefix("tab:") else { return nil }
        let (machine, local) = splitAddress(String(key.dropFirst("tab:".count)))
        return model.place(ofTab: local, on: machine)
    }

    /// A space's triangle: AppKit slides its tabs' rows in and out.
    private func expansion(of space: SpaceItem) -> Binding<Bool> {
        Binding(get: { model.isExpanded(space) }, set: { model.setExpanded($0, space: space) })
    }

    /// The rows shown as selected: the space on screen, or the tab it shows
    /// when its tabs are listed, and, when the focused pane holds an agent,
    /// that agent, as herdr-app marks both.
    static func selectionKeys(_ model: AppModel) -> Set<String> {
        guard let space = model.activeSpace else { return [] }
        return selectionKeys(space, tab: model.activeTab(in: space), focused: model.focusedAddress, model)
    }

    /// The same once a click on the row `key` is done: an agent with its
    /// space or tab, a space or tab with its focused agent.
    static func selectionKeys(after key: String, _ model: AppModel) -> Set<String>? {
        if key.hasPrefix("agent:") {
            let address = String(key.dropFirst("agent:".count))
            return model.place(of: address).map { selectionKeys($0.space, tab: $0.tab, focused: address, model) }
        }
        if let place = tabPlace(key, model) {
            return selectionKeys(place.space, tab: place.tab, focused: model.focusedAddress(in: place.tab, of: place.space), model)
        }
        return model.allSpaces.first { $0.id == key }.map { selectionKeys($0, tab: model.activeTab(in: $0), focused: model.focusedAddress(in: $0), model) }
    }

    private static func selectionKeys(_ space: SpaceItem, tab: LayoutTab?, focused: String?, _ model: AppModel) -> Set<String> {
        // Its tabs listed, a space marks the one it shows, as a folder
        // marks the file open rather than itself.
        let tabRow = model.isExpanded(space) ? tab.map { tabKey($0, in: space) } : nil
        var keys: Set<String> = [tabRow ?? space.id]
        if let focused, model.store.model(focused)?.isAgent == true { keys.insert(agentKey(focused)) }
        return keys
    }

    /// What one list marks: the agents' rows, or the spaces' and tabs'.
    private func selection(agents: Bool) -> Binding<Set<String>> {
        Binding(
            get: { (clicked ?? Self.selectionKeys(model)).filter { $0.hasPrefix("agent:") == agents } },
            set: { keys in
                // A click: the row not selected before, else the one row left.
                let added = keys.subtracting(Self.selectionKeys(model))
                let key = added.count == 1 ? added.first : keys.count == 1 ? keys.first : nil
                // AppKit marks the clicked row alone: the rows the click marks,
                // in both lists, show at once, or the one marked with it blinks off.
                if let key, let after = Self.selectionKeys(after: key, model), after != keys { clicked = after }
                // After the list's own update: changing what it shows from
                // inside it is a reentrant table delegate for AppKit.
                DispatchQueue.main.async {
                    // The agent shown next is seen: its row stays where it was clicked.
                    if model.pointerOnSidebar { model.keepDoneAgents() }
                    if let key, key.hasPrefix("agent:") {
                        model.reveal(String(key.dropFirst("agent:".count)))
                    } else if let place = key.flatMap({ Self.tabPlace($0, model) }) {
                        model.select(tab: place.tab, in: place.space)
                    } else if let key, key != model.activeSpace?.id, let space = model.allSpaces.first(where: { $0.id == key }) {
                        model.select(space: space)
                    }
                    clicked = nil
                    clicks &+= 1
                }
            }
        )
    }

    private func machineNote(_ machine: MachineItem) -> String {
        switch machine.state {
        case "connecting": "Connecting…"
        case "needs_login": "Login needed: hc machine login \(machine.name)"
        default: machine.why.map { "Unreachable: \($0)" } ?? "Unreachable"
        }
    }
}

/// Sets up a sidebar list's table, which SwiftUI doesn't show.
///
/// Its rows take the table's fixed height instead of measuring each one. With
/// measured rows, an update that adds rows in two sections makes AppKit
/// re-enter its own row-height cache (NSTableRowHeightData, macOS 26) and log
/// "reentrant operation in its NSTableView delegate"; a plain SwiftUI sidebar
/// list does the same. Only when that height holds an agent's two lines.
///
/// It never takes the keyboard: a click on a row shows a pane, which takes it
/// at once. Meanwhile, the table would mark its rows in the accent color, the
/// shown space's row too, which would flash.
struct SidebarTable: NSViewRepresentable {
    /// Which list: "spaces" or "agents", for DebugHooks.
    let list: String

    func makeNSView(context: Context) -> Finder {
        let view = Finder()
        view.list = list
        return view
    }

    func updateNSView(_ view: Finder, context: Context) { view.apply() }

    final class Finder: NSView {
        var list = ""
        private weak var table: NSOutlineView?

        #if DEBUG
        /// Each list's table, for DebugHooks.
        static let tables = NSMapTable<NSString, NSOutlineView>.strongToWeakObjects()
        #endif

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The list makes its table after this view joins the window.
            if window != nil { DispatchQueue.main.async { [weak self] in self?.apply(tries: 20) } }
        }

        /// `tries`: look again a little later while the table isn't there yet.
        func apply(tries: Int = 0) {
            if table?.window == nil { table = findTable() }
            guard let table else {
                if tries > 0, window != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.apply(tries: tries - 1) }
                }
                return
            }
            #if DEBUG
            Self.tables.setObject(table, forKey: list as NSString)
            #endif
            // The sidebar icon size sets this height: small rows keep measuring.
            let fixed = table.rowHeight >= 30
            if table.usesAutomaticRowHeights == fixed { table.usesAutomaticRowHeights = !fixed }
            if !table.refusesFirstResponder { table.refusesFirstResponder = true }
            // The rows draw their own mark, a pill (`SelectionPill`).
            if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
        }

        /// The list's table: the nearest one around this view whose list has
        /// this view's frame, which SwiftUI gives it. The sidebar has two
        /// lists: while one comes in, the other still covers its place, so
        /// a frame alike, not one that holds this view, tells them apart.
        private func findTable() -> NSOutlineView? {
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let mine = convert(bounds, to: nil)
            func alike(_ t: NSOutlineView) -> Bool {
                let f = Self.frame(of: t)
                return abs(f.minX - mine.minX) < 1 && abs(f.maxX - mine.maxX) < 1
                    && abs(f.minY - mine.minY) < 1 && abs(f.maxY - mine.maxY) < 1
            }
            var view = superview
            while let v = view {
                if let t = Self.tables(in: v).first(where: alike) { return t }
                view = v.superview
            }
            return nil
        }

        /// Where a table's list sits in the window: its scroll view's frame.
        static func frame(of table: NSOutlineView) -> NSRect {
            let box: NSView = table.enclosingScrollView ?? table
            return box.convert(box.bounds, to: nil)
        }

        private static func tables(in view: NSView) -> [NSOutlineView] {
            if let t = view as? NSOutlineView { return [t] }
            return view.subviews.flatMap(tables(in:))
        }
    }
}

extension EnvironmentValues {
    /// The sidebar's rows shown as selected (`SidebarView.selectionKeys`).
    @Entry var sidebarMarks: Set<String> = []
}

/// Under a sidebar row shown as selected: a pill raised off the sidebar,
/// lit along its inner edge, ringed by a hairline. AppKit's own mark, a
/// rounded box, is off (`SidebarTable`).
struct SelectionPill: View {
    /// The row's key in the selection.
    let key: String
    @Environment(\.sidebarMarks) private var marks
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Capsule()
            .fill(Color.white.opacity(dark ? 0.12 : 0.6))
            .shadow(color: .black.opacity(dark ? 0.25 : 0.07), radius: 1.5, y: 1)
            .overlay { Capsule().strokeBorder(Color.white.opacity(dark ? 0.1 : 0.9), lineWidth: 1) }
            .overlay { Capsule().stroke(Color.black.opacity(dark ? 0.3 : 0.1), lineWidth: 0.5).padding(-0.25) }
            // As far from the card as from the window's edge: the sidebar's
            // own edge doesn't show (`SidebarMaterial`).
            .padding(.leading, 10)
            .padding(.trailing, 10 - Card.margin)
            .padding(.vertical, 1)
            .opacity(marks.contains(key) ? 1 : 0)
    }
}

/// The title over one of the sidebar's lists, as herdr-app heads its spaces
/// and its agents, in the lists' own header font.
struct ListTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer(minLength: 0)
            trailing
        }
        .font(.subheadline.weight(.semibold))
        // The lists' headers' grey: in the sidebar, their secondary looks dimmer.
        .foregroundStyle(.tertiary)
        .padding(.leading, 14)
        .padding(.trailing, 2)
        .frame(height: 28)
    }
}

/// The grip on the line between the sidebar's lists: the up-down pointer,
/// and drags, even in a window in the background (`acceptsFirstMouse`).
struct SplitHandle: NSViewRepresentable {
    /// How far the pointer went down since it was pressed, in points.
    let moved: (CGFloat) -> Void
    let ended: () -> Void

    func makeNSView(context: Context) -> SplitHandleView {
        let view = SplitHandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SplitHandleView, context: Context) {
        view.moved = moved
        view.ended = ended
    }
}

final class SplitHandleView: NSView {
    var moved: (CGFloat) -> Void = { _ in }
    var ended: () -> Void = {}
    /// Where the mouse went down, in the window, until it goes up.
    private var downAt: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .rowResize)
    }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        // The pointer runs ahead of the line: it keeps its look off the band.
        NSCursor.rowResize.set()
        // Window points go up.
        moved(start.y - event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard downAt != nil else { return }
        downAt = nil
        ended()
        window?.invalidateCursorRects(for: self)
    }
}

extension View {
    /// Debug builds: a view under this one that DebugHooks finds by its name.
    @ViewBuilder func debugMark(_ name: String) -> some View {
        #if DEBUG
        background(DebugMark(name: name))
        #else
        self
        #endif
    }
}

#if DEBUG
/// What `debugMark` puts under a view: found by its name, it gives that
/// view's frame. It takes no clicks.
struct DebugMark: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> DebugMarkView {
        let view = DebugMarkView()
        view.name = name
        return view
    }

    func updateNSView(_ view: DebugMarkView, context: Context) {
        view.name = name
    }
}

final class DebugMarkView: NSView {
    var name = ""

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif

struct MachineHeader: View {
    @Environment(AppModel.self) private var model
    let machine: MachineItem

    var body: some View {
        let collapsed = model.isCollapsed(machine.name)
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: machine.icon)
                Text(machine.title)
                Circle()
                    .fill(machine.isConnected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .overlay {
                MachineGrip(name: machine.name, title: machine.title, icon: machine.icon, take: take, entries: entries, click: click)
            }
            // Collapsed, the header tells what its spaces' rows would.
            if collapsed {
                AttentionDot(attention: model.attention(of: machine.spaces.flatMap(\.addresses)))
            }
            HStack(spacing: 8) {
                if machine.isConnected {
                    Button {
                        model.newSpace(on: machine.name)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Space on \(machine.title)")
                }
                FoldChevron(collapsed: collapsed, title: machine.title) {
                    Self.fold(machine.name, !collapsed, model: model)
                }
            }
        }
    }

    /// Hides or shows a machine's spaces: they slide while the chevron turns.
    static func fold(_ machine: String, _ collapsed: Bool, model: AppModel) {
        withAnimation(FoldChevron.animation) { model.setCollapsed(collapsed, machine: machine) }
    }

    /// The machine dragged over this header takes its place.
    private func take(_ dragged: String) {
        // After AppKit's drag callback, like the other changes to the list.
        DispatchQueue.main.async {
            guard let index = model.machineNames.firstIndex(of: machine.name) else { return }
            withAnimation(.easeOut(duration: 0.2)) { model.moveMachine(dragged, to: index) }
        }
    }

    /// The header's menu, worked out when it opens.
    private func entries() -> [MenuEntry] {
        Self.entries(for: machine, model: model)
    }

    /// A click on the machine's name folds or opens it, as its chevron does.
    private func click() {
        Self.fold(machine.name, !model.isCollapsed(machine.name), model: model)
    }

    static func entries(for machine: MachineItem, model: AppModel) -> [MenuEntry] {
        let (name, title, icon) = (machine.name, machine.title, machine.icon)
        let collapsed = model.isCollapsed(name)
        var out: [MenuEntry] = [
            .action("Rename…") { model.renaming = .machine(name, title) },
            .submenu("Icon", image: icon, MachineIcons.entries(checked: icon) { model.setIcon($0, ofMachine: name) }),
            .divider,
            .action(collapsed ? "Expand" : "Collapse") { fold(name, !collapsed, model: model) },
        ]
        let names = model.machineNames
        guard let index = names.firstIndex(of: name), names.count > 1 else { return out }
        func step(_ title: String, to place: Int) -> MenuEntry {
            .action(title) {
                withAnimation(.easeOut(duration: 0.2)) { model.moveMachine(name, to: place) }
            }
        }
        if index > 0 { out.append(step("Move Up", to: index - 1)) }
        if index < names.count - 1 { out.append(step("Move Down", to: index + 1)) }
        return out
    }
}

/// The chevron that ends a sidebar header: › folded, ⌄ open.
struct FoldChevron: View {
    let collapsed: Bool
    /// What it folds, for its help tag.
    let title: String
    let toggle: () -> Void

    /// The curve and length AppKit slides the list's rows with, so the
    /// chevron turns with them.
    static let animation = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.25)

    var body: some View {
        Button(action: toggle) {
            FoldMark(collapsed: collapsed)
        }
        .buttonStyle(.borderless)
        .help(collapsed ? "Expand \(title)" : "Collapse \(title)")
        // It ends where the counts at the end of the rows end.
        .padding(.trailing, 14)
    }
}

/// The chevron's arrow: › folded, ⌄ open.
struct FoldMark: View {
    let collapsed: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .rotationEffect(.degrees(collapsed ? 0 : 90))
            // Square, so the turn keeps it in place.
            .frame(width: 12, height: 12)
    }
}

/// Icons a machine can take, in groups: SF Symbols and their names.
enum MachineIcons {
    static let groups: [[(symbol: String, title: String)]] = [
        [("laptopcomputer", "Laptop"), ("desktopcomputer", "Desktop"), ("macmini", "Mac mini"),
         ("macstudio", "Mac Studio"), ("macpro.gen3", "Mac Pro"), ("pc", "PC"), ("display", "Display")],
        [("server.rack", "Server"), ("cloud", "Cloud"), ("globe", "Internet"), ("network", "Network"),
         ("cpu", "Processor"), ("externaldrive", "Disk"), ("shippingbox", "Container"), ("cube", "Virtual Machine")],
        [("terminal", "Terminal"), ("hammer", "Tools"), ("flask", "Testing"), ("house", "Home"),
         ("building.2", "Office"), ("gamecontroller", "Games")],
    ]

    /// The icon menu, with a check on `current`; `pick` gets the symbol chosen.
    static func entries(checked current: String, pick: @escaping (String) -> Void) -> [MenuEntry] {
        groups.enumerated().flatMap { index, group -> [MenuEntry] in
            let items = group.map { icon in
                MenuEntry.action(icon.title, image: icon.symbol, checked: icon.symbol == current) { pick(icon.symbol) }
            }
            return index == 0 ? items : [.divider] + items
        }
    }
}

/// A line of a menu made in AppKit.
enum MenuEntry {
    /// `image`: an SF Symbol, shown even on macOS 27, which hides menu images
    /// unless told otherwise. A submenu's image follows the system.
    case action(String, image: String? = nil, checked: Bool = false, run: () -> Void)
    case submenu(String, image: String? = nil, [MenuEntry])
    case divider

    static func menu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        for entry in entries { menu.addItem(entry.item) }
        return menu
    }

    private var item: NSMenuItem {
        switch self {
        case .action(let title, let image, let checked, let run):
            let action = MenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
            item.target = action
            // The item holds its target weakly.
            item.representedObject = action
            item.image = image.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            if image != nil, #available(macOS 27, *) { item.preferredImageVisibility = .visible }
            item.state = checked ? .on : .off
            return item
        case .submenu(let title, let image, let entries):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = image.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            item.submenu = Self.menu(entries)
            return item
        case .divider:
            return .separator()
        }
    }
}

/// An AppKit view over a machine's header: a click folds or opens the
/// machine, dragging it onto another machine's header moves it there, and a
/// right click opens its menu. The sidebar's table takes the mouse before
/// SwiftUI's drag and menu on a section header.
private struct MachineGrip: NSViewRepresentable {
    let name: String
    let title: String
    let icon: String
    let take: (String) -> Void
    let entries: () -> [MenuEntry]
    let click: () -> Void

    func makeNSView(context: Context) -> MachineGripView {
        let view = MachineGripView()
        view.toolTip = "Click to collapse or expand; drag onto another machine to reorder; right-click to rename it or change its icon"
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MachineGripView, context: Context) {
        view.name = name
        view.title = title
        view.icon = icon
        view.take = take
        view.entries = entries
        view.click = click
    }
}

final class MachineGripView: NSView {
    var name = ""
    var title = ""
    var icon = ""
    var take: (String) -> Void = { _ in }
    var entries: () -> [MenuEntry] = { [] }
    var click: () -> Void = {}
    /// Where the mouse went down, until it moves far enough to drag.
    private var downAt: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([MachineDrag.type])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([MachineDrag.type])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        downAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: MachineDrag.pasteboardItem(for: name))
        let image = dragImage()
        item.setDraggingFrame(NSRect(origin: .zero, size: image.size), contents: image)
        MachineDrag.shared.name = name
        let session = beginDraggingSession(with: [item], event: event, source: MachineDrag.shared)
        // The order changes while dragging: nothing to slide back to.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        // Let go where it was pressed: a click, not a drag, which forgets
        // where it started.
        if downAt != nil { click() }
        downAt = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let entries = entries()
        return entries.isEmpty ? nil : MenuEntry.menu(entries)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dragged = MachineDrag.shared.dragged(in: sender) else { return [] }
        if dragged != name { take(dragged) }
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        MachineDrag.shared.dragged(in: sender) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // The machine already took its place on the way.
        MachineDrag.shared.dragged(in: sender) != nil
    }

    /// The machine's icon and name on a chip, drawn now for the header's
    /// light or dark look.
    private func dragImage() -> NSImage {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let symbol = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .semibold))
        let iconSize = symbol?.size ?? .zero
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let textSize = text.size()
        let pad: CGFloat = 8, gap: CGFloat = 6
        let size = NSSize(
            width: ceil(min(max(bounds.width, 60), pad + iconSize.width + gap + textSize.width + pad)),
            height: ceil(max(bounds.height, 22))
        )
        let scale = window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return NSImage(size: size) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let chip = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.windowBackgroundColor.setFill()
            chip.fill()
            NSColor.separatorColor.setStroke()
            chip.stroke()
            var x = pad
            if let symbol {
                // A symbol draws black unless given its color.
                let color = NSColor(cgColor: NSColor.secondaryLabelColor.cgColor) ?? .gray
                let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [color])) ?? symbol
                tinted.draw(in: NSRect(x: x, y: (size.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
                x += iconSize.width + gap
            }
            text.draw(at: NSPoint(x: x, y: (size.height - textSize.height) / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

/// The source of every machine drag, and the machine on its way. One object
/// for all of them: a header may leave the window while the order changes.
final class MachineDrag: NSObject, NSDraggingSource {
    static let shared = MachineDrag()
    static let type = NSPasteboard.PasteboardType("com.melvinsiadous.swiftr.machine")

    var name: String?

    static func pasteboardItem(for name: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        // Never empty, even for this Mac ("").
        item.setString("machine:" + name, forType: type)
        return item
    }

    /// The machine dragged, if `info` is one of these drags.
    func dragged(in info: NSDraggingInfo) -> String? {
        (info.draggingSource as AnyObject?) === self ? name : nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        name = nil
    }
}

/// A menu item's action as a closure.
private final class MenuAction: NSObject {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func fire(_ sender: Any?) {
        run()
    }
}

struct SpaceRow: View {
    @Environment(AppModel.self) private var model
    let space: SpaceItem
    /// Its place among its machine's spaces.
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(model.title(of: space))
            } icon: {
                SpaceIconView(look: model.look(of: space))
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            // Closed, the row tells what its tabs' rows would.
            if !model.isExpanded(space) {
                AttentionDot(attention: model.attention(of: space.addresses))
                if space.tabs.count > 1 {
                    Text("\(space.tabs.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: model.logoFolders(of: space)) { model.findLogos(for: space) }
        .contextMenu {
            Button("New Tab") {
                model.select(space: space)
                model.newTab()
            }
            Button("Rename…") {
                model.renaming = .space(space.place, space.space.name)
            }
            Menu("Icon") { iconMenu }
            if index > 0 {
                Button("Move Up") { model.moveSpace(space, to: index - 1) }
            }
            if index < count - 1 {
                Button("Move Down") { model.moveSpace(space, to: index + 1) }
            }
            Divider()
            Button("Close Space", role: .destructive) {
                model.closeSpace(space)
            }
        }
    }

    /// The automatic icon, the logos in the space's folders, the folder,
    /// the other icons, or an image from disk; a check on the current one.
    @ViewBuilder private var iconMenu: some View {
        let current = model.view.spaceIcons?[space.id]
        Group {
            Toggle(isOn: Binding(get: { current == nil }, set: { _ in model.setIcon(nil, of: space) })) {
                Label("Automatic", systemImage: "wand.and.stars")
            }
            ForEach(model.logoChoices(of: space)) { logo in
                Toggle(isOn: Binding(get: { current?.folder == logo.folder }, set: { _ in
                    model.setIcon(SpaceIcon(folder: logo.folder), of: space)
                })) {
                    Label {
                        Text("Logo from \(folderName(logo.folder))")
                    } icon: {
                        Image(nsImage: logo.image)
                    }
                }
            }
            iconChoice("Folder", symbol: SpaceIcons.standard, checked: current?.symbol == SpaceIcons.standard)
            ForEach(Array(SpaceIcons.groups.enumerated()), id: \.offset) { _, group in
                Divider()
                ForEach(group, id: \.symbol) { icon in
                    iconChoice(icon.title, symbol: icon.symbol, checked: current?.symbol == icon.symbol)
                }
            }
            Divider()
            Toggle(isOn: Binding(get: { current?.image != nil }, set: { _ in
                // Once the menu has closed.
                DispatchQueue.main.async { model.chooseIconImage(for: space) }
            })) {
                Label("Image…", systemImage: "photo.badge.plus")
            }
        }
        // macOS 27 hides menu images unless the label asks for its icon.
        .labelStyle(.titleAndIcon)
    }

    private func iconChoice(_ title: String, symbol: String, checked: Bool) -> some View {
        Toggle(isOn: Binding(get: { checked }, set: { _ in
            model.setIcon(SpaceIcon(symbol: symbol), of: space)
        })) {
            Label(title, systemImage: symbol)
        }
    }
}

/// A tab under its space's row, as the tab strip shows it: its program's
/// icon, its name, else its number and what runs in it, and its state.
/// Under the pointer, a close button comes over the row's end. A click
/// shows the tab; a drag moves it among its space's tabs.
struct TabRow: View {
    @Environment(AppModel.self) private var model
    let space: SpaceItem
    let tab: LayoutTab
    /// Its place among its space's tabs.
    let index: Int
    /// The pointer is on the row.
    @State private var hovering = false
    /// The pointer is on the close button.
    @State private var onClose = false

    /// The close button comes once the pointer stays a moment, so a pointer
    /// passing over the rows doesn't light each one, and goes at once.
    private static let reveal = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.15).delay(0.08)
    private static let dismiss = Animation.easeOut(duration: 0.15)
    /// The close button's side, and the fade that ends the title before it.
    private static let closeSide: CGFloat = 16
    private static let fade: CGFloat = 14

    var body: some View {
        let subtitle = model.subtitle(of: tab, in: space)
        let title = model.title(of: tab, index: index)
        HStack(spacing: 6) {
            Label {
                Group {
                    if tab.name.isEmpty, !subtitle.isEmpty {
                        Text("\(title)  \(Text(cleanTitle(subtitle, fallback: subtitle)).foregroundStyle(.secondary))")
                    } else {
                        Text(title)
                    }
                }
                // The title runs to the row's end, where the close button
                // comes under the pointer: there the title fades out. Only
                // the title: under a mask, the sidebar draws its icons blank.
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: hovering ? Self.fade : 0)
                        Color.clear
                            .frame(width: hovering ? Self.closeSide : 0)
                    }
                }
            } icon: {
                ProgramIcon(key: model.programKey(of: tab, in: space) ?? "program")
            }
            .lineLimit(1)
            AttentionDot(attention: model.attention(of: model.addresses(of: tab, in: space)))
                // The close button takes its place.
                .opacity(hovering ? 0 : 1)
        }
        .overlay(alignment: .trailing) { closeButton }
        // The whole row's height: the button shows wherever the pointer is on it.
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
        .onHover { over in
            #if DEBUG
            if DebugHover.shared.holds { return }
            #endif
            withAnimation(over ? Self.reveal : Self.dismiss) { hovering = over }
        }
        #if DEBUG
        // `hover-tab` (DebugHooks): as if the pointer were on this row. After
        // the update, as a pointer's event comes: within it, the animation
        // is lost.
        .onChange(of: DebugHover.shared.tab) { _, id in
            DispatchQueue.main.async {
                withAnimation(id == tab.id ? Self.reveal : Self.dismiss) { hovering = id == tab.id }
            }
        }
        .onChange(of: DebugHover.shared.onClose) { _, on in
            DispatchQueue.main.async {
                withAnimation(Self.dismiss) { onClose = on && DebugHover.shared.tab == tab.id }
            }
        }
        #endif
        .help(subtitle)
        .contextMenu {
            Button("Rename…") {
                model.renaming = .tab(Place(space.machine, tab.id), tab.name)
            }
            if index > 0 {
                Button("Move Up") { model.moveTab(tab.id, in: space, to: index - 1) }
            }
            if index < space.tabs.count - 1 {
                Button("Move Down") { model.moveTab(tab.id, in: space, to: index + 1) }
            }
            Divider()
            Button("Close Tab", role: .destructive) {
                model.closeTab(tab.id, in: space)
            }
        }
    }

    private var closeButton: some View {
        Button {
            model.closeTab(tab.id, in: space)
        } label: {
            // Grey, it lights up with a backing once the pointer is on it.
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(onClose ? .primary : .secondary)
                .frame(width: Self.closeSide, height: Self.closeSide)
                .background(Color.primary.opacity(onClose ? 0.1 : 0), in: .rect(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
        .onHover { over in
            #if DEBUG
            if DebugHover.shared.holds { return }
            #endif
            withAnimation(Self.dismiss) { onClose = over }
        }
        .opacity(hovering ? 1 : 0)
        .scaleEffect(hovering ? 1 : 0.9)
        // Hidden, it takes no click.
        .allowsHitTesting(hovering)
        .help("Close Tab")
    }
}

/// Icons a space can take instead of its automatic one, in groups: SF
/// Symbols and their names.
enum SpaceIcons {
    static let standard = "folder"
    static let groups: [[(symbol: String, title: String)]] = [
        [("chevron.left.forwardslash.chevron.right", "Code"), ("terminal", "Terminal"), ("hammer", "Tools"),
         ("ant", "Debugging"), ("shippingbox", "Package"), ("server.rack", "Server"), ("cloud", "Cloud")],
        [("globe", "Website"), ("iphone", "iPhone App"), ("desktopcomputer", "Mac App"), ("gamecontroller", "Game"),
         ("brain", "AI"), ("chart.bar", "Data"), ("cart", "Shop")],
        [("book", "Documentation"), ("photo", "Photo"), ("film", "Video"), ("music.note", "Music"), ("paintpalette", "Design")],
        [("star", "Star"), ("heart", "Heart"), ("bolt", "Bolt"), ("flame", "Flame"), ("briefcase", "Work"), ("house", "Home")],
    ]
}

/// A space's icon in the sidebar. An image or a letter takes the room of a
/// symbol, so it follows the sidebar's icon size.
struct SpaceIconView: View {
    let look: SpaceLook

    /// Colors for letters. Orange, green and teal are too light for white
    /// on them (about 2:1), so they get darker.
    static let letterColors: [Color] = [
        .red, .orange.mix(with: .black, by: 0.3), .green.mix(with: .black, by: 0.3), .teal.mix(with: .black, by: 0.3),
        .blue, .indigo, .purple, .pink, .brown,
    ]

    var body: some View {
        switch look {
        case .symbol(let name):
            Image(systemName: name)
        case .image(let image):
            Image(systemName: "square")
                .hidden()
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(IconShape())
                }
        case .letter(let letter, let hash):
            Image(systemName: "square")
                .hidden()
                .overlay {
                    GeometryReader { box in
                        let side = min(box.size.width, box.size.height)
                        Text(letter)
                            .font(.system(size: side * 0.66, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: side, height: side)
                            .background(Self.letterColors[Int(hash % UInt32(Self.letterColors.count))].gradient,
                                        in: IconShape())
                            .frame(width: box.size.width, height: box.size.height)
                    }
                }
        }
    }
}

/// A space's picture or letter: a square whose corners grow with it, as an
/// app icon's.
nonisolated struct IconShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.25, style: .continuous)
    }
}

/// A program's icon, from herdr-app's table (`Assets.xcassets/Programs`):
/// Claude's for Claude Code, OpenAI's for Codex, a prompt for a shell…
/// One-color icons take the text's color.
struct ProgramIcon: View {
    /// A `Programs` key.
    let key: String
    var size: CGFloat = 16

    var body: some View {
        Image("Programs/" + key)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel(Programs.name(key) ?? key)
    }
}

/// An agent: its mark, the folder it works in, then its session's title.
struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: TerminalModel

    var body: some View {
        HStack(spacing: 8) {
            ProgramIcon(key: Self.icon(of: agent))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Self.folder(of: agent))
                        .lineLimit(1)
                    // On another machine: which one.
                    if let machine = agent.machine {
                        Text(model.title(ofMachine: machine))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let since = agent.statusMs {
                        ElapsedTime(since: since)
                    }
                    AttentionDot(attention: agent.attention)
                        // As wide in every state, so the times line up.
                        .frame(width: 12)
                        // Level with the text, not sitting on its baseline.
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                Text(Self.subtitle(of: agent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        // What it said last, which the row no longer shows.
        .help(agent.status?.message ?? "")
    }

    /// The folder it works in: "swiftr", "~".
    static func folder(of agent: TerminalModel) -> String {
        let folder = folderName(agent.currentFolder)
        return folder.isEmpty ? name(of: agent) : folder
    }

    /// Its session's title, else what it said last, else its name.
    static func subtitle(of agent: TerminalModel) -> String {
        if let title = ClaudeTitle.session(reported: agent.status?.title, terminal: agent.title) { return title }
        if let message = agent.status?.message, !message.isEmpty { return message }
        return name(of: agent)
    }

    /// "Claude Code", "Codex", else the program it runs.
    static func name(of agent: TerminalModel) -> String {
        let key = agent.programKey
        return Programs.isAgent(key) ? Programs.name(key) ?? key : agent.foreground?.program ?? agent.address
    }

    /// Its program's icon; a robot when that says nothing of an agent (a
    /// shell, a program the table doesn't know).
    static func icon(of agent: TerminalModel) -> String {
        let key = agent.programKey
        return key == "shell" || key == "program" ? "agent" : key
    }
}

/// How long ago an agent's status word changed: "< 1 min", "5 min", "2 h", "3 d".
struct ElapsedTime: View {
    /// ms since 1970.
    let since: Int64

    var body: some View {
        // Again at each minute since the change, when the text changes.
        TimelineView(.periodic(from: Date(timeIntervalSince1970: Double(since) / 1000), by: 60)) { context in
            Text(Self.text(since: since, now: context.date))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    static func text(since: Int64, now: Date) -> String {
        // To the ms: a refresh at the minute can land a hair before it.
        let elapsed = Int64((now.timeIntervalSince1970 * 1000).rounded()) - since
        // Another machine's clock may run a little ahead.
        let minutes = max(0, Int(elapsed / 60_000))
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours) h" : "\(hours / 24) d"
    }
}

/// The header over a group of agents: their state, in its color, and how
/// many. A click folds the group, as in herdr-app.
struct AgentGroupHeader: View {
    let group: AgentGroup
    let folded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Text(title)
                    .foregroundStyle(color)
                Text("\(group.agents.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // Folded, or under the pointer: which way a click goes.
                FoldMark(collapsed: folded)
                    .foregroundStyle(.secondary)
                    .opacity(folded || hovering ? 1 : 0)
                    // Under the chevrons of the other headers.
                    .padding(.trailing, 14)
            }
            .font(.caption.weight(.semibold))
            // The whole header takes the click.
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(folded ? "Expand this group" : "Collapse this group")
        .accessibilityAddTraits(.isHeader)
        // A section's header is a row too: a click would mark it.
        .selectionDisabled()
    }

    private var title: String {
        switch group.attention {
        case .needsYou: return "Needs you"
        case .done: return "Done"
        case .working: return "Working"
        case .idle, .none: return "Idle"
        }
    }

    /// The colors of the agents' own marks.
    private var color: Color {
        switch group.attention {
        case .needsYou: .orange
        case .done: .accentColor
        case .working, .idle, .none: .secondary
        }
    }
}

/// A title without the status symbols agents put in front (✳, ·, •…).
func cleanTitle(_ title: String, fallback: String) -> String {
    let trimmed = title.drop { ch in !(ch.isLetter || ch.isNumber) }.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed == "Claude Code" { return fallback }
    return trimmed
}

struct AttentionDot: View {
    let attention: Attention

    var body: some View {
        switch attention {
        case .needsYou:
            Circle().fill(Color.orange).frame(width: 7, height: 7).help("Waiting for an answer")
        case .done:
            Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("Done, not seen yet")
        case .working:
            ProgressView().controlSize(.mini).help("Working")
        case .idle, .none:
            EmptyView()
        }
    }
}
