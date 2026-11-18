import AppKit
import Foundation

/// One copy of a mod on screen: Swiftr asks its script what the panel
/// holds, lays that out, and draws it here. The pointer, the wheel and the
/// keyboard go back to the script's handlers.
public final class ModView: NSView, ModSurface, NSTextFieldDelegate {
    public let copy: ModCopy
    let center: ModCenter
    let images: ModImages
    var tree: ModNode?
    var state = ModPaintState()
    var renderQueued = false
    /// Nodes that listen or look different under the pointer, by key.
    var byKey: [String: ModNode] = [:]
    var lists: [String: ModNode] = [:]
    var rowEstimates: [String: CGFloat] = [:]
    var hoverChain: [ModHit.Found] = []
    var downKeys: [String] = []
    var fields: [String: NSTextField] = [:]
    var fieldRevisions: [String: Int] = [:]
    var pendingFieldFocus: String?
    var wantsKeyboard = false
    var clock: Timer?
    var clockRate = 0
    var tracking: NSTrackingArea?

    // Surfaces: popups, popovers, hover cards (ModSurfaces.swift).
    /// The nodes whose surface shows, a surface inside another after it.
    var surfaces: [ModNode] = []
    /// Open or shut, by key, for the ones whose state Swiftr holds.
    var surfaceOpen: [String: Bool] = [:]
    var surfacePanels: [String: ModSurfacePanel] = [:]
    var hoverCards: [ModNode] = []
    var hoverTimers: [String: Timer] = [:]
    /// Open or shut: what each running hover timer will do.
    var hoverGoals: [String: Bool] = [:]
    /// The popovers open at the last layout, and what held the keyboard
    /// before each.
    var openPopovers: [String: ModFocusMark] = [:]
    var openSelects: Set<String> = []
    var outsideMonitor: Any?
    var takesDrops = false
    var placedAt = CGRect.null

    // Motion: transitions, springs, loops (ModMotion.swift).
    var runs: [String: ModRun] = [:]
    var targets: [String: ModLength] = [:]
    /// What VoiceOver was told of the panel: its elements by node key, in
    /// reading order. Nil order: to describe again.
    var accessCache: [String: ModAccessElement] = [:]
    var accessOrder: [String]?
    var accessNodes: [String: ModNode] = [:]
    /// The panel's name for VoiceOver; the mod's folder name without it.
    public var accessTitle: String?
    /// Holds the motion clock still, for tests.
    var timeOverride: CFTimeInterval?
    var dragOrigin = CGPoint.zero

    // Parts with a state of their own (ModParts.swift).
    /// A slider's value while Swiftr moves it, by its state.
    var sliderValues: [String: [Double]] = [:]
    var sliderDrag: (state: String, thumb: Int, key: String)?
    /// The sizes the person gave a resizable group's panes, by its id.
    var paneSizes: [String: [CGFloat]] = [:]
    var paneDrag: (group: String, index: Int, start: CGFloat, sizes: [CGFloat])?
    var reportedSizes: [String: CGSize] = [:]
    /// The node pressed that hands files over when dragged.
    var dragCandidate: ModNode?
    var dropKey: String?
    /// Takes the keyboard when it shows: for a mod opened over the window.
    public var takesKeyboard = false { didSet { if takesKeyboard { wantsKeyboard = true } } }
    /// Told how tall the panel would be with all the room it wants, each
    /// time that changes: for a dialog as tall as what it holds.
    public var onNaturalHeight: ((CGFloat) -> Void)?
    var naturalHeight: CGFloat = -1
    /// Text where the mod sets no size or font.
    public var baseSize: CGFloat = 16 { didSet { relayout() } }
    /// On a surface of its own (a sidebar): the mod's outer box is drawn
    /// without its fill, border and rounded corners.
    public var isFlush = false {
        didSet {
            guard isFlush != oldValue else { return }
            state.flush = isFlush
            needsDisplay = true
        }
    }

    public init(copy: ModCopy) {
        self.copy = copy
        center = copy.runtime.center
        let folder = copy.runtime.folder
        let center = center
        images = ModImages { path in
            if let found = center.asset(path) { return found }
            guard !path.split(separator: "/").contains("..") else { return nil }
            let own = folder.appending(path: path)
            return FileManager.default.fileExists(atPath: own.path) ? own : nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        copy.surface = self
        copy.onInvalidate = { [weak self] in self?.queueRender() }
        queueRender()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Render, layout

    /// False while the panel is out of sight (a stack's other child, a
    /// hidden part): its script keeps its timers, and it draws again only
    /// when it shows.
    public var isShown = true {
        didSet {
            // Out of sight, a surface would float over what took its place.
            if isShown != oldValue {
                if isShown { syncPanels() } else { hideSurfaces() }
                // A spinner out of sight costs nothing: its clock stops.
                runClock()
            }
            guard isShown, !oldValue, stale else { return }
            stale = false
            queueRender()
        }
    }
    var stale = false

    func queueRender() {
        guard isShown else { stale = true; return }
        guard !renderQueued else { return }
        renderQueued = true
        // Once per turn of the run loop, however many times the script asked.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.renderNow() }
        }
    }

    /// Asks the script for the panel now.
    public func renderNow() {
        renderQueued = false
        let started = CACurrentMediaTime()
        ModNode.pictureExists = { [images] in images.size($0) != nil }
        guard let made = copy.render() else {
            needsDisplay = true
            return
        }
        let described = CACurrentMediaTime()
        tree = made
        startMotion(in: made)
        relayout()
        lastRenderMs["script"] = (described - started) * 1000
        lastRenderMs["layout"] = (CACurrentMediaTime() - described) * 1000
        renders += 1
    }

    /// How long the last pass took, in milliseconds: `script` (the mod's
    /// render and reading what it wrote), `layout`, `paint`.
    public private(set) var lastRenderMs: [String: Double] = [:]
    public private(set) var renders = 0

    func relayout() {
        guard let tree else { return }
        applyMotion(at: motionTime)
        applyPanes()
        if let onNaturalHeight, bounds.width > 0 {
            layout(tree, width: bounds.width, height: nil)
            let height = ceil(tree.frame.height)
            if height != naturalHeight {
                naturalHeight = height
                onNaturalHeight(height)
            }
        }
        layout(tree, width: bounds.width, height: bounds.height)
        layoutSurfaces()
        var index: [String: ModNode] = [:]
        var found: [String: ModNode] = [:]
        var cards: [ModNode] = []
        var again = false
        each { node in
            if node.isInteractive || node.scrolls { index[node.key] = node }
            if node.popup?.kind == .hoverCard { cards.append(node) }
            guard node.kind == .vlist || node.kind == .hlist, let id = node.id else { return }
            found[id] = node
            guard let sizes = node.listSizes else { return }
            // A list whose rows the mod didn't size: the first row tells.
            if !sizes.known, let first = node.children.first {
                let real = node.kind == .vlist ? first.frame.height : first.frame.width
                if real > 0, abs((rowEstimates[id] ?? 0) - real) > 0.5 { rowEstimates[id] = real; again = true }
            }
        }
        byKey = index
        lists = found
        hoverCards = cards
        if again {
            layout(tree, width: bounds.width, height: bounds.height)
            layoutSurfaces()
        }
        clampScroll()
        // Rows that should show and weren't described: ask again.
        for (id, node) in found where !covers(node, wanted: wantedRows(id: id, node: node)) { queueRender() }
        syncPanels()
        syncFields()
        refreshHover()
        runClock()
        applySelection()
        surfacesChanged()
        reportSizes()
        accessChanged()
        needsDisplay = true
    }

    func layout(_ tree: ModNode, width: CGFloat?, height: CGFloat?) {
        ModLayout.intrinsicSize = { [images] in images.size($0) }
        tree.walk(open: { _ in true }) { node in
            if node.kind == .vlist || node.kind == .hlist, let id = node.id { node.rowEstimate = rowEstimates[id] }
        }
        var base = ModTextStyle()
        base.size = baseSize
        ModLayout.layout(tree, width: width, height: height, baseStyle: base)
        placeSliders(in: tree)
    }

    public override var needsDisplay: Bool {
        didSet { if needsDisplay { for panel in surfacePanels.values { panel.contentView?.needsDisplay = true } } }
    }

    public override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        for panel in surfacePanels.values { panel.contentView?.needsDisplay = true }
    }

