import HerdrKit
import SwiftUI
import UniformTypeIdentifiers

/// A Claude, Codex or OpenCode pane shown as a conversation: the transcript, a field
/// to write to the agent, and buttons for what it asks.
struct MessagesPane: View {
    @Environment(AppModel.self) private var model
    /// Settings › Show diffs expanded.
    @AppStorage("messagesExpandDiffs") private var expandsDiffs = false
    let address: String
    let paneID: String
    let context: PaneContext
    let feed: TranscriptFeed

    var body: some View {
        let record = model.store.model(address)
        let status = feed.status
        let size = model.prefs.fontSize
        let folder = record?.currentFolder ?? ""
        MessageList(feed: feed, status: status, size: size, folder: folder)
            // The conversation runs on under what Claude asks and the field,
            // which float on it as glass.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                PaneBottom(feed: feed, address: address, paneID: paneID, context: context, status: status, size: size, folder: folder)
            }
            .background(Color(nsColor: model.prefs.theme.backgroundColor))
            .environment(\.colorScheme, model.prefs.theme.isDark ? .dark : .light)
            .environment(\.themeAccent, model.prefs.theme.accentColor.map { Color(nsColor: $0) })
            .environment(\.codeFamily, model.prefs.fontName)
            .environment(\.agentName, feed.agentName)
            .environment(\.reusePrompt, RowAction(key: address) { text in
                // Back in the field, to change and send again; what it quoted over it again.
                if let quoted = QuotedPrompt(parsing: text) {
                    model.drafts[address] = quoted.request.isEmpty ? nil : quoted.request
                    model.draftQuotes[address] = quoted.quotes
                } else {
                    model.drafts[address] = text
                }
                model.requestFocus()
            })
            .environment(\.rewindPrompt, rewindAction)
            .environment(\.redoRevert, feed.isOpenCode ? RowAction(key: "\(ObjectIdentifier(feed))") { [feed] _ in Task { await feed.redoRevert() } } : nil)
            .environment(\.unrewindable, feed.summarized)
            .environment(\.expandsDiffs, expandsDiffs)
            .environment(\.linksPaths, record?.machine == nil)
    }
}

/// What sits under the conversation: what the agent asks, notes, the
/// to-do list, the field and the status bar.
private struct PaneBottom: View {
    @Environment(AppModel.self) private var model
    let feed: TranscriptFeed
    let address: String
    let paneID: String
    let context: PaneContext
    let status: AgentStatus?
    let size: Double
    let folder: String

    var body: some View {
        let working = status?.state == "working"
        let todos = feed.todos
        VStack(spacing: 0) {
            AskCard(feed: feed, status: status, size: size, folder: folder, focusedPane: context.focused == paneID) {
                model.setPaneMode(.terminal, for: address)
            }
            if feed.codexBrowsing, status?.state != "blocked" {
                CodexRewindCard(feed: feed, size: size, focusedPane: context.focused == paneID) {
                    model.setPaneMode(.terminal, for: address)
                }
            }
            if feed.commandOutput != nil, status?.state != "blocked", feed.dialog == nil {
                CommandOutputCard(feed: feed, size: size) {
                    model.setPaneMode(.terminal, for: address)
                }
            }
            if feed.actionError != nil, !feed.acting, status?.state != "blocked", feed.dialog == nil {
                ActionNote(feed: feed, size: size)
            }
            if !todos.isEmpty, working || todos.contains(where: { $0.status != .completed }) {
                TodoStrip(todos: todos, size: size, open: Binding(get: { feed.todosOpen }, set: { feed.todosOpen = $0 }))
            }
            Composer(feed: feed, address: address, paneID: paneID, context: context, status: status, size: size, folder: folder)
            StatusBar(feed: feed, status: status, size: size)
        }
        // As wide as the conversation's column.
        .frame(maxWidth: ChatStyle.column(size) + 32)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.25), value: status?.state)
        // A menu's card shows from its command on: Claude's menu fills it in place.
        .animation(.snappy(duration: 0.25), value: feed.dialog != nil && feed.menus.kind == nil)
        .animation(.snappy(duration: 0.25), value: feed.menus.kind)
        .animation(.snappy(duration: 0.25), value: feed.commandOutput != nil)
        .animation(.snappy(duration: 0.25), value: feed.actionError)
    }
}

extension MessagesPane {
    /// A message's Rewind: Claude Code's /rewind list, Gemini's or Codex's
    /// Esc Esc, OpenCode's /timeline, taken to that message.
    var rewindAction: RowAction? {
        let key = "\(ObjectIdentifier(feed))"
        switch feed.agent {
        case .claude, .gemini: return RowAction(key: key) { [feed] id in Task { await feed.rewind(to: id) } }
        case .codex: return RowAction(key: key) { [feed] id in Task { await feed.codexRewind(to: id) } }
        case .opencode: return RowAction(key: key) { [feed] id in Task { await feed.openCodeRewind(to: id) } }
        }
    }
}

/// The conversation, following its end unless the person scrolled up.
private struct MessageList: View {
    @Environment(AppModel.self) private var model
    let feed: TranscriptFeed
    let status: AgentStatus?
    let size: Double
    let folder: String
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    /// How many of the last rows are drawn; older ones come in as the top nears.
    @State private var limit = MessageList.page
    /// Older rows are coming in front: what is read stays in place while
    /// they push the top up (`HoldsPlace`).
    @State private var prepending = false
    /// Less than a screen of rows left above what is shown.
    @State private var nearTop = false
    /// Find (⌘F): the words, the rows that hold them, the one shown.
    @State private var finding = false
    @State private var query = ""
    @State private var matches: [String] = []
    @State private var matchIndex = 0
    /// A row just brought into view from elsewhere (the background list), marked a moment.
    @State private var flashed: String?
    /// A quoted passage just brought into view, marked a moment where it came from.
    @State private var marked: PassageMark.Target?
    /// The pane's width: wide tables take the room beside the column.
    @State private var width: CGFloat = 0
    /// Find's field has the keyboard.
    @FocusState private var findFocused: Bool
    /// Words selected in the conversation, and the button that quotes them.
    @State private var quoteOffer = QuoteOffer()
    /// The rows last folded into turns (`TurnPieces`).
    @State private var turns = TurnPieces()
    /// Counts the returns to the end: only the last one's wait shortens the list.
    @State private var trims = 0
    /// Counts the list's moves: a count that stays tells it rests.
    @State private var rest = Rest()

    /// Rows drawn at once. A plain VStack measures every row, so the end of
    /// the conversation is where it says; a lazy one guesses the heights of
    /// rows not drawn yet, and misses the end when the list changes size.
    static let page = 120

    private var working: Bool { status?.state == "working" }
    private var shownRows: ArraySlice<TranscriptRow> { feed.rows.suffix(limit) }

    var body: some View {
        found
            .onChange(of: query) { search(fromEnd: true) }
            .onChange(of: feed.rows.count) { if finding { search(fromEnd: false) } }
            .onChange(of: feed.appended) { follow() }
            .onChange(of: working) { follow() }
            .onChange(of: feed.waiting) { follow() }
            .onChange(of: feed.rows.last?.id) { before, _ in
                // Rows that come at the end while reading further up don't push
                // others out of the top. Older rows put in front, and the first
                // rows read, add nothing after the last one.
                guard !atBottom, let before, let at = feed.rows.lastIndex(where: { $0.id == before }) else { return }
                let added = feed.rows.count - 1 - at
                if added > 0, feed.rows.count > limit { limit += added }
            }
            .onChange(of: feed.session) { limit = Self.page }
            .onChange(of: feed.phase) { if nearTop { older() } }
    }

