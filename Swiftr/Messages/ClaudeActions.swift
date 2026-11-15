import Foundation
import HerdrKit

/// Answering Claude from the Messages view: the keys a person would press
/// on its screen, each step checked on the screen before the next, so a
/// screen that isn't what was expected stops the answer instead of choosing
/// something else.
extension TranscriptFeed {
    struct ActionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func fail(_ message: String) -> ActionError {
        ActionError(message: message)
    }

    private func core() throws -> CoreConnection {
        guard let c = connection else { throw fail("Swiftr isn't connected to the core.") }
        return c
    }

    /// Claude's screen as text.
    func readScreen() async throws -> String {
        let r = try await core().call("terminal.read", ["terminal": .string(address)])
        return r["text"]?.string ?? ""
    }

    func readPrompt() async throws -> ScreenPrompt? {
        parsePrompt(try await readScreen())
    }

    /// Whether `text`, read in Claude's input box, is the suggestion Claude
    /// Code shows dim there rather than typing; from the screen's colors.
    /// The same text keeps its answer for 20 s: each check attaches.
    func isSuggestion(_ text: String) async -> Bool {
        if let known = suggestionCheck, known.text == text, Date().timeIntervalSince(known.at) < 20 { return known.dim }
        guard let m = record, let c = connection,
              let screen = await StyledScreen.read(address, connection: c, cols: m.cols, rows: m.rows)
        else { return false }
        let words = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let dim = screen.suggestion.map { words($0) == words(text) } ?? false
        suggestionCheck = (text, dim, Date())
        return dim
    }

    /// The text in Claude's input box: "" when it is empty or holds only
    /// Claude Code's dim suggestion; nil when no input box shows.
    func boxText(_ screen: String) async -> String? {
        guard let input = parseFooter(screen)?.input else { return nil }
        guard !input.isEmpty, agent == .claude else { return input }
        return await isSuggestion(input) ? "" : input
    }

    /// Reads the screen until `wanted` says yes, for `seconds` at most; nil if it never did.
    func waitPrompt(_ seconds: Double = 3, until wanted: (ScreenPrompt?) -> Bool) async throws -> ScreenPrompt?? {
        let end = Date().addingTimeInterval(seconds)
        while true {
            let p = try await readPrompt()
            if wanted(p) { return .some(p) }
            if Date() >= end { return nil }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Esc twice empties Claude's input box; false if it still holds text
    /// after 2 s. On a box already empty, the second Esc opens the list of
    /// messages to go back to: it closes.
    func emptyBox() async throws -> Bool {
        try await press(["esc"])
        try await Task.sleep(for: .milliseconds(150))
        try await press(["esc"])
        let cleared = Date().addingTimeInterval(2)
        while Date() < cleared {
            try await Task.sleep(for: .milliseconds(150))
            let screen = try await readScreen()
            if await boxText(screen)?.isEmpty == true { return true }
            if ScreenPrompt.parse(screen: screen)?.isRewindList == true {
                try await press(["esc"])
                return true
            }
        }
        return false
    }

    /// ⌃X ⌃K twice, as Claude Code asks: its sub-agents in the background stop.
    func stopBackgroundAgents() async throws {
        try await acting {
            try await pressAndSettle(["ctrl+x", "ctrl+k"])
            try await press(["ctrl+x", "ctrl+k"])
        }
    }

    /// Quits the agent with its own ⌃C: Codex and OpenCode quit at the
    /// first, Claude Code and Gemini at the second (the first asks for it).
    /// A turn under way stops first, words in its input go first: so ⌃C
    /// goes again, a moment apart, until the program has left the terminal.
    func quit() async throws {
        try await acting {
            guard let pid = record?.foreground?.pid, record?.runsChatAgent == true else { return }
            let here = record?.machine == nil
            // On this Mac the process itself tells sooner than the core: a
            // ⌃C sent after it ended would reach the shell.
            @MainActor func gone() -> Bool {
                if record?.foreground?.pid != pid || record?.runsChatAgent != true { return true }
                return here && kill(pid_t(pid), 0) != 0 && errno == ESRCH
            }
            for _ in 0 ..< 6 {
                try await press(["ctrl+c"])
                let next = Date().addingTimeInterval(0.4)
                while Date() < next {
                    try await Task.sleep(for: .milliseconds(25))
                    if gone() { return }
                }
            }
            throw fail("\(agentName) didn't quit at ⌃C. Its terminal shows why.")
        }
    }

    func press(_ keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        _ = try await core().call("terminal.keys", ["terminal": .string(address), "keys": .array(keys.map { .string($0) })], timeout: .seconds(30))
    }

    /// Presses `keys`, then waits for the screen to change (1.5 s at most):
    /// the card that shows next is read from what they made, not from before.
    func pressAndSettle(_ keys: [String]) async throws {
        let before = try await readScreen()
        try await press(keys)
        let end = Date().addingTimeInterval(1.5)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(100))
            if try await readScreen() != before { return }
        }
    }

    /// Pastes `text` and presses Enter although Claude is blocked: into the
    /// field its question just opened. Keys the person typed in Claude's
    /// terminal here (a digit on its question), or words Swiftr put there as
    /// theirs, are an unsent draft to the core, which would hold the paste
    /// for up to a minute: ⌃U as theirs, in that empty field, ends it
    /// (Gemini's question takes no ⌃U at all).
    ///
    /// The core answers once the agent starts a turn, else ~5 s after the
    /// Enter: an answer on a question's tab starts none. The screen tells
    /// sooner that the words and their Enter went in: it changed, then held
    /// still a moment. Keys pressed next don't wait for the core's answer.
    private func typeIn(_ text: String) async throws {
        if let terminal = terminalSession, terminal.isAttached,
           let at = terminal.lastTyped, Date().timeIntervalSince(at) < 65 {
            terminal.view.send(txt: "\u{15}")
            terminal.draftEnded()
        }
        let c = try core()
        let params: JSON = ["terminal": .string(address), "text": .string(text), "force": true]
        var last = try await readScreen()
        let sent = SendWatch()
        Task {
            do { _ = try await c.call("terminal.send", params, timeout: .seconds(60)) } catch { sent.error = error }
            sent.done = true
        }
        var changed: Date?
        while !sent.done {
            try await Task.sleep(for: .milliseconds(100))
            let now = try await readScreen()
            if now != last {
                last = now
                changed = Date()
            } else if let changed, Date().timeIntervalSince(changed) >= 0.8 {
                return
            }
        }
        if let error = sent.error { throw error }
    }

    /// Own words for a lone question, into the field for them on Claude's
    /// screen, unsent: its digit opens the field (choosing an option would
    /// send it), and they go in as the person pastes, without Enter.
    private func putWords(_ q: AskQuestion, _ text: String, _ p: ScreenPrompt, shown: AskAnswer) async throws {
        if p.options.first(where: \.focused)?.number != q.typeNumber {
            try await pressAndSettle(["\(q.typeNumber)"])
            guard try await waitPrompt(2, until: { $0?.options.first(where: \.focused)?.number == q.typeNumber }) != nil else { return }
        }
        let terminal = try await attachedTerminal(for: "your answer")
        if !shown.other.isEmpty { terminal.view.send(txt: "\u{15}") }
        terminal.view.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
    }

    // MARK: Questions beside previews

    /// Whether the notes of a question beside previews are open for typing:
    /// as the screen's text says, else from its colors. Unknown counts as
    /// closed: Esc there would cancel the question.
    func notesOpen(_ p: ScreenPrompt) async -> Bool {
        if let open = p.notesOpen { return open }
        guard let m = record, let c = connection,
              let screen = await StyledScreen.read(address, connection: c, cols: m.cols, rows: m.rows)
        else { return false }
        return screen.notesShowOpen
    }

    /// Closes the open notes (Esc there keeps their words), so that keys
    /// reach the options again.
    private func closeNotes(_ p: ScreenPrompt) async throws -> ScreenPrompt {
        guard await notesOpen(p) else { return p }
        try await pressAndSettle(["esc"])
        return try await readPrompt() ?? p
    }

    /// The question's options take keys: the notes closed, the cursor up
    /// from `Chat about this` (where ← → and digits do nothing).
    private func onOptions(_ p: ScreenPrompt) async throws -> ScreenPrompt {
        var p = try await closeNotes(p)
        if p.chatFocused {
            try await pressAndSettle(["up"])
            p = try await readPrompt() ?? p
        }
        return p
    }

    /// Opens the notes, emptied: `n` opens them, ⌃U empties them.
    private func openNotes(_ p: ScreenPrompt) async throws {
        var p = p
        if p.chatFocused {
            try await pressAndSettle(["up"])
            p = try await readPrompt() ?? p
        }
        if await !notesOpen(p) {
            try await pressAndSettle(["n"])
            guard let found = try await waitPrompt(2, until: { $0?.previews == true && $0?.notesOpen != false }), let now = found else {
                throw fail("Claude's screen didn't open the notes for your answer.")
            }
            p = now
        }
        if !p.notes.isEmpty { try await press(["ctrl+u"]) }
    }

    /// Words into the open notes, unsent, pasted as the person's own.
    private func pasteNotes(_ text: String) async throws {
        let terminal = try await attachedTerminal(for: "your answer")
        terminal.view.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        _ = try await waitPrompt(2, until: { $0?.notes == words })
    }

    /// Answers a question beside previews: its digit moves the cursor to
    /// the option, Enter picks it, with the notes made to hold the card's
    /// words (Claude takes both). Words alone go in as notes, and Enter
    /// there answers with them; but once the cursor moved on the options
    /// (in the terminal), Claude Code picks the option under it instead,
    /// the notes with it.
    private func answerBesidePreviews(_ q: AskQuestion, _ a: AskAnswer, _ p: ScreenPrompt, shown: AskAnswer) async throws {
        guard let label = a.chosen.first, let i = q.options.firstIndex(where: { $0.label == label }) else {
            guard !a.text.isEmpty else { throw fail("No answer chosen for “\(q.question)”.") }
            try await openNotes(p)
            try await typeIn(a.text)
            return
        }
        var p = p
        if a.text != shown.text {
            try await openNotes(p)
            if !a.text.isEmpty { try await pasteNotes(a.text) }
            p = try await readPrompt() ?? p
        }
        try await pick(i + 1, besidePreviews: try await onOptions(p))
    }

