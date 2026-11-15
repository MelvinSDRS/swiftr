import Foundation
import HerdrKit

// MARK: - Claude Code's own menus, driven from their cards

/// One of Claude Code's own menus that a card drives.
enum ClaudeMenuKind: String, Equatable, Sendable {
    case effort, model, resume

    /// The menu a command sent from the field opens: `/effort` alone
    /// (`/effort high` sets it at once).
    init?(command text: String) {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "/effort": self = .effort
        case "/model": self = .model
        case "/resume": self = .resume
        default: return nil
        }
    }

    /// The command that opens it.
    var command: String { "/" + rawValue }

    /// The menu `p` is, if one of these.
    init?(_ p: ScreenPrompt?) {
        if p?.modelPicker != nil {
            self = .model
        } else if p?.effortMenu != nil {
            self = .effort
        } else if p?.resumeMenu != nil {
            self = .resume
        } else {
            return nil
        }
    }
}

/// A row of Claude Code's model picker: a model, by its number, or `More models`.
enum PickerRow: Hashable, Sendable {
    case model(Int)
    case more

    var number: Int? {
        if case .model(let n) = self { return n }
        return nil
    }
}

/// Claude Code's effort names, low to high, as `/effort` shows them.
enum ClaudeEffort {
    static let levels = ["low", "medium", "high", "xhigh", "max"]

    /// `Medium`, `xHigh` → its place in `levels`.
    static func index(_ name: String?) -> Int? {
        guard let name else { return nil }
        return levels.firstIndex(of: name.lowercased().replacingOccurrences(of: " ", with: ""))
    }
}

/// Drives Claude Code's `/effort`, `/model` and `/resume` menus from their
/// cards. A card shows at once what the person asks for; the keys that
/// take Claude's menu there follow, typed as the person's own (the core
/// holds the keys its API sends until 3 s after the person's last one),
/// one at a time, each once the screen showed the last: Claude Code reads
/// keys that come together as one. A command that opens one of these
/// menus shows its card before the menu is up.
@MainActor @Observable
final class ClaudeMenuDriver {
    @ObservationIgnored private weak var feed: TranscriptFeed?

    init(feed: TranscriptFeed) {
        self.feed = feed
    }

    /// The menu a command sent from the field is opening.
    private(set) var soon: ClaudeMenuKind?
    /// A choice that closes the menu went in: its card goes at once.
    private(set) var closing = false
    /// Keys go in.
    private(set) var driving = false
    /// The menu a chip under the field opened (`MenuChip`): its card shows
    /// in the chip's popover, not over the field.
    private(set) var inPopover: ClaudeMenuKind?

    /// `/effort`: the level asked for, Ultracode on or off.
    private(set) var effortLevel: Int?
    private(set) var ultracode: Bool?
    /// `/model`: the row asked for, and the effort asked for the model
    /// under the cursor (in `ClaudeEffort.levels`).
    private(set) var modelRow: PickerRow?
    private(set) var modelEffort: Int?
    /// `/resume`: the search asked for, every project's list or this
    /// one's, the current branch's only, and rows still to move (down +).
    private(set) var resumeSearch: String?
    private(set) var resumeAll: Bool?
    private(set) var resumeBranch: Bool?
    private(set) var resumeMoves = 0

    /// Steps asked before the menu was up: ← → for the effort, ↑ ↓ for a row.
    @ObservationIgnored private var earlySteps = 0
    /// `More models` opened or closed once the cursor is on it.
    @ObservationIgnored private var toggleMore = false
    @ObservationIgnored private var searchAt = Date.distantPast
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// When a read here last set the menu: reads begun before then are stale.
    @ObservationIgnored private var shownAt = Date.distantPast
    /// When a read from elsewhere first missed the menu.
    @ObservationIgnored private var missedAt: Date?

    /// The menu whose card shows: the one on Claude's screen, else the one
    /// a command is opening.
    var kind: ClaudeMenuKind? {
        guard let feed, feed.agent == .claude, !closing else { return nil }
        if let shown = ClaudeMenuKind(feed.dialog) { return shown }
        return feed.dialog == nil ? soon : nil
    }

    // MARK: Opening

    /// A command went in from the field: the card of the menu it opens
    /// shows now; keys asked there wait for the menu.
    func expect(_ text: String) {
        guard let kind = ClaudeMenuKind(command: text) else { return }
        reset()
        soon = kind
        watch = Task { [weak self] in
            await self?.watchFor(kind)
        }
    }

