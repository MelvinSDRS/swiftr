import AppKit
import Foundation

/// What held the keyboard before a popover took it.
struct ModFocusMark {
    weak var responder: NSResponder?
    var handle: String?
    var key: String?
}

/// The layer a surface shows in: a window of its own over the app's, so
/// the surface can reach past the mod's panel, clear of whatever is beside
/// it. It takes the keyboard only for a field inside it.
final class ModSurfacePanel: NSPanel {
    /// Room around the content, for its shadow.
    static let pad: CGFloat = 32

    init(owner: ModView, key: String) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isMovable = false
        contentView = ModSurfaceView(owner: owner, key: key)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws one surface and hands the pointer back to the mod's view, which
/// knows the tree.
final class ModSurfaceView: NSView {
    weak var owner: ModView?
    let key: String
    private var tracking: NSTrackingArea?

    init(owner: ModView, key: String) {
        self.owner = owner
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let owner, let node = owner.surfaces.first(where: { $0.key == key }) else { return }
        owner.paint(surface: node, in: context, at: CGPoint(x: ModSurfacePanel.pad, y: ModSurfacePanel.pad), dirty: dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// A press began in the clear room around the surface: it and what
    /// follows it belong to the window underneath.
    private var passing = false

    /// The room kept clear around the surface, for its shadow, is not the
    /// surface: a press there goes to what the person sees under it, in the
    /// window the layer floats over.
    private func pass(_ event: NSEvent, begins: Bool = false) -> Bool {
        if begins { passing = !bounds.insetBy(dx: ModSurfacePanel.pad, dy: ModSurfacePanel.pad).contains(convert(event.locationInWindow, from: nil)) }
        guard passing, let layer = window, let under = owner?.window else { return false }
        let at = under.convertPoint(fromScreen: layer.convertPoint(toScreen: event.locationInWindow))
        guard let copy = NSEvent.mouseEvent(with: event.type, location: at, modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                            windowNumber: under.windowNumber, context: nil, eventNumber: event.eventNumber,
                                            clickCount: event.clickCount, pressure: event.pressure) else { return false }
        if begins { owner?.pressedElsewhere(copy) }
        under.sendEvent(copy)
        return true
    }

    override func mouseMoved(with event: NSEvent) { owner?.mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { owner?.mouseEntered(with: event) }
    override func mouseExited(with event: NSEvent) { owner?.mouseMoved(with: event) }
    override func mouseDragged(with event: NSEvent) { if !pass(event) { owner?.mouseDragged(with: event) } }
    override func mouseDown(with event: NSEvent) { if !pass(event, begins: true) { owner?.mouseDown(with: event) } }
    override func mouseUp(with event: NSEvent) { if !pass(event) { owner?.mouseUp(with: event) }; passing = false }
    override func rightMouseDown(with event: NSEvent) { if !pass(event, begins: true) { owner?.rightMouseDown(with: event) } }
    override func rightMouseUp(with event: NSEvent) { if !pass(event) { owner?.rightMouseUp(with: event) }; passing = false }
    override func otherMouseDown(with event: NSEvent) { if !pass(event, begins: true) { owner?.otherMouseDown(with: event) } }
    override func otherMouseUp(with event: NSEvent) { if !pass(event) { owner?.otherMouseUp(with: event) }; passing = false }
    override func scrollWheel(with event: NSEvent) { owner?.scrollWheel(with: event) }
}

extension ModView {
    // MARK: Which surfaces show

    /// Open, as the script or Swiftr holds it, whatever the surface has to show.
    func wantsOpen(_ owner: ModNode) -> Bool {
        guard let popup = owner.popup else { return false }
        switch popup.kind {
        case .popup: return true
        case .popover: return popup.controlled ?? surfaceOpen[owner.key] ?? popup.defaultOpen
        case .hoverCard: return surfaceOpen[owner.key] ?? false
        }
    }

    func isOpen(_ owner: ModNode) -> Bool { owner.popup?.content != nil && wantsOpen(owner) }

    /// Every node that is live: the panel's, and the content of the
    /// surfaces that show.
    func each(_ visit: (ModNode) -> Void) {
        tree?.walk(open: { self.isOpen($0) }, visit)
    }

    /// Whether `node` is `ancestor` or under it, a surface counting as
    /// under the node that opens it.
    func within(_ node: ModNode, _ ancestor: ModNode) -> Bool {
        var at: ModNode? = node
        while let current = at {
            if current === ancestor { return true }
            at = current.parent
        }
        return false
    }

    /// In the surface `owner` opens, or in one opened from inside it.
    func inside(_ owner: ModNode, _ point: CGPoint) -> Bool {
        guard let content = owner.popup?.content else { return false }
        return surfaces.contains { other in
            guard let rect = other.popup?.rect, rect.contains(point) else { return false }
            return other === owner || within(other, content)
        }
    }

    // MARK: Where things are

    /// The nodes under a point, innermost first. A surface is over the panel.
    func chain(at point: CGPoint) -> [ModHit.Found] {
        guard let tree else { return [] }
        for owner in surfaces.reversed() {
            guard let popup = owner.popup, let content = popup.content, popup.rect.contains(point) else { continue }
            return ModHit.chain(content, origin: popup.rect.origin, at: point, scroll: state.scroll)
        }
        return ModHit.chain(tree, at: point, scroll: state.scroll)
    }

    func locate(_ match: (ModNode) -> Bool) -> ModHit.Found? {
        guard let tree else { return nil }
        for owner in surfaces.reversed() {
            guard let popup = owner.popup, let content = popup.content else { continue }
            if let found = ModHit.locate(content, origin: popup.rect.origin, scroll: state.scroll, where: match) { return found }
        }
        return ModHit.locate(tree, origin: .zero, scroll: state.scroll, where: match)
    }

    /// Where a node is, in the view's space.
    func rect(of node: ModNode) -> CGRect? { locate { $0 === node }?.rect }

    /// What surfaces must stay inside: the window, or this view in a picture.
    private var surfaceRoom: CGRect {
        guard let content = window?.contentView else { return bounds }
        return convert(content.bounds, from: content)
    }

    // MARK: Layout

    /// Lays out the content of each surface that shows and pins it to its
    /// trigger, inside the window.
    func layoutSurfaces() {
        surfaces = []
        guard let tree else { return }
        let room = surfaceRoom.insetBy(dx: 8, dy: 8)

        func place(_ owner: ModNode, anchor: CGRect) {
            guard let popup = owner.popup, let content = popup.content else { return }
            var base = owner.textStyle
            base.ellipsis = false
            base.clamp = 0
            ModLayout.layout(content, width: nil, height: nil, baseStyle: base)
            if content.frame.width > room.width, room.width > 0 { ModLayout.layout(content, width: room.width, height: nil, baseStyle: base) }
            placeSliders(in: content)
            // The content's margins keep it off its trigger (`mt(4)`).
            func px(_ key: String) -> CGFloat { if case .px(let v)? = ModLength(content.style[key]) { return v }; return 0 }
            let left = content.restOrigin.x, top = content.restOrigin.y
            let size = CGSize(width: left + content.frame.width + px("mr"), height: top + content.frame.height + px("mb"))
            var origin: CGPoint
            switch popup.anchor {
            case "top_right": origin = CGPoint(x: anchor.maxX - size.width, y: anchor.maxY)
            case "top_center": origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY)
            case "bottom_left": origin = CGPoint(x: anchor.minX, y: anchor.minY - size.height)
            case "bottom_right": origin = CGPoint(x: anchor.maxX - size.width, y: anchor.minY - size.height)
            case "bottom_center": origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height)
            case "left_center": origin = CGPoint(x: anchor.maxX, y: anchor.midY - size.height / 2)
            case "right_center": origin = CGPoint(x: anchor.minX - size.width, y: anchor.midY - size.height / 2)
            default: origin = CGPoint(x: anchor.minX, y: anchor.maxY)
            }
            // Clear of the edges, the top and the left first.
            origin.x = max(room.minX, min(origin.x, room.maxX - size.width))
            origin.y = max(room.minY, min(origin.y, room.maxY - size.height))
            content.frame.origin = .zero
            content.restOrigin = .zero
            popup.rect = CGRect(x: (origin.x + left).rounded(), y: (origin.y + top).rounded(), width: content.frame.width, height: content.frame.height)
        }

        func visit(_ node: ModNode, origin: CGPoint) {
            guard node.display != "none" else { return }
            let rect = node.frame.offsetBy(dx: origin.x, dy: origin.y)
            if let popup = node.popup, let content = popup.content, wantsOpen(node), node.visible {
                place(node, anchor: rect)
                surfaces.append(node)
                visit(content, origin: popup.rect.origin)
            }
            var childOrigin = rect.origin
            if let offset = state.scroll[node.key] {
                childOrigin.x -= offset.x
                childOrigin.y -= offset.y
            }
            for child in node.children { visit(child, origin: childOrigin) }
        }
        visit(tree, origin: .zero)
    }

    // MARK: Their windows

    /// Gives each surface that shows its layer over the window, where the
    /// layout put it, and takes away the layers of those that shut.
    func syncPanels() {
        guard let window, isShown, !isHiddenOrHasHiddenAncestor else {
            closePanels()
            return
        }
        var seen = Set<String>()
        let pad = ModSurfacePanel.pad
        for owner in surfaces {
            guard let popup = owner.popup else { continue }
            seen.insert(owner.key)
            let panel = surfacePanels[owner.key] ?? ModSurfacePanel(owner: self, key: owner.key)
            surfacePanels[owner.key] = panel
            panel.appearance = window.effectiveAppearance
            let frame = window.convertToScreen(convert(popup.rect.insetBy(dx: -pad, dy: -pad), to: nil))
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
            panel.contentView?.needsDisplay = true
        }
        for (key, panel) in surfacePanels where !seen.contains(key) {
            close(panel)
            surfacePanels[key] = nil
        }
        placedAt = convert(bounds, to: nil)
    }

    private func close(_ panel: ModSurfacePanel) {
        let hadKeyboard = panel.isKeyWindow
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if hadKeyboard { window?.makeKey() }
    }

    func closePanels() {
        for panel in surfacePanels.values { close(panel) }
        surfacePanels = [:]
    }

    /// The panel left the screen: nothing of it stays over the window.
    func hideSurfaces() {
        for timer in hoverTimers.values { timer.invalidate() }
        hoverTimers = [:]
        hoverGoals = [:]
        for owner in surfaces where owner.popup?.kind == .hoverCard { surfaceOpen[owner.key] = false }
        for owner in surfaces where owner.popup?.kind == .popover && owner.popup?.closable == true { setOpen(owner, false, gesture: false) }
        closePanels()
    }

    /// The panel moved inside its window (a sidebar slid, a split was
    /// dragged): the surfaces follow.
    func followWindow() {
        guard !surfacePanels.isEmpty, window != nil else { return }
        if convert(bounds, to: nil) != placedAt { relayout() }
    }

    // MARK: Opening and shutting

    func toggle(_ owner: ModNode) { setOpen(owner, !wantsOpen(owner)) }

    func setOpen(_ owner: ModNode, _ open: Bool, gesture: Bool = true) {
        guard let popup = owner.popup, popup.kind != .popup, wantsOpen(owner) != open else { return }
        if popup.kind == .hoverCard || popup.controlled == nil { surfaceOpen[owner.key] = open }
        if gesture { copy.runtime.lastGesture = Date() }
        // The script's own state follows from here; a popover it does not
        // hold shows or goes at once.
        if let handler = popup.openHandler { copy.dispatch(handler, payload: ["args": [open]], gesture: gesture) }
        relayout()
    }

    /// A press: one outside an open popover shuts it; one on a trigger that
    /// opens by this button, other than the left, opens it.
    func pressSurfaces(chain: [ModHit.Found], at point: CGPoint, button: String) {
        for owner in surfaces.reversed() {
            guard let popup = owner.popup, popup.kind == .popover, popup.closable else { continue }
            // Inside it, or on its trigger (the release there shuts it).
            if inside(owner, point) || chain.contains(where: { $0.node === owner }) { continue }
            setOpen(owner, false)
        }
        if button != "left", let trigger = chain.first(where: { $0.node.popup?.kind == .popover && $0.node.popup?.button == button })?.node,
           !trigger.isDisabled {
            toggle(trigger)
        }
    }

    /// Hears presses that land elsewhere in the app while a popover is open
    /// or an element asked to hear them (`on_mouse_down_out`).
    func watchOutsidePresses() {
        let wanted = window != nil && (surfaces.contains { $0.popup?.kind == .popover } || byKey.values.contains { $0.handlers["downout"] != nil })
        if wanted, outsideMonitor == nil {
            outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                nonisolated(unsafe) let pressed = event
                MainActor.assumeIsolated { self?.pressedElsewhere(pressed) }
                return event
            }
        } else if !wanted, let monitor = outsideMonitor {
            NSEvent.removeMonitor(monitor)
            outsideMonitor = nil
        }
    }

