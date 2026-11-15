import AppKit
import HerdrKit
import SwiftUI

/// What Claude asks while it waits, or a menu of its own while it doesn't,
/// as a card over the field: a form for its questions, the command or the
/// edit it asks permission for, its plan.
struct AskCard: View {
    let feed: TranscriptFeed
    let status: AgentStatus?
    let size: Double
    let folder: String
    let focusedPane: Bool
    let openTerminal: () -> Void

    private enum Kind {
        case question(ToolCall, [AskQuestion])
        case plan(ToolCall?)
        case permission(ToolCall?)
        case other
    }

    private var kind: Kind {
        // Codex's requests are read from its screen only.
        if feed.isCodex { return .other }
        // Gemini writes a call to its chat only once done: what it asks
        // for comes from its screen, the call too.
        if feed.isGemini {
            if let call = feed.prompt?.call { return .permission(call) }
            return status?.kind == "permission" ? .permission(nil) : .other
        }
        let calls = feed.openCalls
        if feed.isOpenCode {
            // OpenCode's status names no kind: the call it waits on says.
            if let call = calls.last(where: { $0.name == "AskUserQuestion" }) {
                let questions = AskQuestion.list(call.input)
                if !questions.isEmpty { return .question(call, questions) }
            }
            let asking = calls.last { $0.name != "AskUserQuestion" }
            return asking != nil || feed.prompt?.horizontal == true ? .permission(asking) : .other
        }
        if status?.kind == "question", let call = calls.last(where: { $0.name == "AskUserQuestion" }) {
            let questions = AskQuestion.list(call.input)
            if !questions.isEmpty { return .question(call, questions) }
        }
        let message = status?.message?.lowercased() ?? ""
        let planCall = calls.last { $0.name == "ExitPlanMode" }
        if message.contains("plan") || (planCall != nil && feed.prompt?.reviseOption != nil) { return .plan(planCall) }
        if status?.kind == "permission" { return .permission(Self.call(for: status?.message, in: calls)) }
        return .other
    }

    /// The call a permission is for: the tool its status names ("approve Bash: ls").
    static func call(for message: String?, in calls: [ToolCall]) -> ToolCall? {
        let asking = calls.filter { $0.name != "AskUserQuestion" && $0.name != "ExitPlanMode" }
        if let message, let colon = message.firstIndex(of: ":") {
            let tool = message[..<colon].split(separator: " ").last.map(String.init) ?? ""
            if let call = asking.first(where: { $0.name == tool || ToolRow.label($0.name) == tool }) { return call }
        }
        // A sub-agent asks for its own calls, never for the Agent call that runs it.
        return asking.first { $0.name != "Agent" && $0.name != "Task" }
    }

    /// Claude Code's AskUserQuestion on its screen: a question with its
    /// `Chat about this`, a tab bar, or the review of the answers.
    static func asksOnScreen(_ p: ScreenPrompt, agent: TranscriptFeed.Agent, status: AgentStatus?) -> Bool {
        guard agent == .claude, status?.kind == "question" else { return false }
        return p.isReview || p.shownQuestion != nil && (p.chatOption != nil || !p.tabs.isEmpty)
    }

    /// The tool a permission's status names: "approve Bash: ls" → "Bash".
    static func tool(in message: String?) -> String? {
        guard let message, let colon = message.firstIndex(of: ":") else { return nil }
        return message[..<colon].split(separator: " ").last.map(String.init)
    }

    var body: some View {
        Group {
            if status?.state == "blocked" {
                switch kind {
                case .question(let call, let questions):
                    QuestionCard(feed: feed, call: call.id, questions: questions, size: size, focusedPane: focusedPane, openTerminal: openTerminal)
                        .id(call.id)
                case .plan(let call):
                    PlanCard(feed: feed, call: call, size: size, focusedPane: focusedPane, openTerminal: openTerminal)
                        .id(call?.id ?? "plan")
                case .permission(let call):
                    PermissionCard(feed: feed, call: call, status: status, size: size, folder: folder, focusedPane: focusedPane, openTerminal: openTerminal)
                        .id(call?.id ?? "permission")
                case .other:
                    if let p = feed.prompt, Self.asksOnScreen(p, agent: feed.agent, status: status) {
                        // AskUserQuestion, its call not written yet.
                        ScreenQuestionCard(feed: feed, prompt: p, size: size, focusedPane: focusedPane, openTerminal: openTerminal)
                            .id(p.shownQuestion?.question ?? (p.isReview ? "review" : "question"))
                    } else {
                        ChoiceCard(feed: feed, prompt: feed.prompt, status: status, menu: false, size: size, focusedPane: focusedPane, openTerminal: openTerminal)
                    }
                }
            } else if let kind = feed.menus.kind {
                // `/effort`, `/model`, `/resume`: their card shows from the command on,
                // in a chip's popover when the chip opened the menu.
                if feed.menus.inPopover != kind {
                    ClaudeMenuCard(feed: feed, kind: kind, size: size, focusedPane: focusedPane, openTerminal: openTerminal)
                        .id(kind)
                }
            } else if let menu = feed.dialog, !feed.menus.closing {
                // Not while a menu's card closes: Claude's menu still shows a moment.
                ChoiceCard(feed: feed, prompt: menu, status: status, menu: true, size: size, focusedPane: focusedPane, openTerminal: openTerminal)
            }
        }
    }
}

// MARK: - Questions

/// AskUserQuestion's questions, one at a time as on Claude's screen: a
/// click on one of Claude's options answers it (or ticks its box), one's
/// own words go in the field under them. A lone question's answer goes at
/// once; several show their answers last, to submit together. Submit
/// answers them all on Claude's screen.
private struct QuestionCard: View {
    let feed: TranscriptFeed
    /// The AskUserQuestion call: the answers chosen stay with it in the
    /// feed while the pane shows its terminal.
    let call: String
    let questions: [AskQuestion]
    let size: Double
    let focusedPane: Bool
    let openTerminal: () -> Void
    /// The question shown; `questions.count`: the answers, to submit.
    @State private var page = 0
    /// The last move went forward: the next page comes in from the right.
    @State private var forward = true
    /// The person moved or answered here: answers read from Claude's
    /// screen no longer choose the page.
    @State private var touched = false
    @FocusState private var wordsFocused: Bool

