import Foundation

// MARK: - /effort

/// Claude Code's effort menu (`/effort` alone, 2.1.325), a scale with a
/// mark under the level chosen:
///
///        Effort
///
///                  Faster                             Smarter
///                  ──────────▲───────────────────────────────      Ultracode  off
///                  low     medium     high     xhigh      max      Tab to toggle
///                  Ultracode: dynamic workflows on every task
///                             The default effort for this model
///
///        ←/→ to adjust · Enter to confirm · s for this session only · Esc to cancel
///
/// ← and → move the mark, Tab turns Ultracode on or off (its line under
/// the scale shows while on), Enter keeps the level as the model's default
/// for new sessions, `s` for this session only.
public struct EffortMenu: Sendable, Equatable {
    /// The menu's name (`Effort`).
    public var title: String
    /// The scale's levels, low to high, as named under it.
    public var levels: [String]
    /// The level the mark is under.
    public var current: Int
    /// The words at the scale's ends (`Faster`, `Smarter`).
    public var lowEnd: String?
    public var highEnd: String?
    /// Ultracode: on or off; nil when the menu doesn't offer it.
    public var ultracode: Bool?
    /// What Ultracode does, shown while it is on.
    public var ultracodeNote: String?
    /// What the level costs or means, under the scale.
    public var caption: [String]
    /// The hint at the bottom (`←/→ to adjust · … · Esc to cancel`).
    public var hint: String
    /// `s for this session only` is offered.
    public var takesSession: Bool

    /// The arrows that bring the mark to level `index`.
    public func moves(to index: Int) -> [String] {
        let move = index - current
        return Array(repeating: move > 0 ? "right" : "left", count: abs(move))
    }

    /// The menu at the bottom of `lines`; nil when the screen shows none.
    static func parse(_ lines: [String]) -> EffortMenu? {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        guard let hintAt = lines.lastIndex(where: { $0.contains("to adjust") && $0.localizedCaseInsensitiveContains("esc to cancel") }) else { return nil }
        // The scale: a run of `─` with the mark `▲` in it.
        guard let trackAt = lines[..<hintAt].lastIndex(where: { Self.track($0) != nil }),
              let track = Self.track(lines[trackAt]), trackAt + 1 < hintAt
        else { return nil }
        // The level names under it, each where it sits on the scale.
        let names = Self.words(lines[trackAt + 1]).filter { $0.start <= track.end + 2 }
        guard names.count >= 2 else { return nil }
        let mark = Double(track.mark)
        let current = names.indices.min { abs(names[$0].center - mark) < abs(names[$1].center - mark) } ?? 0
        var menu = EffortMenu(title: "Effort", levels: names.map(\.text), current: current, caption: [], hint: trim(lines[hintAt]),
                              takesSession: lines[hintAt].contains("for this session only"))
        // Ultracode, after the scale on its line: `Ultracode  off`.
        let after = String(Array(lines[trackAt]).dropFirst(track.end + 1)).split(separator: " ").map(String.init)
        if let u = after.firstIndex(where: { $0.lowercased() == "ultracode" }), u + 1 < after.count {
            menu.ultracode = after[u + 1].lowercased() == "on"
        }
        // The ends' words, over the scale.
        if trackAt > 0 {
            let ends = Self.words(lines[trackAt - 1])
            if ends.count == 2 {
                menu.lowEnd = ends[0].text
                menu.highEnd = ends[1].text
            }
        }
        // Over the scale, under the rule: the menu's name.
        var k = trackAt - 2
        while k >= 0, !ScreenPrompt.isRule(lines[k]) {
            let t = trim(lines[k])
            if !t.isEmpty { menu.title = t }
            k -= 1
        }
        // Under the level names: Ultracode's line, then what the level costs.
        for line in lines[(trackAt + 2) ..< hintAt] {
            let t = trim(line)
            guard !t.isEmpty else { continue }
            if t.hasPrefix("Ultracode:") {
                menu.ultracodeNote = trim(String(t.dropFirst("Ultracode:".count)))
            } else {
                menu.caption.append(t)
            }
        }
        return menu
    }

    /// `──────▲─────`: the columns of its first and last dash, and of the mark.
    static func track(_ line: String) -> (start: Int, end: Int, mark: Int)? {
        let chars = Array(line)
        guard let mark = chars.firstIndex(of: "▲") else { return nil }
        var start = mark
        while start > 0, chars[start - 1] == "─" { start -= 1 }
        var end = mark
        while end + 1 < chars.count, chars[end + 1] == "─" { end += 1 }
        // A scale, not a stray mark: dashes on one side at least.
        guard end - start >= 8 else { return nil }
        return (start, end, mark)
    }