    /// Option `n` of a question beside previews: its digit brings the
    /// cursor (it doesn't pick), Enter picks.
    private func pick(_ n: Int, besidePreviews p: ScreenPrompt) async throws {
        if p.options.first(where: \.focused)?.number != n {
            try await press(["\(n)"])
            guard try await waitPrompt(2, until: { $0?.options.first(where: \.focused)?.number == n }) != nil else {
                throw fail("Claude's cursor didn't reach option \(n).")
            }
        }
        try await press(["enter"])
    }

    /// The card's answer onto a lone question beside previews, unsent: its
    /// words wait in the notes, left open; its option gets the cursor.
    private func putBesidePreviews(_ q: AskQuestion, _ a: AskAnswer, _ p: ScreenPrompt, shown: AskAnswer) async throws {
        if !a.text.isEmpty {
            guard a.text != shown.text else { return }
            try await openNotes(p)
            try await pasteNotes(a.text)
            return
        }
        let p = try await onOptions(p)
        guard let label = a.chosen.first, let i = q.options.firstIndex(where: { $0.label == label }),
              p.options.first(where: \.focused)?.number != i + 1
        else { return }
        try await press(["\(i + 1)"])
    }

    /// Runs `body` as the one action under way, then reads the screen anew.
    func acting(_ body: () async throws -> Void) async throws {
        guard !acting else { throw fail("Already answering \(agentName).") }
        acting = true
        actionError = nil
        defer {
            acting = false
            prompt = nil
            promptRead = false
            dialog = nil
            rereadScreen()
        }
        do {
            try await body()
        } catch {
            actionError = (error as? ActionError)?.message ?? (error as? CoreError)?.message ?? error.localizedDescription
            throw error
        }
    }

    // MARK: Choices

    /// Presses the keys that pick `option` in what Claude asks, or in a menu of its own.
    func choose(_ option: ScreenPrompt.Option, in shown: ScreenPrompt) async {
        if shown.searchable { return await pick(option, in: shown) }
        // /rewind: first the message it goes back to, then what goes back.
        if shown.isRewindList {
            rewindTarget = Rewind.prompt(for: option.number - 1, labels: shown.options.map(\.label), in: rewindable)
        }
        // Its second step: what goes back. All but Never mind give the message back to the input box.
        let rewinding = shown.isRewindConfirm && !option.label.localizedCaseInsensitiveContains("never mind")
        let target = rewindTarget
        if shown.isRewindConfirm { rewindTarget = nil }
        // Gemini's: the conversation going back puts the message in its input box.
        let geminiConfirm = isGemini && shown.heading == "Confirm Rewind"
        let geminiRewinds = geminiConfirm && option.label.hasPrefix("Rewind conversation")
        let sent = geminiRewinds ? rewindable : []
        // Its Do nothing goes back to the list: opened by a message's Rewind, the list closes too.
        let closeList = geminiConfirm && option.label.hasPrefix("Do nothing") && rewindTarget != nil
        if isGemini, shown.heading == "Rewind" || geminiConfirm { rewindTarget = nil }
        try? await acting {
            var screen = try await readScreen()
            // Codex's notes open, typed in its terminal: a digit would go
            // into them. They move to the field under the card first.
            if isCodex, AgentInput.codexNotes(screen: screen, columns: record?.cols ?? 80) != nil {
                try await takeCodexNotes(screen)
                screen = try await readScreen()
            }
            // Gemini's cursor on its line for one's own words: a digit would
            // type into them. ↑ leaves the line and keeps them.
            if isGemini, let p = parsePrompt(screen), p.title == "Answer Questions", let n = p.customOption,
               p.options.first(where: \.focused)?.number == n
            {
                try await pressAndSettle(["up"])
                screen = try await readScreen()
            }
            // The cursor may have moved since the card was drawn.
            let now = parsePrompt(screen) ?? shown
            guard let same = now.options.first(where: { $0.number == option.number && $0.label == option.label }) ?? now.option(labelled: option.label)
            else { throw fail("\(agentName)'s screen changed. Look again, or answer in the terminal.") }
            if now.previews {
                try await pick(same.number, besidePreviews: try await onOptions(now))
                return
            }
            try await pressAndSettle(now.keys(for: same))
        }
        if rewinding, actionError == nil {
            let summary = option.label.localizedCaseInsensitiveContains("summarize")
            await finishRewind(to: target, cut: option.label.localizedCaseInsensitiveContains("conversation"), wait: summary ? 300 : 4)
        }
        if geminiRewinds, actionError == nil { await finishGeminiRewind(sent: sent) }
        if closeList, actionError == nil {
            try? await acting {
                if try await rewindList(after: nil) != nil { try await press(["esc"]) }
            }
        }
    }

    /// After Gemini's rewind: the message chosen comes back in its input
    /// box. It moves to the Messages field, whole as it was sent when
    /// `sent` (the messages before the rewind) has it, not as the box wraps it.
    private func finishGeminiRewind(sent: [(id: String, text: String)]) async {
        var restored: String?
        let end = Date().addingTimeInterval(4)
        while restored == nil, Date() < end {
            try? await Task.sleep(for: .milliseconds(250))
            guard let screen = try? await readScreen() else { continue }
            restored = ClaudeFooter.parseGemini(screen: screen)?.input
        }
        guard let restored, !restored.isEmpty else { return }
        try? await acting {
            // Esc twice empties Gemini's input box: the field holds the message now.
            try await press(["esc"])
            try await Task.sleep(for: .milliseconds(150))
            try await press(["esc"])
            let cleared = Date().addingTimeInterval(2)
            while Date() < cleared {
                try await Task.sleep(for: .milliseconds(150))
                if ClaudeFooter.parseGemini(screen: try await readScreen())?.input?.isEmpty == true { return }
            }
            throw fail("Gemini kept the message in its input box: send or clear it in the terminal.")
        }
        guard actionError == nil else { return }
        let words = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        putInField(sent.last { words($0.text) == words(restored) }?.text ?? restored)
    }

    /// Goes back to before the prompt `id` (nil: opens the list only), as
    /// Esc Esc does on Claude's or Gemini's screen: its list opens, the
    /// cursor climbs to that message, Enter. What to restore is the agent's
    /// next question, a card of its own.
    func rewind(to id: String?) async {
        let shown = rewindable
        let at = id.flatMap { id in shown.firstIndex { $0.id == id } }
        try? await acting {
            guard record?.status?.state != "working" else { throw fail("\(agentName) is at work: rewind once it's done.") }
            guard let box = await boxText(try await readScreen()) else {
                throw fail("\(agentName)'s input box isn't showing: close what's on its screen first.")
            }
            guard box.isEmpty else { throw fail("\(agentName)'s input box holds text: send or clear it first.") }
            // Esc twice on an empty input box: the list of messages to go back to.
            try await press(["esc"])
            try await Task.sleep(for: .milliseconds(150))
            try await press(["esc"])
            guard var list = try await rewindList(after: nil) else { throw fail("\(agentName)'s rewind list didn't open.") }
            guard let at, let id else { return }
            let words = shown[at].text
            // Messages further down with the same words: as many to pass.
            let later = shown[(at + 1)...].filter { Rewind.alike($0.text, words) }.count
            var passed = 0
            for _ in 0 ..< 300 {
                try await press(["up"])
                // The cursor stayed (the top) or went round to the end: not in the list.
                guard let next = try await rewindList(after: list),
                      let focused = next.options.first(where: \.focused), focused.label != "(current)"
                else { break }
                list = next
                guard Rewind.names(focused.label, words) else { continue }
                if passed == later {
                    rewindTarget = id
                    try await press(["enter"])
                    return
                }
                passed += 1
            }
            try await press(["esc"])
            throw fail("\(agentName)'s rewind list doesn't name that message.")
        }
    }

    /// The rewind list on the agent's screen, once its cursor isn't where it
    /// was in `before`; nil when it doesn't show so within 1.5 s.
    private func rewindList(after before: ScreenPrompt?) async throws -> ScreenPrompt? {
        func at(_ p: ScreenPrompt) -> String? {
            p.options.first(where: \.focused).map { "\($0.number) \($0.label)" }
        }
        let end = Date().addingTimeInterval(1.5)
        while true {
            if let p = parsePrompt(try await readScreen()), p.heading == "Rewind", !p.numbered,
               before == nil || at(p) != at(before!) || p.options != before!.options {
                return p
            }
            if Date() >= end { return nil }
            try await Task.sleep(for: .milliseconds(80))
        }
    }

    /// After /rewind's second step: Claude Code puts the message chosen
    /// back in its input box (at once, or once its summary is written). It
    /// moves to the Messages field. When the conversation went back
    /// (`cut`), the rows from that message on go out of sight.
    private func finishRewind(to id: String?, cut: Bool, wait seconds: Double) async {
        // The input box comes back, with the message or empty.
        var restored: String?
        let end = Date().addingTimeInterval(seconds)
        while restored == nil, Date() < end {
            try? await Task.sleep(for: .milliseconds(250))
            guard let screen = try? await readScreen() else { continue }
            // Claude's dim suggestion may come back in an empty box: not the message.
            restored = await boxText(screen)
        }
        // No input box: the rewind didn't end (or went elsewhere); the rows stay.
        guard let restored else { return }
        var words: (text: String, images: Int)?
        if let id { words = cut ? rewound(to: id) : said(id) }
        guard !restored.isEmpty else { return }
        try? await acting {
            // The field holds the message now.
            if try await emptyBox() { return }
            words = nil
            throw fail("\(agentName) kept the message in its input box: send or clear it in the terminal.")
        }
        guard actionError == nil else { return }
        // The transcript's words, whole; else the box's, as the screen wraps them.
        putInField(words?.text ?? restored)
        if let words, words.images > 0 { actionError = "The message's pictures stay behind: attach them again to send them." }
    }

    // MARK: Codex's messages held for the turn's end

