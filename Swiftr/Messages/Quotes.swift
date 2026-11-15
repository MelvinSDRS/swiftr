import AppKit
import HerdrKit
import SwiftUI

// Words picked in a conversation, quoted in the next message: as in the
// Codex app, a button over the selection ("Ask Claude") puts them over
// the field as a "Selection" tile; the message then goes as a
// `QuotedPrompt`, and its bubble shows the quote over the question.

/// What the person selected in a conversation, offered to quote by a
/// button over it.
@MainActor @Observable
final class QuoteOffer {
    struct Shown: Equatable {
        /// The words selected, trimmed.
        var text: String
        /// Around the selected lines, in the layer's points from its top left.
        var around: CGRect
        /// The layer's size.
        var room: CGSize
        /// Where the window's bar ends, down from the layer's top: the button stays under it.
        var top: CGFloat
    }

    /// The coordinate space of the layer over the conversation, where the button goes.
    nonisolated static let space = "QuoteOfferLayer"

    var shown: Shown?
    /// The button's frame, in the same points, while shown: a press there leaves the offer.
    @ObservationIgnored var button: CGRect = .null
    /// The view that holds the selection; the words, where they are in it,
    /// and its size then: the words move when it lays them out again.
    @ObservationIgnored weak var source: NSView?
    @ObservationIgnored var text = ""
    @ObservationIgnored var range = NSRange(location: 0, length: 0)
    @ObservationIgnored var lines: CGRect = .zero
    @ObservationIgnored var sourceSize: CGSize = .zero
    /// A view as big as the layer, flipped as SwiftUI's points: the selection's
    /// place, converted to it by AppKit, is where the button goes.
    @ObservationIgnored weak var layer: NSView?

    func hide() {
        if shown != nil { shown = nil }
    }

    /// Lets go of the selection: gone from the screen too.
    func unselect() {
        source?.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 0))
        source = nil
        hide()
    }

    #if DEBUG
    /// The offers of the conversations in sight, by terminal address, for the debug hooks.
    static var shownOffers: [String: QuoteOffer] = [:]
    /// What the button does with the words, for `quote:ask`.
    @ObservationIgnored var debugTake: ((String) -> Void)?
    var debugState: [String: Any] {
        ["shown": shown.map { ["text": $0.text, "around": "\($0.around)", "room": "\($0.room)", "top": $0.top] } ?? [:],
         "button": button.isNull ? "-" : "\(button)", "source": source.map { String(describing: type(of: $0)) } ?? "-",
         "layer": layer.map { "\($0.convert($0.bounds, to: nil))" } ?? "-"]
    }
    #endif
}

/// Sees the person select words in the conversation (a drag, a double or
/// triple click, ⇧ with the arrows, ⌘A) and shows the offer over them; it
/// follows them as the conversation scrolls, and goes once they're no
/// longer selected. SwiftUI's selectable text says what it holds through
/// its accessibility, with its fonts and spacing, though not where:
/// TextKit lays the same text out again to find the words.
struct SelectionWatch: NSViewRepresentable {
    let offer: QuoteOffer
    /// The conversation's terminal, for the debug hooks.
    let address: String

    func makeNSView(context: Context) -> Watcher { Watcher(offer: offer, address: address) }

    func updateNSView(_ view: Watcher, context: Context) {
        view.offer = offer
        view.address = address
    }

    /// Inside the conversation's scroll view, which it finds above it.
    final class Watcher: NSView {
        var offer: QuoteOffer
        var address: String
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var responder: NSKeyValueObservation?
        /// Looks for the release of a press the monitor may not see.
        private var release: Timer?
        /// That press is on the offer's button, which takes the words.
        private var pressingButton = false

