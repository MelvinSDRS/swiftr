import Foundation

/// A question Claude asks with AskUserQuestion, as its call gives it.
public struct AskQuestion: Sendable, Equatable, Identifiable {
    public struct Choice: Sendable, Equatable, Identifiable {
        public var label: String
        public var detail: String

        public var id: String { label }

        public init(label: String, detail: String = "") {
            self.label = label
            self.detail = detail
        }
    }

    /// A word or two over the question (`Color`).
    public var header: String
    public var question: String
    public var multiSelect: Bool
    public var options: [Choice]

    public var id: String { question }

    public init(header: String = "", question: String, multiSelect: Bool = false, options: [Choice]) {
        self.header = header
        self.question = question
        self.multiSelect = multiSelect
        self.options = options
    }

    /// The questions in an AskUserQuestion call's input.
    public static func list(_ input: JSON) -> [AskQuestion] {
        (input["questions"]?.array ?? []).compactMap { q in
            guard let text = q["question"]?.string, !text.isEmpty else { return nil }
            let options = (q["options"]?.array ?? []).compactMap { o -> Choice? in
                guard let label = o["label"]?.string, !label.isEmpty else { return nil }
                return Choice(label: label, detail: o["description"]?.string ?? "")
            }
            return AskQuestion(header: q["header"]?.string ?? "", question: text, multiSelect: q["multiSelect"]?.bool ?? false, options: options)
        }
    }

    /// On Claude Code's screen, the option to type one's own answer in comes
    /// after Claude's (`Type something`)…
    public var typeNumber: Int { options.count + 1 }
    /// …then, under a rule, `Chat about this`.
    public var chatNumber: Int { options.count + 2 }
}

/// What the person answers to one question: options chosen, their own words, or both.
public struct AskAnswer: Sendable, Equatable {
    /// Labels of the options chosen; one at most for a single-select question.
    public var chosen: [String]
    public var other: String

    public init(chosen: [String] = [], other: String = "") {
        self.chosen = chosen
        self.other = other
    }

