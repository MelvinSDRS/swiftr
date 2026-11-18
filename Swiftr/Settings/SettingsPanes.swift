import AppKit
import HerdrKit
import SwiftUI

// MARK: Appearance

/// Light or dark, the terminals' colors, the Dock icon.
struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                ChoiceTiles(selection: $prefs.appearance, choices: [
                    .init(.automatic, "Automatic"), .init(.light, "Light"), .init(.dark, "Dark"),
                ]) { look in
                    AppearancePicture(look: look)
                }
            } header: {
                Text("Appearance")
            } footer: {
                SettingsNote("Automatic follows the Mac. Swiftr's own theme turns light or dark with the windows.")
            }
            Section {
                ThemeGallery()
                HStack {
                    Button("Open Themes Folder") {
                        try? FileManager.default.createDirectory(at: Preferences.themesFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Preferences.themesFolder)
                    }
                    Button("Reload Themes") { prefs.loadThemes() }
                    Spacer()
                }
            } header: {
                Text("Terminal theme")
            } footer: {
                SettingsNote(themeNote(prefs.themeName))
            }
            Section {
                ChoiceTiles(selection: Binding(get: { Mods.shared.sidebarStyle }, set: { Mods.shared.pick(style: $0) }), choices: [
                    .init(.floating, "Floating"), .init(.card, "Card"),
                ]) { style in
                    ModSidebarPicture(style: style)
                }
            } header: {
                Text("Mods sidebar")
            } footer: {
                SettingsNote("The sidebar on the right, with Changes and your mods: a panel on the terminals' card, or a card of its own beside it.")
            }
            Section {
                ChoiceTiles(selection: $prefs.appIcon, choices: [
                    .init(.automatic, "Automatic"), .init(.light, "Light"), .init(.dark, "Dark"),
                ], size: CGSize(width: 72, height: 72), framed: false) { style in
                    AppIconPicture(style: style)
                }
            } header: {
                Text("App icon")
            } footer: {
                SettingsNote("Light and Dark change the Dock icon while Swiftr is open; the Finder keeps the automatic one.")
            }
        }
        .formStyle(.grouped)
    }

    private func themeNote(_ name: String) -> String {
        if name == Preferences.swiftrThemeName {
            return "Swiftr's theme takes herdr's Graphite and Paper colors and turns dark or light with the app, in terminals and in Messages. For Claude Code to follow, pick Auto in its /theme."
        }
        return "This theme keeps its colors in light and dark; Swiftr's turns with the app. A theme is a JSON file in herdr-app's format, in the themes folder."
    }
}

// MARK: Window