    private func watchFor(_ kind: ClaudeMenuKind) async {
        let end = Date().addingTimeInterval(4)
        while !Task.isCancelled, Date() < end {
            try? await Task.sleep(for: .milliseconds(40))
            guard let feed, !Task.isCancelled else { return }
            if ClaudeMenuKind(feed.dialog) == kind { break }
            guard let screen = try? await feed.readScreen(), !Task.isCancelled else { continue }
            let p = feed.parsePrompt(screen)
            if ClaudeMenuKind(p) == kind {
                feed.dialog = p
                shownAt = Date()
                break
            }
        }
        guard !Task.isCancelled else { return }
        watch = nil
        soon = nil
        // What was asked meanwhile goes in now.
        let steps = earlySteps
        earlySteps = 0
        if steps != 0, ClaudeMenuKind(feed?.dialog) == kind {
            switch kind {
            case .effort: stepEffort(steps)
            case .model: stepModel(steps)
            case .resume: moveResume(steps)
            }
        }
        kick()
    }

    /// Back to the menu as Claude's screen shows it, nothing asked.
    func reset() {
        runID += 1
        run?.cancel()
        run = nil
        driving = false
        watch?.cancel()
        watch = nil
        soon = nil
        closing = false
        missedAt = nil
        clearAsked()
    }

    private func clearAsked() {
        effortLevel = nil
        ultracode = nil
        modelRow = nil
        modelEffort = nil
        resumeSearch = nil
        resumeAll = nil
        resumeBranch = nil
        resumeMoves = 0
        earlySteps = 0
        toggleMore = false
    }

    // MARK: From a chip

    /// A chip's click: Claude's menu opens as its command would open it, its
    /// card in the chip's popover from now on. When the menu doesn't come,
    /// the popover goes and the note over the field says why.
    func openInPopover(_ kind: ClaudeMenuKind) {
        guard let feed, inPopover == nil, self.kind == nil, !closing else { return }
        inPopover = kind
        feed.actionError = nil
        Task {
            do {
                try await feed.send(kind.command)
            } catch {
                feed.actionError = (error as? CoreError)?.message ?? error.localizedDescription
            }
            guard inPopover == kind, !closing, ClaudeMenuKind(feed.dialog) != kind else { return }
            inPopover = nil
            if feed.actionError == nil { feed.actionError = "Claude's \(kind.rawValue) menu didn't open." }
        }
    }

    /// The person closed the popover (a click outside it): Claude's menu
    /// closes as Esc closes it, nothing changed.
    func popoverClosed(_ kind: ClaudeMenuKind) {
        guard inPopover == kind else { return }
        inPopover = nil
        guard !closing, self.kind == kind else { return }
        // Its card goes now, not over the field meanwhile.
        closing = true
        Task { await finish("esc", kind: kind) }
    }

    /// The popover goes, Claude's menu still up (Show in Terminal): its
    /// card shows over the field when the conversation shows again.
    func leavePopover() {
        inPopover = nil
    }

    // MARK: /effort

    /// The level the card shows: the one asked for, else Claude's.
    func effortShown(_ m: EffortMenu) -> Int { effortLevel ?? m.current }

    func ultracodeShown(_ m: EffortMenu) -> Bool? { m.ultracode.map { ultracode ?? $0 } }

    func setEffort(_ index: Int) {
        guard let m = feed?.dialog?.effortMenu else { return }
        let i = min(max(index, 0), m.levels.count - 1)
        guard i != effortShown(m) else { return }
        effortLevel = i
        kick()
    }

    func stepEffort(_ step: Int) {
        if let m = feed?.dialog?.effortMenu {
            setEffort(effortShown(m) + step)
        } else if soon == .effort {
            earlySteps += step
        }
    }

    func toggleUltracode() {
        guard let m = feed?.dialog?.effortMenu, let on = ultracodeShown(m) else { return }
        ultracode = !on
        kick()
    }

    // MARK: /model

    /// The picker's rows in screen order, `More models` among the models.
    static func rows(_ p: ScreenPrompt) -> [PickerRow] {
        guard let picker = p.modelPicker else { return [] }
        var rows: [PickerRow] = []
        for o in p.options {
            if picker.moreShown, o.number > picker.moreAfter, !rows.contains(.more) { rows.append(.more) }
            rows.append(.model(o.number))
        }
        if picker.moreShown, !rows.contains(.more) { rows.append(.more) }
        return rows
    }