        init(offer: QuoteOffer, address: String) {
            self.offer = offer
            self.address = address
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            offer.hide()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyUp]) { [weak self] event in
                self?.saw(event)
                return event
            }
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.follow() }
                })
            }
            // Rows above that grow or shrink move the selection too.
            if let rows = enclosingScrollView?.documentView {
                rows.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: rows, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.follow() }
                })
            }
            // The keyboard went elsewhere (the field, another pane): so did the selection.
            responder = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.responderChanged() }
            }
            #if DEBUG
            QuoteOffer.shownOffers[address] = offer
            observers.append(NotificationCenter.default.addObserver(forName: .swiftrDebugSelection, object: nil, queue: nil) { [weak self] note in
                let address = note.object as? String
                MainActor.assumeIsolated {
                    guard let self, address == self.address else { return }
                    self.check()
                }
            })
            #endif
        }

        isolated deinit {
            stop()
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            release?.invalidate()
            release = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            responder?.invalidate()
            responder = nil
        }

        private func saw(_ event: NSEvent) {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return }
            switch event.type {
            case .leftMouseDown:
                pressingButton = offer.shown != nil && offer.button.contains(inLayer(event.locationInWindow))
                guard !pressingButton else { return }
                // A press elsewhere: the offer goes at once, as in the Codex
                // app, and comes back if words are still selected at the release.
                offer.hide()
                waitForRelease()
            case .leftMouseUp:
                release?.invalidate()
                release = nil
                let button = pressingButton
                // Once the view under the pointer took the release (a double
                // click selects then); the button's own click goes first.
                DispatchQueue.main.async { [weak self] in
                    if button { self?.pressingButton = false }
                    self?.check()
                }
            case .keyUp:
                DispatchQueue.main.async { [weak self] in self?.check() }
            default:
                break
            }
        }

        /// A view that follows a drag in a loop of its own keeps the release
        /// from the monitor: once the button is up and that loop is over
        /// (this timer waits outside such loops), look.
        private func waitForRelease() {
            release?.invalidate()
            let started = Date()
            // Stopped with the watcher (`stop`) if it goes first.
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if NSEvent.pressedMouseButtons & 1 != 0, Date().timeIntervalSince(started) < 60 { return }
                    self.release?.invalidate()
                    self.release = nil
                    self.check()
                }
            }
            RunLoop.main.add(timer, forMode: .default)
            release = timer
        }

        private func responderChanged() {
            guard !pressingButton, offer.source != nil else { return }
            if window?.firstResponder !== offer.source {
                offer.source = nil
                offer.hide()
            }
        }

        /// What is selected now, if it's in this conversation's words.
        func check() {
            guard let window, let scroll = enclosingScrollView, !isHiddenOrHasHiddenAncestor,
                  let view = window.firstResponder as? NSView, view !== self, view.isDescendant(of: scroll),
                  (view as? NSText)?.isEditable != true
            else {
                offer.source = nil
                return offer.hide()
            }
            let range = view.accessibilitySelectedTextRange()
            guard range.location != NSNotFound, range.length > 0,
                  let text = view.accessibilitySelectedText().map(QuotedPrompt.tidy), !text.isEmpty
            else {
                offer.source = nil
                return offer.hide()
            }
            offer.source = view
            offer.text = text
            offer.range = range
            offer.lines = Self.place(of: range, in: view)
            offer.sourceSize = view.bounds.size
            follow()
        }

        /// The offer where the selection shows now; none once it scrolled out of sight.
        private func follow() {
            guard let window, let source = offer.source else { return }
            guard source.window === window, !source.isHiddenOrHasHiddenAncestor,
                  let layer = offer.layer, layer.window === window, layer.isFlipped
            else {
                offer.source = nil
                return offer.hide()
            }
            // Laid out again at another width: the words moved in it.
            if source.bounds.size != offer.sourceSize {
                offer.lines = Self.place(of: offer.range, in: source)
                offer.sourceSize = source.bounds.size
            }
            let around = layer.convert(offer.lines, from: source)
            // The window's bar covers the top of the conversation, which runs under it.
            let top = max(0, layer.convert(NSPoint(x: 0, y: window.contentLayoutRect.maxY), from: nil).y)
            guard around.maxY > top, around.minY < layer.bounds.height else { return offer.hide() }
            let shown = QuoteOffer.Shown(text: offer.text, around: around, room: layer.bounds.size, top: top)
            if offer.shown != shown { offer.shown = shown }
        }

        /// A point of the window in the layer's points, from its top left.
        private func inLayer(_ point: NSPoint) -> CGPoint {
            guard let layer = offer.layer, layer.window === window else { return CGPoint(x: -1e6, y: -1e6) }
            return layer.convert(point, from: nil)
        }

        /// Around the selected words in `view`, as the selection shows them;
        /// when TextKit can't lay them out as the view does, around their
        /// lines, all its width.
        static func place(of range: NSRange, in view: NSView) -> CGRect {
            let around = lines(of: range, in: view).reduce(CGRect.null) { $0.union($1) }
            return around.isNull ? view.bounds : around
        }

        /// Each line of `range`'s words in `view`, in its points, as the
        /// selection shows them; when TextKit can't lay them out as the view
        /// does, their lines all its width, as one.
        static func lines(of range: NSRange, in view: NSView) -> [CGRect] {
            let b = view.bounds
            let laid = laidOut(range, in: view) ?? {
                let count = view.accessibilityNumberOfCharacters()
                let rows = max(1, view.accessibilityLine(for: max(0, count - 1)) + 1)
                let height = b.height / CGFloat(rows)
                let first = max(0, view.accessibilityLine(for: range.location))
                let last = max(first, view.accessibilityLine(for: max(range.location, NSMaxRange(range) - 1)))
                return [CGRect(x: 0, y: CGFloat(first) * height, width: b.width, height: CGFloat(last - first + 1) * height)]
            }()
            return laid.compactMap { line in
                var line = line.intersection(CGRect(origin: .zero, size: b.size))
                guard !line.isNull else { return nil }
                // TextKit's points run down from the top, as a flipped view's.
                if !view.isFlipped { line.origin.y = b.height - line.maxY }
                return line.offsetBy(dx: b.minX, dy: b.minY)
            }
        }

        /// The view's text with the fonts and spacing its accessibility gives,
        /// laid out by TextKit at its width: each line of `range`'s glyphs,
        /// from the top left; nil when that layout breaks lines elsewhere
        /// than the view.
        static func laidOut(_ range: NSRange, in view: NSView) -> [CGRect]? {
            let count = view.accessibilityNumberOfCharacters()
            guard count > 0, NSMaxRange(range) <= count,
                  let text = view.accessibilityAttributedString(for: NSRange(location: 0, length: count)), text.length == count
            else { return nil }
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            // A hair wider: rounding must not push a last word to the next line.
            let container = NSTextContainer(size: CGSize(width: view.bounds.width + 1, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            var fragments = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in fragments += 1 }
            guard fragments == view.accessibilityLine(for: count - 1) + 1 else { return nil }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bottom = layout.usedRect(for: container).maxY
            let spacing = (storage.attribute(.paragraphStyle, at: max(range.location, NSMaxRange(range) - 1), effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing ?? 0
            var lines: [CGRect] = []
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { rect, _ in
                var line = rect
                // A line that isn't the last ends with the spacing under it: not the words'.
                if line.maxY < bottom - 0.5, line.height > spacing { line.size.height -= spacing }
                lines.append(line)
            }
            return lines.isEmpty ? nil : lines
        }
    }
}

/// The offer's button, over the selection; under it when the top is too near.
struct QuoteOfferLayer: View {
    let offer: QuoteOffer
    let agentName: String
    let size: Double
    /// The conversation's background: the button is a step lighter, and solid.
    let surface: Color
    let take: (String) -> Void
    @State private var buttonSize = CGSize(width: 110, height: 28)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let shown = offer.shown {
                let gap: CGFloat = 8
                let half = buttonSize.width / 2
                let x = min(max(shown.around.midX, half + gap), max(half + gap, shown.room.width - half - gap))
                let above = shown.around.minY - gap - buttonSize.height
                let y = above >= shown.top + 4 ? above + buttonSize.height / 2 : shown.around.maxY + gap + buttonSize.height / 2
                AskButton(agentName: agentName, size: size, surface: surface) {
                    let text = shown.text
                    offer.unselect()
                    take(text)
                }
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { buttonSize = $0 }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(QuoteOffer.space)) } action: { offer.button = $0 }
                .position(x: x, y: y)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { LayerAnchor(offer: offer) }
        .coordinateSpace(.named(QuoteOffer.space))
        #if DEBUG
        .onAppear { offer.debugTake = take }
        #endif
        .animation(.easeOut(duration: 0.12), value: offer.shown == nil)
    }
}