/// The tab bar, and where the sidebar lists the agents.
struct WindowSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var prefs = model.prefs
        let dark = scheme == .dark
        let theme = prefs.theme
        Form {
            Section {
                ChoiceTiles(selection: $prefs.showsTabBar, choices: [
                    .init(true, "Tab bar"), .init(false, "Tabs in the sidebar"),
                ]) { shown in
                    MiniWindow(dark: dark, theme: theme, tabBar: shown, sidebar: shown ? .spaces : .tabs,
                               mark: shown ? .tabBar : .sidebarTabs)
                }
                Toggle("Ask before closing a tab where a program is running", isOn: $prefs.confirmsTabClose)
            } header: {
                Text("Tabs")
            } footer: {
                SettingsNote("Without the tab bar, a space's triangle in the sidebar lists its tabs. View › Show Tab Bar brings the bar back.")
            }
            Section {
                ChoiceTiles(selection: $prefs.agentsPlace, choices: [
                    .init(.bottom, "Agents below"), .init(.top, "Agents above"),
                ]) { place in
                    MiniWindow(dark: dark, theme: theme, tabBar: prefs.showsTabBar,
                               sidebar: place == .top ? .agentsAbove : .agentsBelow, mark: .agents)
                }
            } header: {
                Text("Sidebar")
            } footer: {
                SettingsNote("Spaces and agents scroll on their own. Drag the line between them to give either more room.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Terminal

/// The font, the Option key and the cursor, over a sample that shows them.
struct TerminalSettings: View {
    @Environment(AppModel.self) private var model
    @State private var fonts: [String] = []
    /// The size while the slider is dragged: terminals take it once it
    /// stops, rather than at every step.
    @State private var sliding: Double?
    @State private var dragging = false

    var body: some View {
        @Bindable var prefs = model.prefs
        let size = sliding ?? prefs.fontSize
        Form {
            Section {
                TerminalSample(theme: prefs.theme, family: prefs.fontName, size: size, blinks: prefs.blinkCursor)
            }
            Section {
                Picker("Font", selection: $prefs.fontName) {
                    Text("SF Mono").tag("")
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { sliding ?? prefs.fontSize }, set: { value in
                            // From the keyboard, at once.
                            if dragging { sliding = value.rounded() } else { prefs.fontSize = value.rounded() }
                        }), in: 7 ... 48) { editing in
                            dragging = editing
                            guard !editing, let done = sliding else { return }
                            prefs.fontSize = done
                            sliding = nil
                        }
                        Text("\(Int(size)) pt")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                        Stepper("Size", value: $prefs.fontSize, in: 7 ... 48, step: 1)
                            .labelsHidden()
                    }
                }
            } header: {
                Text("Font")
            } footer: {
                SettingsNote("⌘+ and ⌘− change the size from the window; ⌘0 sets it back to \(Int(Preferences.defaultFontSize)) pt.")
            }
            Section {
                OptionKeyPicture(mode: prefs.optionKey)
                Picker("Option key", selection: $prefs.optionKey) {
                    Text("Characters, Meta on ← → ↩ ⌫").tag(OptionKey.auto)
                    Text("Meta everywhere").tag(OptionKey.meta)
                    Text("Characters everywhere").tag(OptionKey.characters)
                }
            } header: {
                Text("Keyboard")
            } footer: {
                SettingsNote("Meta sends Esc, then the key, as shells and Emacs expect. Characters are what your keyboard layout types with ⌥.")
            }
            Section {
                Toggle("Blinking cursor", isOn: $prefs.blinkCursor)
            } header: {
                Text("Cursor")
            } footer: {
                SettingsNote("New terminals take it.")
            }
        }
        .formStyle(.grouped)
        .task { fonts = Self.monospacedFamilies() }
    }

    static func monospacedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard !family.hasPrefix("."), let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
    }
}

// MARK: Agents