    /// Files are taken only by a mod that has somewhere to drop them: any
    /// other lets the drag through to what lies behind its panel.
    func watchDrops() {
        let wanted = window != nil && byKey.values.contains { $0.handlers["drop"] != nil }
        guard wanted != takesDrops else { return }
        takesDrops = wanted
        if wanted { registerForDraggedTypes([.fileURL]) } else { unregisterDraggedTypes() }
    }

    func pressedElsewhere(_ event: NSEvent) {
        guard let window else { return }
        // A press this view or one of its surfaces gets is dealt with there.
        if let from = event.window {
            if surfacePanels.values.contains(where: { $0 === from }) { return }
            if from === window, let hit = window.contentView?.hitTest(event.locationInWindow), hit === self || hit.isDescendant(of: self) { return }
        }
        let button = event.type == .leftMouseDown ? "left" : event.type == .rightMouseDown ? "right" : "middle"
        let payload = mouse(flags: event.modifierFlags, clicks: event.clickCount, point: point(of: event), found: nil, button: button)
        for node in byKey.values { if let handler = node.handlers["downout"] { copy.dispatch(handler, payload: payload, gesture: true) } }
        for owner in surfaces.reversed() where owner.popup?.kind == .popover && owner.popup?.closable == true { setOpen(owner, false) }
    }