/// The layer's frame for AppKit: the selection's place converts to it.
private struct LayerAnchor: NSViewRepresentable {
    let offer: QuoteOffer

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.offer = offer
        offer.layer = view
    }

    final class Anchor: NSView {
        weak var offer: QuoteOffer?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { offer?.layer = self }
        }
    }
}

/// "Ask Claude": the selection goes over the field, quoted in the next message.
private struct AskButton: View {
    let agentName: String
    let size: Double
    let surface: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Ask \(agentName)", systemImage: "text.quote")
                .font(.system(size: size * 0.92, weight: .medium))
                .padding(.horizontal, size * 0.85)
                .padding(.vertical, size * 0.45)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // Solid under the glass, as the bubbles: the words it floats over don't show through.
        .background {
            ZStack {
                surface
                Color.primary.opacity(0.1)
            }
            .clipShape(.capsule)
        }
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .paneGlass(.regular.interactive(), in: .capsule)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .help("Quote the selection in your next message to \(agentName)")
    }
}

/// Passages quoted from the conversation, over the field until the next
/// message takes them: the Codex app's "Selection" tiles. A click on one
/// brings back where it came from.
struct QuoteTray: View {
    @Binding var quotes: [String]
    let size: Double
    let reveal: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(quotes.enumerated()), id: \.offset) { i, quote in
                    tile(quote, label: quotes.count == 1 ? "Selection" : "Selection \(i + 1)") {
                        if quotes.indices.contains(i) { quotes.remove(at: i) }
                    }
                }
            }
            .padding(.top, 5)
            .padding(.trailing, 5)
        }
        .scrollIndicators(.never)
    }

    private func tile(_ quote: String, label: String, remove: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: size * 0.2) {
                Label(label, systemImage: "text.quote")
                    .font(.system(size: size * 0.75, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(quote)
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, size * 0.6)
            .padding(.vertical, size * 0.45)
            // Room for the label and two lines of the passage.
            .frame(width: size * 15, height: size * 4.6, alignment: .topLeading)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            .contentShape(.rect(cornerRadius: 8))
            .onTapGesture { reveal(quote) }
            .help(quote.count > 600 ? String(quote.prefix(600)) + "…" : quote)
            Button(action: remove) {
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

/// The passages a message quoted, over its bubble: a click brings back
/// where each came from, as in the Codex app.
struct PromptQuotes: View {
    @Environment(\.transcriptFeed) private var feed
    let quotes: [String]
    let size: Double
    /// The message's item: the passage is looked for before it.
    var promptID: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: size * 0.35) {
            ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
                TrailingFraction(fraction: 0.77) {
                    Button {
                        guard let feed else { return }
                        var info: [String: String] = ["quote": quote]
                        if let promptID { info["prompt"] = promptID }
                        NotificationCenter.default.post(name: .swiftrRevealQuote, object: feed.address, userInfo: info)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: size * 0.5) {
                            Image(systemName: "text.quote")
                                .foregroundStyle(.tertiary)
                            Text(quote)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        .font(.system(size: size * 0.88))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, size * 0.9)
                        .padding(.vertical, size * 0.5)
                        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: size))
                        .overlay(RoundedRectangle(cornerRadius: size).strokeBorder(Color.primary.opacity(0.08)))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Quoted. Click to show where it came from.")
                }
            }
        }
    }
}