/// The agents beside the tabs' +, what tells you about an agent, and what
/// Messages shows for every agent.
struct AgentSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("messagesExpandDiffs") private var expandsDiffs = false

    var body: some View {
        @Bindable var prefs = model.prefs
        let favorites = prefs.favoriteAgents.compactMap { Programs.startable($0) }
        Form {
            Section {
                FavoritesPicture(favorites: favorites)
                ForEach(Array(favorites.enumerated()), id: \.element.key) { i, agent in
                    FavoriteRow(agent: agent, index: i, count: favorites.count)
                }
                addFavorite
            } header: {
                Text("Favorite agents")
            } footer: {
                SettingsNote("Each favorite gets a button beside the tabs' +, in this order; the first also starts with ⌥⌘T. The stars in the + menu add them too.")
            }
            Section {
                AlertFlow()
                NotificationPicture(on: prefs.agentNotifications)
                Toggle("Show notifications", isOn: $prefs.agentNotifications)
                    .onChange(of: prefs.agentNotifications) { _, on in if on { model.alerts.askPermission() } }
                if prefs.agentNotifications, model.alerts.permission == .denied {
                    LabeledContent("macOS blocks Swiftr's notifications") {
                        Button("Open System Settings") { model.alerts.openSystemSettings() }
                    }
                }
            } header: {
                Text("When an agent needs you or is done")
            } footer: {
                SettingsNote("Swiftr plays the “Needs you” sound every time, the “Done” sound only when you're looking elsewhere. Notifications come only when you're looking elsewhere; a click on one shows the agent. While herdr-app runs with its sounds on, it plays them instead.")
            }
            Section {
                Picker(selection: $prefs.sleepAfter) {
                    ForEach(SleepAfter.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                } label: {
                    Label("Put idle agents to sleep", systemImage: "moon.zzz")
                }
            } header: {
                Text("Memory")
            } footer: {
                SettingsNote("Asleep, an agent holds no memory: Swiftr quits it, keeps its tab and its conversation, and starts it again when you write to it. Only an idle Claude Code on this Mac sleeps, out of sight, with nothing unsent and no command running. Each tab's menu has Sleep and Wake.")
            }
            Section {
                Toggle(isOn: $expandsDiffs) {
                    Label("Show diffs expanded", systemImage: "plusminus")
                }
            } header: {
                Text("Messages")
            } footer: {
                SettingsNote("Each edit the agent makes shows its changed lines at once, even among folded steps. Off, a click on the edit shows them. Each agent's own pane sets how its panes open, and the status line and usage under its field.")
            }
        }
        .formStyle(.grouped)
    }

    /// The agents not starred yet: those found on this Mac first.
    private var addFavorite: some View {
        let others = Programs.startable.filter { !model.prefs.isFavorite(agent: $0.key) }
        let found = model.launcher.installed(on: "")
        let here = others.filter { found?.contains($0.key) ?? true }
        let missing = others.filter { !(found?.contains($0.key) ?? true) }
        return Menu {
            ForEach(here, id: \.key) { agent in
                Button(agent.name) { model.prefs.setFavorite(true, agent: agent.key) }
            }
            if !missing.isEmpty {
                Section("Not Found on This Mac") {
                    ForEach(missing, id: \.key) { agent in
                        Button(agent.name) { model.prefs.setFavorite(true, agent: agent.key) }
                    }
                }
            }
        } label: {
            Label("Add Favorite", systemImage: "plus.circle.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(others.isEmpty)
    }
}

/// A favorite: its place, and buttons to move it or take its star away.
private struct FavoriteRow: View {
    @Environment(AppModel.self) private var model
    let agent: Programs.Program
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            ProgramIcon(key: agent.key, size: 16)
                .foregroundStyle(.secondary)
            Text(agent.name)
            if index == 0 {
                KeyCap(label: "⌥⌘T", small: true)
            }
            Spacer()
            Button {
                model.prefs.moveFavorite(agent.key, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .help("Move Up")
            Button {
                model.prefs.moveFavorite(agent.key, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == count - 1)
            .help("Move Down")
            Button {
                model.prefs.setFavorite(false, agent: agent.key)
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .help("Remove from Favorites")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: An agent

/// An agent's own pane: how its panes open, what shows under its field (its
/// status line and the limits of its plan), and for Claude Code the jobs
/// Swiftr or herdr-app does.
struct AgentPaneSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let agent: ChatAgent

    var body: some View {
        let prefs = model.prefs
        Form {
            Section {
                ChoiceTiles(selection: Binding(get: { prefs.panes(of: agent) }, set: { prefs.setPanes($0, of: agent) }), choices: [
                    .init(.terminal, "Terminal"), .init(.messages, "Messages"),
                ]) { mode in
                    MiniWindow(dark: scheme == .dark, theme: prefs.theme, tabBar: prefs.showsTabBar,
                               content: mode == .terminal ? .claude : .messages, agentColor: markColor(prefs.theme))
                }
            } header: {
                Text("\(agent.name) panes open as")
            } footer: {
                SettingsNote("Terminal shows \(agent.title) as it draws itself; Messages shows the conversation, with a field to write in. Each pane can switch with ⇧⌘M or the button at its top right.")
            }
            if agent.hasStatusLine || agent.hasUsage {
                UnderFieldSection(agent: agent)
            }
            if agent.hasUsage {
                UsageLimitsSection(agent: agent)
            } else {
                Section {
                    LabeledContent("Usage", value: "None to show")
                } footer: {
                    SettingsNote("OpenCode has no usage limits of its own: each provider it talks to counts them on its side.")
                }
            }
        }
        .formStyle(.grouped)
        // The limits of the plan as they stand: read again when the pane shows.
        .task(id: agent) { model.usage.check(agent) }
    }

    /// The agent's mark in the small terminal: Claude's orange, Gemini's
    /// blue, the text's color for the others.
    private func markColor(_ theme: TerminalTheme) -> Color {
        switch agent {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .gemini: Color(red: 0.3, green: 0.55, blue: 0.98)
        case .codex, .opencode: theme.pictureText.opacity(0.85)
        }
    }
}

/// What shows under the agent's Messages field: its status line and its usage.
private struct UnderFieldSection: View {
    @Environment(AppModel.self) private var model
    let agent: ChatAgent

    var body: some View {
        let prefs = model.prefs
        Section {
            UnderFieldPicture(agent: agent, usage: prefs.usage(of: agent), statusLine: prefs.showsStatusLine(of: agent))
            if agent.hasStatusLine {
                Toggle(statusLineTitle, isOn: Binding(get: { prefs.showsStatusLine(of: agent) },
                                                      set: { prefs.setShowsStatusLine($0, of: agent) }).animation(.snappy))
            }
            if agent.hasUsage {
                Toggle("Show usage", isOn: Binding(get: { prefs.usage(of: agent).shown }, set: { shown in
                    var settings = prefs.usage(of: agent)
                    settings.shown = shown
                    prefs.setUsage(settings, of: agent)
                }).animation(.snappy))
            }
        } header: {
            Text("Under the Messages field")
        } footer: {
            SettingsNote(note)
        }
    }

    private var statusLineTitle: String {
        switch agent {
        case .claude: "Show your status line"
        case .codex: "Show Codex's status line"
        case .gemini: "Show Gemini's footer"
        case .opencode: ""
        }
    }

    private var note: String {
        switch agent {
        case .claude:
            "Your status line, as Claude Code draws it under its own field, and the limits of your plan. A right click under the field hides either."
        case .codex:
            "What you added to Codex's status line with /statusline (the field already shows the model and folder), and the limits of your ChatGPT plan. A right click under the field hides either."
        case .gemini:
            "Gemini's footer, as it draws it, and the quota it shows there. A right click under the field hides either."
        case .opencode:
            ""
        }
    }
}

/// The limits of the agent's plan, as its replies list them: which show
/// under the field, in what order, and how.
private struct UsageLimitsSection: View {
    @Environment(AppModel.self) private var model
    let agent: ChatAgent

    var body: some View {
        let prefs = model.prefs
        let settings = prefs.usage(of: agent)
        let limits = settings.arrange(model.usage.limits(of: agent), all: true)
        let ids = limits.map(\.id)
        Section {
            if agent != .gemini {
                plan
            }
            if limits.isEmpty {
                Text(empty)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(limits.enumerated()), id: \.element.id) { i, limit in
                LimitRow(limit: limit, shown: Binding(get: { settings.shows(limit.id) }, set: { on in
                    var changed = prefs.usage(of: agent)
                    changed.choices[limit.id] = on
                    prefs.setUsage(changed, of: agent)
                }), index: i, count: limits.count) { step in
                    var changed = prefs.usage(of: agent)
                    changed.move(limit.id, by: step, among: ids)
                    withAnimation(.snappy) { prefs.setUsage(changed, of: agent) }
                }
            }
            Picker("Count", selection: binding(\.countsLeft)) {
                Text("What's left").tag(true)
                Text("What's used").tag(false)
            }
            Toggle("Show when each limit starts over", isOn: binding(\.showsResets))
        } header: {
            Text("Usage limits")
        } footer: {
            SettingsNote(note)
        }
        .disabled(!settings.shown)
    }

    /// The plan the limits come with, and a button to read them again.
    private var plan: some View {
        let plans = model.usage.plans(of: agent)
        let checking = model.usage.checking(agent)
        return LabeledContent("Plan") {
            HStack(spacing: 8) {
                if checking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(plans.isEmpty ? (checking ? "Reading…" : "Not read yet") : plans.joined(separator: ", "))
                Button("Refresh") { model.usage.check(agent, force: true) }
                    .disabled(checking)
            }
        }
    }

    /// Before any reply lists the limits: why.
    private var empty: String {
        if let problem = model.usage.problems(of: agent).first { return UsageText.problem(problem, agent: agent) }
        if model.usage.checking(agent) { return "Reading the limits of your plan…" }
        return agent == .codex
            ? "Codex gives its limits with its first answer: Swiftr lists them then."
            : "Swiftr lists the limits of your plan once it has read them."
    }

    private func binding<V>(_ key: WritableKeyPath<UsageSettings, V>) -> Binding<V> {
        Binding(get: { model.prefs.usage(of: agent)[keyPath: key] }, set: { value in
            var settings = model.prefs.usage(of: agent)
            settings[keyPath: key] = value
            model.prefs.setUsage(settings, of: agent)
        })
    }

    private var note: String {
        let colors = "Orange: you use a limit faster than its time runs; red: it's nearly gone."
        switch agent {
        case .claude:
            return "Only the limits your plan has, as Claude Code's /usage lists them. The arrows set their order under the field. Swiftr asks Anthropic with the sign-in Claude Code keeps in your Keychain: every 3 minutes while a Claude conversation shows, after each answer, and when this pane opens. It never changes that sign-in. " + colors
        case .codex:
            return "Only the limits your ChatGPT plan has, as Codex reports them. The arrows set their order under the field. Swiftr reads them from Codex's session files after each answer, or asks Codex's app server, at most every 5 minutes. " + colors
        case .gemini:
            return "Gemini shows one quota in its footer, for some sign-ins only: the share of the day's requests your account used."
        case .opencode:
            return ""
        }
    }
}

/// A limit: whether it shows under the field, how long it runs, and buttons
/// to move it.
private struct LimitRow: View {
    let limit: UsageWindow
    @Binding var shown: Bool
    let index: Int
    let count: Int
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(limit.title, isOn: $shown)
                .toggleStyle(.checkbox)
            Spacer()
            Text(UsageText.span(limit))
                .foregroundStyle(.secondary)
            if count > 1 {
                Button {
                    move(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .help("Move Up")
                Button {
                    move(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == count - 1)
                .help("Move Down")
            }
        }
        .buttonStyle(.borderless)
    }
}

// MARK: herdr-core

/// Where the terminals live: the core Swiftr talks to, and its machines.
struct CoreSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ConnectionPicture()
            } footer: {
                SettingsNote("Terminals live in herdr-core, not in Swiftr: they keep running when Swiftr quits. herdr-core reaches other machines with ssh, through their own herdr-core.")
            }
            CoreUpdatesSection()
            Section("Details") {
                LabeledContent("Status") { status }
                LabeledContent("Session", value: model.endpoint.session)
                LabeledContent("Socket") {
                    HStack(spacing: 6) {
                        Text(model.endpoint.socketPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: model.endpoint.socketPath)])
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var status: some View {
        switch model.link {
        case .connecting:
            Label("Connecting…", systemImage: "circle.dotted")
                .foregroundStyle(.orange)
        case .missing:
            Label("Not installed", systemImage: "arrow.down.circle")
                .foregroundStyle(.orange)
        case .installing:
            Label("Installing herdr-core…", systemImage: "arrow.down.circle")
                .foregroundStyle(.orange)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let why), .installFailed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
