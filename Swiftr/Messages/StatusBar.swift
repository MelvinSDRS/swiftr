import HerdrKit
import SwiftUI

/// Under the field: the agent's usage, the branch, the keys, and the
/// person's own status line. The agent's settings are in the field, as in the
/// Codex app (`AgentChips`).
struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.codeFamily) private var codeFamily
    let feed: TranscriptFeed
    let status: AgentStatus?
    let size: Double

    var body: some View {
        let facts = feed.facts
        let agent = ChatAgent(feed.agent)
        let showsStatusLine = model.prefs.showsStatusLine(of: agent)
        let lines = showsStatusLine ? statusLines(feed.footer, facts: facts) : nil
        Group {
            if let usage = UsageShown(feed: feed, model: model) {
                // The usage beside the branch; the status line under them.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        UsageStrip(shown: usage, feed: feed, status: status, size: size)
                        Spacer(minLength: 8)
                        trailing(facts)
                    }
                    if let lines { statusLine(lines) }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    if let lines { statusLine(lines) } else { Spacer(minLength: 0) }
                    trailing(facts)
                }
            }
        }
        .font(.system(size: size * 0.8))
        .padding(.horizontal, 22)
        .padding(.bottom, 9)
        .contextMenu {
            if agent.hasStatusLine {
                Toggle("Show Status Line", isOn: Binding(get: { model.prefs.showsStatusLine(of: agent) },
                                                         set: { model.prefs.setShowsStatusLine($0, of: agent) }))
            }
            if let lines {
                Button("Copy Status Line") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
            }
            if agent.hasUsage {
                Toggle("Show Usage", isOn: Binding(get: { model.prefs.usage(of: agent).shown }, set: { shown in
                    var usage = model.prefs.usage(of: agent)
                    usage.shown = shown
                    model.prefs.setUsage(usage, of: agent)
                }))
            }
        }
    }

    // Not selectable: a right click on selectable text opens the text's own
    // menu, without the one below. Copy is in that one.
    private func statusLine(_ lines: [String]) -> some View {
        Text(lines.joined(separator: "\n"))
            .font(CodeFont.font(size * 0.74, family: codeFamily))
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .help(feed.isCodex ? "Codex's status line, as it draws it" : feed.isGemini ? "Gemini's footer, as it draws it" : "Your status line, as Claude Code draws it")
    }

    private func trailing(_ facts: SessionFacts) -> some View {
        HStack(spacing: 6) {
            if let branch = facts.gitBranch, !branch.isEmpty, branch != "HEAD" {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help("Git branch")
            }
            KeysButton(agent: feed.agent, name: feed.agentName, size: size)
            QuitButton(feed: feed, size: size)
        }
        .fixedSize()
    }

    /// OpenCode's line under its input says what the chips say; Codex's
    /// says it too, but for what the person added to it.
    private func statusLines(_ footer: ClaudeFooter?, facts: SessionFacts) -> [String]? {
        guard !feed.isOpenCode, let shown = footer?.statusLine else { return nil }
        let lines = feed.isCodex ? CodexScreen.statusExtras(shown, model: facts.model ?? footer?.model) : shown
        return lines.isEmpty ? nil : lines
    }
}

/// The agent's settings in the field, as the Codex app has them: its mode
/// and the context left on the left (`.leading`), its model and effort on
/// the right (`.trailing`). Each is a menu to change it.
struct AgentChips: View {
    let feed: TranscriptFeed
    let status: AgentStatus?
    let size: Double
    let side: HorizontalEdge

    var body: some View {
        let facts = feed.facts
        let footer = feed.footer
        let idle = status.map { $0.state != "working" && $0.state != "blocked" } ?? false
        let left = side == .leading
        HStack(spacing: 1) {
            if feed.isCodex {
                CodexChips(feed: feed, facts: facts, footer: footer, idle: idle, left: left)
            } else if feed.isOpenCode {
                OpenCodeChips(feed: feed, facts: facts, footer: footer, idle: idle, blocked: status?.state == "blocked", left: left)
            } else if feed.isGemini {
                GeminiChips(feed: feed, facts: facts, footer: footer, idle: idle, blocked: status?.state == "blocked", left: left)
            } else if left {
                ModeChip(feed: feed, mode: footer?.mode ?? facts.permissionMode ?? "default", idle: idle, size: size)
                if let used = facts.contextTokens ?? (feed.nothingSent ? 0 : nil) {
                    ContextChip(feed: feed, used: used, model: facts.model ?? footer?.headerModel, idle: idle, size: size)
                }
                if let goal = facts.activeGoal {
                    GoalChip(feed: feed, goal: goal, idle: idle, size: size)
                }
                let running = feed.runningInBackground
                if !running.isEmpty {
                    BackgroundChip(feed: feed, tasks: running, idle: idle, size: size)
                }
            } else {
                // A new session's header names them until an answer does.
                // Each opens Claude's own menu, its card over the chip.
                if let model = facts.model ?? footer?.headerModel {
                    MenuChip(feed: feed, kind: .model, text: ClaudeModel.displayName(model), help: "Model: \(model)", strong: true, idle: idle, size: size)
                }
                if let effort = footer?.effort ?? facts.effort ?? footer?.headerEffort {
                    MenuChip(feed: feed, kind: .effort, text: effort.prefix(1).uppercased() + effort.dropFirst(), help: "Effort", chevron: true, idle: idle, size: size)
                }
            }
        }
        .font(.system(size: size * 0.92))
    }
}

