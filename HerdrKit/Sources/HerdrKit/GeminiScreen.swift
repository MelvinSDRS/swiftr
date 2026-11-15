import Foundation

/// Gemini CLI's screen (0.6x). What it asks comes in a box at the bottom
/// (`╭─` … `╰─`, each line `│ …`), with no input box under it. The input
/// box sits between a row of `▄` and one of `▀` (each message sent shows
/// the same way above), its mode on the line over it, the columns under
/// it (`workspace (/directory)  sandbox  /model`). Its window title says
/// whether it is ready, at work or waiting for an answer.
public enum GeminiScreen {
    /// What the title Gemini sets says: `◇  Ready (x)`, `✦  Working… (x)`
    /// (or its thought: `✦  Checking the folder (x)`), `⏲  Working… (x)`,
    /// `✋  Action Required (x)`. Nil for any other title, as when its
    /// dynamic title is off (`Gemini CLI (x)`).
    public static func status(title: String) -> AgentStatus? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let mark = t.first else { return nil }
        switch mark {
        case "◇":
            return AgentStatus(state: "idle")
        case "✋":
            return AgentStatus(state: "blocked")
        case "✦", "⏲":
            var said = t.dropFirst().trimmingCharacters(in: .whitespaces)
            // The folder last, in brackets.
            if said.hasSuffix(")"), let open = said.range(of: " (", options: .backwards) { said = String(said[..<open.lowerBound]) }
            let working = said.isEmpty || said == "Working…" || said == "Working..."
            return AgentStatus(state: "working", message: working ? nil : said)
        default:
            return nil
        }
    }

    /// A title Gemini sets that says how it is, not what the session is
    /// about: its status, or `Gemini CLI (x)` when its dynamic title is off.
    public static func isStatusTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        return status(title: t) != nil || (t.hasPrefix("Gemini CLI (") && t.hasSuffix(")"))
    }

    /// The box last on the screen, nothing under it: its lines without its sides.
    static func lastBox(_ lines: [String]) -> [String]? {
        guard let bottom = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let column = lines[bottom].prefix { $0 == " " }.count
        guard lines[bottom].dropFirst(column).hasPrefix("╰"),
              let top = lines[..<bottom].lastIndex(where: { $0.prefix(column).allSatisfy { $0 == " " } && $0.dropFirst(column).hasPrefix("╭") })
        else { return nil }
        return lines[(top + 1) ..< bottom].map { inner($0, column) }
    }

    /// A box's line without its sides: `│ text    │` → `text`, keeping
    /// the indent past the bar's space.
    static func inner(_ line: String, _ column: Int) -> String {
        var s = Substring(line).dropFirst(column)
        if s.hasPrefix("│") { s = s.dropFirst() }
        if s.hasPrefix(" ") { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\u{a0}" { s = s.dropLast() }
        if s.hasSuffix("│") { s = s.dropLast() }
        while let l = s.last, l == " " { s = s.dropLast() }
        return String(s)
    }

    /// `● 1. Allow once`, `  2.  Blue`, `● 1. [x] Cheese`: an option, with
    /// the column of its number; `●` marks Gemini's cursor.
    static func option(_ line: String) -> (number: Int, label: String, focused: Bool, column: Int)? {
        var s = Substring(line).drop { $0 == " " }
        var focused = false
        if s.hasPrefix("●") {
            focused = true
            s = s.dropFirst().drop { $0 == " " }
        }
        let column = line.count - s.count
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let n = Int(digits) else { return nil }
        s = s.dropFirst(digits.count)
        guard s.hasPrefix(". ") else { return nil }
        let label = s.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (n, label, focused, column)
    }

    /// The options from the first `1.` on (or, in a list that scrolls,
    /// from the first under its `▲`), each with the lines under it that
    /// describe it; where they start and end. `window`: the list may show
    /// from a row past its first with no `▲` (a question's list, grown by
    /// ⌃O, keeps where its window started).
    static func options(_ lines: [String], window: Bool = false) -> (options: [ScreenPrompt.Option], first: Int, last: Int)? {
        var options: [ScreenPrompt.Option] = []
        var first = 0
        var last = 0
        var column = 0
        var underArrow = false
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            let follows = { (n: Int) in options.last.map { n == $0.number + 1 } ?? (n == 1 || underArrow || window) }
            if let o = option(line), follows(o.number) {
                var label = o.label
                var checked: Bool?
                for (box, mark) in [("[ ] ", false), ("[x] ", true), ("[X] ", true), ("[✓] ", true)] where label.hasPrefix(box) {
                    label = String(label.dropFirst(box.count)).trimmingCharacters(in: .whitespaces)
                    checked = mark
                }
                if options.isEmpty { first = i }
                options.append(ScreenPrompt.Option(number: o.number, label: label, focused: o.focused, checked: checked))
                last = i
                column = o.column
            } else if !options.isEmpty {
                // A list too long to show whole scrolls between ▲ and ▼.
                if t == "▲" || t == "▼" { continue }
                guard !t.isEmpty, line.prefix(while: { $0 == " " }).count > column else { break }
                let k = options.count - 1
                options[k].detail = options[k].detail.isEmpty ? t : options[k].detail + "\n" + t
                last = i
            } else if !t.isEmpty {
                underArrow = t == "▲"
            }
        }
        return options.isEmpty ? nil : (options, first, last)
    }

    /// `●  Done` / `   Done`: the row that ends a question taking several
    /// answers, drawn with no number, its word where options have their
    /// number (lines that describe an option sit further in); true when
    /// the cursor is on it. Nil for any other line.
    static func doneRow(_ line: String) -> Bool? {
        var t = Substring(line)
        while let l = t.last, l == " " { t = t.dropLast() }
        if t == "   Done" { return false }
        if t == "●  Done" { return true }
        return nil
    }

    /// `← □ Color │ ✓ Toppings │ ≡ Review →`: a question for each, Review last.
    static func tabs(_ line: String) -> [ScreenPrompt.Tab]? {
        var t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("←"), t.hasSuffix("→") else { return nil }
        t = String(t.dropFirst().dropLast())
        let tabs = t.components(separatedBy: "│").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { part -> ScreenPrompt.Tab in
            let mark = part.first ?? " "
            let title = part.dropFirst().trimmingCharacters(in: .whitespaces)
            return ScreenPrompt.Tab(title: title, answered: mark == "✓", isSubmit: mark == "≡")
        }
        return tabs.isEmpty ? nil : tabs
    }

    /// Lines with a box of their own drawn in (`┌─┐`, `│ text`, `└─┘`, as
    /// in `Confirm Rewind`): the text without the frame.
    static func unboxed(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if let f = t.first, "┌└╭╰".contains(f), t.dropFirst().allSatisfy({ "─┐┘╮╯".contains($0) }) { return nil }
            guard t.hasPrefix("│") else { return line }
            var s = t.dropFirst()
            if s.hasSuffix("│") { s = s.dropLast() }
            return s.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Lines without the blank ones at either end.
    static func trimmed(_ lines: some Collection<String>) -> [String] {
        var out = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        while out.first?.isEmpty == true { out.removeFirst() }
        while out.last?.isEmpty == true { out.removeLast() }
        return out
    }

    /// The change a permission box draws, `1 - old` / `1 + new` / `2   same`
    /// per line, as a patch; a new file's lines (`1 one`) as its content.
    static func change(_ lines: [String]) -> (patch: String?, content: String?) {
        let parsed = lines.map { line -> (sign: Character?, text: String) in
            guard let m = line.firstMatch(of: /^\s*\d+ ([-+ ]) (.*)$/) else {
                let plain = line.firstMatch(of: /^\s*\d+ ?(.*)$/).map { String($0.output.1) }
                return (nil, plain ?? line)
            }
            return (m.output.1.first, String(m.output.2))
        }
        let isPatch = parsed.contains { $0.sign == "+" || $0.sign == " " }
        guard isPatch else { return (nil, parsed.map(\.text).joined(separator: "\n") + "\n") }
        let patch = zip(lines, parsed).map { line, p -> String in
            guard let sign = p.sign else { return " " + line.trimmingCharacters(in: .whitespaces) }
            return String(sign) + p.text
        }
        return (patch.joined(separator: "\n"), nil)
    }
}

