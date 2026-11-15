import HerdrKit
import SwiftUI
import UniformTypeIdentifiers

/// One row of the conversation.
struct MessageRow: View, Equatable {
    let row: TranscriptRow
    /// The last row while Claude works: its last tool call is the running one.
    let live: Bool
    let size: Double
    /// The session's folder, to show paths short.
    let folder: String
    /// A turn's last answer shows when it came, and Copy, under it.
    var answer: AnswerMark = .none

    var body: some View {
        switch row {
        case .item(let item):
            ItemView(item: item, size: size, answer: answer)
        case .activity(_, let items):
            ActivityView(items: items, live: live, size: size, folder: folder)
        }
    }
}

/// Whether a row is a turn's last answer, and the conversation's last one,
/// whose buttons always show, as in the Codex app.
enum AnswerMark: Equatable {
    case none, answer, last
}

/// The look Messages takes from the Codex app: one column, room between
/// messages, the person's messages in a bubble.
enum ChatStyle {
    /// The column's width at most, as the Codex app's (48rem at 13 points).
    static func column(_ size: Double) -> CGFloat { 768 * max(1, size / 13) }
    /// Between two messages.
    static func gap(_ size: Double) -> CGFloat { size * 1.25 }
    /// Lines under a finished turn's header.
    static func rule(_ scheme: ColorScheme) -> Color { Color.primary.opacity(scheme == .dark ? 0.11 : 0.09) }
    /// The steps' words, softer than the answers'.
    static let stepText = Color.primary.opacity(0.62)

    /// White on the accent, as on Apple's buttons; black on a light one,
    /// such as Graphite's pale blue.
    static func ink(on color: Color.Resolved) -> Color {
        let light = 0.2126 * Double(color.linearRed) + 0.7152 * Double(color.linearGreen) + 0.0722 * Double(color.linearBlue)
        return light > 0.4 ? .black : .white
    }
}

private struct ItemView: View {
    let item: TranscriptItem
    let size: Double
    var answer: AnswerMark = .none

    var body: some View {
        switch item.kind {
        case .prompt(let text, let images):
            PromptBubble(text: text, images: images, pictures: item.pictures, size: size, id: item.id, time: item.time)
        case .command(let name, let output):
            VStack(alignment: .trailing, spacing: size * 0.45) {
                CommandView(name: name, output: output, size: size)
                RowTimeLabel(time: item.time, size: size)
            }
        case .text(let markdown):
            if answer == .none {
                MarkdownView(markdown, size: size, wideTables: true)
                    .modifier(CopyOnHover(text: markdown, id: item.id, size: size))
            } else {
                AnswerView(text: markdown, id: item.id, time: item.time, last: answer == .last, size: size)
            }
        case .thinking(let text):
            ThinkingView(text: text, size: size)
        case .tool(let call):
            switch call.name {
            case "AskUserQuestion": AnsweredQuestions(call: call, size: size)
            case "ExitPlanMode": PlanRow(call: call, size: size)
            default: ToolRow(call: call, running: false, size: size, folder: "")
            }
        case .notice(let notice):
            NoticeView(notice: notice, size: size)
        }
    }
}

/// When something was written, as the Codex app says it under a message:
/// the hour today, else the day too (`Sep 29, 2:56 PM`), and the year
/// when it isn't this one.
enum RowTime {
    static func text(_ seconds: Double?, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let seconds else { return "" }
        let date = Date(timeIntervalSince1970: seconds)
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        var day = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
        return date.formatted(day) + ", " + time
    }
}

extension EnvironmentValues {
    /// The conversation's own messages show when each was written; a
    /// sub-agent's steps, inside an Agent row, don't.
    @Entry var showsRowTimes = false
}

/// When a message was written, under it.
private struct RowTimeLabel: View {
    @Environment(\.showsRowTimes) private var shown
    let time: Double?
    let size: Double

    var body: some View {
        if shown, let time {
            let date = Date(timeIntervalSince1970: time)
            Text(RowTime.text(time))
                .font(.system(size: size * 0.88))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help(date.formatted(date: .complete, time: .shortened))
        }
    }
}

/// A turn's last answer: its words, then when it came, Copy and Read Aloud.
/// The conversation's last answer always shows its buttons; the others
/// while the pointer is on them, or while they're read.
private struct AnswerView: View {
    let text: String
    /// Its transcript item's, which Read Aloud knows it by.
    let id: String
    let time: Double?
    let last: Bool
    let size: Double
    @State private var hovering = false