    /// Where an event happened, in this view's space: the event may come
    /// from a surface's own window.
    func point(of event: NSEvent) -> CGPoint {
        guard let from = event.window, let window, from !== window else { return convert(event.locationInWindow, from: nil) }
        return convert(window.convertPoint(fromScreen: from.convertPoint(toScreen: event.locationInWindow)), from: nil)
    }

    /// The size the panel wants: for an overlay as tall as what it holds.
    public func fittingSize(width: CGFloat?, height: CGFloat?) -> CGSize {
        if tree == nil { tree = copy.render() }
        guard let tree else { return .zero }
        layout(tree, width: width, height: height)
        let size = tree.frame.size
        relayout()
        return size
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    func wantedRows(id: String, node: ModNode) -> Range<Int> {
        guard let sizes = node.listSizes else { return 0..<0 }
        let offset = state.scroll[node.key] ?? .zero
        return node.kind == .vlist
            ? sizes.rows(from: offset.y, to: offset.y + node.frame.height)
            : sizes.rows(from: offset.x, to: offset.x + node.frame.width)
    }

    func covers(_ node: ModNode, wanted: Range<Int>) -> Bool {
        let from = (node.raw["from"] as? NSNumber)?.intValue ?? 0
        // The rows on screen, without the spare ones around them.
        guard let sizes = node.listSizes else { return true }
        let offset = state.scroll[node.key] ?? .zero
        let start = node.kind == .vlist ? offset.y : offset.x
        let length = node.kind == .vlist ? node.frame.height : node.frame.width
        var first = 0, last = 0
        if let uniform = sizes.uniform, uniform > 0 {
            first = max(0, Int(start / uniform))
            last = min(sizes.count, Int(((start + length) / uniform).rounded(.up)))
        } else {
            first = wanted.lowerBound
            last = wanted.upperBound
        }
        return last <= first || (from <= first && from + node.children.count >= last)
    }

    func clampScroll() {
        for (key, offset) in state.scroll {
            guard let node = byKey[key] else { state.scroll[key] = nil; continue }
            let limit = CGPoint(x: max(0, node.contentSize.width - node.frame.width), y: max(0, node.contentSize.height - node.frame.height))
            let clamped = CGPoint(x: min(max(offset.x, 0), limit.x), y: min(max(offset.y, 0), limit.y))
            if clamped != offset { state.scroll[key] = clamped }
        }
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let started = CACurrentMediaTime()
        paint(in: context, dirty: dirtyRect, fields: false)
        lastRenderMs["paint"] = (CACurrentMediaTime() - started) * 1000
    }

    func paint(in context: CGContext, dirty: CGRect, fields: Bool) {
        state.scale = window?.backingScaleFactor ?? 2
        state.foreground = center.foreground ?? .labelColor
        state.placeholder = (center.foreground ?? .labelColor).withAlphaComponent(0.45)
        state.selectionColor = center.selection ?? .selectedTextBackgroundColor
        state.time = motionTime
        state.drawsFields = fields
        guard let tree else {
            // Nothing to show: say why, for whoever writes the mod.
            guard let error = copy.runtime.errors.last else { return }
            var style = ModTextStyle()
            style.size = 12
            style.lineHeight = 16
            ModTextLayout(text: "\(copy.runtime.name): \(error)", style: style)
                .draw(in: bounds.insetBy(dx: 10, dy: 10), color: .systemRed, underline: false, context: context)
            return
        }
        let painter = ModPainter(images: images, state: state)
        painter.draw(tree, in: context, dirty: dirty)
        // In a window each surface has a layer of its own, over everything.
        // In a picture they are painted here, where they would show.
        guard fields || surfacePanels.isEmpty else { return }
        for owner in surfaces {
            guard let popup = owner.popup, let content = popup.content else { continue }
            painter.draw(surface: content, at: popup.rect.origin, in: context, dirty: dirty)
        }
    }

    /// Paints one surface's content: for its own layer.
    func paint(surface owner: ModNode, in context: CGContext, at origin: CGPoint, dirty: CGRect) {
        guard let content = owner.popup?.content else { return }
        state.scale = window?.backingScaleFactor ?? 2
        state.foreground = center.foreground ?? .labelColor
        state.placeholder = (center.foreground ?? .labelColor).withAlphaComponent(0.45)
        state.selectionColor = center.selection ?? .selectedTextBackgroundColor
        state.time = motionTime
        state.drawsFields = false
        ModPainter(images: images, state: state).draw(surface: content, at: origin, in: context, dirty: dirty)
    }

    /// A picture of the panel at a size, without a window.
    public func snapshot(size: CGSize, scale: CGFloat = 2) -> CGImage? {
        setFrameSize(size)
        renderNow()
        // A second pass, for lists that learned their size in the first.
        if renderQueued { renderNow() }
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let saved = state.scale
        paint(in: context, dirty: CGRect(origin: .zero, size: size), fields: true)
        state.scale = saved
        return context.makeImage()
    }

    /// How many elements the panel holds now.
    public var nodeCount: Int { tree?.count ?? 0 }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        copy.isShown = window != nil
        runClock()
        syncPanels()
        watchOutsidePresses()
        watchDrops()
        if window != nil {
            if wantsKeyboard { window?.makeFirstResponder(self) }
            if let id = pendingFieldFocus { focusField(id) }
        }
    }

