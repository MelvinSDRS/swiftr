import AppKit
import HerdrKit
import SwiftUI

/// The welcome sheet, on the first launch and from Swiftr › Welcome to
/// Swiftr…: a few short steps, each a picture and one thing to do. Every
/// choice is a setting, to change later in Settings.
struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model
    let onboarding: Onboarding
    static let size = CGSize(width: 640, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                page
                    .id(onboarding.step)
                    // The next step comes from the side it's on.
                    .transition(.asymmetric(insertion: .offset(x: onboarding.forward ? 36 : -36).combined(with: .opacity),
                                            removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.snappy(duration: 0.3), value: onboarding.step)
        .interactiveDismissDisabled()
    }

    @ViewBuilder private var page: some View {
        switch onboarding.step {
        case .welcome: WelcomePage()
        case .core: CorePage(state: onboarding.coreState(model))
        case .projects: ProjectsPage(onboarding: onboarding)
        case .agents: AgentsPage()
        case .dictation: DictationPage()
        case .voice: VoicePage()
        }
    }

    /// Back on the left, the steps as dots, and the button that does what
    /// the step asks for.
    private var footer: some View {
        HStack(spacing: 12) {
            if onboarding.step == .welcome {
                Button("Set Up Later") { model.endOnboarding() }
            } else {
                Button("Back") { onboarding.back() }
            }
            Spacer()
            Button {
                onboarding.proceed(model)
            } label: {
                Text(mainTitle)
                    .frame(minWidth: 84)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(busy)
        }
        .controlSize(.large)
        .overlay { StepDots(steps: onboarding.steps, current: onboarding.step) }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var mainTitle: String {
        switch onboarding.step {
        case .welcome: return "Get Started"
        case .core:
            switch onboarding.coreState(model) {
            case .missing: return "Install herdr-core"
            case .installing: return "Installing…"
            case .failed: return "Try Again"
            case .ready: return "Continue"
            }
        case .projects:
            let count = onboarding.toOpen.count
            if count == 0 { return onboarding.opened.isEmpty ? "Skip" : "Continue" }
            return count == 1 ? "Open 1 Project" : "Open \(count) Projects"
        case .agents, .dictation, .voice:
            return onboarding.isLast ? "Done" : "Continue"
        }
    }

    private var busy: Bool {
        switch onboarding.step {
        case .core: onboarding.coreState(model) == .installing
        case .projects: onboarding.opening
        default: false
        }
    }
}

/// The steps as dots, the one shown longer.
private struct StepDots: View {
    let steps: [Onboarding.Step]
    let current: Onboarding.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps, id: \.self) { step in
                Capsule()
                    .fill(step == current ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(.tertiary))
                    .frame(width: step == current ? 18 : 6, height: 6)
            }
        }
        .animation(.snappy(duration: 0.3), value: current)
        .animation(.snappy(duration: 0.3), value: steps)
        .accessibilityElement()
        .accessibilityLabel("Step \((steps.firstIndex(of: current) ?? 0) + 1) of \(steps.count)")
    }
}

/// A step: what it's for in a few words, then its picture and controls.
private struct Page<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            content
                .padding(.top, 24)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 44)
        .padding(.top, 36)
    }
}

/// Rows of choices on one surface, as a Settings section.
private struct RowBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: Welcome

private struct WelcomePage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            Text("Welcome to Swiftr")
                .font(.largeTitle.weight(.semibold))
                .padding(.top, 8)
            Text("Your terminals and coding agents, on every machine, in one window.")
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            MiniWindow(dark: scheme == .dark, theme: model.prefs.theme, content: .messages)
                .frame(width: 400, height: 250)
                .clipShape(shape)
                .overlay { shape.strokeBorder(.primary.opacity(0.14), lineWidth: 0.5) }
                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.16), radius: 16, y: 8)
                .padding(.top, 28)
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 14)
    }
}

// MARK: herdr-core

/// What herdr-core is, as a picture, and its install as it goes.
private struct CorePage: View {
    @Environment(AppModel.self) private var model
    let state: Onboarding.CoreState
    @State private var copied = false

