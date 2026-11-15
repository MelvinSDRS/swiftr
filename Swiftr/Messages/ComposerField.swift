import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Keys the field offers to the command list and the history before acting on them.
enum ComposerKey: Equatable {
    case up, down, tab, backtab, enter, escape
    /// ↑ on the text's first line, ↓ on its last, when no list took the
    /// arrow: the message sent before, or the next one back.
    case earlierMessage, laterMessage
    /// →: takes Claude Code's suggestion, as Tab does; else moves the cursor.
    case right
    /// 1 to 9 in the empty field: the agent's numbered menu may take it.
    case digit(Int)
    /// ⌃R: search the messages sent before.
    case search
    /// ⌃O: every step's details shown, or none, as Claude Code's ⌃O.
    case details
    /// ⌃T: the to-do list open or closed.
    case todos
    /// ⌃B: the command or agent running sent to the background.
    case background
    /// ⌃S: the draft set aside until the next message goes, as Claude Code's stash.
    case stash
    /// ⌃X ⌃S: the message waiting goes to Claude now, as Claude Code's.
    case sendNow
    /// ⌃X ⌃K, twice: Claude Code's sub-agents in the background stop.
    case stopAgents
    /// ⌃G: the draft in the person's text editor, as the agents' terminals
    /// open their editor.
    case editor
    /// ⌥T: Claude Code's thinking on or off.
    case thinking
    /// ⌥, and ⌥.: Codex reasons less or more.
    case lessEffort, moreEffort
    /// ⌃Y: Gemini's YOLO mode on or off.
    case yolo
    /// ⌥P in an empty field: the agent's list of models.
    case modelPicker
    /// ⌥O in an empty field: Claude Code's fast mode on or off.
    case fastMode
    /// ⌃X ↩: Claude Code's queue key. With its default settings it does
    /// what ↩ does while Claude works: the message waits for the steps
    /// under way to end, then joins the turn.
    case queueSubmit
    /// ⌃C, as in the agents' inputs: stops the agent at work; twice in an
    /// empty field, quits it. Not taken, it empties the field.
    case cancel

    /// ⌃ with this letter.
    static func control(_ letter: String) -> ComposerKey? {
        switch letter {
        case "r": .search
        case "o": .details
        case "t": .todos
        case "b": .background
        case "s": .stash
        case "g": .editor
        case "y": .yolo
        default: nil
        }
    }

    /// ⌥ with this key: what the agents bind there.
    static func other(_ flags: NSEvent.ModifierFlags, _ key: String) -> ComposerKey? {
        if flags == .option {
            switch key {
            case "t": return .thinking
            case ",": return .lessEffort
            case ".": return .moreEffort
            case "p": return .modelPicker
            case "o": return .fastMode
            default: return nil
            }
        }
        return nil
    }

    /// ⌃X, then ⌃ with this letter: Claude Code's two-key commands.
    static func chord(_ letter: String) -> ComposerKey? {
        switch letter {
        case "s": .sendNow
        case "k": .stopAgents
        case "b": .background
        default: nil
        }
    }
}

/// A picture pasted or dropped in the field, sent with the next message.
nonisolated struct PendingImage: Identifiable, Equatable, Sendable {
    let id = UUID()
    let name: String
    let data: Data

    /// The core takes up to 8 MB a file.
    static let maxBytes = 8 << 20

    init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    /// A picture's bytes, made small enough for the core: JPEG, then smaller.
    static func fitted(name: String, data: Data) -> PendingImage? {
        if data.count <= maxBytes { return PendingImage(name: name, data: data) }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        var factor = 0.85
        while factor > 0.3 {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: factor]), jpeg.count <= maxBytes {
                return PendingImage(name: (name as NSString).deletingPathExtension + ".jpg", data: jpeg)
            }
            factor -= 0.2
        }
        return nil
    }

    /// The pictures on a pasteboard: image files, or an image itself (a
    /// screenshot). Nil when it holds words or other files, which paste as text.
    static func read(from pb: NSPasteboard, filesOnly: Bool = false) -> [PendingImage]? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let pictures = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            guard pictures.count == urls.count else { return nil }
            let found = pictures.prefix(10).compactMap { url in
                (try? Data(contentsOf: url)).flatMap { fitted(name: url.lastPathComponent, data: $0) }
            }
            return found.isEmpty ? nil : found
        }
        if filesOnly { return nil }
        // Words win: rich text may carry a picture of itself too.
        if pb.string(forType: .string) != nil { return nil }
        if let png = pb.data(forType: .png) { return fitted(name: "Pasted image.png", data: png).map { [$0] } }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:])
        {
            return fitted(name: "Pasted image.png", data: png).map { [$0] }
        }
        return nil
    }

    /// What is dropped on the field, from SwiftUI's drop: pictures for an
    /// agent that takes them (`pictures`), other files (and pictures, for
    /// one that doesn't) to name in the message.
    @MainActor static func load(from providers: [NSItemProvider], pictures: Bool, into add: @escaping @MainActor ([PendingImage]) -> Void,
                                files: @escaping @MainActor ([URL]) -> Void)
    {
        for provider in providers.prefix(20) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    guard pictures, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else {
                        Task { @MainActor in files([url]) }
                        return
                    }
                    guard let data = try? Data(contentsOf: url), let picture = fitted(name: url.lastPathComponent, data: data) else { return }
                    Task { @MainActor in add([picture]) }
                }
            } else if pictures, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]),
                          let picture = fitted(name: "Dropped image.png", data: png)
                    else { return }
                    Task { @MainActor in add([picture]) }
                }
            }
        }
    }
}

