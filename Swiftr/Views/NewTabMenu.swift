import HerdrKit
import SwiftUI

/// The + beside the tabs: it opens `NewTabMenu`.
struct NewTabButton: View {
    @Environment(AppModel.self) private var model
    let space: SpaceItem

    var body: some View {
        Button {
            model.select(space: space)
            model.launcher.menu = .tabStrip
        } label: {
            Image(systemName: "plus")
                // The color itself: a borderless button dims `.primary`.
                .foregroundStyle(Color.primary)
                .frame(width: TabStrip.button.width, height: TabStrip.button.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("New Tab")
        .popover(isPresented: NewTabMenu.shown(.tabStrip, model), arrowEdge: .bottom) {
            NewTabMenu(machine: space.machine)
                .environment(model)
        }
    }
}

/// What a + opens, as herdr-app's new-menu: a terminal, the agents the
/// space's machine has (most picked first; 1 to 9 start them), a new space.
/// An agent's star puts it beside the + (`FavoriteAgents`).
struct NewTabMenu: View {
    @Environment(AppModel.self) private var model
    /// Where the tab goes ("" is this Mac).
    let machine: String
    /// The row under the pointer or picked with the arrow keys.
    @State private var selected: Item?
    @FocusState private var focused: Bool

    enum Item: Hashable {
        case terminal
        case agent(String)
        case space
    }

    /// Binds a popover to the menu being open at `place`.
    static func shown(_ place: AgentLauncher.MenuPlace, _ model: AppModel) -> Binding<Bool> {
        Binding(
            get: { model.launcher.menu == place },
            set: { open in
                if open { model.launcher.menu = place } else if model.launcher.menu == place { model.launcher.menu = nil }
            }
        )
    }

    var body: some View {
        let launcher = model.launcher!
        let choices = launcher.choices(on: machine)
        let installed = choices.filter { $0.installed }.map { $0.agent }
        let items = [Item.terminal] + installed.map { .agent($0.key) } + [.space]
        VStack(alignment: .leading, spacing: 0) {
            row(.terminal, title: "Terminal", hint: "⌘T") {
                ProgramIcon(key: "shell", size: 15)
                    .foregroundStyle(.secondary)
            }
            header
            ForEach(Array(choices.enumerated()), id: \.element.agent.key) { i, choice in
                agentRow(choice.agent, number: choice.installed && i < 9 ? i + 1 : nil, installed: choice.installed)
            }
            if let note = note(knowsAgents: launcher.installed(on: machine) != nil) {
                Text(note)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
            }
            Divider()
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
            row(.space, title: "New Space", hint: "⌘N") {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(5)
        .frame(width: 264)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) {
            move(1, in: items)
            return .handled
        }
        .onKeyPress(.upArrow) {
            move(-1, in: items)
            return .handled
        }
        .onKeyPress(.return) {
            guard let selected else { return .ignored }
            perform(selected)
            return .handled
        }
        .onKeyPress(.escape) {
            model.launcher.menu = nil
            return .handled
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), (1 ... 9).contains(n), n <= installed.count else { return .ignored }
            perform(.agent(installed[n - 1].key))
            return .handled
        }
        .onAppear {
            focused = true
            launcher.check(machine)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Start an Agent")
            Spacer(minLength: 8)
            // On another machine, which one.
            if !machine.isEmpty {
                Text(model.title(ofMachine: machine))
                    .lineLimit(1)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 9)
        .padding(.bottom, 3)
    }

    /// Why the list is short: still asking, or the machine didn't answer.
    private func note(knowsAgents: Bool) -> String? {
        if model.launcher.checkFailed(machine) { return "Couldn't check installed agents" }
        return knowsAgents ? nil : "Checking installed agents…"
    }

    private func agentRow(_ agent: Programs.Program, number: Int?, installed: Bool) -> some View {
        let favorite = model.prefs.isFavorite(agent: agent.key)
        let item = Item.agent(agent.key)
        let star = { model.prefs.setFavorite(!favorite, agent: agent.key) }
        return MenuRow(
            title: agent.name, hint: installed ? number.map(String.init) ?? "" : "Not installed",
            enabled: installed, highlighted: installed && selected == item,
            hover: { hover($0, item) }, action: { perform(item) }
        ) {
            ProgramIcon(key: agent.key, size: 15)
                .foregroundStyle(.secondary)
        } accessory: {
            if installed {
                Button(action: star) {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(favorite ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // A favorite shows its star; the others, under the pointer.
                .opacity(favorite || selected == item ? 1 : 0)
                .allowsHitTesting(favorite || selected == item)
                .help(favorite ? "Remove from Favorites" : "Add to Favorites")
            }
        }
        .accessibilityAction(named: favorite ? "Remove from Favorites" : "Add to Favorites", star)
    }

    private func row(_ item: Item, title: String, hint: String, @ViewBuilder icon: () -> some View) -> some View {
        MenuRow(title: title, hint: hint, highlighted: selected == item, hover: { hover($0, item) }, action: { perform(item) }, icon: icon) {
            EmptyView()
        }
    }

    private func hover(_ inside: Bool, _ item: Item) {
        if inside { selected = item } else if selected == item { selected = nil }
    }

    /// The next row up or down, round the ends.
    private func move(_ step: Int, in items: [Item]) {
        guard !items.isEmpty else { return }
        let i = selected.flatMap(items.firstIndex(of:)) ?? (step > 0 ? -1 : items.count)
        selected = items[((i + step) % items.count + items.count) % items.count]
    }

    private func perform(_ item: Item) {
        model.launcher.menu = nil
        switch item {
        case .terminal: model.newTab()
        case .agent(let key): if let agent = Programs.startable(key) { model.newTab(agent: agent) }
        case .space: model.newSpace(on: machine)
        }
    }
}

/// A line of the menu: an icon, a title, then what a key does.
private struct MenuRow<Icon: View, Accessory: View>: View {
    let title: String
    let hint: String
    var enabled = true
    let highlighted: Bool
    let hover: (Bool) -> Void
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @ViewBuilder let accessory: Accessory

    var body: some View {
        // A button rather than a tap: the click counts even when the menu's
        // window isn't key yet. The star inside is a button of its own.
        Button {
            if enabled { action() }
        } label: {
            HStack(spacing: 8) {
                icon
                    .frame(width: 16, height: 16)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                accessory
                Text(hint)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 16, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(highlighted ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(RowStyle())
        .opacity(enabled ? 1 : 0.5)
        .onHover(perform: hover)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(hint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { action() } }
    }
}

/// A menu row looks the same pressed or not, as a menu item does.
private struct RowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// The starred agents, beside the +: a click starts one in a new tab.
struct FavoriteAgents: View {
    @Environment(AppModel.self) private var model
    let space: SpaceItem

    var body: some View {
        let favorites = model.prefs.favoriteAgents.compactMap { Programs.startable($0) }
        let found = model.launcher.installed(on: space.machine)
        ForEach(Array(favorites.enumerated()), id: \.element.key) { i, agent in
            // Known to be missing on this space's machine.
            let missing = found.map { !$0.contains(agent.key) } ?? false
            Button {
                model.select(space: space)
                model.newTab(agent: agent)
            } label: {
                ProgramIcon(key: agent.key, size: 15)
                    .foregroundStyle(Color.primary)
                    .frame(width: TabStrip.button.width, height: TabStrip.button.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(missing)
            .opacity(missing ? 0.4 : 1)
            .help(missing ? "\(agent.name) isn't installed on \(model.title(ofMachine: space.machine))"
                : "New \(agent.name) Tab" + (i == 0 ? " (⌥⌘T)" : ""))
            .contextMenu {
                Button("New \(agent.name) Tab") {
                    model.select(space: space)
                    model.newTab(agent: agent)
                }
                .disabled(missing)
                Divider()
                if i > 0 {
                    Button("Move Left") { model.prefs.moveFavorite(agent.key, by: -1) }
                }
                if i < favorites.count - 1 {
                    Button("Move Right") { model.prefs.moveFavorite(agent.key, by: 1) }
                }
                Button("Remove from Favorites") { model.prefs.setFavorite(false, agent: agent.key) }
            }
        }
    }
}
