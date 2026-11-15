import Foundation

/// A choice a program shows at the bottom of its screen, such as Claude
/// Code's permission prompts, plan approval and questions:
///
///     ────────────────────────────────
///      Bash command
///      List files
///     ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
///      ls -la
///     ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
///      Do you want to proceed?
///      ❯ 1. Yes
///        2. Yes, allow reading from /tmp from this project
///        3. No
///      Esc to cancel · Tab to amend
///
/// Options are numbered (a digit picks one) or not (arrows and Enter, as in
/// the folder trust dialog).
public struct ScreenPrompt: Sendable, Equatable {
    public struct Option: Sendable, Equatable, Identifiable {
        /// From 1, as shown (or counted, when the options carry no number).
        public var number: Int
        public var label: String
        /// Lines under the option that describe it.
        public var detail: String
        /// The program's cursor is on it.
        public var focused: Bool
        /// A multi-select option's box: checked or not. Nil for plain options.
        public var checked: Bool?

        public var id: Int { number }

        public init(number: Int, label: String, detail: String = "", focused: Bool = false, checked: Bool? = nil) {
            self.number = number
            self.label = label
            self.detail = detail
            self.focused = focused
            self.checked = checked
        }
    }

    /// One of AskUserQuestion's tabs: a question's header, or Submit.
    public struct Tab: Sendable, Equatable {
        public var title: String
        /// ☒: answered; ☐: not yet.
        public var answered: Bool
        /// The last tab, `✔ Submit`.
        public var isSubmit: Bool
    }

    /// The lines right above the options: what is asked.
    public var question: [String]
    public var options: [Option]
    /// The hint under the options (`Esc to cancel · Tab to amend`).
    public var footer: String
    /// What the prompt is about, from the top of its box down to the
    /// question: a title, a command, a diff… Sections apart by "".
    public var context: [String] = []
    /// The options carry numbers.
    public var numbered = true
    /// AskUserQuestion's tabs, when it shows them.
    public var tabs: [Tab] = []
    /// A multi-select question's `Submit` line, under its options.
    public var hasSubmitLine = false
    /// The program's cursor is on that `Submit` line.
    public var submitFocused = false
    /// The options sit side by side, as OpenCode's buttons do: → and ← move
    /// between them, and the program's cursor starts on the first.
    public var horizontal = false
    /// One of OpenCode's pickers: an option is chosen by typing its name
    /// in the picker's search, then Enter.
    public var searchable = false
    /// The call a permission is for, as the screen draws it: Gemini writes
    /// a call to its chat only once it is done.
    public var call: ToolCall?
    /// A question answered in words, typed into its field (Gemini's
    /// `> e.g. notes.txt`), then Enter.
    public var takesText = false
    /// Gemini's question: its option for one's own words (`Enter a custom
    /// value`), when its list shows it.
    public var customOption: Int?
    /// Gemini's question: the words typed in its field, or on its option
    /// for one's own words; "" while that shows `Enter a custom value` or
    /// its field `Enter your response`. Another hint of the question's own
    /// (`e.g. notes.txt`) reads like words: only its color tells.
    public var typedWords = ""
    /// Gemini's question: its list scrolls between `▲` and `▼` (three rows
    /// at most while its view is held to the screen), some answers out of
    /// sight. ⌃O, its `show more lines`, draws them all.
    public var listScrolls = false
    /// Gemini's question that takes several answers: the digit of its
    /// `Done` row, which Gemini draws without one (the next after the line
    /// for one's own words), when the row shows. `hasSubmitLine` and
    /// `submitFocused` say it shows and holds the cursor.
    public var doneNumber: Int?
    /// Claude Code's model picker: its `More models` row, its window, its effort.
    public var modelPicker: ModelPicker?
    /// Claude Code's effort menu (`/effort`): a scale, no options.
    public var effortMenu: EffortMenu?
    /// Claude Code's list of conversations to resume (`/resume`).
    public var resumeMenu: ResumeMenu?
    /// AskUserQuestion's options beside their previews (a mockup Claude
    /// drew for each): a digit only moves the cursor, Enter picks. One's
    /// own words go in as notes (`n` opens them, Esc closes them, Enter
    /// there answers), and `Chat about this` has no digit: ↓ from the last
    /// option reaches it.
    public var previews = false
    /// The notes under the previews; "" when there are none.
    public var notes = ""
    /// The notes are open for typing (true), closed (false), or nil when
    /// only the screen's colors tell: closed notes show dim.
    public var notesOpen: Bool?
    /// The cursor is on `Chat about this` (the option over it keeps its ❯).
    public var chatFocused = false
    /// Codex's list in a short pane (`option 3/4` under it): how many
    /// options it holds; `options` has those in sight. A digit still picks
    /// one out of sight.
    public var listTotal: Int?

    public init(question: [String], options: [Option], footer: String, context: [String] = [], numbered: Bool = true, tabs: [Tab] = [], hasSubmitLine: Bool = false) {
        self.question = question
        self.options = options
        self.footer = footer
        self.context = context
        self.numbered = numbered
        self.tabs = tabs
        self.hasSubmitLine = hasSubmitLine
    }