    /// The rows with Find's bar over them, and what brings a row into view.
    private var found: some View {
        scroller
            .overlay(alignment: .top) {
                if finding {
                    FindBar(query: $query, count: matches.count, index: matchIndex, size: size, focused: $findFocused,
                            step: { step($0) }, close: closeFind)
                        .padding(.top, 10)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: finding)
            .onReceive(NotificationCenter.default.publisher(for: .swiftrFind), perform: findCommand)
            .onReceive(NotificationCenter.default.publisher(for: .swiftrReveal), perform: revealCall)
            .onReceive(NotificationCenter.default.publisher(for: .swiftrRevealQuote), perform: revealQuote)
    }

    /// The rows, following the end, with a button to jump back to it.
    private var scroller: some View {
        ScrollView {
            content
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        // At the end, stay there when rows come or the list shrinks (a
        // question from Claude); further up, keep what is being read in place.
        .defaultScrollAnchor(atBottom ? .bottom : .top, for: .sizeChanges)
        // The rows fade out under the field's glass rather than stop at a line.
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onScrollGeometryChange(for: ListGeometry.self, of: Self.geometry, action: geometryChanged)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // "Ask Claude" over words selected in the rows.
        .overlay(alignment: .topLeading) {
            QuoteOfferLayer(offer: quoteOffer, agentName: feed.agentName, size: size,
                            surface: Color(nsColor: model.prefs.theme.backgroundColor), take: quote)
        }
        .overlay(alignment: .bottom) {
            if !atBottom {
                Button {
                    withAnimation(.snappy(duration: 0.3)) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: size * 0.95, weight: .semibold))
                        .frame(width: size * 2.2, height: size * 2.2)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .paneGlass(.regular.interactive(), in: .circle)
                .padding(.bottom, 10)
                .help("Jump to the latest message")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: atBottom)
    }

    /// The rows drawn, each finished turn folded under how long it took, as
    /// the Codex app shows a conversation; what is queued and under way at the end.
    private var content: some View {
        let open = working || status?.state == "blocked"
        let pieces = turns.pieces(shownRows, openEnd: open)
        let lastTurn = pieces.last { if case .turn = $0 { true } else { false } }?.id
        let found = finding && matches.indices.contains(matchIndex) ? matches[matchIndex] : nil
        return VStack(alignment: .leading, spacing: ChatStyle.gap(size)) {
            top
            ForEach(pieces) { piece in
                switch piece {
                case .row(let row):
                    rowView(row, found: found)
                case .turn(let turn):
                    TurnView(turn: turn, size: size, folder: folder, reveal: turn.holds(found) || turn.holds(flashed) || turn.holds(marked?.row)) { row in
                        rowView(row, found: found)
                    } answer: { row in
                        rowView(row, found: found, answer: turn.id == lastTurn ? .last : .answer)
                    }
                }
            }
            if working || status?.state == "blocked" {
                ForEach(Array(feed.waiting.enumerated()), id: \.offset) { _, text in
                    PromptBubble(text: text, images: 0, size: size, queued: true)
                }
            }
            if working {
                WorkingRow(message: (feed.isCodex ? feed.footer?.activity : nil) ?? status?.message, since: feed.facts.lastPromptAt, size: size)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: ChatStyle.column(size) + 48, alignment: .leading)
        .frame(maxWidth: .infinity)
        // The margin on each side of the column, which a wide table may take.
        .environment(\.tableReach, max(0, (width - ChatStyle.column(size) - 48) / 2))
        // Agent rows read their sub-agents' steps through it.
        .environment(\.transcriptFeed, feed)
        .environment(\.showsDetails, feed.showsDetails)
        .environment(\.showsRowTimes, true)
        .background {
            HoldsPlace(holding: prepending)
            SelectionWatch(offer: quoteOffer, address: feed.address)
        }
    }

    private func rowView(_ row: TranscriptRow, found: String?, answer: AnswerMark = .none) -> some View {
        MessageRow(row: row, live: working && row.id == feed.rows.last?.id, size: size, folder: folder, answer: answer)
            .equatable()
            .background {
                if row.id == found || row.id == flashed { FoundMark() }
                if let marked, marked.row == row.id, !Self.inBubble(row) { passageMark(marked) }
            }
            // A bubble's color would hide it behind: over the words there.
            .overlay {
                if let marked, marked.row == row.id, Self.inBubble(row) { passageMark(marked) }
            }
            .id(row.id)
    }

    /// A message of the person's, in a bubble.
    private static func inBubble(_ row: TranscriptRow) -> Bool {
        if case .item(let item) = row, case .prompt = item.kind { return true }
        return false
    }

    private func passageMark(_ target: PassageMark.Target) -> some View {
        PassageMark(target: target) { Task { await markRow(target.row) } }
            .allowsHitTesting(false)
    }

    private static func geometry(_ geo: ScrollGeometry) -> ListGeometry {
        // The room above the field and Claude's question, which the rows
        // run under.
        let shown = geo.containerSize.height - geo.contentInsets.bottom
        // The content's size counts the room under the field, and a short
        // conversation's top inset puts it at the end: at the end, the
        // offset and the container's height make the content's height.
        let atEnd = geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
        // Older rows load a screen ahead of the top, so that scrolling up
        // never has to wait at it.
        let above = geo.contentOffset.y + geo.contentInsets.top
        let nearTop = above < max(geo.containerSize.height, 400)
        var g = ListGeometry(atEnd: atEnd, height: shown, nearTop: nearTop)
        // A few screens under the rows drawn first: `step` changes as the
        // list moves there, so its rest shows (`olderAtRest`).
        if !nearTop, above < 3 * max(geo.containerSize.height, 400) { g.step = Int(above / 150) }
        #if DEBUG
        g.detail = "offset=\(Int(geo.contentOffset.y)) container=\(Int(geo.containerSize.height)) insets=\(Int(geo.contentInsets.top))/\(Int(geo.contentInsets.bottom)) content=\(Int(geo.contentSize.height))"
        #endif
        return g
    }

    private func geometryChanged(_ old: ListGeometry, _ new: ListGeometry) {
        #if DEBUG
        MessageListProbe.lines[feed.address, default: []].append("\(new.detail) atEnd=\(new.atEnd) atBottom(before)=\(atBottom) heightChanged=\(new.height != old.height)")
        if MessageListProbe.lines[feed.address]!.count > 12 { MessageListProbe.lines[feed.address]!.removeFirst() }
        #endif
        if new.height != old.height, atBottom {
            // That room got smaller or bigger (a question from Claude
            // came or went, the field grew a line): stay at the end.
            position.scrollTo(edge: .bottom)
        } else {
            if new.atEnd, !atBottom { trimSoon() }
            atBottom = new.atEnd
        }
        if nearTop != new.nearTop { nearTop = new.nearTop }
        if new.nearTop { older() }
        rest.moves += 1
        if new.step != nil, !new.atEnd { olderAtRest() }
    }

    // MARK: Find

    /// ⌘F, ⌘G, ⇧⌘G and Esc for this conversation.
    private func findCommand(_ note: Notification) {
        guard note.object as? String == feed.address else { return }
        if let words = note.userInfo?["query"] as? String { query = words }
        switch note.userInfo?["do"] as? String {
        case "next": finding ? step(1) : openFind()
        case "previous": finding ? step(-1) : openFind()
        case "close": closeFind()
        default: openFind()
        }
    }

    private func openFind() {
        // Open already: ⌘F puts the keyboard back in its field.
        if finding { findFocused = true }
        finding = true
        search(fromEnd: true)
    }

    private func closeFind() {
        // The field lets go of the keyboard first: the message field
        // doesn't take it from a field someone types in.
        findFocused = false
        finding = false
        matches = []
        DispatchQueue.main.async { model.requestFocus() }
    }

    /// The rows that hold the words; the newest shown first, or the same
    /// one kept when rows come.
    private func search(fromEnd: Bool) {
        let shown = matches.indices.contains(matchIndex) ? matches[matchIndex] : nil
        let words = query.trimmingCharacters(in: .whitespaces)
        matches = words.isEmpty ? [] : feed.rows.filter { $0.contains(words) }.map(\.id)
        if !fromEnd, let shown, let same = matches.firstIndex(of: shown) {
            matchIndex = same
        } else {
            matchIndex = max(0, matches.count - 1)
            reveal()
        }
    }

    /// The next match (`by` 1) or the one before (-1), round the ends.
    private func step(_ by: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + by + matches.count) % matches.count
        reveal()
    }

    /// Brings the match shown into view, drawing older rows when it is among them.
    private func reveal() {
        guard matches.indices.contains(matchIndex), let at = feed.rows.firstIndex(where: { $0.id == matches[matchIndex] }) else { return }
        let id = matches[matchIndex]
        let needed = feed.rows.count - at + 8
        if needed > limit { limit = needed }
        Task { @MainActor in
            // Once the rows it needs are drawn.
            await Task.yield()
            withAnimation(.snappy(duration: 0.3)) { position.scrollTo(id: id, anchor: .center) }
        }
    }

    /// Brings the row of the call a notice names into view and marks it a moment.
    private func revealCall(_ note: Notification) {
        guard note.object as? String == feed.address, let call = note.userInfo?["call"] as? String,
              let at = feed.rows.lastIndex(where: { $0.holdsCall(call) })
        else { return }
        flash(at)
    }

    /// Brings the row a message quoted from into view and marks the passage
    /// in it a moment: the last row before that message which holds it.
    private func revealQuote(_ note: Notification) {
        guard note.object as? String == feed.address, let quote = note.userInfo?["quote"] as? String else { return }
        let end = (note.userInfo?["prompt"] as? String).flatMap { id in feed.rows.firstIndex { $0.id == id } } ?? feed.rows.count
        guard let at = QuoteSource.row(holding: quote, in: feed.rows, before: end) else { return }
        flash(at, passage: quote)
    }

    /// Words selected in the rows, over the field to go with the next message;
    /// that field takes the keyboard, its pane the focus.
    private func quote(_ text: String) {
        model.draftQuotes[feed.address, default: []].append(text)
        model.terminalFocused(feed.address)
        model.requestFocus()
    }

    /// The row at `at` in view, marked a moment; older rows drawn when it is
    /// among them. With a passage, only its words are marked, or the row when
    /// they can't be found in it.
    private func flash(_ at: Int, passage: String? = nil) {
        let id = feed.rows[at].id
        let needed = feed.rows.count - at + 8
        if needed > limit { limit = needed }
        Task { @MainActor in
            await Task.yield()
            withAnimation(.snappy(duration: 0.3)) { position.scrollTo(id: id, anchor: .center) }
            guard let passage else { return await markRow(id) }
            let mark = PassageMark.Target(row: id, passage: passage)
            marked = mark
            // Faded out by then.
            try? await Task.sleep(for: .seconds(4))
            if marked == mark { marked = nil }
        }
    }

    /// The row `id` marked a moment, as Find marks it.
    private func markRow(_ id: String) async {
        withAnimation(.easeOut(duration: 0.2)) { flashed = id }
        try? await Task.sleep(for: .seconds(1.6))
        if flashed == id { withAnimation(.easeIn(duration: 0.4)) { flashed = nil } }
    }

    /// Rows above those drawn, read already or still in the transcript.
    private var hasOlder: Bool { !feed.atStart || feed.rows.count > limit }

    /// Older rows in front: those already read first, then more from the
    /// transcript. Once they are laid out, the top may still be near (short
    /// rows): then more come.
    private func older() {
        guard !prepending, feed.phase == .ready, hasOlder else { return }
        prepending = true
        if feed.rows.count > limit {
            limit += Self.page
            settle(grew: true)
        } else {
            let before = feed.rows.count
            Task {
                await feed.loadEarlier()
                let grew = feed.rows.count > before
                if grew { limit += Self.page }
                settle(grew: grew)
            }
        }
    }

    /// The list rests a few screens under the rows drawn first: the older
    /// ones come now, while nothing moves. Rows added in front stop the list
    /// for a moment (all of it is laid out again, a quarter of a second for
    /// a long one): a scroll that reaches the top would show that stop.
    private func olderAtRest() {
        guard hasOlder, !prepending else { return }
        let mine = rest.moves
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if mine == rest.moves { older() }
        }
    }

    /// Lets rows that come at the end leave what is read in place again,
    /// once the older ones are laid out.
    private func settle(grew: Bool) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            prepending = false
            // A read that brought nothing waits for the next scroll.
            if grew, nearTop { older() }
        }
    }

    /// Back at the end for a moment, the older rows drawn on the way up go:
    /// each row drawn costs every frame of a scroll, and every row that comes.
    /// They come back as before when the top nears again.
    private func trimSoon() {
        guard limit > Self.page else { return }
        trims += 1
        let mine = trims
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard mine == trims, atBottom, !prepending, !finding, flashed == nil, marked == nil, limit > Self.page else { return }
            limit = Self.page
        }
    }

    private func follow() {
        guard atBottom else { return }
        withAnimation(.snappy(duration: 0.25)) { position.scrollTo(edge: .bottom) }
    }

    @ViewBuilder private var top: some View {
        switch feed.phase {
        case .looking:
            if let reason = feed.unavailable {
                note(reason, spinner: false)
            } else {
                note("Looking for \(feed.agentName)'s session…", spinner: true)
            }
        case .loading:
            note("Reading the conversation…", spinner: true)
        case .empty:
            note("No messages in this session yet.", spinner: false)
        case .ready:
            // Older rows come in before the top shows: the wheel turns only
            // while they are read, for someone who got there first. Its room
            // stays, so that the rows under it don't move when it goes.
            if hasOlder {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .overlay {
                        if feed.loadingEarlier { ProgressView().controlSize(.small) }
                    }
            }
        }
    }

    private func note(_ text: String, spinner: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer()
            if spinner { ProgressView().controlSize(.small) }
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: size * 0.9))
        .padding(.vertical, 20)
    }
}

