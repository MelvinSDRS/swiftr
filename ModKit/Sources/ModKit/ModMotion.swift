import AppKit
import Foundation

/// A property on its way to a new value (`transition`, `spring`).
struct ModRun {
    var from: CGFloat
    var to: CGFloat
    /// The values are percents of the parent, not points.
    var percent: Bool
    var start: CFTimeInterval
    var spec: ModMotion
    /// What shows now.
    var value: CGFloat
    var velocity: CGFloat = 0
    var last: CFTimeInterval
}

/// Motion Swiftr runs by itself, without the script: `spin`, `frames`,
/// `loop`, `transition`, `spring`. One clock for every mod, so two spinners
/// turn together.
extension ModView {
    /// The clock's time. Tests set `timeOverride` to hold it still.
    var motionTime: CFTimeInterval { timeOverride ?? CACurrentMediaTime() }

    private static func ease(_ t: CGFloat, _ name: String) -> CGFloat {
        let t = min(max(t, 0), 1)
        switch name {
        case "linear": return t
        case "ease-in": return t * t
        case "ease-out": return 1 - (1 - t) * (1 - t)
        default: return t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t)
        }
    }

    /// What a property is set to, as the script wrote it.
    private func target(_ property: String, of node: ModNode) -> ModLength? {
        switch property {
        case "opacity": return .px(node.paint.opacity ?? 1)
        case "width": return ModLength(node.style["w"])
        case "height": return ModLength(node.style["h"])
        case "left": return ModLength(node.style["left"])
        case "top": return ModLength(node.style["top"])
        default: return nil
        }
    }

    /// A new tree: where a property with a `transition` or a `spring` got
    /// a new value since the last one, it sets off from what shows now.
    func startMotion(in tree: ModNode) {
        // A slider the script may have moved since: its own value counts again.
        if sliderDrag == nil { sliderValues = [:] }
        let now = motionTime
        var seen = Set<String>()
        tree.walk(open: { _ in true }) { node in
            for (property, spec) in node.motions {
                let id = node.key + "|" + property
                seen.insert(id)
                if isThumbPlace(property, of: node) { continue }
                guard let goal = target(property, of: node) else {
                    targets[id] = nil
                    runs[id] = nil
                    continue
                }
                defer { targets[id] = goal }
                guard let old = targets[id], old != goal else { continue }
                switch (old, goal) {
                case (.px(let a), .px(let b)), (.percent(let a), .percent(let b)):
                    let running = runs[id]
                    var percent = false
                    if case .percent = goal { percent = true }
                    runs[id] = ModRun(from: running?.value ?? a, to: b, percent: percent, start: now, spec: spec,
                                      value: running?.value ?? a, velocity: running?.velocity ?? 0, last: now)
                default:
                    // From points to a percent, or to `auto`: no way between the two.
                    runs[id] = nil
                }
            }
        }
        for id in targets.keys where !seen.contains(id) { targets[id] = nil }
        for id in runs.keys where !seen.contains(id) { runs[id] = nil }
    }

    /// A thumb's place along its slider is its slider's to set
    /// (`placeSliders`), with the thumb's own `transition` on it.
    private func isThumbPlace(_ property: String, of node: ModNode) -> Bool {
        node.part == "slider-thumb" && node.slider != nil && (property == "left" || property == "top")
    }

    /// Moves a run on to `now`. True when it got where it was going.
    func advance(_ run: inout ModRun, to now: CFTimeInterval) -> Bool {
        if run.spec.spring {
            // A damped spring, in small steps.
            let omega = CGFloat(2 * Double.pi / run.spec.response), damping = max(run.spec.damping, 0.05)
            var left = min(max(now - run.last, 0), 0.1)
            while left > 0 {
                let dt = CGFloat(min(left, 1.0 / 240))
                let pull = -omega * omega * (run.value - run.to) - 2 * damping * omega * run.velocity
                run.velocity += pull * dt
                run.value += run.velocity * dt
                left -= 1.0 / 240
            }
            run.last = now
            let near = max(run.spec.epsilon, abs(run.to - run.from) * 0.001, 0.0005)
            if abs(run.value - run.to) < near, abs(run.velocity) < near * 20 {
                run.value = run.to
                return true
            }
            return false
        }
        let t = run.spec.duration > 0 ? CGFloat((now - run.start - run.spec.delay) / run.spec.duration) : 1
        run.value = run.from + (run.to - run.from) * Self.ease(t, run.spec.easing)
        return t >= 1
    }

    private func set(_ property: String, _ value: CGFloat, percent: Bool, on node: ModNode) {
        switch property {
        case "opacity":
            node.opacityOverride = min(max(value, 0), 1)
        case "width":
            node.sizeOverride["w"] = percent ? .percent(value) : .px(max(value, 0))
        case "height":
            node.sizeOverride["h"] = percent ? .percent(value) : .px(max(value, 0))
        case "left", "top":
            // A move from where the layout rests the node.
            let side = property == "left" ? "left" : "top"
            var rest: CGFloat = 0
            var scale: CGFloat = 1
            switch ModLength(node.style[side]) {
            case .px(let v)?: rest = v
            case .percent(let v)?:
                rest = v
                if !percent { rest = 0 }
            default: break
            }
            if percent { scale = ((side == "left" ? node.parent?.frame.width : node.parent?.frame.height) ?? 0) / 100 }
            if side == "left" { node.shift.x = (value - rest) * scale } else { node.shift.y = (value - rest) * scale }
        default:
            break
        }
    }

    /// Sets what moves to its value at `time`, on the tree as it is: before
    /// a layout, and on each tick.
    func applyMotion(at time: CFTimeInterval) {
        guard let tree else { return }
        tree.walk(open: { _ in true }) { node in
            guard !node.motions.isEmpty || !node.loops.isEmpty else { return }
            node.opacityOverride = nil
            node.shift = .zero
            for property in Set(node.motions.keys).union(node.loops.map(\.property)) {
                if property == "width" { node.sizeOverride["w"] = nil }
                if property == "height" { node.sizeOverride["h"] = nil }
            }
            for loop in node.loops {
                // There and back, once a period.
                let phase = CGFloat((time / loop.period).truncatingRemainder(dividingBy: 1))
                let swing = phase < 0.5 ? phase * 2 : 2 - phase * 2
                set(loop.property, loop.from + (loop.to - loop.from) * Self.ease(swing, loop.easing), percent: false, on: node)
            }
            for property in node.motions.keys where !isThumbPlace(property, of: node) {
                let id = node.key + "|" + property
                guard var run = runs[id] else { continue }
                let done = advance(&run, to: time)
                if done {
                    runs[id] = nil
                } else {
                    runs[id] = run
                    set(property, run.value, percent: run.percent, on: node)
                }
            }
        }
    }

    /// What moves now, among what shows.
    private func motionNow() -> (paints: Bool, sizes: Bool, fast: Bool) {
        var paints = false, sizes = false, fast = !runs.isEmpty
        each { node in
            guard node.spin != nil || !node.frames.isEmpty || !node.loops.isEmpty || !node.motions.isEmpty else { return }
            guard node.display != "none" else { return }
            if node.spin != nil || !node.loops.isEmpty { paints = true }
            if !node.frames.isEmpty {
                paints = true
                if node.frameInterval < 0.033 { fast = true }
            }
            if node.loops.contains(where: { $0.property == "width" || $0.property == "height" }) { sizes = true }
            for property in node.motions.keys where runs[node.key + "|" + property] != nil {
                paints = true
                if property == "width" || property == "height" { sizes = true }
            }
        }
        return (paints, sizes, fast)
    }

    /// Runs the clock while something moves or a surface shows (it follows
    /// the panel inside its window), and stops it when nothing does.
    func runClock() {
        let moving = motionNow()
        var rate = 0
        if window != nil, isShown, moving.paints || !surfacePanels.isEmpty { rate = moving.fast ? 60 : 30 }
        guard rate != clockRate || (rate > 0 && clock == nil) else { return }
        clock?.invalidate()
        clock = nil
        clockRate = rate
        guard rate > 0 else { return }
        let timer = Timer(timeInterval: 1.0 / Double(rate), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    func tick() {
        guard let tree, window != nil, isShown else { runClock(); return }
        followWindow()
        let moving = motionNow()
        if moving.sizes {
            // A width or a height on the move: everything around it follows.
            relayout()
            return
        }
        guard moving.paints else { runClock(); return }
        // A transition or a spring on its way: short, and its last step
        // leaves no mark on the node, so the whole panel is drawn again.
        let running = !runs.isEmpty
        applyMotion(at: motionTime)
        if running { placeAllSliders() }
        var dirty = CGRect.null
        func visit(_ node: ModNode, origin: CGPoint, around: CGRect) {
            guard node.display != "none" else { return }
            if !node.motions.isEmpty || !node.loops.isEmpty {
                // Where the layout rests it, and where it is now.
                node.frame.origin = CGPoint(x: node.restOrigin.x + node.shift.x + node.slide.x, y: node.restOrigin.y + node.shift.y + node.slide.y)
            }
            let rect = node.frame.offsetBy(dx: origin.x, dy: origin.y)
            if node.spin != nil {
                dirty = dirty.union(rect.insetBy(dx: -rect.width * 0.25 - 1, dy: -rect.height * 0.25 - 1))
            } else if !node.frames.isEmpty || node.opacityOverride != nil || !node.loops.isEmpty {
                dirty = dirty.union(rect.insetBy(dx: -24, dy: -24))
            }
            if node.shift != .zero || node.loops.contains(where: { $0.property == "left" || $0.property == "top" }) { dirty = dirty.union(around) }
            let offset = state.scroll[node.key] ?? .zero
            for child in node.children { visit(child, origin: CGPoint(x: rect.minX - offset.x, y: rect.minY - offset.y), around: rect) }
        }
        visit(tree, origin: .zero, around: bounds)
        for owner in surfaces {
            if let popup = owner.popup, let content = popup.content { visit(content, origin: popup.rect.origin, around: popup.rect) }
        }
        if running {
            needsDisplay = true
            // Surfaces pinned to something that moved go with it.
            if !surfaces.isEmpty { layoutSurfaces(); syncPanels() }
        } else if !dirty.isNull {
            setNeedsDisplay(dirty)
        }
        // The last transition ended: back to the slow clock, or none.
        if runs.isEmpty, clockRate == 60 { runClock() }
    }
}
