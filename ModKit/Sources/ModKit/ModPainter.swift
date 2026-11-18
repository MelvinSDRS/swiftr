import AppKit
import Foundation

/// What changes between two draws of one tree: the pointer, the keyboard,
/// how far each list is scrolled, the clock.
struct ModPaintState {
    /// The nodes under the pointer, by key.
    var hovered: Set<String> = []
    /// The nodes pressed.
    var pressed: Set<String> = []
    var focusedHandle: String?
    /// The node that holds the keyboard where the script tracks none.
    var focusedKey: String?
    /// The focused node got there by Tab: one that sets no look of its own
    /// for it gets the Mac's ring.
    var showsRing = false
    var scroll: [String: CGPoint] = [:]
    var time: CFTimeInterval = 0
    /// Text's color where the mod sets none.
    var foreground = NSColor.labelColor
    var scale: CGFloat = 2
    /// Draw what fields hold: for a picture of the panel, where no real
    /// field sits on top.
    var drawsFields = false
    /// On a surface that is the panel's own (a sidebar): the mod's outer
    /// box keeps no fill, border or rounded corners of its own.
    var flush = false
    var placeholder = NSColor.secondaryLabelColor
    /// The text the person selected: for each node, the range.
    var selection: [String: NSRange] = [:]
    var selectionColor = NSColor.selectedTextBackgroundColor
}

/// Draws a laid-out tree with Core Graphics, in a flipped context (y down).
struct ModPainter {
    let images: ModImages
    var state: ModPaintState

    func draw(_ root: ModNode, in context: CGContext, dirty: CGRect) {
        draw(root, origin: .zero, context: context, dirty: dirty, color: state.foreground, underline: false, groups: [], outer: state.flush)
    }

    /// Draws a surface's content with its corner at `origin`.
    func draw(surface root: ModNode, at origin: CGPoint, in context: CGContext, dirty: CGRect) {
        draw(root, origin: origin, context: context, dirty: dirty, color: state.foreground, underline: false, groups: [])
    }

    private func isFocused(_ node: ModNode) -> Bool {
        if let key = state.focusedKey { return node.key == key }
        if let handle = node.focusHandle { return handle == state.focusedHandle }
        return false
    }