/// How many times the list moved. Not state the view reads: a change must
/// not make the list's view run again.
private final class Rest {
    var moves = 0
}

/// The rows folded into turns, kept while the rows stay the same: SwiftUI
/// compares the pieces it gets with the last ones, row by row, unless they
/// are the very same array, and the list's view runs again at each change
/// of its own state (the end reached or left, the field's height…).
private final class TurnPieces {
    private var rows: ArraySlice<TranscriptRow> = []
    private var openEnd = false
    private var made: [TurnPiece] = []

    func pieces(_ rows: ArraySlice<TranscriptRow>, openEnd: Bool) -> [TurnPiece] {
        if openEnd != self.openEnd || rows != self.rows {
            self.rows = rows
            self.openEnd = openEnd
            made = TranscriptRow.pieces(rows, openEnd: openEnd)
        }
        return made
    }
}

/// A finished turn, as the Codex app shows it: "Worked for 1m 5s" over a
/// line, the work folded under it (open on click, or with ⌃O), then the
/// agent's last answer. An answer that came at once shows alone. When
/// Settings show diffs expanded, the fold keeps the turn's edits in view.
private struct TurnView<Step: View, Answer: View>: View {
    @Environment(\.showsDetails) private var showsDetails
    @Environment(\.expandsDiffs) private var expandsDiffs
    let turn: TurnFold
    let size: Double
    let folder: String
    /// Find, or the background list, shows a row folded in it.
    let reveal: Bool
    @ViewBuilder let step: (TranscriptRow) -> Step
    @ViewBuilder let answer: (TranscriptRow) -> Answer
    /// Opened or closed by a click; else as ⌃O says.
    @State private var opened: Bool?
    private var open: Bool { reveal || (opened ?? showsDetails) }

    var body: some View {
        VStack(alignment: .leading, spacing: ChatStyle.gap(size)) {
            if !turn.rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // At once: while rows grow in an animation, the list loses its end.
                    TurnHeader(text: turn.milliseconds.map { "Worked for \(TurnHeader.duration($0))" } ?? "Worked for a while",
                               open: open, size: size) { opened = !open }
                    if open {
                        VStack(alignment: .leading, spacing: ChatStyle.gap(size)) {
                            ForEach(turn.rows) { step($0) }
                        }
                        .padding(.top, ChatStyle.gap(size) * 0.8)
                        .padding(.bottom, ChatStyle.gap(size) * 0.3)
                    } else if expandsDiffs {
                        let edits = changes
                        if !edits.isEmpty {
                            VStack(alignment: .leading, spacing: size * 0.55) {
                                ForEach(edits, id: \.id) { call in
                                    ToolRow(call: call, running: false, size: size, folder: folder)
                                }
                            }
                            .padding(.top, ChatStyle.gap(size) * 0.8)
                            .padding(.bottom, ChatStyle.gap(size) * 0.3)
                        }
                    }
                    TurnRule()
                        .padding(.top, size * 0.6)
                }
            }
            let pictures = turn.pictures
            if !pictures.isEmpty {
                ViewedPictures(pictures: pictures, size: size)
            }
            answer(turn.answer)
        }
        .onChange(of: showsDetails) { opened = nil }
    }

    /// The edits folded in the turn that went in, in order.
    private var changes: [ToolCall] {
        turn.rows.flatMap { row -> [ToolCall] in
            let items: [TranscriptItem] = switch row {
            case .item(let item): [item]
            case .activity(_, let items): items
            }
            return items.compactMap { item in
                guard case .tool(let call) = item.kind, ToolRow.showsChange(call) else { return nil }
                return call
            }
        }
    }
}

/// The row Find shows, marked as macOS marks what it finds.
private struct FoundMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.yellow.opacity(0.16))
            .strokeBorder(Color.yellow.opacity(0.55), lineWidth: 1)
            .padding(-7)
    }
}

/// Find in the conversation: the words, how many rows hold them, and
/// buttons to go from one to the next. Return goes to the next, Shift-Return
/// to the one before, Esc closes.
private struct FindBar: View {
    @Binding var query: String
    let count: Int
    let index: Int
    let size: Double
    let focused: FocusState<Bool>.Binding
    let step: (Int) -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in Conversation", text: $query)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit { step(1) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    step(-1)
                    return .handled
                }
                .onExitCommand(perform: close)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(count == 0 ? "No results" : "\(index + 1) of \(count)")
                    .font(.system(size: size * 0.8).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            HStack(spacing: 2) {
                Button { step(-1) } label: { Image(systemName: "chevron.up").frame(width: size * 1.4, height: size * 1.4).contentShape(.rect) }
                    .help("Previous (⇧⌘G)")
                Button { step(1) } label: { Image(systemName: "chevron.down").frame(width: size * 1.4, height: size * 1.4).contentShape(.rect) }
                    .help("Next (⌘G)")
            }
            .disabled(count == 0)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .help("Close (Esc)")
        }
        .buttonStyle(.plain)
        .font(.system(size: size * 0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: 460)
        .paneGlass(.regular, in: .capsule)
        .onAppear {
            DispatchQueue.main.async { focused.wrappedValue = true }
        }
    }
}

extension Notification.Name {
    /// Find in a conversation: `object` is the pane's address, `userInfo["do"]`
    /// is open, next, previous or close.
    static let swiftrFind = Notification.Name("SwiftrFindInConversation")
    /// Show where a tool call is in a conversation: `object` is the pane's
    /// address, `userInfo["call"]` the call's id.
    static let swiftrReveal = Notification.Name("SwiftrRevealCall")
}