    private var answers: [AskAnswer] {
        get { feed.askAnswers[call] ?? [] }
        nonmutating set { feed.askAnswers = [call: newValue] }
    }

    private var complete: Bool {
        answers.count == questions.count && answers.allSatisfy { !$0.isEmpty }
    }

    /// Several questions: their answers show together before they go.
    private var reviews: Bool { questions.count > 1 }
    private var reviewing: Bool { reviews && page >= questions.count }
    /// The question on the page, also under the review's.
    private var shownIndex: Int { min(page, questions.count - 1) }

    private func answered(at i: Int) -> Bool {
        answers.indices.contains(i) && !answers[i].isEmpty
    }

    /// Where the card opens: the first question without an answer, else
    /// the answers (the first question when it is the only one).
    private var firstOpen: Int {
        questions.indices.first { !answered(at: $0) } ?? (reviews ? questions.count : 0)
    }

    private var steps: [StepPills.Step] {
        questions.indices.map { i in
            let header = questions[i].header.trimmingCharacters(in: .whitespaces)
            return StepPills.Step(title: header.isEmpty ? "Question \(i + 1)" : header, answered: answered(at: i))
        } + [StepPills.Step(title: "Submit", answered: complete, isSubmit: true)]
    }

    var body: some View {
        CardFrame(tint: .blue) {
            CardHeader(title: questions.count == 1 ? "\(feed.agentName) has a question" : "\(feed.agentName) has \(questions.count) questions",
                       symbol: "questionmark.bubble.fill", tint: .blue, size: size, openTerminal: openTerminal)
            if reviews {
                StepPills(steps: steps, current: min(page, questions.count), size: size) { go(to: $0) }
            }
            // The page that goes fades out at once; the one that comes slides in.
            ZStack(alignment: .topLeading) {
                Group {
                    if reviewing {
                        review
                    } else {
                        QuestionForm(question: questions[shownIndex], answer: answer(shownIndex), size: size,
                                     showsHeader: !reviews, wordsFocused: $wordsFocused)
                        {
                            answeredHere(shownIndex)
                        }
                    }
                }
                .id(page)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 28 : -28)).animation(.snappy(duration: 0.25).delay(0.05)),
                                        removal: .opacity.animation(.easeOut(duration: 0.08))))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ActionProblem(feed: feed, size: size)
            footer
        }
        .animation(.snappy(duration: 0.25), value: page)
        .modifier(CardKeys(feed: feed, focusedPane: focusedPane, digit: pickByDigit, escape: {
            Task { await feed.escape() }
            return true
        }, enter: enterPressed, left: {
            guard page > 0 else { return false }
            go(to: page - 1)
            return true
        }, right: {
            guard reviews, page < questions.count else { return false }
            go(to: page + 1)
            return true
        }))
        .onAppear {
            if answers.count != questions.count { answers = Array(repeating: AskAnswer(), count: questions.count) }
            page = firstOpen
            // Answered in the terminal meanwhile: here too.
            Task {
                await feed.readAnswers(questions, call: call)
                if !touched { page = firstOpen }
            }
        }
        // Shown again after the terminal (`ConversationContainer` keeps the view).
        .onChange(of: feed.shows) {
            Task { await feed.readAnswers(questions, call: call) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // OpenCode has no "Chat about this".
            if !feed.isOpenCode {
                Button("Chat About This") {
                    let q = questions[shownIndex]
                    Task { try? await feed.chatInstead(q) }
                }
                .help("No answer: write to \(feed.agentName) instead")
            }
            Button(feed.isOpenCode ? "Dismiss" : "Skip") {
                Task { await feed.escape() }
            }
            .help(feed.isOpenCode ? "OpenCode goes on without an answer (Esc)" : "\(feed.agentName) goes on without an answer (Esc)")
            Spacer()
            if feed.acting { ProgressView().controlSize(.small) }
            if reviews, page > 0 {
                Button { go(to: page - 1) } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .help("The question before (←)")
            }
            if !reviews || reviewing {
                Button(reviews ? "Submit Answers" : "Submit", action: submit)
                    .buttonStyle(.glassProminent)
                    .disabled(!complete || feed.acting)
                    .help(complete ? "Send the answers (↩)" : "Answer every question first")
            } else if answered(at: page) {
                Button { go(to: page + 1) } label: {
                    nextLabel
                }
                .buttonStyle(.glassProminent)
                .help("On to the next step (↩)")
            } else {
                Button { go(to: page + 1) } label: {
                    nextLabel
                }
                .help("On to the next step without an answer here (→)")
            }
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
        .font(.system(size: size * 0.9))
    }

    private var nextLabel: some View {
        HStack(spacing: 4) {
            Text(page == questions.count - 1 ? "Review" : "Next")
            Image(systemName: "chevron.right")
        }
    }

    /// The questions and the answers chosen, to look over before they go:
    /// a click on one goes back to its question.
    private var review: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review your answers")
                .font(.system(size: size * 1.02, weight: .medium))
            VStack(spacing: 2) {
                ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                    let words = answers.indices.contains(i) ? Self.said(answers[i]) : ""
                    Button { go(to: i) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.question)
                                .font(.system(size: size * 0.84))
                                .foregroundStyle(.secondary)
                            Label(words.isEmpty ? "No answer yet" : words, systemImage: words.isEmpty ? "circle.dashed" : "arrow.turn.down.right")
                                .font(.system(size: size * 0.95, weight: words.isEmpty ? .regular : .medium))
                                .foregroundStyle(words.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(CardRowStyle())
                    .help("Change this answer")
                }
            }
        }
    }

    /// An answer as words: the options chosen, then one's own.
    static func said(_ a: AskAnswer) -> String {
        (a.chosen + (a.text.isEmpty ? [] : ["“\(a.text)”"])).joined(separator: ", ")
    }

    private func answer(_ i: Int) -> Binding<AskAnswer> {
        Binding(get: { answers.indices.contains(i) ? answers[i] : AskAnswer() }, set: { if answers.indices.contains(i) { answers[i] = $0 } })
    }

    private func go(to target: Int) {
        let to = min(max(target, 0), reviews ? questions.count : questions.count - 1)
        touched = true
        guard to != page else { return }
        forward = to > page
        wordsFocused = false
        page = to
    }

    /// Question `i` got its answer here (one option, or one's own words
    /// with ↩): a lone one's goes at once, as on Claude's screen; else, a
    /// moment on the answer, then the next step.
    private func answeredHere(_ i: Int) {
        touched = true
        guard reviews else {
            if !questions[i].multiSelect { submit() }
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            if page == i { go(to: i + 1) }
        }
    }

    /// A digit picks the option it numbers, as on Claude's screen; the one
    /// after the last opens the field for one's own words. On the review,
    /// 1 submits.
    private func pickByDigit(_ n: Int) -> Bool {
        guard !feed.acting else { return false }
        if reviewing {
            guard n == 1, complete else { return false }
            submit()
            return true
        }
        let i = shownIndex
        let q = questions[i]
        if n == q.options.count + 1 {
            wordsFocused = true
            return true
        }
        guard q.options.indices.contains(n - 1) else { return false }
        var a = answers.indices.contains(i) ? answers[i] : AskAnswer()
        let label = q.options[n - 1].label
        if q.multiSelect {
            if let at = a.chosen.firstIndex(of: label) { a.chosen.remove(at: at) } else { a.chosen.append(label) }
            answer(i).wrappedValue = a
        } else {
            answer(i).wrappedValue = AskAnswer(chosen: [label])
            answeredHere(i)
        }
        return true
    }

    /// ↩: the answers go from the last step; else the next step, once this one has its answer.
    private func enterPressed() -> Bool {
        if !reviews || reviewing {
            guard complete else { return false }
            submit()
            return true
        }
        guard answered(at: page) else { return false }
        go(to: page + 1)
        return true
    }

    private func submit() {
        guard complete, !feed.acting else { return }
        let qs = questions
        let given = answers
        Task { try? await feed.answer(qs, given) }
    }
}