/// A quoted passage marked a moment where it came from: behind its own
/// words, as a highlighter would, where Find marks the whole row. Behind
/// that row, as big as it: the passage is looked for in the selectable
/// texts inside it. When none holds it in one piece (a quote over two
/// blocks, from the Codex app), `missed` marks the row instead.
struct PassageMark: NSViewRepresentable {
    struct Target: Equatable {
        /// The row the passage came from.
        let row: String
        let passage: String
        /// Each reveal marks again, the same passage too.
        let id = UUID()
    }

    let target: Target
    let missed: () -> Void

    func makeNSView(context: Context) -> Marker { Marker() }

    func updateNSView(_ view: Marker, context: Context) {
        view.missed = missed
        view.show(target)
    }

    final class Marker: NSView {
        var missed: (() -> Void)?
        private var target: Target?
        /// The passage's lines, in this view's points.
        private var lines: [CGRect] = []

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func show(_ target: Target) {
            guard target != self.target else { return }
            self.target = target
            lines = []
            alphaValue = 0
            Task { [weak self] in await self?.mark(target) }
        }

        /// Shown a moment, as Find's mark: once found. A row just drawn
        /// (brought into view, or a closed turn opened) may get its texts a
        /// moment later: looks again a few times first.
        private func mark(_ target: Target) async {
            for attempt in 0 ..< 5 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(150)) }
                guard self.target == target else { return }
                if find(target.passage) {
                    needsDisplay = true
                    await NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 1 }
                    try? await Task.sleep(for: .seconds(1.6))
                    guard self.target == target else { return }
                    await NSAnimationContext.runAnimationGroup { $0.duration = 0.4; animator().alphaValue = 0 }
                    return
                }
            }
            #if DEBUG
            PassageMark.debugLast = "missed: \(target.passage.prefix(60))"
            #endif
            missed?()
        }

        /// The passage's lines in the highest text of the row that holds it.
        private func find(_ passage: String) -> Bool {
            guard let document = enclosingScrollView?.documentView else { return false }
            let found = PassageMark.texts(in: document).compactMap { view -> (view: NSView, range: NSRange, top: CGFloat)? in
                let frame = convert(view.bounds, from: view)
                guard bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
                let count = view.accessibilityNumberOfCharacters()
                guard count > 0,
                      let words = view.accessibilityString(for: NSRange(location: 0, length: count)) ?? view.accessibilityValue() as? String,
                      let range = PassageMark.range(of: passage, in: words)
                else { return nil }
                return (view, range, frame.minY)
            }.min { $0.top < $1.top }
            guard let found else { return false }
            lines = SelectionWatch.Watcher.lines(of: found.range, in: found.view).map { convert($0, from: found.view) }
            #if DEBUG
            PassageMark.debugLast = "\(lines.count) lines at \(found.range) of \(NSStringFromClass(type(of: found.view))): \(lines.map { "\($0.integral)" }.joined(separator: " "))"
            #endif
            return !lines.isEmpty
        }

        override func draw(_ dirtyRect: NSRect) {
            // One path, filled once: where two lines' marks meet, no darker band.
            let path = NSBezierPath()
            for line in lines {
                path.append(NSBezierPath(roundedRect: line.insetBy(dx: -3, dy: -1.5), xRadius: 4, yRadius: 4))
            }
            NSColor.systemYellow.withAlphaComponent(0.35).setFill()
            path.fill()
        }
    }

    /// SwiftUI's selectable texts under `view`.
    static func texts(in view: NSView) -> [NSView] {
        view.subviews.flatMap { sub -> [NSView] in
            if sub.isHidden { return [] }
            return NSStringFromClass(type(of: sub)).contains("TextInteractionView") ? [sub] : texts(in: sub)
        }
    }

    /// Where `passage` is in `words`: as it is, else with spaces and line
    /// breaks left out of both (a quote comes trimmed, line by line).
    static func range(of passage: String, in words: String) -> NSRange? {
        let exact = (words as NSString).range(of: passage)
        if exact.location != NSNotFound { return exact }
        func kept(_ text: String) -> (units: [UInt16], places: [Int]) {
            var units: [UInt16] = []
            var places: [Int] = []
            for (i, unit) in text.utf16.enumerated() {
                if let scalar = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                units.append(unit)
                places.append(i)
            }
            return (units, places)
        }
        let have = kept(words)
        let want = kept(passage).units
        guard !want.isEmpty else { return nil }
        let at = (String(decoding: have.units, as: UTF16.self) as NSString).range(of: String(decoding: want, as: UTF16.self))
        guard at.location != NSNotFound, NSMaxRange(at) <= have.places.count else { return nil }
        let start = have.places[at.location]
        return NSRange(location: start, length: have.places[NSMaxRange(at) - 1] + 1 - start)
    }

    #if DEBUG
    /// What the last mark found, for the debug hooks' dump.
    static var debugLast = "-"
    #endif
}

