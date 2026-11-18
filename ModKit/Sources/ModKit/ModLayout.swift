import AppKit
import CFlex
import Foundation

/// Lays a mod's tree out: flexbox, as its script wrote it for herdr-app
/// (GPUI's layout is the web's flexbox). Yoga does the arithmetic.
///
/// Three things differ from Yoga's own habits, to match the web's:
/// - a `div()` is a block: its children stack and fill its width;
/// - children shrink only where the web would let them (below);
/// - text is a leaf that wraps, and says how big it is.
enum ModLayout {
    /// Pictures' own sizes, for the ones a mod doesn't size.
    static var intrinsicSize: (String) -> CGSize? = { _ in nil }

    /// Lays `root` out in `size` (a nil side: as big as the content).
    /// Answers the root's size.
    @discardableResult
    static func layout(_ root: ModNode, width: CGFloat?, height: CGFloat?, baseStyle: ModTextStyle) -> CGSize {
        let host = fx_new()!
        defer { fx_free_tree(host) }
        fx_direction(host, 0)
        fx_align_items(host, 4)
        var refs: [(ModNode, FXNodeRef)] = []
        // Text settings first: whether a box may shrink depends on the text
        // under it.
        resolveText(root, inherited: baseStyle)
        let child = make(root, inherited: baseStyle, parent: nil, refs: &refs)
        // The root fills what it is given, as a block's only child.
        fx_add_child(host, child, 0)
        if width != nil, root.style["w"] == nil { fx_align_self(child, 4) }
        if height != nil, root.style["h"] == nil, root.style["fg"] == nil { fx_grow(child, 1); fx_shrink(child, 1) }
        fx_layout(host, Float(width ?? .nan), Float(height ?? .nan))
        for (node, ref) in refs {
            var x: Float = 0, y: Float = 0, w: Float = 0, h: Float = 0
            fx_frame(ref, &x, &y, &w, &h)
            // A `left` or `top` on the move shifts the node from where it rests.
            node.restOrigin = CGPoint(x: CGFloat(x), y: CGFloat(y))
            node.slide = .zero
            node.frame = CGRect(x: CGFloat(x) + node.shift.x, y: CGFloat(y) + node.shift.y, width: CGFloat(w), height: CGFloat(h))
        }
        finish(root)
        return root.frame.size
    }

    /// After the frames: how big each scrolling node's content is.
    private static func finish(_ node: ModNode) {
        for child in node.children { finish(child) }
        guard node.scrolls else { return }
        var size = CGSize.zero
        for child in node.children where child.display != "none" {
            size.width = max(size.width, child.frame.maxX)
            size.height = max(size.height, child.frame.maxY)
        }
        let s = node.style
        func px(_ key: String) -> CGFloat { if case .px(let v)? = ModLength(s[key]) { return v }; return 0 }
        size.width += px("pr") + node.borders[1]
        size.height += px("pb") + node.borders[2]
        node.contentSize = size
    }

    private static func unit(_ length: ModLength) -> (Float, Int32) {
        switch length {
        case .px(let v): (Float(v), 0)
        case .percent(let v): (Float(v), 1)
        case .auto: (0, 2)
        }
    }

    private static let alignments: [String: Int32] = ["auto": 0, "start": 1, "center": 2, "end": 3, "stretch": 4, "baseline": 5, "between": 6, "around": 7, "evenly": 8]
    private static let justifications: [String: Int32] = ["start": 0, "center": 1, "end": 2, "between": 3, "around": 4, "evenly": 5]

    /// Whether text somewhere under the node can wrap: such a node may get
    /// narrower than its content, as on the web.
    private static func wraps(_ node: ModNode) -> Bool {
        if node.kind == .text { return !node.textStyle.nowrap }
        if node.kind == .md { return true }
        if node.style["w"] != nil { return false }
        return node.children.contains(where: wraps)
    }

    private static func resolveText(_ node: ModNode, inherited: ModTextStyle) {
        var text = inherited
        if !node.style.isEmpty { text.apply(node.style) }
        node.textStyle = text
        // What cuts or clamps text is the box's own, not handed down.
        var down = text
        down.ellipsis = false
        down.clamp = 0
        for child in node.children {
            if child.kind == .text { child.textStyle = text } else { resolveText(child, inherited: down) }
        }
    }