    // MARK: The pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    var lastPoint: CGPoint?

    func refreshHover() { setHover(at: lastPoint, event: nil) }

    func setHover(at point: CGPoint?, event: NSEvent?) {
        lastPoint = point
        var chain: [ModHit.Found] = []
        if let point { chain = self.chain(at: point) }
        // A box around the pointed node that doesn't hold the pointer isn't under it.
        if let point { chain = chain.enumerated().filter { $0.offset == 0 || $0.element.rect.contains(point) }.map(\.element) }
        let keys = Set(chain.map(\.node.key))
        if keys != state.hovered {
            var dirty = CGRect.null
            for found in hoverChain + chain where keys.contains(found.node.key) != state.hovered.contains(found.node.key) {
                let node = found.node
                if node.hover != nil || node.group != nil || node.scrolls { dirty = dirty.union(found.rect) }
            }
            let left = state.hovered.subtracting(keys), entered = keys.subtracting(state.hovered)
            state.hovered = keys
            if !dirty.isNull { setNeedsDisplay(dirty.insetBy(dx: -2, dy: -2)) }
            for key in left { if let handler = byKey[key]?.handlers["hover"] { copy.dispatch(handler, payload: ["args": [false]]) } }
            for key in entered { if let handler = byKey[key]?.handlers["hover"] { copy.dispatch(handler, payload: ["args": [true]]) } }
        }
        hoverChain = chain
        if let event, let point {
            for found in chain { if let handler = found.node.handlers["move"] { copy.dispatch(handler, payload: mouse(event, point: point, found: found)) } }
        }
        let tip = chain.first(where: { $0.node.tooltip != nil })?.node.tooltip
        if toolTip != tip { toolTip = tip }
        for panel in surfacePanels.values where panel.contentView?.toolTip != tip { panel.contentView?.toolTip = tip }
        if let point { cursor(for: chain, at: point).set() }
        watchHoverCards(chain: chain, at: point)
    }

    func cursor(for chain: [ModHit.Found], at point: CGPoint) -> NSCursor {
        // Between two panes of a resizable group: the divider.
        if let divider = paneDivider(in: chain, at: point) { return divider.row ? .resizeLeftRight : .resizeUpDown }
        switch chain.first(where: { $0.node.cursor != nil })?.node.cursor {
        case "pointer": return .pointingHand
        case "text": return .iBeam
        case "vertical_text": return .iBeamCursorForVerticalLayout
        case "grab": return .openHand
        case "grabbing": return .closedHand
        case "crosshair": return .crosshair
        case "not_allowed": return .operationNotAllowed
        case "copy": return .dragCopy
        case "alias": return .dragLink
        case "context_menu": return .contextualMenu
        case "col_resize", "ew_resize", "e_resize", "w_resize": return .resizeLeftRight
        case "row_resize", "ns_resize", "n_resize", "s_resize": return .resizeUpDown
        case "nesw_resize": return .frameResize(position: .topRight, directions: .all)
        case "nwse_resize": return .frameResize(position: .topLeft, directions: .all)
        default: return .arrow
        }
    }

    func modifiers(_ event: NSEvent) -> [String: Any] { modifiers(event.modifierFlags) }

    func modifiers(_ flags: NSEvent.ModifierFlags) -> [String: Any] {
        return ["shift": flags.contains(.shift), "control": flags.contains(.control), "alt": flags.contains(.option),
                "platform": flags.contains(.command), "function": flags.contains(.function)]
    }

    func mouse(_ event: NSEvent, point: CGPoint, found: ModHit.Found?, button: String = "left") -> [String: Any] {
        let moving = event.type == .mouseMoved || event.type == .scrollWheel || event.type == .mouseEntered
        return mouse(flags: event.modifierFlags, clicks: moving ? 0 : event.clickCount, point: point, found: found, button: button)
    }

    func mouse(flags: NSEvent.ModifierFlags, clicks: Int, point: CGPoint, found: ModHit.Found?, button: String) -> [String: Any] {
        var out: [String: Any] = [
            "button": button, "position": ["x": point.x, "y": point.y], "modifiers": modifiers(flags), "click_count": clicks,
        ]
        if let found {
            out["local_position"] = ["x": point.x - found.rect.minX, "y": point.y - found.rect.minY]
            out["bounds"] = ["x": found.rect.minX, "y": found.rect.minY, "width": found.rect.width, "height": found.rect.height]
        }
        return out
    }

    /// Runs a handler on each node from the innermost out, until one stops it.
    @discardableResult
    func bubble(_ chain: [ModHit.Found], _ name: String, payload: (ModHit.Found) -> [String: Any]) -> Bool {
        var ran = false
        for found in chain {
            guard let handler = found.node.handlers[name] else { continue }
            ran = true
            // A press or a release is the person's own doing.
            if copy.dispatch(handler, payload: payload(found), gesture: name != "wheel") { break }
        }
        return ran
    }

    public override func mouseMoved(with event: NSEvent) { setHover(at: point(of: event), event: event) }
    public override func mouseEntered(with event: NSEvent) { setHover(at: point(of: event), event: event) }
    /// For tests and `swiftr-mod`: the pointer moves with the button down.
    /// True when a part took the move (a slider, a divider between panes).
    @discardableResult
    public func mouseDrag(to point: CGPoint) -> Bool { drag(to: point, event: nil) }