    /// What Codex holds for the turn's end, whole: its screen cuts each
    /// message to three lines, filled out from those Swiftr gave it. Empty
    /// when one it shows cut was typed in its terminal, and for the other
    /// agents (Claude Code sends what it holds at once when stopped).
    func heldForTurnEnd() async -> [String] {
        guard isCodex, let screen = try? await readScreen(),
              let shown = ClaudeFooter.parseCodex(screen: screen)?.queued
        else { return [] }
        var held: [String] = []
        for line in shown {
            if let whole = codexQueuedHere.last(where: { Self.codexHolds(line, $0) }) {
                held.append(whole)
            } else if line.hasSuffix("\n…") {
                return []
            } else {
                held.append(line)
            }
        }
        return held
    }

    /// Esc puts what Codex held for the turn's end back in its input, one
    /// message a line. It moves to the field, whole, so that the next
    /// message doesn't go out glued to it.
    func takeBack(_ held: [String]) async {
        let text = held.joined(separator: "\n")
        let start = Date()
        var shown = false
        while Date().timeIntervalSince(start) < 6 {
            try? await Task.sleep(for: .milliseconds(250))
            // While Codex still lists them, they aren't back.
            guard let f = ClaudeFooter.parseCodex(screen: (try? await readScreen()) ?? ""), f.queued.isEmpty else { continue }
            let holds = f.input.map { Self.codexHolds($0, text) } ?? false
            // Gone again: Codex sent them itself.
            if shown, !holds { return }
            shown = holds
            // Stopped soon after the message was queued, Codex sends it a
            // second after Esc: past that, it keeps it.
            if shown, Date().timeIntervalSince(start) >= 2 { break }
        }
        guard shown else { return }
        try? await acting { try await emptyCodexInput(text) }
        guard actionError == nil else { return }
        codexQueuedHere = []
        putInField(text)
    }

    /// One of OpenCode's pickers: its search narrows the list a word of
    /// the option at a time, until the option comes first, where the
    /// picker's cursor goes; Enter takes it. A word the search doesn't
    /// find (one of a description) is taken back, and arrows go the rest.
    private func pick(_ option: ScreenPrompt.Option, in shown: ScreenPrompt) async {
        try? await acting {
            let title = shown.title
            func list(_ query: String) async throws -> ScreenPrompt? {
                let end = Date().addingTimeInterval(2)
                while true {
                    if let d = ScreenPrompt.openCodeDialog(screen: try await readScreen(), query: query), d.searchable, d.title == title { return d }
                    if Date() >= end { return nil }
                    try await Task.sleep(for: .milliseconds(120))
                }
            }
            func index(in d: ScreenPrompt) -> Int? {
                d.options.firstIndex { $0.label == option.label && $0.detail == option.detail }
            }
            let missing = fail("OpenCode's \(title ?? "picker") doesn't list “\(option.label)” any more. Look again, or choose in the terminal.")
            try await press(["ctrl+u"])
            var typed = ""
            for word in option.label.split(separator: " ").map(String.init) {
                let next = typed.isEmpty ? word : typed + " " + word
                let keys = ScreenPrompt.searchKeys(typed.isEmpty ? word : " " + word)
                guard !keys.isEmpty else { continue }
                try await press(keys)
                guard let d = try await list(next) else {
                    throw fail("OpenCode's \(title ?? "picker") didn't show the search. Look again, or choose in the terminal.")
                }
                guard let at = index(in: d) else {
                    // Not in the list any more: the word is taken back.
                    try await press(Array(repeating: "backspace", count: keys.count))
                    break
                }
                if at == 0 {
                    try await press(["enter"])
                    return
                }
                typed = next
            }
            guard !typed.isEmpty, let d = try await list(typed), let at = index(in: d) else { throw missing }
            try await press(Array(repeating: "down", count: at) + ["enter"])
        }
    }

    /// Esc: Claude's question, permission or menu is cancelled.
    func escape() async {
        try? await acting {
            let rewinding = try await readPrompt()?.isRewindConfirm == true
            try await pressAndSettle(["esc"])
            // Esc on /rewind's second step goes back to its list: Cancel closes both.
            if rewinding, try await waitPrompt(1, until: { $0?.isRewindList == true }) != nil {
                try await pressAndSettle(["esc"])
            }
        }
    }

    // MARK: Questions

    /// AskUserQuestion's call Claude waits on, with its questions; OpenCode's
    /// `question` call, read as one.
    var openQuestion: (call: ToolCall, questions: [AskQuestion])? {
        guard agent == .claude || isOpenCode, record?.status?.state == "blocked",
              isOpenCode || record?.status?.kind == "question",
              let call = openCalls.last(where: { $0.name == "AskUserQuestion" })
        else { return nil }
        let questions = AskQuestion.list(call.input)
        return questions.isEmpty ? nil : (call, questions)
    }

    /// Brings Claude's screen to question `i` (its tab) from wherever the
    /// person left it in the terminal: ← and →, from off the field for
    /// one's own words (it takes those keys). The question's prompt; nil
    /// when it doesn't show.
    private func showQuestion(_ i: Int, of questions: [AskQuestion]) async throws -> ScreenPrompt? {
        for _ in 0 ..< 3 {
            guard let p = try await readPrompt(), let at = p.questionIndex(in: questions) else { return nil }
            if at == i { return p }
            if p.previews {
                // In the notes, or on `Chat about this`, ← → do nothing.
                _ = try await onOptions(p)
            } else if at < questions.count, p.options.first(where: \.focused)?.number == questions[at].typeNumber {
                try await pressAndSettle(["up"])
            }
            try await press(Array(repeating: i > at ? "right" : "left", count: abs(i - at)))
            if let found = try await waitPrompt(2, until: { $0?.questionIndex(in: questions) == i }), let p = found { return p }
        }
        return nil
    }

    /// What the person answered on Claude's screen (or OpenCode's), in its
    /// terminal, comes into the question's card: the question shown, and
    /// each tab answered, visited with ← and →; the screen goes back to the
    /// question it showed. What the screen doesn't show stays as chosen in
    /// the card. Once at a time; after the action under way.
    func readAnswers(_ questions: [AskQuestion], call: String) async {
        guard agent == .claude || isOpenCode, !readingAnswers, !questions.isEmpty else { return }
        readingAnswers = true
        defer { readingAnswers = false }
        for _ in 0 ..< 30 where acting { try? await Task.sleep(for: .milliseconds(100)) }
        guard !acting else { return }
        try? await acting {
            let found = isOpenCode ? try await openCodeAnswersShown(questions) : try await claudeAnswersShown(questions)
            guard !found.isEmpty else { return }
            var answers = askAnswers[call] ?? []
            if answers.count != questions.count { answers = Array(repeating: AskAnswer(), count: questions.count) }
            for (i, a) in found {
                // A single choice shows its mark only once its tab is left: none is no news.
                if !a.isEmpty || questions[i].multiSelect { answers[i] = a }
            }
            askAnswers = [call: answers]
            answersRead = (call, answers)
        }
    }

    /// The answers Claude's screen shows: the question it asks, and each
    /// tab marked answered, visited with ← and →; then back to the first.
    private func claudeAnswersShown(_ questions: [AskQuestion]) async throws -> [Int: AskAnswer] {
        guard let p = try await readPrompt(), let at = p.questionIndex(in: questions) else { return [:] }
        var found: [Int: AskAnswer] = [:]
        if at < questions.count { found[at] = p.shownAnswer(for: questions[at]) }
        let tabs = p.tabs.filter { !$0.isSubmit }
        let others = tabs.indices.filter { tabs[$0].answered && $0 != at && $0 < questions.count }
        if !others.isEmpty {
            for i in others {
                guard let shown = try await showQuestion(i, of: questions) else { break }
                found[i] = shown.shownAnswer(for: questions[i])
            }
            _ = try await showQuestion(at, of: questions)
        }
        return found
    }

    /// The answers OpenCode's question box shows. Its tab bar marks none
    /// answered: each question's tab is visited with → and ←, then the box
    /// goes back to the tab it showed. While the person types their own
    /// words there, where the arrows would move, that tab alone.
    private func openCodeAnswersShown(_ questions: [AskQuestion]) async throws -> [Int: AskAnswer] {
        guard let at = try await openCodeTab(of: questions) else { return [:] }
        let p = try await readPrompt()
        var found: [Int: AskAnswer] = [:]
        if at < questions.count, let p { found[at] = p.shownAnswer(for: questions[at]) }
        if p.map(Self.typingOwnWords) == true { return found }
        for i in questions.indices where i != at {
            guard try await goToOpenCodeTab(i, of: questions), let shown = try await readPrompt() else { break }
            found[i] = shown.shownAnswer(for: questions[i])
        }
        _ = try await goToOpenCodeTab(at, of: questions)
        return found
    }

    /// The tab OpenCode's question box shows: a question's index, or the
    /// count of them for its Submit tab; nil when it shows none of them.
    private func openCodeTab(of questions: [AskQuestion]) async throws -> Int? {
        let screen = try await readScreen()
        if ScreenPrompt.isOpenCodeReview(screen: screen) { return questions.count }
        return parsePrompt(screen)?.questionIndex(in: questions)
    }

    /// Brings OpenCode's question box to tab `i` with → and ←: false when
    /// it doesn't get there.
    private func goToOpenCodeTab(_ i: Int, of questions: [AskQuestion]) async throws -> Bool {
        for _ in 0 ..< 3 {
            guard let at = try await openCodeTab(of: questions) else { return false }
            if at == i { return true }
            try await press(Array(repeating: i > at ? "right" : "left", count: abs(i - at)))
            let end = Date().addingTimeInterval(2)
            while Date() < end {
                try await Task.sleep(for: .milliseconds(100))
                if try await openCodeTab(of: questions) == i { return true }
            }
        }
        return false
    }

    /// OpenCode's field for one's own words is open (`enter confirm  esc close`).
    nonisolated static func typingOwnWords(_ p: ScreenPrompt) -> Bool {
        p.footer.contains("esc close")
    }

