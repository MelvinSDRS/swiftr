import Foundation
import HerdrKit

/// One draft, in the Messages field or in the agent's own input (Claude
/// Code's box, Codex's, OpenCode's or Gemini's): when the pane switches,
/// the words follow, so the person goes on writing where they are and
/// neither place holds back the other.
extension TranscriptFeed {
    // MARK: The draft between the field and the agent's input

    /// The pane shows its terminal now: the field's words go into the
    /// agent's input, and what the person chose or typed in a question's
    /// card onto its screen.
    func paneLeft() async {
        await handOffDraft()
        if let open = openQuestion { await pushAnswers(open.questions, call: open.call.id) }
        await pushCardWords()
    }

    /// The pane shows the conversation again: what was typed in the agent's
    /// input comes into the field, and what was answered or typed on its
    /// screen into the question's card.
    func paneShown() async {
        handOffWaiting?.cancel()
        handOffWaiting = nil
        await takeBackDraft()
        if let open = openQuestion { await readAnswers(open.questions, call: open.call.id) }
        await takeBackCardWords()
    }

    /// What the agent's input holds, as `screen` shows it, Claude's dim
    /// suggestion included (`typedInput` tells it apart). Nil when no
    /// input shows (a menu, a question over it).
    func screenInput(_ screen: String) -> InputShown? {
        switch agent {
        case .claude:
            guard let box = ClaudeBox.parse(screen: screen) else { return nil }
            return InputShown(text: box.isEmpty ? "" : box.text, placeholders: box.placeholders, rows: box.rows.count)
        case .codex:
            return AgentInput.codex(screen: screen, columns: record.map(\.cols).flatMap { $0 > 0 ? $0 : nil } ?? 200).map(InputShown.init)
        case .opencode:
            return AgentInput.openCode(screen: screen).map(InputShown.init)
        case .gemini:
            return AgentInput.gemini(screen: screen).map(InputShown.init)
        }
    }

    /// What the person typed in the agent's input: Claude's dim suggestion,
    /// and the note on its waiting messages, are no typing.
    func typedInput(_ screen: String) async -> InputShown? {
        guard agent == .claude else { return screenInput(screen) }
        guard let shown = screenInput(screen), let typed = await boxText(screen) else { return nil }
        if typed.isEmpty || typed.hasPrefix("Press up to edit queued") { return InputShown(text: "", placeholders: [], rows: 1) }
        return shown
    }

    /// Esc (Claude) and ⌃C (Gemini), which empty the input, would stop a
    /// turn: there the words wait for the turn to end. Codex's and
    /// OpenCode's keys for it stop nothing.
    var clearingStopsTurn: Bool { agent == .claude || agent == .gemini }

    /// The agent asks something: its input hides under the question until
    /// it's answered, and the keys that empty it would go to the question
    /// (Claude's Esc and Gemini's ⌃C cancel it). Take It and Clear wait.
    var inputUnderQuestion: Bool { status?.state == "blocked" }

    /// ⇧⌘M again while the words were on their way: that switch found them
    /// moving and let them be. Once they land, they follow to where the pane
    /// shows now. `messages`: the move was for the conversation.
    private func followPane(movedFor messages: Bool) {
        guard paneShowsMessages != messages, let m = record, m.isLive, m.runsChatAgent else { return }
        Task { [weak self] in
            guard let self else { return }
            if self.paneShowsMessages { await self.takeBackDraft() } else { await self.handOffDraft() }
        }
    }

