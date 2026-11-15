import HerdrKit
import SwiftUI

extension Notification.Name {
    /// Debug: opens the usage details of the pane at this address.
    static let swiftrUsageDetails = Notification.Name("swiftrUsageDetails")
}

/// What the usage under a field shows: the agent, its settings, and what is
/// known of its account.
struct UsageShown {
    let agent: ChatAgent
    let settings: UsageSettings
    /// Claude's or Codex's account; nil for Gemini, whose footer says.
    let account: UsageAccount?
    let state: UsageState

    /// nil when the agent's usage doesn't show: turned off, OpenCode, an
    /// agent on another machine, a Gemini whose footer has no quota.
    @MainActor init?(feed: TranscriptFeed, model: AppModel) {
        let agent = ChatAgent(feed.agent)
        let settings = model.prefs.usage(of: agent)
        guard settings.shown else { return nil }
        self.agent = agent
        self.settings = settings
        switch agent {
        case .claude, .codex:
            guard let account = model.usage.account(of: feed.address) else { return nil }
            self.account = account
            state = model.usage.state(of: account) ?? UsageState()
        case .gemini:
            account = nil
            #if DEBUG
            if let fake = model.usage.debugReports?["gemini"] {
                state = UsageState(report: fake, problem: model.usage.debugProblem)
                return
            }
            #endif
            guard let quota = feed.footer?.quota else { return nil }
            state = UsageState(report: UsageReport(windows: [quota], at: Date()))
        case .opencode:
            return nil
        }
    }

    /// The limits chosen in Settings, in the person's order, as they stand now.
    func windows(at now: Date) -> [UsageWindow] {
        settings.arrange(state.report?.windows ?? []).map { $0.current(at: now) }
    }

    /// Numbers this old are dimmed: they may have moved since.
    func isStale(at now: Date) -> Bool {
        guard let at = state.report?.at else { return false }
        return now.timeIntervalSince(at) > 15 * 60
    }
}