    /// The card's answers onto OpenCode's question box, unsent, each on its
    /// question's tab: a choice picked (OpenCode moves on to the next tab,
    /// from the last to Submit), boxes checked, own words typed and
    /// confirmed. A lone question with one answer sends it once picked:
    /// there only own words go in, unconfirmed, and a choice takes off the
    /// words shown (they would come back into the card). The field for own
    /// words, left open in the terminal, stays so when the card didn't
    /// change since it was read; else it closes first (Esc keeps its words).
    private func pushOpenCodeAnswers(_ questions: [AskQuestion], _ answers: [AskAnswer], call: String) async throws {
        if let p = try await readPrompt(), Self.typingOwnWords(p) {
            if let read = answersRead, read.call == call, read.answers == answers { return }
            try await press(["esc"])
            guard try await waitPrompt(2, until: { $0.map(Self.typingOwnWords) == false }) != nil else { return }
        }
        let lone = questions.count == 1 && !questions[0].multiSelect
        for (i, (q, a)) in zip(questions, answers).enumerated() where !a.isEmpty {
            guard try await goToOpenCodeTab(i, of: questions), let p = try await readPrompt(), p.asks(q) else { return }
            let shown = p.shownAnswer(for: q)
            if shown == a { continue }
            if q.multiSelect {
                guard let toggles = p.toggles(toMatch: a.chosen, in: q) else { return }
                if !toggles.isEmpty {
                    try await pressOpenCodeToggles(toggles)
                    _ = try await waitPrompt(3, until: { $0?.toggles(toMatch: a.chosen, in: q)?.isEmpty == true })
                }
                if a.text.isEmpty, !shown.text.isEmpty {
                    try await clearOwnWords(q)
                } else if a.text != shown.text {
                    // Enter: done, on the same tab.
                    guard try await openOwnWords(q) else { return }
                    try await typeIn(a.text)
                }
            } else if !a.text.isEmpty {
                guard try await openOwnWords(q) else { return }
                if lone {
                    let terminal = try await attachedTerminal(for: "your answer")
                    terminal.view.send(txt: "\u{1b}[200~" + a.text + "\u{1b}[201~")
                } else {
                    // Enter confirms them, and OpenCode moves on.
                    try await typeIn(a.text)
                }
            } else if lone {
                if !shown.text.isEmpty { try await clearOwnWords(q) }
            } else if let label = a.chosen.first, let n = q.options.firstIndex(where: { $0.label == label }) {
                try await pressOpenCodeOption(n + 1)
            }
        }
    }

    /// Takes one's own words off `q`'s tab: the field opens, empties, and
    /// closes empty (Esc), unchecked.
    private func clearOwnWords(_ q: AskQuestion) async throws {
        guard try await openOwnWords(q) else { return }
        try await press(["esc"])
        _ = try await waitPrompt(2, until: { $0.map(Self.typingOwnWords) == false })
    }

    /// Presses `digit` on OpenCode's question box as a choice. With the
    /// cursor on the field for one's own words (it can't be seen but in
    /// color), the digit goes into the field instead: then it comes out
    /// (⌫), the field closes (Esc keeps its words), the cursor moves off
    /// it (↑), and the digit goes again.
    private func pressOpenCodeDigit(_ digit: Int) async throws {
        try await pressAndSettle(["\(digit)"])
        guard let p = try await readPrompt(), Self.typingOwnWords(p) else { return }
        try await press(["backspace", "esc", "up"])
        try await Task.sleep(for: .milliseconds(250))
        try await pressAndSettle(["\(digit)"])
    }

    /// Picks OpenCode's option `n` (or ticks its box): its digit; past 9,
    /// where no key names it, arrows from where its cursor is (only its
    /// colors tell), then Enter. Words being typed in its field for one's
    /// own go first: Esc keeps them and closes it.
    private func pressOpenCodeOption(_ n: Int) async throws {
        if n <= 9 { return try await pressOpenCodeDigit(n) }
        if let p = try await readPrompt(), Self.typingOwnWords(p) {
            try await press(["esc"])
            _ = try await waitPrompt(2, until: { $0.map(Self.typingOwnWords) == false })
        }
        guard let at = await openCodeCursor() else {
            throw fail("OpenCode's screen doesn't show its cursor. Pick answer \(n) in the terminal.")
        }
        if at != n {
            try await press(Array(repeating: n > at ? "down" : "up", count: abs(n - at)))
            let end = Date().addingTimeInterval(2)
            while await openCodeCursor() != n {
                guard Date() < end else { throw fail("OpenCode's cursor didn't reach answer \(n).") }
                try await Task.sleep(for: .milliseconds(120))
            }
        }
        try await pressAndSettle(["enter"])
    }

    /// The option OpenCode's cursor is on, from its screen's colors.
    private func openCodeCursor() async -> Int? {
        guard let m = record, let c = connection,
              let styled = await StyledScreen.read(address, connection: c, cols: m.cols, rows: m.rows)
        else { return nil }
        return styled.openCodeCursor
    }

    /// Ticks OpenCode's boxes `toggles` (their digits, as `toggles(toMatch:)`
    /// gives them): the first as `pressOpenCodeOption` does (it takes the
    /// cursor off the field for own words), the others up to 9 at once,
    /// those past 9 with arrows.
    private func pressOpenCodeToggles(_ toggles: [String]) async throws {
        let numbers = toggles.compactMap(Int.init)
        guard let first = numbers.first else { return }
        try await pressOpenCodeOption(first)
        let rest = numbers.dropFirst()
        try await press(rest.filter { $0 <= 9 }.map(String.init))
        for n in rest where n > 9 { try await pressOpenCodeOption(n) }
    }

    /// Opens OpenCode's field for one's own words on `q`'s tab, checked
    /// where it takes several answers, and empties it (⌃U). Its digit opens
    /// it, or goes into it when the cursor is there already; on a box
    /// checked already it unchecks it, and a second press opens it. False
    /// when it doesn't open.
    private func openOwnWords(_ q: AskQuestion) async throws -> Bool {
        for _ in 0 ..< 2 {
            if q.typeNumber <= 9 { try await press(["\(q.typeNumber)"]) } else { try await pressOpenCodeOption(q.typeNumber) }
            if try await waitPrompt(1.5, until: { $0.map(Self.typingOwnWords) == true }) != nil {
                try await press(["ctrl+u"])
                return true
            }
        }
        return false
    }

    /// The answers chosen in the card go onto Claude's screen (or
    /// OpenCode's), unsent, so that its terminal shows them: each on its question's tab, where
    /// choosing moves Claude on to the next. A lone question's choice is
    /// only pointed at (choosing it would send it), and its own words wait
    /// unsent in the field for them.
    func pushAnswers(_ questions: [AskQuestion], call: String) async {
        guard agent == .claude || isOpenCode, !acting, let answers = askAnswers[call], answers.count == questions.count,
              answers.contains(where: { !$0.isEmpty })
        else { return }
        if isOpenCode {
            try? await acting { try await pushOpenCodeAnswers(questions, answers, call: call) }
            return
        }
        try? await acting {
            let lone = questions.count == 1
            for (i, (q, a)) in zip(questions, answers).enumerated() where !a.isEmpty {
                guard let p = try await showQuestion(i, of: questions) else { return }
                let shown = p.shownAnswer(for: q)
                if shown == a { continue }
                if q.multiSelect {
                    try await setBoxes(q, a, p, shown: shown)
                } else if lone, p.previews {
                    try await putBesidePreviews(q, a, p, shown: shown)
                } else if lone, !a.text.isEmpty {
                    try await putWords(q, a.text, p, shown: shown)
                } else if lone {
                    guard let label = a.chosen.first, let n = q.options.firstIndex(where: { $0.label == label }),
                          let target = p.options.first(where: { $0.number == n + 1 })
                    else { continue }
                    try await press(p.moves(to: target))
                } else {
                    try await answerOne(q, a, p, shown: shown)
                    _ = try await waitPrompt(3, until: { $0.map { !$0.asks(q) } ?? true })
                }
            }
        }
    }

    /// Answers AskUserQuestion's questions in order, as the person filled
    /// them in here, then submits the answers. Each from its tab, wherever
    /// the terminal left Claude's screen, and with what it shows there.
    func answer(_ questions: [AskQuestion], _ answers: [AskAnswer]) async throws {
        if isOpenCode { return try await answerOpenCode(questions, answers) }
        try await acting {
            for (i, (q, a)) in zip(questions, answers).enumerated() {
                guard let p = try await showQuestion(i, of: questions) else {
                    throw fail("Claude's screen doesn't show the question “\(q.question)”.")
                }
                let shown = p.shownAnswer(for: q)
                if q.multiSelect {
                    try await answerMany(q, a, p, shown: shown)
                } else {
                    try await answerOne(q, a, p, shown: shown)
                }
                // On to the next question, the review, or done.
                guard try await waitPrompt(4, until: { $0.map { !$0.asks(q) } ?? true }) != nil else {
                    throw fail("Claude didn't take the answer to “\(q.question)”.")
                }
            }
            // Two questions or more, or a multi-select one: Claude shows the answers first.
            if let p = try await readPrompt(), p.isReview {
                guard let submit = p.options.first(where: { $0.label.lowercased().hasPrefix("submit") }) else {
                    throw fail("Claude's review of the answers has no Submit.")
                }
                try await press(p.keys(for: submit))
            }
        }
    }

    /// `p`: the question on Claude's screen; `shown`: what it shows answered
    /// there already (own words typed in its terminal stay, or give way to
    /// these). With the cursor on the field for one's own words, keys go
    /// into it, digits too; ⌃U empties it.
    func answerOne(_ q: AskQuestion, _ a: AskAnswer, _ p: ScreenPrompt, shown: AskAnswer = AskAnswer()) async throws {
        if p.previews { return try await answerBesidePreviews(q, a, p, shown: shown) }
        let inField = p.options.first(where: \.focused)?.number == q.typeNumber
        if !a.text.isEmpty {
            // Its digit opens the field; the text then goes in with Enter.
            if !inField {
                try await press(["\(q.typeNumber)"])
                try await Task.sleep(for: .milliseconds(250))
            }
            if shown.other == a.text {
                try await press(["enter"])
                return
            }
            if !shown.other.isEmpty { try await press(["ctrl+u"]) }
            try await typeIn(a.text)
            return
        }
        guard let label = a.chosen.first, let i = q.options.firstIndex(where: { $0.label == label }) else {
            throw fail("No answer chosen for “\(q.question)”.")
        }
        if inField { try await pressAndSettle(["up"]) }
        try await press(["\(i + 1)"])
    }

