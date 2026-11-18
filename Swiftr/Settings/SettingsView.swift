import AppKit
import HerdrKit
import SwiftUI

/// The Settings window, laid out as System Settings: the panes in a list on
/// the left, the chosen one on the right. It opens on the pane last shown.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsPane.defaultsKey) private var pane = SettingsPane.appearance

    var body: some View {
        let panes = shownPanes
        NavigationSplitView {
            List(selection: Binding<SettingsPane?>(get: { shown(pane, in: panes) }, set: { if let new = $0 { pane = new } })) {
                ForEach(panes) { pane in
                    Label {
                        Text(pane.title)
                    } icon: {
                        PaneIcon(pane: pane)
                    }
                    .tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(196)
            // The list always shows: there is nothing to hide it for.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let current = shown(pane, in: panes)
            detail(current)
                .navigationTitle(current.title)
        }
        .frame(width: 780)
        .frame(minHeight: 620, idealHeight: 700)
        .onAppear {
            model.alerts.refreshPermission()
            // Which agents this Mac has: a pane for each.
            model.launcher.check("")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.alerts.refreshPermission()
        }
    }

    /// The panes: an agent's only when this Mac has it, or before Swiftr
    /// knows; Dictation only on Apple silicon.
    private var shownPanes: [SettingsPane] {
        let installed = model.launcher.installed(on: "")
        return SettingsPane.allCases.filter { pane in
            if pane == .dictation { return SpeechModels.supported }
            guard let agent = pane.agent, let installed else { return true }
            return installed.contains(agent.rawValue)
        }
    }

    /// The pane last shown, else Agents when its agent went.
    private func shown(_ pane: SettingsPane, in panes: [SettingsPane]) -> SettingsPane {
        panes.contains(pane) ? pane : .agents
    }

    @ViewBuilder private func detail(_ pane: SettingsPane) -> some View {
        switch pane {
        case .appearance: AppearanceSettings()
        case .window: WindowSettings()
        case .terminal: TerminalSettings()
        case .agents: AgentSettings()
        case .claude, .codex, .opencode, .gemini:
            // Each its own view, so one's state doesn't carry to the next.
            if let agent = pane.agent { AgentPaneSettings(agent: agent).id(agent) }
        case .voice: VoiceSettings()
        case .dictation: DictationSettings()
        case .mods: ModsSettings()
        case .core: CoreSettings()
        case .updates: UpdatesSettings()
        }
    }
}

/// The panes of the Settings window, in the list's order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance
    case window
    case terminal
    case agents
    case claude
    case codex
    case opencode
    case gemini
    case voice
    case dictation
    case mods
    case core
    case updates

    static let defaultsKey = "settingsPane"

    var id: String { rawValue }

    /// The agent an agent's pane is for.
    var agent: ChatAgent? {
        ChatAgent(rawValue: rawValue)
    }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .window: "Window"
        case .terminal: "Terminal"
        case .agents: "Agents"
        case .claude, .codex, .opencode, .gemini: agent?.title ?? rawValue
        case .voice: "Voice"
        case .dictation: "Dictation"
        case .mods: "Mods"
        case .core: "herdr-core"
        case .updates: "Updates"
        }
    }

    /// Agents' panes show the agent's own mark instead.
    var symbol: String {
        switch self {
        case .appearance: "paintpalette.fill"
        case .window: "macwindow"
        case .terminal: "apple.terminal.fill"
        case .agents: "sparkles"
        case .claude, .codex, .opencode, .gemini: "bubble.left.fill"
        case .voice: "speaker.wave.2.fill"
        case .dictation: "mic.fill"
        case .mods: "puzzlepiece.extension.fill"
        case .core: "point.3.filled.connected.trianglepath.dotted"
        case .updates: "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .appearance: .purple
        case .window: .blue
        case .terminal: Color(white: 0.24)
        case .agents: .orange
        case .claude: Color(red: 0.97, green: 0.94, blue: 0.89)
        case .codex: Color(white: 0.1)
        case .opencode: Color(red: 0.2, green: 0.23, blue: 0.3)
        case .gemini: Color(red: 0.24, green: 0.45, blue: 0.95)
        case .voice: .pink
        case .dictation: .red
        case .mods: .teal
        case .core: .green
        case .updates: Color(white: 0.5)
        }
    }
}

/// A pane's icon in the list: a white symbol on a square of color, as
/// System Settings draws them; an agent's own mark for its pane.
struct PaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(pane.tint.gradient)
            .overlay {
                if pane == .claude {
                    // Claude's mark keeps its own colors.
                    ProgramIcon(key: "claude", size: 13)
                } else if let agent = pane.agent {
                    ProgramIcon(key: agent.rawValue, size: 12)
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.black.opacity(0.1), lineWidth: 0.5)
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}

/// What a group of settings does, under it.
struct SettingsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
