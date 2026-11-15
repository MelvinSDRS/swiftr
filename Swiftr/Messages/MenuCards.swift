import HerdrKit
import SwiftUI

// MARK: - Pieces shared by the cards

/// A row of a card that a click acts on: no fill at rest, a faint one
/// under the pointer or Claude's cursor, the accent's once chosen.
struct CardRowStyle: ButtonStyle {
    /// Chosen: a ticked box, the answer given.
    var selected = false
    /// Claude's cursor is on it: Enter there would take it.
    var focused = false

    func makeBody(configuration: Configuration) -> some View {
        CardRowBody(configuration: configuration, selected: selected, focused: focused)
    }
}

private struct CardRowBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    let focused: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.themeAccent) private var themeAccent
    @State private var hovering = false

    var body: some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var fill: Color {
        let accent = themeAccent ?? .accentColor
        if selected { return accent.opacity(configuration.isPressed ? 0.3 : 0.2) }
        if configuration.isPressed { return Color.primary.opacity(0.11) }
        if hovering, enabled { return Color.primary.opacity(0.07) }
        return focused ? Color.primary.opacity(0.06) : .clear
    }
}

/// The key that picks a row on the agent's screen (`1`), drawn as a key:
/// filled with the accent where Claude's cursor is.
struct CardKeyCap: View {
    let key: String
    let size: Double
    var active = false
    @Environment(\.themeAccent) private var themeAccent

    var body: some View {
        let accent = themeAccent ?? .accentColor
        Text(key)
            .font(.system(size: size * 0.7, weight: .semibold).monospacedDigit())
            .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .frame(minWidth: size * 1.4, minHeight: size * 1.4)
            .background(active ? AnyShapeStyle(accent) : AnyShapeStyle(Color.primary.opacity(0.07)), in: .rect(cornerRadius: size * 0.34))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.34)
                    .strokeBorder(Color.primary.opacity(active ? 0 : 0.14), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// What kind a card is, at its top left: a symbol on a tinted tile.
struct CardBadge: View {
    let symbol: String
    let tint: Color
    let size: Double

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.82, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(.readable(tint))
            .frame(width: size * 1.8, height: size * 1.8)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: size * 0.48))
            .accessibilityHidden(true)
    }
}

/// AskUserQuestion's questions as steps, one pill each, as Claude's
/// screen has one tab each: ticked once answered, Submit last. The step
/// shown stands out when the card knows it; a click on a pill goes there
/// when the card can (`select`).
struct StepPills: View {
    struct Step: Equatable {
        var title: String
        var answered: Bool
        var isSubmit = false
    }

    let steps: [Step]
    /// The step shown; nil when the card can't tell.
    var current: Int?
    let size: Double
    var select: ((Int) -> Void)?
    @Environment(\.themeAccent) private var themeAccent

    /// Claude's tabs, as its screen shows them; `current`, the one open.
    init(tabs: [ScreenPrompt.Tab], current: Int? = nil, size: Double) {
        steps = tabs.map { Step(title: $0.title, answered: $0.answered, isSubmit: $0.isSubmit) }
        self.current = current
        self.size = size
    }

    init(steps: [Step], current: Int?, size: Double, select: ((Int) -> Void)? = nil) {
        self.steps = steps
        self.current = current
        self.size = size
        self.select = select
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                if let select {
                    Button { select(i) } label: { pill(step, here: i == current) }
                        .buttonStyle(.plain)
                        .help(step.isSubmit ? "Your answers, to send" : "Go to this question")
                } else {
                    pill(step, here: i == current)
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: current)
    }

    private func pill(_ step: Step, here: Bool) -> some View {
        let accent = themeAccent ?? .accentColor
        return HStack(spacing: 4) {
            Image(systemName: step.isSubmit ? "paperplane" : step.answered ? "checkmark.circle.fill" : "circle")
            Text(step.title)
                .lineLimit(1)
        }
        .font(.system(size: size * 0.76, weight: here ? .semibold : .medium))
        .foregroundStyle(here ? AnyShapeStyle(.primary) : step.answered ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(step.answered ? accent.opacity(here ? 0.2 : 0.12) : Color.primary.opacity(here ? 0.1 : 0.05), in: .capsule)
        .overlay {
            if here {
                Capsule().strokeBorder(accent.opacity(0.55), lineWidth: 1)
            }
        }
        .contentShape(.capsule)
        .accessibilityElement(children: .combine)
        .accessibilityValue(step.answered ? "Answered" : "")
        .accessibilityAddTraits(here ? .isSelected : [])
    }
}

// MARK: - Pieces of the menu cards

/// A key as a card's hints and buttons name it: `↩`, `esc`, `⌃A`.
struct KeyChip: View {
    let key: String
    let size: Double
    /// On a prominent button: drawn in its words' color.
    var onAccent = false