    /// A multi-select question's boxes and own words as `a` has them, its
    /// answer not yet given (`answerMany`).
    private func setBoxes(_ q: AskQuestion, _ a: AskAnswer, _ prompt: ScreenPrompt, shown: AskAnswer) async throws {
        var prompt = prompt
        // On the field for one's own words, digits would go into it.
        if prompt.options.first(where: \.focused)?.number == q.typeNumber {
            try await pressAndSettle(["up"])
            prompt = try await readPrompt() ?? prompt
        }
        // Digits check and uncheck without moving the cursor.
        guard let toggles = prompt.toggles(toMatch: a.chosen, in: q) else {
            throw fail("Claude's screen doesn't show the options of “\(q.question)”.")
        }
        try await press(toggles)
        guard try await waitPrompt(3, until: { $0?.toggles(toMatch: a.chosen, in: q)?.isEmpty == true }) != nil else {
            throw fail("The boxes of “\(q.question)” didn't change as expected.")
        }
        guard shown.other != a.text else { return }
        // The field for one's own words: typing there checks it, ⌃U empties
        // and unchecks it; Enter then switches it, so look.
        guard let p = try await readPrompt(), let field = p.options.first(where: { $0.number == q.typeNumber }) else {
            throw fail("Claude's screen has no field for your own answer.")
        }
        try await press(p.moves(to: field))
        guard try await waitPrompt(2, until: { $0?.options.first(where: \.focused)?.number == q.typeNumber }) != nil else {
            throw fail("Couldn't reach the field for your own answer.")
        }
        if !shown.other.isEmpty { try await press(["ctrl+u"]) }
        if !a.text.isEmpty { try await typeIn(a.text) }
        try await Task.sleep(for: .milliseconds(200))
        if let p = try await readPrompt(), let box = p.options.first(where: { $0.number == q.typeNumber })?.checked, box != !a.text.isEmpty {
            try await press(["enter"])
        }
    }

    func answerMany(_ q: AskQuestion, _ a: AskAnswer, _ prompt: ScreenPrompt, shown: AskAnswer = AskAnswer()) async throws {
        try await setBoxes(q, a, prompt, shown: shown)
        // Down to Submit, under the options.
        guard let p = try await readPrompt(), let downs = p.downsToSubmit else {
            throw fail("Claude's screen has no Submit for “\(q.question)”.")
        }
        try await press(Array(repeating: "down", count: downs))
        guard try await waitPrompt(2, until: { $0?.submitFocused == true }) != nil else {
            throw fail("Couldn't reach Submit for “\(q.question)”.")
        }
        try await press(["enter"])
    }