extension TranscriptFeed {
    /// Nothing sent to the model yet: a new conversation, or one just
    /// cleared. Its context is all left; no answer names the model yet.
    var nothingSent: Bool {
        facts.contextTokens == nil && (phase == .empty || phase == .ready)
    }
}

/// A small menu in the field: its words, soft until the pointer is on it.
private struct Chip<Items: View>: View {
    let symbol: String?
    let text: String
    let help: String
    var tint: Color?
    var strong = false
    var chevron = false
    var detail: String?
    @ViewBuilder let items: Items
    @State private var hovering = false

    var body: some View {
        Menu {
            items
        } label: {
            ChipLabel(symbol: symbol, text: text, tint: tint, strong: strong, chevron: chevron, detail: detail, lit: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A chip's words: soft until lit.
private struct ChipLabel: View {
    let symbol: String?
    let text: String
    var tint: Color?
    /// The model's name reads as the field's text; the rest is softer.
    var strong = false
    /// A chevron after it, as the Codex app's model menu has.
    var chevron = false
    /// Softer words after `text`: the effort after the model.
    var detail: String?
    /// Under the pointer, or its popover open.
    let lit: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(tint.map { AnyShapeStyle(.readable($0)) } ?? (strong || lit ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(lit ? 0.07 : 0), in: .capsule)
        .contentShape(.capsule)
    }
}

/// A chip that opens one of Claude Code's own menus (`/model`, `/effort`),
/// its card in a popover over the chip: the command, a click away.
private struct MenuChip: View {
    @Environment(AppModel.self) private var model
    let feed: TranscriptFeed
    let kind: ClaudeMenuKind
    let text: String
    let help: String
    var strong = false
    var chevron = false
    let idle: Bool
    let size: Double
    @State private var hovering = false

    var body: some View {
        let menus = feed.menus
        let open = menus.inPopover == kind
        Button {
            menus.openInPopover(kind)
        } label: {
            ChipLabel(symbol: nil, text: text, strong: strong, chevron: chevron, lit: hovering || open)
        }
        .buttonStyle(.plain)
        // Not while another of Claude's menus shows: the command would go into it.
        .disabled(!open && (!idle || feed.acting || menus.kind != nil || feed.dialog != nil))
        .fixedSize()
        .onHover { hovering = $0 }
        .help(idle ? "\(help) · \(kind.command)" : "\(help) · change it once \(feed.agentName) is done")
        // Outside `disabled`: the card in it stays live.
        .popover(isPresented: Binding(get: { menus.inPopover == kind }, set: { if !$0 { menus.popoverClosed(kind) } }), arrowEdge: .top) {
            ClaudeMenuCard(feed: feed, kind: kind, size: size, focusedPane: true) {
                menus.leavePopover()
                model.setPaneMode(.terminal, for: feed.address)
            }
            .environment(\.cardInPopover, true)
            .frame(width: size * 32)
        }
        // The pane shows its terminal: Claude's menu is there to see.
        .onChange(of: feed.paneShowsMessages) { _, shown in
            if !shown, menus.inPopover == kind { menus.leavePopover() }
        }
    }
}

/// Runs a slash command in Claude, as if typed.
@MainActor private func run(_ feed: TranscriptFeed, _ command: String) {
    Task { try? await feed.send(command) }
}

private struct ModeChip: View {
    let feed: TranscriptFeed
    let mode: String
    let idle: Bool
    let size: Double

    /// The modes Shift-Tab goes through, in its order.
    static let modes: [(id: String, name: String, symbol: String)] = [
        ("default", "Manual", "hand.raised"),
        ("acceptEdits", "Accept Edits", "pencil.and.list.clipboard"),
        ("plan", "Plan", "list.bullet.clipboard"),
        ("auto", "Auto", "bolt"),
    ]

    static func name(_ mode: String) -> String {
        switch mode {
        case "bypassPermissions": "Bypass Permissions"
        case "dontAsk": "Don't Ask"
        default: modes.first { $0.id == mode }?.name ?? mode
        }
    }

    static func symbol(_ mode: String) -> String {
        switch mode {
        case "bypassPermissions": "exclamationmark.shield"
        case "dontAsk": "bolt.badge.checkmark"
        default: modes.first { $0.id == mode }?.symbol ?? "hand.raised"
        }
    }

    var body: some View {
        let key = feed.modeKey
        Chip(symbol: Self.symbol(mode), text: Self.name(mode), help: "Permission mode", tint: mode == "default" ? nil : mode == "plan" ? .purple : .orange) {
            ForEach(Self.modes, id: \.id) { m in
                Button {
                    if let key {
                        Task { try? await feed.setMode(m.id, key: key) }
                    } else if m.id == "plan" {
                        run(feed, "/plan")
                    }
                } label: {
                    Label(m.name, systemImage: m.id == mode ? "checkmark" : m.symbol)
                }
                .disabled(feed.acting || (key == nil && !(m.id == "plan" && idle)))
            }
            if key == nil {
                Divider()
                Text("Shift-Tab has another job in your Claude Code keybindings.")
                Text("Bind a key to chat:cycleMode to switch modes from here.")
            }
        }
    }
}

struct ContextChip: View {
    let feed: TranscriptFeed
    let used: Int
    let model: String?
    let idle: Bool
    let size: Double

    var body: some View {
        let window = ClaudeModel.contextWindow(model, used: used)
        let left = max(0, 1 - Double(used) / Double(window))
        let percent = Int((left * 100).rounded())
        let tint: Color? = left < 0.1 ? .red : left < 0.2 ? .orange : nil
        Chip(symbol: "circle.lefthalf.filled", text: "\(percent)% left", help: used == 0 ? Self.nothingSent : "Context: \(Self.tokens(used)) of \(Self.tokens(window)) tokens used", tint: tint) {
            Button("Compact Now") { run(feed, "/compact") }
                .disabled(!idle)
            Button("Show Context Use") { run(feed, "/context") }
                .disabled(!idle)
        }
    }

    static let nothingSent = "Context: nothing sent yet"

    /// OpenCode's and Gemini's context left and its words, from what the
    /// last reply used of the model's window; all of it while nothing was sent.
    static func left(_ facts: SessionFacts, feed: TranscriptFeed) -> (Double, String)? {
        if let used = facts.contextTokens, let window = facts.contextWindow, window > 0 {
            return (max(0, 1 - Double(used) / Double(window)), "Context: \(tokens(used)) of \(tokens(window)) tokens used")
        }
        return feed.nothingSent ? (1, nothingSent) : nil
    }

    /// 1.2k, 262k, 2.5M.
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

/// The goal Claude works toward (`/goal`): what it is, what the last check
/// said, and a way to clear it.
private struct GoalChip: View {
    let feed: TranscriptFeed
    let goal: GoalStatus
    let idle: Bool
    let size: Double
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "target")
                Text("Goal")
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Goal: \(goal.condition)")
        .popover(isPresented: $shown, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Goal", systemImage: "target")
                    .font(.system(size: size * 0.95, weight: .semibold))
                Text(goal.condition)
                    .font(.system(size: size * 0.9))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if goal.state == .notMet, let reason = goal.reason {
                    Divider()
                    Text("Last check: not met yet")
                        .font(.system(size: size * 0.8, weight: .medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        MarkdownView(reason, size: size * 0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Claude Code checks it each time Claude would stop, and sends Claude back to work until it is met.")
                        .font(.system(size: size * 0.8))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if !idle {
                        Text("Stop Claude first.")
                            .font(.system(size: size * 0.8))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear Goal") {
                        shown = false
                        run(feed, "/goal clear")
                    }
                    .disabled(!idle || feed.acting)
                }
            }
            .padding(14)
            .frame(width: 380)
        }
    }
}

// MARK: - Codex

/// Codex's settings: Plan mode, permissions, model and effort, context
/// left. Each opens Codex's own menu for it.
private struct CodexChips: View {
    let feed: TranscriptFeed
    let facts: SessionFacts
    /// Its status line: the model and effort in a new chat.
    let footer: ClaudeFooter?
    let idle: Bool
    /// The chips of the field's left side, else its right side's.
    let left: Bool

    var body: some View {
        if left {
            leading
        } else if let model = facts.model ?? footer?.model {
            let effort = facts.model != nil ? facts.effort : footer?.effort
            Chip(symbol: nil, text: model, help: "Model and reasoning effort", strong: true, chevron: true, detail: effort.map { $0.prefix(1).uppercased() + $0.dropFirst() }) {
                Button("Choose…") { run(feed, "/model") }
                    .disabled(!idle)
            }
        }
    }

    @ViewBuilder private var leading: some View {
        if facts.collaborationMode == "plan" {
            Chip(symbol: "list.bullet.clipboard", text: "Plan", help: "Plan mode: Codex plans before it changes anything", tint: .purple) {
                Text("Codex leaves Plan mode when you accept its plan.")
            }
        }
        if let p = Self.permissions(facts) {
            Chip(symbol: p.symbol, text: p.name, help: "Permissions: \(p.detail)", tint: p.tint) {
                Button("Choose…") { run(feed, "/permissions") }
                    .disabled(!idle)
                Divider()
                Text(p.detail)
            }
        }
        if let (left, help) = context {
            let percent = Int((left * 100).rounded())
            Chip(symbol: "circle.lefthalf.filled", text: "\(percent)% left", help: help,
                 tint: left < 0.1 ? .red : left < 0.2 ? .orange : nil) {
                Button("Compact Now") { run(feed, "/compact") }
                    .disabled(!idle)
            }
        }
    }

    /// The context left and its words; all of it in a new chat.
    private var context: (Double, String)? {
        if let used = facts.contextTokens, let window = facts.contextWindow {
            return (Self.contextLeft(used: used, window: window), "Context: \(ContextChip.tokens(used)) of \(ContextChip.tokens(window)) tokens used")
        }
        return feed.nothingSent ? (1, ContextChip.nothingSent) : nil
    }

    /// As Codex counts it: its own instructions, about 12,000 tokens, left
    /// out of what is used and of the room there is.
    static func contextLeft(used: Int, window: Int) -> Double {
        let baseline = 12_000
        let room = max(1, window - baseline)
        return max(0, min(1, 1 - Double(max(0, used - baseline)) / Double(room)))
    }

    /// The permissions preset the sandbox and approval settings make, as
    /// Codex's `/permissions` names and describes it.
    static func permissions(_ f: SessionFacts) -> (name: String, symbol: String, detail: String, tint: Color?)? {
        switch f.sandbox {
        case "read-only":
            return ("Read Only", "lock", "Read workspace files, with approval required for edits or internet access", nil)
        case "danger-full-access":
            return ("Full Access", "exclamationmark.shield", "Codex can edit files outside this workspace and access the internet without approval", .orange)
        case "workspace-write":
            if f.reviewer == "auto_review" {
                return ("Approve for me", "checkmark.shield", "Only ask for actions detected as potentially unsafe", nil)
            }
            if f.permissionMode == "never" {
                return ("Custom", "folder", "Read and edit workspace files and run commands, never asking", nil)
            }
            return ("Ask for approval", "hand.raised", "Read and edit workspace files and run commands, with approval required for internet access or edits outside the workspace", nil)
        default:
            return nil
        }
    }
}

// MARK: - OpenCode

/// OpenCode's agent (Build, Plan…), model and variant, context left. Each
/// opens OpenCode's own picker for it; the agent chip also switches to the
/// next agent, as Shift-Tab does.
private struct OpenCodeChips: View {
    let feed: TranscriptFeed
    let facts: SessionFacts
    let footer: ClaudeFooter?
    let idle: Bool
    let blocked: Bool
    /// The chips of the field's left side, else its right side's.
    let left: Bool

    /// The model in use: as the screen names it, without its provider's
    /// name (`Flint 40B Free OpenCode`), else as the last reply names it.
    private var shownModel: String? {
        if let shown = footer?.model, !shown.isEmpty {
            if let provider = facts.providerName, shown.hasSuffix(" " + provider) { return String(shown.dropLast(provider.count + 1)) }
            return shown
        }
        return facts.modelName ?? facts.model
    }

    var body: some View {
        if left {
            leading
        } else if let model = shownModel {
            // Its screen shows no variant for the default one.
            let variant = footer != nil ? footer?.effort : facts.effort
            Chip(symbol: nil, text: model, help: "Model and variant", strong: true, chevron: true, detail: variant) {
                Button("Choose Model…") { run(feed, "/models") }
                    .disabled(!idle)
                Button("Choose Variant…") { run(feed, "/variants") }
                    .disabled(!idle)
            }
        }
    }

    @ViewBuilder private var leading: some View {
        if let agent = footer?.mode ?? facts.agent, !agent.isEmpty {
            let name = agent.prefix(1).uppercased() + agent.dropFirst()
            Chip(symbol: agent == "plan" ? "list.bullet.clipboard" : agent == "build" ? "hammer" : "person.crop.circle", text: name,
                 help: "OpenCode's agent", tint: agent == "plan" ? .purple : nil) {
                Button("Next Agent (⇧⇥)") { Task { try? await feed.nextAgent() } }
                    .disabled(blocked)
                Button("Choose…") { run(feed, "/agents") }
                    .disabled(!idle)
                Divider()
                Text(Self.about(agent))
            }
        }
        if let (left, help) = ContextChip.left(facts, feed: feed) {
            let percent = Int((left * 100).rounded())
            Chip(symbol: "circle.lefthalf.filled", text: "\(percent)% left", help: help,
                 tint: left < 0.1 ? .red : left < 0.2 ? .orange : nil) {
                Button("Compact Now") { run(feed, "/compact") }
                    .disabled(!idle)
            }
        }
    }

    static func about(_ agent: String) -> String {
        switch agent {
        case "build": "Build: uses every tool, as allowed"
        case "plan": "Plan: reads and plans, changes nothing"
        default: "One of your agents"
        }
    }
}

// MARK: - Gemini

/// Gemini's approval mode (Manual, Auto-Accept Edits, Plan, YOLO), its
/// model and the context left, each a menu.
private struct GeminiChips: View {
    let feed: TranscriptFeed
    let facts: SessionFacts
    let footer: ClaudeFooter?
    let idle: Bool
    let blocked: Bool
    /// The chips of the field's left side, else its right side's.
    let left: Bool

    /// Shift-Tab goes round the first three, in this order; ⌃Y turns YOLO on and off.
    static let modes: [(id: String, name: String, symbol: String, about: String)] = [
        ("default", "Manual", "hand.raised", "Asks before it edits a file or runs a command"),
        ("acceptEdits", "Auto-Accept Edits", "pencil.and.list.clipboard", "Edits files without asking"),
        ("plan", "Plan", "list.bullet.clipboard", "Reads and plans, changes nothing"),
        ("bypassPermissions", "YOLO", "exclamationmark.shield", "Runs every tool without asking"),
    ]

    var body: some View {
        if left {
            leading
        } else if let model = footer?.model ?? facts.model {
            // `Auto`: Gemini picks the model for each request; the last one used tells which.
            let used = facts.model.flatMap { $0 == model ? nil : $0 }
            Chip(symbol: nil, text: model, help: used.map { "Model: \(model), last \($0)" } ?? "Model: \(model)", strong: true, chevron: true) {
                Button("Choose…") { run(feed, "/model") }
                    .disabled(!idle)
                Button("Usage by Model") { run(feed, "/stats model") }
                    .disabled(!idle)
                if let used {
                    Divider()
                    Text("Last reply: \(used)")
                }
            }
        }
    }

    @ViewBuilder private var leading: some View {
        let mode = footer?.mode ?? "default"
        let shown = Self.modes.first { $0.id == mode } ?? Self.modes[0]
        Chip(symbol: shown.symbol, text: shown.name, help: "Approval mode: \(shown.about)", tint: mode == "default" ? nil : mode == "plan" ? .purple : .orange) {
            ForEach(Self.modes, id: \.id) { m in
                Button {
                    Task { try? await feed.setMode(m.id, key: "shift+tab") }
                } label: {
                    Label(m.name, systemImage: m.id == mode ? "checkmark" : m.symbol)
                }
                .disabled(feed.acting || blocked)
            }
            Divider()
            Text(shown.about)
        }
        if let (left, help) = ContextChip.left(facts, feed: feed) {
            let percent = Int((left * 100).rounded())
            Chip(symbol: "circle.lefthalf.filled", text: "\(percent)% left", help: help,
                 tint: left < 0.1 ? .red : left < 0.2 ? .orange : nil) {
                Button("Compress Now") { run(feed, "/compress") }
                    .disabled(!idle)
                Button("Session Stats") { run(feed, "/stats") }
                    .disabled(!idle)
            }
        }
    }
}

// MARK: - To-dos

/// Claude's to-do list over the field: what it does now and how far it is,
/// the whole list on click.
struct TodoStrip: View {
    let todos: [TodoItem]
    let size: Double
    /// ⌃T in the field opens and closes it too.
    @Binding var open: Bool

    var body: some View {
        let done = todos.filter { $0.status == .completed }.count
        let current = todos.first { $0.status == .inProgress }
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    ProgressRing(fraction: Double(done) / Double(max(todos.count, 1)), size: size)
                    Text(current.map { $0.active ?? $0.text } ?? (done == todos.count ? "All done" : "\(todos.count - done) to do"))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(done) of \(todos.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up")
                        .font(.system(size: size * 0.7, weight: .semibold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the to-do list (⌃T)" : "Show the to-do list (⌃T)")
            if open {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(todos) { todo in
                            Label {
                                Text(todo.text)
                                    .strikethrough(todo.status == .completed)
                                    .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                                    .fontWeight(todo.status == .inProgress ? .medium : .regular)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: todo.status == .completed ? "checkmark.circle.fill" : todo.status == .inProgress ? "circle.dotted.circle" : "circle")
                                    .foregroundStyle(todo.status == .completed ? Color.green : todo.status == .inProgress ? Color.accentColor : Color.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: size * 0.88))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .paneGlass(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }
}

private struct ProgressRing: View {
    let fraction: Double
    let size: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size * 0.95, height: size * 0.95)
        .animation(.smooth(duration: 0.3), value: fraction)
    }
}

/// What runs in the background, as Claude Code's `/tasks` lists it: in the
/// accent color, with a dot that pings while they run, so it shows at a
/// glance. A click lists each sub-agent and command.
private struct BackgroundChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let feed: TranscriptFeed
    let tasks: [BackgroundJob]
    let idle: Bool
    let size: Double
    @State private var shown = false
    @State private var hovering = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            HStack(spacing: 6) {
                LiveDot(diameter: size * 0.48, pings: !reduceMotion)
                Text("\(tasks.count) in background")
                    .fontWeight(.medium)
                    .lineLimit(1)
                Image(systemName: shown ? "chevron.down" : "chevron.up")
                    .font(.system(size: size * 0.6, weight: .bold))
                    .opacity(0.75)
            }
            .foregroundStyle(.tint)
            .padding(.leading, 8)
            .padding(.trailing, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(hovering || shown ? 0.22 : 0.13), in: .capsule)
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .padding(.leading, 3)
        .onHover { hovering = $0 }
        .help("In the background: \(BackgroundList.counts(tasks)). Click to see them.")
        .accessibilityLabel("\(tasks.count) in background: \(BackgroundList.counts(tasks))")
        .popover(isPresented: $shown, arrowEdge: .top) {
            BackgroundList(feed: feed, tasks: tasks, idle: idle, size: size) { shown = false }
        }
    }
}

/// A dot in the accent color, with a ring that grows out of it and fades,
/// over and over. Core Animation runs it, out of the app: a SwiftUI
/// animation in the field would make SwiftUI go over the whole
/// conversation on each frame (see `WorkingRow`).
private struct LiveDot: View {
    let diameter: Double
    let pings: Bool

    var body: some View {
        RenderStandIn {
            LiveDotLayer(pings: pings)
        } standIn: {
            Circle().fill(.tint)
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct LiveDotLayer: NSViewRepresentable {
    let pings: Bool

    func makeNSView(context: Context) -> LiveDotView {
        LiveDotView()
    }

    func updateNSView(_ view: LiveDotView, context: Context) {
        view.show(color: Color.accentColor.resolve(in: context.environment).cgColor, pings: pings)
    }
}

final class LiveDotView: NSView {
    private let ring = CALayer()
    private let dot = CALayer()
    private var pings = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.opacity = 0
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(color: CGColor, pings: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = color
        ring.backgroundColor = color
        CATransaction.commit()
        self.pings = pings
        ping()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for circle in [ring, dot] {
            circle.frame = bounds
            circle.cornerRadius = min(bounds.width, bounds.height) / 2
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ping()
    }

    private func ping() {
        guard pings else {
            ring.removeAnimation(forKey: "ping")
            return
        }
        guard window != nil, ring.animation(forKey: "ping") == nil else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55
        fade.toValue = 0
        let both = CAAnimationGroup()
        both.animations = [grow, fade]
        both.duration = 1.4
        // A pause between pings.
        let cycle = CAAnimationGroup()
        cycle.animations = [both]
        cycle.duration = 2.2
        cycle.repeatCount = .infinity
        both.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(cycle, forKey: "ping")
    }

    /// Nothing here to click: clicks go to the chip.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The chip's popover: each sub-agent and command, how long it has run, a
/// click to see where it started; Claude Code's task list, and a way to
/// stop the sub-agents.
private struct BackgroundList: View {
    @Environment(\.codeFamily) private var codeFamily
    let feed: TranscriptFeed
    let tasks: [BackgroundJob]
    let idle: Bool
    let size: Double
    let close: () -> Void
    @State private var hovered: String?
    @State private var confirming = false

    /// "2 sub-agents, 1 command".
    static func counts(_ tasks: [BackgroundJob]) -> String {
        let agents = tasks.filter { $0.kind == .agent }.count
        let commands = tasks.count - agents
        return [agents == 0 ? nil : agents == 1 ? "1 sub-agent" : "\(agents) sub-agents",
                commands == 0 ? nil : commands == 1 ? "1 command" : "\(commands) commands"]
            .compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        let subAgents = tasks.filter { $0.kind == .agent }
        let commands = tasks.filter { $0.kind != .agent }
        let both = !subAgents.isEmpty && !commands.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
            ScrollView {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        section(both ? "Sub-agents" : nil, subAgents, now: context.date)
                        section(both ? "Commands" : nil, commands, now: context.date)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: size * 26)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
        }
        .frame(width: size * 28)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 7) {
                Text("Background Tasks")
                    .font(.system(size: size * 1.02, weight: .semibold))
                Text("\(tasks.count)")
                    .font(.system(size: size * 0.75, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: .capsule)
            }
            Text("\(feed.agentName) goes on while these run. Click one to see where it started.")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func section(_ title: String?, _ list: [BackgroundJob], now: Date) -> some View {
        if !list.isEmpty {
            if let title {
                Text(title)
                    .font(.system(size: size * 0.75, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
            ForEach(list) { task in
                Button {
                    NotificationCenter.default.post(name: .swiftrReveal, object: feed.address, userInfo: ["call": task.id])
                    close()
                } label: {
                    row(task, now: now)
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? task.id : hovered == task.id ? nil : hovered }
                .help("Show where \(feed.agentName) started it")
            }
        }
    }

    private func row(_ task: BackgroundJob, now: Date) -> some View {
        let agent = task.kind == .agent
        let tint: Color = agent ? .purple : .blue
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: agent ? "person.2.fill" : "apple.terminal.fill")
                .font(.system(size: size * 0.78, weight: .medium))
                .foregroundStyle(.readable(tint))
                .frame(width: size * 2, height: size * 2)
                .background(tint.opacity(0.15), in: .rect(cornerRadius: size * 0.5))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.title)
                        .font(.system(size: size * 0.92, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if let started = task.started {
                        Text(TurnHeader.duration(Int(max(0, now.timeIntervalSince1970 - started) * 1000)))
                            .font(.system(size: size * 0.78).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                // The sub-agent's type: Explore, general-purpose…
                if agent, let type = task.detail, type != task.title {
                    Text(type)
                        .font(.system(size: size * 0.8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !agent, let command = task.detail, command != task.title {
                    Text(command)
                        .font(CodeFont.font(size * 0.76, family: codeFamily))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 6))
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: size * 0.65, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovered == task.id ? 1 : 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(hovered == task.id ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 9))
        .contentShape(.rect)
    }

    /// Sub-agents among them: Claude Code stops those at ⌃X ⌃K.
    private var agents: Int {
        feed.agent == .claude ? tasks.filter { $0.kind == .agent }.count : 0
    }

    @ViewBuilder private var footer: some View {
        if confirming {
            // Asked twice, as Claude Code asks for ⌃X ⌃K twice.
            VStack(alignment: .leading, spacing: 9) {
                Label {
                    Text(agents == 1 ? "Stop the sub-agent?" : "Stop \(agents) sub-agents?")
                        .font(.system(size: size * 0.9, weight: .semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.readable(.orange))
                }
                Text(agents == 1 ? "What it found so far is lost. Commands keep running." : "What they found so far is lost. Commands keep running.")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") { confirming = false }
                    Button {
                        Task { try? await feed.stopBackgroundAgents() }
                        close()
                    } label: {
                        Text(agents == 1 ? "Stop Sub-agent" : "Stop \(agents) Sub-agents")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    if agents > 0 {
                        Button {
                            confirming = true
                        } label: {
                            Label(agents == 1 ? "Stop Sub-agent…" : "Stop Sub-agents…", systemImage: "stop.circle")
                        }
                        .fixedSize()
                        .help("Claude Code's ⌃X ⌃K, twice: its sub-agents in the background stop")
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { try? await feed.send("/tasks") }
                        close()
                    } label: {
                        Label("Task List", systemImage: "list.bullet.rectangle")
                    }
                    .fixedSize()
                    .disabled(!idle)
                    .help(idle ? "Runs /tasks: Claude Code's list shows each task's output and can stop it" : "Opens once \(feed.agentName) is done")
                }
                if !idle {
                    Text("The task list opens once \(feed.agentName) is done.")
                        .font(.system(size: size * 0.78))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Quits the agent, as ⌃C twice in an empty field does; asked first, in a
/// popover, as a click can't be taken back.
private struct QuitButton: View {
    @Environment(AppModel.self) private var model
    let feed: TranscriptFeed
    let size: Double
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "power")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Quit \(feed.agentName) (⌃C twice in an empty field)")
        .popover(isPresented: $shown, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Quit \(feed.agentName)?")
                    .font(.system(size: size * 0.95, weight: .semibold))
                Text("\(feed.agentName) ends in this terminal, even while it works, and the pane goes back to the terminal. The conversation stays saved.")
                    .font(.system(size: size * 0.85))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") { shown = false }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        shown = false
                        Task {
                            try? await feed.quit()
                            model.requestFocus()
                        }
                    } label: {
                        Text("Quit").foregroundStyle(.red)
                    }
                }
            }
            .padding(14)
            .frame(width: size * 22)
        }
    }
}

/// The keys the Messages view knows, in a popover from the status bar.
private struct KeysButton: View {
    let agent: TranscriptFeed.Agent
    let name: String
    let size: Double
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Keyboard shortcuts")
        .popover(isPresented: $shown, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Keyboard Shortcuts")
                    .font(.system(size: size * 0.95, weight: .semibold))
                // One grid, so the keys line up from section to section.
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    section("In the field", rows)
                    section("When \(name) asks", [
                        ("1 – 9", "Choose that answer"),
                        ("Esc", "Cancel, or say no"),
                    ])
                    section("Conversation", [
                        ("⌘F", "Find in the conversation"),
                        ("⌘G  ⇧⌘G", "Next and previous match"),
                        ("⇧⌘M", "Show the terminal instead"),
                    ])
                }
            }
            .padding(14)
            .fixedSize()
        }
    }

    private var rows: [(String, String)] {
        var out: [(String, String)] = [
            ("↩", "Send"),
            ("⇧↩  ⌥↩", "New line"),
            ("Esc", "Stop \(name) while it works"),
            ("⌃C", "Stop \(name) while it works, else clear the field"),
            ("⌃C ⌃C", "Quit \(name), from an empty field"),
        ]
        if agent != .opencode { out.append(("Esc Esc", "Go back to an earlier message")) }
        out += [
            ("↑  ↓", "Your earlier messages"),
            ("⌃R", "Search your earlier messages"),
            ("⌃O", "Show or hide every step's details"),
            ("⌃T", "Show or hide the to-do list"),
            ("⌃S", "Set the draft aside; it comes back after you send"),
            ("Tab", "Complete a command or file"),
            ("⇧Tab", agent == .opencode ? "OpenCode's next agent" : agent == .gemini ? "Gemini's next mode" : "\(name)'s next mode, or what you bound it to"),
            ("/", "Commands"),
            ("@", "Files"),
        ]
        if agent != .opencode, agent != .gemini { out.append(("!", "A shell command")) }
        out.append(("⌃L", "Clear the field (⌘Z brings the text back)"))
        out.append(("⌃G", "Write the message in your text editor; each save comes back here"))
        out.append(("⌥P", agent == .claude ? "Pick the model, in an empty field" : "Pick the model, in an empty field, between turns"))
        if agent == .claude {
            out.append(("⌃B", "Send the command or agent running to the background"))
            out.append(("⌃X ⌃S", "Send the waiting message now"))
            out.append(("⌃X ⌃K ×2", "Stop the agents running in the background"))
            out.append(("Tab  →", "Take Claude's suggestion, in an empty field"))
            out.append(("⌥T", "Thinking on or off"))
            out.append(("⌥O", "Fast mode on or off, in an empty field"))
            out.append(("⌃X ↩", "While Claude works: Claude Code's queue key (as ↩: Claude reads it once its steps under way end)"))
        }
        if agent == .gemini {
            out.append(("⌃Y", "YOLO mode on or off: Gemini runs every tool without asking"))
        }
        if agent == .codex {
            out.append(("Tab", "While Codex works: send after this turn, not now"))
            out.append(("⌥,  ⌥.", "Codex reasons less or more"))
        }
        out.append(("⌘V", "Paste a picture, or drop one"))
        return out
    }

    @ViewBuilder private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: size * 0.78, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .gridCellColumns(2)
        }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            GridRow {
                Text(row.0)
                    .font(.system(size: size * 0.82, weight: .medium).monospaced())
                    .gridColumnAlignment(.trailing)
                Text(row.1)
                    .font(.system(size: size * 0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: size * 19, alignment: .leading)
            }
        }
    }
}