    /// Where Claude's cursor is in the picker.
    static func cursor(_ p: ScreenPrompt) -> PickerRow? {
        if p.modelPicker?.moreFocused == true { return .more }
        return p.options.first(where: \.focused).map { .model($0.number) }
    }

    /// The row the card shows the cursor on: the one asked for, else Claude's.
    func rowShown(_ p: ScreenPrompt) -> PickerRow? { modelRow ?? Self.cursor(p) }

    func highlight(_ row: PickerRow) {
        guard let p = feed?.dialog, p.modelPicker != nil, row != rowShown(p) else { return }
        modelRow = row
        modelEffort = nil
        kick()
    }

    func stepModel(_ step: Int) {
        guard let p = feed?.dialog, let picker = p.modelPicker else {
            if soon == .model { earlySteps += step }
            return
        }
        let rows = Self.rows(p)
        let shown = rowShown(p)
        if let shown, let at = rows.firstIndex(of: shown) {
            let to = at + step
            if rows.indices.contains(to) {
                highlight(rows[to])
            } else if case .model(let n) = shown, to >= rows.count ? picker.hiddenBelow > 0 : picker.hiddenAbove {
                // Past the window's edge: Claude's list scrolls.
                highlight(.model(max(1, n + step)))
            }
        } else if case .model(let n)? = shown {
            highlight(.model(max(1, n + step)))
        } else if let first = rows.first {
            highlight(first)
        }
    }

    /// `More models`, opened or closed: the cursor goes there, then Enter.
    func openOrCloseMore() {
        guard let p = feed?.dialog, p.modelPicker?.moreShown == true else { return }
        modelRow = .more
        modelEffort = nil
        toggleMore = true
        kick()
    }

    /// The effort the card shows for the model under the cursor (in `ClaudeEffort.levels`).
    func modelEffortShown(_ p: ScreenPrompt) -> Int? {
        modelEffort ?? ClaudeEffort.index(p.modelPicker?.effort)
    }

    func setModelEffort(_ index: Int) {
        guard let p = feed?.dialog, p.modelPicker?.effort != nil else { return }
        let i = min(max(index, 0), ClaudeEffort.levels.count - 1)
        guard i != modelEffortShown(p) else { return }
        modelEffort = i
        kick()
    }

    func stepModelEffort(_ step: Int) {
        guard let p = feed?.dialog, let now = modelEffortShown(p) else { return }
        setModelEffort(now + step)
    }

    // MARK: /resume

    /// Words for Claude's search; they go in once the typing pauses.
    func search(_ words: String) {
        guard feed?.dialog?.resumeMenu != nil || soon == .resume else { return }
        resumeSearch = words
        searchAt = Date()
        kick()
    }

    /// The row the card shows Claude's cursor on: Claude's, moved by the
    /// rows asked still; nil while the search has it.
    func resumeRowShown(_ m: ResumeMenu) -> Int? {
        guard !m.entries.isEmpty else { return nil }
        if let at = m.entries.first(where: \.focused)?.index {
            return min(max(at + resumeMoves, 0), m.entries.count - 1)
        }
        // From the search, ↓ goes to the first row.
        return resumeMoves > 0 ? min(resumeMoves - 1, m.entries.count - 1) : nil
    }

    func moveResume(_ step: Int) {
        guard feed?.dialog?.resumeMenu != nil else {
            if soon == .resume { earlySteps += step }
            return
        }
        resumeMoves += step
        kick()
    }

    func allProjectsShown(_ m: ResumeMenu) -> Bool { resumeAll ?? m.allProjects }

    func branchOnlyShown(_ m: ResumeMenu) -> Bool? { m.branchOnly.map { resumeBranch ?? $0 } }

    /// Every project's conversations or this one's (⌃A).
    func showAllProjects(_ all: Bool) {
        guard let m = feed?.dialog?.resumeMenu, m.canSwitchProjects, all != allProjectsShown(m) else { return }
        resumeAll = all
        keepSearch(m)
        kick()
    }

    /// Only the current branch's conversations, or every branch's (⌃B).
    func showBranchOnly(_ only: Bool) {
        guard let m = feed?.dialog?.resumeMenu, let now = branchOnlyShown(m), only != now else { return }
        resumeBranch = only
        keepSearch(m)
        kick()
    }

