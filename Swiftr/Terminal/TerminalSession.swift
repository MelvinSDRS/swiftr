import AppKit
import HerdrKit
@preconcurrency import SwiftTerm
import Synchronization

/// One attach stream: bytes arrive on the connection's reader thread and are
/// parsed there, then credited (schema/README.md, "Flow control").
nonisolated final class AttachSink: StreamSink, @unchecked Sendable {
    private let feed: TerminalFeedSender
    private let closed: @Sendable (JSON?) -> Void
    private let sawPictures: @Sendable () -> Void
    #if DEBUG
    /// Bytes this stream brought, for the debug dump.
    let received = Mutex(0)
    #endif
    // Reader thread only.
    private var channel: UInt32 = 0
    private weak var connection: CoreConnection?
    private var picturesSeen = false

    /// `sawPictures` runs once, on the reader thread, when the stream first
    /// holds a kitty picture cell (U+10EEEE).
    init(feed: TerminalFeedSender, closed: @escaping @Sendable (JSON?) -> Void, sawPictures: @escaping @Sendable () -> Void) {
        self.feed = feed
        self.closed = closed
        self.sawPictures = sawPictures
    }

    func streamOpened(channel: UInt32, connection: CoreConnection, result: JSON) {
        self.channel = channel
        self.connection = connection
    }

    func streamData(_ bytes: UnsafeRawBufferPointer) {
        #if DEBUG
        received.withLock { $0 += bytes.count }
        #endif
        if !picturesSeen, Self.holdsPictureCell(bytes) {
            picturesSeen = true
            sawPictures()
        }
        feed.feed(byteArray: Array(bytes)[...])
        connection?.credit(channel, bytes.count)
    }

    /// U+10EEEE in UTF-8: the cell kitty draws a picture over.
    private static let pictureCell: [UInt8] = [0xF4, 0x8E, 0xBB, 0xAE]

    private static func holdsPictureCell(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress, bytes.count >= pictureCell.count else { return false }
        return pictureCell.withUnsafeBytes { memmem(base, bytes.count, $0.baseAddress, $0.count) != nil }
    }

    func streamResize(cols: Int, rows: Int) {}

    func streamClosed(reason: JSON?) {
        closed(reason)
    }
}

/// A cell's size, measured the way SwiftTerm measures it.
enum CellMetrics {
    static func points(for font: NSFont, scale: CGFloat) -> CGSize {
        let height = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        var chars: [UniChar] = [0x57]
        var glyphs: [CGGlyph] = [0]
        let width = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
            ? font.advancement(forGlyph: NSGlyph(glyphs[0])).width
            : font.maximumAdvancement.width
        return CGSize(width: max(1, (width * scale).rounded() / scale), height: max(1, ceil(height * scale) / scale))
    }

    static func pixels(for font: NSFont, scale: CGFloat) -> (Int, Int) {
        let p = points(for: font, scale: scale)
        return (Int((p.width * scale).rounded()), Int((p.height * scale).rounded()))
    }
}

/// One terminal shown by Swiftr: its SwiftTerm view and its attach stream.
@Observable
final class TerminalSession {
    enum Phase: Equatable {
        /// Not attached yet, or detached while hidden.
        case waiting
        case attaching
        case attached
        /// The connection or the program was lost: waiting to attach again.
        case lost
        /// The program ended (`exited`, `killed`...).
        case ended(String)
        case failed(String)
    }

    let address: String
    private(set) var phase: Phase = .waiting

    @ObservationIgnored let view: SwiftrTerminalView
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var channel: UInt32?
    @ObservationIgnored private var connection: CoreConnection?
    /// Rises with every attach and detach, so a late answer is dropped.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var sizeRetries = 0
    @ObservationIgnored private var toldDisplay: JSON?
    @ObservationIgnored private var toldFocus: Bool?
    /// A clean paint asked for after another client changed the size.
    @ObservationIgnored private var repaintTask: Task<Void, Never>?
    @ObservationIgnored private var painted = false
    @ObservationIgnored private var metalTried = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    #if DEBUG
    /// The stream now open or opening, for the debug dump.
    @ObservationIgnored private(set) var sink: AttachSink?
    #endif
    /// When it was last on screen, for keeping recent terminals attached.
    @ObservationIgnored var lastShown = Date.distantPast