/// The text of the field where the person writes to Claude: an AppKit text
/// view, so every macOS text shortcut works (undo, words, lines, Emacs keys,
/// the Edit menu). Return sends; Shift-, Option- or Control-Return go to a
/// new line; Esc goes to `onEscape` instead of the word completion list.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    let size: Double
    let enabled: Bool
    let dark: Bool
    /// The model asks the focused pane to take the keyboard when this changes.
    let focusTick: Int
    let wantsFocus: Bool
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onFocus: () -> Void
    /// Up, Down, Tab, Return, Esc go here first; true when taken.
    var onKey: (ComposerKey) -> Bool = { _ in false }
    /// Pictures pasted or dropped.
    var onImages: ([PendingImage]) -> Void = { _ in }
    /// Whether the agent takes pictures: else a picture file dropped is a file.
    var takesPictures = true
    /// Files dropped (not pictures the agent takes), to name in the message.
    var onFiles: ([URL]) -> Void = { _ in }
    /// Where the cursor goes once the field holds the text asked for (a
    /// draft back from the agent's input, its cursor where the agent's was).
    var caretAsk: CaretAsk? = nil
    /// The cursor moved: its UTF-16 offset (a selection's end), and the
    /// text's length.
    var onCaret: (Int, Int) -> Void = { _, _ in }

    /// Taller than this, the text scrolls.
    static let maxLines: CGFloat = 12

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocus() }
        view.onImages = { [weak coordinator = context.coordinator] in coordinator?.parent.onImages($0) }
        view.onFiles = { [weak coordinator = context.coordinator] in coordinator?.parent.onFiles($0) }
        view.onControlKey = { [weak coordinator = context.coordinator] key in coordinator?.parent.onKey(key) ?? false }
        view.takesPictures = takesPictures
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.string = text

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        // The scroll bar comes with text taller than the field can grow (`height`).
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = view

        context.coordinator.view = view
        context.coordinator.tick = focusTick
        context.coordinator.applyCaret(caretAsk)
        style(view, in: scroll)
        if wantsFocus { view.focusWhenShown() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = coordinator.view else { return }
        view.takesPictures = takesPictures
        if view.string != text { coordinator.replace(with: text) }
        coordinator.applyCaret(caretAsk)
        style(view, in: scroll)
        if !wantsFocus {
            view.forgetFocus()
        } else if coordinator.tick != focusTick {
            coordinator.tick = focusTick
            view.focusWhenShown()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: context.coordinator.height(forWidth: width))
    }

    /// Font, colors and light or dark as the pane's theme has them.
    private func style(_ view: ComposerTextView, in scroll: NSScrollView) {
        let font = NSFont.systemFont(ofSize: size)
        let color: NSColor = enabled ? .labelColor : .secondaryLabelColor
        if view.font != font { view.font = font }
        if view.textColor != color { view.textColor = color }
        if view.isEditable != enabled { view.isEditable = enabled }
        view.isSelectable = true
        view.insertionPointColor = .labelColor
        view.typingAttributes = [.font: font, .foregroundColor: color]
        // SwiftUI's color scheme doesn't reach AppKit views: the theme may be
        // dark while macOS is light.
        let look = NSAppearance(named: dark ? .darkAqua : .aqua)
        if scroll.appearance?.name != look?.name { scroll.appearance = look }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var view: ComposerTextView?
        var tick = 0
        /// The last place asked for the cursor, put there once.
        private var caretTick = 0
        /// The text changes from the model, not from typing.
        private var replacing = false

        init(_ parent: ComposerField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !replacing, let view, parent.text != view.string else { return }
            parent.text = view.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view else { return }
            parent.onCaret(NSMaxRange(view.selectedRange()), (view.string as NSString).length)
        }

        /// The cursor where `ask` puts it, once the field holds its text.
        func applyCaret(_ ask: CaretAsk?) {
            guard let ask, ask.tick != caretTick, let view, view.string == ask.text else { return }
            caretTick = ask.tick
            let place = NSRange(location: min(ask.offset, (view.string as NSString).length), length: 0)
            view.setSelectedRange(place)
            view.scrollRangeToVisible(place)
        }

        /// Puts the model's text in, as one step Undo can take back (the
        /// field emptied once sent).
        func replace(with text: String) {
            guard let view, let storage = view.textStorage else { return }
            replacing = true
            defer { replacing = false }
            let all = NSRange(location: 0, length: storage.length)
            if view.isEditable, view.shouldChangeText(in: all, replacementString: text) {
                storage.replaceCharacters(in: all, with: text)
                view.didChangeText()
            } else {
                view.string = text
                view.undoManager?.removeAllActions(withTarget: storage)
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // An input method finishing a word takes Return for itself.
                if textView.hasMarkedText() { return false }
                let flags = NSApp.currentEvent?.modifierFlags.intersection([.shift, .option, .control]) ?? []
                if flags.isEmpty {
                    if !parent.onKey(.enter) { parent.onSubmit() }
                } else {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                }
                return true
            case #selector(NSResponder.insertLineBreak(_:)):
                // A plain new line, not the line separator character.
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if !parent.onKey(.escape) { parent.onEscape() }
                return true
            case #selector(NSTextView.complete(_:)) where NSApp.currentEvent?.keyCode == 53:
                // Esc, where macOS would list word completions.
                if !parent.onKey(.escape) { parent.onEscape() }
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab completes a command, else moves on as in a text field; Option-Tab types one.
                if parent.onKey(.tab) { return true }
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.moveUp(_:)):
                // A list's or the agent's menu first; else, from the first
                // line, the messages sent, as in the agents' terminals.
                if parent.onKey(.up) { return true }
                return caretOnEdge(of: textView, top: true) && parent.onKey(.earlierMessage)
            case #selector(NSResponder.moveDown(_:)):
                if parent.onKey(.down) { return true }
                return caretOnEdge(of: textView, top: false) && parent.onKey(.laterMessage)
            case #selector(NSResponder.moveRight(_:)):
                return parent.onKey(.right)
            case #selector(NSResponder.insertBacktab(_:)):
                // Shift-Tab switches the agent's mode, as in its terminal.
                if parent.onKey(.backtab) { return true }
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }

        /// Whether the cursor stands on the text's first line as laid out
        /// (`top`), or on its last; an empty field is both.
        private func caretOnEdge(of view: NSTextView, top: Bool) -> Bool {
            guard let layout = view.layoutManager, let container = view.textContainer else { return true }
            let length = (view.string as NSString).length
            guard length > 0 else { return true }
            layout.ensureLayout(for: container)
            func lineTop(_ index: Int) -> CGFloat {
                // After a final new line, the cursor has a line of its own.
                if index >= length, layout.extraLineFragmentTextContainer != nil { return layout.extraLineFragmentRect.minY }
                let glyph = layout.glyphIndexForCharacter(at: min(index, length - 1))
                return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            }
            let selected = view.selectedRange()
            let at = top ? lineTop(selected.location) : lineTop(NSMaxRange(selected))
            return abs(at - lineTop(top ? 0 : length)) < 0.5
        }

        /// The text's height at `width`, one line to `maxLines`.
        func height(forWidth width: CGFloat) -> CGFloat {
            guard let view, let layout = view.layoutManager, let container = view.textContainer else { return 0 }
            let font = view.font ?? .systemFont(ofSize: parent.size)
            let line = ceil(layout.defaultLineHeight(for: font))
            let used: CGFloat
            if abs(container.size.width - width) < 0.5 {
                layout.ensureLayout(for: container)
                used = layout.usedRect(for: container).height
            } else {
                // Not laid out at that width yet: measure the text alone.
                var text = view.string.isEmpty ? " " : view.string
                if text.hasSuffix("\n") { text += " " }
                used = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
                    with: NSSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height
            }
            let most = line * ComposerField.maxLines
            // Focused, the text view stands a point taller than its one line,
            // and AppKit shows a scroll bar for it: only for text past the most.
            let tall = ceil(used) > most
            if let scroll = view.enclosingScrollView, scroll.hasVerticalScroller != tall { scroll.hasVerticalScroller = tall }
            return min(max(ceil(used), line), most)
        }
    }
}