// MARK: - What it asks

extension ScreenPrompt {
    /// The box Gemini asks in, last on its screen: its questions (`Answer
    /// Questions`, one at a time, tabs over them, `Review your answers:`
    /// last), a permission (`? Shell  ls -la`, the command or change in a
    /// box, `Allow execution of [Shell]?`), or another choice of its own.
    public static func parseGemini(screen: String) -> ScreenPrompt? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let box = GeminiScreen.lastBox(lines),
              let h = box.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        let head = box[h].trimmingCharacters(in: .whitespaces)
        let body = Array(box[(h + 1)...])
        if head == "Answer Questions" { return geminiQuestion(body) }
        if head == "> Rewind" { return geminiRewind(body) }
        if head.hasPrefix("? ") { return geminiPermission(String(head.dropFirst(2)), body) }
        // Another of its choices (a folder to trust, a picker).
        guard let (options, first, last) = GeminiScreen.options(box), options.count >= 2 else { return nil }
        let question = GeminiScreen.unboxed(GeminiScreen.trimmed(box[..<first]))
        let footer = GeminiScreen.trimmed(box[(last + 1)...]).first ?? ""
        return ScreenPrompt(question: question, options: options, footer: footer)
    }

    /// Gemini's question: the row under its cursor, `Done` included.
    public var geminiCursor: Int? {
        submitFocused ? doneNumber : options.first(where: \.focused)?.number
    }

    /// Gemini's question whose list shows from a row past its first with
    /// no `▲` (its window kept its start when ⌃O let it grow; it shows to
    /// the end): keys that take the cursor to the first row, where the
    /// window starts again, then back. ↑ to it, or ↓ round the end,
    /// whichever is fewer. Nil when the list shows from its first row.
    public var geminiTopWalk: (there: [String], back: [String])? {
        guard !listScrolls, let first = options.first?.number, first > 1,
              let last = doneNumber ?? options.last?.number, let at = geminiCursor
        else { return nil }
        let up = at - 1
        let round = last - at + 1
        let (there, back) = up <= round ? ("up", "down") : ("down", "up")
        let n = min(up, round)
        return (Array(repeating: there, count: n), Array(repeating: back, count: n))
    }

    /// One of Gemini's questions, or its review of the answers.
    private static func geminiQuestion(_ body: [String]) -> ScreenPrompt? {
        var lines = body
        var tabs: [Tab] = []
        if let i = lines.firstIndex(where: { GeminiScreen.tabs($0) != nil }) {
            tabs = GeminiScreen.tabs(lines[i]) ?? []
            lines.remove(at: i)
        }
        var hint = ""
        if let i = lines.lastIndex(where: { $0.contains("Esc to cancel") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("Enter to ") }) {
            hint = lines[i].trimmingCharacters(in: .whitespaces)
            lines.remove(at: i)
        }
        let context = ["Answer Questions"]
        if let r = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Review your answers:" }) {
            // Enter sends them all.
            let answers = GeminiScreen.trimmed(lines[(r + 1)...]).filter { !$0.isEmpty }
            return ScreenPrompt(question: ["Review your answers:", ""] + answers, options: [Option(number: 1, label: "Submit answers", focused: true)],
                                footer: hint, context: context, numbered: false, tabs: tabs)
        }
        // `Done` ends a question that takes several answers, under its line
        // for one's own words: no number, though the next digit picks it.
        let done = lines.indices.first { i in
            GeminiScreen.doneRow(lines[i]) != nil && lines[..<i].contains { GeminiScreen.option($0) != nil }
        }
        let scrolls = lines.contains { ["▲", "▼"].contains($0.trimmingCharacters(in: .whitespaces)) }
        if let (options, first, _) = GeminiScreen.options(done.map { Array(lines[..<$0]) } ?? lines, window: true) {
            let question = GeminiScreen.trimmed(lines[..<first]).filter { $0 != "▲" && $0 != "▼" }
            var p = ScreenPrompt(question: GeminiScreen.trimmed(question), options: options, footer: hint, context: context, tabs: tabs)
            p.listScrolls = scrolls
            // The last numbered option takes one's own words (`teal ✓` once
            // chosen). A list that scrolls (▲ ▼) may hide it: then only its
            // hint or `Done` under it tell it.
            if let own = options.last {
                if let done {
                    p.hasSubmitLine = true
                    p.submitFocused = GeminiScreen.doneRow(lines[done]) == true
                    p.doneNumber = own.number + 1
                }
                var words = ([own.label] + own.detail.split(separator: "\n").map(String.init))
                    .joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if words.hasSuffix("✓") { words = String(words.dropLast()).trimmingCharacters(in: .whitespaces) }
                let empty = words == "Enter a custom value"
                if !scrolls || empty || done != nil {
                    p.customOption = own.number
                    p.typedWords = empty ? "" : words
                }
            }
            return p
        }
        // Answered in words: `> e.g. notes.txt`, its hint or what is typed.
        guard let field = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }) else { return nil }
        var p = ScreenPrompt(question: GeminiScreen.trimmed(lines[..<field]), options: [], footer: hint, context: context, numbered: false, tabs: tabs)
        p.takesText = true
        let rows = lines[field...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let words = rows.joined(separator: " ").dropFirst().trimmingCharacters(in: .whitespaces)
        p.typedWords = words == "Enter your response" ? "" : words
        return p
    }

    /// Its rewind list (Esc Esc on an empty input, `/rewind`): each message
    /// sent, what it changed under it (`1 file changed +3`), apart by blank
    /// lines, `Stay at current position` last; `●` marks the cursor, arrows
    /// move it. The message chosen, it asks what goes back (`Confirm Rewind`).
    private static func geminiRewind(_ body: [String]) -> ScreenPrompt? {
        var options: [Option] = []
        var group: [String] = []
        var focused = false
        var footer = ""
        func close() {
            guard !group.isEmpty else { return }
            var label = group.count > 1 ? group.dropLast().joined(separator: " ") : group[0]
            // Gemini's first message, its own: the folder and the date.
            if label.hasPrefix("<session_context>") { label = "The session's start" }
            options.append(Option(number: options.count + 1, label: label, detail: group.count > 1 ? group[group.count - 1] : "", focused: focused))
            group = []
            focused = false
        }
        for line in body {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("(Use Enter") {
                footer = String(t.dropFirst().prefix { $0 != ")" })
                break
            }
            if t.isEmpty { close(); continue }
            if t.hasPrefix("●") {
                focused = true
                t = t.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            group.append(t)
        }
        close()
        guard options.count >= 2 else { return nil }
        return ScreenPrompt(question: ["Go back to which message?"], options: options, footer: footer, context: ["Rewind"], numbered: false)
    }

    /// `Shell  ls -la`, `WriteFile  Writing to hello.txt`, `Edit  hello.txt: a => b`:
    /// the tool, what it does, the box with the command or the change.
    private static func geminiPermission(_ head: String, _ body: [String]) -> ScreenPrompt? {
        let split = head.range(of: "  ")
        let tool = split.map { String(head[..<$0.lowerBound]) } ?? head
        let what = split.map { head[$0.upperBound...].trimmingCharacters(in: .whitespaces) } ?? ""
        var inner: [String] = []
        var rest = body
        if let open = body.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("╭") }),
           let close = body[open...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("╰") })
        {
            let column = body[open].prefix { $0 == " " }.count
            inner = body[(open + 1) ..< close].map { GeminiScreen.inner($0, column) }
            rest = Array(body[(close + 1)...])
        }
        guard let (options, first, last) = GeminiScreen.options(rest), options.count >= 2 else { return nil }
        let question = GeminiScreen.trimmed(rest[..<first])
        let footer = GeminiScreen.trimmed(rest[(last + 1)...]).first ?? ""
        let change: (patch: String?, content: String?) = tool == "WriteFile" || tool == "Edit" ? GeminiScreen.change(inner) : (nil, nil)
        let title = switch tool {
        case "Shell": "Shell command"
        case "WriteFile": change.content != nil ? "Create file" : "Write file"
        case "Edit": "Edit file"
        default: tool
        }
        var context = [title]
        if !what.isEmpty { context.append(what) }
        if !inner.isEmpty { context += [""] + inner }
        // Its editor would open in the terminal, out of sight: left out, the others keep their digits.
        let shown = options.filter { !$0.label.hasPrefix("Modify with external editor") }
        var p = ScreenPrompt(question: question, options: shown, footer: footer, context: context)
        let id = "gemini-asks"
        switch tool {
        case "Shell":
            let command = inner.isEmpty ? what : inner.joined(separator: "\n")
            p.call = ToolCall(id: id, name: "Shell", input: ["command": .string(command)])
        case "WriteFile", "Edit":
            // `Writing to hello.txt`; `hello.txt: two => deux`.
            let file = what.hasPrefix("Writing to ") ? String(what.dropFirst(11)) : what.range(of: ": ").map { String(what[..<$0.lowerBound]) } ?? what
            if let content = change.content {
                p.call = ToolCall(id: id, name: "Write", input: ["file_path": .string(file), "content": .string(content)])
            } else if let patch = change.patch {
                p.call = ToolCall(id: id, name: "Edit", input: ["file_path": .string(file), "diff": .string(patch)])
            }
        default:
            break
        }
        return p
    }
}

