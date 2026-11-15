import AppKit
import HerdrKit
import SwiftUI

// Settings › Dictation's pictures: how a dictation goes, with the key to
// hold in it; what the tidy-up takes out; what the vocabulary fixes.

/// The theme's accent, which the Messages field's dictation shows in.
private struct DictationAccent: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let accent = model.prefs.theme.accentColor.map { Color(nsColor: $0) } ?? .accentColor
        content
            .environment(\.themeAccent, accent)
            .tint(accent)
    }
}

extension View {
    func dictationAccent() -> some View {
        modifier(DictationAccent())
    }
}

// MARK: How it goes

/// Hold the key, speak, let go: the key (a click on it records another),
/// the voice, and the text in the field. With no key, the microphone's two
/// clicks instead.
struct DictationFlow: View {
    @Environment(\.themeAccent) private var themeAccent
    @State private var key = Dictation.key
    @State private var recording = false
    @State private var refused = false
    static let node: CGFloat = 50

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 0) {
                step(caption: firstCaption, tint: recording ? (refused ? .orange : themeAccent ?? .accentColor) : nil) {
                    HStack(spacing: 6) {
                        if key == nil, !recording {
                            MicNode()
                        } else {
                            HoldKeyRecorder(key: $key, recording: $recording, refused: $refused)
                        }
                        KeyChoices(key: $key, recording: $recording)
                    }
                }
                FlowArrow()
                step(caption: "Speak") { WaveNode() }
                FlowArrow()
                step(caption: key == nil ? "Click again" : "Let go") { FieldNode() }
            }
            .frame(maxWidth: .infinity)
            if key?.code == 63 {
                HStack(spacing: 8) {
                    Text("Set the \(Image(systemName: "globe")) key to Do Nothing in Keyboard settings, or it opens its own menu.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open") { Self.openKeyboardSettings() }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 14)
        .animation(.snappy(duration: 0.25), value: key)
        .animation(.snappy(duration: 0.2), value: recording)
        .accessibilityElement(children: .contain)
        #if DEBUG
        // "show:none", "show:63", "show:<code>:<modifiers>:<label>": a key shown here only, not saved.
        .onReceive(NotificationCenter.default.publisher(for: .swiftrDebugDictationRecord)) { note in
            guard let text = note.object as? String, text.hasPrefix("show:") else { return }
            let parts = text.dropFirst(5).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.first == "none" {
                key = nil
            } else if let code = parts.first.flatMap({ UInt16($0) }) {
                key = DictationKey(code: code, modifiers: parts.count > 1 ? UInt(parts[1]) ?? 0 : 0, label: parts.count > 2 ? parts[2] : "")
            }
        }
        #endif
    }

    private var firstCaption: String {
        if recording { return refused ? "Add ⌃, ⌥ or ⌘" : "Press a key" }
        return key == nil ? "Click" : "Hold"
    }

    private func step(caption: String, tint: Color? = nil, @ViewBuilder _ node: () -> some View) -> some View {
        VStack(spacing: 9) {
            node()
                .frame(height: Self.node)
            Text(caption)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                .contentTransition(.opacity)
        }
        .fixedSize()
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A line from one step to the next, ending in an arrow.
private struct FlowArrow: View {
    var body: some View {
        Canvas { g, size in
            let y = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 6, y: y))
            line.addLine(to: CGPoint(x: size.width - 9, y: y))
            var head = Path()
            head.move(to: CGPoint(x: size.width - 11, y: y - 4))
            head.addLine(to: CGPoint(x: size.width - 4, y: y))
            head.addLine(to: CGPoint(x: size.width - 11, y: y + 4))
            head.closeSubpath()
            g.stroke(line, with: .style(.tertiary), lineWidth: 1.5)
            g.fill(head, with: .style(.tertiary))
        }
        .frame(width: 36, height: DictationFlow.node)
        .accessibilityHidden(true)
    }
}