    init(address: String, cols: Int, rows: Int, model: AppModel) {
        self.address = address
        self.model = model
        let prefs = model.prefs
        let font = prefs.font
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let cell = CellMetrics.points(for: font, scale: scale)
        // Sized as its grid, so attaching from out of sight changes nothing.
        let frame = CGRect(x: 0, y: 0, width: CGFloat(max(cols, 2)) * cell.width + 0.5, height: CGFloat(max(rows, 1)) * cell.height + 0.5)
        var options = TerminalOptions.default
        options.cols = max(cols, 2)
        options.rows = max(rows, 1)
        options.cursorStyle = prefs.blinkCursor ? .blinkBlock : .steadyBlock
        options.scrollback = prefs.scrollback
        options.ansi256PaletteStrategy = .xterm
        view = SwiftrTerminalView(frame: frame, font: font, options: options)
        view.terminalDelegate = self
        view.glyphFallbackProvider = NerdFontFallback.shared
        view.allowMouseReporting = true
        applyLook()
        view.onFocusChange = { [weak self] _ in self?.focusChanged() }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let w = self.view.window, window == ObjectIdentifier(w) else { return }
                    self.focusChanged()
                }
            })
        }
    }

    isolated deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    var isAttached: Bool { phase == .attached }

    // MARK: Look

    /// Font, colors and keys from the settings; tells the core when they change.
    func applyLook() {
        guard let prefs = model?.prefs else { return }
        let theme = prefs.theme
        let font = prefs.font
        if view.font != font { view.font = font }
        view.nativeBackgroundColor = theme.backgroundColor
        view.nativeForegroundColor = theme.foregroundColor
        view.caretColor = theme.cursorColor
        view.selectedTextBackgroundColor = theme.selectionColor
        // SwiftTerm writes selected text in this color, black unless told: dark
        // themes had black text on their selection.
        view.selectedTextForegroundColor = theme.foregroundColor
        view.installColors(theme.ansi.prefix(16).map { hex in
            let c = RGB(hex: hex) ?? RGB(hex: "#888888")!
            return SwiftTerm.Color(red: UInt16(c.r * 65535), green: UInt16(c.g * 65535), blue: UInt16(c.b * 65535))
        })
        switch prefs.optionKey {
        case .auto:
            view.optionAsMetaKey = false
            view.optionAsMetaKeyForFunctionalKeys = true
        case .meta:
            view.optionAsMetaKey = true
        case .characters:
            view.optionAsMetaKey = false
            view.optionAsMetaKeyForFunctionalKeys = false
        }
        refreshDisplay()
    }

    /// What the core answers color and cell-size queries with.
    private func display() -> JSON {
        guard let prefs = model?.prefs else { return .null }
        let theme = prefs.theme
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let (w, h) = CellMetrics.pixels(for: prefs.font, scale: scale)
        func hex(_ s: String?, _ fallback: String) -> JSON { .string(RGB(hex: s ?? fallback)?.hex ?? fallback) }
        return ["fg": hex(theme.foreground, "#ffffff"), "bg": hex(theme.background, "#000000"), "cursor": hex(theme.cursor, theme.foreground), "cell": [JSON(w), JSON(h)]]
    }

    private func refreshDisplay() {
        guard let channel, let connection else { return }
        let now = display()
        if now != toldDisplay {
            toldDisplay = now
            connection.facts(channel, now)
        }
    }

    // MARK: Attaching

    /// Attaches unless attached or attaching.
    func attach() {
        guard let model, let connection = model.connection else { return }
        switch phase {
        case .attached, .attaching, .ended: return
        default: break
        }
        attempt += 1
        let attempt = self.attempt
        phase = .attaching
        if painted {
            // The core paints the whole screen and its history again.
            view.feed(text: "\u{1b}c\u{1b}[3J")
            painted = false
            toldDisplay = nil
            applyLook()
        }
        let size = view.terminalDimensions
        let display = display()
        let box = WeakBox(self)
        let sink = AttachSink(feed: view.feedSender, closed: { reason in
            onMain { box.value?.closed(reason, attempt: attempt) }
        }, sawPictures: {
            onMain { box.value?.picturesShown(attempt: attempt) }
        })
        #if DEBUG
        self.sink = sink
        #endif
        Task {
            do {
                let a = try await connection.attach(address, cols: size.cols, rows: size.rows, history: 2000, display: display, sink: sink)
                guard attempt == self.attempt else {
                    connection.detach(a.channel)
                    return
                }
                // The first paint has the size asked for; a newer layout wants a new one.
                if view.window != nil, view.terminalDimensions != size, sizeRetries < 3 {
                    sizeRetries += 1
                    connection.detach(a.channel)
                    phase = .waiting
                    painted = true
                    attach()
                    return
                }
                sizeRetries = 0
                channel = a.channel
                self.connection = connection
                view.route.withLock { $0 = ReplyRoute(connection: connection, channel: a.channel, automatic: a.automaticInput) }
                toldDisplay = display
                toldFocus = nil
                painted = true
                phase = .attached
                refreshDisplay()
                focusChanged()
            } catch let error as CoreError {
                guard attempt == self.attempt else { return }
                painted = true
                switch error.kind {
                case "finished": phase = .ended("finished")
                case "not_found": phase = .ended("removed")
                case "unavailable", "lost", "timeout": phase = .lost
                default: phase = .failed(error.message)
                }
            } catch {
                guard attempt == self.attempt else { return }
                phase = .failed("\(error)")
            }
        }
    }

    /// The stream holds kitty picture cells. The core's first paint keeps
    /// those cells but not the pictures sent before this attach, so they
    /// would stay blank: SIGCONT makes the program repaint as after a
    /// suspend, and Claude Code sends its pictures again. Programs here only;
    /// a running program takes SIGCONT as a no-op unless it handles it.
    private func picturesShown(attempt: Int) {
        guard attempt == self.attempt, let m = model?.store.model(address), m.machine == nil,
              let pid = m.foreground?.pid, pid > 1 else { return }
        kill(pid_t(pid), SIGCONT)
    }

    /// Leaves the stream; the view keeps what it shows.
    func detach() {
        attempt += 1
        if let channel, let connection { connection.detach(channel) }
        view.route.withLock { $0 = nil }
        channel = nil
        connection = nil
        if phase == .attached || phase == .attaching { phase = .waiting }
    }

    /// After a loss (`restarted`) or a reconnect: attach again.
    func reattach() {
        switch phase {
        case .attached, .attaching: detach()
        case .ended, .failed: phase = .lost
        default: break
        }
        attach()
    }

    /// The connection dropped: every stream on it is gone.
    func connectionLost() {
        attempt += 1
        view.route.withLock { $0 = nil }
        channel = nil
        connection = nil
        if case .ended = phase { return }
        phase = .lost
    }

    private func closed(_ reason: JSON?, attempt: Int) {
        guard attempt == self.attempt else { return }
        view.route.withLock { $0 = nil }
        channel = nil
        connection = nil
        let why = reason?["reason"]?.string ?? ""
        if reason == nil || why.isEmpty {
            phase = .lost
        } else if why == "exited" || why == "killed" {
            phase = .ended(why)
        } else {
            // A kept terminal lost its program, or the core stopped: a new
            // shell comes with `restarted`.
            phase = .lost
        }
        model?.sessionClosed(self)
    }

    // MARK: Screen

    /// The view went on screen: use Metal, take the size and the focus.
    func didAppear() {
        lastShown = Date()
        if !metalTried {
            metalTried = true
            try? view.setUseMetal(true)
        }
        refreshDisplay()
        sendSize()
        if phase == .waiting || phase == .lost { attach() }
    }

    /// The grid changed: the pane's size while Swiftr is in front, else the
    /// size another client gave the terminal.
    private func sized(cols: Int, rows: Int) {
        if drivesSize {
            sendSize()
        } else if phase == .attached {
            // Output drawn for the new size may have come before the grid
            // changed: attach again for a paint made for it.
            repaintTask?.cancel()
            repaintTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, !self.drivesSize, self.phase == .attached else { return }
                self.reattach()
            }
        }
    }

    /// Swiftr sets a terminal's size only while it is the app in front: in
    /// the background it would take the size from the app being used.
    private var drivesSize: Bool { model?.appActive == true }

    /// Sends the grid of a view on screen, unless the core has it already.
    private func sendSize() {
        guard drivesSize, phase == .attached, let channel, let connection, view.window != nil else { return }
        let d = view.terminalDimensions
        if let m = model?.store.model(address), m.cols == d.cols, m.rows == d.rows { return }
        connection.resize(channel, cols: d.cols, rows: d.rows)
    }

    /// The view's size for a given grid, as SwiftTerm measures it.
    func frameSize(cols: Int, rows: Int) -> CGSize {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let cell = CellMetrics.points(for: view.font, scale: scale)
        let now = view.terminalDimensions
        // What SwiftTerm keeps beside the grid (a scroll bar, when shown).
        let extra = max(0, view.getOptimalFrameSize().width - CGFloat(now.cols) * cell.width)
        return CGSize(width: CGFloat(max(cols, 2)) * cell.width + extra + 0.5, height: CGFloat(max(rows, 1)) * cell.height + 0.5)
    }

    private func focusChanged() {
        let focused = view.hasFocus
        if focused {
            model?.terminalFocused(address)
            // Taken up again here: another app may have sized it meanwhile.
            sendSize()
        }
        guard phase == .attached, let channel, let connection, toldFocus != focused else { return }
        // Never "not focused" first: from an app in the background it could
        // hide the focus of the app being used.
        if toldFocus == nil && !focused { return }
        toldFocus = focused
        connection.focus(channel, focused)
    }

    /// Makes this terminal take the keyboard.
    func focus() {
        guard let window = view.window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    /// When keys last went in from here as the person's: the core holds
    /// sends back while their draft may be unsent (`draftEnded`).
    @ObservationIgnored private(set) var lastTyped: Date?

    /// The person's draft in the program's input was sent or cleared.
    func draftEnded() {
        lastTyped = nil
    }

    private func typed(_ data: ArraySlice<UInt8>) {
        guard let channel, let connection, phase == .attached else { return }
        sendSize()
        lastTyped = Date()
        connection.input(channel, Array(data))
    }
}

extension TerminalSession: TerminalViewDelegate {
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { sized(cols: newCols, rows: newRows) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { typed(data) }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        MainActor.assumeIsolated {
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    nonisolated func bell(source: TerminalView) {
        MainActor.assumeIsolated {
            if view.window?.isKeyWindow == true, view.hasFocus { NSSound.beep() }
        }
    }
}