// MARK: - Its input box

extension ClaudeFooter {
    /// Gemini's input box, nil while it asks something (it hides the box):
    /// what is typed (`>   Type your message or @path/to/file` is its hint),
    /// its mode (the line over the box: `Shift+Tab to accept edits` alone
    /// for the default, `auto-accept edits …`, `plan …`, `YOLO …`, given as
    /// Claude Code's `acceptEdits`, `plan`, `bypassPermissions`), what it
    /// does while it works (`⠋ Thinking... (esc to cancel, 2s)` over the
    /// rule above), the messages it holds (`Queued (press ↑ to edit):`),
    /// and its columns under the box: the model, then the others (the
    /// sandbox it runs in, what `/footer` added) as its status line.
    public static func parseGemini(screen: String) -> ClaudeFooter? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func row(_ line: String, of mark: Character) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.count >= 8 && t.allSatisfy { $0 == mark }
        }
        guard let bottom = lines.lastIndex(where: { row($0, of: "▀") }),
              let top = lines[..<bottom].lastIndex(where: { row($0, of: "▄") }),
              bottom - top >= 2, bottom - top <= 40
        else { return nil }
        // The box a message sent left above isn't the input: nothing but columns follow that one.
        for line in lines[(bottom + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("╭") || t.hasPrefix("│") || t.hasPrefix("╰") || t.hasPrefix("✦") || row(line, of: "▄") { return nil }
        }
        var footer = ClaudeFooter()
        var input = lines[(top + 1) ..< bottom].map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = input.first, let sign = first.first, ">!*".contains(sign) {
            input[0] = String(first.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let typed = input.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        footer.input = typed == "Type your message or @path/to/file" ? "" : typed
        footer.mode = top > 0 ? geminiMode(lines[top - 1]) : "default"
        // Over the rule above the box: its work line, the messages it holds.
        let rule = lines[..<top].lastIndex { ScreenPrompt.isRule($0) } ?? top
        var queued: [String] = []
        var inQueue = false
        for line in lines[max(0, rule - 20) ..< rule] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Queued (") {
                inQueue = true
                queued = []
                continue
            }
            if inQueue {
                if t.isEmpty || !line.hasPrefix("  ") {
                    inQueue = false
                } else {
                    queued.append(t)
                    continue
                }
            }
            if let r = t.range(of: " (esc to cancel") {
                footer.busy = true
                let said = t[..<r.lowerBound].drop { ("\u{2800}" ... "\u{28FF}").contains($0) || $0 == " " }
                let activity = said.replacingOccurrences(of: "...", with: "…").trimmingCharacters(in: .whitespaces)
                footer.activity = activity.isEmpty ? nil : activity
            }
        }
        footer.queued = queued
        // Under the box: names over values, `/model` over the model.
        let under = lines[(bottom + 1)...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if under.count >= 2, under[under.startIndex].contains("workspace") || under[under.startIndex].contains("/model") {
            let names = Array(under[under.startIndex])
            let values = Array(under[under.startIndex + 1])
            // A name starts after two spaces (or one, at the line's start).
            let starts = names.indices.filter { i in
                names[i] != " " && (i == 0 || (names[i - 1] == " " && (i == 1 || names[i - 2] == " ")))
            }
            var status: [String] = []
            for (k, start) in starts.enumerated() {
                let end = k + 1 < starts.count ? starts[k + 1] : max(values.count, names.count)
                let name = String(names[start ..< min(end, names.count)]).trimmingCharacters(in: .whitespaces)
                let value = start < values.count ? String(values[start ..< min(end, values.count)]).trimmingCharacters(in: .whitespaces) : ""
                guard !value.isEmpty else { continue }
                if name.hasPrefix("/model") {
                    footer.model = value
                } else if name == "quota", let quota = GeminiUsage.window(fromFooterValue: value) {
                    footer.quota = quota
                    status.append(value)
                } else if !name.hasPrefix("workspace"), value != "no sandbox" {
                    status.append(value)
                }
            }
            // The other columns, as Gemini words them: a sandbox, what the person added with /footer.
            footer.statusLine = status
        }
        return footer
    }

    /// The mode the line over Gemini's box names, as Claude Code's are called.
    static func geminiMode(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("auto-accept edits") { return "acceptEdits" }
        if t.hasPrefix("plan ") || t == "plan" { return "plan" }
        if t.hasPrefix("YOLO") { return "bypassPermissions" }
        return "default"
    }
}