    /// The box's first line: `Bash command`, `Edit file`, `Ready to code?`.
    public var title: String? {
        context.lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// The first line of text over the options, in the box or above them: a menu's name (`Rewind`).
    public var heading: String? {
        (context + question).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// `/rewind`'s list of the messages it can go back to, `(current)` last.
    public var isRewindList: Bool {
        heading == "Rewind" && options.last?.label == "(current)"
    }

    /// `/rewind`'s second step: what to restore to the point before the message chosen.
    public var isRewindConfirm: Bool {
        heading == "Rewind" && options.contains { $0.label.hasPrefix("Restore ") }
    }

    /// `/rewind`'s second step, read for a card: what it asks, the message it
    /// quotes and when that was sent, and what restoring does.
    public struct RewindDetails: Sendable, Equatable {
        public var intro: String?
        public var message: [String]
        /// "2h ago".
        public var ago: String?
        public var notes: [String]
    }

    /// Codex's approval prompt: what it asks (`Would you like to run the
    /// following command?`), why, and what it would run or change.
    public struct CodexApproval: Sendable, Equatable {
        public var question: String
        /// `Reason: …`, without the word.
        public var reason: String?
        /// The command, without its `$ `; lines the screen wrapped joined back.
        public var command: String?
        /// What else it shows: the files of an edit, the permissions asked.
        public var details: [String] = []
    }

    public var codexApproval: CodexApproval? {
        let lines = (context + question).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let q = lines.firstIndex(where: { $0.hasPrefix("Would you like to ") }) else { return nil }
        var approval = CodexApproval(question: lines[q])
        var command: [String] = []
        var inCommand = false
        for line in lines[(q + 1)...] {
            if line.isEmpty {
                inCommand = false
            } else if line.hasPrefix("Reason: ") {
                approval.reason = String(line.dropFirst("Reason: ".count))
            } else if line.hasPrefix("$ ") {
                command.append(String(line.dropFirst(2)))
                inCommand = true
            } else if inCommand {
                command.append(line)
            } else {
                approval.details.append(line)
            }
        }
        if !command.isEmpty { approval.command = command.joined(separator: " ") }
        return approval
    }

    /// `Yes, proceed (y)` → `Yes, proceed`: the key a program names for an
    /// option (Codex's `(y)`, Claude's `(shift+tab)`), which a card
    /// answering with a click doesn't need.
    public static func withoutKeyHint(_ label: String) -> String {
        guard let r = label.range(of: #"\s*\((?:[a-z]|esc|enter|tab|shift\+tab|ctrl\+[a-z])\)$"#, options: .regularExpression) else { return label }
        return String(label[..<r.lowerBound])
    }

    /// A hint made only of keys and what they do (`esc to interrupt`, `Tab
    /// to amend`, `↑↓ select  enter submit`): the program's, for its
    /// terminal, where a card answers with clicks.
    public static func isKeyHint(_ hint: String) -> Bool {
        let parts = hint.replacingOccurrences(of: #"\s*[|·]\s*|\s{2,}"#, with: "\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let key = #"(?:tab|enter|return|esc|escape|space|shift\+tab|ctrl\+\w|alt\+\w|⇧tab|⇆\s*tab|↑↓|←→|↑|↓|←|→|⏎)"#
        let part = #"^(?:press\s+)?"# + key + #"(?:\s*(?:/|or)\s*"# + key + #")*\s+\w"#
        return !parts.isEmpty && parts.allSatisfy { $0.range(of: part, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Codex's count over the question it asks (`Question 1/2 (2
    /// unanswered)`): which one this is, of how many.
    public static func codexQuestionCount(_ line: String) -> (index: Int, total: Int)? {
        guard let m = line.trimmingCharacters(in: .whitespaces).wholeMatch(of: #/Question (\d+)/(\d+)(?: \(\d+ unanswered\))?/#),
              let index = Int(m.1), let total = Int(m.2)
        else { return nil }
        return (index, total)
    }

    /// An edit as Claude Code draws it in its box, for when its call isn't
    /// in the transcript yet: the file's name, then the numbered lines
    /// (`2 -bye`, `3 +goodbye`), without the "No newline at end of file" notes.
    public struct ScreenDiff: Sendable, Equatable {
        public var file: String?
        public var lines: [LineDiff.Line]
    }

    public var screenDiff: ScreenDiff? {
        guard title?.localizedCaseInsensitiveContains("file") == true else { return nil }
        // Sections apart by "": the file's name, then the diff.
        var sections: [[String]] = [[]]
        for line in context.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !(sections.last?.isEmpty ?? true) { sections.append([]) }
            } else {
                sections[sections.count - 1].append(line)
            }
        }
        guard let k = sections.firstIndex(where: { !$0.isEmpty && $0.allSatisfy { Self.diffLine($0) != nil } }) else { return nil }
        let lines = sections[k].compactMap(Self.diffLine)
            .filter { $0.text.trimmingCharacters(in: .whitespaces) != "No newline at end of file" }
        let file = k > 0 ? sections[k - 1].last?.trimmingCharacters(in: .whitespaces) : nil
        return ScreenDiff(file: file, lines: lines)
    }

    /// `2 -bye`: removed; `3 +goodbye`: added; `1  hi`: kept.
    static func diffLine(_ s: String) -> LineDiff.Line? {
        guard let m = s.firstMatch(of: #/^\s*\d+ ([-+ ])(.*)$/#) else { return nil }
        let text = String(m.2)
        switch m.1 {
        case "-": return LineDiff.Line(.removed, text)
        case "+": return LineDiff.Line(.added, text)
        default: return LineDiff.Line(.same, text)
        }
    }

    /// The parts of `/rewind`'s second step. Its lines share the box's indent;
    /// the quoted message's lost their bar (`│`), so they sit further left.
    public var rewindDetails: RewindDetails? {
        guard isRewindConfirm else { return nil }
        func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }
        var lines = (context + question).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let head = lines.first, head.trimmingCharacters(in: .whitespaces) == "Rewind" else { return nil }
        lines.removeFirst()
        let margin = indent(head)
        var r = RewindDetails(intro: nil, message: [], ago: nil, notes: [])
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if indent(line) < margin {
                if t.hasPrefix("("), t.hasSuffix(" ago)") { r.ago = String(t.dropFirst().dropLast()) } else { r.message.append(t) }
            } else if r.intro == nil, r.message.isEmpty, r.notes.isEmpty {
                r.intro = t
            } else {
                r.notes.append(t)
            }
        }
        return r
    }

    /// AskUserQuestion's last step: the answers, to submit or cancel.
    public var isReview: Bool {
        (context + question).contains { $0.trimmingCharacters(in: .whitespaces) == "Review your answers" }
            || question.contains { $0.contains("Ready to submit your answers?") }
    }

    /// Options with check boxes: several may be chosen.
    public var isMultiSelect: Bool { options.contains { $0.checked != nil } }

    /// `Tab to amend`: a note can go with the choice.
    public var canAmend: Bool { footer.localizedCaseInsensitiveContains("tab to amend") }

    /// The question's text, without its tab bar.
    public var questionText: String {
        question.filter { Self.tabs(in: $0) == nil }.map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The prompt at the bottom of `screen`, nil if it shows none.
    public static func parse(screen: String) -> ScreenPrompt? {
        let raw = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lines = raw.map(clean)
        return modelPicker(lines) ?? effortMenu(lines) ?? resumeMenu(lines) ?? previewQuestion(raw)
            ?? numbered(lines) ?? spaced(lines) ?? unnumbered(lines)
    }

    // MARK: Numbered options

    /// `longDetails`: descriptions of any length, inside a box that is
    /// surely a prompt's (OpenCode's questions wrap theirs over many lines
    /// in a narrow pane).
    private static func numbered(_ lines: [String], longDetails: Bool = false) -> ScreenPrompt? {
        // The last option line: the end of the choice.
        guard let last = lines.lastIndex(where: { option($0) != nil }), let lastOption = option(lines[last]) else { return nil }
        // Only a footer and blank lines may follow a prompt's options; an
        // input box under them means they are text on the screen.
        let after = lines[(last + 1)...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard after.count <= 8 else { return nil }
        for (k, line) in after.enumerated() where isBoxTop(line) && k + 1 < after.count {
            let next = after[k + 1].trimmingCharacters(in: .whitespaces)
            if next.hasPrefix("❯") || next.hasPrefix(">"), option(after[k + 1]) == nil { return nil }
        }
        // Codex's list in a short pane: the options in sight, `option 3/4 | …` under them.
        let window = after.prefix(4).lazy.compactMap(listWindow).first
        var options: [Option] = []
        var detail: [String] = []
        var expected = lastOption.number
        var first = last
        var i = last
        var submitLine = false
        var submitCursor = false
        while i >= 0 {
            let line = lines[i]
            // Over the first option in sight: the question, left of the numbers.
            if window != nil, !options.isEmpty, detail.isEmpty, option(line) == nil,
               !line.trimmingCharacters(in: .whitespaces).isEmpty, indent(line) < lastOption.column
            {
                break
            }
            if let o = option(line), o.number == expected {
                var label = o.label
                let checked = checkbox(&label)
                // `Switch to gpt-6-luna      Fast and affordable…`: a name, then what it is.
                let (name, aside) = columns(label)
                label = name
                if !aside.isEmpty { detail.append(aside) }
                // Multi-select: the `Submit` line under the last box.
                if let s = detail.firstIndex(of: "Submit"), checked != nil {
                    detail.remove(at: s)
                    submitLine = true
                }
                options.insert(Option(number: o.number, label: label, detail: detail.reversed().joined(separator: "\n"), focused: o.focused, checked: checked), at: 0)
                detail = []
                first = i
                if o.number == 1 { break }
                expected -= 1
            } else if isRule(line) {
                // A rule inside the list (AskUserQuestion puts "Chat about this"
                // under one) when the option above it comes next; else the
                // options above a rule aren't these.
                guard detail.isEmpty,
                      let above = lines[..<i].lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitLine($0) }),
                      let o = option(lines[above]), o.number == expected
                else { return nil }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if isSubmitLine(line) {
                    detail.append("Submit")
                    if line.contains("❯") { submitCursor = true }
                } else {
                    detail.append(line.trimmingCharacters(in: .whitespaces))
                }
                // Descriptions are short; a long run of text isn't one.
                if detail.count > 8, !longDetails { return nil }
            }
            i -= 1
        }
        if let window {
            guard let top = options.first?.number, top + options.count - 1 <= window.total else { return nil }
        } else {
            guard options.first?.number == 1, options.count >= 2 else { return nil }
        }
        // Under the last option: its description (indented past its number), then the hint.
        var below = last + 1
        var lastDetail: [String] = []
        while below < lines.count {
            let line = lines[below]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isRule(line) { break }
            guard indent(line) > lastOption.column else { break }
            lastDetail.append(trimmed)
            below += 1
        }
        if !lastDetail.isEmpty {
            let aside = options[options.count - 1].detail
            options[options.count - 1].detail = ([aside] + lastDetail).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        var footer = lines[below...].map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !isRule($0) } ?? ""
        if window != nil, let r = footer.range(of: #"^option \d+/\d+\s*(\|\s*)?"#, options: .regularExpression) {
            footer.removeSubrange(r)
        }
        var prompt = surroundings(of: first, in: lines)
        // Codex's check before answers that leave a question out: its own
        // words, not the conversation over them.
        if let k = prompt.question.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Submit with unanswered questions?" }) {
            prompt.question = unindented(Array(prompt.question[k...]))
            prompt.context = []
        }
        prompt.options = options
        prompt.listTotal = window?.total
        prompt.footer = footer
        prompt.hasSubmitLine = submitLine
        prompt.submitFocused = submitLine && submitCursor
        return prompt
    }

    // MARK: Options without numbers

    /// `❯ No, exit` / `  Yes, I trust this folder`, then `Enter to confirm`.
    private static func unnumbered(_ lines: [String]) -> ScreenPrompt? {
        guard let cursor = lines.lastIndex(where: { cursorLabel($0) != nil }), let (column, _) = cursorLabel(lines[cursor]) else { return nil }
        // The options: the lines next to the cursor's, their text where its starts.
        func label(_ line: String) -> String? {
            if let (c, text) = cursorLabel(line) { return c == column ? text : nil }
            guard indent(line) == column else { return nil }
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        var start = cursor
        while start > 0, label(lines[start - 1]) != nil { start -= 1 }
        var end = cursor
        while end + 1 < lines.count, label(lines[end + 1]) != nil { end += 1 }
        guard end > start else { return nil }
        // Only a real choice says how to make it, under the options or a line or two lower.
        let below = lines[(end + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !isRule($0) }.prefix(4)
        guard let footer = below.first(where: { $0.localizedCaseInsensitiveContains("enter to") }) else { return nil }
        var options: [Option] = []
        for (n, i) in (start ... end).enumerated() {
            // `User instructions      Saved in ~/.claude/CLAUDE.md`: a name, then what it is.
            let (name, aside) = columns(label(lines[i]) ?? "")
            options.append(Option(number: n + 1, label: name, detail: aside, focused: i == cursor))
        }
        var prompt = surroundings(of: start, in: lines)
        prompt.options = options
        prompt.footer = footer
        prompt.numbered = false
        return prompt
    }

    // MARK: Options apart by blank lines

    /// Options of a line or a few, a blank line between them, as `/rewind`
    /// lists the messages it can go back to:
    ///
    ///       Fix the login page
    ///       2 files changed
    ///
    ///     ❯ (current)
    ///
    ///     Enter to continue · Esc to cancel
    ///
    /// An option's first line names it; the lines under it describe it.
    private static func spaced(_ lines: [String]) -> ScreenPrompt? {
        guard let cursor = lines.lastIndex(where: { cursorLabel($0) != nil }), let (column, _) = cursorLabel(lines[cursor]) else { return nil }
        func blank(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).isEmpty }
        func sign(_ i: Int) -> Bool { cursorLabel(lines[i]) != nil }
        // An option's line: its text where the cursor's starts.
        func inColumn(_ i: Int) -> Bool {
            if let (c, _) = cursorLabel(lines[i]) { return c == column }
            return !blank(i) && indent(lines[i]) == column
        }
        // The cursor's option: its line, then the lines under it.
        var end = cursor
        while end + 1 < lines.count, inColumn(end + 1), !sign(end + 1) { end += 1 }
        var blocks = [cursor ... end]
        // Above: a blank line, then the last line of another option.
        var i = cursor - 1
        while i >= 1, blank(i), inColumn(i - 1) {
            var start = i - 1
            while start > 0, !sign(start), inColumn(start - 1) { start -= 1 }
            // One cursor only: a second one is another list's (`/memory` has two).
            if sign(start) { return nil }
            blocks.insert(start ... i - 1, at: 0)
            i = start - 1
        }
        // Below, the same way.
        var j = end + 1
        while j + 1 < lines.count, blank(j), inColumn(j + 1), !sign(j + 1) {
            var last = j + 1
            while last + 1 < lines.count, inColumn(last + 1), !sign(last + 1) { last += 1 }
            blocks.append(j + 1 ... last)
            j = last + 1
        }
        // Options of a few lines each; one block alone is a plain list.
        guard blocks.count >= 2, blocks.allSatisfy({ $0.count <= 4 }) else { return nil }
        // Only a real choice says how to make it, under the options or a line or two lower.
        let below = lines[min(j, lines.count)...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !isRule($0) }.prefix(4)
        guard let footer = below.first(where: { $0.localizedCaseInsensitiveContains("enter to") || $0.localizedCaseInsensitiveContains("esc to") })
        else { return nil }
        // `↑ 5 more` over the first message shown, `↓ 2 more` under the
        // last: where the list scrolls, no option nor part of one.
        func scrollMark(_ i: Int) -> Bool {
            lines[i].trimmingCharacters(in: .whitespaces).wholeMatch(of: /[↑↓] \d+ more/) != nil
        }
        var options: [Option] = []
        for block in blocks {
            let rows = block.filter { !scrollMark($0) }
            guard let top = rows.first else { continue }
            let first = cursorLabel(lines[top])?.text ?? lines[top].trimmingCharacters(in: .whitespaces)
            let detail = rows.dropFirst().map { lines[$0].trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            options.append(Option(number: options.count + 1, label: first, detail: detail, focused: top == cursor))
        }
        guard options.count >= 2 else { return nil }
        let start = blocks[0].lowerBound
        var prompt = surroundings(of: start > 0 && scrollMark(start - 1) ? start - 1 : start, in: lines)
        prompt.options = options
        prompt.footer = footer
        prompt.numbered = false
        return prompt
    }

    /// `option 3/4 | tab to add notes | …`: Codex's list in a short pane
    /// shows some of its options; this says where the cursor is, of how many.
    static func listWindow(_ line: String) -> (at: Int, total: Int)? {
        guard let m = line.trimmingCharacters(in: .whitespaces).firstMatch(of: #/^option (\d+)/(\d+)(?:\s|$)/#),
              let at = Int(m.1), let total = Int(m.2), at >= 1, at <= total
        else { return nil }
        return (at, total)
    }

    /// A label set out in columns, two spaces or more apart: the first, and the rest.
    static func columns(_ text: String) -> (String, String) {
        let parts = text.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count > 1 else { return (text, "") }
        return (parts[0], parts.dropFirst().joined(separator: " "))
    }

    /// `❯ text` at some column: the column of its text, and the text.
    private static func cursorLabel(_ line: String) -> (column: Int, text: String)? {
        let s = Substring(line).drop { $0 == " " }
        guard let first = s.first, "❯›▶→".contains(first) else { return nil }
        let rest = s.dropFirst().drop { $0 == " " }
        guard !rest.isEmpty, option(line) == nil else { return nil }
        return (line.count - rest.count, String(rest).trimmingCharacters(in: .whitespaces))
    }

    // MARK: Panels

    /// One of Claude Code's own screens at the bottom (`/memory`, `/config`,
    /// `/status`…), its options unknown: its text from the rule over it, and
    /// the hint that says how to leave it (`Esc to cancel`). Nil when the
    /// screen's last lines give no such hint.
    public static func panel(screen: String) -> ScreenPrompt? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { clean(String($0)) }
        let filled = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        // The hint: in the last three lines with text. `esc to interrupt` is Claude at work.
        guard let hintAt = filled.suffix(3).last(where: { i in
            let t = lines[i].lowercased()
            return t.contains("esc to") && !t.contains("interrupt")
        }) else { return nil }
        var body: [String] = []
        var j = hintAt - 1
        while j >= 0, body.count < 40, !isRule(lines[j]) {
            body.insert(lines[j], at: 0)
            j -= 1
        }
        let text = unindented(trimmed(body))
        guard !text.isEmpty else { return nil }
        return ScreenPrompt(question: [], options: [], footer: lines[hintAt].trimmingCharacters(in: .whitespaces), context: text, numbered: false)
    }

    // MARK: Above the options

    /// The question above the option at `first`, and what comes above it
    /// up to the top of the prompt's box.
    static func surroundings(of first: Int, in lines: [String]) -> ScreenPrompt {
        // What is asked: the lines above, up to a rule or a box's top.
        var question: [String] = []
        var j = first - 1
        while j >= 0, question.count < 30 {
            let line = lines[j]
            if isRule(line) { break }
            question.insert(line, at: 0)
            j -= 1
        }
        question = trimmed(question)
        // Keep the indentation the program gave, less what all lines share.
        question = unindented(question)
        var tabs: [Tab] = []
        if let bar = question.lazy.compactMap({ Self.tabs(in: $0) }).first { tabs = bar }
        // Above a dashed rule: the sections of the same box, up to its top.
        var context: [String] = []
        if j >= 0, isDashed(lines[j]) {
            var section: [String] = []
            var k = j - 1
            var count = 0
            while k >= 0, count < 80 {
                let line = lines[k]
                if isRule(line) {
                    if !isDashed(line) { break }
                    context.insert(contentsOf: [""] + unindented(trimmed(section)), at: 0)
                    section = []
                } else {
                    section.insert(line, at: 0)
                }
                k -= 1
                count += 1
            }
            context.insert(contentsOf: unindented(trimmed(section)), at: 0)
            context = trimmed(context)
            if let bar = context.lazy.compactMap({ Self.tabs(in: $0) }).first, tabs.isEmpty { tabs = bar }
        }
        return ScreenPrompt(question: question, options: [], footer: "", context: context, tabs: tabs)
    }

    private static func trimmed(_ lines: [String]) -> [String] {
        var out = lines
        while let f = out.first, f.trimmingCharacters(in: .whitespaces).isEmpty { out.removeFirst() }
        while let l = out.last, l.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        return out
    }

    private static func unindented(_ lines: [String]) -> [String] {
        let shared = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(indent).min() ?? 0
        return lines.map { String($0.dropFirst(min(shared, indent($0)))) }
    }

    /// `←  ☐ Color  ☒ Pets  ✔ Submit  →`: AskUserQuestion's tabs.
    static func tabs(in line: String) -> [Tab]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("☐") || t.contains("☒") || t.contains("✔ Submit") else { return nil }
        var tabs: [Tab] = []
        var current: (mark: Character, title: String)?
        func close() {
            if let c = current {
                let title = c.title.trimmingCharacters(in: .whitespaces)
                tabs.append(Tab(title: title, answered: c.mark == "☒", isSubmit: c.mark == "✔" && title == "Submit"))
            }
            current = nil
        }
        for ch in t {
            if ch == "☐" || ch == "☒" || ch == "✔" {
                close()
                current = (ch, "")
            } else if ch == "←" || ch == "→" {
                close()
            } else if current != nil {
                current!.title.append(ch)
            }
        }
        close()
        return tabs.isEmpty ? nil : tabs
    }

    /// `[ ] Cat` / `[✔] Cat`: the box's state, and the label without it.
    private static func checkbox(_ label: inout String) -> Bool? {
        for (box, checked) in [("[ ] ", false), ("[✔] ", true), ("[✓] ", true), ("[x] ", true), ("[X] ", true), ("[×] ", true)] where label.hasPrefix(box) {
            label = String(label.dropFirst(box.count)).trimmingCharacters(in: .whitespaces)
            return checked
        }
        if label == "[ ]" { label = ""; return false }
        return nil
    }

    static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// A multi-select question's `Submit` line, the cursor on it or not.
    static func isSubmitLine(_ line: String) -> Bool {
        var t = Substring(line.trimmingCharacters(in: .whitespaces))
        if let f = t.first, "❯›>".contains(f) { t = t.dropFirst() }
        return t.trimmingCharacters(in: .whitespaces) == "Submit"
    }


    // MARK: Keys

    /// Keys that choose `option`: its digit, or Esc for the "No (esc)" one,
    /// or arrows and Enter.
    public func keys(for option: Option) -> [String] {
        if option.label.lowercased().contains("(esc)") { return ["esc"] }
        // Codex's `Submit with unanswered questions?`: a digit only moves its cursor.
        if isCodexSubmitCheck, option.number <= 9 { return ["\(option.number)", "enter"] }
        // OpenCode: Esc rejects, wherever its cursor is.
        if horizontal, option.label.lowercased() == "reject" { return ["esc"] }
        if numbered, option.number <= 9 { return ["\(option.number)"] }
        return moves(to: option) + ["enter"]
    }

    /// Codex asks before it sends answers that leave a question out:
    /// `Submit with unanswered questions?`, `Proceed` or `Go back`.
    public var isCodexSubmitCheck: Bool {
        (context + question).contains { $0.trimmingCharacters(in: .whitespaces) == "Submit with unanswered questions?" }
    }

    /// Codex's question, its list scrolled in a short pane: every option,
    /// those out of sight from its call (`choices`, the question's own
    /// options; Codex adds `None of the above` under them). Descriptions
    /// come from the call too: the screen may cut the last one in sight.
    /// As it is when the call doesn't hold as many.
    public func wholeList(_ choices: [AskQuestion.Choice]) -> ScreenPrompt {
        guard let total = listTotal, total == choices.count || total == choices.count + 1 else { return self }
        var p = self
        p.options = (1 ... total).map { n in
            let choice = n <= choices.count ? choices[n - 1] : nil
            if var shown = options.first(where: { $0.number == n }) {
                if let choice, choice.label == shown.label { shown.detail = choice.detail }
                return shown
            }
            if let choice { return Option(number: n, label: choice.label, detail: choice.detail) }
            return Option(number: n, label: "None of the above", detail: "Optionally, add details in notes (tab)")
        }
        return p
    }

    /// Arrow presses that bring the program's cursor to `option`.
    public func moves(to option: Option) -> [String] {
        let at = options.first(where: \.focused)?.number ?? (submitFocused ? doneNumber : nil) ?? 1
        let move = option.number - at
        let (forward, back) = horizontal ? ("right", "left") : ("down", "up")
        return Array(repeating: move > 0 ? forward : back, count: abs(move))
    }

    /// The option labelled `text` (case and a trailing period aside).
    public func option(labelled text: String) -> Option? {
        func norm(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespaces).lowercased()
            while t.hasSuffix(".") { t.removeLast() }
            return t
        }
        let want = norm(text)
        return options.first { norm($0.label) == want }
    }

    // MARK: Lines

    /// The line without a box's side bars and trailing spaces.
    static func clean(_ line: String) -> String {
        var s = Substring(line)
        while let l = s.last, l == " " || l == "\u{a0}" { s = s.dropLast() }
        if s.hasSuffix("│") || s.hasSuffix("┃") { s = s.dropLast() }
        while let l = s.last, l == " " { s = s.dropLast() }
        let lead = s.prefix { $0 == " " }
        let rest = s.dropFirst(lead.count)
        if rest.hasPrefix("│") || rest.hasPrefix("┃") { s = rest.dropFirst() }
        return String(s)
    }

    /// `❯ 2. Yes, and…` → 2, "Yes, and…", focused, and the column of its number.
    /// `↓ 5. Summarize…`: an arrow says the list goes on past the screen.
    static func option(_ line: String) -> (number: Int, label: String, focused: Bool, column: Int)? {
        var s = Substring(line).drop { $0 == " " }
        var focused = false
        while let first = s.first, "❯›>▶→↑↓".contains(first) {
            if first != "↑", first != "↓" { focused = true }
            s = s.dropFirst().drop { $0 == " " }
        }
        let column = line.count - s.count
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard (1 ... 2).contains(digits.count), let n = Int(digits), n >= 1 else { return nil }
        s = s.dropFirst(digits.count)
        guard let mark = s.first, mark == "." || mark == ")" else { return nil }
        s = s.dropFirst()
        guard s.first == " " else { return nil }
        let label = s.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (n, label, focused, column)
    }

    /// A line drawn across: `────`, `╌╌╌╌`, a box's top or bottom.
    public static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 8 else { return false }
        let drawing = t.filter { "─━═╌┄-╭╮╰╯┌┐└┘▔▁".contains($0) }.count
        return drawing * 10 >= t.count * 8
    }

    /// A dashed rule, between the sections of one prompt.
    public static func isDashed(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return isRule(line) && t.filter { "╌┄".contains($0) }.count * 2 >= t.count
    }

    /// The rule over Claude Code's input box. Claude Code writes in it, a
    /// space either side: the session's title at its end
    /// (`──────── Fix the login page ─`), a hint at its start. A long title
    /// leaves too few dashes for `isRule`.
    public static func isBoxTop(_ line: String) -> Bool {
        if isRule(line) { return !isDashed(line) }
        let t = line.trimmingCharacters(in: .whitespaces)
        let lead = t.prefix { $0 == "─" }.count
        let trail = t.reversed().prefix { $0 == "─" }.count
        guard lead >= 1, trail >= 1, max(lead, trail) >= 6, lead + trail < t.count else { return false }
        let text = t.dropFirst(lead).dropLast(trail)
        return text.count >= 3 && text.first == " " && text.last == " "
    }
}

// MARK: - OpenCode's prompts

extension ScreenPrompt {
    /// What OpenCode asks at the bottom of its screen: a permission
    ///
    ///     △ Permission required
    ///       → Edit notes.txt
    ///     1 - hello                 1 + goodbye
    ///      Allow once   Always allow   Reject      ctrl+f fullscreen  ⇆ select  enter confirm
    ///
    /// or its questions: `Questions`, a tab bar when there are several
    /// (`Fruit  Toppings  Submit`), the question, numbered options (`[ ]`
    /// boxes when several may be chosen), the last one `Type your own answer`.
    /// OpenCode 1.x writes no `Questions` and ends its tab bar with
    /// `Confirm`: its box is the `┃` lines down to the hints (`esc dismiss`).
    public static func parseOpenCode(screen: String) -> ScreenPrompt? {
        let raw = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lines = raw.map { clean($0) }
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        if let buttons = lines.lastIndex(where: { $0.contains("Allow once") && $0.contains("Reject") }) {
            guard let top = lines[..<buttons].lastIndex(where: { $0.contains("Permission required") }) else { return nil }
            let title = String(trim(lines[top]).drop { !$0.isLetter })
            // What it is about: the call, a diff side by side; blank runs made one.
            var body: [String] = []
            for line in unindented(trimmed(Array(lines[(top + 1) ..< buttons]))) where !(line.isEmpty && body.last?.isEmpty == true) {
                body.append(line)
            }
            let parts = lines[buttons].components(separatedBy: "  ").map(trim).filter { !$0.isEmpty }
            let hintAt = parts.firstIndex { $0.contains("select") || $0.contains("confirm") || $0.contains("fullscreen") } ?? parts.count
            let labels = Array(parts[..<hintAt])
            guard labels.count >= 2 else { return nil }
            let options = labels.enumerated().map { Option(number: $0.offset + 1, label: $0.element, focused: $0.offset == 0) }
            var prompt = ScreenPrompt(question: [], options: options, footer: parts[hintAt...].joined(separator: " · "), context: [title] + body, numbered: false)
            prompt.horizontal = true
            return prompt
        }
        // In a wide pane OpenCode's side column shares the box's rows.
        let main = lines.map(openCodeMain)
        let start: Int
        var title = "Questions"
        if let head = main.lastIndex(where: { ["Questions", "Question"].contains(trim($0)) }) {
            start = head + 1
            title = trim(main[head])
        } else if let top = openCodeQuestionBox(raw, main) {
            start = top
        } else {
            return nil
        }
        guard var prompt = numbered(Array(main[start...]), longDetails: true) else { return nil }
        // The tab bar: the questions' headers, then Submit (1.x: Confirm).
        if let bar = prompt.question.firstIndex(where: { !trim($0).isEmpty }) {
            let names = prompt.question[bar].components(separatedBy: "  ").map(trim).filter { !$0.isEmpty }
            if names.count >= 2, let last = names.last, ["Submit", "Confirm"].contains(last) {
                prompt.tabs = names.map { Tab(title: $0, answered: false, isSubmit: $0 == last) }
                prompt.question.remove(at: bar)
            }
        }
        prompt.question = unindented(trimmed(prompt.question))
        prompt.context = [title]
        return prompt
    }

    /// A row of OpenCode's screen (its box's bar taken off) without the
    /// side column OpenCode draws in a wide pane (`Connect provider
    /// /connect`, the session's notes) on the same rows as its question
    /// box. The box's text starts a few columns in and holds no run of six
    /// spaces; a row whose text starts far right is the column's alone.
    public static func openCodeMain(_ line: String) -> String {
        let chars = Array(line)
        guard let first = chars.firstIndex(where: { $0 != " " }) else { return line }
        if first > 12 { return "" }
        var i = first
        while i < chars.count {
            guard chars[i] == " " else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j] == " " { j += 1 }
            if j - i >= 6, j < chars.count { return String(chars[..<i]) }
            i = j
        }
        return line
    }

    /// OpenCode 1.x's question box: the first of the `┃` lines that run
    /// down to its hints (`↑↓ select  enter submit  esc dismiss`).
    private static func openCodeQuestionBox(_ raw: [String], _ lines: [String]) -> Int? {
        guard let hints = lines.lastIndex(where: { $0.contains("esc dismiss") && $0.contains("enter ") }) else { return nil }
        func boxed(_ line: String) -> Bool { line.drop { $0 == " " }.first == "┃" }
        guard boxed(raw[hints]) else { return nil }
        var top = hints
        while top > 0, hints - top < 40, boxed(raw[top - 1]) { top -= 1 }
        return top
    }

    /// One of OpenCode's own screens over the conversation: a picker
    /// (`/models`, `/agents`, `/themes`…) or a panel (release highlights),
    /// its box cut out of what lies under it:
    ///
    ///     Select model                                     esc
    ///
    ///     Search
    ///
    ///       Big Pickle                                      Free
    ///     ● GLM-5.3-Flash Free                              Free
    ///
    ///       View all integrations ctrl+a  Favorite ctrl+f
    ///
    /// A picker's options are its list (`●` marks the one in use), a
    /// panel's text its context. `query`: what was typed in the picker's
    /// search, shown in place of `Search`. Nil when no such box shows.
    public static func openCodeDialog(screen: String, query: String? = nil) -> ScreenPrompt? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { Array(String($0)) }
        // The title line: a few words, then `esc` at the box's right edge.
        func title(_ line: [Character]) -> (start: Int, end: Int, text: String)? {
            var end = line.count
            while end > 0, line[end - 1] == " " { end -= 1 }
            guard end >= 3, String(line[(end - 3) ..< end]) == "esc" else { return nil }
            var i = end - 3
            var gap = 0
            while i > 0, line[i - 1] == " " { i -= 1; gap += 1 }
            guard gap >= 3, i > 0 else { return nil }
            // The title's words, back to a run of three spaces or the line's start.
            var start = i
            var spaces = 0
            while start > 0 {
                if line[start - 1] == " " { spaces += 1 } else { spaces = 0 }
                if spaces >= 3 { break }
                start -= 1
            }
            if spaces >= 3 { start += spaces - 1 }
            let text = String(line[start ..< i]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= 60, !text.contains("ctrl+"), !text.contains("┃") else { return nil }
            let lead = line[start...].prefix { $0 == " " }.count
            return (start + lead, end, text)
        }
        guard let top = lines.indices.last(where: { title(lines[$0]) != nil }), let head = title(lines[top]) else { return nil }
        // The box's columns: from a little left of the title to a little
        // right of `esc`, inside its margins.
        let left = max(0, head.start - 3)
        func cut(_ line: [Character]) -> String {
            guard line.count > left else { return "" }
            return String(line[left ..< min(line.count, head.end + 2)]).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        let typed = query.map { searchText($0) } ?? ""
        /// The search line: `Search`, or what was typed in it.
        func isSearch(_ s: String) -> Bool { s == "Search" || (!typed.isEmpty && (s == typed || typed.hasSuffix(s))) }
        var body: [String] = []
        var blanks = 0
        var shown = 0
        var searchFirst = false
        for line in lines[(top + 1)...] {
            let text = cut(line)
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                blanks += 1
                // Two blank lines end the box. OpenCode 1.1 leaves two
                // under its search line, before the list.
                if blanks >= 2, shown > (searchFirst ? 1 : 0) || blanks >= 4 { break }
            } else {
                if shown == 0 { searchFirst = isSearch(t) }
                shown += 1
                blanks = 0
            }
            body.append(text)
            if body.count > 60 { break }
        }
        body = unindented(trimmed(body))
        let filled = body.map { $0.trimmingCharacters(in: .whitespaces) }
        // The keys' hints: the last line naming one.
        let hintAt = filled.lastIndex { $0.contains("ctrl+") || $0.contains("enter ") || $0.contains("↑↓") }
        // Its keys work on the terminal only: the card has its own buttons.
        var prompt = ScreenPrompt(question: [], options: [], footer: "", context: [head.text], numbered: false)
        let first = filled.firstIndex { !$0.isEmpty }
        if let search = first, isSearch(filled[search]) {
            // A picker: the list under its search, to the hints.
            let end = hintAt ?? filled.count
            var options: [Option] = []
            for line in filled[(search + 1) ..< max(search + 1, end)] where !line.isEmpty {
                var label = line
                let current = label.hasPrefix("●")
                if current { label = String(label.dropFirst()).trimmingCharacters(in: .whitespaces) }
                var (name, aside) = columns(label)
                // `build The default agent…`: a lower-case name, then what it is.
                if aside.isEmpty, let space = name.firstIndex(of: " ") {
                    let head = name[..<space]
                    let rest = name[name.index(after: space)...]
                    if head == head.lowercased(), head.contains(where: \.isLetter), rest.first?.isUppercase == true {
                        (name, aside) = (String(head), String(rest))
                    }
                }
                options.append(Option(number: options.count + 1, label: name, detail: aside, focused: false, checked: current ? true : nil))
            }
            guard !options.isEmpty else { return nil }
            // Marks show the one in use only: the others' boxes stay off.
            if options.contains(where: { $0.checked == true }) {
                options = options.map { var o = $0; o.checked = o.checked ?? false; return o }
            }
            prompt.options = options
            prompt.searchable = true
        } else {
            let text = body.prefix(hintAt ?? body.count)
            prompt.context += Array(text)
        }
        return prompt
    }

    /// The keys that type `text` in a picker's search: letters as lower
    /// case, a space as `space`. The characters keys don't name are left
    /// out, as the search forgives letters missing.
    public static func searchKeys(_ text: String) -> [String] {
        text.lowercased().compactMap { c in
            if c == " " { return "space" }
            return c.isLetter && c.isASCII || c.isNumber && c.isASCII || c == "-" || c == "." ? String(c) : nil
        }
    }

    /// What a picker's search shows once `searchKeys(text)` are pressed.
    public static func searchText(_ text: String) -> String {
        searchKeys(text).map { $0 == "space" ? " " : $0 }.joined()
    }

    /// OpenCode's last step with several questions: `Fruit: Apple`, then
    /// `enter submit` (1.x titles it `Review`).
    public static func isOpenCodeReview(screen: String) -> Bool {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { openCodeMain(clean(String($0))).trimmingCharacters(in: .whitespaces) }
        guard let head = lines.lastIndex(where: { $0 == "Questions" || $0 == "Review" }) else { return false }
        return lines[head...].contains { $0.contains("enter submit") } && !lines[head...].contains { option($0) != nil }
    }
}

// MARK: - The footer under Claude Code's input

/// What Claude Code shows under its input box: the person's status line,
/// then the permission mode (`⏵⏵ accept edits on (shift+tab to cycle)`).
public struct ClaudeFooter: Sendable, Equatable {
    /// `default`, `acceptEdits`, `plan`, `auto`, `bypassPermissions`; nil when not shown.
    public var mode: String?
    /// The status line's lines, as the person's statusLine command drew them.
    public var statusLine: [String] = []
    /// `◐ medium · /effort` above the box: the effort level.
    public var effort: String?
    /// The model and effort Claude Code's header names, at the top of a new
    /// session and again after /clear: until an answer tells them.
    public var headerModel: String?
    public var headerEffort: String?
    /// The text in the input box, when the screen shows it.
    public var input: String?
    /// Claude Code's suggested next message, dim in its empty input box
    /// (Tab takes it there). As text it reads like typing: the app tells
    /// them apart by the screen's colors and moves it here from `input`.
    public var suggestion: String?
    /// The model OpenCode's input box names: its name, then its provider's
    /// (`Flint 40B Free OpenCode`).
    public var model: String?
    /// OpenCode's work dots run under its input box.
    public var busy = false
    /// What OpenCode says beside its dots: why it waits to try again.
    /// Codex: what it does now (`Running npm test`, the step it names).
    public var activity: String?
    /// Codex browses its transcript to go back to an earlier message
    /// (Esc Esc): ←/→ pick a message of the person's, Enter goes back to it.
    public var browsing = false
    /// Messages Codex holds until its turn ends (Tab while it works), as
    /// it lists them above its input.
    public var queued: [String] = []
    /// Codex's input line as it reads: what was typed, or its dim hint,
    /// which reads the same.
    public var shown: String?
    /// Gemini's daily limit, from the quota its footer shows (`12% used`).
    public var quota: UsageWindow?

    public init(mode: String? = nil, statusLine: [String] = [], effort: String? = nil, input: String? = nil, model: String? = nil) {
        self.mode = mode
        self.statusLine = statusLine
        self.effort = effort
        self.input = input
        self.model = model
    }

    /// Read from the bottom of Claude Code's screen; nil when no input box shows there.
    public static func parse(screen: String) -> ClaudeFooter? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        // The input box: the last two full rules, with the prompt between them.
        guard let bottom = lines.lastIndex(where: { ScreenPrompt.isRule($0) && !ScreenPrompt.isDashed($0) }), bottom > 0,
              let top = lines[..<bottom].lastIndex(where: ScreenPrompt.isBoxTop),
              bottom - top >= 2, bottom - top <= 30,
              lines[top + 1].trimmingCharacters(in: .whitespaces).hasPrefix("❯")
                || lines[top + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">")
                || lines[top + 1].trimmingCharacters(in: .whitespaces).hasPrefix("!")
        else { return nil }
        var footer = ClaudeFooter()
        // The box's text, without the prompt sign.
        var input = lines[(top + 1) ..< bottom].map { $0.trimmingCharacters(in: .whitespaces) }
        if var first = input.first {
            first = String(first.drop { "❯>!".contains($0) }).trimmingCharacters(in: .whitespaces)
            input[0] = first
        }
        footer.input = input.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var below = lines[(bottom + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }
        while let l = below.last, l.isEmpty { below.removeLast() }
        if let i = below.lastIndex(where: { mode(of: $0) != nil || $0.contains("? for shortcuts") }) {
            footer.mode = mode(of: below[i]) ?? "default"
            footer.statusLine = Array(below[..<i]).filter { !$0.isEmpty }
        } else {
            footer.statusLine = below.filter { !$0.isEmpty }
        }
        // `◐ medium · /effort`, right-aligned just above the box.
        if top > 0 {
            let above = lines[top - 1].trimmingCharacters(in: .whitespaces)
            if let r = above.range(of: " · /effort") {
                let word = above[..<r.lowerBound].split(separator: " ").last.map(String.init) ?? ""
                if !word.isEmpty { footer.effort = word }
            }
        }
        if let header = header(lines[..<top]) {
            footer.headerModel = header.model
            footer.headerEffort = header.effort
        }
        return footer
    }

    /// The model and effort in Claude Code's header, on the line under its
    /// name, right of its logo:
    ///
    ///      ▐▛███▛█   Claude Code v2.1.323
    ///     ▝▜██████▀  Opus 5.5 with xhigh effort · Claude Team
    ///      ▝▝   ▝▝   ~/Projects/swiftr · /rc
    ///
    /// The model as an id (`claude-opus-5-5`). Nil when no header shows.
    static func header(_ lines: ArraySlice<String>) -> (model: String, effort: String?)? {
        func text(_ line: String) -> String {
            String(line.drop { $0 == " " || ("\u{2580}" ... "\u{259F}").contains($0) }).trimmingCharacters(in: .whitespaces)
        }
        guard let title = lines.firstIndex(where: { text($0).wholeMatch(of: /Claude Code v\d+(?:\.\d+)+/) != nil }),
              title + 1 < lines.endIndex,
              let named = text(lines[title + 1]).components(separatedBy: " · ").first, !named.isEmpty
        else { return nil }
        if let m = named.wholeMatch(of: /(.+) with (\S+) effort/) {
            return (ClaudeModel.id(displayName: String(m.1)), String(m.2))
        }
        // Cut short on a narrow screen: the model before its effort.
        return (ClaudeModel.id(displayName: named.components(separatedBy: " with ")[0]), nil)
    }

    /// What Claude Code printed back to a key (⌥T: "Thinking can't be
    /// turned off for Haiku 5.5"): the note right-aligned just above its
    /// input box, when the key changed it. Its effort line isn't one: the
    /// footer shows that.
    public static func keyReply(before: String, after: String) -> String? {
        func note(_ screen: String) -> String? {
            guard parse(screen: screen) != nil else { return nil }
            let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
            guard let bottom = lines.lastIndex(where: { ScreenPrompt.isRule($0) && !ScreenPrompt.isDashed($0) }),
                  let top = lines[..<bottom].lastIndex(where: ScreenPrompt.isBoxTop), top > 0,
                  lines[top - 1].prefix(while: { $0 == " " }).count >= 20
            else { return nil }
            let text = lines[top - 1].trimmingCharacters(in: .whitespaces)
            return text.isEmpty || text.hasSuffix("/effort") ? nil : text
        }
        guard let now = note(after), now != note(before) else { return nil }
        return now
    }

    /// The permission mode a mode line names.
    static func mode(of line: String) -> String? {
        let t = line.lowercased()
        if t.contains("accept edits on") { return "acceptEdits" }
        if t.contains("plan mode on") { return "plan" }
        if t.contains("auto mode on") { return "auto" }
        if t.contains("bypass permissions on") { return "bypassPermissions" }
        if t.contains("manual mode on") || t.contains("default mode on") { return "default" }
        if t.contains("don't ask mode on") || t.contains("dontask mode on") { return "dontAsk" }
        return nil
    }
}