    /// Messages → terminal: the field's words go into the agent's input,
    /// typed as the person would type them, and leave the field once the
    /// input shows them; the agent's cursor goes where the field's was.
    /// Its pictures go first, their files pasted there.
    func handOffDraft() async {
        // Switched back already: the words stay. Asleep, they wait for the wake.
        guard !movingDraft, !paneShowsMessages, !isAsleep else { return }
        let text = fieldDraft
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pictures = fieldPictures
        // A lone `?` opens Claude Code's help instead.
        guard !words.isEmpty || !pictures.isEmpty, !(agent == .claude && words == "?" && pictures.isEmpty),
              let m = record, m.isLive, m.runsChatAgent, !codexBrowsing
        else { return }
        if status?.state == "blocked" {
            handOffWhenAnswered()
            return
        }
        movingDraft = true
        defer {
            movingDraft = false
            followPane(movedFor: false)
        }
        let back = caretBack(in: text)
        // No input (a menu, a question): the words wait in the field.
        guard let screen = try? await readScreen(), let shown = await typedInput(screen),
              let terminal = try? await attachedTerminal(for: "your draft"), fieldDraft == text
        else { return }
        if !pictures.isEmpty {
            guard await handPictures(pictures, then: text, after: shown, into: terminal) else { return }
            moveCaret(back: back, in: terminal)
        } else if ClaudeBox.squeezed(shown.text) != ClaudeBox.squeezed(text) {
            // After what the input holds already, on a line of its own.
            typeAsPerson((shown.isEmpty ? "" : "\n") + text, into: terminal)
            guard await inputShows(text) else { return }
            moveCaret(back: back, in: terminal)
        }
        if fieldDraft == text {
            fieldDraft = ""
            // A place asked for these words, not shown yet, is no more.
            caretAsk = nil
            fieldCaret = nil
        }
        heldInBox = nil
        heldCut = false
    }