    private static func make(_ node: ModNode, inherited: ModTextStyle, parent: ModNode?, refs: inout [(ModNode, FXNodeRef)]) -> FXNodeRef {
        let ref = fx_new()!
        refs.append((node, ref))
        let text = node.textStyle
        let s = node.style

        if node.kind == .text {
            node.line = ModTextLayout(text: node.text ?? "", style: text)
            fx_set_measure(ref, Unmanaged.passUnretained(node).toOpaque(), measureLeaf)
        } else {
            apply(s, node: node, to: ref)
            switch node.kind {
            case .svg, .img:
                // A picture nobody sized takes its own size.
                if s["w"] == nil || s["h"] == nil, let own = node.source.flatMap(intrinsicSize) {
                    if s["w"] == nil, s["h"] == nil { fx_size(ref, 0, Float(own.width), 0); fx_size(ref, 1, Float(own.height), 0) }
                    else if own.width > 0, own.height > 0 { fx_aspect(ref, Float(own.width / own.height)) }
                }
            case .input, .textarea, .editor, .md:
                fx_set_measure(ref, Unmanaged.passUnretained(node).toOpaque(), measureLeaf)
            case .vlist, .hlist:
                listRows(node, ref: ref, inherited: text, refs: &refs)
                shrinkRule(node, ref: ref, parent: parent)
                return ref
            default:
                break
            }
        }
        shrinkRule(node, ref: ref, parent: parent)

        guard node.kind == .div || node.kind == .path else { return ref }
        var index: Int32 = 0
        for child in node.children {
            let made = make(child, inherited: text, parent: node, refs: &refs)
            fx_add_child(ref, made, index)
            index += 1
        }
        return ref
    }

    /// How much a child gives way when its parent is too small. Yoga would
    /// let every child shrink to nothing; the web stops at what the content
    /// needs. So: a child shrinks if the mod said so (`flex_1`,
    /// `flex_shrink`), if it cuts or scrolls its content, or if its text can
    /// wrap; never in a block, nor along the way a parent scrolls.
    private static func shrinkRule(_ node: ModNode, ref: FXNodeRef, parent: ModNode?) {
        let s = node.style
        guard let parent else { return }
        let block = parent.display != "flex" && parent.kind == .div
        if block || parent.kind == .vlist || parent.kind == .hlist {
            fx_grow(ref, 0)
            fx_shrink(ref, 0)
            fx_basis(ref, 0, 2)
            return
        }
        let direction = parent.style["fd"] as? String ?? "row"
        let row = direction.hasPrefix("row")
        // A pane of a resizable group: as long as the person made it, or
        // sharing what the sized ones leave.
        if node.part == "pane", parent.part == "resizable" {
            if node.sizeOverride[row ? "w" : "h"] != nil {
                fx_grow(ref, 0)
                fx_shrink(ref, 1)
            } else {
                fx_grow(ref, 1)
                fx_shrink(ref, 1)
                fx_basis(ref, 0, 0)
            }
            fx_overflow(ref, 1)
            return
        }
        if let grow = s["fg"] as? NSNumber { fx_grow(ref, grow.floatValue) }
        if let basis = ModLength(s["fb"]) { let (v, u) = unit(basis); fx_basis(ref, v, u) }
        let scrollsAlong = row ? parent.overflowX == .scroll : parent.overflowY == .scroll
        if scrollsAlong, s["fs"] == nil || node.kind == .text {
            fx_shrink(ref, 0)
        } else if let shrink = s["fs"] as? NSNumber {
            fx_shrink(ref, shrink.floatValue)
        } else if node.kind == .text {
            fx_shrink(ref, node.textStyle.nowrap && !node.textStyle.ellipsis ? 0 : 1)
        } else {
            let cuts = row ? node.overflowX != .visible : node.overflowY != .visible
            fx_shrink(ref, cuts || (row && wraps(node)) ? 1 : 0)
        }
    }