/// One question: its text, Claude's options and a field for one's own.
private struct QuestionForm: View {
    let question: AskQuestion
    @Binding var answer: AskAnswer
    let size: Double
    /// Its header over it: a lone question has no steps to show it in.
    let showsHeader: Bool
    var wordsFocused: FocusState<Bool>.Binding
    /// One option chosen (a single choice), or one's own words given with ↩.
    let answered: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader, !question.header.isEmpty {
                Text(question.header)
                    .font(.system(size: size * 0.74, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.16), in: .capsule)
            }
            Text(question.question)
                .font(.system(size: size * 1.02, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if question.multiSelect {
                Text("Choose any.")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
            }
            RenderScroll {
                VStack(spacing: 2) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { j, choice in
                        ChoiceRow(number: j + 1, label: choice.label, detail: choice.detail,
                                  selected: answer.chosen.contains(choice.label), multi: question.multiSelect, size: size)
                        {
                            toggle(choice.label)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            OwnAnswerRow(text: $answer.other, selected: !answer.text.isEmpty, multi: question.multiSelect, size: size, focused: wordsFocused) {
                // One choice only: one's own words replace Claude's options.
                if !question.multiSelect, !answer.text.isEmpty { answer.chosen = [] }
            } submit: {
                if !answer.text.isEmpty { answered() }
            }
        }
    }

    private func toggle(_ label: String) {
        if question.multiSelect {
            if let i = answer.chosen.firstIndex(of: label) { answer.chosen.remove(at: i) } else { answer.chosen.append(label) }
        } else {
            answer.chosen = [label]
            answer.other = ""
            answered()
        }
    }
}

private struct ChoiceRow: View {
    let number: Int?
    let label: String
    let detail: String
    let selected: Bool
    let multi: Bool
    let size: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let number, !multi {
                    CardKeyCap(key: "\(number)", size: size, active: selected)
                } else {
                    Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .font(.system(size: size * 0.95))
                        .frame(minWidth: size * 1.4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: size * 0.95, weight: selected ? .medium : .regular))
                    // A detail that only says the label again ("Red", "Red") adds nothing.
                    if !detail.isEmpty, detail.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(label) != .orderedSame {
                        Text(detail)
                            .font(.system(size: size * 0.82))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if selected, !multi {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.85, weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Chosen")
                }
            }
        }
        .buttonStyle(CardRowStyle(selected: selected))
    }
}

/// "Type something": the person's own answer. ↩ gives it.
private struct OwnAnswerRow: View {
    @Binding var text: String
    let selected: Bool
    let multi: Bool
    let size: Double
    var focused: FocusState<Bool>.Binding
    let edited: () -> Void
    let submit: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "pencil.line")
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .font(.system(size: size * 0.95))
            TextField(multi ? "Something else…" : "Or answer in your own words…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: size * 0.95))
                .lineLimit(1 ... 4)
                .focused(focused)
                .onChange(of: text) { edited() }
                .onSubmit(submit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
    }
}

// MARK: - Permissions

/// A tool Claude wants to run: what it would do, Claude Code's options as
/// buttons, and a field to say what to do instead.
private struct PermissionCard: View {
    @Environment(\.codeFamily) private var codeFamily
    let feed: TranscriptFeed
    let call: ToolCall?
    let status: AgentStatus?
    let size: Double
    let folder: String
    let focusedPane: Bool
    let openTerminal: () -> Void
    @State private var note = ""
    @State private var choosing: Int?
    /// The call a sub-agent asks about, from its own transcript.
    @State private var subagentCall: ToolCall?