    /// OpenCode's questions: a tab each, and Submit, when there are several
    /// or one takes several answers; else picking the answer sends it. Its
    /// digits pick, or check and uncheck; `Type your own answer` opens a
    /// field; → moves on; Enter on the last tab sends the answers. Each
    /// answer from its tab, wherever the terminal left the box, with what
    /// the box shows there already (the card's answers went onto it).
    private func answerOpenCode(_ questions: [AskQuestion], _ answers: [AskAnswer]) async throws {
        try await acting {
            // The field for own words, left open in the terminal: Esc closes it, keeping them.
            if let p = try await readPrompt(), Self.typingOwnWords(p) {
                try await press(["esc"])
                _ = try await waitPrompt(2, until: { $0.map(Self.typingOwnWords) == false })
            }
            var tabbed = false
            for (i, (q, a)) in zip(questions, answers).enumerated() {
                // Each from its tab, wherever the terminal left the box.
                _ = try await goToOpenCodeTab(i, of: questions)
                guard let found = try await waitPrompt(4, until: { $0.map { $0.asks(q) } ?? false }), let p = found else {
                    throw fail("OpenCode's screen doesn't show the question “\(q.question)”.")
                }
                tabbed = !p.tabs.isEmpty
                let shown = p.shownAnswer(for: q)
                if q.multiSelect {
                    guard let toggles = p.toggles(toMatch: a.chosen, in: q) else {
                        throw fail("OpenCode's screen doesn't show the options of “\(q.question)”.")
                    }
                    try await pressOpenCodeToggles(toggles)
                    guard try await waitPrompt(3, until: { $0?.toggles(toMatch: a.chosen, in: q)?.isEmpty == true }) != nil else {
                        throw fail("The boxes of “\(q.question)” didn't change as expected.")
                    }
                    if a.text.isEmpty, !shown.text.isEmpty {
                        try await clearOwnWords(q)
                    } else if a.text != shown.text {
                        // Its field opens; Enter puts the words in, checked.
                        guard try await openOwnWords(q) else { throw fail("OpenCode's screen didn't open the field for your own answer.") }
                        try await typeIn(a.text)
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    // → moves on, as Tab does: OpenCode 1.x's Tab also
                    // switches the agent under the box (Build → Plan).
                    try await press(["right"])
                } else if !a.text.isEmpty {
                    guard try await openOwnWords(q) else { throw fail("OpenCode's screen didn't open the field for your own answer.") }
                    try await typeIn(a.text)
                } else {
                    guard let label = a.chosen.first, let i = q.options.firstIndex(where: { $0.label == label }) else {
                        throw fail("No answer chosen for “\(q.question)”.")
                    }
                    try await pressOpenCodeOption(i + 1)
                }
                guard try await waitPrompt(4, until: { $0.map { !$0.asks(q) } ?? true }) != nil else {
                    throw fail("OpenCode didn't take the answer to “\(q.question)”.")
                }
            }
            guard tabbed else { return }
            // The answers show on the last tab: Enter sends them.
            let end = Date().addingTimeInterval(3)
            while Date() < end {
                if ScreenPrompt.isOpenCodeReview(screen: try await readScreen()) {
                    try await press(["enter"])
                    return
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            throw fail("OpenCode's screen doesn't show the answers to send.")
        }
    }

    /// AskUserQuestion's "Chat about this": no answer; the person writes instead.
    func chatInstead(_ q: AskQuestion) async throws {
        try await acting {
            // Beside previews it has no digit: ↓ from the last option reaches it.
            if let p = try await readPrompt(), p.previews {
                let on = try await closeNotes(p)
                if !on.chatFocused {
                    let at = on.options.first(where: \.focused)?.number ?? 1
                    try await press(Array(repeating: "down", count: on.options.count - at + 1))
                    guard try await waitPrompt(2, until: { $0?.chatFocused == true }) != nil else {
                        throw fail("Claude's cursor didn't reach “Chat about this”.")
                    }
                }
                try await press(["enter"])
                return
            }
            guard let p = try await readPrompt(), let chat = p.options.first(where: { $0.label.lowercased().hasPrefix("chat about") }) ?? p.options.first(where: { $0.number == q.chatNumber })
            else { throw fail("Claude's screen has no “Chat about this”.") }
            try await press(p.keys(for: chat))
        }
    }

    // MARK: Permissions and plans

    /// Says no to what Claude asks, with what to do instead when `note` has words.
    func refuse(_ note: String) async throws {
        try await acting {
            guard let p = try await readPrompt(), let no = p.refusal else { throw fail("Claude's screen has no “No”.") }
            let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                try await press(p.keys(for: no))
                return
            }
            guard p.canAmend else { throw fail("This prompt takes no note. Say no, then write to Claude.") }
            // Tab on "No" opens a field for what to do instead.
            try await press(p.moves(to: no) + ["tab"])
            guard try await waitPrompt(2, until: { $0?.options.contains { $0.label.lowercased().contains("tell claude") } == true }) != nil else {
                throw fail("Claude's screen didn't open the field for your note.")
            }
            try await typeIn(text)
        }
    }

    /// Sends Claude back to its plan with what to change.
    func revisePlan(_ note: String) async throws {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try await acting {
            guard let p = try await readPrompt(), let revise = p.reviseOption else {
                throw fail("Claude's screen has no way to send the plan back.")
            }
            try await press(p.keys(for: revise))
            try await Task.sleep(for: .milliseconds(250))
            try await typeIn(text)
        }
    }

    // MARK: Codex: back to an earlier message

    /// The person's messages, oldest first, as Codex's Esc Esc steps
    /// through them with ← (its `!` commands aren't among them).
    var codexPrompts: [(id: String, text: String)] {
        rows.compactMap { row in
            guard case .item(let item) = row, case .prompt(let text, _) = item.kind else { return nil }
            return (item.id, text)
        }
    }

    /// Esc Esc on an empty field, as in Codex's terminal: Codex browses its
    /// transcript for a message to go back to, and the card lists them.
    func openCodexBacktrack() async {
        try? await acting {
            try await startCodexBrowsing()
        }
    }

    /// Cancel on that card, or Esc: Codex stops browsing, nothing changed.
    func closeCodexBacktrack() async {
        try? await acting {
            try await press(["esc"])
            _ = try await waitCodexBrowsing(false)
        }
    }

    /// Goes back to before the message `id` as Codex does it: Esc Esc,
    /// ← until that message, Enter. Codex takes it and what came after out
    /// of the conversation (files stay as they are) and puts its words back
    /// in its input; they move to the field from there.
    func codexRewind(to id: String) async {
        let prompts = codexPrompts
        guard let at = prompts.firstIndex(where: { $0.id == id }) else { return }
        let back = prompts.count - 1 - at
        let words = said(id)
        var done = false
        try? await acting {
            if !(ClaudeFooter.parseCodex(screen: try await readScreen())?.browsing ?? false) {
                try await startCodexBrowsing()
            }
            // Codex starts on the last message.
            if back > 0 { try await press(Array(repeating: "left", count: back)) }
            try await Task.sleep(for: .milliseconds(200))
            try await press(["enter"])
            let text = words?.text ?? prompts[at].text
            // Done when Codex stops browsing with the message in its input.
            let end = Date().addingTimeInterval(3)
            var restored = false
            while Date() < end {
                try await Task.sleep(for: .milliseconds(150))
                guard let f = ClaudeFooter.parseCodex(screen: try await readScreen()), !f.browsing else { continue }
                restored = Self.codexHolds(f.input ?? f.shown ?? "", text)
                if restored { break }
            }
            guard restored else {
                if ClaudeFooter.parseCodex(screen: try await readScreen())?.browsing == true { try await press(["esc"]) }
                throw fail("Codex didn't go back to that message (one sent while it worked can't be taken back alone).")
            }
            try await emptyCodexInput(text)
            done = true
        }
        guard done else { return }
        _ = rewound(to: id)
        if let words {
            putInField(words.text)
            if words.images > 0 { actionError = "The message's pictures stay behind: attach them again to send them." }
        } else {
            putInField(prompts[at].text)
        }
        recheckSession()
    }

    /// Esc twice on Codex's empty input; Codex then browses its transcript.
    private func startCodexBrowsing() async throws {
        guard record?.status?.state != "working" else { throw fail("Codex is at work: go back once it's done.") }
        guard let shown = ClaudeFooter.parseCodex(screen: try await readScreen()) else {
            throw fail("Codex's input isn't showing: close what's on its screen first.")
        }
        if let typed = shown.input, !typed.isEmpty {
            throw fail("Codex's input holds “\(typed)”, typed in its terminal: send or clear it there first.")
        }
        try await press(["esc"])
        try await Task.sleep(for: .milliseconds(150))
        try await press(["esc"])
        guard try await waitCodexBrowsing(true) else {
            throw fail("Codex didn't open its list of messages: it has none yet, or its input holds text.")
        }
    }

    /// Reads Codex's screen until it browses (or stops), 2 s at most.
    private func waitCodexBrowsing(_ wanted: Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(2)
        while true {
            if let f = ClaudeFooter.parseCodex(screen: try await readScreen()), f.browsing == wanted {
                footer = f
                return true
            }
            if Date() >= end { return false }
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    /// Takes `text` back out of Codex's input: ⌃U and Backspace, line by
    /// line from its end, where Codex leaves the cursor. Never ⌃C, which
    /// quits Codex when the input is empty.
    func emptyCodexInput(_ text: String) async throws {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let rounds = min(200, lines + text.count / 60 + 1)
        for _ in 0 ..< 3 {
            try await press(Array(repeating: ["ctrl+u", "backspace"], count: rounds).flatMap { $0 } + ["ctrl+k", "ctrl+u"])
            try await Task.sleep(for: .milliseconds(250))
            guard let f = ClaudeFooter.parseCodex(screen: try await readScreen()) else { continue }
            if f.input == "" || !Self.codexHolds(f.input ?? f.shown ?? "", text) { return }
        }
        throw fail("Codex kept the message in its input: clear it in the terminal.")
    }

    // MARK: OpenCode

    /// Goes back to before the prompt `id` as OpenCode's /timeline does:
    /// its list of messages, that one, then Revert among its actions. The
    /// message and those after it go out of sight, its file changes are
    /// undone, and its words come back: out of OpenCode's input box, into
    /// the field. `/redo` (the row's Restore) undoes it all.
    func openCodeRewind(to id: String) async {
        let shown = rewindable
        guard let at = shown.firstIndex(where: { $0.id == id }) else { return }
        let words = shown[at].text
        try? await acting {
            guard let footer = parseFooter(try await readScreen()), let box = footer.input else {
                throw fail("OpenCode's input box isn't showing: close what's on its screen first.")
            }
            guard !footer.busy, record?.status?.state != "working" else { throw fail("OpenCode is at work: rewind once it's done.") }
            guard box.isEmpty else { throw fail("OpenCode's input box holds text: send or clear it first.") }
            _ = try await core().call("terminal.send", ["terminal": .string(address), "text": .string("/timeline")], timeout: .seconds(30))
            guard var list = try await openCodeDialog("Timeline") else { throw fail("OpenCode's timeline didn't open.") }
            // The message's first words narrow the list.
            let query = words.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
            let keys = ScreenPrompt.searchKeys(query)
            if !keys.isEmpty {
                try await press(keys)
                list = try await openCodeDialog("Timeline", query: query) ?? list
            }
            let matches = list.options.indices.filter { Rewind.names(list.options[$0].label, words) }
            guard !matches.isEmpty else {
                try await press(["esc"])
                throw fail("OpenCode's timeline doesn't name that message.")
            }
            // Its search sorts by words, not by date: the time beside each
            // row tells messages that read the same apart.
            let sent = sentAt(id).map { Date(timeIntervalSince1970: $0) }
            guard let pick = Rewind.openCodePick(times: matches.map { list.options[$0].detail }, sent: sent) else {
                try await press(["esc"])
                throw fail("Several messages read the same in OpenCode's timeline: rewind in the terminal (/timeline).")
            }
            try await press(Array(repeating: "down", count: matches[pick]) + ["enter"])
            guard let actions = try await openCodeDialog("Message Actions"),
                  let revert = actions.options.firstIndex(where: { $0.label.hasPrefix("Revert") })
            else {
                try await press(["esc"])
                throw fail("OpenCode didn't offer to revert that message.")
            }
            try await press(Array(repeating: "down", count: revert) + ["enter"])
        }
        guard actionError == nil else { return }
        await finishOpenCodeRewind(words)
    }

    /// When the row `id` was written, in seconds since 1970.
    private func sentAt(_ id: String) -> Double? {
        for row in rows {
            if case .item(let item) = row, item.id == id { return item.time }
        }
        return nil
    }

    /// OpenCode's dialog titled `title` once it shows (3 s at most: on
    /// another machine each look at the screen takes a while), with `query`
    /// in its search when given.
    private func openCodeDialog(_ title: String, query: String? = nil) async throws -> ScreenPrompt? {
        let end = Date().addingTimeInterval(3)
        while true {
            if let d = ScreenPrompt.openCodeDialog(screen: try await readScreen(), query: query), d.title == title, !d.options.isEmpty,
               query == nil || d.searchable
            {
                return d
            }
            if Date() >= end { return nil }
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    /// After OpenCode's Revert: the message comes back in its input box.
    /// The field takes it, whole as it was sent; the box is emptied.
    private func finishOpenCodeRewind(_ words: String) async {
        var restored = false
        let end = Date().addingTimeInterval(4)
        while !restored, Date() < end {
            try? await Task.sleep(for: .milliseconds(250))
            guard let screen = try? await readScreen() else { continue }
            restored = parseFooter(screen)?.input?.isEmpty == false
        }
        // OpenCode 1.1 keeps its box empty: the field takes the words all the same.
        if restored {
            try? await acting { try await emptyOpenCodeInput(words) }
            guard actionError == nil else { return }
        }
        guard !words.isEmpty else { return }
        putInField(words)
        revertedWords = words
    }

    /// Takes `text` back out of OpenCode's input box: ⌃U and Backspace,
    /// line by line from its end, where the cursor is. Never ⌃C or ⌃D,
    /// which quit OpenCode.
    private func emptyOpenCodeInput(_ text: String) async throws {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let rounds = min(200, lines + text.count / 60 + 1)
        for _ in 0 ..< 3 {
            try await press(Array(repeating: ["ctrl+u", "backspace"], count: rounds).flatMap { $0 } + ["ctrl+k", "ctrl+u"])
            try await Task.sleep(for: .milliseconds(250))
            if parseFooter(try await readScreen())?.input?.isEmpty == true { return }
        }
        throw fail("OpenCode kept the message in its input box: clear it in the terminal.")
    }

    /// OpenCode's /redo: what its revert took out of sight comes back, file changes too.
    func redoRevert() async {
        do {
            var count = try await revertedCount()
            for _ in 0 ..< 20 {
                try await send("/redo")
                // OpenCode 1.1 brings back one message at a time: /redo
                // again while its screen still counts some out of sight.
                var now = count
                let end = Date().addingTimeInterval(3)
                repeat {
                    try await Task.sleep(for: .milliseconds(300))
                    now = try await revertedCount()
                } while now != nil && now == count && Date() < end
                guard let left = now, left != count else { break }
                count = left
            }
            // The message is back in the conversation: not in the field too.
            if let words = revertedWords { takeOutOfField(words) }
            revertedWords = nil
        } catch {
            actionError = (error as? CoreError)?.message ?? error.localizedDescription
        }
    }

    /// The messages OpenCode's screen says a revert holds out of sight
    /// (`2 messages reverted`), nil when it says none.
    private func revertedCount() async throws -> Int? {
        guard let m = try await readScreen().firstMatch(of: /(\d+) messages? reverted/) else { return nil }
        return Int(m.1)
    }

    // MARK: Gemini

    /// An answer in words to Gemini's question, then Enter, which sends it:
    /// pasted on its `Enter a custom value` line, which a paste fills anew
    /// while the cursor is off it (↑ when on it); else into its field for
    /// words, emptied first.
    func answerGemini(_ text: String, custom: ScreenPrompt.Option?) async throws {
        try await acting {
            if let p = try await readPrompt() { try await readyGeminiWords(p, custom: custom?.number) }
            try await typeIn(text)
        }
    }

    /// Gemini's question ready for words that replace its own: the cursor
    /// off the line for them (↑, which keeps them as the answer), or its
    /// field emptied (End, then ⌫ a letter at a time: it takes no ⌃U).
    private func readyGeminiWords(_ p: ScreenPrompt, custom: Int? = nil) async throws {
        if let n = p.customOption ?? custom {
            if p.options.first(where: \.focused)?.number == n {
                try await press(["up"])
                _ = try await waitPrompt(2, until: { $0?.options.first(where: \.focused)?.number != n })
            }
        } else if p.takesText, !p.typedWords.isEmpty {
            try await press(["end"] + Array(repeating: "backspace", count: p.typedWords.count + 2))
            _ = try await waitPrompt(2, until: { $0?.typedWords.isEmpty == true })
        }
    }

    /// Codex's question answered with `option` and the person's words as its
    /// note: the cursor goes to the option, Tab opens a note under it, then
    /// the words and Enter.
    func answerCodex(_ option: ScreenPrompt.Option, note: String, in shown: ScreenPrompt) async throws {
        try await acting {
            guard try await openCodexNotes(on: option) != nil else {
                throw fail("Codex's question changed: answer it again.")
            }
            try await typeIn(note)
        }
    }

    /// Codex's notes opened on `option`, empty: the cursor moves to it, Tab
    /// opens them. Notes open on another one go first (Tab clears them).
    /// Nil when the option isn't there; false when no notes showed after.
    private func openCodexNotes(on option: ScreenPrompt.Option) async throws -> Bool? {
        let columns = record?.cols ?? 80
        let notes = { (screen: String) in AgentInput.codexNotes(screen: screen, columns: columns) }
        if notes(try await readScreen()) != nil {
            try await press(["tab"])
            _ = try await screenWait(2) { notes($0) == nil }
        }
        guard let now = try await readPrompt(), let target = now.options.first(where: { $0.label == option.label }) else { return nil }
        let moves = target.number - (now.options.first(where: \.focused)?.number ?? 1)
        if moves != 0 { try await pressAndSettle(Array(repeating: moves > 0 ? "down" : "up", count: abs(moves))) }
        try await press(["tab"])
        return try await screenWait(2) { notes($0)?.isEmpty == true }
    }

    /// Reads the screen until `wanted` says yes, for `seconds` at most.
    private func screenWait(_ seconds: Double, until wanted: (String) -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while true {
            if wanted(try await readScreen()) { return true }
            if Date() >= end { return false }
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    /// Gemini's next question (→): the answers ticked go with it. On the
    /// line for one's own words → would move in them: ↑ first.
    func nextGeminiQuestion() async throws {
        try await acting {
            if let p = try await readPrompt(), let n = p.customOption, p.options.first(where: \.focused)?.number == n {
                try await pressAndSettle(["up"])
            }
            try await pressAndSettle(["right"])
        }
    }

    /// Gemini's `Done`, under a question that takes several answers: the
    /// answers ticked go, with the words in the field under the card, put
    /// on its line for one's own words first. Its digit picks it, pressed
    /// off that line (there digits type). Asked alone, the answers are
    /// sent; else the next question shows.
    func doneGemini() async throws {
        try await acting {
            let changed = "Gemini's question changed. Look again, or answer in the terminal."
            guard var p = try await readPrompt(), p.doneNumber != nil else { throw fail(changed) }
            let key = cardWordsKey(p)
            try await putGeminiWords(p)
            p = try await readPrompt() ?? p
            if let n = p.customOption, p.options.first(where: \.focused)?.number == n {
                try await pressAndSettle(["up"])
                p = try await readPrompt() ?? p
            }
            guard let done = p.doneNumber, cardWordsKey(p) == key else { throw fail(changed) }
            try await pressAndSettle(["\(done)"])
            cardWords[key] = nil
            cardWordsRead[key] = nil
        }
    }

    /// Gemini's question, its list scrolling (3 rows at most while Gemini
    /// holds its view to the screen): ⌃O, its `show more lines`, draws the
    /// list whole, so the card shows every answer. The list keeps where its
    /// window started, though: with the cursor down the list, the rows
    /// above stay out of sight until the cursor goes to the first and back
    /// (`geminiTopWalk`). Once while it asks, and only while the pane shows
    /// the conversation: another ⌃O would scroll it again. In the terminal
    /// ⌃O also opens the last turn's tool output, and holds until the next
    /// message. The question as Gemini draws it then; nil when Swiftr
    /// pressed nothing, or Gemini drew something else.
    func showWholeGeminiList(_ p: ScreenPrompt) async -> ScreenPrompt? {
        guard isGemini, p.title == "Answer Questions", p.listScrolls || p.geminiTopWalk != nil,
              !geminiListShown, paneShowsMessages, !acting
        else { return nil }
        geminiListShown = true
        acting = true
        defer { acting = false }
        func shown(_ wanted: (ScreenPrompt) -> Bool) async -> ScreenPrompt? {
            guard let found = try? await waitPrompt(2, until: { $0.map(wanted) ?? false }) else { return nil }
            return found
        }
        var now = p
        if now.listScrolls {
            guard (try? await press(["ctrl+o"])) != nil, let whole = await shown({ !$0.listScrolls }) else { return nil }
            now = whole
        }
        guard let walk = now.geminiTopWalk, let at = now.geminiCursor else { return now }
        guard (try? await press(walk.there)) != nil, await shown({ $0.options.first?.number == 1 }) != nil,
              (try? await press(walk.back)) != nil, let back = await shown({ $0.geminiCursor == at })
        else { return nil }
        return back
    }

    /// Codex's question, its list scrolled in a short pane (`option 3/4`):
    /// the options out of sight come from its call, so the card shows
    /// them all. The call's question is the one whose words the screen
    /// shows, else the one its `Question 1/2` counts.
    func wholeCodexList(_ p: ScreenPrompt) -> ScreenPrompt {
        guard p.listTotal != nil, let call = openCalls.last(where: { $0.name == "AskUserQuestion" }) else { return p }
        let questions = AskQuestion.list(call.input)
        func words(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let shown = words(cardWordsKey(p))
        let counted = p.question.lazy.compactMap(ScreenPrompt.codexQuestionCount).first
        guard let q = questions.first(where: { words($0.question) == shown })
            ?? counted.flatMap({ c in c.total == questions.count && questions.indices.contains(c.index - 1) ? questions[c.index - 1] : nil })
        else { return p }
        return p.wholeList(q.options)
    }

    // MARK: Words under Codex's and Gemini's question cards

    /// The key of a question's words in `cardWords`: its lines, without
    /// Codex's `Question 1/2 (2 unanswered)`, which counts down.
    func cardWordsKey(_ p: ScreenPrompt) -> String {
        p.question.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && ScreenPrompt.codexQuestionCount($0) == nil }
            .joined(separator: "\n")
    }

    /// The option the words under Codex's question card go with, as its
    /// notes: the one they came from in its terminal, else `None of the
    /// above`.
    func noteOption(_ p: ScreenPrompt) -> ScreenPrompt.Option? {
        cardNoteOn[cardWordsKey(p)].flatMap { label in p.options.first { $0.label == label } }
            ?? p.options.last { $0.label.hasPrefix("None of the above") }
    }

    /// The pane shows its terminal: the words in the field under Codex's or
    /// Gemini's question card go onto its screen, unsent, as the person
    /// pastes. Codex's become notes on the option they go with and leave
    /// the card (there, digits would type into them); Gemini's fill its
    /// line for one's own words or its field, and stay in the card: Gemini
    /// keeps them as the answer.
    func pushCardWords() async {
        guard isCodex || isGemini else { return }
        // After the move under way (⇧⌘M twice in a row); switched back
        // meanwhile, they stay.
        for _ in 0 ..< 30 where acting { try? await Task.sleep(for: .milliseconds(100)) }
        guard status?.state == "blocked", !acting, !paneShowsMessages else { return }
        try? await acting {
            guard let p = try await readPrompt() else { return }
            guard isCodex else { return try await putGeminiWords(p) }
            let key = cardWordsKey(p)
            guard let words = cardWords[key], !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let option = noteOption(p), try await openCodexNotes(on: option) == true
            else { return }
            let terminal = try await attachedTerminal(for: "your note")
            terminal.view.send(txt: "\u{1b}[200~" + words + "\u{1b}[201~")
            cardWords[key] = nil
            cardNoteOn[key] = nil
        }
    }

    /// The words under Gemini's question card onto its screen, unsent, as
    /// the person pastes them: on its line for one's own words or into its
    /// field, where a paste fills them anew. Words read there and emptied
    /// in the field leave it too.
    private func putGeminiWords(_ p: ScreenPrompt) async throws {
        guard p.title == "Answer Questions", p.customOption != nil || p.takesText else { return }
        let key = cardWordsKey(p)
        guard let words = cardWords[key], words != p.typedWords else { return }
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard let read = cardWordsRead[key], !read.hint, read.words == p.typedWords else { return }
            try await emptyGeminiWords(p)
            cardWords[key] = nil
            cardWordsRead[key] = nil
            return
        }
        try await readyGeminiWords(p)
        let terminal = try await attachedTerminal(for: "your answer")
        terminal.view.send(txt: "\u{1b}[200~" + words + "\u{1b}[201~")
        // On its screen before the next keys.
        _ = try await waitPrompt(2, until: { $0.map { $0.typedWords != p.typedWords } ?? false })
    }

    /// Takes the words off Gemini's question: out of its field, or off its
    /// line for one's own words, the cursor moved onto it, then up again.
    private func emptyGeminiWords(_ p: ScreenPrompt) async throws {
        guard !p.takesText else { return try await readyGeminiWords(p) }
        guard let n = p.customOption, let own = p.options.first(where: { $0.number == n }) else { return }
        try await press(p.moves(to: own))
        _ = try await waitPrompt(2, until: { $0?.options.first(where: \.focused)?.number == n })
        try await press(["end"] + Array(repeating: "backspace", count: p.typedWords.count + 2) + ["up"])
        _ = try await waitPrompt(2, until: { $0?.typedWords.isEmpty == true })
    }

    /// Codex's notes, open on its question: they move to the field under
    /// its card, with the option they go with when not `None of the
    /// above`. ⌃U and Tab, as the person, clear them there (and end their
    /// draft for the core).
    private func takeCodexNotes(_ screen: String) async throws {
        let columns = record?.cols ?? 80
        guard let p = parsePrompt(screen), let notes = AgentInput.codexNotes(screen: screen, columns: columns) else { return }
        let key = cardWordsKey(p)
        if !notes.isEmpty {
            cardWords[key] = notes.text
            cardNoteOn[key] = p.options.first(where: \.focused).flatMap { $0.label.hasPrefix("None of the above") ? nil : $0.label }
        }
        let terminal = try await attachedTerminal(for: "your note")
        terminal.view.send(txt: "\u{15}\t")
        terminal.draftEnded()
        _ = try await screenWait(2) { AgentInput.codexNotes(screen: $0, columns: columns) == nil }
    }

    /// The pane shows the conversation again: the words on Codex's or
    /// Gemini's question come into the field under its card. Codex's notes
    /// move there (`takeCodexNotes`). Gemini's stay; read with their
    /// colors, as a hint of the question's own (`e.g. notes.txt`) reads like
    /// words. Its other questions' words are read again once the card shows
    /// them: the terminal may have changed them.
    func takeBackCardWords() async {
        guard isCodex || isGemini else { return }
        // After the move under way (⇧⌘M twice in a row); switched back
        // meanwhile, they stay.
        for _ in 0 ..< 30 where acting { try? await Task.sleep(for: .milliseconds(100)) }
        guard status?.state == "blocked", !acting, paneShowsMessages else { return }
        try? await acting {
            let screen = try await readScreen()
            if isCodex { return try await takeCodexNotes(screen) }
            // Its list scrolled again in the terminal is drawn whole once more.
            geminiListShown = false
            guard let p = parsePrompt(screen), p.title == "Answer Questions" else { return }
            let key = cardWordsKey(p)
            cardWords = cardWords.filter { $0.key == key }
            cardWordsRead = [:]
            guard p.customOption != nil || p.takesText else { return }
            let words = p.typedWords
            let hint = words.isEmpty ? false : await isGeminiHint(words)
            cardWordsRead[key] = (words, hint)
            cardWords[key] = words.isEmpty || hint ? nil : words
        }
    }

    /// Gemini's question on the card: the words its screen holds for it,
    /// typed in the terminal or kept from before, come into the field under
    /// the card while the person wrote nothing there. Each read once.
    func readGeminiWords(_ p: ScreenPrompt) async {
        guard paneShowsMessages, !acting, p.title == "Answer Questions", p.customOption != nil || p.takesText else { return }
        let key = cardWordsKey(p)
        let words = p.typedWords
        guard cardWords[key] == nil, !words.isEmpty, cardWordsRead[key]?.words != words else { return }
        cardWordsRead[key] = (words, false)
        let hint = await isGeminiHint(words)
        cardWordsRead[key] = (words, hint)
        guard !hint, !acting, cardWords[key] == nil else { return }
        cardWords[key] = words
    }

    /// Whether `words` on Gemini's question are a hint of its own, drawn in
    /// the color of the keys line under them (`StyledScreen.isGeminiHint`).
    private func isGeminiHint(_ words: String) async -> Bool {
        guard let m = record, let c = connection,
              let styled = await StyledScreen.read(address, connection: c, cols: m.cols, rows: m.rows)
        else { return false }
        return styled.isGeminiHint(words)
    }

    /// Claude's question: its tab bar and the question shown, which the tab
    /// read from the screen's colors goes with.
    static func questionTabKey(_ p: ScreenPrompt) -> String {
        let tabs = p.tabs.map { ($0.answered ? "☒ " : "☐ ") + $0.title }
        let question = p.question.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (tabs + question).joined(separator: "\n")
    }

    /// Claude's question: which tab its screen shows as open, from its
    /// colors (`StyledScreen.shownTab`); once per tab bar and question.
    /// The review is Submit's, and needs no read.
    func readQuestionTab(_ p: ScreenPrompt) async {
        guard paneShowsMessages, !acting, p.tabs.count > 2, !p.isReview else { return }
        let key = Self.questionTabKey(p)
        guard questionTabRead != key else { return }
        questionTabRead = key
        guard let m = record, let c = connection,
              let styled = await StyledScreen.read(address, connection: c, cols: m.cols, rows: m.rows),
              let index = styled.shownTab,
              // The colors are those of this question still.
              let read = parsePrompt(styled.rows.map(\.text).joined(separator: "\n")), Self.questionTabKey(read) == key
        else { return }
        questionTab = (key, index)
    }

    // MARK: Mode

    /// OpenCode: Shift-Tab, its next agent (Build, Plan, the person's).
    func nextAgent() async throws {
        try await acting {
            try await press(["shift+tab"])
            try await Task.sleep(for: .milliseconds(300))
            if let f = ClaudeFooter.parseOpenCode(screen: try await readScreen()) { footer = f }
        }
    }

    /// A key pressed in the agent's own input, as the person would press it
    /// there: Shift-Tab does what the agent binds to it (Claude Code's next
    /// mode, or the person's own binding). The footer is read again after.
    /// `label`: the agent's reply, if it prints one over its input, shows
    /// in a card under that title.
    func pressInInput(_ key: String, label: String? = nil) async throws {
        try await acting {
            let before = try await readScreen()
            try await press([key])
            // The footer changes (mode, effort) a moment after.
            let end = Date().addingTimeInterval(1.5)
            var changed = false
            while Date() < end, !changed {
                try await Task.sleep(for: .milliseconds(150))
                changed = try await readScreen() != before
            }
            guard changed, let label else { return }
            try await Task.sleep(for: .milliseconds(200))
            let after = try await readScreen()
            let reply = switch agent {
            case .codex: CodexScreen.keyReply(before: before, after: after)
            case .claude: ClaudeFooter.keyReply(before: before, after: after)
            case .opencode, .gemini: String?.none
            }
            if let reply { showReply(reply, to: label) }
        }
    }

    /// Presses the agent's mode key until the footer shows `mode`, or
    /// stops at the first press that changes nothing. Gemini: ⌃Y turns
    /// YOLO on and off, `key` goes round the other modes.
    func setMode(_ mode: String, key: String) async throws {
        try await acting {
            var seen: Set<String> = []
            for _ in 0 ..< 7 {
                guard var f = parseFooter(try await readScreen()), let now = f.mode else {
                    throw fail("\(agentName)'s screen doesn't show its mode.")
                }
                if f.effort == nil { f.effort = footer?.effort }
                footer = f
                if now == mode { return }
                guard !seen.contains(now) else { throw fail("This mode isn't one \(agentName) offers in this session.") }
                seen.insert(now)
                let yolo = isGemini && (mode == "bypassPermissions" || now == "bypassPermissions")
                try await press([yolo ? "ctrl+y" : key])
                // Wait for the mode line to change.
                let end = Date().addingTimeInterval(2)
                while Date() < end {
                    try await Task.sleep(for: .milliseconds(150))
                    if let g = parseFooter(try await readScreen()), g.mode != now { break }
                }
            }
            throw fail("Couldn't switch \(agentName) to this mode.")
        }
    }

    // MARK: Claude Code's model picker

    /// One step in Claude Code's model picker, from the picker as it shows
    /// now; its card then shows the picker as the keys left it, in place.
    private func pickerStep(_ body: (ScreenPrompt) async throws -> Void) async {
        guard !acting else { return }
        acting = true
        actionError = nil
        defer {
            acting = false
            rereadScreen()
        }
        do {
            guard let now = try await readPrompt(), now.modelPicker != nil else { throw fail("Claude's model picker isn't open any more.") }
            try await body(now)
            let after = try await readPrompt()
            dialog = after?.modelPicker != nil ? after : nil
        } catch {
            actionError = (error as? ActionError)?.message ?? (error as? CoreError)?.message ?? error.localizedDescription
        }
    }

    /// Brings the picker's cursor to model `number`, or to `More models`
    /// (nil): the arrows its rows call for, then one at a time while it
    /// isn't there (past the window's edge, where the rows can't tell).
    private func movePickerCursor(to number: Int?, in now: ScreenPrompt) async throws {
        func there(_ p: ScreenPrompt?) -> Bool {
            guard let p, let m = p.modelPicker else { return false }
            if let number { return p.options.first(where: \.focused)?.number == number }
            return m.moreFocused
        }
        if there(now) { return }
        if let moves = now.pickerMoves(to: number), !moves.isEmpty {
            try await press(moves)
            if try await waitPrompt(1.5, until: there) != nil { return }
        }
        for _ in 0 ..< 20 {
            guard let p = try await readPrompt(), p.modelPicker != nil else { throw fail("Claude's model picker closed.") }
            if there(p) { return }
            guard let step = p.pickerStep(toward: number) else { break }
            try await pressAndSettle([step])
        }
        throw fail("Claude's cursor didn't reach that model. Look again, or choose in the terminal.")
    }

    /// The picker's cursor on model `number` (its effort then shows), or on `More models` (nil).
    func highlightModel(_ number: Int?) async {
        await pickerStep { now in try await movePickerCursor(to: number, in: now) }
    }

    /// `More models` opened or closed: Enter on it.
    func toggleMoreModels() async {
        await pickerStep { now in
            try await movePickerCursor(to: nil, in: now)
            try await pressAndSettle(["enter"])
        }
    }

    /// → or ←: more or less effort for the model under the picker's cursor.
    func stepModelEffort(up: Bool) async {
        await pickerStep { now in
            guard now.modelPicker?.effort != nil else { throw fail("This model has no effort to change.") }
            try await pressAndSettle([up ? "right" : "left"])
        }
    }

    /// The model under the picker's cursor taken: Enter makes it the default
    /// for new sessions too, `s` takes it for this session only.
    func takeModel(sessionOnly: Bool) async {
        try? await acting {
            guard let now = try await readPrompt(), let m = now.modelPicker, !m.moreFocused,
                  now.options.contains(where: \.focused)
            else { throw fail("No model is under Claude's cursor: pick one first.") }
            try await pressAndSettle([sessionOnly ? "s" : "enter"])
        }
    }
}

/// The keys of the person's Claude Code that do things Swiftr asks for.
nonisolated enum ClaudeKeys {
    /// The key that cycles the permission mode in Claude's input: the one
    /// `keybindings.json` binds to `chat:cycleMode`, else Shift-Tab unless
    /// the file gives it another job.
    static func cycleMode(bindings json: JSON?) -> String? {
        var chat: [String: JSON] = [:]
        for block in json?["bindings"]?.array ?? [] where block["context"]?.string == "Chat" {
            for (key, action) in block["bindings"]?.object ?? [:] { chat[key] = action }
        }
        if let bound = chat.first(where: { $0.value.string == "chat:cycleMode" })?.key { return bound }
        // Shift-Tab given another job, or none.
        return chat["shift+tab"] == nil ? "shift+tab" : nil
    }

    /// From this Mac's `~/.claude/keybindings.json`.
    static func localCycleMode() -> String? {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        let data = try? Data(contentsOf: dir.appending(path: "keybindings.json"))
        return cycleMode(bindings: data.flatMap { try? JSON(data: $0) })
    }
}

/// A send to the core under way, as `typeIn` watches it.
@MainActor private final class SendWatch {
    var done = false
    var error: (any Error)?
}