    var body: some View {
        Text(key)
            .font(.system(size: size * 0.66, weight: .semibold, design: .rounded))
            .foregroundStyle(onAccent ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            .padding(.horizontal, size * 0.28)
            .frame(minWidth: size * 1.3, minHeight: size * 1.3)
            .background(onAccent ? Color.white.opacity(0.16) : Color.primary.opacity(0.07), in: .rect(cornerRadius: size * 0.3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(onAccent ? Color.white.opacity(0.2) : Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// A card's button words, with the key that does the same.
struct KeyedLabel: View {
    let title: String
    let key: String
    let size: Double
    var onAccent = false

    var body: some View {
        HStack(spacing: size * 0.45) {
            Text(title)
            KeyChip(key: key, size: size, onAccent: onAccent)
        }
    }
}

/// Keys and what they do, at a card's foot: `↑ ↓ Move`. As many as fit.
struct MenuHints: View {
    let hints: [(keys: [String], label: String)]
    let size: Double

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: hints.count, through: 1, by: -1)), id: \.self) { n in
                row(Array(hints.prefix(n)))
            }
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func row(_ shown: [(keys: [String], label: String)]) -> some View {
        HStack(spacing: size * 0.9) {
            ForEach(shown.indices, id: \.self) { i in
                HStack(spacing: size * 0.22) {
                    ForEach(shown[i].keys, id: \.self) { KeyChip(key: $0, size: size) }
                    Text(shown[i].label)
                        .font(.system(size: size * 0.76))
                        .foregroundStyle(.secondary)
                        .padding(.leading, size * 0.15)
                }
                .fixedSize()
            }
        }
    }
}

/// The keyboard on a menu's card while it shows: its keys as in Claude's
/// menu (`ClaudeMenuDriver.key`). The field takes it back once the card goes.
struct MenuKeys: ViewModifier {
    let feed: TranscriptFeed
    let focusedPane: Bool
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var held = false

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in
                guard let name = Self.name(of: press), feed.menus.key(name) else { return .ignored }
                return .handled
            }
            .onAppear(perform: take)
            // Shown again without leaving the window (`ConversationContainer`).
            .onChange(of: feed.shows) { take() }
            .onChange(of: focused) { _, now in if now { held = true } }
            .onDisappear { if held { model.requestFocus() } }
    }

    private func take() {
        if focusedPane, feed.isShown { focused = true }
    }

    /// A key as `ClaudeMenuDriver.key` names it; nil for the others.
    static func name(of press: KeyPress) -> String? {
        let mods = press.modifiers.intersection([.shift, .control, .option, .command])
        switch press.key {
        case .leftArrow: return mods.isEmpty ? "left" : nil
        case .rightArrow: return mods.isEmpty ? "right" : nil
        case .upArrow: return mods.isEmpty ? "up" : nil
        case .downArrow: return mods.isEmpty ? "down" : nil
        case .return: return mods.isEmpty ? "enter" : nil
        case .escape: return "esc"
        case .tab: return mods.isEmpty ? "tab" : nil
        default: break
        }
        let c = press.characters.lowercased()
        if mods == .control, c == "a" || c == "\u{01}" { return "ctrl+a" }
        if mods == .control, c == "b" || c == "\u{02}" { return "ctrl+b" }
        if mods.isEmpty, c == "s" { return "s" }
        return nil
    }
}

/// A row of a menu's list that a click acts on: a faint fill under the
/// pointer; the one Claude's cursor is on carries the card's sliding mark.
struct PickListRow<Content: View>: View {
    let marked: Bool
    let mark: Namespace.ID
    let size: Double
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, size * 0.8)
            .padding(.vertical, size * 0.55)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if marked {
                    RoundedRectangle(cornerRadius: size * 0.8, style: .continuous)
                        .fill(Color.primary.opacity(0.085))
                        .overlay {
                            RoundedRectangle(cornerRadius: size * 0.8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                        }
                        .matchedGeometryEffect(id: "cursor", in: mark)
                } else if hovering {
                    RoundedRectangle(cornerRadius: size * 0.8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }
            }
            .contentShape(.rect(cornerRadius: size * 0.8))
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

/// Rows to come while Claude's menu opens.
struct SkeletonRows: View {
    let count: Int
    let size: Double

    var body: some View {
        VStack(alignment: .leading, spacing: size * 1.05) {
            ForEach(0 ..< count, id: \.self) { i in
                VStack(alignment: .leading, spacing: size * 0.4) {
                    Capsule().frame(width: size * [14, 10, 12, 8][i % 4], height: size * 0.62)
                    Capsule().frame(width: size * [9, 7, 8, 6][i % 4], height: size * 0.46).opacity(0.6)
                }
            }
        }
        .foregroundStyle(Color.primary.opacity(0.07))
        .padding(.horizontal, size * 0.8)
        .padding(.vertical, size * 0.55)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Opening")
    }
}

/// Effort levels as the steps of a stair, low to high, lit up to the
/// level: a click or a drag across them picks one. `compact`: in a
/// model's row of the picker, without the names.
struct EffortStairs: View {
    let levels: [String]
    /// Nil while not known: the menu is opening.
    let level: Int?
    let size: Double
    var compact = false
    let pick: (Int) -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var width = 0.0
    @State private var hover: Int?
    @State private var pressed = false

    private var count: Int { max(levels.count, 1) }

    /// Each level's own color, from a calm yellow to a hot magenta.
    static func tint(_ i: Int, of count: Int) -> Color {
        let stops: [(Double, Double, Double)] = [
            (0.98, 0.80, 0.24), (0.99, 0.62, 0.18), (0.98, 0.45, 0.20), (0.93, 0.29, 0.29), (0.85, 0.27, 0.62),
        ]
        let part = count > 1 ? min(max(Double(i) / Double(count - 1), 0), 1) : 0.5
        let at = part * Double(stops.count - 1)
        let lo = Int(at.rounded(.down)), hi = min(lo + 1, stops.count - 1)
        let f = at - Double(lo)
        let a = stops[lo], b = stops[hi]
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }

    var body: some View {
        VStack(spacing: size * 0.55) {
            HStack(alignment: .bottom, spacing: compact ? size * 0.16 : size * 0.38) {
                ForEach(0 ..< count, id: \.self) { i in
                    step(i)
                }
            }
            .frame(height: height(count - 1), alignment: .bottom)
            if !compact {
                HStack(spacing: size * 0.38) {
                    ForEach(0 ..< count, id: \.self) { i in
                        Text(levels.indices.contains(i) ? levels[i] : "")
                            .font(.system(size: size * 0.82, weight: i == level ? .semibold : .regular))
                            .foregroundStyle(i == level ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .contentShape(.rect)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !pressed { pressed = true }
                    choose(at: value.location.x)
                }
                .onEnded { _ in pressed = false }
        )
        .onContinuousHover { phase in
            let now: Int? = if case .active(let at) = phase { index(at: at.x) } else { nil }
            if hover != now { hover = now }
        }
        .animation(.snappy(duration: 0.24), value: level)
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityElement()
        .accessibilityLabel("Effort")
        .accessibilityValue(level.flatMap { levels.indices.contains($0) ? levels[$0] : nil } ?? "")
        .accessibilityAdjustableAction { direction in
            guard let level else { return }
            switch direction {
            case .increment: pick(min(level + 1, count - 1))
            case .decrement: pick(max(level - 1, 0))
            @unknown default: break
            }
        }
    }

    private func height(_ i: Int) -> Double {
        let low = compact ? size * 0.36 : size * 0.85
        let high = compact ? size * 1.05 : size * 3.3
        return count > 1 ? low + (high - low) * Double(i) / Double(count - 1) : high
    }

    private func index(at x: Double) -> Int {
        guard width > 0 else { return level ?? 0 }
        return min(max(Int(x / width * Double(count)), 0), count - 1)
    }

    private func choose(at x: Double) {
        guard enabled else { return }
        let i = index(at: x)
        guard i != level else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        pick(i)
    }

    private func step(_ i: Int) -> some View {
        let lit = level.map { i <= $0 } ?? false
        let current = i == level
        let tint = Self.tint(i, of: count)
        let radius = compact ? size * 0.1 : size * 0.32
        let fill: AnyShapeStyle = if lit {
            AnyShapeStyle(tint.opacity(current ? 1 : 0.8).gradient)
        } else if hover == i, enabled {
            // Its color, faintly: what a click there would light.
            AnyShapeStyle(tint.opacity(0.3))
        } else {
            AnyShapeStyle(Color.primary.opacity(compact ? 0.16 : 0.1))
        }
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .frame(width: compact ? size * 0.3 : nil, height: height(i))
            .frame(maxWidth: compact ? nil : .infinity)
            .shadow(color: current && !compact ? tint.opacity(0.55) : .clear, radius: size * 0.6)
            .scaleEffect(current && pressed && !compact ? 1.05 : 1, anchor: .bottom)
    }
}

// MARK: - Claude Code's own menus

/// `/effort`, `/model` or `/resume`: the card of the menu Claude shows, or
/// of the one a command is opening, shown at once and filled once it's up.
struct ClaudeMenuCard: View {
    let feed: TranscriptFeed
    let kind: ClaudeMenuKind
    let size: Double
    let focusedPane: Bool
    let openTerminal: () -> Void

    var body: some View {
        let p = feed.dialog
        switch kind {
        case .effort:
            EffortCard(feed: feed, menu: p?.effortMenu, size: size, focusedPane: focusedPane, openTerminal: openTerminal)
        case .model:
            ModelPickerCard(feed: feed, prompt: p?.modelPicker != nil ? p : nil, size: size, focusedPane: focusedPane, openTerminal: openTerminal)
        case .resume:
            ResumeCard(feed: feed, menu: p?.resumeMenu, size: size, focusedPane: focusedPane, openTerminal: openTerminal)
        }
    }
}

// MARK: - /effort

/// Claude Code's effort menu (`/effort`): its levels as a stair (← →, a
/// click, a drag), Ultracode (Tab), then Set as Default (Enter) or Use in
/// This Session (`s`). What is asked shows at once; Claude's menu follows.
struct EffortCard: View {
    let feed: TranscriptFeed
    let menu: EffortMenu?
    let size: Double
    let focusedPane: Bool
    let openTerminal: () -> Void

    var body: some View {
        let driver = feed.menus
        let levels = menu?.levels ?? ClaudeEffort.levels
        let level = menu.map(driver.effortShown)
        // Claude's words under its scale are for the level it shows.
        let behind = menu != nil && level != menu?.current
        CardFrame(tint: .gray) {
            CardHeader(title: menu?.title ?? "Effort", symbol: Self.gauge(level ?? 1, of: levels.count),
                       tint: level.map { EffortStairs.tint($0, of: levels.count) } ?? .orange, size: size,
                       terminalLabel: "Show in Terminal", openTerminal: openTerminal)
            VStack(spacing: size * 0.7) {
                HStack {
                    Label(menu?.lowEnd ?? "Faster", systemImage: "hare")
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Text(menu?.highEnd ?? "Smarter")
                        Image(systemName: "brain")
                    }
                }
                .font(.system(size: size * 0.76))
                .foregroundStyle(.tertiary)
                EffortStairs(levels: levels, level: level, size: size) { driver.setEffort($0) }
                    .disabled(menu == nil)
                Text(menu.map { $0.caption.joined(separator: " ") } ?? "Opening Claude's effort menu…")
                    .font(.system(size: size * 0.82))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: size * 1.25)
                    .opacity(behind ? 0.3 : 1)
                    .animation(.easeOut(duration: 0.15), value: behind)
            }
            .frame(maxWidth: size * 32)
            .frame(maxWidth: .infinity)
            .padding(.vertical, size * 0.15)
            if let menu {
                if let on = driver.ultracodeShown(menu) {
                    Divider().opacity(0.5)
                    ultracode(on, note: menu.ultracodeNote)
                }
            } else {
                // Its place kept while Claude's menu opens: the card doesn't grow then.
                Divider().opacity(0.5)
                ultracode(false, note: nil)
                    .disabled(true)
                    .opacity(0.5)
            }
            ActionProblem(feed: feed, size: size)
            footer
        }
        .modifier(MenuKeys(feed: feed, focusedPane: focusedPane))
    }

    private func ultracode(_ on: Bool, note: String?) -> some View {
        HStack(spacing: size * 0.75) {
            Image(systemName: "sparkles")
                .font(.system(size: size * 1.0, weight: .medium))
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: on)
                .frame(width: size * 1.6)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ultracode")
                    .font(.system(size: size * 0.92, weight: .medium))
                Text((note ?? "dynamic workflows on every task").capitalizedFirst)
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            KeyChip(key: "⇥", size: size)
            Toggle("Ultracode", isOn: Binding(get: { on }, set: { _ in feed.menus.toggleUltracode() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Tab on Claude's screen")
        }
    }

    private var footer: some View {
        let hints: [(keys: [String], label: String)] = [(["←", "→"], "Adjust")] + (menu?.ultracode != nil ? [(["⇥"], "Ultracode")] : [])
        return HStack(spacing: size * 0.6) {
            MenuHints(hints: hints, size: size)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            Button { Task { await feed.menus.choose("esc") } } label: {
                KeyedLabel(title: "Cancel", key: "esc", size: size)
            }
            .buttonStyle(.glass)
            .help("Esc on Claude's screen: the effort stays as it was")
            if menu?.takesSession != false {
                Button { Task { await feed.menus.choose("s") } } label: {
                    KeyedLabel(title: "This Session", key: "S", size: size)
                }
                .buttonStyle(.glass)
                .disabled(menu == nil)
                .help("s on Claude's screen: new sessions keep your default")
            }
            Button { Task { await feed.menus.choose("enter") } } label: {
                KeyedLabel(title: "Set as Default", key: "↩", size: size, onAccent: true)
            }
            .buttonStyle(.glassProminent)
            .disabled(menu == nil)
            .help("Enter on Claude's screen: new sessions start with it too")
        }
        .font(.system(size: size * 0.88))
    }

    /// A gauge for level `i` of `count`.
    static func gauge(_ i: Int, of count: Int) -> String {
        guard count > 1 else { return "gauge.with.dots.needle.50percent" }
        let part = Double(i) / Double(count - 1)
        return switch part {
        case ..<0.17: "gauge.with.dots.needle.0percent"
        case ..<0.42: "gauge.with.dots.needle.33percent"
        case ..<0.59: "gauge.with.dots.needle.50percent"
        case ..<0.84: "gauge.with.dots.needle.67percent"
        default: "gauge.with.dots.needle.100percent"
        }
    }
}

private extension String {
    /// `dynamic workflows` → `Dynamic workflows`.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - /model

/// `/model` (⌥P): Claude Code's models as rows. ↑ ↓ or a click put its
/// cursor on one, whose effort shows on its row as a small stair (← →, a
/// click, a drag); then Set as Default (Enter) or Use in This Session (`s`).
struct ModelPickerCard: View {
    let feed: TranscriptFeed
    /// Nil while the picker opens.
    let prompt: ScreenPrompt?
    let size: Double
    let focusedPane: Bool
    let openTerminal: () -> Void
    @Namespace private var mark

    /// Effort names as the picker writes them.
    private static let effortNames = ["Low", "Medium", "High", "xHigh", "Max"]

    /// The last picker shown, in any pane, as it opens: while the next one
    /// opens, the card takes its shape with blank rows, and keeps its
    /// height once the list is up.
    @MainActor private static var shape: ScreenPrompt?

    /// The shape before any picker was seen: Claude Code 2.1.325's.
    private static let sample = ScreenPrompt.parse(screen: """
          Select model
          Switch between Claude models. Your pick becomes the default for new sessions.

            1.  Default (recommended)  Opus 5.5 · Best for everyday, complex tasks
            2.  Opus 5.5               For complex work and everyday tasks
            3.  Fable 5.2              For your toughest challenges
            4.  Sonnet 5.5             Most efficient for simpler tasks
          ❯ 5.  Haiku 5.5 ✔            Fastest for quick answers
            ▸   More models

          ◐ Medium effort (default) ←/→ to adjust

          Enter to set as default · s to use this session only · Esc to cancel
        """)

    var body: some View {
        let driver = feed.menus
        let opening = prompt?.modelPicker == nil
        let shown = opening ? nil : prompt.flatMap(driver.rowShown)
        let p = opening ? Self.shape ?? Self.sample : prompt
        CardFrame(tint: .gray) {
            CardHeader(title: "Model", subtitle: p?.modelPicker?.about, subtitlePending: opening, symbol: "cpu", tint: .purple, size: size,
                       terminalLabel: "Show in Terminal", openTerminal: openTerminal)
            if let p, let picker = p.modelPicker {
                list(p, picker: picker, shown: shown)
                    // Claude's picker is opening: its rows to come, blank.
                    .redacted(reason: opening ? .placeholder : [])
                    .disabled(opening)
                    .accessibilityHidden(opening)
            } else {
                SkeletonRows(count: 6, size: size)
            }
            ActionProblem(feed: feed, size: size)
            footer(chosen: shown?.number != nil)
        }
        .modifier(MenuKeys(feed: feed, focusedPane: focusedPane))
        .onChange(of: prompt, initial: true) { _, now in Self.keep(now) }
    }

    /// The picker as it opens, kept as the next one's shape: `More models`
    /// closed, nothing scrolled out of sight.
    private static func keep(_ p: ScreenPrompt?) {
        guard let p, let picker = p.modelPicker, !picker.moreOpen, !picker.hiddenAbove, picker.hiddenBelow == 0 else { return }
        shape = p
    }

    private func list(_ prompt: ScreenPrompt, picker: ScreenPrompt.ModelPicker, shown: PickerRow?) -> some View {
        let driver = feed.menus
        return VStack(alignment: .leading, spacing: 10) {
            RenderScroll {
                VStack(spacing: 2) {
                    if picker.hiddenAbove, case .model(let first)? = ClaudeMenuDriver.rows(prompt).first {
                        edge("Earlier Models", symbol: "chevron.up") { driver.highlight(.model(max(1, first - 1))) }
                    }
                    ForEach(ClaudeMenuDriver.rows(prompt), id: \.self) { row in
                        switch row {
                        case .model(let n):
                            if let option = prompt.options.first(where: { $0.number == n }) {
                                model(option, marked: shown == row, prompt: prompt)
                            }
                        case .more:
                            more(open: picker.moreOpen, marked: shown == .more)
                        }
                    }
                    if picker.hiddenBelow > 0, let last = prompt.options.last?.number {
                        edge(picker.hiddenBelow == 1 ? "1 More Model" : "\(picker.hiddenBelow) More Models", symbol: "chevron.down") {
                            driver.highlight(.model(last + 1))
                        }
                    }
                }
                .animation(.snappy(duration: 0.2), value: shown)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(picker.notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.readable(.orange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func model(_ option: ScreenPrompt.Option, marked: Bool, prompt: ScreenPrompt) -> some View {
        PickListRow(marked: marked, mark: mark, size: size, action: { feed.menus.highlight(.model(option.number)) }) {
            HStack(alignment: .center, spacing: size * 0.75) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.system(size: size * 0.95, weight: marked ? .semibold : .regular))
                        if option.checked == true {
                            ToolRow.tag("In Use", symbol: "checkmark", tint: .green, size: size)
                        }
                    }
                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .font(.system(size: size * 0.8))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if marked, let effort = feed.menus.modelEffortShown(prompt) {
                    effortControl(effort, prompt: prompt)
                        .transition(.opacity)
                }
            }
        }
        .accessibilityAddTraits(marked ? .isSelected : [])
    }

    /// The effort of the model under the cursor: a small stair and its name.
    private func effortControl(_ effort: Int, prompt: ScreenPrompt) -> some View {
        let driver = feed.menus
        // Claude shows a model's effort once its cursor is there.
        let known = driver.modelRow == nil || driver.modelRow == ClaudeMenuDriver.cursor(prompt)
        return HStack(spacing: size * 0.5) {
            EffortStairs(levels: ClaudeEffort.levels, level: effort, size: size, compact: true) { driver.setModelEffort($0) }
            Text(Self.effortNames.indices.contains(effort) ? Self.effortNames[effort] : "")
                .font(.system(size: size * 0.84, weight: .medium))
                .contentTransition(.opacity)
                .frame(minWidth: size * 3.6, alignment: .leading)
            if prompt.modelPicker?.effortIsDefault == true, driver.modelEffort == nil {
                Text("Default")
                    .font(.system(size: size * 0.78))
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(known ? 1 : 0.35)
        .help("This model's effort: ← → on the keyboard, or a click")
    }

    /// `More models`: the older ones, opened or closed.
    private func more(open: Bool, marked: Bool) -> some View {
        PickListRow(marked: marked, mark: mark, size: size, action: { feed.menus.openOrCloseMore() }) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: size * 0.72, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .animation(.snappy(duration: 0.2), value: open)
                    .frame(width: size * 1.1)
                Text(open ? "Fewer Models" : "More Models")
                    .font(.system(size: size * 0.9))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
        }
        .help(open ? "Hide the older models" : "Show the older models")
    }

    /// Models Claude's window scrolled out of sight: a click moves its cursor there.
    private func edge(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        PickListRow(marked: false, mark: mark, size: size, action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: size * 0.82))
                .foregroundStyle(.secondary)
        }
    }

    private func footer(chosen: Bool) -> some View {
        HStack(spacing: size * 0.6) {
            MenuHints(hints: [(["↑", "↓"], "Model"), (["←", "→"], "Effort")], size: size)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            Button { Task { await feed.menus.choose("esc") } } label: {
                KeyedLabel(title: "Cancel", key: "esc", size: size)
            }
            .buttonStyle(.glass)
            .help("Esc on Claude's screen")
            Button { Task { await feed.menus.choose("s") } } label: {
                KeyedLabel(title: "This Session", key: "S", size: size)
            }
            .buttonStyle(.glass)
            .disabled(!chosen)
            .help("s on Claude's screen: new sessions keep your default")
            Button { Task { await feed.menus.choose("enter") } } label: {
                KeyedLabel(title: "Set as Default", key: "↩", size: size, onAccent: true)
            }
            .buttonStyle(.glassProminent)
            .disabled(!chosen)
            .help("Enter on Claude's screen: new sessions start with it too")
        }
        .font(.system(size: size * 0.88))
    }
}

// MARK: - /resume

/// Claude Code's list of conversations to resume (`/resume`) as a search
/// over a list: the search has the keyboard from the command on, ↑ ↓ move,
/// ↩ resumes, Esc clears the search, then closes. What is asked shows at
/// once; Claude's list follows.
struct ResumeCard: View {
    let feed: TranscriptFeed
    /// Nil while the list opens.
    let menu: ResumeMenu?
    let size: Double
    let focusedPane: Bool
    let openTerminal: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.themeAccent) private var themeAccent
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var held = false
    /// The list's height so far: it doesn't shrink while the card shows.
    @State private var tallest = 0.0
    /// This card kept the list as it opened for the next one.
    @State private var kept = false
    @Namespace private var mark

    /// The list as it last opened, by pane, and in any pane: while the
    /// next one opens, the card takes its shape with blank rows.
    @MainActor private static var shapes: [String: ResumeMenu] = [:]
    @MainActor private static var lastShape: ResumeMenu?

    /// The shape before any list was seen: Claude Code 2.1.325's, long
    /// enough to fill the card, as most projects' are.
    private static let sample = ScreenPrompt.parse(screen: """
          Resume session (1 of 40)
          ╭──────────────────────────────────────────────────╮
          │ ⌕ Search…                                        │
          ╰──────────────────────────────────────────────────╯
            project

          ❯ Add a settings window
            1 hour ago · main · 1.2MB

            Fix the build on the server
            3 hours ago · main · 3.4MB

            Write the release notes
            5 hours ago · main · 860.1KB

            Make the sidebar easier to read
            yesterday · main · 2.1MB

            Check the new icons
            yesterday · main · 410.7KB

            Clean up the tests
            2 days ago · main · 5.6MB

            Speed up the first launch
            2 days ago · main · 1.9MB

            Update the docs
            3 days ago · main · 730.2KB

            Try a darker theme
            4 days ago · main · 1.1MB

            Plan the next release
            5 days ago · main · 2.8MB

            Ctrl+A to show all projects · Ctrl+B to only show current branch · Esc to cancel
        """)?.resumeMenu

    /// What the card shows the controls and rows of: Claude's list, or
    /// while it opens, the shape it will likely take.
    private var shown: ResumeMenu? {
        menu ?? Self.shapes[feed.address] ?? Self.lastShape ?? Self.sample
    }

    private func subtitle(_ menu: ResumeMenu?) -> String? {
        guard let menu else { return nil }
        var parts: [String] = [feed.menus.allProjectsShown(menu) ? "All projects" : menu.project ?? "This project"]
        if feed.menus.branchOnlyShown(menu) == true { parts.append("current branch") }
        if let total = menu.total { parts.append(total == 1 ? "1 conversation" : "\(total) conversations") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let opening = menu == nil
        let shown = self.shown
        CardFrame(tint: .gray) {
            CardHeader(title: "Resume a Conversation", subtitle: subtitle(shown), subtitlePending: opening, symbol: "clock.arrow.circlepath",
                       tint: .blue, size: size, terminalLabel: "Show in Terminal", openTerminal: openTerminal)
            HStack(spacing: size * 0.6) {
                searchField
                if let shown, shown.canSwitchProjects {
                    Picker("Conversations", selection: Binding(get: { feed.menus.allProjectsShown(shown) }, set: { feed.menus.showAllProjects($0) })) {
                        Text("This Project").tag(false)
                        Text("All Projects").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(opening)
                    .help("Ctrl+A on Claude's screen")
                }
            }
            if let shown, let only = feed.menus.branchOnlyShown(shown) {
                Toggle("Current branch only", isOn: Binding(get: { only }, set: { feed.menus.showBranchOnly($0) }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: size * 0.84))
                    .foregroundStyle(.secondary)
                    .disabled(opening)
                    .help("Ctrl+B on Claude's screen")
            }
            list
            ActionProblem(feed: feed, size: size)
            footer
        }
        .onAppear {
            if let words = menu?.search, search.isEmpty { search = words }
            take()
        }
        .onChange(of: menu, initial: true) { _, now in keep(now) }
        .onChange(of: feed.shows) { take() }
        .onChange(of: searchFocused) { _, now in if now { held = true } }
        // Typed in the terminal: here too, unless being typed here.
        .onChange(of: menu?.search) { _, now in
            if !searchFocused, let now, now != search.trimmingCharacters(in: .whitespaces) { search = now }
        }
        .onDisappear { if held { model.requestFocus() } }
    }

    private func take() {
        if focusedPane, feed.isShown { searchFocused = true }
    }

    /// The list as it opens, kept as the next one's shape: with rows, no
    /// search, at its top.
    private func keep(_ m: ResumeMenu?) {
        guard !kept, let m, !m.entries.isEmpty, m.search.isEmpty, !m.searching, !m.moreAbove else { return }
        kept = true
        Self.shapes[feed.address] = m
        Self.lastShape = m
    }

    private var searchField: some View {
        let accent = themeAccent ?? .accentColor
        return HStack(spacing: size * 0.5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search conversations", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onChange(of: search) { _, now in feed.menus.search(now) }
                .onSubmit { Task { await feed.menus.choose("enter") } }
                .onKeyPress(.downArrow) {
                    feed.menus.moveResume(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    feed.menus.moveResume(-1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    // A search to empty first, as in Spotlight; then the list closes.
                    if search.isEmpty {
                        Task { await feed.menus.choose("esc") }
                    } else {
                        search = ""
                    }
                    return .handled
                }
                .onKeyPress(phases: .down) { press in
                    guard press.modifiers.intersection([.shift, .control, .option, .command]) == .control else { return .ignored }
                    let c = press.characters.lowercased()
                    if c == "a" || c == "\u{01}" { return feed.menus.key("ctrl+a") ? .handled : .ignored }
                    if c == "b" || c == "\u{02}" { return feed.menus.key("ctrl+b") ? .handled : .ignored }
                    return .ignored
                }
            if feed.menus.driving, feed.menus.resumeSearch != nil {
                ProgressView()
                    .controlSize(.mini)
            }
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the search (Esc)")
            }
        }
        .font(.system(size: size * 0.95))
        .padding(.horizontal, size * 0.75)
        .padding(.vertical, size * 0.5)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: size * 0.75, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.75, style: .continuous)
                .strokeBorder(searchFocused ? accent.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: searchFocused ? 1.5 : 0.5)
        }
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    private var list: some View {
        Group {
            if let menu {
                found(menu)
                    // Measured once Claude's list shows, not its shape before.
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { tallest = max(tallest, $0) }
                    .frame(minHeight: tallest, alignment: .top)
            } else if let shape = shown, !shape.entries.isEmpty {
                // Claude's list is opening: its rows to come, blank.
                rows(shape, at: nil)
                    .redacted(reason: .placeholder)
                    .disabled(true)
                    .accessibilityHidden(true)
            } else {
                SkeletonRows(count: 4, size: size)
            }
        }
    }

    /// Claude's list as it shows; or what it shows when there is none.
    @ViewBuilder private func found(_ menu: ResumeMenu) -> some View {
        if menu.entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: menu.search.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: size * 1.4))
                    .foregroundStyle(.tertiary)
                Text(menu.empty ?? (feed.menus.driving ? "Looking…" : "No conversations to show."))
                    .font(.system(size: size * 0.9))
                    .foregroundStyle(.secondary)
                if !feed.menus.allProjectsShown(menu), menu.canSwitchProjects, menu.search.isEmpty {
                    Button("Show All Projects") { feed.menus.showAllProjects(true) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, size)
        } else {
            rows(menu, at: feed.menus.resumeRowShown(menu))
        }
    }

    /// The list's rows, the one at `at` marked.
    private func rows(_ menu: ResumeMenu, at: Int?) -> some View {
        RenderScroll {
            VStack(spacing: 2) {
                if menu.moreAbove {
                    edge("Earlier", symbol: "chevron.up") { feed.menus.moveResume(-((at ?? 0) + 1)) }
                }
                ForEach(menu.entries) { entry in
                    row(entry, marked: entry.index == at)
                }
                if menu.moreBelow {
                    edge("More", symbol: "chevron.down") { feed.menus.moveResume(menu.entries.count - (at ?? -1)) }
                }
            }
            .animation(.snappy(duration: 0.18), value: at)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ entry: ResumeMenu.Entry, marked: Bool) -> some View {
        let parts = entry.details.components(separatedBy: " · ")
        let rest = parts.dropFirst().joined(separator: " · ")
        return PickListRow(marked: marked, mark: mark, size: size, action: { Task { await feed.menus.resume(entry.index) } }) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title == "(session)" ? "Untitled conversation" : entry.title)
                        .font(.system(size: size * 0.95, weight: marked ? .medium : .regular))
                        .foregroundStyle(entry.title == "(session)" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if !rest.isEmpty {
                            Label(rest, systemImage: "arrow.triangle.branch")
                        }
                        if let folder = entry.folder {
                            Label(Self.short(folder), systemImage: "folder")
                                .truncationMode(.middle)
                        }
                    }
                    .font(.system(size: size * 0.78))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let when = entry.when {
                    Text(when)
                        .font(.system(size: size * 0.8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                KeyChip(key: "↩", size: size)
                    .opacity(marked ? 1 : 0)
            }
        }
        .help("Resume this conversation")
    }

    /// Conversations past the rows shown: Claude's cursor goes past the
    /// edge, and its list scrolls.
    private func edge(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        PickListRow(marked: false, mark: mark, size: size, action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: size * 0.82))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        var hints: [(keys: [String], label: String)] = [(["↑", "↓"], "Move")]
        if shown?.canSwitchProjects == true { hints.append((["⌃A"], "Projects")) }
        if shown?.branchOnly != nil { hints.append((["⌃B"], "Branch")) }
        return HStack(spacing: size * 0.6) {
            MenuHints(hints: hints, size: size)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            Button { Task { await feed.menus.choose("esc") } } label: {
                KeyedLabel(title: "Cancel", key: "esc", size: size)
            }
            .buttonStyle(.glass)
            .help("Esc on Claude's screen")
            Button { Task { await feed.menus.choose("enter") } } label: {
                KeyedLabel(title: "Resume", key: "↩", size: size, onAccent: true)
            }
            .buttonStyle(.glassProminent)
            .disabled(menu?.entries.isEmpty != false)
            .help(menu?.searching == true ? "Enter on Claude's screen: its first match" : "Enter on Claude's screen: the conversation under its cursor")
        }
        .font(.system(size: size * 0.88))
    }

    /// `/Users/me/Projects/shop` → `~/Projects/shop`.
    static func short(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Questions read from the screen

/// What Claude asks with AskUserQuestion, read from its screen: Claude
/// Code writes the call only with its answer. One question at a time, as
/// its screen shows them; a click on an option answers (or ticks its
/// box), own words go in the field under them; the review last.
struct ScreenQuestionCard: View {
    let feed: TranscriptFeed
    let prompt: ScreenPrompt
    let size: Double
    let focusedPane: Bool
    let openTerminal: () -> Void
    @State private var words = ""
    @State private var choosing: Int?
    @FocusState private var wordsFocused: Bool

    private var questionTabs: [ScreenPrompt.Tab] { prompt.tabs.filter { !$0.isSubmit } }

    /// The tab Claude shows as open: Submit's on the review, else as its
    /// screen's colors said for this question.
    private var openTab: Int? {
        if prompt.isReview { return prompt.tabs.lastIndex(where: \.isSubmit) }
        guard let shown = feed.questionTab, shown.key == TranscriptFeed.questionTabKey(prompt) else { return nil }
        return shown.index
    }

    private var title: String {
        let n = questionTabs.count
        return n > 1 ? "\(feed.agentName) has \(n) questions" : "\(feed.agentName) has a question"
    }

    var body: some View {
        let q = prompt.shownQuestion
        CardFrame(tint: .blue) {
            CardHeader(title: title, symbol: "questionmark.bubble.fill", tint: .blue, size: size, openTerminal: openTerminal)
            if prompt.tabs.count > 2 {
                StepPills(tabs: prompt.tabs, current: openTab, size: size)
            }
            if prompt.isReview {
                review
            } else if let q {
                question(q)
            } else {
                // Not understood: the screen's words and options as they are.
                ScreenText(paragraphs: ScreenParagraph.split(prompt.context + [""] + prompt.question), size: size)
                ForEach(prompt.options) { option in
                    OptionRow(option: option, numbered: prompt.numbered, busy: choosing == option.number, size: size) { pick(option) }
                }
            }
            ActionProblem(feed: feed, size: size)
            footer(q)
        }
        .modifier(CardKeys(feed: feed, focusedPane: focusedPane, digit: { n in
            guard let option = prompt.options.first(where: { $0.number == n }) else { return false }
            if option.number == prompt.ownWordsOption?.number, q != nil {
                wordsFocused = true
                return true
            }
            pick(option)
            return true
        }, escape: {
            Task { await feed.escape() }
            return true
        }))
        .onAppear { takeTyped() }
        .onChange(of: prompt) { takeTyped() }
    }

    /// Words typed for the question in the terminal come into the field.
    private func takeTyped() {
        guard !wordsFocused, let q = prompt.shownQuestion else { return }
        let typed = prompt.shownAnswer(for: q).other
        if words != typed { words = typed }
    }

    private func question(_ q: AskQuestion) -> some View {
        let own = prompt.ownWordsOption
        let options = prompt.options.filter { $0.number < (own?.number ?? Int.max) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(q.question)
                .font(.system(size: size * 1.02, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if q.multiSelect {
                Text("Choose any.")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
            }
            RenderScroll {
                VStack(spacing: 2) {
                    ForEach(options) { option in
                        Button { pick(option) } label: {
                            optionLabel(option, multi: q.multiSelect)
                        }
                        .buttonStyle(CardRowStyle(selected: option.checked == true, focused: option.focused && !q.multiSelect))
                        .disabled(feed.acting)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            ownWords(q, own: own)
        }
    }

    private func optionLabel(_ option: ScreenPrompt.Option, multi: Bool) -> some View {
        var label = option.label
        let marked = label.hasSuffix("✔") || label.hasSuffix("✓")
        if marked { label = String(label.dropLast()).trimmingCharacters(in: .whitespaces) }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if multi {
                Image(systemName: option.checked == true ? "checkmark.square.fill" : "square")
                    .font(.system(size: size * 1.0))
                    .foregroundStyle(option.checked == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(minWidth: size * 1.4)
            } else {
                CardKeyCap(key: "\(option.number)", size: size, active: option.focused)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(OptionRow.codeSpans(label))
                    .font(.system(size: size * 0.95, weight: option.checked == true || marked ? .medium : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                // A detail that only says the label again ("Red", "Red") adds nothing.
                if !option.detail.isEmpty, option.detail.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(label) != .orderedSame {
                    Text(option.detail)
                        .font(.system(size: size * 0.82))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if choosing == option.number {
                ProgressView().controlSize(.small)
            } else if marked {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.85, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Your answer")
            }
        }
    }

    /// The field for one's own words: on Claude's screen, the row over
    /// `Chat about this`, or the notes beside previews.
    @ViewBuilder private func ownWords(_ q: AskQuestion, own: ScreenPrompt.Option?) -> some View {
        if own != nil || prompt.previews {
            let empty = words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: "pencil.line")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                TextField(q.multiSelect ? "Something else…" : "Or answer in your own words…", text: $words, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: size * 0.95))
                    .lineLimit(1 ... 5)
                    .focused($wordsFocused)
                    .onSubmit { if !q.multiSelect, !empty { send(q) } }
                if !q.multiSelect {
                    Button { send(q) } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: size * 1.35))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .disabled(empty || feed.acting)
                    .help("Answer with your own words (↩)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
        }
    }

    /// AskUserQuestion's review: each question with its answer, to submit.
    private var reviewPairs: [(question: String, answer: String)] {
        var out: [(question: String, answer: String)] = []
        for line in prompt.context + prompt.question {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("●") {
                out.append((String(t.dropFirst()).trimmingCharacters(in: .whitespaces), ""))
            } else if t.hasPrefix("→"), !out.isEmpty {
                out[out.count - 1].answer = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    @ViewBuilder private var review: some View {
        let pairs = reviewPairs
        Text("Review your answers")
            .font(.system(size: size * 1.02, weight: .medium))
        if pairs.isEmpty {
            ScreenText(paragraphs: ScreenParagraph.split(prompt.question), size: size)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.question)
                            .font(.system(size: size * 0.84))
                            .foregroundStyle(.secondary)
                        Label(pair.answer.isEmpty ? "No answer" : pair.answer, systemImage: "arrow.turn.down.right")
                            .font(.system(size: size * 0.95, weight: .medium))
                            .foregroundStyle(pair.answer.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
        }
    }

    private func footer(_ q: AskQuestion?) -> some View {
        HStack(spacing: 8) {
            if let q, prompt.chatOption != nil {
                Button("Chat About This") { Task { try? await feed.chatInstead(q) } }
                    .help("No answer: write to \(feed.agentName) instead")
            }
            if prompt.isReview, let cancel = prompt.options.first(where: { $0.label.lowercased().hasPrefix("cancel") }) {
                Button("Cancel") { pick(cancel) }
                    .help("\(feed.agentName) goes on without your answers")
            } else {
                Button("Skip") { Task { await feed.escape() } }
                    .help("\(feed.agentName) goes on without an answer (Esc)")
            }
            Spacer()
            if feed.acting, choosing == nil { ProgressView().controlSize(.small) }
            if prompt.isReview, let submit = prompt.options.first(where: { $0.label.lowercased().hasPrefix("submit") }) {
                Button("Submit Answers") { pick(submit) }
                    .buttonStyle(.glassProminent)
                    .help("Send the answers to \(feed.agentName)")
            } else if let q, q.multiSelect {
                Button("Continue") { send(q) }
                    .buttonStyle(.glassProminent)
                    .help("Takes the ticked answers, then on to the next step")
            }
        }
        .buttonStyle(.glass)
        .disabled(feed.acting)
        .font(.system(size: size * 0.9))
    }

    private func pick(_ option: ScreenPrompt.Option) {
        guard choosing == nil, !feed.acting else { return }
        choosing = option.number
        Task {
            await feed.choose(option, in: prompt)
            choosing = nil
        }
    }

    /// Own words for a single choice; for several, the boxes as ticked and
    /// the words, given.
    private func send(_ q: AskQuestion) {
        guard !feed.acting else { return }
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = q.multiSelect ? prompt.options.filter { $0.checked == true && q.options.indices.contains($0.number - 1) }.map { q.options[$0.number - 1].label } : []
        guard q.multiSelect || !text.isEmpty else { return }
        Task {
            try? await feed.answerShown(q, AskAnswer(chosen: chosen, other: text))
            if feed.actionError == nil { words = "" }
        }
    }
}