    /// A hover card opens once the pointer has rested on its trigger, and
    /// shuts once it has left both the trigger and the card.
    func watchHoverCards(chain: [ModHit.Found], at point: CGPoint?) {
        for owner in hoverCards {
            guard let popup = owner.popup else { continue }
            let key = owner.key
            let open = surfaceOpen[key] ?? false
            var over = chain.contains { $0.node === owner }
            if !over, open, let point { over = inside(owner, point) }
            if over == open {
                hoverTimers.removeValue(forKey: key)?.invalidate()
                hoverGoals[key] = nil
                continue
            }
            guard hoverTimers[key] == nil else { continue }
            let timer = Timer(timeInterval: over ? popup.openDelay : popup.closeDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hoverFired(key, open: over) }
            }
            RunLoop.main.add(timer, forMode: .common)
            hoverTimers[key] = timer
            hoverGoals[key] = over
        }
    }

    private func hoverFired(_ key: String, open: Bool) {
        hoverTimers[key] = nil
        hoverGoals[key] = nil
        guard (surfaceOpen[key] ?? false) != open else { return }
        surfaceOpen[key] = open
        relayout()
    }

    /// For tests and `swiftr-mod`: rests the pointer on the first element
    /// that shows `text` (nil: takes it away), as long as a hover card waits.
    @discardableResult
    public func hover(text: String?) -> Bool {
        var point: CGPoint?
        if let text {
            guard let found = locate({ $0.kind == .text && $0.text == text }) else { return false }
            point = CGPoint(x: found.rect.midX, y: found.rect.midY)
        }
        setHover(at: point, event: nil)
        for (key, goal) in hoverGoals {
            hoverTimers.removeValue(forKey: key)?.invalidate()
            hoverFired(key, open: goal)
        }
        return true
    }