    var body: some View {
        Page(title: "Your terminals live in herdr-core",
             subtitle: "Agents keep working when you quit Swiftr, here and on your other machines.") {
            CorePicture(ready: state == .ready)
                .padding(.top, 30)
            status
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .top)
                .padding(.top, 44)
        }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .missing:
            Text("Swiftr downloads it from herdr.dev into ~/.local.")
                .foregroundStyle(.secondary)
        case .installing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing herdr-core…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let why):
            let command = CoreInstall.command(environment: model.endpoint.environment)
            VStack(spacing: 8) {
                Label(why.hasSuffix(".") ? why : why + ".", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(command)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                    .help("Copy the command that installs herdr-core from Terminal")
                }
            }
        case .ready:
            Label("herdr-core is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

/// Swiftr, the window; herdr-core, where the terminals run; and the other
/// machines it reaches. The line to herdr-core is whole once it's there.
struct CorePicture: View {
    let ready: Bool
    private static let icon: CGFloat = 54

    var body: some View {
        // The lines run at the middle of the icons, the box centered on them.
        HStack(alignment: .iconMiddle, spacing: 0) {
            node(title: "Swiftr", detail: "The window", width: 112) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: Self.icon, height: Self.icon)
            }
            CoreLine(color: ready ? .green : .secondary, dashed: !ready, label: nil)
                .frame(width: 68, height: 24)
                .padding(.leading, -22)
            core
            CoreLine(color: .secondary, dashed: true, label: "ssh")
                .frame(width: 72, height: 24)
                .padding(.trailing, -26)
            node(title: "Other machines", detail: "Servers, other Macs", width: 112) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
                    .frame(width: Self.icon - 8, height: Self.icon - 8)
                    .overlay {
                        Image(systemName: "server.rack")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
            }
        }
        .animation(.snappy(duration: 0.35), value: ready)
        .accessibilityElement()
        .accessibilityLabel("Swiftr is the window. herdr-core runs your terminals, and reaches other machines over ssh.")
    }

    /// herdr-core as a box that holds the terminals.
    private var core: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.green.gradient)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: "server.rack")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text("herdr-core")
                        .font(.callout.weight(.semibold))
                    Text("Runs your terminals")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if ready {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.bottom, 4)
            terminal("claude", "Claude Code")
            terminal("codex", "Codex")
            terminal("shell", "zsh")
        }
        .padding(12)
        .frame(width: 236)
        .background(.quaternary.opacity(0.45), in: shape)
        .overlay { shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
    }

    private func terminal(_ key: String, _ name: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(spacing: 8) {
            ProgramIcon(key: key, size: 14)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(.background.opacity(0.7), in: shape)
        .overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
    }

    private func node(title: String, detail: String, width: CGFloat, @ViewBuilder icon: () -> some View) -> some View {
        VStack(spacing: 4) {
            icon()
                .alignmentGuide(.iconMiddle) { $0[VerticalAlignment.center] }
            Text(title)
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .frame(width: width)
    }
}

/// A line between two parts of the picture, with what goes over it.
private struct CoreLine: View {
    let color: Color
    let dashed: Bool
    let label: String?

    var body: some View {
        Canvas { g, size in
            var p = Path()
            p.move(to: CGPoint(x: 3, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width - 3, y: size.height / 2))
            g.stroke(p, with: .color(color.opacity(dashed ? 0.6 : 1)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3, 5] : []))
        }
        .overlay(alignment: .top) {
            if let label {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .offset(y: -6)
            }
        }
    }
}

// MARK: Projects

/// The folders to open as spaces: where the person's agents worked
/// lately, and any they add or drop here.
private struct ProjectsPage: View {
    @Environment(AppModel.self) private var model
    let onboarding: Onboarding
    @State private var dropping = false