/// The voice, as the field shows it while you speak.
private struct WaveNode: View {
    var body: some View {
        RenderStandIn {
            VoiceWave(source: .demo)
        } standIn: {
            Capsule().fill(.tint.opacity(0.4)).frame(height: 3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(width: 138, height: DictationFlow.node)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
        .voiceEdge(source: .demo, corner: DictationFlow.node / 2)
        .accessibilityLabel("Your voice")
    }
}

/// The Messages field with what was said in it.
private struct FieldNode: View {
    @Environment(\.themeAccent) private var themeAccent
    @Environment(\.self) private var environment

    var body: some View {
        let accent = themeAccent ?? .accentColor
        HStack(spacing: 2) {
            Text("Fix the login bug")
                .font(.system(size: 13))
                .lineLimit(1)
                .fixedSize()
            Capsule()
                .fill(accent)
                .frame(width: 2, height: 16)
            Spacer(minLength: 10)
            Circle()
                .fill(accent)
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ChatStyle.ink(on: accent.resolve(in: environment)))
                }
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .frame(width: 184, height: 40)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityLabel("The text in the field, not sent")
    }
}

/// The microphone beside Send, for a dictation without a key.
private struct MicNode: View {
    @Environment(\.themeAccent) private var themeAccent
    @Environment(\.self) private var environment

    var body: some View {
        let accent = themeAccent ?? .accentColor
        Circle()
            .fill(accent)
            .frame(width: 40, height: 40)
            .overlay {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ChatStyle.ink(on: accent.resolve(in: environment)))
            }
            .accessibilityLabel("The microphone beside Send")
    }
}

// MARK: The key

/// The key to hold, drawn as on the keyboard: a click on it, and the next
/// key pressed takes its place. Esc keeps it.
private struct HoldKeyRecorder: View {
    @Environment(\.themeAccent) private var themeAccent
    @Binding var key: DictationKey?
    @Binding var recording: Bool
    @Binding var refused: Bool
    @State private var monitor: Any?
    /// A modifier went down alone: it's the key, if no other comes with it.
    @State private var modifierDown: UInt16?
    @State private var pulse = false

    var body: some View {
        Button {
            recording ? stop() : record()
        } label: {
            HoldKeyCaps(key: key)
                .opacity(recording ? 0.35 : 1)
                .overlay {
                    if recording {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(refused ? Color.orange : themeAccent ?? .accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .padding(-4)
                            .opacity(pulse ? 1 : 0.35)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                            }
                            .onDisappear { pulse = false }
                    }
                }
                .modifier(Shake(amount: refused ? 1 : 0))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(recording ? "Press the key to hold, or Esc to keep \(key?.name ?? "none")" : "\(key?.name ?? "No key") · Click to choose another key")
        .accessibilityLabel("Key to hold: \(key?.name ?? "none")")
        .onDisappear { stop() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .swiftrDebugDictationRecord)) { note in
            switch note.object as? String {
            case "on": record()
            case "refused": record(); refused = true
            case let text? where text.hasPrefix("show:"): break
            default: stop()
            }
        }
        #endif
    }

    private func set(_ new: DictationKey?) {
        stop()
        key = new
        Dictation.key = new
    }