    /// Messages → terminal while the agent asks: its input hides under the
    /// question, so the field's words go in once the person answers there
    /// and the input shows again. Back in the conversation, they stay in
    /// the field.
    private func handOffWhenAnswered() {
        handOffWaiting?.cancel()
        handOffWaiting = Task { [weak self] in
            var hidden = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled, !self.paneShowsMessages, self.record?.isLive == true,
                      !self.fieldDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !self.fieldPictures.isEmpty
                else { return }
                if self.status?.state == "blocked" { continue }
                // Answered: the input shows again a moment later.
                guard let screen = try? await self.readScreen(), self.screenInput(screen) != nil else {
                    hidden += 1
                    if hidden > 10 { return }
                    continue
                }
                guard !Task.isCancelled else { return }
                self.handOffWaiting = nil
                await self.handOffDraft()
                return
            }
        }
    }

    /// Into the agent's input, after what it holds on a line of its own:
    /// each picture's file pasted, as the person drops one there, where the
    /// agent shows a mark for it (`[Image #1]`, OpenCode `[Image 1]`, Gemini
    /// `[Image shot.png]`); then `text`, typed. The pictures leave the field
    /// once the input shows them all, kept with their marks for the way
    /// back. True once the input shows `text` too.
    private func handPictures(_ pictures: [PendingImage], then text: String, after shown: InputShown, into terminal: TerminalSession) async -> Bool {
        var paths: [String] = []
        for picture in pictures {
            guard let path = try? await attach(picture.data, name: picture.name) else {
                actionError = "Swiftr couldn't put \(picture.name) beside \(agentName)'s terminal: your draft stays here."
                return false
            }
            paths.append(path)
        }
        // Changed meanwhile: it stays.
        guard fieldDraft == text, fieldPictures.map(\.id) == pictures.map(\.id) else { return false }
        let before = Self.imageMarks(in: shown.text).count
        if !shown.isEmpty { typeAsPerson("\n", into: terminal) }
        // Claude alone puts no space after a mark.
        let space = agent == .claude ? " " : ""
        var handed: [HandedPicture] = []
        for (i, path) in paths.enumerated() {
            if i > 0 { terminal.view.send(txt: space) }
            terminal.view.send(txt: "\u{1b}[200~" + path + "\u{1b}[201~")
            // The agent reads the file, then shows its mark where the cursor was.
            guard let mark = await newMark(count: before + i + 1) else {
                actionError = "\(agentName) didn't take \(pictures[i].name) as a picture: your draft stays here."
                return false
            }
            handed.append(HandedPicture(mark: mark, picture: pictures[i]))
        }
        handedPictures += handed
        fieldPictures.removeAll { picture in pictures.contains { $0.id == picture.id } }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        typeAsPerson((text.first?.isWhitespace == true ? "" : space) + text, into: terminal)
        return await inputShows(text)
    }

    /// The last picture mark in the agent's input once it shows `count` of
    /// them, within 8 s.
    private func newMark(count: Int) async -> String? {
        let end = Date().addingTimeInterval(8)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(150))
            guard let screen = try? await readScreen(), let input = screenInput(screen) else { continue }
            let marks = Self.imageMarks(in: input.text)
            if marks.count >= count { return marks.last }
        }
        return nil
    }

    /// The agents' marks for pictures in `text`: `[Image #1]`, `[Image 1]`,
    /// `[Image shot.png]`.
    nonisolated static func imageMarks(in text: String) -> [String] {
        ClaudeBox.placeholders(in: text).filter { $0.hasPrefix("[Image ") }
    }

    /// Whether the marks in the agent's input, `text`, are those of the
    /// pictures the field handed it, each one and no other: then the
    /// pictures can come back with the words.
    func holdsHandedPictures(_ text: String) -> Bool {
        !handedPictures.isEmpty && ClaudeBox.placeholders(in: text) == handedPictures.map(\.mark)
    }

    /// `text` without the marks of the pictures handed, nor the space after each.
    private func withoutHandedPictures(_ text: String) -> String {
        var out = text
        for mark in handedPictures.map(\.mark) {
            if let r = out.range(of: mark + " ") ?? out.range(of: mark) { out.removeSubrange(r) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Terminal → Messages: the words typed in the agent's input move to
    /// the field, its cursor where the agent's was, and the input empties.
    /// Claude's come exactly as typed (its prompt history has them); the
    /// others' as their rows read, joined where they wrapped. Pastes and
    /// pictures shown as `[Pasted text #1]` stay in the agent, which alone
    /// has them, and so does a draft taller than Gemini's box: the field
    /// says so, and they go first with the next message. The pictures the
    /// field handed the agent come back with the words, while its input
    /// shows them all and no other mark. Where emptying the input would
    /// stop a turn (Claude, Gemini), the words move once it ends; under a
    /// question, once it's answered.
    func takeBackDraft() async {
        // Switched back already: the words stay.
        guard !movingDraft, paneShowsMessages, let m = record, m.isLive, m.runsChatAgent else { return }
        if status?.state == "blocked" {
            takeBackWhenIdle = true
            return
        }
        movingDraft = true
        defer {
            movingDraft = false
            rereadScreen()
            followPane(movedFor: true)
        }
        guard let screen = try? await readScreen(), let shown = await typedInput(screen) else {
            heldInBox = nil
            heldCut = false
            return
        }
        guard !shown.isEmpty else {
            heldInBox = nil
            heldCut = false
            // Sent or emptied in the terminal: the pictures went with it.
            handedPictures = []
            return
        }
        heldInBox = shown.text
        heldCut = shown.cut
        if clearingStopsTurn, status?.state == "working" {
            takeBackWhenIdle = true
            return
        }
        let pictures = holdsHandedPictures(shown.text) ? handedPictures.map(\.picture) : []
        guard shown.placeholders.isEmpty || !pictures.isEmpty, !shown.cut,
              let terminal = try? await attachedTerminal(for: "your draft")
        else { return }
        // Before the input empties: the field's cursor goes there too. The
        // pictures' marks come first, and the place counts from the end.
        let caret = await inputCaret()
        let taken: String
        if agent == .claude {
            guard let box = ClaudeBox.parse(screen: screen), let words = await takeClaudeBox(box, terminal) else { return }
            taken = pictures.isEmpty ? words : withoutHandedPictures(words)
        } else {
            guard await clearInput(terminal, rows: shown.rows) else { return }
            taken = pictures.isEmpty ? shown.text : withoutHandedPictures(shown.text)
        }
        heldInBox = nil
        heldCut = false
        // A message Claude Code gave back in its terminal (Esc before any
        // answer): it left the conversation there, and leaves it here.
        if agent == .claude, status?.state != "working", let last = unansweredPrompts.last,
           ClaudeBox.squeezed(taken) == ClaudeBox.squeezed(last.text)
        {
            _ = rewound(to: last.id)
        }
        // Pictures the box held no more, taken out there, stay out.
        handedPictures = []
        if !pictures.isEmpty {
            fieldPictures = pictures + fieldPictures.filter { picture in !pictures.contains { $0.id == picture.id } }
        }
        let now = fieldDraft
        if now.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldDraft = taken
            placeCaret(caret, in: taken, after: "")
        } else if !taken.isEmpty, ClaudeBox.squeezed(now) != ClaudeBox.squeezed(taken) {
            fieldDraft = now + "\n\n" + taken
            placeCaret(caret, in: taken, after: now + "\n\n")
        }
    }

    /// Claude's box emptied with Esc Esc: the words it held. Claude Code
    /// keeps them in its prompt history (↑ brings them back): exactly as
    /// typed, where the screen wraps them and may show only the last lines.
    /// Nil when the box kept them.
    private func takeClaudeBox(_ box: ClaudeBox, _ terminal: TerminalSession) async -> String? {
        let since = Date()
        guard await clearBox(terminal, holding: box.text) else { return nil }
        var words = await clearedDraft(matching: box.text, since: since)
        if words == nil, box.rows.count >= 8 {
            // Maybe more than the screen showed: back in the box, whole (↑).
            terminal.view.send(txt: "\u{1b}[A")
            terminal.draftEnded()
            try? await Task.sleep(for: .milliseconds(300))
            if let back = ClaudeBox.parse(screen: (try? await readScreen()) ?? ""), !back.isEmpty {
                heldInBox = back.text
                return nil
            }
            words = box.text
            actionError = "Claude's input box held a long draft: if its first lines are missing here, ↑ in its terminal brings all of it back."
        }
        return words ?? box.text
    }

    /// The screen was read, the agent's input shown holding `typed` (""
    /// for nothing, or Claude's dim suggestion): what the field couldn't
    /// take shows over it, and moves into it once the agent's turn ends.
    func boxRead(_ typed: String, screen: String, status: String?) {
        guard !movingDraft, typingMessages == 0 else { return }
        let words = typed.hasPrefix("Press up to edit queued") ? "" : typed
        let shown = words.isEmpty ? nil : screenInput(screen)
        let held = words.isEmpty ? nil : shown.flatMap { $0.isEmpty ? nil : $0.text } ?? words
        if held != heldInBox { heldInBox = held }
        let cut = held != nil && shown?.cut == true
        if cut != heldCut { heldCut = cut }
        if held == nil {
            takeBackWhenIdle = false
            // Sent or emptied in the terminal: the pictures went with it.
            if !handedPictures.isEmpty { handedPictures = [] }
        }
        if takeBackWhenIdle, held != nil, status != "blocked", !(clearingStopsTurn && status == "working"), paneShowsMessages {
            takeBackWhenIdle = false
            Task { await takeBackDraft() }
        }
    }

    /// What the field shows over it as held in the agent's input, cleared:
    /// Esc Esc in Claude's box, as in its terminal (↑ there brings it back);
    /// the others' own keys for it.
    func clearHeldBox() async {
        guard !movingDraft, let held = heldInBox, !(clearingStopsTurn && status?.state == "working"), !inputUnderQuestion else { return }
        movingDraft = true
        defer {
            movingDraft = false
            rereadScreen()
            followPane(movedFor: true)
        }
        guard let terminal = try? await attachedTerminal(for: "your draft") else { return }
        if agent == .claude {
            if await clearBox(terminal, holding: held) {
                heldInBox = nil
                handedPictures = []
            }
            return
        }
        let rows = (try? await readScreen()).flatMap(screenInput)?.rows ?? 1
        if await clearInput(terminal, rows: max(rows, held.components(separatedBy: "\n").count)) {
            heldInBox = nil
            heldCut = false
            handedPictures = []
        }
    }

    /// Before a message: Claude's own menu over its box closes, as Esc
    /// closes it; and once the person typed in the terminal, ⌃U in the
    /// empty input ends the draft the core would hold the message back for
    /// (no agent does anything with it there). What the input holds from
    /// the terminal, "" when nothing: the message then goes after it.
    func inputForMessage() async throws -> String {
        var screen = try await readScreen()
        if agent == .claude, ClaudeFooter.parse(screen: screen) == nil, dialog != nil || ScreenPrompt.parse(screen: screen).map(Self.isMenu) == true {
            await escape()
            let end = Date().addingTimeInterval(2)
            repeat {
                try await Task.sleep(for: .milliseconds(150))
                screen = try await readScreen()
            } while ClaudeFooter.parse(screen: screen) == nil && Date() < end
        }
        guard let shown = await typedInput(screen) else { return "" }
        if shown.isEmpty {
            if let terminal = terminalSession, terminal.isAttached, let at = terminal.lastTyped, Date().timeIntervalSince(at) < 65 {
                terminal.view.send(txt: "\u{15}")
                terminal.draftEnded()
            }
            return ""
        }
        return shown.text
    }

    /// The message after what Claude's box holds from its terminal, on a
    /// line of its own, then Enter: one message, as when both are typed
    /// there (queued while Claude works). Typed as the person: the core
    /// would hold a send back for their draft. `text` starts with the
    /// pictures' paths, which Claude takes as images.
    func sendAfterBox(_ text: String, pictures: [String]) async throws {
        let terminal = try await attachedTerminal(for: "the message")
        heldInBox = nil
        // What the box holds goes with the message, the pictures handed too.
        handedPictures = []
        let before = ClaudeBox.parse(screen: try await readScreen())?.text ?? ""
        let images = before.matches(of: /\[Image #\d+\]/).count
        let pastes = before.matches(of: /\[Pasted text #\d+/).count
        terminal.view.send(txt: "\n")
        terminal.view.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        // Enter once the box shows it, its pictures read.
        let tail = String(ClaudeBox.squeezed(text).suffix(40))
        let end = Date().addingTimeInterval(pictures.isEmpty ? 3 : 12)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(150))
            guard let box = ClaudeBox.parse(screen: try await readScreen()) else { break }
            let shows = ClaudeBox.squeezed(box.text).hasSuffix(tail) || box.text.matches(of: /\[Pasted text #\d+/).count > pastes
            if shows, box.text.matches(of: /\[Image #\d+\]/).count >= images + pictures.count { break }
        }
        terminal.view.send(txt: "\r")
        terminal.draftEnded()
        let gone = Date().addingTimeInterval(4)
        while Date() < gone {
            try await Task.sleep(for: .milliseconds(250))
            // A question or a menu in its place: it went.
            guard let box = await boxText(try await readScreen()) else { return }
            if box.isEmpty || box.hasPrefix("Press up to edit queued") { return }
        }
        throw CoreError(kind: "kept", message: "Claude keeps the message in its input box: press Return in its terminal, or clear it there.")
    }

    /// Codex, OpenCode or Gemini: the message after what its input holds
    /// from its terminal, on a line of its own, then Enter (Tab for Codex
    /// at work when Enter leaves it there, as `queueIfLeft`): one message,
    /// as when both are typed there. Typed as the person, as for Claude.
    func sendAfterInput(_ text: String, working: Bool) async throws {
        let terminal = try await attachedTerminal(for: "the message")
        heldInBox = nil
        heldCut = false
        // What the input holds goes with the message, the pictures handed too.
        handedPictures = []
        typeAsPerson("\n" + text, into: terminal)
        _ = await inputShows(text)
        terminal.view.send(txt: "\r")
        terminal.draftEnded()
        var tabbed = false
        let gone = Date().addingTimeInterval(4)
        while Date() < gone {
            try await Task.sleep(for: .milliseconds(250))
            // A question or a menu in its place: it went.
            guard let shown = screenInput(try await readScreen()) else { return }
            if shown.isEmpty { return }
            if isCodex, working, !tabbed {
                tabbed = true
                terminal.view.send(txt: "\t")
            }
        }
        throw CoreError(kind: "kept", message: "\(agentName) keeps the message in its input: press Return in its terminal, or clear it there.")
    }

    /// Types `text` into the agent's input as the person would: each line
    /// pasted, in parts small enough that the agent shows them as text, not
    /// as a mark (Claude Code folds a paste over 800 characters into
    /// `[Pasted text #n]`, Codex over 1000, Gemini over 500 or 5 lines),
    /// a new line (⌃J) between lines. OpenCode folds a paste of 3 lines or
    /// over 150 characters and drops a ⌃J that follows a paste at once:
    /// there each line's break goes inside its last part.
    func typeAsPerson(_ text: String, into terminal: TerminalSession) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let size = switch agent {
        case .claude, .codex: 600
        case .gemini: 400
        case .opencode: 140
        }
        for (i, line) in lines.enumerated() {
            var parts: [Substring] = []
            var rest = Substring(line)
            while !rest.isEmpty {
                parts.append(rest.prefix(size))
                rest = rest.dropFirst(size)
            }
            if isOpenCode {
                let last = i == lines.count - 1
                if parts.isEmpty, !last { parts = [""] }
                for (k, part) in parts.enumerated() {
                    terminal.view.send(txt: "\u{1b}[200~" + part + (k == parts.count - 1 && !last ? "\n" : "") + "\u{1b}[201~")
                }
                continue
            }
            if i > 0 { terminal.view.send(txt: "\n") }
            for part in parts {
                terminal.view.send(txt: "\u{1b}[200~" + part + "\u{1b}[201~")
            }
        }
    }

    // MARK: The cursor with the draft

    /// How far the field's cursor is from the end of `text`, in the steps
    /// ← takes in the agent's input: characters, code points in Gemini's.
    /// 0 when the field told no place for this text.
    private func caretBack(in text: String) -> Int {
        guard let caret = fieldCaret, caret.length == text.utf16.count, caret.offset < caret.length else { return 0 }
        let tail = String(decoding: Array(text.utf16.dropFirst(caret.offset)), as: UTF16.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        return agent == .gemini ? tail.unicodeScalars.count : tail.count
    }

    /// ← `back` times in the agent's input, as the person presses it, once
    /// the draft typed there shows: its cursor goes where the field's was.
    private func moveCaret(back: Int, in terminal: TerminalSession) {
        guard back > 0 else { return }
        terminal.view.send(txt: String(repeating: "\u{1b}[D", count: min(back, 5000)))
    }

    /// Where the cursor is in the agent's input: its screen read with
    /// colors has the cursor, then its input is read with a mark there
    /// (`DraftCaret`). Nil when it isn't in the input.
    private func inputCaret() async -> DraftCaret.Place? {
        guard let m = record, let c = connection,
              let styled = await StyledScreen.read(address, connection: c, cols: m.cols, rows: m.rows),
              styled.rows.indices.contains(styled.cursor.y)
        else { return nil }
        // Each character's own columns, as the screen drew it. Gemini draws
        // its cursor as a reversed cell; the terminal's cursor it puts
        // there slips after an emoji (it counts the text in UTF-16 units).
        let y = styled.cursor.y
        let row = styled.rows[y]
        let reversed = agent == .gemini ? row.inverse.firstIndex(of: true) : nil
        let index = reversed ?? row.index(ofColumn: styled.cursor.x)
        guard let (screen, under) = DraftCaret.marked(styled.rows.map(\.text), at: index, row: y),
              let shown = screenInput(screen)
        else { return nil }
        return DraftCaret.place(in: shown.text, under: under)
    }

    /// The field's cursor where the agent's was, in `taken`, which follows
    /// `before` in the field; at the end, the field puts it there itself.
    /// It counts as the field's at once: switched back before the field
    /// shows it, the draft takes it to the agent's input again.
    private func placeCaret(_ place: DraftCaret.Place?, in taken: String, after before: String) {
        let text = before + taken
        let length = text.utf16.count
        guard let place, let n = DraftCaret.offset(of: place, in: taken), n < taken.count else {
            caretAsk = nil
            fieldCaret = (length, length)
            return
        }
        let at = text.index(text.startIndex, offsetBy: min(before.count + n, text.count)).utf16Offset(in: text)
        caretTick += 1
        caretAsk = CaretAsk(offset: at, text: text, tick: caretTick)
        fieldCaret = (at, length)
    }

    /// Whether the agent's input ends with `text` within 2 s: a long draft
    /// shows only its last lines there.
    private func inputShows(_ text: String) async -> Bool {
        let tail = String(ClaudeBox.squeezed(text).suffix(60))
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(120))
            guard let screen = try? await readScreen(), let shown = screenInput(screen) else { continue }
            if ClaudeBox.squeezed(shown.text).hasSuffix(tail) { return true }
        }
        return false
    }

    /// Empties Codex's, OpenCode's or Gemini's input as the person would,
    /// with keys that stop no turn and never quit: ⌃K ⌃U in Codex (two
    /// rounds a row: each line, then its break), ⇧Home ⌫ ⇧End ⌫ in OpenCode,
    /// ⌃C in Gemini, once (a second on an empty input would quit it); ⌃C
    /// quits Codex and OpenCode. Then ⌃U, which ends the core's wait on
    /// the person's draft. True once the input shows empty.
    private func clearInput(_ terminal: TerminalSession, rows: Int) async -> Bool {
        switch agent {
        case .codex: terminal.view.send(txt: String(repeating: "\u{0b}\u{15}", count: 2 * rows + 2))
        case .opencode: terminal.view.send(txt: "\u{1b}[1;2H\u{7f}\u{1b}[1;2F\u{7f}")
        case .gemini: terminal.view.send(txt: "\u{03}")
        case .claude: return false
        }
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(150))
            guard let screen = try? await readScreen(), let shown = screenInput(screen) else { continue }
            if shown.isEmpty {
                terminal.view.send(txt: "\u{15}")
                terminal.draftEnded()
                return true
            }
        }
        return false
    }

    /// Esc twice in Claude's box as the person, once more while a list over
    /// it (`/` commands, `@` files) takes the first; then ⌃U, which ends
    /// the core's wait on their draft. True once the box shows `shown` no more.
    private func clearBox(_ terminal: TerminalSession, holding shown: String) async -> Bool {
        terminal.view.send(txt: "\u{1b}")
        try? await Task.sleep(for: .milliseconds(150))
        terminal.view.send(txt: "\u{1b}")
        var cleared = false
        for round in 0 ..< 4 {
            try? await Task.sleep(for: .milliseconds(round == 0 ? 250 : 200))
            guard let screen = try? await readScreen() else { continue }
            if let box = ClaudeBox.parse(screen: screen) {
                // Empty, or its dim suggestion back in it.
                if box.isEmpty || ClaudeBox.squeezed(box.text) != ClaudeBox.squeezed(shown), await boxText(screen)?.isEmpty == true {
                    cleared = true
                    break
                }
            } else if ScreenPrompt.parse(screen: screen)?.isRewindList == true {
                // One Esc too many on the empty box opened its rewind list.
                terminal.view.send(txt: "\u{1b}")
                cleared = true
                break
            }
            terminal.view.send(txt: "\u{1b}")
        }
        if cleared {
            terminal.view.send(txt: "\u{15}")
            terminal.draftEnded()
        }
        return cleared
    }

    /// The words Claude Code wrote to its prompt history when its box was
    /// emptied (since `since`) and that end as the box showed them: exactly
    /// as typed. It doesn't write the same words twice in a row: then its
    /// last line of this session is them. Nil when it wrote none.
    private func clearedDraft(matching shown: String, since: Date) async -> String? {
        guard let s = session else { return nil }
        let want = ClaudeBox.squeezed(shown)
        let from = Int64((since.timeIntervalSince1970 - 5) * 1000)
        let end = Date().addingTimeInterval(s.machine == nil ? 1.2 : 2.5)
        var last: String?
        while true {
            if let lines = await historyLines(s) {
                let matching = lines.last.flatMap { ClaudeBox.squeezed($0.text).hasSuffix(want) ? $0 : nil }
                if let matching, matching.timestamp >= from { return matching.text }
                last = matching?.text
            }
            if Date() >= end { return last }
            try? await Task.sleep(for: .milliseconds(s.machine == nil ? 80 : 400))
        }
    }

    /// This session's last lines in Claude Code's prompt history, oldest
    /// first, beside its sessions (`<config>/history.jsonl`).
    private func historyLines(_ s: ClaudeSession) async -> [(text: String, timestamp: Int64)]? {
        var config = URL(filePath: s.path)
        for _ in 0 ..< 3 { config.deleteLastPathComponent() }
        if let machine = s.machine {
            guard let c = connection,
                  let r = try? await c.call("machine.exec", ["on": .string(machine), "line": .string(PromptHistory.remoteSessionLine(config: config.path, id: s.id, tailBytes: 1 << 20)), "timeout": 10], timeout: .seconds(15)),
                  let out = r["stdout"]?.string.flatMap({ Data(base64Encoded: $0) })
            else { return nil }
            return PromptHistory.session(out, id: s.id)
        }
        let path = config.appending(path: "history.jsonl").path
        let id = s.id
        return await Task.detached(priority: .userInitiated) { () -> [(text: String, timestamp: Int64)]? in
            guard let h = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            let from = size > 1 << 20 ? size - (1 << 20) : 0
            try? h.seek(toOffset: from)
            var data = (try? h.readToEnd()) ?? Data()
            if from > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
            return PromptHistory.session(Data(data), id: id)
        }.value
    }

    // MARK: Keys for the agent's own menus

    /// Esc Esc in the empty field: Claude's (or Gemini's) list of messages
    /// to go back to. Keys pressed before it shows wait for it.
    func openRewindList() async {
        menuOpening = true
        defer { menuOpening = false }
        if isGemini {
            try? await press(["esc", "esc"])
        } else {
            await rewind(to: nil)
        }
        guard actionError == nil else { return }
        // Its card comes with the next look at the screen.
        rereadScreen()
        for _ in 0 ..< 20 where dialog == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A key for the menu the agent shows over its input, from the field
    /// (↑ ↓ ↩ Esc, a digit), as in its terminal: pressed after those before
    /// it, and the menu's card follows its cursor.
    func menuKey(_ key: String) {
        // `/effort`, `/model`, `/resume`: their card takes the key.
        if menus.kind != nil, menus.key(key) { return }
        menuKeys.append(key)
        guard !menuDraining else { return }
        menuDraining = true
        Task {
            await drainMenuKeys()
            menuDraining = false
        }
    }

    private func drainMenuKeys() async {
        var waited = 0
        while !menuKeys.isEmpty {
            // The list opening (Esc Esc), or a choice under way, first.
            if acting || menuOpening {
                waited += 1
                if waited > 100 {
                    menuKeys = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let key = menuKeys.removeFirst()
            switch key {
            case "up", "down":
                var keys = [key]
                while let next = menuKeys.first, next == "up" || next == "down" { keys.append(menuKeys.removeFirst()) }
                await moveInMenu(keys)
            case "enter":
                await chooseInMenu(number: nil)
            case "esc":
                await escape()
            default:
                if let n = Int(key) { await chooseInMenu(number: n) }
            }
        }
    }

    /// Arrows in the menu; its card then shows where the cursor went.
    private func moveInMenu(_ keys: [String]) async {
        guard let before = try? await readScreen() else { return }
        do {
            try await press(keys)
        } catch {
            actionError = (error as? CoreError)?.message ?? error.localizedDescription
            return
        }
        var screen = before
        let end = Date().addingTimeInterval(1)
        while Date() < end, screen == before {
            try? await Task.sleep(for: .milliseconds(50))
            screen = (try? await readScreen()) ?? before
        }
        let menu = parsePrompt(screen)
        if let menu, menu.options.count >= 2 { dialog = menu }
        rereadScreen()
    }

    /// ↩ (nil: the option under the cursor) or a digit in the menu, as the
    /// menu's card would choose it.
    private func chooseInMenu(number: Int?) async {
        guard let screen = try? await readScreen() else { return }
        if agent == .claude, ScreenPrompt.parse(screen: screen)?.modelPicker != nil {
            if number == nil { await takeModel(sessionOnly: false) }
            return
        }
        guard let menu = parsePrompt(screen) else {
            if number == nil {
                try? await press(["enter"])
                rereadScreen()
            }
            return
        }
        let option: ScreenPrompt.Option?
        if let number {
            option = menu.numbered ? menu.options.first { $0.number == number } : nil
        } else {
            option = menu.options.first(where: \.focused)
        }
        if let option {
            await choose(option, in: menu)
        } else if number == nil {
            try? await press(["enter"])
            rereadScreen()
        }
    }
}

/// A picture the field handed to Claude's box, and the mark the box
/// shows for it (`[Image #2]`).
struct HandedPicture: Equatable {
    let mark: String
    let picture: PendingImage
}

/// What an agent's input holds, as its screen shows it.
struct InputShown: Equatable {
    /// The words, its rows joined where the agent wrapped them; "" for none.
    var text: String
    /// Marks for what only the agent has (`[Pasted text #1]`, `[Image #2]`).
    var placeholders: [String]
    /// Its rows on the screen.
    var rows: Int
    /// The input shows only some of its rows (Gemini's last 10).
    var cut = false

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension InputShown {
    init(_ input: AgentInput) {
        self.init(text: input.isEmpty ? "" : input.text, placeholders: input.placeholders, rows: input.rows.count, cut: input.cut)
    }
}

/// A place for the Messages field's cursor: `offset` (UTF-16) once the
/// field holds `text`; `tick` tells one ask from the next.
struct CaretAsk: Equatable {
    var offset: Int
    var text: String
    var tick: Int
}