    public override func mouseDragged(with event: NSEvent) {
        let point = point(of: event)
        // A slider, a divider between panes, files handed over: the drag is theirs.
        if drag(to: point, event: event) { return }
        if let start = dragStart, selecting || hypot(point.x - start.x, point.y - start.y) > 4 { select(from: start, to: point) }
        setHover(at: point, event: event)
    }
    public override func mouseExited(with event: NSEvent) { setHover(at: nil, event: nil); NSCursor.arrow.set() }

    func press(_ event: NSEvent, button: String) {
        press(at: point(of: event), button: button, clicks: event.clickCount, flags: event.modifierFlags)
    }

    func release(_ event: NSEvent, button: String) {
        release(at: point(of: event), button: button, clicks: event.clickCount, flags: event.modifierFlags)
    }

    func press(at point: CGPoint, button: String, clicks: Int, flags: NSEvent.ModifierFlags) {
        setHover(at: point, event: nil)
        let chain = hoverChain
        let keys = chain.map(\.node.key)
        downKeys = keys
        // The pointer takes over from Tab: no ring, and a press away from
        // the part that had the keyboard takes it off that part.
        if state.showsRing || state.focusedKey != nil {
            if let focused = state.focusedKey, !keys.contains(focused) { state.focusedKey = nil }
            state.showsRing = false
            needsDisplay = true
        }
        // A drag from here selects text, unless the mod does its own thing
        // with a press and a move there (tabs to reorder, a slider).
        var owned = chain.contains { $0.node.handlers["down_left"] != nil || $0.node.handlers["move"] != nil || $0.node.field != nil }
        // A press outside an open popover shuts it; one on its trigger, with
        // the button it opens by, is the trigger's.
        pressSurfaces(chain: chain, at: point, button: button)
        if button == "left", beginDrag(chain: chain, at: point) { owned = true }
        dragStart = button == "left" && !owned ? point : nil
        if button == "left", selectionAnchor != nil { clearSelection() }
        if button == "left" {
            state.pressed = Set(keys)
            if chain.contains(where: { $0.node.active != nil }) { needsDisplay = true }
        }
        if let handle = chain.first(where: { $0.node.focusHandle != nil })?.node.focusHandle {
            focus(handle: handle)
        } else if window?.firstResponder is NSText {
            // A press outside a field ends the typing in it.
            window?.makeFirstResponder(self)
        }
        for node in byKey.values where !keys.contains(node.key) {
            if let handler = node.handlers["downout"] {
                copy.dispatch(handler, payload: mouse(flags: flags, clicks: clicks, point: point, found: nil, button: button), gesture: true)
            }
        }
        bubble(chain, "down_" + button) { self.mouse(flags: flags, clicks: clicks, point: point, found: $0, button: button) }
        bubble(chain, "down_any") { self.mouse(flags: flags, clicks: clicks, point: point, found: $0, button: button) }
        // The right button over a row of a long list: the list's own handler, with the row's key.
        if button == "right", let row = chain.first(where: { $0.node.itemKey != nil && $0.node.parent?.handlers["item2"] != nil }),
           let handler = row.node.parent?.handlers["item2"], let key = row.node.itemKey {
            let event = mouse(flags: flags, clicks: clicks, point: point, found: row, button: button)
            copy.dispatch(handler, payload: ["args": [key, event]], gesture: true)
        }
    }

    func release(at point: CGPoint, button: String, clicks: Int, flags: NSEvent.ModifierFlags) {
        setHover(at: point, event: nil)
        let chain = hoverChain
        bubble(chain, "up_" + button) { self.mouse(flags: flags, clicks: clicks, point: point, found: $0, button: button) }
        if button == "left", endDrag(at: point) {
            // A slider or a divider was let go: no click.
            dragStart = nil
            if !state.pressed.isEmpty { state.pressed = []; needsDisplay = true }
        } else if button == "left", selecting {
            // The drag selected text: it wasn't a click.
            selecting = false
            dragStart = nil
            if !state.pressed.isEmpty { state.pressed = []; needsDisplay = true }
        } else if button == "left" {
            dragStart = nil
            // What was pressed and is still under the pointer. A part that is off hears nothing.
            let pressed = chain.filter { downKeys.contains($0.node.key) && !($0.node.isControl && $0.node.isDisabled) }
            let click: [String: Any] = ["click_count": clicks, "modifiers": modifiers(flags), "position": ["x": point.x, "y": point.y]]
            let off = chain.first(where: { $0.node.isControl })?.node.isDisabled == true
            if !off {
                bubble(pressed, "click") { _ in click }
                if clicks == 2 { bubble(pressed, "dbl") { _ in click } }
                // A row of a long list: the list's own handler, with the row's key.
                if let row = pressed.first(where: { $0.node.itemKey != nil && $0.node.parent?.handlers["item"] != nil }),
                   let handler = row.node.parent?.handlers["item"], let key = row.node.itemKey {
                    copy.dispatch(handler, payload: ["args": [key]], gesture: true)
                }
                // The innermost part answers the press its own way, and a
                // popover's trigger opens or shuts it.
                let nodes = pressed.map(\.node)
                if let part = nodes.first(where: \.actsOnPress) { activate(part) }
                if let trigger = nodes.first(where: { $0.popup?.kind == .popover }), trigger.popup?.button == "left" { toggle(trigger) }
            }
            if !state.pressed.isEmpty { state.pressed = []; needsDisplay = true }
        }
        downKeys = []
    }

    public override func mouseDown(with event: NSEvent) { press(event, button: "left") }
    public override func mouseUp(with event: NSEvent) { release(event, button: "left") }
    public override func rightMouseDown(with event: NSEvent) {
        press(event, button: "right")
        // Where the mod does nothing with a right press, the press goes on
        // to what holds the view: the app's own menu, if it has one there.
        let taken = hoverChain.contains {
            $0.node.handlers["down_right"] != nil || $0.node.handlers["up_right"] != nil || $0.node.popup?.button == "right"
                || ($0.node.itemKey != nil && $0.node.parent?.handlers["item2"] != nil)
        }
        if !taken, event.window === window { super.rightMouseDown(with: event) }
    }
    public override func rightMouseUp(with event: NSEvent) { release(event, button: "right") }
    public override func otherMouseDown(with event: NSEvent) { press(event, button: "middle") }
    public override func otherMouseUp(with event: NSEvent) { release(event, button: "middle") }