    // MARK: The keyboard, in and out

    /// After a layout: a popover that just opened takes the keyboard, one
    /// that just shut gives it back; a `Select` hands it between its
    /// trigger and its list.
    func surfacesChanged() {
        var now: [String: ModNode] = [:]
        for owner in surfaces where owner.popup?.kind == .popover { now[owner.key] = owner }
        for (key, owner) in now where openPopovers[key] == nil {
            openPopovers[key] = ModFocusMark(responder: window?.firstResponder, handle: state.focusedHandle, key: state.focusedKey)
            // Only from the person's own hand: a popover that opens by
            // itself (`default_open`, a timer) leaves the keyboard where it
            // is, in the terminal say.
            guard holdsKeyboard || Date().timeIntervalSince(copy.runtime.lastGesture) < 1 else { continue }
            if let handle = owner.popup?.focusHandle { focus(handle: handle) } else if let content = owner.popup?.content { focus(node: content, byKey: false) }
        }
        for (key, mark) in openPopovers where now[key] == nil {
            openPopovers[key] = nil
            giveBack(mark)
        }
        watchDrops()

        var selects = Set<String>()
        for node in byKey.values where (node.part == "select" || node.part == "combobox") && node.state["open"] == true { selects.insert(node.key) }
        for key in selects.subtracting(openSelects) { if let handle = byKey[key]?.contentFocus { focus(handle: handle) } }
        for key in openSelects.subtracting(selects) {
            guard let node = byKey[key], let handle = node.focusHandle, state.focusedHandle == node.contentFocus else { continue }
            focus(handle: handle)
        }
        openSelects = selects
        watchOutsidePresses()
    }

    /// Whether the keyboard is in this mod: on the panel, in one of its
    /// fields, or in a surface's own layer. In a picture, when the mod was
    /// given it.
    var holdsKeyboard: Bool {
        guard let window else { return takesKeyboard }
        if surfacePanels.values.contains(where: { $0.isKeyWindow }) { return true }
        let first = window.firstResponder
        return first === self || (first as? NSView).map { $0.isDescendant(of: self) } ?? false
    }