/// Keeps what is read in place while older rows come in front: the
/// conversation's scroll view moves down by what they add above, as the
/// rows are laid out, before they show. SwiftUI's own anchor for size
/// changes left the scroll where it was, so the rows jumped down.
private struct HoldsPlace: NSViewRepresentable {
    let holding: Bool

    func makeNSView(context: Context) -> Holder { Holder() }

    func updateNSView(_ view: Holder, context: Context) { view.holding = holding }

    /// Inside the conversation's scroll view, which it finds above it.
    final class Holder: NSView {
        var holding = false
        /// The rows' height at their last change.
        private var height: CGFloat?
        private var observer: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil, let rows = enclosingScrollView?.documentView else { return }
            height = rows.frame.height
            rows.postsFrameChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: rows, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.rowsChanged() }
            }
        }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        private func rowsChanged() {
            guard let scroll = enclosingScrollView, let rows = scroll.documentView else { return }
            let now = rows.frame.height
            defer { height = now }
            // Rows laid out from the top: those added in front push the rest down.
            guard holding, rows.isFlipped, let before = height, now != before else { return }
            let clip = scroll.contentView
            var shown = clip.bounds
            shown.origin.y += now - before
            clip.scroll(to: clip.constrainBoundsRect(shown).origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}

private struct ListGeometry: Equatable {
    var atEnd: Bool
    var height: CGFloat
    var nearTop = false
    /// Where the list is, in steps of 150 points, a few screens under the
    /// rows drawn first; nil elsewhere.
    var step: Int?
    #if DEBUG
    var detail = ""
    #endif
}

#if DEBUG
/// The last scroll geometry each conversation saw, for the debug dump.
@MainActor enum MessageListProbe {
    static var lines: [String: [String]] = [:]
}

/// Rows as MessageList lays them out, without the scroll view, for the
/// `render` debug hook: ImageRenderer draws them with the screen locked.
struct RowsRender: View {
    let feed: TranscriptFeed
    let rows: [TranscriptRow]
    let size: Double
    let folder: String

    var body: some View {
        let pieces = TranscriptRow.pieces(rows, openEnd: feed.status?.state == "working" || feed.status?.state == "blocked")
        let lastTurn = pieces.last { if case .turn = $0 { true } else { false } }?.id
        VStack(alignment: .leading, spacing: ChatStyle.gap(size)) {
            ForEach(pieces) { piece in
                switch piece {
                case .row(let row):
                    MessageRow(row: row, live: false, size: size, folder: folder)
                case .turn(let turn):
                    TurnView(turn: turn, size: size, folder: folder, reveal: false) { row in
                        MessageRow(row: row, live: false, size: size, folder: folder)
                    } answer: { row in
                        MessageRow(row: row, live: false, size: size, folder: folder, answer: turn.id == lastTurn ? .last : .answer)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: ChatStyle.column(size) + 48)
        .environment(\.transcriptFeed, feed)
        .environment(\.showsDetails, feed.showsDetails)
        .environment(\.expandsDiffs, UserDefaults.standard.bool(forKey: "messagesExpandDiffs"))
        .environment(\.showsRowTimes, true)
        .environment(\.flatRender, true)
    }
}

/// The pane as shown, for the `render-pane` debug hook: the last rows,
/// then what sits under them, the field drawn as plain text.
struct PaneRender: View {
    @Environment(AppModel.self) private var model
    let feed: TranscriptFeed
    let rows: [TranscriptRow]
    let address: String
    let paneID: String
    let context: PaneContext

    var body: some View {
        let size = model.prefs.fontSize
        let folder = model.store.model(address)?.currentFolder ?? ""
        VStack(spacing: 0) {
            RowsRender(feed: feed, rows: rows, size: size, folder: folder)
                .frame(maxWidth: .infinity, alignment: .leading)
            PaneBottom(feed: feed, address: address, paneID: paneID, context: context, status: feed.status, size: size, folder: folder)
        }
        .environment(\.flatRender, true)
    }
}

extension Notification.Name {
    /// Debug hooks: the field of the Claude at `object` (an address) acts as
    /// a key would make it: `userInfo["do"]` is submit, up, down, tab, enter or escape.
    static let swiftrDebugField = Notification.Name("SwiftrDebugField")
}
#endif


/// Where the person writes to Claude. Return sends; Shift-, Option- or
/// Control-Return go to a new line; Esc stops Claude while it works;
/// Shift-Tab does what it does in the agent's input (its next mode). `/` lists commands, `@` the project's
/// files, `!` runs a shell command, ↑ brings back what was sent, pictures
/// pasted or dropped go with the message, other files dropped are named
/// in it. What is written stays, by terminal, until sent.
private struct Composer: View {
    @Environment(AppModel.self) private var model
    let feed: TranscriptFeed
    let address: String
    let paneID: String
    let context: PaneContext
    let status: AgentStatus?
    let size: Double
    let folder: String
    @State private var sending = false
    @State private var problem: String?
    /// The command picked in the list over the field.
    @State private var selection = 0
    /// The text for which Esc closed that list.
    @State private var dismissedFor: String?
    /// While ↑ and ↓ go through the messages sent: which one shows, in
    /// which list (newest first), what the field held before, and the
    /// changes made to those shown.
    @State private var historyIndex: Int?
    @State private var historyWalk: [String] = []
    @State private var historyDraft = ""
    @State private var historyEdits: [Int: String] = [:]
    /// ⌃R's search through the messages sent before is open; what the
    /// field held when it opened, put back by Esc.
    @State private var searching = false
    @State private var searchBase: String?
    @State private var dropping = false
    /// When Esc was last pressed in an empty field: twice opens the rewind list.
    @State private var lastEscape: Date?
    /// When ⌃C was pressed in an empty field: a second one soon after quits
    /// the agent; till then the field says so.
    @State private var quitAsked: Date?

    private var draft: Binding<String> {
        Binding(get: { model.drafts[address] ?? "" }, set: { model.drafts[address] = $0.isEmpty ? nil : $0 })
    }

    /// The pictures to send with the text, kept with it.
    private var images: [PendingImage] {
        get { model.draftImages[address] ?? [] }
        nonmutating set { model.draftImages[address] = newValue.isEmpty ? nil : newValue }
    }

    /// Passages of the conversation quoted over the text (`QuotedPrompt`), kept with it.
    private var quotes: [String] {
        get { model.draftQuotes[address] ?? [] }
        nonmutating set { model.draftQuotes[address] = newValue.isEmpty ? nil : newValue }
    }

    /// Claude's configuration folder on this Mac, from its session's path
    /// (`<config>/projects/<folder>/<id>.jsonl`); nil on another machine.
    private var configFolder: String? {
        guard let s = feed.session, s.machine == nil, feed.agent == .claude else { return nil }
        var url = URL(filePath: s.path)
        for _ in 0 ..< 3 { url.deleteLastPathComponent() }
        return url.path
    }

    /// The `.gemini` folder a Gemini on this Mac reads, from its chat's path
    /// (`<.gemini>/tmp/<project>/chats/session-….json`); nil on another machine.
    private var geminiFolder: String? {
        guard let s = feed.session, s.machine == nil, feed.isGemini else { return nil }
        var url = URL(filePath: s.path)
        for _ in 0 ..< 4 { url.deleteLastPathComponent() }
        return url.path
    }

    /// Where the agent keeps what was sent before, as its ⌃R and ↑ go
    /// through it: on this Mac, or on the machine it runs on.
    private var historySource: HistorySource? {
        guard let s = feed.session else { return nil }
        let machine = s.machine
        switch feed.agent {
        case .claude:
            guard !folder.isEmpty, let config = machine == nil ? configFolder : ClaudeWatch.remoteConfig else { return nil }
            return HistorySource(kind: .claude(project: folder), path: config + "/history.jsonl", machine: machine)
        case .codex:
            // `<home>/sessions/YYYY/MM/DD/rollout-….jsonl`
            guard let sessions = s.path.range(of: "/sessions/", options: .backwards) else { return nil }
            return HistorySource(kind: .codex, path: String(s.path[..<sessions.lowerBound]) + "/history.jsonl", machine: machine)
        case .opencode:
            guard machine == nil else { return HistorySource(kind: .openCode, path: "", machine: machine) }
            let env = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            let state = env.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.local/state"
            return HistorySource(kind: .openCode, path: state + "/opencode/prompt-history.jsonl", machine: nil)
        case .gemini:
            // `<.gemini>/tmp/<project>/chats/session-….jsonl`
            let project = ((s.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            return HistorySource(kind: .gemini, path: project + "/logs.json", machine: machine)
        }
    }

    var body: some View {
        let running = model.store.model(address)?.runsChatAgent == true
        let codex = feed.isCodex
        let claude = feed.agent == .claude
        let blocked = status?.state == "blocked"
        let working = status?.state == "working"
        let text = model.drafts[address] ?? ""
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty && quotes.isEmpty
        let typed = SlashCommand.typedName(text)
        // Listed only for a `/`: not at each key of a message.
        let matches: [SlashCommand] = typed.map { name -> [SlashCommand] in
            let offered: [SlashCommand] = switch feed.agent {
            case .claude: CommandCatalog.shared.commands(config: configFolder, folder: folder)
            case .codex: CommandCatalog.shared.codexCommands()
            case .opencode: CommandCatalog.shared.openCodeCommands(folder: folder)
            case .gemini: CommandCatalog.shared.geminiCommands(gemini: geminiFolder, folder: folder)
            }
            return SlashCommand.matching(name, in: offered)
        } ?? []
        let listed = running && !blocked && !searching && dismissedFor != text ? matches : []
        // `@word` at the end: the project's files that match it.
        let mention = running && !blocked && !searching && listed.isEmpty && dismissedFor != text ? FileMention.typed(text) : nil
        let files = mention.flatMap { word in
            FileIndex.shared.index(folder: folder, machine: model.store.model(address)?.machine, connection: model.connection)?.matching(word)
        } ?? []
        let found = searching
            ? HistoryPopup.matches(text, conversation: feed.history, folder: HistoryStore.shared.entries(historySource))
            : []
        VStack(alignment: .leading, spacing: 0) {
            popup(listed: listed, files: files, found: found, query: text)
            VStack(alignment: .leading, spacing: 6) {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: size * 0.85))
                        .foregroundStyle(.readable(.orange))
                }
                DictationLine(address: address, size: size)
                // OpenCode and Gemini take a pasted `!` as words, not as a shell command.
                if text.hasPrefix("!"), !feed.isOpenCode, !feed.isGemini {
                    Label(codex ? "Shell command: Codex runs it and shows the output" : "Shell command: Claude Code runs it and shows Claude the output", systemImage: "terminal")
                        .font(.system(size: size * 0.8))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                // As the Codex app's field: the text on top, then a row with
                // what to attach and the agent's settings, and the round
                // button. On Liquid Glass, which the conversation runs under.
                VStack(alignment: .leading, spacing: size * 0.6) {
                    // A menu of Claude's own over its box: what the box held shows again once it closes.
                    if let held = feed.heldInBox, feed.dialog == nil {
                        HeldInBoxLine(text: held, agent: feed.agent, name: feed.agentName, cut: feed.heldCut, handed: feed.holdsHandedPictures(held), size: size,
                                      waits: working && feed.clearingStopsTurn, asks: feed.inputUnderQuestion) {
                            Task { await feed.takeBackDraft() }
                        } clear: {
                            Task { await feed.clearHeldBox() }
                        } show: {
                            model.setPaneMode(.terminal, for: address)
                        }
                    }
                    if let aside = model.stashedDrafts[address] {
                        SetAsideLine(text: aside, size: size) {
                            _ = handle(.stash, listed: [], files: [])
                        }
                    }
                    if !quotes.isEmpty {
                        QuoteTray(quotes: Binding(get: { quotes }, set: { quotes = $0 }), size: size) { quote in
                            NotificationCenter.default.post(name: .swiftrRevealQuote, object: address, userInfo: ["quote": quote])
                        }
                        .transition(.opacity)
                    }
                    if !images.isEmpty {
                        ImageTray(images: Binding(get: { images }, set: { images = $0 }), size: size)
                    }
                    field(text: text, running: running, blocked: blocked, working: working, claude: claude, listed: listed, files: files, found: found)
                        // While the voice goes into it: bars over the words.
                        .modifier(DictationCover(address: address, size: size))
                        .padding(.horizontal, size * 0.35)
                    HStack(spacing: 2) {
                        attachButton(ready: running && !blocked)
                        AgentChips(feed: feed, status: status, size: size, side: .leading)
                        Spacer(minLength: 6)
                        AgentChips(feed: feed, status: status, size: size, side: .trailing)
                        DictationButton(address: address, size: size, ready: running && !blocked)
                            .padding(.leading, 2)
                        buttons(empty: empty, running: running, blocked: blocked, working: working)
                            .padding(.leading, 2)
                    }
                }
                .padding(.horizontal, size * 0.6)
                .padding(.top, size * 0.95)
                .padding(.bottom, size * 0.6)
                .paneGlass(.regular, in: .rect(cornerRadius: Self.corner(size)))
                .overlay {
                    if dropping {
                        RoundedRectangle(cornerRadius: Self.corner(size))
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .allowsHitTesting(false)
                    }
                }
                .paneDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
                    drop(providers, ready: running && !blocked)
                }
                .overlay {
                    DictationFieldEdge(address: address, corner: Self.corner(size))
                }
                #if DEBUG
                .onReceive(NotificationCenter.default.publisher(for: .swiftrDebugField)) { note in
                    debugField(note, listed: listed, files: files, found: found)
                }
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        // The commands' list and the history's come and go at once: growing
        // in an animation, they laid the whole conversation out again at
        // each of its frames, three times the work of opening them.
        .animation(.snappy(duration: 0.18), value: quotes.count)
        // When `/` is typed; also when the field opens on a `/` kept from
        // before, or the session's folders turn up after it.
        .onChange(of: typed == nil ? nil : [configFolder, geminiFolder, folder], initial: true) {
            guard typed != nil else { return }
            if feed.isOpenCode {
                CommandCatalog.shared.loadOpenCode(folder: folder)
            } else if feed.isGemini {
                CommandCatalog.shared.loadGemini(gemini: geminiFolder, folder: folder)
            } else {
                CommandCatalog.shared.load(config: configFolder, folder: folder)
            }
        }
        .onChange(of: typed) { selection = 0 }
        .onChange(of: text) {
            if searching { selection = 0 }
            quitAsked = nil
        }
        .onChange(of: blocked) { if blocked { endSearch(restore: false) } }
        .onChange(of: mention) { selection = 0 }
    }

    /// What is dropped on the field: pictures with the message; other files
    /// named in it.
    private func drop(_ providers: [NSItemProvider], ready: Bool) -> Bool {
        guard ready else { return false }
        PendingImage.load(from: providers, pictures: true, into: { found in images += found }, files: { urls in mention(urls) })
        return true
    }

    #if DEBUG
    /// Debug hooks: a key pressed in the field, or a file dropped on it.
    private func debugField(_ note: Notification, listed: [SlashCommand], files: [String], found: [String]) {
        guard note.object as? String == address else { return }
        var keys: [String: ComposerKey] = ["up": .up, "down": .down, "tab": .tab, "right": .right, "backtab": .backtab, "enter": .enter, "escape": .escape, "search": .search]
        for n in 1 ... 9 { keys["\(n)"] = .digit(n) }
        switch note.userInfo?["do"] as? String {
        case "submit": submit()
        case "drop":
            if let path = note.userInfo?["path"] as? String { mention([URL(filePath: path)]) }
        case let what?:
            // As the key would: Esc the list didn't take goes on to the
            // field's own, ↑ and ↓ to the messages sent (from any line here).
            guard let key = keys[what], !handle(key, listed: listed, files: files, found: found) else { break }
            switch key {
            case .escape: escape(working: status?.state == "working", empty: draft.wrappedValue.isEmpty, claude: feed.agent == .claude)
            case .up: _ = handle(.earlierMessage, listed: listed, files: files, found: found)
            case .down: _ = handle(.laterMessage, listed: listed, files: files, found: found)
            default: break
            }
        default: break
        }
    }
    #endif

    /// The commands that match the `/word` typed, or the files the `@word`.
    @ViewBuilder private func popup(listed: [SlashCommand], files: [String], found: [String], query: String) -> some View {
        if searching {
            HistoryPopup(entries: found, query: query, selection: min(selection, max(found.count - 1, 0)), size: size) { entry in
                use(entry)
            }
            .transition(.opacity)
        } else if !listed.isEmpty {
            CommandPopup(commands: listed, selection: min(selection, listed.count - 1), size: size,
                         agent: feed.agent == .claude ? "Claude Code" : feed.isGemini ? "Gemini CLI" : feed.agentName,
                         sectioned: SlashCommand.typedName(query)?.isEmpty == true)
            { command in
                complete(command, run: true)
            }
            .transition(.opacity)
        } else if !files.isEmpty {
            FilePopup(paths: files, selection: min(selection, files.count - 1), size: size) { path in
                completeFile(path)
            }
            .transition(.opacity)
        }
    }

    /// The field's corners, as round as the Codex app's.
    static func corner(_ size: Double) -> CGFloat { size * 1.55 }

    /// Send; Stop instead while the agent works and nothing is written, as
    /// the Codex app's one round button.
    @ViewBuilder private func buttons(empty: Bool, running: Bool, blocked: Bool, working: Bool) -> some View {
        let name = feed.agentName
        if working, empty, images.isEmpty {
            RoundButton(symbol: "stop.fill", on: true, size: size) {
                Task { await feed.interrupt() }
            }
            .help("Stop \(name) (Esc)")
        } else {
            let off = empty || !running || blocked
            RoundButton(symbol: "arrow.up", on: !off, busy: sending, size: size, action: submit)
                .disabled(off || sending)
                .help(working && !feed.isCodex ? "Send: \(name) reads it \(readsWhen) (↩)" : "Send (↩)")
        }
    }

    /// "+": pictures to send with the message, other files to name in it.
    private func attachButton(ready: Bool) -> some View {
        Button(action: attach) {
            Image(systemName: "plus")
                .font(.system(size: size * 1.1))
                .frame(width: size * 2.15, height: size * 2.15)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary.opacity(ready ? 0.85 : 0.3))
        .disabled(!ready)
        .help("Attach pictures or files")
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Attach"
        panel.message = "Pictures go with the message; other files are named in it."
        guard panel.runModal() == .OK else { return }
        var others: [URL] = []
        for url in panel.urls {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
               let data = try? Data(contentsOf: url), let picture = PendingImage.fitted(name: url.lastPathComponent, data: data)
            {
                images += [picture]
            } else {
                others.append(url)
            }
        }
        if !others.isEmpty { mention(others) }
    }

    /// The text field itself, with its hint while empty.
    private func field(text: String, running: Bool, blocked: Bool, working: Bool, claude: Bool, listed: [SlashCommand], files: [String], found: [String]) -> some View {
        RenderStandIn {
            ComposerField(
                text: draft, size: size, enabled: running && !blocked, dark: model.prefs.theme.isDark,
                // Not once the pane shows its terminal again: this view is
                // kept, still in the window while it leaves, and would take
                // back the keyboard the terminal just took.
                focusTick: model.focusTick, wantsFocus: context.focused == paneID && model.showsMessages(address),
                onSubmit: submit,
                onEscape: { escape(working: working, empty: text.isEmpty, claude: claude) },
                onFocus: { model.terminalFocused(address) },
                onKey: { handle($0, listed: listed, files: files, found: found) },
                onImages: { takePictures($0) },
                onFiles: mention,
                // The cursor follows the draft to the agent's input and back.
                caretAsk: feed.caretAsk,
                onCaret: { feed.fieldCaret = ($0, $1) }
            )
        } standIn: {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: size))
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .topLeading) {
            if text.isEmpty {
                if quitAsked != nil {
                    Text("Press ⌃C again to quit \(feed.agentName)")
                        .font(.system(size: size))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                } else if searching {
                    Text("Search your earlier messages")
                        .font(.system(size: size))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                } else if let next = suggestion(running: running, blocked: blocked, working: working) {
                    // Claude Code's guess at the next message, as dim as in its terminal.
                    HStack(spacing: 6) {
                        Text(next)
                            .font(.system(size: size))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Text("Tab")
                            .font(.system(size: size * 0.72, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .rect(cornerRadius: 4))
                            .fixedSize()
                    }
                    .allowsHitTesting(false)
                    .help("\(feed.agentName) suggests this message: Tab or → puts it in the field")
                } else {
                    Text(placeholder(running: running, blocked: blocked, working: working))
                        .font(.system(size: size))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// Claude Code's suggested next message, while its input box shows it
    /// and the field is free to take it.
    private func suggestion(running: Bool, blocked: Bool, working: Bool) -> String? {
        guard running, !blocked, !working, feed.agent == .claude,
              let next = feed.footer?.suggestion, !next.isEmpty else { return nil }
        return next
    }

    /// Esc stops the agent at work. On an empty field, Esc twice goes back
    /// to an earlier message, as in the agent's terminal: Claude Code's
    /// rewind list, Codex browsing its transcript (Esc again stops it),
    /// Gemini's rewind list.
    private func escape(working: Bool, empty: Bool, claude: Bool) {
        if working {
            Task { await feed.interrupt() }
            return
        }
        if feed.codexBrowsing {
            Task { await feed.closeCodexBacktrack() }
            return
        }
        guard empty, feed.agent != .opencode, status?.state != "blocked" else { return }
        if let last = lastEscape, Date().timeIntervalSince(last) < 0.6 {
            lastEscape = nil
            if feed.isCodex {
                Task { await feed.openCodexBacktrack() }
            } else {
                // Claude's list, or Gemini's: a card the field's keys then
                // move in (↑ ↓ ↩ Esc), as in the terminal.
                Task { await feed.openRewindList() }
            }
        } else {
            lastEscape = Date()
        }
    }

    /// ⌃C, as in the agents' terminals: ends ⌃R's search, or stops the
    /// agent at work. In an empty field the first says a second quits the
    /// agent; the second, within 1.5 s, does. False leaves the field to
    /// empty itself.
    private func cancel(empty: Bool) -> Bool {
        guard model.store.model(address)?.runsChatAgent == true, status?.state != "blocked" else { return false }
        if searching {
            endSearch(restore: true)
            return true
        }
        if status?.state == "working" {
            quitAsked = nil
            Task { await feed.interrupt() }
            return true
        }
        guard empty else { return false }
        if let asked = quitAsked, Date().timeIntervalSince(asked) < 1.5 {
            quitAsked = nil
            // The pane shows the terminal then: it takes the keyboard.
            Task {
                try? await feed.quit()
                model.requestFocus()
            }
            return true
        }
        let now = Date()
        quitAsked = now
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if quitAsked == now { quitAsked = nil }
        }
        return true
    }

    /// Pictures pasted: they go with the message. Claude Code reads a
    /// picture's path at the start of a message; Codex and OpenCode one
    /// pasted alone in their input (`TranscriptFeed.send`).
    private func takePictures(_ found: [PendingImage]) {
        images += found
    }

    /// When a message sent while the agent works reaches it: Claude Code
    /// hands it over once the step under way ends, OpenCode at the turn's end.
    private var readsWhen: String {
        feed.agent == .claude ? "after its current step" : "at the end of the turn"
    }

    private func placeholder(running: Bool, blocked: Bool, working: Bool) -> String {
        let name = feed.agentName
        if !running { return "\(name) isn't running in this terminal" }
        if blocked { return "Answer \(name) above first" }
        if working { return feed.isCodex ? "Write to Codex · ↩ now, Tab after this turn" : "Write to \(name) (it reads this \(readsWhen))" }
        if feed.isOpenCode || feed.isGemini { return "Write to \(name) · / for commands · @ for files" }
        return "Write to \(name) · / for commands · ! for shell"
    }

    /// Keys the field passes on: the command list's first, or the files',
    /// then the history's; Shift-Tab, the agent's mode.
    private func handle(_ key: ComposerKey, listed: [SlashCommand], files: [String], found: [String] = []) -> Bool {
        let text = model.drafts[address] ?? ""
        switch key {
        case .right:
            // → takes Claude Code's suggestion as Tab does; else it moves the cursor.
            return !searching && takeSuggestion(text)
        case .details:
            // At once: while rows grow in an animation, the list loses its end.
            feed.showsDetails.toggle()
            return true
        case .todos:
            guard !feed.todos.isEmpty else { return false }
            withAnimation(.snappy(duration: 0.2)) { feed.todosOpen.toggle() }
            return true
        case .background:
            // As in Claude Code's terminal, while a command or an agent runs.
            guard feed.agent == .claude, status?.state == "working", feed.runsInForeground else { return false }
            Task { try? await feed.press(["ctrl+b"]) }
            return true
        case .sendNow:
            // A message waits while Claude works: it goes now, as with Send Now.
            guard feed.agent == .claude, status?.state == "working", !feed.queued.isEmpty else { return false }
            Task { try? await feed.press(["ctrl+x", "ctrl+s"]) }
            return true
        case .stopAgents:
            // Claude Code stops its sub-agents at the second ⌃X ⌃K: each goes to it.
            guard feed.agent == .claude, feed.runningInBackground.contains(where: { $0.kind == .agent }) else { return false }
            Task { try? await feed.press(["ctrl+x", "ctrl+k"]) }
            return true
        case .stash:
            // The draft and the one set aside change places: nothing is lost.
            let aside = model.stashedDrafts[address]
            guard !text.isEmpty || aside != nil else { return false }
            withAnimation(.snappy(duration: 0.18)) {
                model.stashedDrafts[address] = text.isEmpty ? nil : text
                model.drafts[address] = aside
            }
            return true
        case .editor:
            // As the agents' ⌃G: the draft in a text editor; each save comes back here.
            do {
                try DraftEditor.shared.open(text, for: address, agent: feed.agentName) { [model, address] saved in
                    model.drafts[address] = saved.isEmpty ? nil : saved
                }
            } catch {
                problem = "The draft didn't open in your editor: \(error.localizedDescription)"
            }
            return true
        case .thinking:
            // Claude Code's ⌥T: thinking on or off.
            guard feed.agent == .claude, status?.state != "blocked" else { return false }
            Task { try? await feed.pressInInput("alt+t", label: "⌥T Thinking") }
            return true
        case .lessEffort, .moreEffort:
            // Codex's ⌥, and ⌥.: it reasons less or more.
            guard feed.isCodex, status?.state != "blocked" else { return false }
            Task {
                try? await feed.pressInInput(key == .moreEffort ? "alt+." : "alt+,", label: key == .moreEffort ? "⌥. More reasoning" : "⌥, Less reasoning")
            }
            return true
        case .modelPicker:
            // ⌥P: Claude Code's own key; the others' command, between turns.
            // With text in the field, ⌥P types its letter.
            guard text.isEmpty, images.isEmpty, status?.state != "blocked" else { return false }
            if feed.agent == .claude {
                Task { try? await feed.pressInInput("alt+p") }
                return true
            }
            guard status?.state != "working" else { return false }
            Task {
                do { try await feed.send(feed.isOpenCode ? "/models" : "/model") } catch { problem = (error as? CoreError)?.message ?? error.localizedDescription }
            }
            return true
        case .fastMode:
            // Claude Code's ⌥O, in an empty field: fast mode on or off.
            guard feed.agent == .claude, text.isEmpty, images.isEmpty, status?.state != "blocked" else { return false }
            Task { try? await feed.pressInInput("alt+o", label: "⌥O Fast mode") }
            return true
        case .queueSubmit:
            // Claude Code's ⌃X ↩ while it works.
            guard feed.agent == .claude, status?.state == "working", images.isEmpty,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !quotes.isEmpty
            else { return false }
            submitDraft(queue: true)
            return true
        case .yolo:
            // Gemini's ⌃Y: YOLO mode on or off. Elsewhere the field's own ⌃Y.
            guard feed.isGemini, status?.state != "blocked" else { return false }
            Task { try? await feed.pressInInput("ctrl+y") }
            return true
        case .cancel:
            return cancel(empty: text.isEmpty)
        default:
            break
        }
        if searching {
            let count = found.count
            let i = min(selection, max(count - 1, 0))
            switch key {
            case .up, .backtab: if count > 0 { selection = (i - 1 + count) % count }
            case .down, .search: if count > 0 { selection = (i + 1) % count }
            case .tab, .enter: if count > 0 { use(found[i]) } else { endSearch(restore: false) }
            case .escape: endSearch(restore: true)
            case .details, .todos, .background, .stash, .sendNow, .stopAgents, .editor, .thinking, .lessEffort, .moreEffort, .yolo, .modelPicker, .fastMode, .queueSubmit, .cancel, .digit, .right, .earlierMessage, .laterMessage: break
            }
            return true
        }
        if key == .search {
            guard model.store.model(address)?.runsChatAgent == true, status?.state != "blocked" else { return false }
            // The search starts empty, as in a shell; Esc gives the draft back.
            searchBase = text
            model.drafts[address] = nil
            searching = true
            selection = 0
            HistoryStore.shared.load(historySource, connection: model.connection)
            return true
        }
        let count = listed.isEmpty ? files.count : listed.count
        if count > 0 {
            let i = min(selection, count - 1)
            switch key {
            case .up, .backtab: selection = (i - 1 + count) % count
            case .down: selection = (i + 1) % count
            case .tab: if listed.isEmpty { completeFile(files[i]) } else { complete(listed[i], run: false) }
            case .enter: if listed.isEmpty { completeFile(files[i]) } else { complete(listed[i], run: true) }
            case .escape: dismissedFor = text
            case .search, .details, .todos, .background, .stash, .sendNow, .stopAgents, .editor, .thinking, .lessEffort, .moreEffort, .yolo, .modelPicker, .fastMode, .queueSubmit, .cancel, .digit, .right, .earlierMessage, .laterMessage: break
            }
            return true
        }
        // A menu of the agent's own shows over its input (Esc Esc's rewind
        // list, `/model`): with the field empty, its keys go to it, as in
        // its terminal. Esc closes it whatever the field holds.
        if feed.agent == .claude || feed.isGemini, status?.state != "blocked", feed.dialog != nil || feed.menuOpening {
            let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
            switch key {
            case .up where blank:
                feed.menuKey("up")
                return true
            case .down where blank:
                feed.menuKey("down")
                return true
            case .enter where blank:
                feed.menuKey("enter")
                return true
            case .digit(let n) where blank && feed.dialog?.numbered == true:
                feed.menuKey("\(n)")
                return true
            case .escape:
                feed.menuKey("esc")
                return true
            default:
                break
            }
        }
        switch key {
        case .earlierMessage: return recall(older: true)
        case .laterMessage: return recall(older: false)
        case .tab:
            // Codex at work: Tab holds the message for the turn's end, as in its terminal.
            if feed.isCodex, status?.state == "working", images.isEmpty,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !quotes.isEmpty {
                submitDraft(queue: true)
                return true
            }
            // Tab takes Claude Code's suggestion into the empty field, as in its terminal.
            return takeSuggestion(text)
        case .backtab:
            // Shift-Tab goes to the agent's own input and does what it is
            // bound to there: Claude Code's next permission mode (or what
            // the person bound it to), OpenCode's next agent.
            Task { try? await feed.pressInInput("shift+tab") }
            return true
        default: return false
        }
    }

    /// Claude Code's suggestion into the empty field; false when there is none to take.
    private func takeSuggestion(_ text: String) -> Bool {
        guard text.isEmpty, images.isEmpty, let next = feed.footer?.suggestion, !next.isEmpty,
              feed.agent == .claude, status?.state != "working", status?.state != "blocked"
        else { return false }
        model.drafts[address] = next
        return true
    }

    /// A message found by ⌃R, in the field to send again or change.
    private func use(_ entry: String) {
        model.drafts[address] = entry
        searching = false
        searchBase = nil
        selection = 0
        endWalk()
    }

    /// Closes ⌃R's search; Esc gives the field back as it was before.
    private func endSearch(restore: Bool) {
        guard searching else { return }
        if restore, let base = searchBase { model.drafts[address] = base.isEmpty ? nil : base }
        searching = false
        searchBase = nil
        selection = 0
    }

    /// The file or folder picked in the list: in the field as `@path`.
    private func completeFile(_ path: String) {
        selection = 0
        model.drafts[address] = FileMention.complete(model.drafts[address] ?? "", with: path)
    }

    /// Files dropped on the field: named with `@`, as the agent reads them,
    /// from the project's folder when inside it. On another machine, each
    /// goes beside the terminal first.
    private func mention(_ urls: [URL]) {
        let machine = model.store.model(address)?.machine
        Task {
            var names: [String] = []
            for url in urls.prefix(20) {
                if machine == nil {
                    names.append(Self.relative(url.path, to: folder))
                } else if let data = try? Data(contentsOf: url), data.count <= PendingImage.maxBytes,
                          let path = try? await feed.attach(data, name: url.lastPathComponent)
                {
                    names.append(path)
                } else {
                    problem = "\(url.lastPathComponent) can't go to that machine (8 MB at most, files only)."
                }
            }
            guard !names.isEmpty else { return }
            var text = model.drafts[address] ?? ""
            if let last = text.last, !last.isWhitespace { text += " " }
            text += names.map { "@" + ($0.contains(" ") ? "\"\($0)\"" : $0) }.joined(separator: " ") + " "
            model.drafts[address] = text
            model.requestFocus()
        }
    }

    /// `path` from `folder` when inside it, else whole.
    static func relative(_ path: String, to folder: String) -> String {
        guard !folder.isEmpty else { return path }
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// The command in the field; run at once when it needs nothing after it.
    private func complete(_ command: SlashCommand, run: Bool) {
        selection = 0
        if run, !command.argumentHint.hasPrefix("<") {
            model.drafts[address] = "/" + command.name
            submit()
        } else {
            model.drafts[address] = "/" + command.name + " "
        }
    }

    /// What ↑ goes back through, newest first, each once: this
    /// conversation's messages, then those the agent kept from earlier ones
    /// (Claude Code's and Gemini's from this folder, Codex's and OpenCode's
    /// from every folder).
    private var sentBefore: [String] {
        var seen = Set<String>()
        return (feed.history.reversed() + HistoryStore.shared.entries(historySource)).filter { seen.insert($0).inserted }
    }

    /// ↑ from the field's first line, ↓ from its last, as in the agents'
    /// terminals: the messages sent before, the cursor at the end going
    /// back, at the start coming forward. Past the newest, what the field
    /// held comes back. A message changed on the way keeps its change
    /// until one is sent.
    private func recall(older: Bool) -> Bool {
        let text = model.drafts[address] ?? ""
        guard let at = historyIndex, historyWalk.indices.contains(at) else {
            guard older else { return false }
            let reading = HistoryStore.shared.load(historySource, connection: model.connection)
            let walk = sentBefore
            // The newest already in the field: the one before it.
            let first = walk.first == text ? 1 : 0
            guard walk.indices.contains(first) else {
                // A new conversation: the folder's messages may be on their way.
                guard let reading else { return false }
                Task {
                    await reading.value
                    if historyIndex == nil, (model.drafts[address] ?? "") == text { _ = recall(older: true) }
                }
                return true
            }
            historyWalk = walk
            historyDraft = text
            historyEdits = [:]
            showSent(first, caretAtEnd: true)
            return true
        }
        // Read since the walk began (the folder's messages): at its end, so the places stay.
        let known = Set(historyWalk)
        historyWalk += sentBefore.filter { !known.contains($0) }
        if text != historyEdits[at] ?? historyWalk[at] { historyEdits[at] = text }
        if older {
            if at + 1 < historyWalk.count { showSent(at + 1, caretAtEnd: true) }
        } else if at > 0 {
            showSent(at - 1, caretAtEnd: false)
        } else {
            let draft = historyDraft
            endWalk()
            putInField(draft, caret: draft.utf16.count)
        }
        return true
    }

    private func showSent(_ i: Int, caretAtEnd: Bool) {
        historyIndex = i
        let shown = historyEdits[i] ?? historyWalk[i]
        putInField(shown, caret: caretAtEnd ? shown.utf16.count : 0)
    }

    /// `text` in the field, its cursor at `caret` (UTF-16).
    private func putInField(_ text: String, caret: Int) {
        model.drafts[address] = text.isEmpty ? nil : text
        feed.caretTick += 1
        feed.caretAsk = CaretAsk(offset: caret, text: text, tick: feed.caretTick)
    }

    /// ↑ and ↓ move the cursor again; the changes made on the way are dropped.
    private func endWalk() {
        historyIndex = nil
        historyWalk = []
        historyDraft = ""
        historyEdits = [:]
    }

    private func submit() {
        submitDraft(queue: false)
    }

    /// Sends the draft; `queue`: Codex holds it until its turn ends (Tab).
    private func submitDraft(queue: Bool) {
        let typed = (model.drafts[address] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Passages quoted from the conversation go first, the words typed after them.
        let quoted = quotes
        let text = QuotedPrompt(quotes: quoted, request: typed).text
        let pictures = images
        let ready = model.store.model(address)?.runsChatAgent == true && status?.state != "blocked"
        guard !text.isEmpty || !pictures.isEmpty, !sending, ready else { return }
        sending = true
        problem = nil
        // Out of the field at once: the core takes a few seconds to tell
        // that a command starting no turn (`/status`) went in.
        model.drafts[address] = nil
        images.removeAll { picture in pictures.contains { $0.id == picture.id } }
        quotes = []
        endWalk()
        searching = false
        searchBase = nil
        Task {
            do {
                // Each picture beside the terminal; its path first in the message becomes the image.
                var paths: [String] = []
                for picture in pictures {
                    paths.append(try await feed.attach(picture.data, name: picture.name))
                }
                if queue, paths.isEmpty {
                    try await feed.queue(text)
                } else {
                    try await feed.send(text, pictures: paths)
                }
                DraftEditor.shared.stop(address)
                // ⌃S: the draft set aside comes back once this one went.
                if (model.drafts[address] ?? "").isEmpty, let aside = model.stashedDrafts.removeValue(forKey: address) {
                    model.drafts[address] = aside
                }
            } catch {
                problem = (error as? CoreError)?.message ?? error.localizedDescription
                // Still in Claude's input box: back in the field too, it would go twice.
                if (error as? CoreError)?.kind != "kept" {
                    // Back in the field, unless something else was written meanwhile.
                    if (model.drafts[address] ?? "").isEmpty, !typed.isEmpty { model.drafts[address] = typed }
                    images = pictures + images.filter { added in !pictures.contains { $0.id == added.id } }
                    quotes = quoted + quotes
                }
            }
            sending = false
            // A menu's card that opened meanwhile keeps the keyboard (`/resume`'s search).
            if feed.menus.kind == nil { model.requestFocus() }
        }
    }
}

/// The field's round button: Send, or Stop. A drop of glass: clear while
/// the field is empty, filled with the theme's accent when it can act.
/// Glass alone, even tinted, stays too pale for the arrow.
private struct RoundButton: View {
    @Environment(\.themeAccent) private var themeAccent
    @Environment(\.self) private var environment
    let symbol: String
    /// Ready: full strength; else faded, as the Codex app's empty field has it.
    let on: Bool
    var busy = false
    let size: Double
    let action: () -> Void

    var body: some View {
        let fill = themeAccent ?? Color.accentColor
        Button(action: action) {
            ZStack {
                if on {
                    Circle().fill(fill)
                }
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size * (symbol == "stop.fill" ? 0.72 : 0.95), weight: .semibold))
                        .foregroundStyle(on ? ChatStyle.ink(on: fill.resolve(in: environment)) : Color.secondary)
                }
            }
            .frame(width: size * 2.15, height: size * 2.15)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .paneGlass(.regular.interactive(), in: .circle)
    }
}

/// ⌃S: the draft set aside, over the field until it comes back.
private struct SetAsideLine: View {
    let text: String
    let size: Double
    let bringBack: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
            Text("Set aside: \(Text(text.split(separator: "\n").first.map(String.init) ?? "").foregroundStyle(.primary))")
            Spacer(minLength: 8)
            Button("Bring Back", action: bringBack)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Back in the field now (⌃S); else after you send")
        }
        .font(.system(size: size * 0.85))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.top, 2)
        .transition(.opacity)
    }
}

/// What the agent's input holds from its terminal that the field couldn't
/// take (a paste, a picture, a draft taller than Gemini's box; anything
/// while Claude or Gemini works): it goes first with the next message.
/// Take It moves plain words here; Clear empties the input with the
/// agent's own keys.
private struct HeldInBoxLine: View {
    let text: String
    let agent: TranscriptFeed.Agent
    let name: String
    /// The input holds more than it shows.
    let cut: Bool
    /// Its marks are the pictures the field handed the agent: they come back too.
    let handed: Bool
    let size: Double
    /// Emptying the input would stop the agent's turn: Take It and Clear wait.
    let waits: Bool
    /// The agent asks something over its input: Take It and Clear wait for the answer.
    let asks: Bool
    let take: () -> Void
    let clear: () -> Void
    let show: () -> Void

    var body: some View {
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        let more = text.contains("\n") || cut ? " …" : ""
        let marks = !ClaudeBox.placeholders(in: text).isEmpty
        let place = agent == .claude ? "box" : "input"
        HStack(spacing: 6) {
            Image(systemName: "terminal")
            Text("In \(name)'s \(place): \(Text(first + more).foregroundStyle(.primary))")
                .lineLimit(1)
                .truncationMode(.tail)
                .help(cut ? "Typed in \(name)'s terminal, taller than its box shows. It goes first with your next message." : "Typed in \(name)'s terminal. It goes first with your next message.")
            Spacer(minLength: 8)
            if !marks || handed, !cut {
                button("Take It", action: take)
                    .disabled(waits || asks)
                    .help(asks ? "Once you answer \(name)'s question, it can move here"
                        : waits ? "Once \(name)'s turn ends, it moves here" : handed ? "Into the field with its pictures, out of \(name)'s \(place)" : "Into the field, out of \(name)'s \(place)")
            }
            button("Clear", action: clear)
                .disabled(waits || asks)
                .help(asks ? askHelp
                    : waits ? "\(agent == .gemini ? "⌃C" : "Esc") would stop \(name): clear it once its turn ends" : clearHelp)
            button("Show", action: show)
                .help("Show \(name)'s terminal")
        }
        .font(.system(size: size * 0.85))
        .foregroundStyle(.secondary)
        .padding(.top, 2)
        .transition(.opacity)
    }

    /// Clear while the agent asks: its keys would go to the question.
    private var askHelp: String {
        switch agent {
        case .claude: "Esc would cancel Claude's question: clear it once you answer"
        case .codex: "⌃K ⌃U would go to Codex's question: clear it once you answer"
        case .opencode: "⇧Home ⌫ would go to OpenCode's question: clear it once you answer"
        case .gemini: "⌃C would cancel Gemini's question: clear it once you answer"
        }
    }

    private var clearHelp: String {
        switch agent {
        case .claude: "Out of Claude's box, as Esc Esc there (↑ there brings it back)"
        case .codex: "Out of Codex's input, as ⌃K ⌃U there"
        case .opencode: "Out of OpenCode's input, as ⇧Home ⌫ there"
        case .gemini: "Out of Gemini's input, as ⌃C there"
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle((waits || asks) && title != "Show" ? Color.secondary : Color.accentColor)
    }
}

/// Pictures that go with the next message.
private struct ImageTray: View {
    @Binding var images: [PendingImage]
    let size: Double

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(images) { picture in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let image = NSImage(data: picture.data) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: size * 4, height: size * 4)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                        .help(picture.name)
                        Button {
                            images.removeAll { $0.id == picture.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .font(.system(size: size * 1.05))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .help("Remove")
                    }
                }
            }
            .padding(.top, 5)
            .padding(.trailing, 5)
        }
        .scrollIndicators(.never)
    }
}

/// Switches a Claude pane between its terminal and its conversation.
struct PaneModeToggle: View {
    @Environment(AppModel.self) private var model
    let address: String
    /// The mark under the chosen button, which slides to the other one.
    @Namespace private var mark

    var body: some View {
        let mode = model.paneMode(of: address)
        HStack(spacing: 2) {
            button(.terminal, symbol: "terminal", help: "Terminal", current: mode)
            button(.messages, symbol: "text.bubble", help: "Messages", current: mode)
        }
        .padding(3)
        .paneGlass(.regular.interactive(), in: .capsule)
        .animation(.smooth(duration: 0.25), value: mode)
    }

    private func button(_ m: PaneMode, symbol: String, help: String, current: PaneMode) -> some View {
        Button {
            model.setPaneMode(m, for: address)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 22)
                .background {
                    if current == m {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.28))
                            .matchedGeometryEffect(id: "mark", in: mark)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(help + " (⇧⌘M)")
    }
}