    public override func scrollWheel(with event: NSEvent) {
        guard tree != nil else { super.scrollWheel(with: event); return }
        let point = point(of: event)
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        // A wheel that counts in lines.
        if !event.hasPreciseScrollingDeltas { dx *= 18; dy *= 18 }
        let chain = chain(at: point)
        let phase: String = event.phase.contains(.began) ? "started" : event.phase.contains(.ended) ? "ended" : event.phase.contains(.cancelled) ? "cancelled" : "moved"
        let stopped = bubble(chain, "wheel") { found in
            var payload = self.mouse(event, point: point, found: found)
            payload["delta"] = ["x": dx, "y": dy]
            payload["touch_phase"] = phase
            return payload
        }
        for found in chain where found.node.scrolls {
            let node = found.node
            let limit = CGPoint(x: max(0, node.contentSize.width - found.rect.width), y: max(0, node.contentSize.height - found.rect.height))
            let old = state.scroll[node.key] ?? .zero
            var new = old
            if node.overflowY == .scroll || node.kind == .vlist { new.y = min(max(old.y - dy, 0), limit.y) }
            if node.overflowX == .scroll || node.kind == .hlist { new.x = min(max(old.x - dx, 0), limit.x) }
            guard new != old else { continue }
            state.scroll[node.key] = new
            scrolled(node, rect: found.rect)
            return
        }
        // Nothing here scrolls that way: what holds the mod may.
        if !stopped { super.scrollWheel(with: event) }
    }

    func scrolled(_ node: ModNode, rect: CGRect) {
        setNeedsDisplay(rect)
        if let id = node.id, node.kind == .vlist || node.kind == .hlist, !covers(node, wanted: wantedRows(id: id, node: node)) { queueRender() }
        // A surface goes with its trigger, as far as the window's edge.
        if !surfaces.isEmpty {
            layoutSurfaces()
            syncPanels()
            needsDisplay = true
        }
        syncFields()
        refreshHover()
    }

    // MARK: Selecting and copying text

    struct TextPlace {
        var key: String
        var index: Int
    }

    var dragStart: CGPoint?
    var selecting = false
    var selectionAnchor: TextPlace?
    var selectionHead: TextPlace?

    /// Every text that shows, in reading order, with where it is drawn.
    func shownTexts() -> [(node: ModNode, rect: CGRect)] {
        var out: [(ModNode, CGRect)] = []
        func walk(_ node: ModNode, origin: CGPoint, clip: CGRect) {
            guard node.display != "none", node.visible else { return }
            let rect = node.frame.offsetBy(dx: origin.x, dy: origin.y)
            if node.kind == .text || node.kind == .md {
                if rect.intersects(clip) || clip.isNull == false && rect.isEmpty { out.append((node, rect)) }
                return
            }
            var childOrigin = rect.origin
            var childClip = clip
            if node.overflowX != .visible || node.overflowY != .visible || node.scrolls {
                childClip = clip.intersection(rect)
                if childClip.isNull { return }
                if let offset = state.scroll[node.key] {
                    childOrigin.x -= offset.x
                    childOrigin.y -= offset.y
                }
            }
            for child in node.children { walk(child, origin: childOrigin, clip: childClip) }
        }
        if let tree { walk(tree, origin: .zero, clip: bounds.insetBy(dx: -4000, dy: -40_000)) }
        return out
    }

    func place(at point: CGPoint, in texts: [(node: ModNode, rect: CGRect)]) -> TextPlace? {
        // The text under the point, else the nearest: by rows first.
        var best: (distance: CGFloat, item: (node: ModNode, rect: CGRect))?
        for item in texts {
            let dx = max(item.rect.minX - point.x, 0, point.x - item.rect.maxX)
            let dy = max(item.rect.minY - point.y, 0, point.y - item.rect.maxY)
            let distance = dy * 1000 + dx
            if best == nil || distance < best!.distance { best = (distance, item) }
        }
        guard let found = best?.item else { return nil }
        let index = found.node.kind == .md ? 0 : found.node.line?.index(at: point, in: found.rect) ?? 0
        return TextPlace(key: found.node.key, index: index)
    }

    func select(from start: CGPoint, to point: CGPoint) {
        let texts = shownTexts()
        if !selecting {
            selecting = true
            selectionAnchor = place(at: start, in: texts)
            // The keyboard, for ⌘C.
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        }
        selectionHead = place(at: point, in: texts)
        applySelection(texts)
    }

    func clearSelection() {
        selectionAnchor = nil
        selectionHead = nil
        if !state.selection.isEmpty { state.selection = [:]; needsDisplay = true }
    }

    /// Works the selection out again: after a drag step, or a new render.
    func applySelection(_ known: [(node: ModNode, rect: CGRect)]? = nil) {
        guard let anchor = selectionAnchor, let head = selectionHead else { return }
        let texts = known ?? shownTexts()
        guard let a = texts.firstIndex(where: { $0.node.key == anchor.key }), let b = texts.firstIndex(where: { $0.node.key == head.key }) else {
            // What was selected is gone from the panel.
            clearSelection()
            return
        }
        let (first, last) = a < b || (a == b && anchor.index <= head.index) ? ((a, anchor.index), (b, head.index)) : ((b, head.index), (a, anchor.index))
        var ranges: [String: NSRange] = [:]
        for index in first.0...last.0 {
            let node = texts[index].node
            let length = node.kind == .md ? (node.text ?? "").utf16.count : node.line?.length ?? 0
            let from = index == first.0 && node.kind != .md ? min(first.1, length) : 0
            let to = index == last.0 && node.kind != .md ? min(last.1, length) : length
            if to > from || (node.kind == .md && length > 0) { ranges[node.key] = NSRange(location: from, length: max(to - from, 0)) }
        }
        if !NSDictionary(dictionary: state.selection).isEqual(to: ranges) {
            state.selection = ranges
            needsDisplay = true
        }
    }

    /// The selected text, a line per row of the panel.
    public var selectedText: String {
        var out = ""
        var lastRow: CGFloat?
        for (node, rect) in shownTexts() {
            guard let range = state.selection[node.key], let text = node.text else { continue }
            let piece = node.kind == .md ? text : (text as NSString).substring(with: NSIntersectionRange(range, NSRange(location: 0, length: (text as NSString).length)))
            if let row = lastRow { out += abs(rect.midY - row) > rect.height / 2 ? "\n" : " " }
            out += piece
            lastRow = rect.midY
        }
        return out
    }

