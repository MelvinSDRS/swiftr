import AppKit
import SwiftUI

/// Holds a session's SwiftTerm view while a pane shows it. The view belongs
/// to the session, so it survives tab switches; this container only lends
/// it a place on screen.
final class TerminalContainer: NSView {
    private(set) var session: TerminalSession?
    var inset = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 4)
    /// The terminal's size set by another client, which the view keeps while
    /// Swiftr is in the background; nil: the view fills the pane.
    var followGrid: GridSize? {
        didSet { if followGrid != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ next: TerminalSession, background: NSColor) {
        layer?.backgroundColor = background.cgColor
        guard next !== session else { return }
        if let old = session, old.view.superview === self { old.view.removeFromSuperview() }
        session = next
        next.view.autoresizingMask = []
        addSubview(next.view)
        needsLayout = true
        if window != nil { appeared() }
    }

    /// Gives the view back; it stays with its session.
    func release() {
        if let s = session, s.view.superview === self { s.view.removeFromSuperview() }
        session = nil
    }

    override func layout() {
        super.layout()
        guard let session, session.view.superview === self else { return }
        let pane = NSRect(x: inset.left, y: inset.bottom, width: max(0, bounds.width - inset.left - inset.right), height: max(0, bounds.height - inset.top - inset.bottom))
        var frame = pane
        if let grid = followGrid {
            // Top left, cut at the pane's edges when bigger.
            let size = session.frameSize(cols: grid.cols, rows: grid.rows)
            frame = NSRect(x: pane.minX, y: pane.maxY - size.height, width: size.width, height: size.height)
        }
        if session.view.frame != frame { session.view.frame = frame }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { appeared() }
    }

    private func appeared() {
        // After this layout pass, so the grid has its final size.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let s = self.session, s.view.superview === self, self.window != nil else { return }
                self.layoutSubtreeIfNeeded()
                s.didAppear()
                if self.pendingFocus { self.takeFocus() }
            }
        }
    }

    /// The model wants this pane to have the keyboard: now if it is on
    /// screen, else as soon as it is.
    private var pendingFocus = false

    func focusWhenShown() {
        pendingFocus = true
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.takeFocus() }
        }
    }

    private func takeFocus() {
        guard pendingFocus, let s = session, s.view.superview === self, let window else { return }
        pendingFocus = false
        // Not while someone types a name somewhere else.
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return }
        s.focus()
    }
}

/// A terminal's grid in cells.
struct GridSize: Equatable {
    let cols: Int
    let rows: Int
}

struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    let background: NSColor
    let followGrid: GridSize?
    let focused: Bool
    let focusTick: Int

    final class Coordinator {
        var tick = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalContainer {
        let container = TerminalContainer()
        container.followGrid = followGrid
        container.show(session, background: background)
        return container
    }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        container.followGrid = followGrid
        container.show(session, background: background)
        if focused, context.coordinator.tick != focusTick {
            context.coordinator.tick = focusTick
            container.focusWhenShown()
        }
    }

    static func dismantleNSView(_ container: TerminalContainer, coordinator: Coordinator) {
        container.release()
    }
}