/// The usage under the field: each limit's share left (or used) on a thin
/// bar, and when it starts over. A click lists them all.
struct UsageStrip: View {
    @Environment(AppModel.self) private var model
    let shown: UsageShown
    let feed: TranscriptFeed
    let status: AgentStatus?
    let size: Double
    @State private var open = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            Button {
                open.toggle()
            } label: {
                label(now: now)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(UsageText.summary(shown, now: now))
            .popover(isPresented: $open, arrowEdge: .top) {
                UsageDetails(shown: shown, size: size) { open = false }
            }
        }
        .task(id: shown.account) {
            guard let account = shown.account else { return }
            while !Task.isCancelled {
                // A conversation kept out of sight doesn't ask.
                if feed.isShown { model.usage.refresh(account) }
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .onChange(of: status?.state) { old, new in
            // A turn just ended: what it used shows.
            if old == "working", new != "working", let account = shown.account {
                model.usage.refresh(account, soon: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftrUsageDetails)) { note in
            if note.object as? String == feed.address { open = true }
        }
    }

    @ViewBuilder private func label(now: Date) -> some View {
        let windows = shown.windows(at: now)
        if windows.isEmpty, shown.state.report?.windows.isEmpty == false, shown.state.problem == nil {
            // Every limit turned off in Settings.
            Color.clear.frame(width: 0, height: 0)
        } else if windows.isEmpty {
            if shown.state.problem != nil, !shown.state.checking {
                Label("Usage", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text("Usage…")
                    .foregroundStyle(.tertiary)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                UsageMeters(windows: windows, settings: shown.settings, size: size, now: now, form: .full)
                UsageMeters(windows: windows, settings: shown.settings, size: size, now: now, form: .bars)
                UsageMeters(windows: windows, settings: shown.settings, size: size, now: now, form: .numbers)
                UsageMeters(windows: windows, settings: shown.settings, size: size, now: now, form: .closest)
            }
            .opacity(shown.isStale(at: now) ? 0.55 : 1)
        }
    }
}

/// The limits in a row, as wide as `form` lets them be.
struct UsageMeters: View {
    enum Form {
        /// Name, bar, share and when it starts over.
        case full
        /// Without when it starts over.
        case bars
        /// Name and share.
        case numbers
        /// The limit closest to its end, alone.
        case closest
    }

    let windows: [UsageWindow]
    let settings: UsageSettings
    let size: Double
    let now: Date
    var form = Form.full

    var body: some View {
        let shown = form == .closest ? Array(UsageText.closest(windows, at: now).prefix(1)) : windows
        HStack(spacing: size * 1.4) {
            ForEach(shown) { window in
                meter(window)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func meter(_ w: UsageWindow) -> some View {
        let level = w.level(at: now)
        let share = settings.countsLeft ? w.left : w.used
        return HStack(spacing: 5) {
            Text(w.title)
                .foregroundStyle(.secondary)
            if form == .full || form == .bars {
                UsageBar(fraction: share / 100, level: level, width: size * 2.6, height: 4)
            }
            Text(form == .full || form == .bars ? UsageText.share(share, left: settings.countsLeft) : "\(Int(share.rounded()))%")
                .monospacedDigit()
                .foregroundStyle(UsageText.tint(level))
            if form == .full, settings.showsResets, let at = w.resetsAt {
                Text(UsageText.until(at, from: now))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A limit's share on a thin bar: neutral while use keeps pace with time,
/// orange ahead of it, red near the end. `pace` marks where an even pace
/// would be.
struct UsageBar: View {
    let fraction: Double
    let level: UsageWindow.Level
    let width: Double
    let height: Double
    var pace: Double? = nil

    var body: some View {
        let filled = min(1, max(0, fraction))
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.13))
            if filled > 0 {
                Capsule()
                    .fill(UsageText.barColor(level))
                    .frame(width: max(height, width * filled))
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .leading) {
            if let pace {
                Capsule()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 2, height: height + 6)
                    .offset(x: min(width - 2, max(0, width * pace - 1)))
                    .help("An even pace: where the bar would be if use kept up with the time gone by")
            }
        }
        .accessibilityHidden(true)
    }
}

/// All of an account's limits, bigger: how far each is, how much of its time
/// went by, when it starts over; the plan and when it was read.
struct UsageDetails: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let shown: UsageShown
    let size: Double
    let close: () -> Void

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let state = shown.account.flatMap { model.usage.state(of: $0) } ?? shown.state
            let width = size * 24
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(shown.agent.name) Usage")
                        .font(.system(size: size * 0.95, weight: .semibold))
                    Spacer()
                    if let plan = state.report?.plan {
                        Text(plan)
                            .font(.system(size: size * 0.8))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(shown.settings.arrange(state.report?.windows ?? [], all: true)) { window in
                    row(window.current(at: now), now: now, width: width)
                }
                if let problem = state.problem {
                    Label {
                        Text(UsageText.problem(problem, agent: shown.agent))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 8) {
                    Text(UsageText.updated(state, now: now))
                        .font(.system(size: size * 0.78))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Settings…") {
                        UserDefaults.standard.set(shown.agent.rawValue, forKey: SettingsPane.defaultsKey)
                        openSettings()
                        close()
                    }
                    if let account = shown.account {
                        Button("Refresh") { model.usage.refresh(account, force: true) }
                            .disabled(state.checking || UsageText.waiting(state, now: now))
                    }
                }
            }
            .padding(14)
            .frame(width: width + 28)
        }
    }

    private func row(_ w: UsageWindow, now: Date, width: Double) -> some View {
        let level = w.level(at: now)
        let left = shown.settings.countsLeft
        let share = left ? w.left : w.used
        let elapsed = w.elapsed(at: now)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(w.title)
                    .font(.system(size: size * 0.88, weight: .medium))
                Spacer()
                Text(UsageText.share(share, left: left))
                    .font(.system(size: size * 0.88).monospacedDigit())
                    .foregroundStyle(UsageText.tint(level))
            }
            UsageBar(fraction: share / 100, level: level, width: width, height: 6,
                     pace: elapsed.map { left ? 1 - $0 : $0 })
            if let detail = UsageText.detail(w, now: now) {
                Text(detail)
                    .font(.system(size: size * 0.78).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        // Those Settings leaves out of the strip, softer.
        .opacity(shown.settings.shows(w.id) ? 1 : 0.6)
    }
}

/// The words and colors of usage.
enum UsageText {
    /// "45% left", "55% used".
    static func share(_ share: Double, left: Bool) -> String {
        "\(Int(share.rounded()))% \(left ? "left" : "used")"
    }

    /// "45m", "2h 5m", "4d 3h": the time until `date`.
    static func until(_ date: Date, from now: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let (d, h, m) = (s / 86400, s % 86400 / 3600, s % 3600 / 60)
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(1, m))m"
    }

    /// How long a limit runs, for Settings: "5 hours", "7 days"; "Credit".
    static func span(_ w: UsageWindow) -> String {
        if w.isCredit { return "Credit" }
        guard let length = w.length, length > 0 else { return "" }
        let hours = Int((length / 3600).rounded())
        if hours < 24 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let days = Int((length / 86400).rounded())
        if days >= 300 { return "1 year" }
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// "8:39 PM" today, "Tue 1:00 AM" another day.
    static func when(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Under a limit's bar: the time gone by, when it starts over.
    static func detail(_ w: UsageWindow, now: Date) -> String? {
        var parts: [String] = []
        if let elapsed = w.elapsed(at: now) { parts.append("\(Int((elapsed * 100).rounded()))% of the time gone") }
        if let at = w.resetsAt { parts.append("resets in \(until(at, from: now)), \(when(at))") }
        guard !parts.isEmpty else { return nil }
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The limits closest to their end first.
    static func closest(_ windows: [UsageWindow], at now: Date) -> [UsageWindow] {
        func rank(_ l: UsageWindow.Level) -> Int { l == .near ? 2 : l == .ahead ? 1 : 0 }
        return windows.sorted { a, b in
            let (ra, rb) = (rank(a.level(at: now)), rank(b.level(at: now)))
            return ra != rb ? ra > rb : a.used > b.used
        }
    }

    static func tint(_ level: UsageWindow.Level) -> AnyShapeStyle {
        switch level {
        case .calm: AnyShapeStyle(.secondary)
        case .ahead: AnyShapeStyle(.readable(.orange))
        case .near: AnyShapeStyle(.readable(.red))
        }
    }

    static func barColor(_ level: UsageWindow.Level) -> AnyShapeStyle {
        switch level {
        case .calm: AnyShapeStyle(Color.primary.opacity(0.5))
        case .ahead: AnyShapeStyle(Color.orange)
        case .near: AnyShapeStyle(Color.red)
        }
    }

    /// "Updated 3 min ago".
    static func updated(_ state: UsageState, now: Date) -> String {
        if state.checking { return "Updating…" }
        guard let at = state.report?.at else { return "" }
        let s = now.timeIntervalSince(at)
        if s < 60 { return "Updated just now" }
        if s < 3600 { return "Updated \(Int(s / 60)) min ago" }
        if Calendar.current.isDate(at, inSameDayAs: now) { return "Updated at " + at.formatted(date: .omitted, time: .shortened) }
        return "Updated " + when(at)
    }

    static func waiting(_ state: UsageState, now: Date) -> Bool {
        if case .busy(let until) = state.problem { return until > now }
        return false
    }

    static func problem(_ problem: UsageState.Problem, agent: ChatAgent) -> String {
        switch problem {
        case .signedOut:
            "Claude Code isn't signed in with this account, or signs in with an API key, which has no usage limits."
        case .expired:
            "Claude Code's sign-in has run out. Claude Code renews it the next time it works; the numbers come back then."
        case .keychain(let why):
            "Swiftr couldn't read Claude Code's sign-in from the Keychain: \(why) Refresh tries again."
        case .busy(let until):
            "Anthropic asks to wait: Swiftr asks again at \(until.formatted(date: .omitted, time: .shortened))."
        case .failed(let why):
            why
        }
    }

    /// The strip's tooltip: each limit in words.
    static func summary(_ shown: UsageShown, now: Date) -> String {
        var lines = shown.settings.arrange(shown.state.report?.windows ?? [], all: true).map { $0.current(at: now) }.map { w in
            var line = "\(w.title): \(Int(w.used.rounded()))% used"
            if let at = w.resetsAt { line += ", resets in \(until(at, from: now))" }
            return line
        }
        if let problem = shown.state.problem { lines.append(self.problem(problem, agent: shown.agent)) }
        let updated = updated(shown.state, now: now)
        if !updated.isEmpty { lines.append(updated) }
        return lines.isEmpty ? "\(shown.agent.name) usage" : lines.joined(separator: "\n")
    }
}