    /// The words of a line and where each starts and centers.
    static func words(_ line: String) -> [(text: String, start: Int, center: Double)] {
        let chars = Array(line)
        var out: [(text: String, start: Int, center: Double)] = []
        var i = 0
        while i < chars.count {
            if chars[i] == " " {
                i += 1
                continue
            }
            let start = i
            while i < chars.count, chars[i] != " " { i += 1 }
            out.append((text: String(chars[start ..< i]), start: start, center: Double(start + i - 1) / 2))
        }
        return out
    }
}

// MARK: - /resume

/// Claude Code's list of conversations to resume (`/resume`, 2.1.325):
///
///        Resume session (1 of 154)
///        ╭──────────────────────────╮
///        │ ⌕ Search…                │
///        ╰──────────────────────────╯
///          swiftr
///
///        ❯ Make Messages Mode Look Like Codex
///          20 hours ago · main · 102.8MB
///
///          Improve Swiftr Settings Organization
///          20 hours ago · main · 27.3MB · /Users/me/Projects/swiftr
///
///        ↓ Swiftr et Apple Silicon
///          20 hours ago · main · 488.9KB
///
///          Ctrl+A to show all projects · Ctrl+B to only show current branch · … · Esc to cancel
///
/// Arrows move the cursor (`❯`), the list scrolling under it (`↑`, `↓`
/// beside the edge rows); Enter resumes. Typing goes into the search, which
/// then holds the cursor (no `❯`, hint `Type to Search · Enter to select ·
/// Esc to clear`); ↓ goes back to the list. Ctrl+A shows every project's
/// conversations (each with its folder), Ctrl+B only the current branch's.
public struct ResumeMenu: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        /// From 0, in the order shown.
        public var index: Int
        public var title: String
        /// `20 hours ago · main · 102.8MB`, without the folder.
        public var details: String
        /// The conversation's folder, when every project's show.
        public var folder: String?
        /// The cursor is on it.
        public var focused: Bool

        public var id: Int { index }

        /// `20 hours ago`: when it was last written to.
        public var when: String? {
            details.components(separatedBy: " · ").first
        }
    }

    /// `(1 of 154)`: where the cursor is, of how many.
    public var position: Int?
    public var total: Int?
    /// The search's words; "" while it shows `Search…`.
    public var search: String
    /// The project's name over the list, when only its conversations show.
    public var project: String?
    public var entries: [Entry]
    /// Conversations past the rows shown, above or below.
    public var moreAbove: Bool
    public var moreBelow: Bool
    /// What shows when none does (`No conversations found in this project.`).
    public var empty: String?
    /// Every project's conversations show (`Ctrl+A to only show current repo`).
    public var allProjects: Bool
    /// Ctrl+A switches between this project's and every project's.
    public var canSwitchProjects: Bool
    /// Only the current branch's show; nil when the hint doesn't offer it.
    public var branchOnly: Bool?
    /// The search holds the cursor: typing goes there, ↓ back to the list.
    public var searching: Bool
    public var hint: String

    /// The arrows that bring the cursor to entry `index`; from the search,
    /// ↓ first, which puts it on the first entry.
    public func moves(to index: Int) -> [String] {
        let at = entries.first(where: \.focused)?.index
        let from = at ?? 0
        let move = index - from
        return (at == nil ? ["down"] : []) + Array(repeating: move > 0 ? "down" : "up", count: abs(move))
    }

    static func parse(_ lines: [String]) -> ResumeMenu? {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        // The hint: in the last three lines with text (`Esc to cancel`, `Esc
        // to clear`; `esc to interrupt` is Claude at work).
        let filled = lines.indices.filter { !trim(lines[$0]).isEmpty }
        guard let hintAt = filled.suffix(3).last(where: { i in
            let t = lines[i].lowercased()
            return t.contains("esc to") && !t.contains("interrupt")
        }) else { return nil }
        // The title, alone on its line: `Resume session (1 of 154)`.
        guard let top = lines[..<hintAt].lastIndex(where: { trim($0).wholeMatch(of: /Resume session(?: \(\d+ of \d+\))?/) != nil })
        else { return nil }
        let hint = trim(lines[hintAt])
        var menu = ResumeMenu(search: "", entries: [], moreAbove: false, moreBelow: false, allProjects: false, canSwitchProjects: false,
                              searching: false, hint: hint)
        if let m = trim(lines[top]).firstMatch(of: /\((\d+) of (\d+)\)/) {
            menu.position = Int(m.1)
            menu.total = Int(m.2)
        }
        // The search box, right under the title: `⌕ words`, or `⌕ Search…`
        // while empty. Without it, the words are the conversation's.
        guard let box = lines[(top + 1) ..< hintAt].prefix(3).firstIndex(where: { $0.contains("⌕") }) else { return nil }
        let after = lines[box].components(separatedBy: "⌕").dropFirst().joined(separator: "⌕")
        let words = trim(after.replacingOccurrences(of: "│", with: ""))
        menu.search = words == "Search…" || words == "Search..." ? "" : words
        var start = box + 1
        // Its box's bottom.
        if start < hintAt, ScreenPrompt.isRule(lines[start]) { start += 1 }
        let lower = hint.lowercased()
        menu.allProjects = lower.contains("only show current repo") || lower.contains("only show current project")
        menu.canSwitchProjects = lower.contains("ctrl+a")
        if lower.contains("ctrl+b to only show current branch") {
            menu.branchOnly = false
        } else if lower.contains("ctrl+b to show all branches") {
            menu.branchOnly = true
        }
        menu.searching = lower.hasPrefix("type to search · enter to select")
        // The rows: a title, then its details (`20 hours ago · main · 1MB`).
        let body = Array(lines[start ..< hintAt])
        var i = 0
        while i < body.count {
            let line = body[i]
            let t = trim(line)
            guard !t.isEmpty else {
                i += 1
                continue
            }
            if i + 1 < body.count, Self.isDetails(body[i + 1]) {
                var title = Substring(t)
                var focused = false
                if let f = title.first, "❯›>↑↓".contains(f), title.dropFirst().first == " " {
                    if f == "↑" { menu.moreAbove = true } else if f == "↓" { menu.moreBelow = true } else { focused = true }
                    title = title.dropFirst().drop { $0 == " " }
                }
                var parts = trim(body[i + 1]).components(separatedBy: " · ")
                var folder: String?
                if parts.count > 1, let last = parts.last, last.hasPrefix("/") || last.hasPrefix("~") {
                    folder = last
                    parts.removeLast()
                }
                menu.entries.append(Entry(index: menu.entries.count, title: String(title), details: parts.joined(separator: " · "),
                                          folder: folder, focused: focused))
                // Each with its folder: every project's show, the search's hint doesn't say.
                if folder != nil { menu.allProjects = true }
                i += 2
                continue
            }
            if menu.entries.isEmpty {
                // Over the rows: the project's name; or what shows when none
                // does, with a hint of its own (`Ctrl+A to show all projects`).
                if t.hasPrefix("No ") {
                    menu.empty = t
                } else if menu.empty == nil, menu.project == nil, !t.lowercased().hasPrefix("ctrl+") {
                    menu.project = t
                }
            }
            i += 1
        }
        return menu
    }

    /// `20 hours ago · main · 1MB`: a row's second line.
    static func isDetails(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains(" · ") else { return false }
        let when = t.components(separatedBy: " · ")[0]
        return when.hasSuffix(" ago") || when == "just now" || when == "now" || when.hasPrefix("yesterday")
            || when.firstMatch(of: /^[A-Z][a-z]{2} \d{1,2}/) != nil || when.firstMatch(of: /^\d{4}-\d{2}-\d{2}/) != nil
    }
}

extension ScreenPrompt {
    /// Claude Code's effort menu, as a prompt with no options.
    static func effortMenu(_ lines: [String]) -> ScreenPrompt? {
        guard let menu = EffortMenu.parse(lines) else { return nil }
        var p = ScreenPrompt(question: [menu.title], options: [], footer: menu.hint, numbered: false)
        p.effortMenu = menu
        return p
    }

    /// Claude Code's list of conversations to resume, as a prompt with no options.
    static func resumeMenu(_ lines: [String]) -> ScreenPrompt? {
        guard let menu = ResumeMenu.parse(lines) else { return nil }
        var p = ScreenPrompt(question: ["Resume session"], options: [], footer: menu.hint, numbered: false)
        p.resumeMenu = menu
        return p
    }
}