    @objc public func copy(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public override func selectAll(_ sender: Any?) {
        let texts = shownTexts()
        guard let first = texts.first, let last = texts.last else { return }
        selectionAnchor = TextPlace(key: first.node.key, index: 0)
        selectionHead = TextPlace(key: last.node.key, index: last.node.line?.length ?? 0)
        applySelection(texts)
    }

    /// Selects from one text to another, as a drag would. For tests.
    @discardableResult
    public func select(fromText first: String, toText last: String) -> Bool {
        guard let a = frame(ofText: first), let b = frame(ofText: last) else { return false }
        selecting = false
        select(from: CGPoint(x: a.minX + 0.5, y: a.midY), to: CGPoint(x: b.maxX - 0.5, y: b.midY))
        selecting = false
        return true
    }

    // MARK: For tests and the app's debug hooks

    /// Every text of the panel, top to bottom.
    public func texts() -> [String] {
        var out: [String] = []
        each { node in
            guard node.kind == .text || node.kind == .md, let text = node.text, !text.isEmpty else { return }
            var up: ModNode? = node
            while let at = up { if at.display == "none" { return }; up = at.parent }
            out.append(text)
        }
        return out
    }

    /// Presses and releases on the first element that shows `text`, as the
    /// pointer would. False when no element shows it.
    @discardableResult
    public func click(text: String, button: String = "left", clicks: Int = 1) -> Bool {
        guard let found = locate({ $0.kind == .text && $0.text == text }) else { return false }
        click(at: CGPoint(x: found.rect.midX, y: found.rect.midY), button: button, clicks: clicks)
        return true
    }

    /// Presses and releases on the element with this id.
    @discardableResult
    public func click(id: String, button: String = "left", clicks: Int = 1) -> Bool {
        guard let found = locate({ $0.id == id }) else { return false }
        click(at: CGPoint(x: found.rect.midX, y: found.rect.midY), button: button, clicks: clicks)
        return true
    }

    public func click(at point: CGPoint, button: String = "left", clicks: Int = 1) {
        press(at: point, button: button, clicks: clicks, flags: [])
        release(at: point, button: button, clicks: clicks, flags: [])
        setHover(at: nil, event: nil)
    }

    /// The fields' hints, in the order they show.
    public func fieldHints() -> [String] {
        fields.values.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }.map { $0.placeholderString ?? "" }
    }

    /// Types into the field with this hint, as the keyboard would, and
    /// presses Return when `submit`.
    @discardableResult
    public func type(_ text: String, inFieldWithHint hint: String, submit: Bool = false) -> Bool {
        guard let (id, field) = fields.first(where: { $0.value.placeholderString == hint }) else { return false }
        field.stringValue = text
        copy.runtime.lastGesture = Date()
        copy.field(id, event: "change", value: text)
        if submit { copy.field(id, event: "submit", value: text) }
        return true
    }

    /// Where an element with this text is, for a picture or a real click.
    public func frame(ofText text: String) -> CGRect? {
        locate({ $0.kind == .text && $0.text == text })?.rect
    }

    // MARK: The keyboard

    private static let keyNames: [UInt16: String] = [
        36: "enter", 76: "enter", 53: "escape", 48: "tab", 51: "backspace", 117: "delete", 49: "space",
        126: "up", 125: "down", 123: "left", 124: "right", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    func keyEvent(_ event: NSEvent) -> [String: Any] {
        let flags = event.modifierFlags
        let key = Self.keyNames[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").lowercased()
        var chord = ""
        if flags.contains(.control) { chord += "ctrl-" }
        if flags.contains(.option) { chord += "alt-" }
        if flags.contains(.command) { chord += "cmd-" }
        if flags.contains(.shift) { chord += "shift-" }
        var out: [String: Any] = ["key": key, "keystroke": chord + key, "modifiers": modifiers(event), "is_held": event.isARepeat]
        if let typed = event.characters, !typed.isEmpty, !flags.contains(.command), !flags.contains(.control),
           Self.keyNames[event.keyCode] == nil || key == "space", typed.unicodeScalars.allSatisfy({ $0.value >= 32 && !(0xF700...0xF8FF).contains($0.value) }) {
            out["key_char"] = typed
        }
        return out
    }

    /// The node that holds the keyboard and the nodes around it, innermost
    /// first: who hears a key.
    func keyPath(from start: ModNode? = nil) -> [ModNode] {
        guard let tree else { return [] }
        var node = start
        if node == nil { node = focusedNode() }
        var path: [ModNode] = []
        var at = node ?? tree
        while true {
            path.append(at)
            guard let up = at.parent else { break }
            at = up
        }
        return path
    }

    func normalized(_ chord: String) -> Set<String> {
        Set(chord.lowercased().split(separator: "-", omittingEmptySubsequences: false).map { part -> String in
            switch part {
            case "control": "ctrl"
            case "option": "alt"
            case "command", "platform", "super", "secondary": "cmd"
            case "return": "enter"
            case "esc": "escape"
            default: String(part)
            }
        })
    }

    func matches(_ predicate: String?, contexts: Set<String>) -> Bool {
        guard let predicate, !predicate.isEmpty else { return true }
        // Any of the `||` parts, each a list of `&&` names, `!` for "not".
        return predicate.components(separatedBy: "||").contains { part in
            part.components(separatedBy: "&&").allSatisfy { term in
                let name = term.trimmingCharacters(in: .whitespaces)
                return name.hasPrefix("!") ? !contexts.contains(String(name.dropFirst()).trimmingCharacters(in: .whitespaces)) : contexts.contains(name)
            }
        }
    }

    /// Hands a key to the mod. False when nothing in it listens.
    func key(_ payload: [String: Any], name: String, from start: ModNode? = nil) -> Bool {
        guard let tree else { return false }
        let path = keyPath(from: start)
        if name == "keydown", let chord = payload["keystroke"] as? String, !tree.bindings.isEmpty {
            let pressed = normalized(chord)
            let contexts = Set(path.compactMap(\.keyContext))
            for binding in tree.bindings {
                guard let wanted = binding["keystroke"] as? String, normalized(wanted) == pressed, let action = binding["action"] as? String,
                      matches(binding["context"] as? String, contexts: contexts) else { continue }
                if let handler = path.lazy.compactMap({ $0.actions[action] }).first {
                    copy.dispatch(handler, payload: ["args": []], gesture: true)
                    return true
                }
            }
        }
        var heard = false
        for node in path {
            guard let handler = node.handlers[name] else { continue }
            heard = true
            if copy.dispatch(handler, payload: payload, gesture: true) { break }
        }
        return heard
    }

    public override func keyDown(with event: NSEvent) {
        // ⌘C and ⌘A on selected text, before the mod's own keys.
        let command = event.modifierFlags.intersection([.command, .control, .option]) == .command
        if command, event.charactersIgnoringModifiers == "c", !state.selection.isEmpty { copy(nil); return }
        if command, event.charactersIgnoringModifiers == "a", selectionAnchor != nil { selectAll(nil); return }
        let payload = keyEvent(event)
        copy.runtime.lastGesture = Date()
        // A part's own keys first (Space on a checkbox, Escape in a popover,
        // Tab to the next stop), then the mod's.
        if partKey(payload) { return }
        if !key(payload, name: "keydown") { super.keyDown(with: event) }
    }

    /// For tests and `swiftr-mod`: a key, as the keyboard would send it
    /// (`"tab"`, `"shift-tab"`, `"space"`, `"enter"`, `"escape"`, `"down"`, `"a"`).
    @discardableResult
    public func press(key chord: String) -> Bool {
        let name = chord.split(separator: "-").last.map(String.init) ?? chord
        var payload: [String: Any] = ["key": name, "keystroke": chord, "modifiers": modifiers([]), "is_held": false]
        if name.count == 1, name == chord { payload["key_char"] = name }
        copy.runtime.lastGesture = Date()
        if partKey(payload) { return true }
        return key(payload, name: "keydown")
    }

    public override func flagsChanged(with event: NSEvent) {
        // `on_modifiers_changed`, on what holds the keyboard and around it.
        let payload: [String: Any] = ["modifiers": modifiers(event)]
        var heard = false
        for node in keyPath() {
            guard let handler = node.handlers["mods"] else { continue }
            heard = true
            if copy.dispatch(handler, payload: payload) { break }
        }
        if !heard { super.flagsChanged(with: event) }
    }

    // MARK: Files dropped on the panel

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropEntered(sender) }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropEntered(sender) }
    public override func draggingExited(_ sender: NSDraggingInfo?) { dropLeft() }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { drop(sender) }