    /// The keyboard goes back to what had it, unless the person has already
    /// put it elsewhere.
    private func giveBack(_ mark: ModFocusMark) {
        guard let window else {
            state.focusedHandle = mark.handle
            state.focusedKey = mark.key
            return
        }
        guard holdsKeyboard else { return }
        if let responder = mark.responder, responder !== self {
            // The terminal, a field (through its editor), or nothing at
            // all: the window itself.
            var back: NSResponder? = responder is NSWindow ? nil : responder
            if let editor = responder as? NSText, let field = editor.delegate as? NSTextField { back = field }
            if let view = back as? NSView, view.window !== window { back = nil }
            state.focusedKey = nil
            state.showsRing = false
            if state.focusedHandle != mark.handle {
                state.focusedHandle = mark.handle
                copy.focusChanged(mark.handle)
            }
            window.makeFirstResponder(back)
        } else {
            state.focusedHandle = mark.handle
            state.focusedKey = mark.key
            copy.focusChanged(mark.handle)
            if window.firstResponder !== self { window.makeFirstResponder(self) }
        }
        needsDisplay = true
    }

    // MARK: For tests

    /// The surfaces that show: what kind, where in the panel, and whether
    /// each has its own layer over the window and the keyboard there.
    public func surfaceReport() -> [[String: Any]] {
        surfaces.map { owner in
            let rect = owner.popup?.rect ?? .zero
            let panel = surfacePanels[owner.key]
            var kind = "popup"
            if owner.popup?.kind == .popover { kind = "popover" } else if owner.popup?.kind == .hoverCard { kind = "hover-card" }
            var out: [String: Any] = ["kind": kind, "rect": [rect.minX, rect.minY, rect.width, rect.height], "layer": panel != nil]
            if let panel {
                out["layer_frame"] = [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height]
                out["layer_key"] = panel.isKeyWindow
                out["layer_shown"] = panel.isVisible
                out["layer_number"] = panel.windowNumber
            }
            return out
        }
    }

    /// Where a real pointer event must go to land on the element that
    /// shows `text`: the window (a surface's own layer, or the panel's) and
    /// the point in it.
    public func eventPlace(ofText text: String) -> (window: NSWindow, point: CGPoint)? {
        guard let window, let found = locate({ $0.kind == .text && $0.text == text }) else { return nil }
        let middle = CGPoint(x: found.rect.midX, y: found.rect.midY)
        let inWindow = convert(middle, to: nil)
        for panel in surfacePanels.values {
            let there = panel.convertPoint(fromScreen: window.convertPoint(toScreen: inWindow))
            if panel.contentView?.bounds.insetBy(dx: ModSurfacePanel.pad, dy: ModSurfacePanel.pad).contains(panel.contentView?.convert(there, from: nil) ?? .zero) == true {
                return (panel, there)
            }
        }
        return (window, inWindow)
    }

    /// The same for the field with this hint, which sits in its own layer
    /// when a surface holds it.
    public func eventPlace(ofFieldWithHint hint: String) -> (window: NSWindow, point: CGPoint)? {
        guard let field = fields.values.first(where: { $0.placeholderString == hint && !$0.isHidden }), let home = field.window else { return nil }
        return (home, field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil))
    }

    /// A press on the element that shows `text`, let go `by` away from it:
    /// a slider's or a divider's drag.
    @discardableResult
    public func drag(fromText text: String, by: CGSize) -> Bool {
        guard let found = locate({ $0.kind == .text && $0.text == text }) else { return false }
        return drag(from: CGPoint(x: found.rect.midX, y: found.rect.midY), by: by)
    }

    /// The same from a point of the panel.
    @discardableResult
    public func drag(from start: CGPoint, by: CGSize) -> Bool {
        let end = CGPoint(x: start.x + by.width, y: start.y + by.height)
        press(at: start, button: "left", clicks: 1, flags: [])
        let taken = drag(to: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), event: nil)
        _ = drag(to: end, event: nil)
        release(at: end, button: "left", clicks: 1, flags: [])
        setHover(at: nil, event: nil)
        return taken
    }

    /// What holds the keyboard in the mod, for a dump: a part's name and
    /// its id, or the script's own handle.
    public var focusReport: String {
        guard let node = focusedNode() else { return "" }
        return [node.part ?? "element", node.id ?? "", state.showsRing ? "ring" : ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The topmost popover that shows, for Escape.
    var topPopover: ModNode? { surfaces.last { $0.popup?.kind == .popover } }
}