    /// Claude empties its search when it loads another list: the words go
    /// in again after.
    private func keepSearch(_ m: ResumeMenu) {
        if resumeSearch == nil, !m.search.isEmpty { resumeSearch = m.search }
    }

    /// Conversation `index`, as the card shows the list, resumed: Claude's
    /// cursor goes there, then Enter.
    func resume(_ index: Int) async {
        guard let m = feed?.dialog?.resumeMenu, m.entries.indices.contains(index) else { return }
        resumeMoves = m.entries.first(where: \.focused).map { index - $0.index } ?? index + 1
        kick()
        await choose("enter")
    }

    // MARK: Reads from elsewhere

    /// A read of Claude's screen made elsewhere (`refreshScreen`), begun at
    /// `readAt`: true when it should leave the card's menu as it is. One
    /// begun before a read here is stale; one that misses the menu waits
    /// for the next read, a moment later: a redraw shows none for an instant.
    func holds(_ screen: String, readAt: Date) -> Bool {
        guard let feed, feed.agent == .claude, !closing, let kind = ClaudeMenuKind(feed.dialog) else {
            missedAt = nil
            return false
        }
        if readAt < shownAt { return true }
        if ClaudeMenuKind(feed.parsePrompt(screen)) == kind {
            missedAt = nil
            return false
        }
        guard let missed = missedAt else {
            missedAt = Date()
            Task { [weak feed] in
                try? await Task.sleep(for: .milliseconds(300))
                feed?.rereadScreen()
            }
            return true
        }
        if Date().timeIntervalSince(missed) < 0.25 { return true }
        missedAt = nil
        // Claude's menu went (closed in its terminal): its popover too.
        if inPopover == kind { inPopover = nil }
        return false
    }

    /// Whether a read begun at `readAt` is older than the menu the card shows.
    func isStale(_ readAt: Date) -> Bool {
        readAt < shownAt && ClaudeMenuKind(feed?.dialog) != nil
    }

    /// Whether `kind`'s menu came up for the command just sent (4 s at most).
    func opens(_ kind: ClaudeMenuKind) async -> Bool {
        await watch?.value
        return ClaudeMenuKind(feed?.dialog) == kind
    }

    // MARK: Keys from the card

    /// A key on the card, as in Claude's menu (`left`, `enter`, `s`,
    /// `ctrl+a`…): false when the card leaves it to others.
    @discardableResult
    func key(_ name: String) -> Bool {
        guard let kind, let feed else { return false }
        let p = feed.dialog
        switch (kind, name) {
        case (.effort, "left"): stepEffort(-1)
        case (.effort, "right"): stepEffort(1)
        case (.effort, "tab"): toggleUltracode()
        case (.effort, "s"):
            guard p?.effortMenu?.takesSession != false else { return false }
            Task { await choose("s") }
        case (.model, "up"): stepModel(-1)
        case (.model, "down"): stepModel(1)
        case (.model, "left"): stepModelEffort(-1)
        case (.model, "right"): stepModelEffort(1)
        case (.model, "s"):
            Task { await choose("s") }
        case (.model, "enter"):
            if let p, rowShown(p) == .more {
                openOrCloseMore()
            } else {
                Task { await choose("enter") }
            }
        case (.resume, "up"): moveResume(-1)
        case (.resume, "down"): moveResume(1)
        case (.resume, "ctrl+a"):
            guard let m = p?.resumeMenu, m.canSwitchProjects else { return false }
            showAllProjects(!allProjectsShown(m))
        case (.resume, "ctrl+b"):
            guard let m = p?.resumeMenu, let only = branchOnlyShown(m) else { return false }
            showBranchOnly(!only)
        case (_, "enter"):
            Task { await choose("enter") }
        case (_, "esc"):
            Task { await choose("esc") }
        default:
            return false
        }
        return true
    }

    // MARK: Driving

    /// What to do next on Claude's screen.
    private enum Step: Equatable {
        case key(String)
        case search(String)
        case move(Int)
    }