    /// For tests and `swiftr-mod`: drops files on the first element that
    /// shows `text`, as a drag from the Finder would.
    @discardableResult
    public func drop(paths: [String], onText text: String) -> Bool {
        guard let found = locate({ $0.kind == .text && $0.text == text }) else { return false }
        let point = CGPoint(x: found.rect.midX, y: found.rect.midY)
        guard let handler = chain(at: point).first(where: { $0.node.handlers["drop"] != nil })?.node.handlers["drop"] else { return false }
        copy.dispatch(handler, payload: ["paths": paths], gesture: true)
        return true
    }

    public override func keyUp(with event: NSEvent) {
        if !key(keyEvent(event), name: "keyup") { super.keyUp(with: event) }
    }

    public override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    public override func resignFirstResponder() -> Bool {
        // The keyboard went to one of this mod's own fields, or away.
        needsDisplay = true
        return true
    }

    // MARK: What the script asks of its view

    func focus(handle: String) {
        state.focusedHandle = handle
        // The script's own handle: no node of Swiftr's choosing, and no ring.
        state.focusedKey = nil
        state.showsRing = false
        copy.focusChanged(handle)
        wantsKeyboard = true
        if let window, window.firstResponder !== self {
            if !window.isKeyWindow, surfacePanels.values.contains(where: { $0.isKeyWindow }) { window.makeKey() }
            window.makeFirstResponder(self)
        }
        needsDisplay = true
    }

    func dispatchAction(_ name: String) {
        if let handler = keyPath().lazy.compactMap({ $0.actions[name] }).first { copy.dispatch(handler, payload: ["args": []]) }
    }

    func listRange(id: String, count: Int) -> Range<Int> {
        guard let node = lists[id], let sizes = node.listSizes, sizes.count == count, node.frame.height > 0 || node.frame.width > 0 else {
            return 0..<min(count, 80)
        }
        return wantedRows(id: id, node: node)
    }

