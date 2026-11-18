import AppKit
import Foundation

/// What herdr-app's ready-made parts do by themselves. None of them draws:
/// the look is the mod's. Swiftr gives them the Mac's behavior: a press or
/// a key on a `Checkbox` reports its change, a `Link` opens its page, a
/// slider follows the pointer, Tab goes from one to the next.
extension ModView {
    // MARK: A press on a part

    /// The part's own answer to a click, or to Space and Return on it.
    func activate(_ node: ModNode) {
        guard !node.isDisabled else { return }
        copy.runtime.lastGesture = Date()
        func change(_ value: Bool) {
            if let handler = node.handlers["change"] { copy.dispatch(handler, payload: ["args": [value]], gesture: true) }
        }
        if let action = node.step, let state = node.number {
            step(state, action, frame: node.enclosing(part: "number"))
            return
        }
        switch node.part {
        case "checkbox", "switch":
            change(!(node.state["checked"] ?? false))
        case "radio":
            // A radio cannot clear itself.
            if node.state["checked"] != true { change(true) }
        case "toggle":
            change(!(node.state["pressed"] ?? false))
        case "accordion-trigger":
            change(!(node.enclosing(part: "accordion-item")?.state["open"] ?? node.state["open"] ?? false))
        case "link":
            // A page, on the person's own press, as `cx.open_url` would.
            if let text = node.url, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                center.host?.modOpen(url)
            }
        default:
            break
        }
    }

    /// A step of a number field: the mod's own (`on_step`), else the sum,
    /// kept between the field's bounds.
    func step(_ state: String, _ action: String, frame: ModNode?) {
        if frame?.state["disabled"] == true { return }
        if let handler = frame?.handlers["step"] {
            copy.dispatch(handler, payload: ["args": [action]], gesture: true)
        } else {
            copy.step(state, action: action)
        }
    }

    // MARK: Sliders

    private struct SliderScale {
        var min = 0.0, max = 100.0, step = 1.0
        var logarithmic = false

        init(_ node: ModNode) {
            let options = node.raw["o"] as? [String: Any] ?? [:]
            func number(_ key: String, _ fallback: Double) -> Double { (options[key] as? NSNumber)?.doubleValue ?? fallback }
            min = number("min", 0)
            max = number("max", 100)
            step = number("step", 1)
            logarithmic = options["scale"] as? String == "logarithmic" && min > 0 && max > min
        }

        /// Where a value is along the slider, 0 to 1.
        func fraction(_ value: Double) -> CGFloat {
            guard max > min else { return 0 }
            let f = logarithmic ? log(Swift.max(value, min) / min) / log(max / min) : (value - min) / (max - min)
            return CGFloat(Swift.min(Swift.max(f, 0), 1))
        }

        /// The value at a place along the slider, on a step.
        func value(at fraction: CGFloat) -> Double {
            let f = Double(Swift.min(Swift.max(fraction, 0), 1))
            var value = logarithmic ? min * pow(max / min, f) : min + f * (max - min)
            if step > 0 { value = min + ((value - min) / step).rounded() * step }
            // No stray digits from a step like 0.1.
            value = (value * 1e9).rounded() / 1e9
            return Swift.min(Swift.max(value, min), max)
        }
    }

    /// A slider's value: where the person has it, else what the script gave.
    func sliderValues(of node: ModNode) -> [Double] {
        if let id = node.slider, let moved = sliderValues[id] { return moved }
        if let one = node.raw["v"] as? NSNumber { return [one.doubleValue] }
        if let two = node.raw["v"] as? [NSNumber], !two.isEmpty { return two.map(\.doubleValue) }
        return [SliderScale(node).min]
    }

    private func isVertical(_ node: ModNode) -> Bool { node.access["axis"] as? String == "vertical" }

    /// Puts each slider's fill and thumbs where its value says, in a tree
    /// just laid out.
    func placeSliders(in root: ModNode) {
        root.walk { indicator in
            guard indicator.part == "slider-indicator", let id = indicator.slider else { return }
            let scale = SliderScale(indicator)
            let values = sliderValues(of: indicator)
            let vertical = isVertical(indicator)
            let size = indicator.frame.size
            let low = values.count > 1 ? scale.fraction(values[0]) : 0
            let high = scale.fraction(values[values.count - 1])
            // A vertical slider grows from the bottom.
            indicator.fill = vertical
                ? CGRect(x: 0, y: size.height * (1 - high), width: size.width, height: size.height * (high - low))
                : CGRect(x: size.width * low, y: 0, width: size.width * (high - low), height: size.height)
            indicator.walk { thumb in
                guard thumb.part == "slider-thumb", thumb.slider == id else { return }
                let at = thumb.state["start"] == true && values.count > 1 ? low : high
                var along = vertical ? size.height * (1 - at) : size.width * at
                // A thumb with a `transition` or a `spring` on its place
                // glides to a value set from elsewhere; under the pointer it
                // keeps up with it.
                let property = vertical ? "top" : "left"
                if let spec = thumb.motions[property] {
                    let run = thumb.key + "|" + property, now = motionTime
                    if sliderDrag != nil {
                        runs[run] = nil
                    } else if case .px(let old)? = targets[run], old != along {
                        let from = runs[run]?.value ?? old
                        runs[run] = ModRun(from: from, to: along, percent: false, start: now, spec: spec, value: from,
                                           velocity: runs[run]?.velocity ?? 0, last: now)
                    }
                    targets[run] = .px(along)
                    if var going = runs[run] {
                        if advance(&going, to: now) {
                            runs[run] = nil
                        } else {
                            runs[run] = going
                            along = going.value
                        }
                    }
                }
                thumb.slide = vertical ? CGPoint(x: 0, y: along) : CGPoint(x: along, y: 0)
                thumb.frame.origin = CGPoint(x: thumb.restOrigin.x + thumb.shift.x + thumb.slide.x,
                                             y: thumb.restOrigin.y + thumb.shift.y + thumb.slide.y)
            }
        }
    }

    func placeAllSliders() {
        if let tree { placeSliders(in: tree) }
        for owner in surfaces { if let content = owner.popup?.content { placeSliders(in: content) } }
        needsDisplay = true
    }

    /// The indicator of a slider's state: the box a pointer is measured against.
    private func indicator(of state: String) -> ModNode? {
        var found: ModNode?
        each { if found == nil, $0.part == "slider-indicator", $0.slider == state { found = $0 } }
        return found
    }

    private func moveSlider(to point: CGPoint) {
        guard let drag = sliderDrag, let indicator = indicator(of: drag.state), let rect = rect(of: indicator), rect.width > 0, rect.height > 0 else { return }
        let scale = SliderScale(indicator)
        var values = sliderValues(of: indicator)
        let fraction = isVertical(indicator) ? 1 - (point.y - rect.minY) / rect.height : (point.x - rect.minX) / rect.width
        var value = scale.value(at: fraction)
        let index = min(drag.thumb, values.count - 1)
        // The two ends of a range never cross.
        if values.count > 1 { value = index == 0 ? min(value, values[1]) : max(value, values[0]) }
        guard values[index] != value else { return }
        values[index] = value
        setSlider(drag.state, values)
    }

    private func setSlider(_ state: String, _ values: [Double]) {
        sliderValues[state] = values
        placeAllSliders()
        copy.slider(state, values: values, event: "change")
    }

    /// The arrows, Home and End on a slider's thumb.
    func sliderKey(_ key: String, on thumb: ModNode) -> Bool {
        guard let state = thumb.slider, let indicator = indicator(of: state) else { return false }
        if thumb.enclosing(part: "slider")?.state["disabled"] == true { return false }
        let scale = SliderScale(indicator)
        var values = sliderValues(of: indicator)
        let index = thumb.state["start"] == true || values.count == 1 ? 0 : values.count - 1
        var value = values[index]
        let step = scale.step > 0 ? scale.step : (scale.max - scale.min) / 100
        switch key {
        case "right", "up": value = scale.logarithmic ? scale.value(at: scale.fraction(value) + 0.05) : value + step
        case "left", "down": value = scale.logarithmic ? scale.value(at: scale.fraction(value) - 0.05) : value - step
        case "home": value = scale.min
        case "end": value = scale.max
        default: return false
        }
        value = min(max((value * 1e9).rounded() / 1e9, scale.min), scale.max)
        if values.count > 1 { value = index == 0 ? min(value, values[1]) : max(value, values[0]) }
        if values[index] != value {
            values[index] = value
            setSlider(state, values)
            copy.slider(state, values: values, event: "release")
        }
        return true
    }

    // MARK: Panes with a divider to drag

    /// A group's panes, the hidden ones too: a hidden pane keeps its place
    /// and its size for when it shows again.
    private func panes(of group: ModNode) -> [ModNode] { group.children.filter { $0.part == "pane" } }

    private func isRow(_ group: ModNode) -> Bool { (group.style["fd"] as? String ?? "row").hasPrefix("row") }

    /// Each pane's size along its group, as the person left it, else as its
    /// mod gave it. Under zero: the pane shares what is left.
    private func sizes(of group: ModNode, _ panes: [ModNode]) -> [CGFloat] {
        if let id = group.id, let kept = paneSizes[id], kept.count == panes.count { return kept }
        return panes.map { ($0.pane?["size"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? -1 }
    }

    /// Which of the panes that show shares what is left: the first with no
    /// size of its own, else the last, so the group is always filled.
    private func sharer(_ panes: [ModNode], _ sizes: [CGFloat]) -> Int? {
        let shown = panes.indices.filter { panes[$0].display != "none" }
        return shown.first { sizes[$0] < 0 } ?? shown.last
    }

    /// Before a layout: each pane takes its size.
    func applyPanes() {
        tree?.walk(open: { _ in true }) { group in
            guard group.part == "resizable" else { return }
            let panes = panes(of: group)
            guard !panes.isEmpty else { return }
            let sizes = sizes(of: group, panes), sharer = sharer(panes, sizes)
            let side = isRow(group) ? "w" : "h"
            for (index, pane) in panes.enumerated() {
                pane.sizeOverride[side] = sizes[index] >= 0 && index != sharer ? .px(sizes[index]) : nil
            }
        }
    }

    /// The divider under the pointer: after which pane, of which group.
    func paneDivider(in chain: [ModHit.Found], at point: CGPoint) -> (group: ModNode, index: Int, row: Bool)? {
        for found in chain where found.node.part == "resizable" {
            let group = found.node, row = isRow(group)
            let panes = panes(of: group)
            let shown = panes.indices.filter { panes[$0].display != "none" }
            for index in shown.dropLast() {
                let edge = row ? found.rect.minX + panes[index].frame.maxX : found.rect.minY + panes[index].frame.maxY
                if abs((row ? point.x : point.y) - edge) <= 4 { return (group, index, row) }
            }
        }
        return nil
    }

    private func movePanes(to point: CGPoint) {
        guard let drag = paneDrag else { return }
        var group: ModNode?
        each { if group == nil, $0.part == "resizable", $0.id == drag.group { group = $0 } }
        guard let group else { return }
        let panes = panes(of: group), row = isRow(group)
        // The pane before the divider, and the next one that shows.
        let before = drag.index
        guard drag.sizes.count == panes.count, before < panes.count,
              let after = panes.indices.first(where: { $0 > before && panes[$0].display != "none" }) else { return }
        func limits(_ pane: ModNode) -> (CGFloat, CGFloat) {
            let low = (pane.pane?["min"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 40
            let high = (pane.pane?["max"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? .greatestFiniteMagnitude
            return (low, max(low, high))
        }
        let first = drag.sizes[before], both = first + drag.sizes[after]
        let (lowA, highA) = limits(panes[before]), (lowB, highB) = limits(panes[after])
        var size = first + (row ? point.x : point.y) - drag.start
        // Each of the two stays within its own bounds; together they keep their room.
        size = min(max(size, lowA, both - highB), highA, both - lowB)
        var sizes = sizes(of: group, panes)
        // The pane that shares what is left goes on doing so: its neighbor carries the size.
        let sharer = sharer(panes, sizes)
        if before != sharer { sizes[before] = size }
        if after != sharer { sizes[after] = both - size }
        guard sizes != paneSizes[drag.group] else { return }
        paneSizes[drag.group] = sizes
        relayout()
    }

    // MARK: Drags that belong to a part

    /// A press that starts a drag of a part's own: a slider, a divider.
    /// A node that hands files over is kept, for a drag that leaves it.
    func beginDrag(chain: [ModHit.Found], at point: CGPoint) -> Bool {
        dragCandidate = nil
        if let divider = paneDivider(in: chain, at: point), let id = divider.group.id {
            let panes = panes(of: divider.group)
            paneDrag = (id, divider.index, divider.row ? point.x : point.y, panes.map { divider.row ? $0.frame.width : $0.frame.height })
            return true
        }
        if let part = chain.first(where: { $0.node.slider != nil && ($0.node.part == "slider-thumb" || $0.node.part == "slider-track" || $0.node.part == "slider-indicator") })?.node,
           let state = part.slider, part.enclosing(part: "slider")?.state["disabled"] != true, let indicator = indicator(of: state), let rect = rect(of: indicator) {
            let values = sliderValues(of: indicator)
            var thumb = values.count - 1
            if part.part == "slider-thumb" {
                thumb = part.state["start"] == true ? 0 : values.count - 1
            } else if values.count > 1 {
                // The end of the range nearer the press.
                let scale = SliderScale(indicator)
                let at = isVertical(indicator) ? 1 - (point.y - rect.minY) / max(rect.height, 1) : (point.x - rect.minX) / max(rect.width, 1)
                thumb = abs(scale.fraction(values[0]) - at) <= abs(scale.fraction(values[1]) - at) ? 0 : 1
            }
            sliderDrag = (state, thumb, indicator.key)
            moveSlider(to: point)
            return true
        }
        if let source = chain.first(where: { !$0.node.dragPaths.isEmpty })?.node {
            dragCandidate = source
            dragOrigin = point
            return true
        }
        return false
    }

    /// The pointer moved with the button down. True when the move was a
    /// part's own.
    func drag(to point: CGPoint, event: NSEvent?) -> Bool {
        if sliderDrag != nil { moveSlider(to: point); return true }
        if paneDrag != nil { movePanes(to: point); return true }
        if let source = dragCandidate {
            guard hypot(point.x - dragOrigin.x, point.y - dragOrigin.y) > 4 else { return true }
            dragCandidate = nil
            handOver(source, event: event)
            return true
        }
        return false
    }

    /// The button came up. True when it ended a slider's or a divider's
    /// drag: no click then.
    func endDrag(at point: CGPoint) -> Bool {
        dragCandidate = nil
        if let drag = sliderDrag {
            sliderDrag = nil
            // A press let go where it began moved nothing: the value to
            // report is the one the slider shows, not an empty one.
            if let indicator = indicator(of: drag.state) { copy.slider(drag.state, values: sliderValues(of: indicator), event: "release") }
            return true
        }
        if let drag = paneDrag {
            paneDrag = nil
            var group: ModNode?
            each { if group == nil, $0.part == "resizable", $0.id == drag.group { group = $0 } }
            if let group, let handler = group.handlers["resize"] {
                let row = isRow(group)
                let sizes = panes(of: group).filter { $0.display != "none" }.map { Double(row ? $0.frame.width : $0.frame.height) }
                copy.dispatch(handler, payload: ["args": [sizes]], gesture: true)
            }
            return true
        }
        return false
    }

    // MARK: Sizes

    /// `on_size_change`: each element that asked hears its first size, and
    /// each one after that.
    func reportSizes() {
        var seen: [String: CGSize] = [:]
        var changed: [String] = []
        for node in byKey.values where node.handlers["size"] != nil {
            seen[node.key] = node.frame.size
            if reportedSizes[node.key] != node.frame.size { changed.append(node.key) }
        }
        reportedSizes = seen
        guard !changed.isEmpty else { return }
        // After this layout, not inside it: the script may ask for a new
        // one. Handlers are numbered anew at each render, so each is looked
        // up when its turn comes.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for key in changed {
                    guard let node = self.byKey[key], let handler = node.handlers["size"] else { continue }
                    let size = node.frame.size
                    self.reportedSizes[key] = size
                    self.copy.dispatch(handler, payload: ["args": [["width": Double(size.width), "height": Double(size.height)]]])
                }
            }
        }
    }

    // MARK: The keyboard on parts

    /// The node that holds the keyboard.
    func focusedNode() -> ModNode? {
        var found: ModNode?
        if let key = state.focusedKey {
            each { if found == nil, $0.key == key { found = $0 } }
        } else if let handle = state.focusedHandle {
            each { if found == nil, $0.focusHandle == handle { found = $0 } }
        }
        return found
    }

    /// Gives a node the keyboard. `byKey`: the person got there with Tab,
    /// so a node with no look of its own for that gets the Mac's ring.
    func focus(node: ModNode, byKey: Bool) {
        if let id = node.field, node.kind == .input || node.kind == .textarea || node.kind == .editor {
            state.focusedKey = nil
            state.showsRing = false
            focusField(id)
            needsDisplay = true
            return
        }
        state.focusedKey = node.key
        state.showsRing = byKey
        if state.focusedHandle != node.focusHandle {
            state.focusedHandle = node.focusHandle
            copy.focusChanged(node.focusHandle)
        }
        wantsKeyboard = true
        if let window, window.firstResponder !== self {
            // A field in a surface's own window gives the keyboard back.
            if !window.isKeyWindow, surfacePanels.values.contains(where: { $0.isKeyWindow }) { window.makeKey() }
            window.makeFirstResponder(self)
        }
        needsDisplay = true
    }

    private func isShownNode(_ node: ModNode) -> Bool {
        var at: ModNode? = node
        while let current = at {
            if current.display == "none" || !current.visible { return false }
            at = current.parent
        }
        return true
    }

    /// Where Tab lands, in order: fields, parts a key acts on, and what the
    /// mod made a stop with `tab_index`.
    func tabStops() -> [ModNode] {
        var stops: [(node: ModNode, index: Int, order: Int)] = []
        var order = 0
        each { node in
            order += 1
            guard node.tabStop != false else { return }
            let field = node.field != nil && (node.kind == .input || node.kind == .textarea || node.kind == .editor)
            guard field || node.isControl || node.tabIndex != nil || node.tabStop == true else { return }
            if node.isControl, node.isDisabled { return }
            if node.part == "slider-thumb", node.enclosing(part: "slider")?.state["disabled"] == true { return }
            guard isShownNode(node) else { return }
            stops.append((node, node.tabIndex ?? 0, order))
        }
        return stops.sorted { ($0.index, $0.order) < ($1.index, $1.order) }.map(\.node)
    }

    /// Moves the keyboard to the next stop (`step` 1) or the one before (-1).
    /// False when the mod has none.
    @discardableResult
    public func moveFocus(by step: Int) -> Bool {
        let stops = tabStops()
        guard !stops.isEmpty else { return false }
        var current: Int?
        if let editor = window?.firstResponder as? NSText ?? surfacePanels.values.lazy.compactMap({ $0.firstResponder as? NSText }).first,
           let field = editor.delegate as? NSTextField, let id = field.identifier?.rawValue {
            current = stops.firstIndex { $0.field == id }
        }
        if current == nil, let focused = focusedNode() { current = stops.firstIndex { $0 === focused } }
        let next = current.map { ($0 + step + stops.count) % stops.count } ?? (step > 0 ? 0 : stops.count - 1)
        focus(node: stops[next], byKey: true)
        reveal(stops[next])
        return true
    }

    /// Scrolls what holds a node so that it shows.
    private func reveal(_ node: ModNode) {
        var inner = node.frame
        var at = node
        var moved = false
        while let up = at.parent, !at.isSurfaceRoot {
            if up.scrolls {
                var offset = state.scroll[up.key] ?? .zero
                let old = offset
                if up.overflowY == .scroll || up.kind == .vlist {
                    if inner.minY < offset.y { offset.y = inner.minY } else if inner.maxY > offset.y + up.frame.height { offset.y = inner.maxY - up.frame.height }
                }
                if up.overflowX == .scroll || up.kind == .hlist {
                    if inner.minX < offset.x { offset.x = inner.minX } else if inner.maxX > offset.x + up.frame.width { offset.x = inner.maxX - up.frame.width }
                }
                if offset != old {
                    state.scroll[up.key] = offset
                    moved = true
                }
                inner = inner.offsetBy(dx: -offset.x, dy: -offset.y)
            }
            inner = inner.offsetBy(dx: up.frame.minX, dy: up.frame.minY)
            at = up
        }
        if moved {
            clampScroll()
            layoutSurfaces()
            syncPanels()
            syncFields()
            needsDisplay = true
        }
    }

    /// A key the focused part, an open popover or a `Select` answers by
    /// itself, before the mod's own handlers. False when it is not theirs.
    func partKey(_ payload: [String: Any]) -> Bool {
        guard let key = payload["key"] as? String, let chord = payload["keystroke"] as? String else { return false }
        let plain = chord == key
        let focused = focusedNode()

        // A `Select` or a `Combobox` around what holds the keyboard.
        if plain, let focused, let select = keyPath(from: focused).first(where: { $0.part == "select" || $0.part == "combobox" }), !select.isDisabled {
            let open = select.state["open"] == true
            func tell(_ name: String, _ arguments: [Any]) {
                if let handler = select.handlers[name] { copy.dispatch(handler, payload: ["args": arguments], gesture: true) }
            }
            switch (key, open) {
            case ("enter", false), ("down", false), ("up", false):
                tell("open", [true])
                return true
            case ("enter", true):
                tell("confirm", [[String: Any]()])
                return true
            case ("escape", true):
                tell("dismiss", [[String: Any]()])
                tell("open", [false])
                return true
            default:
                break
            }
        }

        // Escape shuts the popover on top.
        if plain, key == "escape", let popover = topPopover {
            setOpen(popover, false)
            return true
        }

        if plain || chord == "shift-tab", key == "tab" {
            // One field alone: Tab is the mod's, as it was.
            let stops = tabStops()
            guard stops.count > 1 || stops.contains(where: { $0.field == nil }) else { return false }
            return moveFocus(by: chord == "shift-tab" ? -1 : 1)
        }

        // The part that holds the keyboard, whether Tab or the script's own
        // handle took it there.
        guard plain, let focused else { return false }
        if focused.part == "slider-thumb" { return sliderKey(key, on: focused) }
        guard key == "space" || key == "enter", focused.isControl, !focused.isDisabled else { return false }
        // Space and Return press the part, as a click would.
        if let handler = focused.handlers["click"] {
            copy.dispatch(handler, payload: ["click_count": 1, "modifiers": modifiers([]), "position": ["x": 0, "y": 0]], gesture: true)
        }
        if focused.actsOnPress { activate(focused) }
        if focused.popup?.kind == .popover { toggle(focused) }
        return true
    }

    /// A key in a field that Swiftr answers itself: ↑ and ↓ step a number
    /// field, Tab goes to the next stop, Escape shuts a popover.
    func fieldKey(_ selector: Selector, in node: ModNode) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard let frame = node.enclosing(part: "number"), let state = frame.number else { return false }
            step(state, selector == #selector(NSResponder.moveUp(_:)) ? "increment" : "decrement", frame: frame)
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            let stops = tabStops()
            guard stops.count > 1 else { return false }
            return moveFocus(by: selector == #selector(NSResponder.insertBacktab(_:)) ? -1 : 1)
        case #selector(NSResponder.cancelOperation(_:)):
            guard let popover = topPopover, let content = popover.popup?.content, within(node, content) else { return false }
            setOpen(popover, false)
            return true
        default:
            return false
        }
    }

    // MARK: Files, in and out

    /// The element under a drag that takes dropped files (`on_drop`).
    private func dropTarget(_ sender: NSDraggingInfo) -> ModNode? {
        guard sender.draggingSource as? ModView !== self else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        return chain(at: point).first(where: { $0.node.handlers["drop"] != nil })?.node
    }

    private func droppedPaths(_ sender: NSDraggingInfo) -> [String] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map(\.path)
    }

    func dropEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = dropTarget(sender)
        if dropKey != target?.key {
            dropKey = target?.key
            needsDisplay = true
        }
        return target == nil ? [] : .copy
    }

    func dropLeft() {
        if dropKey != nil { dropKey = nil; needsDisplay = true }
    }

    func drop(_ sender: NSDraggingInfo) -> Bool {
        defer { dropLeft() }
        guard let target = dropTarget(sender), let handler = target.handlers["drop"] else { return false }
        let paths = droppedPaths(sender)
        guard !paths.isEmpty else { return false }
        copy.dispatch(handler, payload: ["paths": paths], gesture: true)
        return true
    }

    /// Starts the drag of the files an element hands over (`drag_paths`).
    private func handOver(_ source: ModNode, event: NSEvent?) {
        guard let event, window != nil, let rect = rect(of: source) else { return }
        // Files on another machine have no place on this Mac to point at.
        guard source.dragMachine == nil else { return }
        let paths = source.dragPaths.filter { copy.runtime.mayHandOver($0) }
        guard !paths.isEmpty else { return }
        let home = center.userHome
        let items = paths.enumerated().map { index, path -> NSDraggingItem in
            let url = URL(fileURLWithPath: ModFiles.expand(path, home: home))
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let side: CGFloat = 32, nudge = CGFloat(index) * 4
            item.setDraggingFrame(CGRect(x: rect.midX - side / 2 + nudge, y: rect.midY - side / 2 + nudge, width: side, height: side), contents: icon)
            return item
        }
        state.pressed = []
        needsDisplay = true
        beginDraggingSession(with: items, event: event, source: self)
    }
}

extension ModView: NSDraggingSource {
    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