    private func next(_ p: ScreenPrompt) -> Step? {
        if let m = p.effortMenu {
            if let want = effortLevel, want != m.current { return .key(want > m.current ? "right" : "left") }
            if let want = ultracode, let on = m.ultracode, want != on { return .key("tab") }
            return nil
        }
        if let picker = p.modelPicker {
            if let want = modelRow {
                if let step = p.pickerStep(toward: want.number) { return .key(step) }
                if Self.cursor(p) == want, toggleMore, want == .more { return .key("enter") }
            }
            if let want = modelEffort, let now = ClaudeEffort.index(picker.effort), want != now,
               modelRow == nil || modelRow == Self.cursor(p)
            {
                return .key(want > now ? "right" : "left")
            }
            return nil
        }
        if let m = p.resumeMenu {
            if let want = resumeAll, m.canSwitchProjects, want != m.allProjects { return .key("ctrl+a") }
            if let want = resumeBranch, let only = m.branchOnly, want != only { return .key("ctrl+b") }
            if let words = resumeSearch, words.trimmingCharacters(in: .whitespaces) != m.search { return .search(words) }
            if resumeMoves != 0 { return .move(resumeMoves > 0 ? 1 : -1) }
            return nil
        }
        return nil
    }

    /// Keys go in until Claude's menu is as asked. Not while the menu
    /// isn't up yet: they wait for it.
    private func kick() {
        guard run == nil, soon == nil else { return }
        runID += 1
        let id = runID
        driving = true
        run = Task { [weak self] in
            await self?.drive()
            guard let self, self.runID == id else { return }
            self.run = nil
            self.driving = false
        }
    }