    var body: some View {
        Page(title: "Open your projects", subtitle: "Each folder becomes a space in the sidebar, with its own tabs.") {
            VStack(spacing: 8) {
                HStack {
                    if onboarding.folders.contains(where: \.suggested) {
                        Text("Where your agents worked lately")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        onboarding.chooseFolders()
                    } label: {
                        Label("Add Folders…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 4)
                list
                    .frame(height: 300)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .opacity(dropping ? 1 : 0)
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        onboarding.add(urls.map(\.path))
                        return true
                    } isTargeted: { dropping = $0 }
                if let problem = onboarding.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await onboarding.suggest(model) }
    }

    @ViewBuilder private var list: some View {
        if onboarding.folders.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("Drop folders here")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            ScrollView {
                RowBox {
                    ForEach(onboarding.folders) { folder in
                        if folder != onboarding.folders.first {
                            Divider().padding(.leading, 46)
                        }
                        row(folder)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func row(_ folder: ProjectFolder) -> some View {
        let opened = onboarding.opened.contains(folder.path)
        let picked = onboarding.picked.contains(folder.path)
        return Button {
            onboarding.toggle(folder)
        } label: {
            HStack(spacing: 10) {
                // As the sidebar will show the space: its logo, else its letter.
                SpaceIconView(look: onboarding.look(of: folder))
                    .font(.system(size: 20))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.name)
                        .fontWeight(.medium)
                    Text(folder.shownPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if opened {
                    Text("Open")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(picked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(opened)
        .accessibilityLabel(folder.name)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

// MARK: Agents

/// The agents this Mac has, to star; how their panes open; and whether
/// Swiftr tells when one needs the person.
private struct AgentsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var prefs = model.prefs
        let found = model.launcher.installed(on: "")
        let agents = Programs.startable.filter { found?.contains($0.key) == true }
        let favorites = prefs.favoriteAgents.compactMap { Programs.startable($0) }
        Page(title: "Pick your agents", subtitle: "A starred agent gets a button beside the tabs’ +.") {
            VStack(spacing: 18) {
                FavoritesPicture(favorites: favorites)
                if !agents.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                        ForEach(agents, id: \.key) { agent in
                            chip(agent)
                        }
                    }
                } else if found == nil {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 34)
                } else {
                    Text("Swiftr found no agent on this Mac. Once you install one, the + lists it.")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 34)
                }
                if found == nil || agents.contains(where: { ChatAgent(rawValue: $0.key) != nil }) {
                    VStack(spacing: 6) {
                        Text("They open as")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ChoiceTiles(selection: panes, choices: [.init(.terminal, "Terminal"), .init(.messages, "Messages")]) { mode in
                            MiniWindow(dark: scheme == .dark, theme: prefs.theme, tabBar: prefs.showsTabBar,
                                       content: mode == .terminal ? .claude : .messages)
                        }
                    }
                }
                Toggle(isOn: $prefs.agentNotifications) {
                    Label("Notify me when an agent needs me or is done", systemImage: "bell")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        // Which agents this Mac has; asked again once herdr-core answers.
        .task(id: model.link == .connected) { model.launcher.check("") }
    }

    /// How every agent's panes open; each agent's Settings pane sets its own.
    private var panes: Binding<PaneMode> {
        let prefs = model.prefs
        let shown = Programs.startable.lazy.compactMap { ChatAgent(rawValue: $0.key) }
            .first { model.launcher.installed(on: "")?.contains($0.rawValue) == true } ?? .claude
        return Binding(get: { prefs.panes(of: shown) }, set: { mode in
            for agent in ChatAgent.allCases { prefs.setPanes(mode, of: agent) }
        })
    }

    private func chip(_ agent: Programs.Program) -> some View {
        let favorite = model.prefs.isFavorite(agent: agent.key)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Button {
            withAnimation(.snappy(duration: 0.25)) { model.prefs.setFavorite(!favorite, agent: agent.key) }
        } label: {
            HStack(spacing: 8) {
                ProgramIcon(key: agent.key, size: 16)
                    .foregroundStyle(.secondary)
                Text(agent.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(favorite ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.quaternary.opacity(0.45), in: shape)
            .overlay { shape.strokeBorder(Color.accentColor.opacity(favorite ? 0.7 : 0), lineWidth: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.name)
        .accessibilityAddTraits(favorite ? .isSelected : [])
        .help(favorite ? "Remove from Favorites" : "Add to Favorites")
    }
}

// MARK: Dictation and voice

/// How a dictation goes, with the key to hold, and the models it runs on.
private struct DictationPage: View {
    var body: some View {
        Page(title: "Dictate your messages", subtitle: "Hold the key, speak, let go. What you say stays on this Mac.") {
            VStack(spacing: 10) {
                DictationFlow()
                RowBox {
                    modelRow(DictationCatalog.speech)
                    Divider().padding(.leading, 50)
                    modelRow(DictationCatalog.tidy)
                    Divider().padding(.leading, 50)
                    modelRow(DictationCatalog.vocabulary)
                }
                DownloadsNote()
            }
        }
        .dictationAccent()
    }

    private func modelRow(_ model: DictationModel) -> some View {
        DictationModelRow(model: model)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}

/// The voice models to read answers aloud with, each with its voices to hear.
private struct VoicePage: View {
    var body: some View {
        Page(title: "Hear the answers", subtitle: "The speaker under a message reads it aloud, in your Mac’s voices or one of these.") {
            VStack(spacing: 10) {
                // As tall as its rows; it scrolls only where they don't fit.
                ViewThatFits(in: .vertical) {
                    models
                    ScrollView { models }
                }
                DownloadsNote()
                    .padding(.bottom, 4)
            }
        }
        .onDisappear { SamplePlayer.shared.stop() }
    }

    private var models: some View {
        RowBox {
            ForEach(VoiceCatalog.models) { model in
                if model.id != VoiceCatalog.models.first?.id {
                    Divider().padding(.leading, 12)
                }
                VoiceModelRow(model: model)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
    }
}

private struct DownloadsNote: View {
    var body: some View {
        Text("Downloads go on while you use Swiftr. Settings has the rest.")
            .font(.callout)
            .foregroundStyle(.tertiary)
    }
}