    private func record() {
        guard monitor == nil else { return }
        recording = true
        refused = false
        modifierDown = nil
        DictationKeys.shared.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            take(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        refused = false
        modifierDown = nil
        DictationKeys.shared.paused = false
    }

    private func take(_ event: NSEvent) {
        let flags = UInt(event.modifierFlags.rawValue)
        if event.type == .flagsChanged {
            let pressed = DictationKey(code: event.keyCode)
            guard pressed.isModifier else { return }
            if pressed.isDown(in: flags) {
                // A second modifier: a key with modifiers is on its way.
                modifierDown = modifierDown == nil ? event.keyCode : 0
            } else if modifierDown == event.keyCode {
                set(pressed)
            }
            return
        }
        // Esc alone: keep the key there was.
        if event.keyCode == 53, flags & DictationKey.modifierMask == 0 {
            stop()
            return
        }
        let modifiers = flags & DictationKey.modifierMask
        let name = Self.name(of: event)
        // A letter alone would no longer type.
        if modifiers & (DictationKey.control | DictationKey.option | DictationKey.command) == 0, !name.isFunctionKey {
            withAnimation(.linear(duration: 0.3)) { refused = true }
            modifierDown = nil
            Task {
                try? await Task.sleep(for: .milliseconds(320))
                refused = refused && recording
            }
            return
        }
        set(DictationKey(code: event.keyCode, modifiers: modifiers, label: name.label))
    }

    /// What the key is called: F5, Space, or the letter it types.
    private static func name(of event: NSEvent) -> (label: String, isFunctionKey: Bool) {
        let functionKeys: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        if let name = functionKeys[event.keyCode] { return (name, true) }
        let others: [UInt16: String] = [49: "Space", 48: "Tab", 36: "Return", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let name = others[event.keyCode] { return (name, false) }
        return ((event.charactersIgnoringModifiers ?? "").uppercased(), false)
    }
}

/// The keys of the shortcut: one cap for a modifier held alone, as the
/// keyboard prints it; a cap for each sign and the key otherwise.
private struct HoldKeyCaps: View {
    let key: DictationKey?

    var body: some View {
        HStack(spacing: 5) {
            if let key {
                if let modifier = Self.modifiers[key.code] {
                    BigKeyCap(sign: modifier.sign, symbol: modifier.symbol, word: modifier.word, right: modifier.right, width: 84)
                } else {
                    ForEach(Self.signs(key.modifiers), id: \.self) { sign in
                        BigKeyCap(sign: sign, width: 44)
                    }
                    BigKeyCap(sign: key.label.isEmpty ? "?" : key.label, width: key.label.count > 2 ? 72 : 48)
                }
            } else {
                BigKeyCap(sign: "–", width: 60)
            }
        }
    }

    /// A modifier's cap: its sign, its word, and which side the word sits.
    struct Cap {
        var sign = ""
        var symbol: String?
        let word: String
        let right: Bool
    }

    static let modifiers: [UInt16: Cap] = [
        61: Cap(sign: "⌥", word: "right option", right: true),
        58: Cap(sign: "⌥", word: "left option", right: false),
        54: Cap(sign: "⌘", word: "right command", right: true),
        55: Cap(sign: "⌘", word: "left command", right: false),
        60: Cap(sign: "⇧", word: "right shift", right: true),
        56: Cap(sign: "⇧", word: "left shift", right: false),
        62: Cap(sign: "⌃", word: "right control", right: true),
        59: Cap(sign: "⌃", word: "left control", right: false),
        63: Cap(symbol: "globe", word: "fn", right: false),
    ]

    static func signs(_ modifiers: UInt) -> [String] {
        var out: [String] = []
        if modifiers & DictationKey.control != 0 { out.append("⌃") }
        if modifiers & DictationKey.option != 0 { out.append("⌥") }
        if modifiers & DictationKey.shift != 0 { out.append("⇧") }
        if modifiers & DictationKey.command != 0 { out.append("⌘") }
        return out
    }
}

/// A key as a Mac keyboard draws it: a raised cap, its sign at the top and
/// its word at the bottom, on the side it sits.
private struct BigKeyCap: View {
    var sign = ""
    var symbol: String?
    var word: String?
    var right = true
    let width: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack {
            if let word {
                VStack(alignment: right ? .trailing : .leading, spacing: 0) {
                    Group {
                        if let symbol {
                            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                        } else {
                            Text(sign).font(.system(size: 16, weight: .medium))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: right ? .trailing : .leading)
                    Spacer(minLength: 0)
                    Text(word)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            } else {
                Text(sign)
                    .font(.system(size: sign.count > 2 ? 13 : 17, weight: .medium, design: .rounded))
            }
        }
        .frame(width: width, height: 44)
        .background {
            shape
                .fill(.primary.opacity(0.08))
                .background(shape.fill(.background))
                .shadow(color: .black.opacity(0.3), radius: 0, y: 1.5)
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(colors: [.primary.opacity(0.22), .primary.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
        }
    }
}

/// Keys most people hold, and None: a small menu beside the key.
private struct KeyChoices: View {
    @Binding var key: DictationKey?
    @Binding var recording: Bool

    var body: some View {
        Menu {
            Button("Right Option") { set(.rightOption) }
            Button("Right Command") { set(DictationKey(code: 54)) }
            Button("Fn (Globe)") { set(DictationKey(code: 63)) }
            Divider()
            Button("None: Microphone Only") { set(nil) }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.quaternary))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Other keys")
        .opacity(recording ? 0 : 1)
    }

    private func set(_ new: DictationKey?) {
        key = new
        Dictation.key = new
    }
}

/// A shake from side to side, as a refused password: `amount` from 0 to 1.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(amount * .pi * 6), y: 0))
    }
}

// MARK: Tidy-up

/// What the tidy-up does: the stumbles of the words as said go, the
/// sentence gets its capital and its full stop. Off, the tidied side fades.
struct TidyPicture: View {
    let on: Bool

    var body: some View {
        HStack(spacing: 0) {
            bubble(icon: "waveform", tint: .secondary) {
                Text("\(dropped("um ")) \(dropped("the ")) the build \(dropped("is ")) is broken")
            }
            FlowArrow()
                .frame(width: 34)
            bubble(icon: "wand.and.sparkles", tint: .tint) {
                Text("The build is broken.")
            }
            .opacity(on ? 1 : 0.35)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .opacity(on ? 0 : 1)
            }
        }
        .fixedSize()
        .animation(.snappy, value: on)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(on ? "“um the the build is is broken” becomes “The build is broken.”" : "Text goes in as said")
    }

    private func dropped(_ word: String) -> Text {
        Text(word.trimmingCharacters(in: .whitespaces))
            .strikethrough()
            .foregroundStyle(.tertiary)
    }

    private func bubble(icon: String, tint: some ShapeStyle, @ViewBuilder _ text: () -> Text) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            text()
                .font(.system(size: 12.5))
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

// MARK: Vocabulary

/// What a name in the vocabulary fixes: heard as a word, written as spelled.
struct VocabularyPicture: View {
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("“swifter”")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
            FlowArrow()
                .frame(width: 34)
            WordChip(word: "Swiftr")
        }
        .fixedSize()
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heard as “swifter”, written “Swiftr”")
    }
}