    var body: some View {
        let p = feed.prompt
        CardFrame(tint: .orange) {
            CardHeader(title: feed.isOpenCode ? "OpenCode asks for permission" : p?.title ?? "\(feed.agentName) asks for permission",
                       symbol: "hand.raised.fill", tint: .orange, size: size, openTerminal: openTerminal)
            if let call = call ?? subagentCall {
                RenderScroll {
                    CallPreview(call: call, size: size, folder: folder)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            } else if let diff = p?.screenDiff {
                // The edit as Claude Code's box draws it, until its call is in the transcript.
                VStack(alignment: .leading, spacing: 6) {
                    if let file = diff.file {
                        Label {
                            Text(file)
                                .font(CodeFont.font(size * 0.88, family: codeFamily))
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                        }
                        .font(.system(size: size * 0.88))
                    }
                    DiffView(lines: diff.lines, size: size)
                }
            } else if let p, p.context.count > 1 {
                // Claude Code's tips ("Tip: auto mode handles these prompts…") aren't what it asks.
                let lines = p.context.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("Tip:") }
                Monospaced(text: lines.joined(separator: "\n").trimmingCharacters(in: .newlines), maxLines: 18, total: nil, size: size, tint: nil)
            }
            if let p {
                if !p.questionText.isEmpty {
                    // `find with '-exec' executes commands…`, then `Do you want to proceed?`:
                    // why Claude Code asks, then what.
                    let parts = p.questionText.components(separatedBy: "\n\n")
                    if parts.count > 1 {
                        Label(parts.dropLast().joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                            .font(.system(size: size * 0.88))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(parts.last ?? p.questionText)
                        .font(.system(size: size * 0.95, weight: .medium))
                }
                VStack(spacing: 5) {
                    ForEach(p.options) { option in
                        OptionRow(option: option, numbered: p.numbered, busy: choosing == option.number, size: size) { pick(option, in: p) }
                            .disabled(feed.acting)
                    }
                }
                if p.canAmend {
                    NoteField(placeholder: "Or tell Claude what to do instead…", text: $note, busy: feed.acting, size: size) {
                        let text = note
                        Task {
                            try? await feed.refuse(text)
                            if feed.actionError == nil { note = "" }
                        }
                    }
                }
            } else {
                WaitingLine(feed: feed, status: status, size: size)
            }
            ActionProblem(feed: feed, size: size)
        }
        .modifier(CardKeys(feed: feed, focusedPane: focusedPane, digit: { n in
            guard let p = feed.prompt, let option = p.options.first(where: { $0.number == n }) else { return false }
            pick(option, in: p)
            return true
        }, escape: {
            guard let p = feed.prompt, let no = p.refusal else { return false }
            pick(no, in: p)
            return true
        }))
        .task(id: p?.title ?? "") {
            // `Bash command · from the Explore agent`: the call is in that sub-agent's transcript.
            guard call == nil, !feed.isOpenCode, let title = p?.title, title.contains("from the"),
                  let tool = AskCard.tool(in: status?.message)
            else {
                subagentCall = nil
                return
            }
            subagentCall = await feed.subagentCall(named: tool)
        }
    }

    private func pick(_ option: ScreenPrompt.Option, in p: ScreenPrompt) {
        guard choosing == nil, !feed.acting else { return }
        choosing = option.number
        Task {
            await feed.choose(option, in: p)
            choosing = nil
        }
    }
}

/// What a tool call would do: the command, the edit, the file, the page.
struct CallPreview: View {
    @Environment(\.codeFamily) private var codeFamily
    let call: ToolCall
    let size: Double
    let folder: String

    var body: some View {
        let i = call.input
        VStack(alignment: .leading, spacing: 6) {
            switch call.name {
            case "Bash", "PowerShell", "Shell":
                if let d = i["description"]?.string, !d.isEmpty {
                    Text(d).font(.system(size: size * 0.9)).foregroundStyle(.secondary)
                }
                Monospaced(text: "$ " + (i["command"]?.string ?? ""), maxLines: 20, total: nil, size: size, tint: nil)
            case "Edit":
                path(i["file_path"]?.string)
                if let diff = i["diff"]?.string {
                    // Gemini's and OpenCode's: the change as a patch.
                    PatchView(diff: diff, size: size)
                } else {
                    DiffView(old: i["old_string"]?.string ?? "", new: i["new_string"]?.string ?? "", size: size)
                }
            case "MultiEdit":
                path(i["file_path"]?.string)
                ForEach(Array((i["edits"]?.array ?? []).prefix(6).enumerated()), id: \.offset) { _, edit in
                    DiffView(old: edit["old_string"]?.string ?? "", new: edit["new_string"]?.string ?? "", size: size)
                }
            case "Write":
                path(i["file_path"]?.string)
                Monospaced(text: i["content"]?.string ?? "", maxLines: 24, total: nil, size: size, tint: nil)
            case "NotebookEdit":
                path(i["notebook_path"]?.string)
                Monospaced(text: i["new_source"]?.string ?? "", maxLines: 20, total: nil, size: size, tint: nil)
            case "Read":
                path(i["file_path"]?.string)
            case "WebFetch":
                labelled("globe", i["url"]?.string ?? "")
                if let prompt = i["prompt"]?.string, !prompt.isEmpty {
                    Text(prompt).font(.system(size: size * 0.88)).foregroundStyle(.secondary)
                }
            case "WebSearch":
                labelled("magnifyingglass", i["query"]?.string ?? "")
            case "Glob", "Grep":
                labelled("magnifyingglass", [i["pattern"]?.string, i["path"]?.string.map(short)].compactMap { $0 }.joined(separator: "  in  "))
            case "Skill":
                labelled("sparkles", i["skill"]?.string ?? "")
            case "Agent", "Task":
                if let d = i["description"]?.string { labelled("person.2", d) }
                if let prompt = i["prompt"]?.string {
                    Monospaced(text: prompt, maxLines: 12, total: nil, size: size, tint: nil)
                }
            default:
                labelled(ToolRow.symbol(call.name), ToolRow.label(call.name))
                if case .object(let fields) = i, !fields.isEmpty {
                    Monospaced(text: String(decoding: i.data(pretty: true), as: UTF8.self), maxLines: 16, total: nil, size: size, tint: nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func path(_ p: String?) -> some View {
        labelled("doc.text", short(p ?? ""))
    }

    private func labelled(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(CodeFont.font(size * 0.88, family: codeFamily))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(.system(size: size * 0.88))
    }

    private func short(_ s: String) -> String {
        if !folder.isEmpty, s.hasPrefix(folder + "/") { return String(s.dropFirst(folder.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if s.hasPrefix(home + "/") { return "~" + s.dropFirst(home.count) }
        return s
    }
}

// MARK: - Plans

/// ExitPlanMode: the plan, to approve one way or another or send back with a note.
private struct PlanCard: View {
    let feed: TranscriptFeed
    let call: ToolCall?
    let size: Double
    let focusedPane: Bool
    let openTerminal: () -> Void
    @State private var note = ""
    @State private var choosing: Int?
    @State private var tall = false

    var body: some View {
        let p = feed.prompt
        let plan = call?.input["plan"]?.string ?? p.map { $0.context.dropFirst().joined(separator: "\n") } ?? ""
        CardFrame(tint: .purple) {
            HStack {
                CardHeader(title: "Claude's plan is ready", symbol: "list.bullet.clipboard.fill", tint: .purple, size: size, openTerminal: openTerminal)
            }
            if !plan.isEmpty {
                RenderScroll {
                    MarkdownView(plan, size: size * 0.92)
                        .padding(12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: tall ? 640 : 300)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    Button(tall ? "Less" : "More", systemImage: tall ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                        withAnimation(.snappy(duration: 0.2)) { tall.toggle() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(8)
                    .help(tall ? "Show less of the plan" : "Show more of the plan")
                }
            }
            if let p {
                if !p.questionText.isEmpty, !p.questionText.contains("\n") {
                    Text(p.questionText).font(.system(size: size * 0.95, weight: .medium))
                }
                VStack(spacing: 5) {
                    ForEach(p.options.filter { $0.number != p.reviseOption?.number }) { option in
                        OptionRow(option: option, numbered: p.numbered, busy: choosing == option.number, size: size) { pick(option, in: p) }
                            .disabled(feed.acting)
                    }
                }
                if p.reviseOption != nil {
                    NoteField(placeholder: "Tell Claude what to change…", text: $note, busy: feed.acting, size: size) {
                        let text = note
                        Task {
                            try? await feed.revisePlan(text)
                            if feed.actionError == nil { note = "" }
                        }
                    }
                }
            } else {
                WaitingLine(feed: feed, status: nil, size: size)
            }
            ActionProblem(feed: feed, size: size)
        }
        .modifier(CardKeys(feed: feed, focusedPane: focusedPane, digit: { n in
            guard let p = feed.prompt, let option = p.options.first(where: { $0.number == n }), option.number != p.reviseOption?.number else { return false }
            pick(option, in: p)
            return true
        }, escape: { false }))
    }

    private func pick(_ option: ScreenPrompt.Option, in p: ScreenPrompt) {
        guard choosing == nil, !feed.acting else { return }
        choosing = option.number
        Task {
            await feed.choose(option, in: p)
            choosing = nil
        }
    }
}

// MARK: - Anything else

/// What Claude's screen shows as a choice: a sign-in, a folder to trust,
/// one of its menus (`/model`, "Switch model?").
private struct ChoiceCard: View {
    let feed: TranscriptFeed
    let prompt: ScreenPrompt?
    let status: AgentStatus?
    /// One of Claude Code's own menus, while it isn't blocked.
    let menu: Bool
    let size: Double
    let focusedPane: Bool
    let openTerminal: () -> Void
    @State private var choosing: Int?

    /// A menu's name: its box's first line, else the first line over its
    /// options (`Memory`); without its colon (`Accessing workspace:`).
    private var menuTitle: String? {
        guard let p = prompt,
              let name = p.title ?? p.question.lazy.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        return name.hasSuffix(":") ? String(name.dropLast()) : name
    }

    /// Claude Code's first question in a folder it hasn't worked in.
    private var asksTrust: Bool {
        prompt?.options.contains { $0.label.localizedCaseInsensitiveContains("trust this folder") } ?? false
    }

    private var title: String {
        let name = feed.agentName
        if menu { return menuTitle ?? (feed.agent == .claude ? "Claude Code asks" : "\(name) asks") }
        switch status?.kind {
        case "question": return "\(name) has a question for you"
        case "auth": return "\(name) needs to sign in again"
        default: return prompt?.title ?? "\(name) asks for permission"
        }
    }

    var body: some View {
        CardFrame(tint: menu ? .gray : .orange) {
            CardHeader(title: title, symbol: asksTrust ? "folder.badge.questionmark" : menu ? "list.bullet.rectangle" : "hand.raised.fill",
                       tint: menu ? .secondary : .orange, size: size, openTerminal: openTerminal)
            if let p = prompt {
                // A menu's name is the card's title.
                let gemini = feed.isGemini && !menu && p.context.first == "Answer Questions"
                let question = menu && p.title == nil ? Array(p.question.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.dropFirst()) : p.question
                // Codex's `Question 1/2 (2 unanswered)`: a caption, when it asks several.
                let count = feed.isCodex ? (p.context + question).lazy.compactMap(ScreenPrompt.codexQuestionCount).first : nil
                let uncounted = { (lines: [String]) in count == nil ? lines : lines.filter { ScreenPrompt.codexQuestionCount($0) == nil } }
                // Gemini's `Answer Questions` says what the card's title says.
                let paragraphs = ScreenParagraph.split((menu || gemini ? Array(p.context.dropFirst()) : uncounted(p.context)) + [""] + uncounted(question))
                if gemini, !p.tabs.isEmpty {
                    GeminiTabs(tabs: p.tabs, size: size)
                }
                if let count, count.total > 1 {
                    Text("Question \(count.index) of \(count.total)")
                        .font(.system(size: size * 0.8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                let approval = feed.isCodex && !menu ? p.codexApproval : nil
                if let rewind = p.rewindDetails {
                    RewindDetailsView(details: rewind, size: size)
                } else if let approval {
                    CodexApprovalView(approval: approval, size: size)
                } else if !paragraphs.isEmpty {
                    RenderScroll {
                        ScreenText(paragraphs: paragraphs, size: size)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 240)
                    .fixedSize(horizontal: false, vertical: true)
                }
                // A long list (one of OpenCode's pickers) scrolls.
                RenderScroll {
                    VStack(spacing: 5) {
                        // Gemini's own answer goes in the field under the options.
                        ForEach(gemini ? p.options.filter { $0.number != p.customOption && $0.label != GeminiAnswer.custom } : p.options) { option in
                            OptionRow(option: option, numbered: p.numbered,
                                      busy: choosing == option.number, size: size, checkbox: gemini && option.checked != nil) { pick(option, in: p) }
                                .disabled(feed.acting)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                if gemini {
                    GeminiAnswer(feed: feed, prompt: p, size: size)
                } else if feed.isCodex, !menu, status?.kind == "question", let option = feed.noteOption(p) {
                    CodexNote(feed: feed, prompt: p, option: option, size: size)
                }
                HStack {
                    // Keys for the program's terminal (`esc to interrupt`,
                    // `Tab to amend`): here the buttons do.
                    if !p.footer.isEmpty, approval == nil, !ScreenPrompt.isKeyHint(p.footer) {
                        // A hint, or a warning (`/rewind`'s second step).
                        Text(p.footer)
                            .font(.system(size: size * 0.78))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    // Several answers ticked: Gemini's `Done` sends them, or
                    // keeps them and shows the next question.
                    if gemini, p.hasSubmitLine {
                        Button("Done") { Task { try? await feed.doneGemini() } }
                            .buttonStyle(.glass)
                            .disabled(feed.acting)
                            .help(p.tabs.count > 1 ? "Gemini's Done: keeps these answers, then the next question" : "Gemini's Done: sends the answers ticked")
                    } else if gemini, p.options.contains(where: { $0.checked != nil }), p.tabs.count > 1 {
                        // `Done` out of sight: they go with the next question (→).
                        Button("Next Question") { Task { try? await feed.nextGeminiQuestion() } }
                            .buttonStyle(.glass)
                            .disabled(feed.acting)
                            .help("→ on Gemini's screen")
                    }
                    Button(p.options.isEmpty && !p.takesText ? "Close" : "Cancel") { Task { await feed.escape() } }
                        .buttonStyle(.glass)
                        .help("Esc on \(feed.agentName)'s screen")
                }
            } else {
                WaitingLine(feed: feed, status: status, size: size)
            }
            ActionProblem(feed: feed, size: size)
        }
        .modifier(CardKeys(feed: feed, focusedPane: focusedPane && !menu, digit: { n in
            guard let p = prompt, p.numbered, let option = p.options.first(where: { $0.number == n }) else { return false }
            pick(option, in: p)
            return true
        }, escape: {
            Task { await feed.escape() }
            return true
        }))
    }

    private func pick(_ option: ScreenPrompt.Option, in p: ScreenPrompt) {
        guard choosing == nil, !feed.acting else { return }
        choosing = option.number
        Task {
            await feed.choose(option, in: p)
            choosing = nil
        }
    }
}

// MARK: - Claude Code's model picker

/// Gemini's questions, one at a time: a tab for each over the options,
/// ticked once answered, Review last.
private struct GeminiTabs: View {
    let tabs: [ScreenPrompt.Tab]
    let size: Double

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                Label(tab.title, systemImage: tab.isSubmit ? "list.bullet" : tab.answered ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(tab.answered ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
    }
}

/// Under Gemini's options: a field for an answer in words, for a question
/// that takes one or offers `Enter a custom value`. Its words follow onto
/// Gemini's screen and back (`TranscriptFeed.cardWords`).
private struct GeminiAnswer: View {
    static let custom = "Enter a custom value"
    let feed: TranscriptFeed
    let prompt: ScreenPrompt
    let size: Double

    var body: some View {
        let custom = prompt.customOption.flatMap { n in prompt.options.first { $0.number == n } }
            ?? prompt.options.first { $0.label == Self.custom }
        if prompt.takesText || custom != nil {
            let key = feed.cardWordsKey(prompt)
            let text = Binding(get: { feed.cardWords[key] ?? "" }, set: { feed.cardWords[key] = $0 })
            NoteField(placeholder: prompt.takesText ? "Your answer…" : "Or type your own answer…", text: text, busy: feed.acting, size: size) {
                let typed = text.wrappedValue
                Task {
                    try? await feed.answerGemini(typed, custom: custom)
                    if feed.actionError == nil { feed.cardWords[key] = nil }
                }
            }
        }
    }
}

/// Codex's question in one's own words: a note on its `None of the above`
/// (Tab on Codex's screen opens one under an option), then Enter. Its
/// words follow onto Codex's screen and back (`TranscriptFeed.cardWords`);
/// notes typed there under another option come back with it, named over
/// the field, until the field empties.
private struct CodexNote: View {
    let feed: TranscriptFeed
    let prompt: ScreenPrompt
    let option: ScreenPrompt.Option
    let size: Double

    var body: some View {
        let key = feed.cardWordsKey(prompt)
        let text = Binding(get: { feed.cardWords[key] ?? "" }, set: {
            feed.cardWords[key] = $0
            if $0.isEmpty, feed.cardNoteOn[key] != nil { feed.cardNoteOn[key] = nil }
        })
        let other = !option.label.hasPrefix("None of the above")
        VStack(alignment: .leading, spacing: 4) {
            if other {
                Text("Note on “\(option.label)”")
                    .font(.system(size: size * 0.78))
                    .foregroundStyle(.secondary)
            }
            NoteField(placeholder: "Or type your own answer…", text: text, busy: feed.acting, size: size) {
                let typed = text.wrappedValue
                Task {
                    try? await feed.answerCodex(option, note: typed, in: prompt)
                    if feed.actionError == nil {
                        feed.cardWords[key] = nil
                        feed.cardNoteOn[key] = nil
                    }
                }
            }
        }
    }
}

/// Text from a program's screen as paragraphs: words in the system font,
/// wrapped to the card; paths, commands and columns in the code font, as
/// the screen drew them.
struct ScreenText: View {
    @Environment(\.codeFamily) private var codeFamily
    let paragraphs: [ScreenParagraph]
    let size: Double

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.6) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                Text(p.text)
                    .font(p.prose ? .system(size: size * 0.92) : CodeFont.font(size * 0.85, family: codeFamily))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Codex's approval prompt as Claude's permission cards show theirs: why
/// it asks, what it would run, then the question over the answers.
private struct CodexApprovalView: View {
    let approval: ScreenPrompt.CodexApproval
    let size: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = approval.reason {
                Text(reason)
                    .font(.system(size: size * 0.9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let command = approval.command {
                Monospaced(text: "$ " + command, maxLines: 20, total: nil, size: size, tint: nil)
            }
            // `Environment: local`: where it runs, said in words.
            let environment = approval.details.filter { $0.hasPrefix("Environment: ") }
            let rest = approval.details.filter { !$0.hasPrefix("Environment: ") }
            if !rest.isEmpty {
                Monospaced(text: rest.joined(separator: "\n"), maxLines: 16, total: nil, size: size, tint: nil)
            }
            ForEach(environment, id: \.self) { line in
                Text(line)
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
            }
            Text(approval.question)
                .font(.system(size: size * 0.95, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `/rewind`'s second step as prose: what it asks, the message in a quote,
/// and what restoring does, its line counts in green and red.
private struct RewindDetailsView: View {
    let details: ScreenPrompt.RewindDetails
    let size: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let intro = details.intro {
                Text(intro)
                    .foregroundStyle(.secondary)
            }
            if !details.message.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    Capsule()
                        .fill(.tint)
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(details.message.joined(separator: " "))
                            .lineLimit(4)
                        if let ago = details.ago {
                            Text(ago)
                                .font(.system(size: size * 0.78))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(details.notes.enumerated()), id: \.offset) { _, note in
                Self.counted(note)
            }
        }
        .font(.system(size: size * 0.9))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "restored +1 -1 in code.txt" with +1 green and -1 red.
    static func counted(_ line: String) -> Text {
        var out = Text("")
        for (i, word) in line.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let w = String(word)
            let isCount = w.count > 1 && w.dropFirst().allSatisfy(\.isNumber)
            var t = Text((i == 0 ? "" : " ") + w)
            if isCount, w.hasPrefix("+") { t = t.foregroundStyle(.readable(.green)) } else if isCount, w.hasPrefix("-") { t = t.foregroundStyle(.readable(.red)) }
            out = Text("\(out)\(t)")
        }
        return out
    }
}

// MARK: - Codex: back to an earlier message

/// Codex browsing its transcript to go back (Esc Esc): the person's
/// messages, newest first. The one picked and all after it leave the
/// conversation; its words come back to the field. Files stay as they are.
struct CodexRewindCard: View {
    let feed: TranscriptFeed
    let size: Double
    let focusedPane: Bool
    let openTerminal: () -> Void
    @State private var choosing: String?

    var body: some View {
        let prompts = Array(feed.codexPrompts.reversed())
        CardFrame(tint: .gray) {
            CardHeader(title: "Go back to an earlier message", symbol: "arrow.uturn.backward.circle", tint: .secondary,
                       size: size, terminalLabel: "Choose in Terminal", openTerminal: openTerminal)
            Text("Codex forgets the message you pick and everything after it; its words come back to the field. Files stay as they are.")
                .font(.system(size: size * 0.82))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RenderScroll {
                VStack(spacing: 5) {
                    ForEach(Array(prompts.enumerated()), id: \.element.id) { i, p in
                        OptionRow(option: .init(number: i + 1, label: Self.line(p.text)), numbered: i < 9,
                                  busy: choosing == p.id, size: size) { pick(p.id) }
                            .disabled(feed.acting)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { Task { await feed.closeCodexBacktrack() } }
                    .buttonStyle(.glass)
                    .help("Esc on Codex's screen")
            }
            ActionProblem(feed: feed, size: size)
        }
        .modifier(CardKeys(feed: feed, focusedPane: focusedPane, digit: { n in
            guard (1 ... min(9, prompts.count)).contains(n) else { return false }
            pick(prompts[n - 1].id)
            return true
        }, escape: {
            Task { await feed.closeCodexBacktrack() }
            return true
        }))
    }

    /// A message as one line, cut when long.
    static func line(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > 160 ? String(words.prefix(159)) + "…" : words
    }

    private func pick(_ id: String) {
        guard choosing == nil, !feed.acting else { return }
        choosing = id
        Task {
            await feed.codexRewind(to: id)
            choosing = nil
        }
    }
}

// MARK: - Pieces

/// A card over the field: Liquid Glass, as round as the Codex app's
/// cards; a faint tint in the card's color says what kind it is. In a
/// popover, whose own glass is the card's.
struct CardFrame<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content
    @Environment(\.cardInPopover) private var inPopover

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(inPopover ? 16 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        if inPopover {
            card
        } else {
            card
                .paneGlass(.regular.tint(tint.opacity(0.12)), in: .rect(cornerRadius: 22))
                .padding(.horizontal, 16)
                .padding(.top, 6)
        }
    }
}

extension EnvironmentValues {
    /// The card shows in a popover (a chip's), not over the field.
    @Entry var cardInPopover = false
}

struct CardHeader: View {
    let title: String
    /// A line under the title: what the card is about.
    var subtitle: String?
    /// The subtitle isn't known yet: blank, in the place it will take.
    var subtitlePending = false
    let symbol: String
    let tint: Color
    let size: Double
    /// What the terminal button does, said on it.
    var terminalLabel = "Answer in Terminal"
    let openTerminal: () -> Void

    var body: some View {
        // `Read file      1 of 2`: Claude Code's count of the prompts waiting, apart.
        let count = title.firstMatch(of: /^(.*?) {2,}(\d+ of \d+)$/)
        HStack(alignment: .center, spacing: 10) {
            CardBadge(symbol: symbol, tint: tint == .secondary ? .gray : tint, size: size)
            VStack(alignment: .leading, spacing: 1) {
                Text(count.map { String($0.1) } ?? title)
                    .font(.system(size: size, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: size * 0.8))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .redacted(reason: subtitlePending ? .placeholder : [])
                }
            }
            Spacer(minLength: 8)
            if let count {
                Text(count.2)
                    .font(.system(size: size * 0.82).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Claude asks for more than one thing")
            }
            Button(terminalLabel, systemImage: "terminal", action: openTerminal)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: size * 0.9))
                .help(terminalLabel)
        }
    }
}

/// One of Claude Code's numbered options as a button.
struct OptionRow: View {
    let option: ScreenPrompt.Option
    let numbered: Bool
    let busy: Bool
    let size: Double
    /// One of several answers to tick (Gemini's), its box drawn checked or not.
    var checkbox = false
    let action: () -> Void

    /// `Yes, and don't ask again for commands that start with `touch x``:
    /// what is between backticks in the code font.
    static func codeSpans(_ label: String) -> AttributedString {
        let pieces = label.split(separator: "`", omittingEmptySubsequences: false)
        guard pieces.count >= 3, pieces.count % 2 == 1 else { return AttributedString(label) }
        var out = AttributedString()
        for (i, piece) in pieces.enumerated() {
            var part = AttributedString(String(piece))
            if i % 2 == 1 { part.inlinePresentationIntent = .code }
            out += part
        }
        return out
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if numbered {
                    CardKeyCap(key: "\(option.number)", size: size, active: option.focused)
                }
                VStack(alignment: .leading, spacing: 2) {
                    // The key that picks it on the program's screen (`(shift+tab)`, Codex's `(y)`): here a click does.
                    Text(Self.codeSpans(ScreenPrompt.withoutKeyHint(option.label)))
                        .font(.system(size: size * 0.95))
                        .fixedSize(horizontal: false, vertical: true)
                    if !option.detail.isEmpty {
                        Text(ScreenPrompt.withoutKeyHint(option.detail))
                            .font(.system(size: size * 0.82))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if busy {
                    ProgressView().controlSize(.small)
                } else if checkbox {
                    Image(systemName: option.checked == true ? "checkmark.square.fill" : "square")
                        .font(.system(size: size * 0.95))
                        .foregroundStyle(option.checked == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .accessibilityLabel(option.checked == true ? "Ticked" : "Not ticked")
                } else if option.checked == true {
                    // The one in use, in a picker.
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.85, weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityLabel("In use")
                }
            }
        }
        .buttonStyle(CardRowStyle(focused: option.focused))
    }
}

/// A field for a note that goes with an answer.
private struct NoteField: View {
    let placeholder: String
    @Binding var text: String
    let busy: Bool
    let size: Double
    let send: () -> Void

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: size * 0.95))
                .lineLimit(1 ... 5)
                .onSubmit { if !empty, !busy { send() } }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: size * 1.35))
            }
            .buttonStyle(.plain)
            .foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            .disabled(empty || busy)
            .help("Send the note (↩)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
    }
}

/// Claude blocked, its screen not read yet or not understood.
private struct WaitingLine: View {
    let feed: TranscriptFeed
    let status: AgentStatus?
    let size: Double

    var body: some View {
        HStack(spacing: 8) {
            if !feed.promptRead { ProgressView().controlSize(.small) }
            Text(status?.message.flatMap { $0.isEmpty ? nil : $0 } ?? "\(feed.agentName) is waiting for an answer.")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: size * 0.92))
    }
}

struct ActionProblem: View {
    let feed: TranscriptFeed
    let size: Double

    var body: some View {
        if let problem = feed.actionError {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: size * 0.85))
                .foregroundStyle(.readable(.orange))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What went wrong, or is left to do, once no card shows (after `/rewind`):
/// a line over the field until closed or the next message.
struct ActionNote: View {
    let feed: TranscriptFeed
    let size: Double

    var body: some View {
        if let problem = feed.actionError {
            HStack(spacing: 8) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: size * 0.85))
                    .foregroundStyle(.readable(.orange))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { feed.actionError = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .paneGlass(.regular.tint(Color.orange.opacity(0.08)), in: .rect(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }
}

/// Keys on a card, as on Claude's screen: digits choose, Esc cancels,
/// Return submits. Not while a field is being written in.
struct CardKeys: ViewModifier {
    let feed: TranscriptFeed
    let focusedPane: Bool
    let digit: (Int) -> Bool
    let escape: () -> Bool
    var enter: () -> Bool = { false }
    /// ← and →: a card with steps goes from one to the next.
    var left: () -> Bool = { false }
    var right: () -> Bool = { false }
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                guard !Self.typing, let n = Int(press.characters), digit(n) else { return .ignored }
                return .handled
            }
            .onKeyPress(.escape) { !Self.typing && escape() ? .handled : .ignored }
            .onKeyPress(.return) { !Self.typing && enter() ? .handled : .ignored }
            .onKeyPress(.leftArrow) { !Self.typing && left() ? .handled : .ignored }
            .onKeyPress(.rightArrow) { !Self.typing && right() ? .handled : .ignored }
            .onAppear { take() }
            // Shown again without leaving the window (`ConversationContainer`).
            .onChange(of: feed.shows) { take() }
    }

    /// A text field or view has the keyboard: keys are words there.
    @MainActor private static var typing: Bool {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return text.isEditable
    }

    /// Not while out of sight: a conversation left stays in the window, hidden.
    private func take() {
        if focusedPane, feed.isShown { focused = true }
    }
}

/// What Codex printed for one of its commands (`/status`, `/diff`), read
/// from its screen: its session file doesn't keep it.
struct CommandOutputCard: View {
    @Environment(\.codeFamily) private var codeFamily
    let feed: TranscriptFeed
    let size: Double
    let openTerminal: () -> Void

    var body: some View {
        if let output = feed.commandOutput {
            CardFrame(tint: .gray) {
                CardHeader(title: output.command, symbol: output.symbol, tint: .secondary, size: size, terminalLabel: "Show in Terminal", openTerminal: openTerminal)
                RenderScroll {
                    Text(output.text)
                        .font(CodeFont.font(size * 0.85, family: codeFamily))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close") { feed.closeCommandOutput() }
                        .buttonStyle(.glass)
                }
            }
        }
    }
}