    private var shown: Bool {
        #if DEBUG
        if HoverActions.debugShown { return true }
        #endif
        return last || hovering || ReadAloud.shared.readingID == id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.5) {
            MarkdownView(text, size: size, wideTables: true)
            HStack(spacing: size * 0.4) {
                RowTimeLabel(time: time, size: size)
                HoverActions(text: text, readID: id, size: size, plain: true)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// AskUserQuestion: what the agent asked and what the person answered,
/// on the person's side, as the Codex app shows an answered question.
private struct AnsweredQuestions: View {
    @Environment(\.agentName) private var agentName
    let call: ToolCall
    let size: Double

    var body: some View {
        let questions = AskQuestion.list(call.input)
        let answers = call.result?.answers ?? []
        TrailingFraction(fraction: 0.7) {
            VStack(alignment: .leading, spacing: size * 0.8) {
                ForEach(questions) { q in
                    VStack(alignment: .leading, spacing: size * 0.35) {
                        // The question on one line, as there; the whole of it under the pointer.
                        Text(q.question)
                            .foregroundStyle(Color.primary.opacity(0.7))
                            .lineLimit(1)
                            .help("\(agentName) asked: \(q.question)")
                        if let a = answers.first(where: { $0.question == q.question }) {
                            Text(a.answer)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                outcome(answered: !answers.isEmpty)
            }
            .font(.system(size: size))
            .textSelection(.enabled)
            .padding(.horizontal, size * 1.2)
            .padding(.vertical, size * 0.8)
            .paneGlass(.regular, in: .rect(cornerRadius: size * 1.7))
        }
    }

    @ViewBuilder private func outcome(answered: Bool) -> some View {
        if let result = call.result {
            if let declined = result.declined {
                Text(declined.isEmpty ? "Not answered" : "Not answered: \(declined)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !answered, !result.text.isEmpty {
                Text(result.text)
                    .foregroundStyle(result.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(4)
            }
        } else {
            Text("Waiting for your answer…")
                .foregroundStyle(.secondary)
        }
    }
}

/// Lays its view out at most `fraction` of the width offered, at the
/// trailing edge: the person's side of the conversation.
struct TrailingFraction: Layout {
    var fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        guard let width = proposal.width, width.isFinite else { return view.sizeThatFits(.unspecified) }
        let fitted = view.sizeThatFits(ProposedViewSize(width: width * fraction, height: nil))
        return CGSize(width: width, height: fitted.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let fitted = view.sizeThatFits(ProposedViewSize(width: bounds.width * fraction, height: nil))
        view.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                   proposal: ProposedViewSize(width: fitted.width, height: fitted.height))
    }
}

/// ExitPlanMode: Claude's plan, and what became of it.
private struct PlanRow: View {
    let call: ToolCall
    let size: Double
    @State private var open = false

    var body: some View {
        let plan = call.input["plan"]?.string ?? ""
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: size * 0.7, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Label("Plan", systemImage: "list.bullet.clipboard")
                        .fontWeight(.medium)
                    Text(Self.title(plan))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    outcome
                }
                .font(.system(size: size * 0.92))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                MarkdownView(plan, size: size * 0.95)
                    .padding(.leading, size * 0.4)
            }
            if let note = call.result?.declined, !note.isEmpty {
                Label(note, systemImage: "arrow.uturn.backward")
                    .font(.system(size: size * 0.88))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(size * 1.1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: size * 1.3))
    }

    @ViewBuilder private var outcome: some View {
        if let result = call.result {
            if result.declined != nil {
                Text("Sent back").foregroundStyle(.secondary)
            } else if result.isError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Label("Approved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.readable(.green))
            }
        } else {
            Text("Waiting for you").foregroundStyle(.secondary)
        }
    }

    /// The plan's heading, or its first line.
    static func title(_ plan: String) -> String {
        plan.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) }.first { !$0.isEmpty } ?? ""
    }
}

extension EnvironmentValues {
    /// The theme's accent, for the Send button; nil for the Mac's.
    @Entry var themeAccent: Color? = nil
    /// The terminal's font family, for code; "" for SF Mono.
    @Entry var codeFamily: String = Preferences.defaultFontName
    /// Whose conversation shows: "Claude", "Codex", "OpenCode".
    @Entry var agentName: String = "Claude"
    /// Puts a prompt sent before back in the field, to change and send again.
    @Entry var reusePrompt: RowAction? = nil
    /// Goes back to before a prompt (its item's id): Claude Code's /rewind, Codex's and Gemini's Esc Esc, OpenCode's /timeline.
    @Entry var rewindPrompt: RowAction? = nil
    /// OpenCode's /redo: what a revert took out of sight comes back.
    @Entry var redoRevert: RowAction? = nil
    /// Prompts /rewind no longer lists (a summary replaced them).
    @Entry var unrewindable: Set<String> = []
    #if DEBUG
    /// Drawn by a debug render (ImageRenderer): no scroll views.
    @Entry var flatRender = false
    #endif
}

/// Something a row's button does with a string, equal to another action of
/// the same key: closures can't be compared, and a new one at each update
/// would redraw every row that reads it.
struct RowAction: Equatable {
    let key: String
    let run: (String) -> Void

    func callAsFunction(_ s: String) { run(s) }

    static func == (a: RowAction, b: RowAction) -> Bool { a.key == b.key }
}

/// A message's buttons: Copy; for an agent's message, Read Aloud; for the
/// person's own, Edit (back in the field) and Rewind. Over a message in a
/// capsule, or in a row under it (`plain`), as the Codex app has them.
struct HoverActions: View {
    @Environment(\.reusePrompt) private var reusePrompt
    @Environment(\.rewindPrompt) private var rewindPrompt
    @Environment(\.unrewindable) private var unrewindable
    let text: String
    /// What Copy copies, when not `text`: a message that quoted the conversation, as Markdown.
    var copyText: String?
    /// An agent's message's item: Read Aloud reads it, and knows it by it.
    var readID: String?
    var editable = false
    /// The prompt's item: Rewind goes back to before it.
    var promptID: String?
    let size: Double
    var plain = false
    @State private var copied = false

    #if DEBUG
    /// Debug hooks: every message shows its buttons (`actions-shown:on`).
    static var debugShown = false
    #endif

    var body: some View {
        let buttons = HStack(spacing: plain ? 0 : 4) {
            Button(action: copy) {
                icon(copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .help("Copy")
            if let readID {
                let reading = ReadAloud.shared.readingID == readID
                Button {
                    ReadAloud.shared.toggle(id: readID, markdown: text)
                } label: {
                    icon(reading ? "stop.circle" : "speaker.wave.2")
                        .contentTransition(.symbolEffect(.replace))
                }
                .help(reading ? "Stop Reading" : "Read Aloud")
            }
            if editable, let reusePrompt {
                Button {
                    reusePrompt(text)
                } label: {
                    icon("pencil")
                }
                .help("Edit: back in the field, to change and send again")
            }
            if let promptID, let rewindPrompt, !unrewindable.contains(promptID) {
                Button {
                    rewindPrompt(promptID)
                } label: {
                    icon("arrow.counterclockwise")
                }
                .help("Rewind: go back to before this message")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        if plain {
            buttons
                .font(.system(size: size * 0.92))
        } else {
            buttons
                .font(.system(size: size * 0.8, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .paneGlass(.regular.interactive(), in: .capsule)
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: size * (plain ? 1.9 : 1.3), height: size * (plain ? 1.6 : 1.2))
            .contentShape(.rect)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText ?? text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// Claude's text with Copy and Read Aloud at its end while the pointer is
/// on it, or while it's read.
private struct CopyOnHover: ViewModifier {
    let text: String
    /// Its transcript item's, which Read Aloud knows it by.
    let id: String
    let size: Double
    @State private var hovering = false

    private var shown: Bool {
        #if DEBUG
        if HoverActions.debugShown { return true }
        #endif
        return hovering || ReadAloud.shared.readingID == id
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if shown {
                    HoverActions(text: text, readID: id, size: size)
                        .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Code in Messages, in the terminal's font: built once per family, size
/// and weight, as rows draw again while scrolling.
enum CodeFont {
    private static var fonts: [String: Font] = [:]

    static func font(_ size: Double, family: String, bold: Bool = false) -> Font {
        let key = "\(family)|\(size)|\(bold)"
        if let font = fonts[key] { return font }
        var ns = Preferences.font(family: family, size: size)
        if bold { ns = NSFontManager.shared.convert(ns, toHaveTrait: .boldFontMask) }
        let font = Font(ns as CTFont)
        if fonts.count > 200 { fonts.removeAll(keepingCapacity: true) }
        fonts[key] = font
        return font
    }
}

/// What the person wrote: its pictures, a bubble of glass on their side,
/// and under it when it was sent, with Copy, Edit and Rewind while the
/// pointer is on it.
struct PromptBubble: View {
    @Environment(\.agentName) private var agentName
    @Environment(\.transcriptFeed) private var feed
    @Environment(\.themeAccent) private var themeAccent
    @Environment(\.self) private var environment
    let text: String
    let images: Int
    /// The pictures, as files: fewer than `images` when some weren't kept.
    var pictures: [TranscriptImage] = []
    let size: Double
    /// Its item, for Rewind; nil for a queued one.
    var id: String?
    /// When it was sent.
    var time: Double?
    var queued = false
    @State private var hovering = false

    private var actionsShown: Bool {
        #if DEBUG
        if HoverActions.debugShown { return true }
        #endif
        return hovering
    }

    var body: some View {
        let shown = images > 0 ? Transcript.withoutImageTags(text) : text
        // Another program's message, sent with `hc send`: its words, and from whom.
        let sent = Transcript.sentWithHC(shown)
        let words = sent?.words ?? shown
        // A message that quoted the conversation: the passages over the
        // bubble, the question in it.
        let quoted = QuotedPrompt(parsing: words)
        let asked = quoted?.request ?? words
        let corner = size * 1.3
        VStack(alignment: .trailing, spacing: size * 0.45) {
            if let sent {
                Label("From \(sent.sender)", systemImage: "terminal")
                    .font(.system(size: size * 0.85))
                    .foregroundStyle(.secondary)
                    .help("Sent with hc send, not typed here")
            }
            if !pictures.isEmpty {
                PromptPictures(pictures: pictures, size: size)
            } else if images > 0 {
                Label(images == 1 ? "1 image" : "\(images) images", systemImage: "photo")
                    .font(.system(size: size * 0.85))
                    .foregroundStyle(.secondary)
            }
            if let quoted {
                PromptQuotes(quotes: quoted.quotes, size: size, promptID: id)
            }
            if !asked.isEmpty {
                TrailingFraction(fraction: 0.77) {
                    let bubble = Text(asked)
                        .font(.system(size: size))
                        .lineSpacing(size * 0.3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, size * 1.15)
                        .padding(.vertical, size * 0.72)
                    if queued {
                        // Not read yet: a dashed outline.
                        bubble.background {
                            RoundedRectangle(cornerRadius: corner)
                                .strokeBorder(Color.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    } else {
                        // In the Send button's color: the theme's accent, else the
                        // Mac's; a drop of glass filled with it, as that button.
                        let fill = themeAccent ?? Color.accentColor
                        bubble
                            .foregroundStyle(ChatStyle.ink(on: fill.resolve(in: environment)))
                            .background(fill, in: .rect(cornerRadius: corner))
                            .paneGlass(.regular, in: .rect(cornerRadius: corner))
                    }
                }
            }
            if queued {
                HStack(spacing: 8) {
                    Label(feed?.agent == .claude ? "Waiting: Claude reads it after its current step" : "Queued: \(agentName) will read it at the end of this turn",
                          systemImage: "clock")
                        .foregroundStyle(.secondary)
                    if feed?.agent == .claude {
                        // Claude Code's send-now key (⌃↩, or ⌃X ⌃S where a terminal can't tell ⌃↩).
                        Button("Send Now") { Task { try? await feed?.press(["ctrl+x", "ctrl+s"]) } }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .help("Claude reads it now; a command still running goes on in the background")
                    }
                }
                .font(.system(size: size * 0.8))
            } else {
                // Copy, Edit and Rewind come beside the time, which stays put.
                HStack(spacing: size * 0.4) {
                    if !words.isEmpty {
                        HoverActions(text: words, copyText: quoted?.markdown, editable: true, promptID: id, size: size, plain: true)
                            .opacity(actionsShown ? 1 : 0)
                            .allowsHitTesting(actionsShown)
                    }
                    RowTimeLabel(time: time, size: size)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A slash command or a `!` line the person ran, and what it printed.
private struct CommandView: View {
    @Environment(\.codeFamily) private var codeFamily
    let name: String
    let output: String?
    let size: Double

    var body: some View {
        TrailingFraction(fraction: 0.77) {
            VStack(alignment: .leading, spacing: size * 0.4) {
                Label(name, systemImage: name.hasPrefix("!") ? "terminal" : "slash.circle")
                    .font(CodeFont.font(size * 0.92, family: codeFamily))
                if let output, !output.isEmpty {
                    Text(output)
                        .font(CodeFont.font(size * 0.85, family: codeFamily))
                        .foregroundStyle(.secondary)
                        .lineLimit(12)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, size * 1.15)
            .padding(.vertical, size * 0.72)
            .paneGlass(.regular, in: .rect(cornerRadius: size * 1.3))
        }
    }
}

/// Tool calls and thinking between two answers. One step shows as it is;
/// more fold under one line in the Codex app's words ("Read files, ran a
/// command"), open on click, or with ⌃O.
private struct ActivityView: View {
    let items: [TranscriptItem]
    let live: Bool
    let size: Double
    let folder: String
    @Environment(\.showsDetails) private var showsDetails
    @Environment(\.expandsDiffs) private var expandsDiffs
    /// Opened or closed by a click; else as ⌃O says.
    #if DEBUG
    @State private var unfolded: Bool? = ToolRow.debugOpen ? true : nil
    #else
    @State private var unfolded: Bool?
    #endif
    @State private var hovering = false
    private var expanded: Bool { unfolded ?? showsDetails }

    /// The steps that show while the group is folded: the last two while
    /// the agent works, and its edits when Settings show diffs expanded.
    private var folded: [TranscriptItem] {
        let last = live ? Set(items.suffix(2).map(\.id)) : []
        return items.filter { item in
            if last.contains(item.id) { return true }
            guard expandsDiffs, case .tool(let call) = item.kind else { return false }
            return ToolRow.showsChange(call)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.55) {
            if items.count > 1 {
                Button {
                    let now = !expanded
                    withAnimation(.snappy(duration: 0.2)) { unfolded = now }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: Self.symbol(items))
                            .frame(width: size * 1.2)
                        let (summary, errors) = Self.summary(items)
                        // Failed calls stand out from the rest.
                        let failed = errors == 0 ? Text("") : Text(" · \(Text(errors == 1 ? "1 error" : "\(errors) errors").foregroundStyle(.readable(.orange)))")
                        Text("\(summary)\(failed)")
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: size * 0.7, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .opacity(hovering || expanded ? 1 : 0)
                    }
                    .font(.system(size: size))
                    .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(ChatStyle.stepText))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            }
            // While the agent works, its last steps show under the line.
            let shown: [TranscriptItem] = items.count <= 1 || expanded ? items : folded
            ForEach(shown) { item in
                switch item.kind {
                case .tool(let call):
                    ToolRow(call: call, running: live && item.id == items.last?.id && call.result == nil, size: size, folder: folder)
                case .thinking(let text):
                    ThinkingView(text: text, size: size)
                default:
                    EmptyView()
                }
            }
            .padding(.leading, items.count > 1 ? size * 1.2 + 7 : 0)
        }
        .onChange(of: showsDetails) { unfolded = nil }
    }

    /// What kind of step a tool is, for the line that sums them up.
    private enum Step: CaseIterable {
        case read, image, command, edit, search, web, agent, todo, skill, thought, tool

        init(_ item: TranscriptItem) {
            guard case .tool(let call) = item.kind else {
                self = .thought
                return
            }
            switch call.name {
            case "Read" where call.viewsPicture: self = .image
            case "Read", "NotebookRead": self = .read
            case "ViewImage": self = .image
            case "Bash", "PowerShell", "Shell", "BashOutput", "KillShell": self = .command
            case "Edit", "MultiEdit", "Write", "NotebookEdit", "Delete": self = .edit
            case "Grep", "Glob", "LS", "ToolSearch": self = .search
            case "WebSearch", "WebFetch": self = .web
            case "Agent", "Task": self = .agent
            case "TodoWrite": self = .todo
            case "Skill": self = .skill
            default: self = .tool
            }
        }

        /// As the Codex app words it, mid-sentence.
        func words(_ n: Int) -> String {
            switch self {
            case .read: "read files"
            case .image: n == 1 ? "viewed an image" : "viewed \(n) images"
            case .command: n == 1 ? "ran a command" : "ran commands"
            case .edit: n == 1 ? "edited a file" : "edited files"
            case .search: "searched the code"
            case .web: "searched the web"
            case .agent: n == 1 ? "ran an agent" : "ran agents"
            case .todo: "updated the to-do list"
            case .skill: n == 1 ? "used a skill" : "used skills"
            case .thought: "thought"
            case .tool: n == 1 ? "called a tool" : "called tools"
            }
        }

        var symbol: String {
            switch self {
            case .read: "doc.text"
            case .image: "photo"
            case .command: "terminal"
            case .edit: "pencil"
            case .search: "magnifyingglass"
            case .web: "globe"
            case .agent: "person.2"
            case .todo: "checklist"
            case .skill: "sparkles"
            case .thought: "brain"
            case .tool: "wrench.and.screwdriver"
            }
        }
    }

    /// "Read files, ran a command": each kind of step once, in the order
    /// they came; and how many calls failed.
    static func summary(_ items: [TranscriptItem]) -> (String, Int) {
        var counts: [Step: Int] = [:]
        var order: [Step] = []
        var errors = 0
        for item in items {
            let step = Step(item)
            if counts[step] == nil { order.append(step) }
            counts[step, default: 0] += 1
            if case .tool(let call) = item.kind, call.result?.isError == true { errors += 1 }
        }
        // Thinking says little once there are steps.
        if order.count > 1 { order.removeAll { $0 == .thought } }
        let words = order.map { $0.words(counts[$0]!) }.joined(separator: ", ")
        return (words.prefix(1).uppercased() + words.dropFirst(), errors)
    }

    /// The first kind of step's.
    static func symbol(_ items: [TranscriptItem]) -> String {
        (items.first { if case .tool = $0.kind { true } else { false } }).map { Step($0).symbol } ?? Step.thought.symbol
    }
}

/// The agent's thinking: "Thought", its words on click, or with ⌃O.
private struct ThinkingView: View {
    @Environment(\.showsDetails) private var showsDetails
    let text: String
    let size: Double
    /// Opened or closed by a click; else as ⌃O says.
    @State private var opened: Bool?
    @State private var hovering = false
    private var open: Bool { opened ?? showsDetails }

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.4) {
            Button {
                opened = !open
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain")
                        .frame(width: size * 1.2)
                    Text("Thought")
                    Image(systemName: "chevron.right")
                        .font(.system(size: size * 0.7, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .opacity(hovering || open ? 1 : 0)
                }
                .font(.system(size: size))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(ChatStyle.stepText))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            if open {
                Text(text)
                    .font(.system(size: size))
                    .lineSpacing(size * 0.35)
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: size * 44, alignment: .leading)
                    .padding(.leading, size * 1.2 + 7)
            }
        }
        .onChange(of: showsDetails) { opened = nil }
    }
}

extension EnvironmentValues {
    /// ⌃O: steps, groups of steps and thinking shown open, as Claude Code's ⌃O shows them in full.
    @Entry var showsDetails = false
    /// Settings › Show diffs expanded: each edit shows its changed lines
    /// without a click, even among folded steps.
    @Entry var expandsDiffs = false
}

/// On a command or agent Claude runs: sends it to the background, as ⌃B in its terminal.
private struct BackgroundButton: View {
    let size: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Run in Background", systemImage: "arrow.down.right.circle")
                .font(.system(size: size * 0.78, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Claude goes on while it runs (⌃B)")
    }
}

/// One tool call: its name and what it is about; details on click.
struct ToolRow: View {
    @Environment(\.transcriptFeed) private var feed
    @Environment(\.showsDetails) private var showsDetails
    @Environment(\.expandsDiffs) private var expandsDiffs
    @Environment(\.codeFamily) private var codeFamily
    let call: ToolCall
    let running: Bool
    let size: Double
    let folder: String
    /// Opened or closed by a click; else as ⌃O says, or Settings for an edit.
    #if DEBUG
    /// Debug hooks: rows drawn from now on start open (`tools-open:on`).
    static var debugOpen = false
    @State private var opened: Bool? = ToolRow.debugOpen ? true : nil
    #else
    @State private var opened: Bool?
    #endif
    @State private var hovering = false
    private var open: Bool { opened ?? (showsDetails || expandsDiffs && Self.showsChange(call)) }

    /// An edit that went in, whose changed lines Settings can show at once.
    /// One declined or failed changed nothing: it stays shut.
    static func showsChange(_ call: ToolCall) -> Bool {
        guard ["Edit", "MultiEdit", "Write"].contains(call.name), let result = call.result else { return false }
        return !result.isError && result.declined == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                opened = !open
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: Self.symbol(call.viewsPicture ? "ViewImage" : call.name))
                        .frame(width: size * 1.2)
                    // As the Codex app says a step: `Ran` and the command, `Read` and the file.
                    let phrase = Self.phrase(call, running: running)
                    Text(phrase.verb)
                        .layoutPriority(1)
                    if !phrase.detail.isEmpty {
                        Text(short(phrase.detail))
                            .font(phrase.code ? CodeFont.font(size * 0.92, family: codeFamily) : .system(size: size))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    // How it went, right after what it did: at the far end of a wide pane it reads as no one's.
                    Group {
                        if running, feed?.agent == .claude, TranscriptFeed.canRunInBackground(call) {
                            BackgroundButton(size: size) { Task { try? await feed?.press(["ctrl+b"]) } }
                        }
                        if running {
                            ProgressView().controlSize(.mini)
                        } else if let run = call.result?.agent {
                            AgentRunNote(run: run, ended: run.background ? feed?.backgroundEnd(call.id) : nil, size: size)
                        } else if call.result?.backgroundTask != nil {
                            // A command sent to the background: its notice says when it ended.
                            AgentRunNote(run: AgentRun(background: true), ended: feed?.backgroundEnd(call.id), size: size)
                        } else if call.result?.declined != nil {
                            Self.tag("Declined", symbol: nil, tint: .secondary, size: size)
                        } else if call.result?.isError == true {
                            Self.tag("Failed", symbol: "exclamationmark.triangle.fill", tint: .orange, size: size)
                        }
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                .font(.system(size: size))
                .foregroundStyle(hovering || open ? AnyShapeStyle(.primary) : AnyShapeStyle(ChatStyle.stepText))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            if let note = call.result?.declined, !note.isEmpty {
                Label(note, systemImage: "arrow.uturn.backward")
                    .font(.system(size: size * 0.88))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, size * 1.2 + 7)
            }
            if open {
                ToolDetail(call: call, size: size, folder: folder)
                    .padding(.leading, size * 1.2 + 7)
            }
        }
        .onChange(of: showsDetails) { opened = nil }
        .onChange(of: expandsDiffs) { opened = nil }
    }

    /// A word in a capsule beside the row: `Declined`, `Failed`.
    static func tag(_ word: String, symbol: String?, tint: Color, size: Double) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(word)
        }
        .font(.system(size: size * 0.78, weight: .medium))
        .foregroundStyle(.readable(tint))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(tint.opacity(0.12), in: .capsule)
    }

    /// Paths under the session's folder or the home folder, shortened.
    private func short(_ s: String) -> String {
        if !folder.isEmpty, s.hasPrefix(folder + "/") { return String(s.dropFirst(folder.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if s.hasPrefix(home + "/") { return "~" + s.dropFirst(home.count) }
        return s.replacingOccurrences(of: "\n", with: " ")
    }

    /// What a step did, in the Codex app's words: `Ran` and the command,
    /// `Read` and the file; and whether what it names is code.
    static func phrase(_ call: ToolCall, running: Bool) -> (verb: String, detail: String, code: Bool) {
        let summary = call.summary
        switch call.name {
        case "Bash", "PowerShell", "Shell":
            let command = call.input["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let first = command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            let shown = first.isEmpty ? summary : first + (command.contains("\n") ? " …" : "")
            return (running ? "Running" : "Ran", shown, !first.isEmpty)
        case "BashOutput": return ("Read the output of", summary, true)
        case "KillShell": return ("Stopped", summary, true)
        case "Read" where call.viewsPicture: return ("Viewed", summary, false)
        case "Read", "NotebookRead", "WebFetch": return (running ? "Reading" : "Read", summary, false)
        case "ViewImage": return ("Viewed", summary, false)
        case "Write": return (running ? "Writing" : "Wrote", summary, false)
        case "Edit", "MultiEdit", "NotebookEdit": return (running ? "Editing" : "Edited", summary, false)
        case "Delete": return ("Deleted", summary, false)
        case "Grep": return (running ? "Searching for" : "Searched for", summary, true)
        case "Glob": return (running ? "Listing files" : "Listed files", summary, true)
        case "LS": return (running ? "Listing files in" : "Listed files in", summary, false)
        case "WebSearch": return (running ? "Searching the web for" : "Searched the web for", summary, false)
        case "ToolSearch": return ("Loaded tools", summary, false)
        case "Skill": return ("Used skill", summary, false)
        case "TodoWrite": return ("Updated to-dos", summary, false)
        default: return (label(call), summary, false)
        }
    }

    /// A sub-agent's type for the Agent tool (`Explore`), as Claude Code
    /// names the row; else the tool's name.
    static func label(_ call: ToolCall) -> String {
        if call.name == "Agent" || call.name == "Task",
           let type = call.input["subagent_type"]?.string ?? call.result?.agent?.type, !type.isEmpty {
            return type
        }
        return label(call.name)
    }

    static func label(_ name: String) -> String {
        // Claude Code's own word for it.
        if name == "TodoWrite" { return "To-dos" }
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).split(separator: "__", maxSplits: 1).map(String.init)
        return parts.count == 2 ? "\(parts[0]) · \(parts[1])" : String(name.dropFirst(5))
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "Bash", "PowerShell", "BashOutput", "KillShell", "Shell": "terminal"
        case "Read": "doc.text"
        case "Delete": "trash"
        case "ViewImage": "photo"
        case "Write": "square.and.pencil"
        case "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Grep", "Glob", "ToolSearch": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent", "Task": "person.2"
        case "TodoWrite": "checklist"
        case "Skill": "sparkles"
        case "AskUserQuestion": "questionmark.bubble"
        case "ExitPlanMode", "EnterPlanMode": "list.bullet.clipboard"
        default: name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}

/// A tool call's input and result.
private struct ToolDetail: View {
    let call: ToolCall
    let size: Double
    let folder: String

    var body: some View {
        if call.name == "Agent" || call.name == "Task" {
            agent
        } else {
            tool
        }
    }

    /// A sub-agent: its task, its steps, what it answered. A run in the
    /// background answers in its notice, when it ends.
    private var agent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let prompt = call.input["prompt"]?.string {
                caption("Prompt")
                Monospaced(text: prompt, maxLines: 6, total: nil, size: size, tint: nil)
            }
            SubagentSteps(call: call, size: size, folder: folder)
            if let result = call.result, result.agent?.background != true {
                let reply = Self.agentReply(result.text)
                if !reply.isEmpty {
                    caption("Reply")
                    MarkdownView(reply, size: size * 0.92)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(result.isError ? Color.orange.opacity(0.08) : Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
                }
            }
        }
    }

    /// A small word over a box: what the agent was asked, what it said.
    private func caption(_ word: String) -> some View {
        Text(word)
            .font(.system(size: size * 0.75, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, -4)
    }

    /// A sub-agent's answer without the lines Claude Code adds for Claude
    /// (`agentId: … (use SendMessage…)`, `<usage>…</usage>`).
    static func agentReply(_ text: String) -> String {
        var t = text
        if let r = t.range(of: "\nagentId: ", options: .backwards) { t = String(t[..<r.lowerBound]) }
        if let r = t.range(of: "<usage>", options: .backwards) { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var tool: some View {
        VStack(alignment: .leading, spacing: 6) {
            input
            if let result = call.result {
                if !result.text.isEmpty, !Self.saysOnlyDone(call) {
                    Monospaced(text: result.text, maxLines: 40, total: result.lines, size: size, tint: result.isError ? .orange : nil)
                }
                if !result.pictures.isEmpty {
                    ResultPictures(pictures: result.pictures, size: size)
                } else if result.images > 0 {
                    Label(result.images == 1 ? "1 image" : "\(result.images) images", systemImage: "photo")
                        .font(.system(size: size * 0.85))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No result yet.")
                    .font(.system(size: size * 0.85))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A result that only says it went in ("The file … has been updated
    /// successfully.", "Todos have been modified successfully…"): the change
    /// or the list above says more.
    static func saysOnlyDone(_ call: ToolCall) -> Bool {
        guard let result = call.result, !result.isError else { return false }
        let t = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch call.name {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return t.hasPrefix("The file ") || t.hasPrefix("File created successfully")
        case "TodoWrite": return t.hasPrefix("Todos have been modified successfully")
        default: return false
        }
    }

    @ViewBuilder private var input: some View {
        let i = call.input
        switch call.name {
        case "Bash", "PowerShell", "Shell":
            if let command = i["command"]?.string {
                Monospaced(text: "$ " + command, maxLines: 20, total: nil, size: size, tint: nil)
            }
        case "Edit":
            if let diff = i["diff"]?.string {
                // Codex: the change as a patch.
                if let moved = i["move_path"]?.string {
                    Label("Moved to \(moved)", systemImage: "arrow.right")
                        .font(.system(size: size * 0.85))
                        .foregroundStyle(.secondary)
                }
                PatchView(diff: diff, size: size)
            } else {
                DiffView(old: i["old_string"]?.string ?? "", new: i["new_string"]?.string ?? "", size: size)
            }
        case "MultiEdit":
            ForEach(Array((i["edits"]?.array ?? []).enumerated()), id: \.offset) { _, edit in
                DiffView(old: edit["old_string"]?.string ?? "", new: edit["new_string"]?.string ?? "", size: size)
            }
        case "Write":
            if let content = i["content"]?.string {
                Monospaced(text: content, maxLines: 30, total: nil, size: size, tint: nil)
            }
        case "TodoWrite":
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array((i["todos"]?.array ?? []).enumerated()), id: \.offset) { _, todo in
                    let status = todo["status"]?.string ?? ""
                    Label(todo["content"]?.string ?? "", systemImage: status == "completed" ? "checkmark.circle.fill" : status == "in_progress" ? "circle.dotted" : "circle")
                        .font(.system(size: size * 0.9))
                        .foregroundStyle(status == "completed" ? .secondary : .primary)
                }
            }
        case "Agent", "Task":
            if let prompt = i["prompt"]?.string {
                Monospaced(text: prompt, maxLines: 12, total: nil, size: size, tint: nil)
            }
        case "Read", "Glob", "Grep", "WebSearch", "WebFetch", "Skill", "Delete", "ViewImage":
            EmptyView()
        default:
            if case .object(let fields) = i, !fields.isEmpty {
                Monospaced(text: String(decoding: i.data(pretty: true), as: UTF8.self), maxLines: 16, total: nil, size: size, tint: nil)
            }
        }
    }
}

/// Text in a box, in the terminal's font, cut after `maxLines`.
struct Monospaced: View {
    @Environment(\.codeFamily) private var codeFamily
    let text: String
    let maxLines: Int
    /// Lines in the whole text, if more than `text` holds.
    let total: Int?
    let size: Double
    let tint: Color?

    var body: some View {
        // A file's last newline would show as an empty line.
        let lines = text.replacing(/\n+\z/, with: "").split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(maxLines).joined(separator: "\n")
        let all = max(total ?? 0, lines.count)
        VStack(alignment: .leading, spacing: 4) {
            SideScroll {
                Text(shown)
                    .font(CodeFont.font(size * 0.82, family: codeFamily))
                    .foregroundStyle(tint.map { AnyShapeStyle(.readable($0)) } ?? AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(8)
            }
            if all > maxLines {
                Text("… \(all - maxLines) more lines")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
    }
}

/// Code wider than the row, scrolled sideways; code that fits, as it is.
/// AppKit tends each scroll view on every frame of the conversation's own
/// scroll: with one per box, a conversation full of changes had 35, and
/// dropped frames. A debug render draws it cut at the row's edge instead:
/// ImageRenderer can't draw a scroll view.
struct SideScroll<Content: View>: View {
    #if DEBUG
    @Environment(\.flatRender) private var flat
    #else
    private let flat = false
    #endif
    @ViewBuilder let content: Content

    var body: some View {
        if flat {
            content
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
        } else {
            ViewThatFits(in: .horizontal) {
                content
                ScrollView(.horizontal) { content }
                    .scrollIndicators(.never)
            }
        }
    }
}

/// An AppKit view, which ImageRenderer can't draw: a debug render shows
/// `standIn` in its place.
struct RenderStandIn<Content: View, StandIn: View>: View {
    #if DEBUG
    @Environment(\.flatRender) private var flat
    #else
    private let flat = false
    #endif
    @ViewBuilder let content: Content
    @ViewBuilder let standIn: StandIn

    var body: some View {
        if flat { standIn } else { content }
    }
}

/// A scroll view. A debug render, which can't draw one, lays its content
/// out flat instead, cut where the scroll view would end.
struct RenderScroll<Content: View>: View {
    #if DEBUG
    @Environment(\.flatRender) private var flat
    #else
    private let flat = false
    #endif
    let axes: Axis.Set
    let content: Content

    init(_ axes: Axis.Set = .vertical, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    var body: some View {
        if flat {
            content
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(axes) { content }
        }
    }
}

extension View {
    /// `onDrop`, left out of a debug render: ImageRenderer can't draw the
    /// AppKit view it adds.
    func paneDrop(of types: [UTType], isTargeted: Binding<Bool>, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        modifier(PaneDrop(types: types, isTargeted: isTargeted, perform: perform))
    }

    /// Liquid Glass. A debug render, which can't draw glass, gets a plain
    /// fill of the same shape.
    func paneGlass(_ glass: Glass = .regular, in shape: some Shape) -> some View {
        modifier(PaneGlass(glass: glass, shape: shape))
    }
}

private struct PaneDrop: ViewModifier {
    #if DEBUG
    @Environment(\.flatRender) private var flat
    #else
    private let flat = false
    #endif
    let types: [UTType]
    let isTargeted: Binding<Bool>
    let perform: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if flat {
            content
        } else {
            content.onDrop(of: types, isTargeted: isTargeted, perform: perform)
        }
    }
}

private struct PaneGlass<S: Shape>: ViewModifier {
    #if DEBUG
    @Environment(\.flatRender) private var flat
    #else
    private let flat = false
    #endif
    let glass: Glass
    let shape: S

    func body(content: Content) -> some View {
        if flat {
            content.background(Color.primary.opacity(0.07), in: shape)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

/// An edit, line by line: added and removed lines on a green or red band,
/// the lines it keeps dimmed between them.
struct DiffView: View {
    let lines: [LineDiff.Line]
    let size: Double
    static let maxLines = 60

    init(old: String, new: String, size: Double) {
        self.init(lines: LineDiff.lines(old: old, new: new), size: size)
    }

    init(lines: [LineDiff.Line], size: Double) {
        self.lines = lines
        self.size = size
    }

    var body: some View {
        let shown = lines.prefix(Self.maxLines).map { line in
            switch line.kind {
            case .removed: DiffLines.Line(kind: .removed, text: line.text)
            case .added: DiffLines.Line(kind: .added, text: line.text)
            case .same: DiffLines.Line(kind: .same, text: line.text)
            }
        }
        DiffLines(lines: shown, more: lines.count - shown.count, size: size)
    }
}

/// A change as a unified diff (what Codex writes), drawn as DiffView draws
/// an edit; file headers left out.
struct PatchView: View {
    let diff: String
    let size: Double
    static let maxLines = 60

    var body: some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("--- ") && !$0.hasPrefix("+++ ") && !$0.hasPrefix("diff --git") && !$0.hasPrefix("index ") }
        let trimmed = lines.last?.isEmpty == true ? Array(lines.dropLast()) : Array(lines)
        DiffLines(lines: trimmed.prefix(Self.maxLines).map(Self.line), more: trimmed.count - min(trimmed.count, Self.maxLines), size: size)
    }

    static func line(_ line: Substring) -> DiffLines.Line {
        if line.hasPrefix("@@") { return .init(kind: .hunk, text: String(line)) }
        if line.hasPrefix("+") { return .init(kind: .added, text: String(line.dropFirst())) }
        if line.hasPrefix("-") { return .init(kind: .removed, text: String(line.dropFirst())) }
        if line.hasPrefix(" ") { return .init(kind: .same, text: String(line.dropFirst())) }
        return .init(kind: .same, text: String(line))
    }
}

/// Lines of a change in a box: added and removed ones on a band of green or
/// red that runs across the box, in the text's own color, which reads in
/// light mode as in dark; the lines kept between them dimmed.
struct DiffLines: View {
    enum Kind { case added, removed, same, hunk }

    struct Line {
        let kind: Kind
        let text: String
    }

    @Environment(\.codeFamily) private var codeFamily
    let lines: [Line]
    /// Lines left out after these.
    let more: Int
    let size: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SideScroll {
                BandLines {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        row(line)
                    }
                }
                .font(CodeFont.font(size * 0.82, family: codeFamily))
                .textSelection(.enabled)
                .padding(.vertical, 8)
            }
            if more > 0 {
                Text("… \(more) more lines")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
    }

    private func row(_ line: Line) -> some View {
        let band: Color? = switch line.kind {
        case .added: .green
        case .removed: .red
        case .same, .hunk: nil
        }
        let text = line.text.isEmpty ? " " : line.text
        let shown: Text = switch line.kind {
        case .added: Text("\(Text("+ ").foregroundStyle(.readable(.green)))\(text)")
        case .removed: Text("\(Text("- ").foregroundStyle(.readable(.red)))\(text)")
        case .same: Text("  " + text).foregroundStyle(.secondary)
        case .hunk: Text(text).foregroundStyle(.tertiary)
        }
        return shown
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A plain rectangle: the bands of lines that follow join up.
            .background {
                if let band { Rectangle().fill(band.opacity(0.15)) }
            }
    }
}

/// Lines one under the other, each as wide as the widest, and as the box
/// when that is wider: the bands behind them run across.
private struct BandLines: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widest = sizes.map(\.width).max() ?? 0
        return CGSize(width: max(widest, proposal.width ?? 0), height: sizes.map(\.height).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let height = subview.sizeThatFits(.unspecified).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }
}

/// A color for text and small marks: the system's own in dark mode, darker
/// in light mode, where green, orange or red text reads faintly on a light box.
struct ReadableTint: ShapeStyle {
    let color: Color

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark ? color : color.mix(with: .black, by: 0.4)
    }
}

extension ShapeStyle where Self == ReadableTint {
    /// `color`, darkened in light mode so text in it reads.
    static func readable(_ color: Color) -> ReadableTint { ReadableTint(color: color) }
}

/// OpenCode's revert under way: how many messages went out of sight and
/// the files put back as they were, with Restore (`/redo`). The next
/// message makes it final.
struct RevertedNotice: View {
    @Environment(\.redoRevert) private var redo
    @Environment(\.codeFamily) private var codeFamily
    let messages: Int
    let files: [RevertedFile]
    let size: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .foregroundStyle(.secondary)
                Text(messages == 1 ? "1 message reverted" : "\(messages) messages reverted")
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                if let redo {
                    Button("Restore") { redo("") }
                        .help("Bring back the messages and their file changes (/redo)")
                }
            }
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(files, id: \.path) { file in
                        HStack(spacing: 6) {
                            Text(file.path)
                                .font(CodeFont.font(size * 0.82, family: codeFamily))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(Self.status(file.status))
                                .foregroundStyle(.secondary)
                            if file.additions > 0 { Text("+\(file.additions)").foregroundStyle(.readable(.green)) }
                            if file.deletions > 0 { Text("−\(file.deletions)").foregroundStyle(.readable(.red)) }
                        }
                        .font(.system(size: size * 0.82))
                    }
                }
            }
            Text("Your next message makes it final.")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: size * 0.9))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
    }

    /// What the revert did to the file.
    static func status(_ s: String) -> String {
        switch s {
        case "deleted": "removed"
        case "added": "restored"
        case "modified": "changed back"
        default: s
        }
    }
}

/// Something that happened in the session.
struct NoticeView: View {
    let notice: Notice
    let size: Double
    #if DEBUG
    @State private var open = ToolRow.debugOpen
    #else
    @State private var open = false
    #endif

    var body: some View {
        switch notice {
        case .compacted(let summary):
            VStack(spacing: 6) {
                centered(Label("Conversation compacted", systemImage: "rectangle.compress.vertical"))
                if let summary, !summary.isEmpty {
                    Button(open ? "Hide Summary" : "Show Summary") { open.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: size * 0.85))
                    if open {
                        MarkdownView(summary, size: size * 0.9)
                            .padding(10)
                            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
                    }
                }
            }
        case .interrupted:
            TurnHeader(text: "You stopped", size: size, ruled: true)
        case .task(_, let status, let summary, let ms, let result, _):
            VStack(spacing: 6) {
                centered(Label((summary.isEmpty ? "Background task done" : summary) + (ms.map { " · " + Self.duration($0) } ?? ""),
                               systemImage: status == "completed" ? "checkmark.circle" : status == "failed" ? "xmark.octagon"
                                   : ["stopped", "killed"].contains(status) ? "stop.circle" : "gearshape.2"))
                // What the task handed back to Claude.
                if let result {
                    Button(open ? "Hide Result" : "Show Result") { open.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: size * 0.85))
                    if open {
                        MarkdownView(result, size: size * 0.9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
                    }
                }
            }
        case .message(let from, let text):
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    open.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope")
                        Text(from.isEmpty ? "Message from an agent" : "Message from \(from)")
                            .fontWeight(.medium)
                        Text(firstLine(text))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: size * 0.9))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if open {
                    MarkdownView(text, size: size * 0.95)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: size * 0.9))
                .foregroundStyle(.readable(.red))
                .textSelection(.enabled)
        case .info(let text):
            Text(text)
                .font(.system(size: size * 0.85))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .turnEnded(let ms):
            // A turn that ended on a question or a step: its answer didn't fold it.
            TurnHeader(text: "Worked for \(TurnHeader.duration(ms))", size: size, ruled: true)
        case .goal(let goal):
            GoalNotice(goal: goal, size: size)
        case .agentsStopped:
            EmptyView()
        case .reverted(let messages, let files):
            RevertedNotice(messages: messages, files: files, size: size)
        case .hookFeedback(let text):
            VStack(spacing: 6) {
                centered(Label("A Stop hook sent Claude back to work", systemImage: "arrow.uturn.backward.circle"))
                Button(open ? "Hide Feedback" : "Show Feedback") { open.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: size * 0.85))
                if open {
                    Text(text)
                        .font(.system(size: size * 0.88))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
                }
            }
        }
    }

    private func centered(_ content: some View) -> some View {
        HStack {
            Spacer()
            content
                .font(.system(size: size * 0.82))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func firstLine(_ s: String) -> String {
        s.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? ""
    }

    static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        if s < 60 { return "\(max(s, 1)) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }
}

/// A `/goal` check: met, not met yet (Claude goes on), or out of reach;
/// what it took, and why the check said so.
private struct GoalNotice: View {
    let goal: GoalStatus
    let size: Double
    #if DEBUG
    @State private var open = ToolRow.debugOpen
    #else
    @State private var open = false
    #endif

    var body: some View {
        let failed = goal.state == .failed
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(title)
                    .foregroundStyle(goal.state == .notMet ? .secondary : .primary)
                    .fontWeight(goal.state == .notMet ? .regular : .medium)
                if let cost {
                    Text(cost)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: size * 0.82))
            .help("Goal: \(goal.condition)")
            if goal.reason != nil, !failed {
                Button(open ? "Hide Why" : "Why?") { open.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: size * 0.82))
            }
            if open || failed, let reason = goal.reason {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Goal: \(goal.condition)")
                        .font(.system(size: size * 0.85))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    MarkdownView(reason, size: size * 0.88)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
            }
        }
    }

    private var title: String {
        switch goal.state {
        case .met: "Goal met"
        case .failed: "Goal can't be met"
        default: "Goal not met yet: Claude keeps going"
        }
    }

    private var symbol: String {
        switch goal.state {
        case .met: "checkmark.seal.fill"
        case .failed: "xmark.seal.fill"
        default: "target"
        }
    }

    private var tint: AnyShapeStyle {
        switch goal.state {
        case .met: AnyShapeStyle(Color.green)
        case .failed: AnyShapeStyle(Color.red)
        default: AnyShapeStyle(.secondary)
        }
    }

    /// "2 h 27 min · 2 turns · 262k tokens", once met or failed.
    private var cost: String? {
        var parts: [String] = []
        if let ms = goal.milliseconds { parts.append(NoticeView.duration(ms)) }
        if let n = goal.turns { parts.append(n == 1 ? "1 turn" : "\(n) turns") }
        if let n = goal.tokens { parts.append(ContextChip.tokens(n) + " tokens") }
        return parts.isEmpty ? nil : "· " + parts.joined(separator: " · ")
    }
}

/// What a sub-agent's run took ("11 tools · 2 min 30 s"), or that it runs
/// on its own.
private struct AgentRunNote: View {
    let run: AgentRun
    /// A run in the background, once its notice came.
    let ended: (status: String, milliseconds: Int?)?
    let size: Double

    var body: some View {
        Group {
            if run.background, let ended {
                let stopped = ["stopped", "killed"].contains(ended.status)
                Label((stopped ? "Stopped" : "In the background") + (ended.milliseconds.map { " · " + NoticeView.duration($0) } ?? ""),
                      systemImage: ended.status == "completed" ? "checkmark.circle" : stopped ? "stop.circle" : "xmark.octagon")
            } else if run.background {
                // No spinner: its notice may lie before the part of the conversation read.
                Text("In the background")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: .capsule)
            } else if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
            }
        }
        .font(.system(size: size * 0.78))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help([run.model.map(ClaudeModel.displayName), run.tokens.map { ContextChip.tokens($0) + " tokens" }].compactMap { $0 }.joined(separator: " · "))
    }

    private var parts: [String] {
        var out: [String] = []
        if let n = run.toolUses { out.append(n == 1 ? "1 tool" : "\(n) tools") }
        if let ms = run.milliseconds { out.append(NoticeView.duration(ms)) }
        return out
    }
}

/// The agent at work, as the Codex app says it: what it does, with light
/// passing over the words, and for how long since the person wrote.
///
/// While it moves, neither SwiftUI nor AppKit does any work. Drawn by
/// SwiftUI (the light 30 times a second, the time each second), each step
/// made SwiftUI go over every row of the conversation and AppKit lay out
/// the window again: 60 to 80 % of a core while the agent worked, even with
/// the conversation hidden behind another one, and scrolling stuttered.
/// Core Animation moves the light on its own; the time is a picture, drawn
/// again once a second while in sight.
struct WorkingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: String?
    /// When the turn started, in seconds since 1970.
    var since: Double?
    let size: Double

    var body: some View {
        // OpenCode's reason to wait before it tries again can be long.
        let words = message.flatMap { $0.isEmpty ? nil : $0 } ?? "Working"
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(words)
                // Reduce Motion: no light going over.
                .foregroundStyle(reduceMotion ? AnyShapeStyle(.secondary) : AnyShapeStyle(LightBand.dim))
                .lineLimit(2)
                .overlay {
                    if !reduceMotion {
                        RenderStandIn {
                            LightBand(words: words, size: size)
                        } standIn: {
                            EmptyView()
                        }
                    }
                }
            if let since {
                // Room for the longest time it may show; the time is drawn over it.
                Text("00h 00m 00s")
                    .monospacedDigit()
                    .hidden()
                    .overlay(alignment: .leading) {
                        RenderStandIn {
                            TurnClock(since: since, size: size)
                        } standIn: {
                            TurnClock.text(since: since, now: .now)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
            }
        }
        .font(.system(size: size))
    }
}

/// The band of light going over WorkingRow's words: once over in 1.6 s,
/// then again, from a bit before their start to a bit after their end. A
/// gradient layer cut to the words' shape by a picture of them, which Core
/// Animation moves on its own.
private struct LightBand: NSViewRepresentable {
    /// The words between two passes of light.
    static let dim = Color.primary.opacity(0.45)
    let words: String
    let size: Double

    func makeNSView(context: Context) -> LightBandView {
        LightBandView()
    }

    func updateNSView(_ view: LightBandView, context: Context) {
        // Over the dim words, so that the band's middle shows them at 95 %.
        let lit = Color.primary.opacity(0.5 / 0.55).resolve(in: context.environment).cgColor
        view.show(words: words, size: size, lit: lit)
    }
}

final class LightBandView: NSView {
    private let band = CAGradientLayer()
    private let shape = CALayer()
    private var words = ""
    private var size = 0.0
    /// What the shape was drawn for.
    private var drawn: (words: String, size: Double, bounds: CGSize, scale: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.locations = [-0.43, -0.25, -0.07]
        shape.contentsGravity = .resize
        band.mask = shape
        layer?.addSublayer(band)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(words: String, size: Double, lit: CGColor) {
        self.words = words
        self.size = size
        let clear = lit.copy(alpha: 0) ?? lit
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.colors = [clear, lit, clear]
        CATransaction.commit()
        drawShape()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = bounds
        shape.frame = band.bounds
        CATransaction.commit()
        drawShape()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        drawShape()
        move()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawShape()
    }

    /// The words as the row lays them out, drawn by SwiftUI itself, so that
    /// the band falls on them exactly.
    private func drawShape() {
        let scale = window?.backingScaleFactor ?? 2
        guard bounds.width > 0, bounds.height > 0, !words.isEmpty else { return }
        if let drawn, drawn.words == words, drawn.size == size, drawn.bounds == bounds.size, drawn.scale == scale { return }
        let renderer = ImageRenderer(content: Text(words)
            .font(.system(size: size))
            .lineLimit(2)
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading))
        renderer.scale = scale
        renderer.isOpaque = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.contents = renderer.cgImage
        shape.contentsScale = scale
        band.contentsScale = scale
        CATransaction.commit()
        drawn = (words, size, bounds.size, scale)
    }

    /// Over and over: Core Animation keeps it going, out of the app.
    private func move() {
        guard window != nil, band.animation(forKey: "light") == nil else { return }
        let pass = CABasicAnimation(keyPath: "locations")
        pass.fromValue = [-0.43, -0.25, -0.07]
        pass.toValue = [1.07, 1.25, 1.43]
        pass.duration = 1.6
        pass.repeatCount = .infinity
        pass.timingFunction = CAMediaTimingFunction(name: .linear)
        band.add(pass, forKey: "light")
    }

    /// Nothing here to click: clicks go to the conversation under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// How long since the turn started, drawn once a second into a layer of
/// its own while in sight: a SwiftUI clock made SwiftUI go over the whole
/// conversation each second.
private struct TurnClock: NSViewRepresentable {
    let since: Double
    let size: Double

    static func text(since: Double, now: Date) -> Text {
        Text(TurnHeader.duration(Int(max(0, now.timeIntervalSince1970 - since) * 1000)))
    }

    func makeNSView(context: Context) -> TurnClockView {
        TurnClockView()
    }

    func updateNSView(_ view: TurnClockView, context: Context) {
        view.show(since: since, size: size, scheme: context.environment.colorScheme)
    }
}

final class TurnClockView: NSView {
    private let picture = CALayer()
    private var since = 0.0
    private var size = 0.0
    private var scheme = ColorScheme.light
    private var timer: Timer?
    /// The time the picture shows.
    private var drawn = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        picture.contentsGravity = .resize
        layer?.addSublayer(picture)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(since: Double, size: Double, scheme: ColorScheme) {
        if since != self.since || size != self.size || scheme != self.scheme { drawn = "" }
        self.since = since
        self.size = size
        self.scheme = scheme
        tick()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = bounds
        CATransaction.commit()
        drawn = ""
        tick()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tick()
    }

    override func viewDidHide() {
        super.viewDidHide()
        tick()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        tick()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawn = ""
        tick()
    }

    /// Draws the time when it changed; the timer runs only while in sight.
    private func tick() {
        guard window != nil, !isHiddenOrHasHiddenAncestor else {
            timer?.invalidate()
            timer = nil
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                // Gone with its row: nothing left to draw.
                guard let self else { return timer.invalidate() }
                MainActor.assumeIsolated { self.tick() }
            }
            timer.tolerance = 0.1
            // Also while a scroll or a menu holds the run loop.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        let time = TurnHeader.duration(Int(max(0, Date().timeIntervalSince1970 - since) * 1000))
        guard time != drawn, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let renderer = ImageRenderer(content: Text(time)
            .font(.system(size: size))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(width: bounds.width, height: bounds.height, alignment: .leading)
            .environment(\.colorScheme, scheme))
        renderer.scale = scale
        renderer.isOpaque = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = renderer.cgImage
        picture.contentsScale = scale
        CATransaction.commit()
        drawn = time
    }

    /// Nothing here to click: clicks go to the conversation under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What tops a finished turn's answer, as in the Codex app: "Worked for
/// 1m 5s", with a chevron when the work folded under it opens; "You
/// stopped". A line under it when `ruled`.
struct TurnHeader: View {
    let text: String
    /// Whether the work under it shows; nil when nothing folds under it.
    var open: Bool?
    let size: Double
    var ruled = false
    var action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        if ruled {
            VStack(alignment: .leading, spacing: size * 0.6) {
                label
                TurnRule()
            }
        } else {
            label
        }
    }

    @ViewBuilder private var label: some View {
        let words = HStack(spacing: 5) {
            Text(text)
                .monospacedDigit()
            if let open {
                Image(systemName: "chevron.right")
                    .font(.system(size: size * 0.7, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
        }
        .font(.system(size: size * 0.95))
        .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        if let action {
            Button(action: action) {
                words.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        } else {
            words
        }
    }

    /// As the Codex app counts a turn's time: 18s, 1m 30s, 2h 41m 38s.
    static func duration(_ ms: Int) -> String {
        let total = max(1, Int((Double(ms) / 1000).rounded()))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return [h > 0 ? "\(h)h" : nil, m > 0 ? "\(m)m" : nil, s > 0 ? "\(s)s" : nil].compactMap { $0 }.joined(separator: " ")
    }
}

/// The line under a finished turn's header.
struct TurnRule: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(ChatStyle.rule(scheme))
            .frame(height: 1)
    }
}

extension ToolCall {
    /// A Read whose result is a picture: the Codex app says "Viewed".
    var viewsPicture: Bool { name == "Read" && (result?.images ?? 0) > 0 }
}