    func scroll(handle: String, toItem index: Int, strategy: String?) {
        // After the layout that follows: the list may have just grown.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.scrollNow(handle: handle, toItem: index, strategy: strategy) }
        }
    }

    func scrollNow(handle: String, toItem index: Int, strategy: String?) {
        guard let found = locate({ $0.scrollHandle == handle }) else { return }
        let node = found.node
        let vertical = node.kind != .hlist && node.overflowY == .scroll || node.kind == .vlist
        let view = vertical ? found.rect.height : found.rect.width
        let content = vertical ? node.contentSize.height : node.contentSize.width
        var start: CGFloat = 0, length: CGFloat = 0
        if index < 0 {
            start = content
        } else if let sizes = node.listSizes {
            start = sizes.offset(of: index)
            length = sizes.size(of: index)
        } else if index < node.children.count {
            let frame = node.children[index].frame
            start = vertical ? frame.minY : frame.minX
            length = vertical ? frame.height : frame.width
        } else { return }
        let old = state.scroll[node.key] ?? .zero
        var at = vertical ? old.y : old.x
        switch strategy {
        case "top": at = start
        case "center": at = start - (view - length) / 2
        default:
            // Only as far as it takes to show the row.
            if index < 0 { at = content - view } else if start < at { at = start } else if start + length > at + view { at = start + length - view }
        }
        at = min(max(at, 0), max(0, content - view))
        let new = vertical ? CGPoint(x: old.x, y: at) : CGPoint(x: at, y: old.y)
        guard new != old else { return }
        state.scroll[node.key] = new
        byKey[node.key] = node
        scrolled(node, rect: found.rect)
    }

    // MARK: Fields

    final class Field: NSTextField {
        var onFocus: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let took = super.becomeFirstResponder()
            if took { onFocus?() }
            return took
        }
    }

    final class SecretField: NSSecureTextField {
        var onFocus: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let took = super.becomeFirstResponder()
            if took { onFocus?() }
            return took
        }
    }

    /// Puts a real text field over each field the script described.
    func syncFields() {
        guard let tree else { return }
        var seen = Set<String>()
        let color = center.foreground ?? .labelColor
        place(tree, origin: .zero, color: color, clip: bounds, host: self, seen: &seen)
        // A surface's fields sit in its own layer; in a picture, where the
        // surface would show.
        for owner in surfaces {
            guard let popup = owner.popup, let content = popup.content else { continue }
            if let layer = surfacePanels[owner.key]?.contentView {
                let pad = ModSurfacePanel.pad
                place(content, origin: CGPoint(x: pad, y: pad), color: color, clip: layer.bounds, host: layer, seen: &seen)
            } else {
                place(content, origin: popup.rect.origin, color: color, clip: popup.rect, host: self, seen: &seen)
            }
        }
        for (id, field) in fields where !seen.contains(id) {
            field.removeFromSuperview()
            fields[id] = nil
            fieldRevisions[id] = nil
        }
        if let id = pendingFieldFocus, fields[id] != nil, window != nil { focusField(id) }
    }

    func place(_ node: ModNode, origin: CGPoint, color inherited: NSColor, clip: CGRect, host: NSView, seen: inout Set<String>) {
        guard node.display != "none" else { return }
        let rect = node.frame.offsetBy(dx: origin.x, dy: origin.y)
        let color = node.paint.textColor ?? inherited
        if let id = node.field, node.kind == .input || node.kind == .textarea || node.kind == .editor {
            seen.insert(id)
            let options = node.raw["o"] as? [String: Any] ?? [:]
            let masked = options["masked"] as? Bool == true
            var field = fields[id]
            if let existing = field, (existing is NSSecureTextField) != masked {
                existing.removeFromSuperview()
                field = nil
                fieldRevisions[id] = nil
            }
            let made = field ?? makeField(id: id, masked: masked, multiline: node.kind != .input)
            fields[id] = made
            if made.superview !== host { host.addSubview(made) }
            var style = node.textStyle
            if node.kind == .editor, style.family == nil { style.family = ModFonts.monoFamily }
            let font = ModFonts.font(style)
            if made.font != font { made.font = font }
            if made.textColor != color { made.textColor = color }
            let hint = options["placeholder"] as? String ?? ""
            if made.placeholderString != hint {
                made.placeholderAttributedString = NSAttributedString(string: hint, attributes: [.font: font, .foregroundColor: color.withAlphaComponent(0.45)])
                made.placeholderString = hint
            }
            // The script's own changes (`set_value`) win over what is typed.
            let revision = (node.raw["rev"] as? NSNumber)?.intValue ?? 0
            if fieldRevisions[id] != revision {
                fieldRevisions[id] = revision
                let value = node.raw["v"] as? String ?? ""
                if made.stringValue != value { made.stringValue = value }
            }
            // A field scrolled out of its list hides.
            made.isHidden = !clip.intersects(rect)
            // One line sits in the middle of its box, as in herdr-app.
            var frame = rect
            if node.kind == .input {
                let line = ceil(font.ascender - font.descender + font.leading) + 2
                frame = CGRect(x: rect.minX, y: (rect.midY - line / 2).rounded(), width: rect.width, height: min(line, max(rect.height, line)))
            }
            if made.frame != frame { made.frame = frame }
            return
        }
        var childOrigin = rect.origin
        var childClip = clip
        if node.overflowX != .visible || node.overflowY != .visible || node.scrolls {
            childClip = clip.intersection(rect)
            if let offset = state.scroll[node.key] {
                childOrigin.x -= offset.x
                childOrigin.y -= offset.y
            }
        }
        for child in node.children { place(child, origin: childOrigin, color: color, clip: childClip, host: host, seen: &seen) }
    }

    func makeField(id: String, masked: Bool, multiline: Bool) -> NSTextField {
        let field: NSTextField
        let focused: () -> Void = { [weak self] in self?.copy.field(id, event: "focus", value: nil) }
        if masked {
            let secret = SecretField()
            secret.onFocus = focused
            field = secret
        } else {
            let plain = Field()
            plain.onFocus = focused
            field = plain
        }
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.isBordered = false
        field.drawsBackground = false
        // No inset of the field's own: its text starts where the mod's box does.
        (field.cell as? NSTextFieldCell)?.lineBreakMode = .byClipping
        field.focusRingType = .none
        field.delegate = self
        if multiline {
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
        } else {
            field.usesSingleLineMode = true
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            field.lineBreakMode = .byTruncatingTail
        }
        return field
    }

    func fieldID(_ object: Any?) -> String? { (object as? NSTextField)?.identifier?.rawValue }

    public func controlTextDidChange(_ notification: Notification) {
        guard let id = fieldID(notification.object), let field = fields[id] else { return }
        copy.field(id, event: "change", value: field.stringValue)
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        guard let id = fieldID(notification.object), let field = fields[id] else { return }
        copy.field(id, event: "blur", value: field.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let id = fieldID(control), let field = fields[id] else { return false }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let multiline = !field.usesSingleLineMode
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if multiline, !flags.contains(.command) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            copy.field(id, event: "submit", value: field.stringValue, extra: ["secondary": flags.contains(.command), "shift": flags.contains(.shift)])
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
             #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // Keys a mod steers its lists with while a field holds the keyboard.
            if multiline, selector != #selector(NSResponder.cancelOperation(_:)) { return false }
            guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
            var start: ModNode?
            each { if start == nil, $0.field == id { start = $0 } }
            // A number field steps with ↑ and ↓; Tab goes to the next stop.
            if let start, fieldKey(selector, in: start) { return true }
            return key(keyEvent(event), name: "keydown", from: start)
        default:
            return false
        }
    }

    func focusField(_ id: String) {
        // The field's own window: a surface's layer, or the app's.
        guard let field = fields[id], window != nil, let home = field.window else {
            pendingFieldFocus = id
            return
        }
        pendingFieldFocus = nil
        state.focusedKey = nil
        state.showsRing = false
        // A field in a surface's layer takes the keyboard there.
        if home is ModSurfacePanel, !home.isKeyWindow { home.makeKey() }
        if home.firstResponder !== field.currentEditor() { home.makeFirstResponder(field) }
    }

    func replaceInField(_ id: String, text: String) {
        guard let field = fields[id] else { return }
        if let editor = field.currentEditor() {
            editor.insertText(text)
        } else {
            field.stringValue += text
        }
        copy.field(id, event: "change", value: field.stringValue)
    }

    func selectInField(_ id: String, start: Int, end: Int) {
        guard let field = fields[id], let editor = field.currentEditor() else { return }
        let length = (field.stringValue as NSString).length
        let from = min(max(start, 0), length), to = min(max(end, from), length)
        editor.selectedRange = NSRange(location: from, length: to - from)
    }
}