/// The names in the vocabulary, each a chip with its ✕, and a field that
/// adds one with Return (several, between commas). Kept as the text
/// Settings always kept: the names between commas.
struct WordChips: View {
    @Binding var text: String
    @State private var typed = ""
    @State private var adding = false
    @FocusState private var typing: Bool

    var body: some View {
        let words = DictationVocabulary.parse(text)
        ChipFlow(spacing: 6) {
            ForEach(words, id: \.self) { word in
                WordChip(word: word) { remove(word) }
            }
            // A button until clicked: a field there would take the
            // keyboard each time the pane opens.
            if adding {
                TextField("Name", text: $typed, prompt: Text("Name, Return"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .frame(width: 110)
                    .focused($typing)
                    // The field comes with the click: it takes the keyboard once there.
                    .onAppear { typing = true }
                    .onSubmit { add() }
                    .onExitCommand { close() }
                    .onChange(of: typing) { if !typing { close() } }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .overlay(Capsule().strokeBorder(.tint.opacity(0.8), lineWidth: 1))
            } else {
                Button {
                    adding = true
                } label: {
                    Label(words.isEmpty ? "Add a Name" : "Add", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Add a name to write as it's spelled")
            }
        }
        .padding(.vertical, 4)
        .animation(.snappy(duration: 0.2), value: words)
    }

    private func add() {
        var words = DictationVocabulary.parse(text)
        for word in DictationVocabulary.parse(typed) where !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            words.append(word)
        }
        text = words.joined(separator: ", ")
        typed = ""
        // Ready for the next one.
        typing = true
    }

    private func close() {
        if !typed.trimmingCharacters(in: .whitespaces).isEmpty { add() }
        adding = false
        typing = false
    }

    private func remove(_ word: String) {
        text = DictationVocabulary.parse(text).filter { $0 != word }.joined(separator: ", ")
    }
}

/// A name as a chip, in the accent's tint; with `remove`, its ✕.
struct WordChip: View {
    let word: String
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Text(word)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("Remove \(word)")
                .accessibilityLabel("Remove \(word)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, remove == nil ? 10 : 6)
        .frame(height: 26)
        .background(Capsule().fill(.tint.opacity(0.16)))
        .overlay(Capsule().strokeBorder(.tint.opacity(0.4), lineWidth: 0.75))
    }
}

/// Lays chips out in lines, as many to a line as fit.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

#if DEBUG
extension Notification.Name {
    /// "on", "refused" or "off": Settings' key recorder, for snapshots.
    static let swiftrDebugDictationRecord = Notification.Name("swiftrDebugDictationRecord")
}
#endif