    private static func apply(_ s: [String: Any], node: ModNode, to ref: FXNodeRef) {
        if node.display == "none" { fx_display(ref, 1) }
        if node.display == "flex" {
            switch s["fd"] as? String {
            case "column": fx_direction(ref, 0)
            case "column-reverse": fx_direction(ref, 1)
            case "row-reverse": fx_direction(ref, 3)
            default: fx_direction(ref, 2)
            }
            if let wrap = s["fw"] as? NSNumber { fx_wrap(ref, wrap.int32Value) }
            if let v = (s["jc"] as? String).flatMap({ justifications[$0] }) { fx_justify(ref, v) }
            if let v = (s["ai"] as? String).flatMap({ alignments[$0] }) { fx_align_items(ref, v) }
            if let v = (s["ac"] as? String).flatMap({ alignments[$0] }) { fx_align_content(ref, v) }
            if let v = s["gx"] as? NSNumber { fx_gap(ref, 0, v.floatValue) }
            if let v = s["gy"] as? NSNumber { fx_gap(ref, 1, v.floatValue) }
        } else {
            // A block: its children stack, each as wide as it.
            fx_direction(ref, 0)
            fx_align_items(ref, 4)
        }
        if let v = (s["as"] as? String).flatMap({ alignments[$0] }) { fx_align_self(ref, v) }
        for (which, key) in ["w", "h", "minw", "minh", "maxw", "maxh"].enumerated() {
            if let length = node.sizeOverride[key] ?? ModLength(s[key]) { let (v, u) = unit(length); fx_size(ref, Int32(which), v, u) }
        }
        for (edge, side) in ["l", "t", "r", "b"].enumerated() {
            if let length = ModLength(s["p" + side]) { let (v, u) = unit(length); fx_padding(ref, Int32(edge), v, u) }
            if let length = ModLength(s["m" + side]) { let (v, u) = unit(length); fx_margin(ref, Int32(edge), v, u) }
        }
        for (edge, key) in ["left", "top", "right", "bottom"].enumerated() {
            if let length = ModLength(s[key]) { let (v, u) = unit(length); fx_inset(ref, Int32(edge), v, u) }
        }
        // top, right, bottom, left → Yoga's left, top, right, bottom.
        let b = node.borders
        if b[3] > 0 { fx_border(ref, 0, Float(b[3])) }
        if b[0] > 0 { fx_border(ref, 1, Float(b[0])) }
        if b[1] > 0 { fx_border(ref, 2, Float(b[1])) }
        if b[2] > 0 { fx_border(ref, 3, Float(b[2])) }
        if node.absolute { fx_position_type(ref, 1) }
        if let ratio = s["ar"] as? NSNumber { fx_aspect(ref, ratio.floatValue) }
        if node.scrolls { fx_overflow(ref, 2) } else if node.overflowX == .hidden || node.overflowY == .hidden { fx_overflow(ref, 1) }
    }

    /// A long list's rows, each at its place among the rows not described.
    private static func listRows(_ node: ModNode, ref: FXNodeRef, inherited: ModTextStyle, refs: inout [(ModNode, FXNodeRef)]) {
        let count = (node.raw["n"] as? NSNumber)?.intValue ?? node.children.count
        let from = (node.raw["from"] as? NSNumber)?.intValue ?? 0
        let vertical = node.kind == .vlist
        let sizes = ModListSizes(node.raw["sizes"], count: count, fallback: node.rowEstimate ?? inherited.lineHeightPx + 8)
        node.listSizes = sizes
        // What makes the list as long as all its rows.
        let spacer = fx_new()!
        fx_size(spacer, vertical ? 1 : 0, Float(sizes.total), 0)
        fx_size(spacer, vertical ? 0 : 1, 1, 0)
        fx_shrink(spacer, 0)
        fx_add_child(ref, spacer, 0)
        fx_direction(ref, vertical ? 0 : 2)
        var index: Int32 = 1
        for (offset, child) in node.children.enumerated() {
            let row = from + offset
            let made = make(child, inherited: inherited, parent: node, refs: &refs)
            fx_position_type(made, 1)
            if vertical {
                fx_inset(made, 1, Float(sizes.offset(of: row)), 0)
                fx_inset(made, 0, 0, 0)
                fx_inset(made, 2, 0, 0)
                if sizes.known { fx_size(made, 1, Float(sizes.size(of: row)), 0) }
            } else {
                fx_inset(made, 0, Float(sizes.offset(of: row)), 0)
                fx_inset(made, 1, 0, 0)
                fx_inset(made, 3, 0, 0)
                if sizes.known { fx_size(made, 0, Float(sizes.size(of: row)), 0) }
            }
            fx_add_child(ref, made, index)
            index += 1
        }
    }