    private func drive() async {
        guard let feed else { return }
        var unchanged = 0
        var missing = 0
        for _ in 0 ..< 120 {
            guard !Task.isCancelled, let screen = try? await feed.readScreen(), !Task.isCancelled else { return }
            let p = feed.parsePrompt(screen)
            guard let p, ClaudeMenuKind(p) != nil else {
                // Mid-redraw, or the menu went: look again a moment.
                missing += 1
                if missing > 8 {
                    clearAsked()
                    feed.rereadScreen()
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            missing = 0
            if feed.dialog != p { feed.dialog = p }
            shownAt = Date()
            guard let step = next(p) else {
                clearAsked()
                return
            }
            // Words for the search go once the typing pauses.
            if case .search = step {
                let wait = 0.15 - Date().timeIntervalSince(searchAt)
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                    continue
                }
            }
            do {
                switch step {
                case .key(let key):
                    try await feed.typeAsPerson(key)
                    if key == "enter" { toggleMore = false }
                case .move(let d):
                    try await feed.typeAsPerson(d > 0 ? "down" : "up")
                case .search(let words):
                    let text = words.replacingOccurrences(of: "\n", with: " ")
                    try await feed.typeAsPerson("ctrl+u")
                    if text.trimmingCharacters(in: .whitespaces).isEmpty {
                        feed.terminalSession?.draftEnded()
                    } else {
                        try await Task.sleep(for: .milliseconds(30))
                        try await feed.typeWords(text)
                    }
                }
            } catch {
                feed.actionError = (error as? CoreError)?.message ?? error.localizedDescription
                clearAsked()
                return
            }
            // ⌃A and ⌃B load another list: that takes a moment.
            // ⌃A and ⌃B load another list: that takes a moment, and Claude
            // empties its search first. Its list is what tells it's done.
            let after = if let m = p.resumeMenu, step == .key("ctrl+a") || step == .key("ctrl+b") {
                await switchedList(from: m, projects: step == .key("ctrl+a"))
            } else {
                await changedScreen(from: screen, within: 0.6)
            }
            guard !Task.isCancelled else { return }
            // The move counts once Claude's list shows it, with the list.
            if case .move(let d) = step { resumeMoves -= d }
            if let after {
                unchanged = 0
                if let q = feed.parsePrompt(after), ClaudeMenuKind(q) != nil {
                    if feed.dialog != q { feed.dialog = q }
                    shownAt = Date()
                }
            } else {
                // Claude doesn't move (an end of its list, a level it lacks).
                unchanged += 1
                if unchanged >= 2 {
                    clearAsked()
                    return
                }
            }
        }
        clearAsked()
    }

    /// The screen once Claude's list switched (⌃A: every project's or this
    /// one's; ⌃B: the current branch's only or every branch's); nil after 3 s.
    private func switchedList(from m: ResumeMenu, projects: Bool) async -> String? {
        guard let feed else { return nil }
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return nil }
            if let now = try? await feed.readScreen(), let q = feed.parsePrompt(now)?.resumeMenu,
               projects ? q.allProjects != m.allProjects : q.branchOnly != m.branchOnly
            {
                return now
            }
        }
        return nil
    }

    /// The screen once it's no longer `before`; nil if it stayed so for `seconds`.
    private func changedScreen(from before: String, within seconds: Double) async -> String? {
        guard let feed else { return nil }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return nil }
            if let now = try? await feed.readScreen(), now != before { return now }
        }
        return nil
    }

    // MARK: Choosing

    /// The keys under way and the menu opening, done (3 s at most).
    private func settled() async {
        let end = Date().addingTimeInterval(3)
        while run != nil || watch != nil, Date() < end {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Enter, `s` or Esc in Claude's menu, once the keys under way went in:
    /// the menu closes, its card (or popover) at once.
    func choose(_ key: String) async {
        guard feed != nil, !closing else { return }
        let kind = self.kind
        closing = true
        inPopover = nil
        await finish(key, kind: kind)
    }

    private func finish(_ key: String, kind: ClaudeMenuKind?) async {
        guard let feed else { return }
        await settled()
        feed.actionError = nil
        var problem: String?
        var draftEnds = key == "enter"
        do {
            if key == "esc", let m = feed.dialog?.resumeMenu, !m.search.isEmpty {
                // Esc in the search would only empty it.
                try await feed.typeAsPerson("ctrl+u")
                draftEnds = true
                try await Task.sleep(for: .milliseconds(60))
            }
            var gone = false
            if key == "esc" {
                // Esc from Claude's list may go back to its search first: once
                // the screen moved, a menu still there takes a second one.
                for _ in 0 ..< 2 where !gone {
                    let before = try await feed.readScreen()
                    // Nothing to close (a popover shut while the menu was opening,
                    // and it never came): Esc would go to Claude's input box.
                    if kind != nil, ClaudeMenuKind(feed.parsePrompt(before)) != kind {
                        gone = true
                        break
                    }
                    try await feed.typeAsPerson("esc")
                    _ = await changedScreen(from: before, within: 1.5)
                    gone = await menuGone(kind, within: 0.3)
                }
            } else {
                try await feed.typeAsPerson(key)
                gone = await menuGone(kind, within: 2)
            }
            if !gone { problem = "Claude's menu didn't close. Look in the terminal." }
        } catch {
            problem = (error as? CoreError)?.message ?? error.localizedDescription
        }
        reset()
        if let problem {
            feed.actionError = problem
        } else {
            feed.dialog = nil
            if draftEnds { feed.terminalSession?.draftEnded() }
            if key == "s" { await endDraft() }
            if kind == .resume, key == "enter" { feed.followCommand() }
        }
        feed.rereadScreen()
    }

    private func menuGone(_ kind: ClaudeMenuKind?, within seconds: Double) async -> Bool {
        guard let feed else { return true }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(40))
            guard let screen = try? await feed.readScreen() else { continue }
            if ClaudeMenuKind(feed.parsePrompt(screen)) != kind { return true }
        }
        return false
    }

    /// `s` went in as the person's: the core takes it for words they typed
    /// and would hold the next message back. Once Claude's input box is
    /// back, empty, ⌃U as theirs ends that.
    private func endDraft() async {
        guard let feed else { return }
        let end = Date().addingTimeInterval(1.5)
        while Date() < end {
            if let screen = try? await feed.readScreen(), let text = await feed.boxText(screen) {
                if text.isEmpty, let terminal = feed.terminalSession, terminal.isAttached {
                    terminal.view.send(txt: "\u{15}")
                    terminal.draftEnded()
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    /// What a key name types in a terminal.
    nonisolated static func bytes(_ key: String) -> String {
        switch key {
        case "up": "\u{1b}[A"
        case "down": "\u{1b}[B"
        case "right": "\u{1b}[C"
        case "left": "\u{1b}[D"
        case "tab": "\t"
        case "enter": "\r"
        case "esc": "\u{1b}"
        case "ctrl+a": "\u{01}"
        case "ctrl+b": "\u{02}"
        case "ctrl+u": "\u{15}"
        default: key
        }
    }

    /// What the debug dump shows of it.
    var debugState: [String: Any] {
        var out: [String: Any] = ["driving": driving, "closing": closing]
        if let soon { out["soon"] = soon.rawValue }
        if let inPopover { out["inPopover"] = inPopover.rawValue }
        if let kind { out["kind"] = kind.rawValue }
        if let effortLevel { out["effortLevel"] = effortLevel }
        if let ultracode { out["ultracode"] = ultracode }
        if let modelRow { out["modelRow"] = modelRow.number.map(String.init) ?? "more" }
        if let modelEffort { out["modelEffort"] = modelEffort }
        if let resumeSearch { out["resumeSearch"] = resumeSearch }
        if resumeMoves != 0 { out["resumeMoves"] = resumeMoves }
        return out
    }
}

extension TranscriptFeed {
    /// `key` typed in Claude's terminal as the person's own: the core sends
    /// it at once, where keys from its API wait until 3 s after the
    /// person's last one.
    func typeAsPerson(_ key: String) async throws {
        let terminal = try await attachedTerminal(for: "Claude's menu")
        terminal.view.send(txt: ClaudeMenuDriver.bytes(key))
    }

    /// Words typed as the person's own (keys from the core type no
    /// capitals or accents), a letter at a time: `/resume`'s search drops
    /// a paste, and letters that come together read as one.
    func typeWords(_ text: String) async throws {
        let terminal = try await attachedTerminal(for: "Claude's menu")
        for letter in text where !letter.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            terminal.view.send(txt: String(letter))
            try await Task.sleep(for: .milliseconds(12))
        }
    }

    // MARK: Questions read from the screen

    /// Own words, or a multi-select question's boxes as they are, given as
    /// the answer to the question Claude's screen shows: its call isn't
    /// known yet (Claude Code writes it with its answer).
    func answerShown(_ q: AskQuestion, _ a: AskAnswer) async throws {
        try await acting {
            guard let p = try await readPrompt(), p.asks(q) else {
                throw fail("Claude's screen doesn't show the question “\(q.question)” any more.")
            }
            let shown = p.shownAnswer(for: q)
            if q.multiSelect {
                try await answerMany(q, a, p, shown: shown)
            } else {
                try await answerOne(q, a, p, shown: shown)
            }
            guard try await waitPrompt(4, until: { $0.map { !$0.asks(q) } ?? true }) != nil else {
                throw fail("Claude didn't take the answer to “\(q.question)”.")
            }
        }
    }

    /// Claude's cursor to tab `index` of a question's tab bar (from 0;
    /// Submit last), from tab `from`: ← or →, off the field for one's own
    /// words first (it takes those keys).
    func showQuestionTab(_ index: Int, from: Int, own: Int?) async {
        guard index != from else { return }
        try? await acting {
            if let own, try await readPrompt()?.options.first(where: \.focused)?.number == own {
                try await pressAndSettle(["up"])
            }
            try await pressAndSettle(Array(repeating: index > from ? "right" : "left", count: abs(index - from)))
        }
    }
}

extension ScreenPrompt {
    /// AskUserQuestion's `Chat about this`, under its options.
    var chatOption: Option? {
        // Beside previews it is no option of the list: no digit picks it.
        if previews { return Option(number: options.count + 1, label: "Chat about this", focused: chatFocused) }
        return options.last { $0.label.lowercased().hasPrefix("chat about this") }
    }

    /// AskUserQuestion's row for one's own words (`Type something.`, or the
    /// words typed there): right over `Chat about this`. None beside
    /// previews, where they go in as notes.
    var ownWordsOption: Option? {
        if previews { return nil }
        if let chat = chatOption { return options.first { $0.number == chat.number - 1 } }
        return options.first { ["type something", "type something."].contains($0.label.lowercased()) }
    }

    /// The question Claude's screen asks, as its call would give it: its
    /// own options, without the row for one's own words and the chat. Nil
    /// on the review, or when the screen shows no such question.
    var shownQuestion: AskQuestion? {
        guard !isReview, let end = previews ? options.count + 1 : ownWordsOption?.number, end > 1 else { return nil }
        let text = questionText
        guard !text.isEmpty else { return nil }
        let choices = options.filter { $0.number < end }.map { o -> AskQuestion.Choice in
            var label = o.label
            // A single choice comes back marked once its tab is left.
            if label.hasSuffix("✔") || label.hasSuffix("✓") { label = String(label.dropLast()).trimmingCharacters(in: .whitespaces) }
            return AskQuestion.Choice(label: label, detail: o.detail)
        }
        return AskQuestion(question: text, multiSelect: isMultiSelect, options: choices)
    }
}