    /// Their own words, trimmed.
    public var text: String { other.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isEmpty: Bool { chosen.isEmpty && text.isEmpty }
}

extension ScreenPrompt {
    /// Claude Code's AskUserQuestion when its options have previews (2.1.325):
    /// the options in a column 30 cells wide, each label wrapping in it,
    /// the focused option's preview 4 cells to the right, the notes under
    /// the preview, then `Chat about this` under a rule, and the hint:
    ///
    ///     ←  ☒ Layout  ☐ Color  ✔ Submit  →
    ///
    ///     Which card layout do you prefer?
    ///
    ///       1. Stacked                      ┌──────────────────┐
    ///     ❯ 2. Side by side            ✔    │ +-----+ +-----+  │
    ///         (Recommended)                 │ | Low | | Med |  │
    ///       3. Compact                      └──────────────────┘
    ///
    ///                                       Notes: press n to add notes
    ///     ────────────────────────────────────────────────────────────
    ///       Chat about this
    ///
    ///     Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel
    ///
    /// The answer's mark (✔) sits right of its label's first row. `raw`:
    /// the screen's lines as they are (`clean` would eat the previews' bars).
    static func previewQuestion(_ raw: [String]) -> ScreenPrompt? {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        guard let hintAt = raw.lastIndex(where: { $0.contains("n to add notes") && $0.contains("Enter to select") }),
              let chatAt = raw[..<hintAt].lastIndex(where: { !trim($0).isEmpty }), chatAt > 0
        else { return nil }
        var chat = trim(raw[chatAt])
        let chatFocused = chat.hasPrefix("❯")
        if chatFocused { chat = trim(String(chat.dropFirst())) }
        guard chat == "Chat about this", isRule(raw[chatAt - 1]) else { return nil }
        let ruleAt = chatAt - 1
        // The notes start where the previews do: 34 cells right of the options' column.
        guard let notesAt = raw[..<ruleAt].lastIndex(where: { notesColumn(in: $0) != nil }),
              let notesStart = notesColumn(in: raw[notesAt])
        else { return nil }
        let base = notesStart - 34
        guard base >= 0 else { return nil }
        func left(_ i: Int) -> String {
            var s = Substring(cut(raw[i], at: base + 30).left)
            while s.last == " " { s = s.dropLast() }
            return String(s)
        }
        // The first option: the nearest `1.` over the notes, under the question.
        var first: Int?
        var k = ruleAt - 1
        while first == nil, k >= 0, k >= ruleAt - 60, !isRule(left(k)) {
            if option(left(k))?.number == 1 { first = k }
            k -= 1
        }
        guard let first else { return nil }
        var options: [Option] = []
        var marked: Set<Int> = []
        var i = first
        while i < ruleAt {
            let l = left(i)
            if let o = option(l), o.number == options.count + 1 {
                var label = o.label
                if label.hasSuffix("✔") {
                    label = trim(String(label.dropLast()))
                    marked.insert(o.number)
                }
                options.append(Option(number: o.number, label: label, focused: o.focused && !chatFocused))
            } else if let last = options.indices.last, indent(l) > base + 2, !trim(l).isEmpty {
                // The label wrapped.
                options[last].label += " " + trim(l)
            } else {
                break
            }
            i += 1
        }
        guard options.count >= 2 else { return nil }
        for n in marked { options[n - 1].label += " ✔" }
        // The notes' words, from the `Notes:` line down to the rule.
        var words = [String(cut(raw[notesAt], at: notesStart).right.dropFirst("Notes:".count))]
        for j in notesAt + 1 ..< ruleAt {
            words.append(cut(raw[j], at: notesStart).right)
        }
        let notes = words.map(trim).filter { !$0.isEmpty }.joined(separator: " ")
        var prompt = surroundings(of: first, in: raw.map(clean))
        prompt.options = options
        prompt.footer = trim(raw[hintAt])
        prompt.previews = true
        prompt.chatFocused = chatFocused
        switch notes {
        case "press n to add notes":
            prompt.notesOpen = false
        case "Add notes on this design…":
            prompt.notesOpen = true
        default:
            prompt.notes = notes
            // Claude Code names the editor for the notes only while they are open.
            prompt.notesOpen = prompt.footer.contains("ctrl+g to edit") ? true : nil
        }
        return prompt
    }

    /// The cell where `Notes:` starts on a line, when the words before it
    /// (an option's, at most) end 4 spaces or more before it.
    static func notesColumn(in line: String) -> Int? {
        guard let r = line.range(of: "Notes:") else { return nil }
        let before = line[..<r.lowerBound]
        guard before.allSatisfy({ $0 == " " }) || before.hasSuffix("    ") else { return nil }
        return cells(before)
    }

    /// A line cut at cell `column`: what shows left of it, and from it on.
    /// Wide characters (CJK, emoji) take two cells.
    static func cut(_ line: String, at column: Int) -> (left: String, right: String) {
        var at = 0
        for i in line.indices {
            if at >= column { return (String(line[..<i]), String(line[i...])) }
            at += cells(line[i ... i])
        }
        return (line, "")
    }

    /// The cells `s` takes on a terminal.
    static func cells<S: StringProtocol>(_ s: S) -> Int {
        s.reduce(0) { sum, c in
            let wide = c.unicodeScalars.contains { u in
                u.properties.isEmojiPresentation || (0x1100 ... 0x115F).contains(u.value) || (0x2E80 ... 0xA4CF).contains(u.value)
                    || (0xAC00 ... 0xD7A3).contains(u.value) || (0xF900 ... 0xFAFF).contains(u.value) || (0xFE30 ... 0xFE4F).contains(u.value)
                    || (0xFF00 ... 0xFF60).contains(u.value) || (0xFFE0 ... 0xFFE6).contains(u.value) || (0x20000 ... 0x3FFFD).contains(u.value)
            }
            return sum + (wide ? 2 : 1)
        }
    }