    private func draw(_ node: ModNode, origin: CGPoint, context: CGContext, dirty: CGRect, color inherited: NSColor, underline inheritedUnderline: Bool, groups: Set<String>, outer: Bool = false) {
        guard node.display != "none" else { return }
        let rect = node.frame.offsetBy(dx: origin.x, dy: origin.y)
        let clips = node.overflowX != .visible || node.overflowY != .visible || node.scrolls
        // Nothing of a leaf or a clipped box shows outside its frame.
        if clips || node.children.isEmpty, !rect.insetBy(dx: -24, dy: -24).intersects(dirty) { return }

        var paint = node.paint
        let hovered = state.hovered.contains(node.key)
        if hovered, let hover = node.hover { paint = paint.merged(hover) }
        if let over = node.groupHover, let name = node.groupHoverName, groups.contains(name) { paint = paint.merged(over) }
        if let active = node.active, state.pressed.contains(node.key) { paint = paint.merged(active) }
        let focused = (node.focus != nil || state.showsRing) && isFocused(node)
        if focused, let focus = node.focus { paint = paint.merged(focus) }
        defer { if focused, node.focus == nil, state.showsRing { ring(node, rect: node.frame.offsetBy(dx: origin.x, dy: origin.y), context: context) } }
        let color = paint.textColor ?? inherited
        let underline = paint.underline ?? inheritedUnderline
        guard node.visible else { return }
        // The outer box, flush: the surface under it is its background.
        let bare = outer && (node.kind == .div || node.kind == .frag)
        if bare {
            paint.fill = nil
            paint.borderColor = nil
            paint.shadow = nil
        }

        let opacity = node.opacityOverride ?? paint.opacity ?? 1
        if opacity <= 0 { return }
        if opacity < 1 {
            context.saveGState()
            context.setAlpha(opacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer {
            if opacity < 1 {
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
        if let period = node.spin, period > 0 {
            context.saveGState()
            let angle = CGFloat((state.time * 1000).truncatingRemainder(dividingBy: period) / period) * 2 * .pi
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: angle)
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }
        defer { if let period = node.spin, period > 0 { context.restoreGState() } }

        switch node.kind {
        case .text:
            if let range = state.selection[node.key], let line = node.line {
                context.setFillColor(state.selectionColor.cgColor)
                for box in line.rects(for: range, in: rect) { context.fill(box) }
            }
            // `frames` on the element around it: the text of this moment.
            var shown: String?
            if let frames = node.parent?.frames, !frames.isEmpty, node.parent?.children.count == 1, let interval = node.parent?.frameInterval {
                shown = frames[Int(state.time / interval) % frames.count]
            }
            node.line?.draw(in: rect, color: color, underline: underline, context: context, override: shown)
            return
        case .svg:
            if let source = node.source { images.draw(source, in: rect, tint: color, scale: state.scale, context: context) }
            return
        case .img:
            box(node, rect: rect, paint: paint, context: context)
            if let source = node.source {
                context.saveGState()
                context.addPath(Self.path(rect, radii: node.radii))
                context.clip()
                images.draw(source, in: rect, tint: nil, scale: state.scale, context: context)
                context.restoreGState()
            }
            return
        case .md:
            if state.selection[node.key] != nil {
                context.setFillColor(state.selectionColor.cgColor)
                context.fill(rect)
            }
            ModMarkdown.draw(node, in: rect, color: color, context: context)
            return
        case .input, .textarea, .editor:
            box(node, rect: rect, paint: paint, context: context)
            if state.drawsFields {
                let value = node.raw["v"] as? String ?? ""
                let options = node.raw["o"] as? [String: Any] ?? [:]
                let shown = value.isEmpty ? options["placeholder"] as? String ?? "" : (options["masked"] as? Bool == true ? String(repeating: "•", count: value.count) : value)
                var style = node.textStyle
                style.nowrap = node.kind == .input
                style.ellipsis = node.kind == .input
                var at = rect
                if node.kind == .input {
                    at = CGRect(x: rect.minX + 2, y: rect.midY - style.lineHeightPx / 2, width: rect.width - 4, height: style.lineHeightPx)
                }
                ModTextLayout(text: shown, style: style).draw(in: at, color: value.isEmpty ? state.placeholder : color, underline: false, context: context)
            }
            return
        case .path:
            drawPath(node, origin: origin, paint: paint, context: context)
            return
        case .div, .vlist, .hlist, .frag:
            break
        }

        box(node, rect: rect, paint: paint, context: context)
        // A slider's filled part, under its thumb.
        if let fill = node.fill, let look = node.range, fill.width > 0, fill.height > 0 {
            box(rect: fill.offsetBy(dx: rect.minX, dy: rect.minY), radii: node.rangeRadii, borders: [0, 0, 0, 0], dashed: false, paint: look, context: context)
        }
        guard !node.children.isEmpty else { return }

        var childOrigin = rect.origin
        var childDirty = dirty
        if clips {
            context.saveGState()
            if bare { context.addRect(rect) } else { context.addPath(Self.path(rect, radii: node.radii)) }
            context.clip()
            childDirty = dirty.intersection(rect)
            if let offset = state.scroll[node.key] {
                childOrigin.x -= offset.x
                childOrigin.y -= offset.y
            }
        }
        var inner = groups
        if hovered, let group = node.group { inner.insert(group) }
        if !childDirty.isNull {
            for child in node.children {
                draw(child, origin: childOrigin, context: context, dirty: childDirty, color: color, underline: underline, groups: inner)
            }
        }
        if clips {
            context.restoreGState()
            if node.scrolls, hovered { scroller(node, rect: rect, color: color, context: context) }
        }
    }

    /// The thumb that says where a list is, while the pointer is over it.
    private func scroller(_ node: ModNode, rect: CGRect, color: NSColor, context: CGContext) {
        let offset = state.scroll[node.key] ?? .zero
        context.setFillColor(color.withAlphaComponent(0.28).cgColor)
        if node.contentSize.height > rect.height + 1, node.overflowX != .scroll || node.overflowY == .scroll || node.kind == .vlist {
            let length = max(24, rect.height * rect.height / node.contentSize.height)
            let travel = rect.height - length - 4
            let at = travel * offset.y / max(1, node.contentSize.height - rect.height)
            let thumb = CGRect(x: rect.maxX - 7, y: rect.minY + 2 + at, width: 5, height: length)
            context.addPath(CGPath(roundedRect: thumb, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            context.fillPath()
        }
        if node.contentSize.width > rect.width + 1, node.overflowX == .scroll || node.kind == .hlist {
            let length = max(24, rect.width * rect.width / node.contentSize.width)
            let travel = rect.width - length - 4
            let at = travel * offset.x / max(1, node.contentSize.width - rect.width)
            let thumb = CGRect(x: rect.minX + 2 + at, y: rect.maxY - 7, width: length, height: 5)
            context.addPath(CGPath(roundedRect: thumb, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            context.fillPath()
        }
    }

    // MARK: Boxes

    private static let shadows: [String: (y: CGFloat, blur: CGFloat, alpha: CGFloat)] = [
        "2xs": (1, 1, 0.05), "xs": (1, 2, 0.06), "sm": (1, 3, 0.10), "md": (4, 8, 0.12),
        "lg": (10, 18, 0.14), "xl": (20, 28, 0.16), "2xl": (25, 50, 0.25),
    ]

    /// The Mac's ring around what holds the keyboard.
    private func ring(_ node: ModNode, rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(3)
        let around = rect.insetBy(dx: -1.5, dy: -1.5)
        context.addPath(Self.path(around, radii: node.radii.map { max($0, 2) + 1.5 }))
        context.strokePath()
        context.restoreGState()
    }

    private func box(_ node: ModNode, rect: CGRect, paint: ModPaint, context: CGContext) {
        box(rect: rect, radii: node.radii, borders: node.borders, dashed: node.dashed, paint: paint, context: context)
    }

    private func box(rect: CGRect, radii: [CGFloat], borders b: [CGFloat], dashed: Bool, paint: ModPaint, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        if let fill = paint.fill {
            let shape = Self.path(rect, radii: radii)
            let shadow = paint.shadow.flatMap { Self.shadows[$0] }
            switch fill {
            case .color(let color):
                if let shadow {
                    context.saveGState()
                    context.setShadow(offset: CGSize(width: 0, height: -shadow.y), blur: shadow.blur, color: NSColor.black.withAlphaComponent(shadow.alpha).cgColor)
                }
                context.setFillColor(color.cgColor)
                context.addPath(shape)
                context.fillPath()
                if shadow != nil { context.restoreGState() }
            case .gradient(let stops, let angle):
                context.saveGState()
                context.addPath(shape)
                context.clip()
                let colors = stops.map { $0.0.cgColor } as CFArray
                let locations = stops.map { $0.1 }
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) {
                    // CSS angles: 0 points up, 90 to the right.
                    let radians = angle * .pi / 180
                    let dx = sin(radians), dy = -cos(radians)
                    let half = (abs(dx) * rect.width + abs(dy) * rect.height) / 2
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    context.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: center.x - dx * half, y: center.y - dy * half),
                        end: CGPoint(x: center.x + dx * half, y: center.y + dy * half),
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                    )
                }
                context.restoreGState()
            case .slash(let color, let width, let interval):
                context.saveGState()
                context.addPath(shape)
                context.clip()
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(max(width, 0.5))
                let step = max(width + interval, 2)
                var x = rect.minX - rect.height
                while x < rect.maxX {
                    context.move(to: CGPoint(x: x, y: rect.maxY))
                    context.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                    x += step
                }
                context.strokePath()
                context.restoreGState()
            case .checker(let color, let size):
                context.saveGState()
                context.addPath(shape)
                context.clip()
                context.setFillColor(color.cgColor)
                let cell = max(size, 1)
                var row = 0
                var y = rect.minY
                while y < rect.maxY {
                    var x = rect.minX + (row % 2 == 0 ? 0 : cell)
                    while x < rect.maxX {
                        context.fill(CGRect(x: x, y: y, width: cell, height: cell))
                        x += cell * 2
                    }
                    y += cell
                    row += 1
                }
                context.restoreGState()
            }
        }

        guard let color = paint.borderColor, color.alphaComponent > 0, b.contains(where: { $0 > 0 }) else { return }
        if b[0] == b[1], b[1] == b[2], b[2] == b[3] {
            let width = b[0]
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            if dashed { context.setLineDash(phase: 0, lengths: [width * 3, width * 2]) }
            context.addPath(Self.path(rect.insetBy(dx: width / 2, dy: width / 2), radii: radii.map { max(0, $0 - width / 2) }))
            context.strokePath()
            context.restoreGState()
            return
        }
        // Sides of different widths: each its own bar, inside the corners.
        context.saveGState()
        if radii.contains(where: { $0 > 0 }) {
            context.addPath(Self.path(rect, radii: radii))
            context.clip()
        }
        context.setFillColor(color.cgColor)
        if b[0] > 0 { context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: b[0])) }
        if b[2] > 0 { context.fill(CGRect(x: rect.minX, y: rect.maxY - b[2], width: rect.width, height: b[2])) }
        if b[3] > 0 { context.fill(CGRect(x: rect.minX, y: rect.minY, width: b[3], height: rect.height)) }
        if b[1] > 0 { context.fill(CGRect(x: rect.maxX - b[1], y: rect.minY, width: b[1], height: rect.height)) }
        context.restoreGState()
    }

    /// A box with a radius per corner (top-left, top-right, bottom-right,
    /// bottom-left), each no more than half the short side.
    static func path(_ rect: CGRect, radii: [CGFloat]) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let r = radii.map { min(max($0, 0), limit) }
        if r[0] == r[1], r[1] == r[2], r[2] == r[3] {
            return r[0] <= 0 ? CGPath(rect: rect, transform: nil) : CGPath(roundedRect: rect, cornerWidth: r[0], cornerHeight: r[0], transform: nil)
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + r[0], y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r[1], y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r[1]), radius: r[1])
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r[2]))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r[2], y: rect.maxY), radius: r[2])
        path.addLine(to: CGPoint(x: rect.minX + r[3], y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r[3]), radius: r[3])
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r[0]))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r[0], y: rect.minY), radius: r[0])
        path.closeSubpath()
        return path
    }

    // MARK: Free shapes

    private func drawPath(_ node: ModNode, origin: CGPoint, paint: ModPaint, context: CGContext) {
        guard let spec = node.raw["path"] as? [String: Any], let ops = spec["ops"] as? [[Any]] else { return }
        func n(_ op: [Any], _ index: Int) -> CGFloat { (op[index] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0 }
        let path = CGMutablePath()
        for op in ops {
            guard let name = op.first as? String else { continue }
            switch name {
            case "M" where op.count >= 3: path.move(to: CGPoint(x: origin.x + n(op, 1), y: origin.y + n(op, 2)))
            case "L" where op.count >= 3: path.addLine(to: CGPoint(x: origin.x + n(op, 1), y: origin.y + n(op, 2)))
            case "Q" where op.count >= 5:
                path.addQuadCurve(to: CGPoint(x: origin.x + n(op, 3), y: origin.y + n(op, 4)), control: CGPoint(x: origin.x + n(op, 1), y: origin.y + n(op, 2)))
            case "C" where op.count >= 7:
                path.addCurve(
                    to: CGPoint(x: origin.x + n(op, 5), y: origin.y + n(op, 6)),
                    control1: CGPoint(x: origin.x + n(op, 1), y: origin.y + n(op, 2)),
                    control2: CGPoint(x: origin.x + n(op, 3), y: origin.y + n(op, 4))
                )
            case "A" where op.count >= 8: path.addLine(to: CGPoint(x: origin.x + n(op, 6), y: origin.y + n(op, 7)))
            case "Z": path.closeSubpath()
            default: break
            }
        }
        guard case .color(let color)? = paint.fill else { return }
        context.saveGState()
        context.addPath(path)
        if spec["mode"] as? String == "stroke" {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth((spec["width"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if let dash = spec["dash"] as? [NSNumber], !dash.isEmpty { context.setLineDash(phase: 0, lengths: dash.map { CGFloat($0.doubleValue) }) }
            context.strokePath()
        } else {
            context.setFillColor(color.cgColor)
            context.fillPath()
        }
        context.restoreGState()
    }
}

/// Where the pointer is in a tree.
enum ModHit {
    struct Found {
        let node: ModNode
        /// In the tree root's space, scroll counted.
        let rect: CGRect
    }

    /// The node the pointer acts on (the topmost that listens, looks
    /// different under the pointer, or scrolls) and the nodes around it,
    /// innermost first. Empty over nothing.
    static func chain(_ root: ModNode, origin: CGPoint = .zero, at point: CGPoint, scroll: [String: CGPoint]) -> [Found] {
        var out: [Found] = []
        _ = find(root, origin: origin, point: point, scroll: scroll, into: &out)
        return out
    }

    private static func find(_ node: ModNode, origin: CGPoint, point: CGPoint, scroll: [String: CGPoint], into out: inout [Found]) -> Bool {
        guard node.display != "none", node.visible, node.kind != .text else { return false }
        let rect = node.frame.offsetBy(dx: origin.x, dy: origin.y)
        let inside = rect.contains(point)
        let clips = node.overflowX != .visible || node.overflowY != .visible || node.scrolls
        if clips, !inside { return false }
        var childOrigin = rect.origin
        if clips, let offset = scroll[node.key] {
            childOrigin.x -= offset.x
            childOrigin.y -= offset.y
        }
        // Later children are drawn over earlier ones.
        for child in node.children.reversed() where find(child, origin: childOrigin, point: point, scroll: scroll, into: &out) {
            out.append(Found(node: node, rect: rect))
            return true
        }
        if inside, node.isInteractive || node.scrolls {
            out.append(Found(node: node, rect: rect))
            return true
        }
        return false
    }

    /// Where a node is, in the root's space. Nil when it isn't in the tree.
    static func rect(of key: String, in root: ModNode, scroll: [String: CGPoint]) -> CGRect? {
        locate(root, origin: .zero, scroll: scroll) { $0.key == key }?.rect
    }

    static func locate(_ node: ModNode, origin: CGPoint, scroll: [String: CGPoint], where match: (ModNode) -> Bool) -> Found? {
        let rect = node.frame.offsetBy(dx: origin.x, dy: origin.y)
        if match(node) { return Found(node: node, rect: rect) }
        var childOrigin = rect.origin
        if let offset = scroll[node.key] {
            childOrigin.x -= offset.x
            childOrigin.y -= offset.y
        }
        for child in node.children {
            if let found = locate(child, origin: childOrigin, scroll: scroll, where: match) { return found }
        }
        return nil
    }
}