/// Tells when it takes the keyboard, and takes it when asked once on screen.
/// Disabled, it leaves the keyboard to what Claude asks (keys 1–9, Esc).
final class ComposerTextView: NSTextView {
    var onFocus: (() -> Void)?
    var onImages: (([PendingImage]) -> Void)?
    var onFiles: (([URL]) -> Void)?
    /// ⌃R, ⌃O, ⌃T, ⌃B, ⌃S, ⌃G, ⌃C, the ⌃X pairs and the agents' ⌥ keys: true
    /// when taken. Else the text's own (⌃B moves back, ⌃T swaps letters,
    /// ⌃K deletes to the end, ⌥T types †, ⌥P π).
    var onControlKey: ((ComposerKey) -> Bool)?
    var takesPictures = true
    private var pendingFocus = false
    /// When ⌃X was pressed: the next key may finish a pair.
    private var pairStarted: Date?

    override func keyDown(with event: NSEvent) {
        let control = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control && !hasMarkedText()
        let letter = event.charactersIgnoringModifiers?.lowercased()
        if let started = pairStarted {
            pairStarted = nil
            if Date().timeIntervalSince(started) < 2 {
                if control, let key = letter.flatMap(ComposerKey.chord), onControlKey?(key) == true { return }
                // ⌃X ↩, as in Claude Code.
                let others = event.modifierFlags.intersection([.command, .option, .shift])
                if [36, 76].contains(event.keyCode), others.isEmpty, !hasMarkedText(), onControlKey?(.queueSubmit) == true { return }
            }
        }
        // ⌃X does nothing in text: it starts a pair.
        if control, letter == "x", onControlKey != nil {
            pairStarted = Date()
            return
        }
        // ⌃L empties the field, as it empties the agents' inputs; ⌘Z brings the text back.
        if control, letter == "l", isEditable {
            if !string.isEmpty {
                selectAll(nil)
                delete(nil)
            }
            return
        }
        // ⌃C: the pane stops the agent at work, or quits it from an empty
        // field; else the field empties, as the agents' inputs do (⌘Z brings the text back).
        if control, letter == "c", isEditable {
            if onControlKey?(.cancel) == true { return }
            if !string.isEmpty {
                selectAll(nil)
                delete(nil)
            }
            return
        }
        if control, let key = letter.flatMap(ComposerKey.control), onControlKey?(key) == true { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !hasMarkedText(), let key = letter.flatMap({ ComposerKey.other(flags, $0) }), onControlKey?(key) == true { return }
        // A digit in the empty field, as in the agent's terminal: one of its menus may take it.
        if flags.subtracting(.shift).isEmpty, string.isEmpty, !hasMarkedText(), let typed = event.characters, typed.count == 1,
           let n = Int(typed), (1 ... 9).contains(n), onControlKey?(.digit(n)) == true { return }
        super.keyDown(with: event)
    }

    /// A picture pasted goes with the message, not into the text.
    override func paste(_ sender: Any?) {
        if isEditable, let onImages, let pictures = PendingImage.read(from: .general) {
            onImages(pictures)
            return
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if isEditable, takesPictures, let onImages, let pictures = PendingImage.read(from: pb, filesOnly: true) {
            onImages(pictures)
            return true
        }
        // Other files: named in the message (`@path`), not pasted as text.
        if isEditable, let onFiles, let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    override var acceptsFirstResponder: Bool { isEditable && super.acceptsFirstResponder }

    override var isEditable: Bool {
        didSet { if isEditable, !oldValue, pendingFocus, shown { DispatchQueue.main.async { [weak self] in self?.takeFocus() } } }
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocus?() }
        return took
    }

    /// Another pane has the keyboard now: don't take it back later.
    func forgetFocus() {
        pendingFocus = false
    }

    /// The pane wants the keyboard: now if on screen, else as soon as it is.
    func focusWhenShown() {
        pendingFocus = true
        if shown { DispatchQueue.main.async { [weak self] in self?.takeFocus() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if shown, pendingFocus { DispatchQueue.main.async { [weak self] in self?.takeFocus() } }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if shown, pendingFocus { DispatchQueue.main.async { [weak self] in self?.takeFocus() } }
    }

    /// In a window and not hidden: a conversation out of sight stays in the
    /// window, hidden (`ConversationContainer`).
    private var shown: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    private func takeFocus() {
        // Disabled: wait until it can be written in again.
        guard pendingFocus, isEditable, shown, let window else { return }
        pendingFocus = false
        // Not while someone types a name somewhere else.
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return }
        if window.firstResponder !== self { window.makeFirstResponder(self) }
    }
}