    private static let measureLeaf: FXMeasure = { context, width, widthMode, height, heightMode, outWidth, outHeight in
        guard let context, let outWidth, let outHeight else { return }
        // The layout runs on the main thread, and calls back on it.
        nonisolated(unsafe) let held = context
        nonisolated(unsafe) let wide = outWidth
        nonisolated(unsafe) let high = outHeight
        MainActor.assumeIsolated {
            let node = Unmanaged<ModNode>.fromOpaque(held).takeUnretainedValue()
            let limit: CGFloat? = widthMode == 0 ? nil : CGFloat(width)
            var size: CGSize
            switch node.kind {
            case .text:
                size = node.line?.measure(width: limit) ?? .zero
            case .md:
                size = ModMarkdown.size(of: node, width: limit ?? 480)
            case .input:
                size = CGSize(width: limit ?? 160, height: node.textStyle.lineHeightPx)
            case .textarea, .editor:
                let rows = CGFloat(((node.raw["o"] as? [String: Any])?["rows"] as? NSNumber)?.intValue ?? 3)
                size = CGSize(width: limit ?? 240, height: node.textStyle.lineHeightPx * rows)
            default:
                size = .zero
            }
            if widthMode == 1 { size.width = CGFloat(width) } else if widthMode == 2 { size.width = min(size.width, CGFloat(width)) }
            if heightMode == 1 { size.height = CGFloat(height) } else if heightMode == 2, node.kind != .text { size.height = min(size.height, CGFloat(height)) }
            wide.pointee = Float(size.width)
            high.pointee = Float(size.height)
        }
    }
}

/// The rows' sizes of a long list: one for all, or one each.
struct ModListSizes {
    let count: Int
    let uniform: CGFloat?
    /// Where each row starts, and the end of the last.
    let offsets: [CGFloat]
    /// False when the mod gave no sizes (`list`, `uniform_list`).
    let known: Bool

    init(_ any: Any?, count: Int, fallback: CGFloat) {
        self.count = count
        if let n = any as? NSNumber {
            uniform = CGFloat(n.doubleValue)
            offsets = []
            known = true
        } else if let list = any as? [NSNumber], !list.isEmpty {
            uniform = nil
            var running: CGFloat = 0
            var all: [CGFloat] = []
            all.reserveCapacity(count + 1)
            for index in 0..<count {
                all.append(running)
                running += CGFloat(list[min(index, list.count - 1)].doubleValue)
            }
            all.append(running)
            offsets = all
            known = true
        } else {
            uniform = fallback
            offsets = []
            known = false
        }
    }

    var total: CGFloat { uniform.map { $0 * CGFloat(count) } ?? offsets.last ?? 0 }

    func offset(of row: Int) -> CGFloat {
        if let uniform { return uniform * CGFloat(row) }
        return offsets[min(max(row, 0), offsets.count - 1)]
    }

    func size(of row: Int) -> CGFloat {
        if let uniform { return uniform }
        guard row >= 0, row + 1 < offsets.count else { return 0 }
        return offsets[row + 1] - offsets[row]
    }

    /// The rows that show between two offsets, and some beyond each end.
    func rows(from start: CGFloat, to end: CGFloat) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let extra = max(end - start, 200)
        let low = start - extra, high = end + extra
        if let uniform, uniform > 0 {
            let first = max(0, Int((low / uniform).rounded(.down)))
            let last = min(count, Int((high / uniform).rounded(.up)) + 1)
            return min(first, count)..<max(last, min(first, count))
        }
        var first = 0
        while first < count, offsets[first + 1] < low { first += 1 }
        var last = first
        while last < count, offsets[last] < high { last += 1 }
        return first..<last
    }
}