/// Where a quoted passage is in a conversation: the rows' words, without
/// what Markdown adds, nor case.
enum QuoteSource {
    /// Letters and digits only, lowercased: `**bold** text` and the bold text shown are the same.
    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The last row before `end` that holds the passage, the agent's words first.
    static func row(holding quote: String, in rows: [TranscriptRow], before end: Int) -> Int? {
        let wanted = key(quote)
        guard !wanted.isEmpty else { return nil }
        let range = rows.indices.prefix(min(max(end, 0), rows.count))
        if let at = range.last(where: { key(words(rows[$0], prompts: false)).contains(wanted) }) { return at }
        return range.last { key(words(rows[$0], prompts: true)).contains(wanted) }
    }

    private static func words(_ row: TranscriptRow, prompts: Bool) -> String {
        func of(_ item: TranscriptItem) -> String {
            switch item.kind {
            case .prompt(let text, _): prompts ? text : ""
            case .command(let name, let output): name + "\n" + (output ?? "")
            case .text(let text), .thinking(let text): text
            case .tool(let call): [call.summary, call.result?.text ?? ""].joined(separator: "\n")
            case .notice: ""
            }
        }
        switch row {
        case .item(let item): return of(item)
        case .activity(_, let items): return items.map(of).joined(separator: "\n")
        }
    }
}

extension Notification.Name {
    /// Show where a quoted passage came from: `object` is the pane's address,
    /// `userInfo["quote"]` the passage, `userInfo["prompt"]` the message that quoted it.
    static let swiftrRevealQuote = Notification.Name("SwiftrRevealQuote")
    #if DEBUG
    /// Debug hooks: the conversation at `object` (an address) looks at what is selected, as after a click.
    static let swiftrDebugSelection = Notification.Name("SwiftrDebugSelection")
    #endif
}