    /// The screen asks `q`: its text is the question's, line wrapping aside.
    public func asks(_ q: AskQuestion) -> Bool {
        // The review lists every question again.
        guard !isReview else { return false }
        let shown = Self.squeezed(questionText)
        let wanted = Self.squeezed(q.question)
        guard !shown.isEmpty, !wanted.isEmpty else { return false }
        if shown == wanted || shown.contains(wanted) { return true }
        // Cut on a narrow screen: what shows is the question's start.
        return shown.count >= 16 && wanted.hasPrefix(shown.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")))
    }

    /// The text on one line, its runs of spaces as one.
    static func squeezed(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }

    /// What Claude's (or OpenCode's) screen shows answered to `q`, the
    /// question it asks now: a single choice comes back marked (`2. Blue ✔`,
    /// OpenCode `2. Blue ✓`), boxes show checked (`[✔] Dog`, `[✓] Dog`), and
    /// one's own words take the place of `Type something` (`4. my own color
    /// ✔`, `4. [✔] hamster`; OpenCode's of `Type your own answer`, `4. my
    /// own color✓`; typed but not yet chosen: `4. my own color`).
    public func shownAnswer(for q: AskQuestion) -> AskAnswer {
        // Beside previews: the option marked, and the notes as one's own
        // words (Claude takes both together).
        if previews {
            var answer = AskAnswer(other: notes)
            if let o = options.first(where: { $0.label.hasSuffix("✔") }), q.options.indices.contains(o.number - 1) {
                answer.chosen = [q.options[o.number - 1].label]
            }
            return answer
        }
        var answer = AskAnswer()
        for option in options where option.number <= q.typeNumber {
            var label = option.label
            let marked = label.hasSuffix("✔") || label.hasSuffix("✓")
            if marked { label = String(label.dropLast()).trimmingCharacters(in: .whitespaces) }
            let chosen = q.multiSelect ? option.checked == true : marked
            if option.number == q.typeNumber {
                let typed = !["type something", "type something.", "type your own answer"].contains(label.lowercased())
                if typed, chosen || !q.multiSelect { answer.other = label }
            } else if chosen, q.options.indices.contains(option.number - 1) {
                answer.chosen.append(q.options[option.number - 1].label)
            }
        }
        if !q.multiSelect, !answer.chosen.isEmpty { answer.other = "" }
        return answer
    }

    /// Which of `questions` the screen asks (its tab); the count of them on
    /// the last tab, the review; nil when it shows none of them.
    public func questionIndex(in questions: [AskQuestion]) -> Int? {
        if isReview { return questions.count }
        return questions.firstIndex { asks($0) }
    }

    /// Multi-select: the digits that make the boxes of Claude's options
    /// match `chosen` (labels), each box that differs pressed once.
    public func toggles(toMatch chosen: [String], in q: AskQuestion) -> [String]? {
        var keys: [String] = []
        for (i, choice) in q.options.enumerated() {
            guard let shown = options.first(where: { $0.number == i + 1 }), let checked = shown.checked else { return nil }
            if checked != chosen.contains(choice.label) { keys.append("\(i + 1)") }
        }
        return keys
    }

    /// Down presses that bring the cursor to a multi-select question's
    /// `Submit` line, under its last option.
    public var downsToSubmit: Int? {
        guard hasSubmitLine, let last = options.last(where: { $0.checked != nil }) else { return nil }
        if submitFocused { return 0 }
        let at = options.first(where: \.focused)?.number ?? 1
        return last.number - at + 1
    }

    /// Permission prompts: the last option, which says no.
    public var refusal: Option? {
        options.last { $0.label.lowercased().hasPrefix("no") || $0.label.lowercased() == "reject" }
    }

    /// Plan approval: the option that sends Claude back to the plan with a note.
    public var reviseOption: Option? {
        options.first { o in
            let l = o.label.lowercased()
            return l.contains("tell claude") || l.contains("keep planning") || l.contains("what to change")
        }
    }
}
