import AppKit
import Foundation

/// A length as a mod writes it: `240`, `"50%"`, `"auto"`.
nonisolated enum ModLength: Equatable {
    case px(CGFloat)
    case percent(CGFloat)
    case auto

    init?(_ any: Any?) {
        if let n = any as? NSNumber { self = .px(CGFloat(n.doubleValue)); return }
        guard let s = any as? String else { return nil }
        if s == "auto" { self = .auto; return }
        if s.hasSuffix("%"), let n = Double(s.dropLast()) { self = .percent(CGFloat(n)); return }
        guard let n = Double(s) else { return nil }
        self = .px(CGFloat(n))
    }
}

nonisolated enum ModOverflow { case visible, hidden, scroll }

/// What a node is filled with.
nonisolated enum ModFill {
    case color(NSColor)
    /// Stops at 0…1 along a line at `angle` degrees (0: upward, as in CSS).
    case gradient([(NSColor, CGFloat)], angle: CGFloat)
    case slash(NSColor, width: CGFloat, interval: CGFloat)
    case checker(NSColor, size: CGFloat)

    init?(_ any: Any?) {
        if let s = any as? String {
            guard let c = ModColor.parse(s) else { return nil }
            self = .color(c)
            return
        }
        guard let d = any as? [String: Any] else { return nil }
        let opacity = (d["opacity"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1
        func color(_ any: Any?) -> NSColor? {
            guard let c = (any as? String).flatMap(ModColor.parse) else { return nil }
            return opacity == 1 ? c : c.withAlphaComponent(c.alphaComponent * opacity)
        }
        if let c = color(d["solid"]) { self = .color(c); return }
        if let stops = d["gradient"] as? [[String: Any]] {
            let parsed = stops.compactMap { stop -> (NSColor, CGFloat)? in
                guard let c = color(stop["color"]) else { return nil }
                let at = (stop["at"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                return (c, at > 1 ? at / 100 : at)
            }
            guard parsed.count >= 2 else { return nil }
            self = .gradient(parsed, angle: (d["angle"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 180)
            return
        }
        func number(_ key: String, _ fallback: CGFloat) -> CGFloat { (d[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? fallback }
        if let c = color(d["slash"]) { self = .slash(c, width: number("width", 1), interval: number("interval", 6)); return }
        if let c = color(d["checker"]) { self = .checker(c, size: number("size", 8)); return }
        return nil
    }
}

nonisolated enum ModColor {
    nonisolated(unsafe) private static var cache: [String: NSColor] = [:]
    private static let lock = NSLock()

    /// `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`.
    static func parse(_ text: String) -> NSColor? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[text] { return hit }
        guard text.hasPrefix("#") else { return nil }
        var hex = String(text.dropFirst())
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? (value << 8) | 0xff : value
        let color = NSColor(
            srgbRed: CGFloat((rgba >> 24) & 0xff) / 255, green: CGFloat((rgba >> 16) & 0xff) / 255,
            blue: CGFloat((rgba >> 8) & 0xff) / 255, alpha: CGFloat(rgba & 0xff) / 255
        )
        if cache.count > 4096 { cache.removeAll() }
        cache[text] = color
        return color
    }
}

/// The part of a look that can change with the pointer (`hover`, `active`)
/// or the keyboard (`focus`): colors, not sizes.
nonisolated struct ModPaint {
    var fill: ModFill?
    var borderColor: NSColor?
    var textColor: NSColor?
    var opacity: CGFloat?
    var shadow: String?
    var underline: Bool?

    init(_ s: [String: Any]) {
        fill = ModFill(s["bg"])
        borderColor = (s["bc"] as? String).flatMap(ModColor.parse)
        textColor = (s["tc"] as? String).flatMap(ModColor.parse)
        opacity = (s["op"] as? NSNumber).map { CGFloat($0.doubleValue) }
        shadow = s["sh"] as? String
        underline = (s["ul"] as? NSNumber).map { $0.intValue != 0 }
    }

    /// This look with another's set fields over it.
    func merged(_ over: ModPaint) -> ModPaint {
        var out = self
        if let v = over.fill { out.fill = v }
        if let v = over.borderColor { out.borderColor = v }
        if let v = over.textColor { out.textColor = v }
        if let v = over.opacity { out.opacity = v }
        if let v = over.shadow { out.shadow = v }
        if let v = over.underline { out.underline = v }
        return out
    }
}

/// Text settings a node hands down to the text under it.
nonisolated struct ModTextStyle: Equatable {
    var size: CGFloat = 16
    var weight: Int = 400
    var family: String?
    var italic = false
    /// A length, or a multiple of the size (negative: `-1.5` is 1.5×).
    var lineHeight: CGFloat = -1.618
    var align: NSTextAlignment = .left
    var nowrap = false
    var ellipsis = false
    var clamp = 0
    var strike = false
    /// How thick the line under the text is; nil is the font's own.
    var underlineWidth: CGFloat?
    var wavy = false
    /// Painted behind the text itself (`text_bg`).
    var background: NSColor?

    var lineHeightPx: CGFloat { lineHeight < 0 ? (-lineHeight * size).rounded() : lineHeight }

    mutating func apply(_ s: [String: Any]) {
        if let v = s["ts"] as? NSNumber { size = CGFloat(v.doubleValue) }
        if let v = s["wt"] as? NSNumber { weight = v.intValue }
        if let v = s["ff"] as? String { family = v }
        if let v = s["it"] as? NSNumber { italic = v.intValue != 0 }
        if let v = s["lh"] {
            if let n = v as? NSNumber { lineHeight = CGFloat(n.doubleValue) }
            else if let t = v as? String, t.hasPrefix("x"), let n = Double(t.dropFirst()) { lineHeight = -CGFloat(n) }
            else if let t = v as? String, t.hasSuffix("%"), let n = Double(t.dropLast()) { lineHeight = -CGFloat(n / 100) }
        }
        if let v = s["ta"] as? String { align = v == "center" ? .center : v == "right" ? .right : .left }
        if let v = s["ws"] as? String { nowrap = v == "nowrap" }
        if let v = s["el"] as? NSNumber { ellipsis = v.intValue != 0 }
        if let v = s["lc"] as? NSNumber { clamp = v.intValue }
        if let v = s["st"] as? NSNumber { strike = v.intValue != 0 }
        if let v = s["ulw"] as? NSNumber { underlineWidth = CGFloat(v.doubleValue) }
        if let v = s["uls"] as? String { wavy = v == "wavy" }
        if let v = (s["tbg"] as? String).flatMap(ModColor.parse) { background = v }
    }
}

/// A surface that opens from its trigger: a `Popup`, a `Popover`, a
/// `HoverCard`. The node that holds it is what the surface is pinned to.
final class ModPopup {
    enum Kind { case popup, popover, hoverCard }

    let kind: Kind
    /// What the surface shows. Nil: shut, or nothing to show.
    let content: ModNode?
    /// Which corner of the surface is pinned to its trigger.
    let anchor: String
    /// `open(…)`, where the script holds the state itself.
    let controlled: Bool?
    let defaultOpen: Bool
    /// A press outside shuts it.
    let closable: Bool
    /// The pointer button that opens a popover.
    let button: String
    /// Seconds the pointer rests on a hover card's trigger before it
    /// opens, and stays away before it shuts.
    let openDelay: TimeInterval
    let closeDelay: TimeInterval
    /// `on_open_change`.
    let openHandler: Int?
    /// What takes the keyboard when a popover opens (`track_focus`).
    let focusHandle: String?

    // Found when the surface is placed.
    /// The content's box, in the view's space.
    var rect = CGRect.zero

    init(kind: Kind, raw: [String: Any], content: ModNode?) {
        self.kind = kind
        self.content = content
        let options = raw["pop"] as? [String: Any] ?? [:]
        anchor = options["anchor"] as? String ?? (kind == .hoverCard ? "top_center" : "top_left")
        controlled = kind == .popover ? (raw["st"] as? [String: Bool])?["open"] : nil
        defaultOpen = options["default_open"] as? Bool ?? false
        closable = options["closable"] as? Bool ?? true
        button = options["button"] as? String ?? "left"
        openDelay = ((options["open_delay"] as? NSNumber)?.doubleValue ?? 600) / 1000
        closeDelay = ((options["close_delay"] as? NSNumber)?.doubleValue ?? 300) / 1000
        openHandler = (raw["hs"] as? [String: Any])?["open"] as? Int
        focusHandle = raw["fh"] as? String
    }
}

/// `loop`: a property that swings between two values, forever.
nonisolated struct ModLoop {
    var property: String
    var from: CGFloat
    var to: CGFloat
    /// Seconds there and back.
    var period: TimeInterval
    var easing: String
}

/// `transition` or `spring`: how a property goes to a new value.
nonisolated struct ModMotion {
    var spring = false
    var duration: TimeInterval = 0
    var delay: TimeInterval = 0
    var easing = "ease-in-out"
    var response: TimeInterval = 0.3
    var damping: CGFloat = 1
    var epsilon: CGFloat = 0

    init(_ raw: [String: Any]) {
        func number(_ key: String) -> Double? { (raw[key] as? NSNumber)?.doubleValue }
        spring = raw["spring"] != nil
        duration = (number("ms") ?? 0) / 1000
        delay = (number("delay") ?? 0) / 1000
        easing = raw["easing"] as? String ?? "ease-in-out"
        response = max(0.05, (number("response") ?? 300) / 1000)
        damping = CGFloat(number("damping") ?? 1)
        epsilon = CGFloat(number("epsilon") ?? 0)
    }
}

/// One element of a mod's panel, as its script described it.
final class ModNode {
    enum Kind: String {
        case div, text, svg, img, input, textarea, editor, md, path, vlist, hlist, frag
    }

    let kind: Kind
    var id: String?
    /// Stable across redraws: the ids down to this node, or its place where
    /// it has none. What a click, a hover, a scroll position hold on to.
    var key = ""
    let style: [String: Any]
    var children: [ModNode] = []
    weak var parent: ModNode?
    var text: String?
    var handlers: [String: Int] = [:]
    var actions: [String: Int] = [:]
    var tooltip: String?
    var source: String?
    var focusHandle: String?
    var scrollHandle: String?
    var keyContext: String?
    var part: String?
    var state: [String: Bool] = [:]
    var selectable = false
    var raw: [String: Any]
    /// `cx.bind_keys(…)`, on the root.
    var bindings: [[String: Any]] = []
    /// `.group("row")`: what `group_hover("row", …)` under it answers to.
    var group: String?
    var groupHoverName: String?
    /// Milliseconds a turn takes (`spin`).
    var spin: Double?
    var listSizes: ModListSizes?
    /// A row's size as last measured, for a list whose mod gave none.
    var rowEstimate: CGFloat?
    /// The field's state in the script (`InputState`…).
    var field: String?
    /// The surface this node opens (`Popup`, `Popover`, `HoverCard`).
    var popup: ModPopup?
    /// Where Tab lands (`tab_index`, `tab_stop`).
    var tabIndex: Int?
    var tabStop: Bool?
    /// A `Select`'s list: what takes the keyboard while it is open.
    var contentFocus: String?
    /// A `Link`'s page.
    var url: String?
    /// Files this element hands over when dragged (`drag_paths`), and the
    /// machine they are on (nil: this Mac).
    var dragPaths: [String] = []
    var dragMachine: String?
    /// What a screen reader is told: `role`, `label`, `value`…
    var access: [String: Any] = [:]
    /// The texts shown in turn (`frames`), and how long each stays.
    var frames: [String] = []
    var frameInterval: TimeInterval = 0.1
    var loops: [ModLoop] = []
    /// `transition` and `spring`, by property.
    var motions: [String: ModMotion] = [:]
    /// A slider part's state in the script.
    var slider: String?
    /// A `NumberInput`'s state, on its frame and its two step buttons.
    var number: String?
    /// On a step button: `increment` or `decrement`.
    var step: String?
    /// A resizable group's pane: `size`, `min`, `max`.
    var pane: [String: Any]?
    /// How a slider's filled part looks (`range_style`).
    var range: ModPaint?
    var rangeRadii: [CGFloat] = [0, 0, 0, 0]
    /// The filled part of a slider's indicator, in the indicator's own
    /// space. Found by the view from the slider's value.
    var fill: CGRect?
    /// A row's key in its list (`get_key`), for `on_item_click`.
    var itemKey: Any?

    // Set by the view while something moves: a transition, a loop, a
    // pane's divider. They win over what the script wrote.
    var sizeOverride: [String: ModLength] = [:]
    var opacityOverride: CGFloat?
    /// Where the layout put the node, before a moving `left` or `top`.
    var restOrigin = CGPoint.zero
    var shift = CGPoint.zero
    /// Where its slider's value puts a thumb, from where the layout rests it.
    var slide = CGPoint.zero

    // Read once from `style`.
    let paint: ModPaint
    let hover: ModPaint?
    let active: ModPaint?
    let focus: ModPaint?
    let groupHover: ModPaint?
    var display: String
    let absolute: Bool
    var overflowX = ModOverflow.visible
    var overflowY = ModOverflow.visible
    var radii: [CGFloat] = [0, 0, 0, 0]          // top-left, top-right, bottom-right, bottom-left
    var borders: [CGFloat] = [0, 0, 0, 0]        // top, right, bottom, left
    var dashed = false
    var visible = true
    var blocksMouse = false
    var cursor: String?

    // Found by the layout.
    /// In its parent's space.
    var frame = CGRect.zero
    var textStyle = ModTextStyle()
    /// The text as it will be drawn, measured with its font.
    var line: ModTextLayout?
    /// For a node that scrolls: how big what it holds is.
    var contentSize = CGSize.zero

    var isInteractive: Bool {
        !handlers.isEmpty || !actions.isEmpty || hover != nil || active != nil || tooltip != nil || cursor != nil
            || focusHandle != nil || blocksMouse || kind == .input || kind == .textarea || kind == .editor
            || popup != nil || isControl || !dragPaths.isEmpty || part == "slider-track" || part == "pane"
            || (itemKey != nil && (parent?.handlers["item"] != nil || parent?.handlers["item2"] != nil))
    }

    /// Parts a press or a key acts on by itself: a `Checkbox` reports its
    /// change, a `Link` opens its page.
    static let controls: Set<String> = ["button", "link", "checkbox", "switch", "radio", "toggle", "accordion-trigger", "slider-thumb"]

    var actsOnPress: Bool { part.map(Self.controls.contains) ?? false || step != nil }

    /// Such a part, or a popover's trigger.
    var isControl: Bool { actsOnPress || popup?.kind == .popover }

    /// The nearest node around this one that is such a part.
    func enclosing(part wanted: String) -> ModNode? {
        var at: ModNode? = self
        while let node = at {
            if node.part == wanted { return node }
            at = node.parent
        }
        return nil
    }

    /// Off: by its own `disabled`, or its accordion item's.
    var isDisabled: Bool {
        if state["disabled"] == true { return true }
        if part == "accordion-trigger", enclosing(part: "accordion-item")?.state["disabled"] == true { return true }
        return false
    }

    /// The root of a surface's content: its parent is the node that opens it.
    var isSurfaceRoot: Bool { parent?.popup?.content === self }

    var scrolls: Bool { overflowX == .scroll || overflowY == .scroll || kind == .vlist || kind == .hlist }

    private init(kind: Kind, raw: [String: Any]) {
        self.kind = kind
        self.raw = raw
        let s = raw["s"] as? [String: Any] ?? [:]
        style = s
        paint = ModPaint(s)
        hover = (s["hover"] as? [String: Any]).map(ModPaint.init)
        active = (s["active"] as? [String: Any]).map(ModPaint.init)
        focus = (s["focus"] as? [String: Any]).map(ModPaint.init)
        groupHover = (s["ghover"] as? [String: Any]).map(ModPaint.init)
        display = s["d"] as? String ?? "block"
        absolute = s["pos"] as? String == "absolute"
        id = raw["i"] as? String
        func overflow(_ any: Any?) -> ModOverflow? {
            switch any as? String {
            case "hidden": .hidden
            case "scroll": .scroll
            default: nil
            }
        }
        if let both = overflow(s["ov"]) { overflowX = both; overflowY = both }
        if let x = overflow(s["ovx"]) { overflowX = x }
        if let y = overflow(s["ovy"]) { overflowY = y }
        func number(_ key: String) -> CGFloat { (s[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0 }
        radii = [number("rtl"), number("rtr"), number("rbr"), number("rbl")]
        borders = [number("bt"), number("br"), number("bb"), number("bl")]
        dashed = s["bs"] as? String == "dashed"
        if let v = s["vis"] as? NSNumber { visible = v.intValue != 0 }
        blocksMouse = s["block"] != nil
        cursor = s["cur"] as? String
        if let h = raw["hs"] as? [String: Any] {
            for (name, value) in h {
                if let index = value as? Int { handlers[name] = index }
                else if name == "actions", let table = value as? [String: Int] { actions = table }
            }
        }
        tooltip = raw["tip"] as? String
        source = raw["src"] as? String
        focusHandle = raw["fh"] as? String
        scrollHandle = raw["sc"] as? String
        keyContext = raw["kc"] as? String
        part = raw["part"] as? String
        if let st = raw["st"] as? [String: Bool] { state = st }
        selectable = (raw["sel"] as? NSNumber)?.intValue == 1
        text = raw["text"] as? String
        group = s["group"] as? String
        groupHoverName = s["ghoverg"] as? String
        let anim = raw["anim"] as? [String: Any] ?? [:]
        spin = (anim["spin"] as? NSNumber)?.doubleValue
        frames = anim["frames"] as? [String] ?? []
        frameInterval = max(0.016, ((anim["ms"] as? NSNumber)?.doubleValue ?? 100) / 1000)
        for item in raw["loops"] as? [[String: Any]] ?? [] {
            guard let property = item["p"] as? String, let from = item["from"] as? NSNumber, let to = item["to"] as? NSNumber else { continue }
            let period = max(0.1, ((item["period"] as? NSNumber)?.doubleValue ?? 1000) / 1000)
            loops.append(ModLoop(property: property, from: CGFloat(from.doubleValue), to: CGFloat(to.doubleValue), period: period,
                                 easing: item["easing"] as? String ?? "ease-in-out"))
        }
        for (property, spec) in raw["mo"] as? [String: Any] ?? [:] {
            if let spec = spec as? [String: Any] { motions[property] = ModMotion(spec) }
        }
        field = raw["f"] as? String
        tabIndex = (raw["ti"] as? NSNumber)?.intValue
        tabStop = (raw["tstop"] as? NSNumber).map { $0.intValue != 0 }
        contentFocus = raw["cfh"] as? String
        url = raw["url"] as? String
        if let drag = raw["drag"] as? [String: Any] {
            dragPaths = drag["paths"] as? [String] ?? []
            dragMachine = drag["on"] as? String
        }
        access = raw["a"] as? [String: Any] ?? [:]
        slider = raw["sl"] as? String
        self.number = raw["num"] as? String
        pane = raw["pane"] as? [String: Any]
        if let look = s["range"] as? [String: Any] {
            range = ModPaint(look)
            func corner(_ key: String) -> CGFloat { (look[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0 }
            rangeRadii = [corner("rtl"), corner("rtr"), corner("rbr"), corner("rbl")]
        }
    }

    /// A plain box around nodes made here, not by the script.
    private convenience init(box style: [String: Any], holding children: [ModNode]) {
        self.init(kind: .div, raw: ["k": "div", "s": style])
        self.children = children
        for child in children { child.parent = self }
    }

    private init(text: String) {
        kind = .text
        raw = [:]
        style = [:]
        paint = ModPaint([:])
        hover = nil
        active = nil
        focus = nil
        groupHover = nil
        display = "block"
        absolute = false
        self.text = text
    }

    /// The tree from what the script wrote.
    static func build(_ any: Any) -> ModNode? {
        guard let root = make(any) else { return nil }
        root.key = root.id ?? "root"
        root.assignKeys()
        return root
    }

    /// Whether a picture's file is there: an `Avatar` shows its fallback
    /// when it isn't. Set by the view before it asks for a tree.
    static var pictureExists: (String) -> Bool = { _ in true }

    private static func make(_ any: Any) -> ModNode? {
        if let s = any as? String { return ModNode(text: s) }
        guard let d = any as? [String: Any], let k = d["k"] as? String else { return nil }
        guard let kind = Kind(rawValue: k) else { return nil }
        let part = d["part"] as? String
        let slots = d["slots"] as? [String: Any] ?? [:]
        func slot(_ name: String) -> ModNode? { slots[name].flatMap(make) }
        // Something a surface can be pinned to: a text or a list of
        // elements gets a box.
        func boxed(_ made: ModNode?) -> ModNode? {
            guard let made else { return nil }
            if made.kind == .frag { return ModNode(box: [:], holding: made.children) }
            return made.kind == .text ? ModNode(box: [:], holding: [made]) : made
        }

        // A popover and a hover card draw nothing of their own: they are
        // their trigger, which opens the surface. Without one, nothing.
        if part == "popover" || part == "hovercard" {
            guard let trigger = boxed(slot("trigger")) else { return nil }
            let surface = ModPopup(kind: part == "popover" ? .popover : .hoverCard, raw: d, content: boxed(slot("content")))
            surface.content?.parent = trigger
            trigger.popup = surface
            return trigger
        }

        let node = ModNode(kind: kind, raw: d)
        var children: [ModNode] = []
        // An array used as a child: its items, in place.
        func add(_ made: ModNode?) {
            guard let made else { return }
            if made.kind == .frag { children.append(contentsOf: made.children) } else { children.append(made) }
        }
        let open = node.state["open"] == true
        switch part {
        case "popup":
            add(slot("trigger"))
            let surface = ModPopup(kind: .popup, raw: d, content: boxed(slot("content")))
            surface.content?.parent = node
            node.popup = surface
        case "avatar":
            // The picture, or what stands in for it: never both.
            let image = slot("image")
            if let image, let source = image.source, pictureExists(source) { add(image) } else { add(slot("fallback")) }
        case "number":
            let state = d["num"] as? String
            func button(_ name: String, _ action: String) -> ModNode? {
                guard let made = boxed(slot(name)) else { return nil }
                made.number = state
                made.step = action
                return made
            }
            let editor = slot("input") ?? (d["editor"].flatMap(make))
            let less = button("decrement_button", "decrement"), more = button("increment_button", "increment")
            if node.state["controls_right"] == true {
                add(editor)
                add(ModNode(box: ["d": "flex", "fd": "column"], holding: [more, less].compactMap { $0 }))
            } else {
                add(less)
                add(editor)
                add(more)
            }
        default:
            add(slot("header"))
        }
        for child in d["c"] as? [Any] ?? [] { add(make(child)) }
        switch part {
        case "collapsible":
            // Its content is there only while it is open.
            if open { add(slot("content")) }
        case "accordion-item":
            if let panel = slot("panel") {
                if open { add(panel) } else if panel.state["keep_mounted"] == true {
                    // Kept, out of sight: what it holds stays as it was.
                    panel.display = "none"
                    add(panel)
                }
            }
        case "resizable":
            // What isn't a pane gets one.
            children = children.map { child in
                if child.part == "pane" { return child }
                let pane = ModNode(box: [:], holding: [child])
                pane.part = "pane"
                pane.pane = [:]
                return pane
            }
            for pane in children where (pane.pane?["hidden"] as? NSNumber)?.intValue == 1 { pane.display = "none" }
        default:
            break
        }
        add(slot("footer"))
        // `frames` with nothing in the element: the frames are its text.
        if !node.frames.isEmpty, children.isEmpty { children.append(ModNode(text: node.frames[0])) }
        // A row of a long list knows its key.
        if let keys = d["keys"] as? [Any], keys.count == children.count {
            for (index, child) in children.enumerated() { child.itemKey = keys[index] }
        }
        node.children = children
        for child in node.children { child.parent = node }
        return node
    }

    private func assignKeys() {
        var seen: [String: Int] = [:]
        for (index, child) in children.enumerated() {
            var name = child.id ?? "#\(index)"
            // Two children with one id still get two keys.
            if let count = seen[name] { seen[name] = count + 1; name += "~\(count)" } else { seen[name] = 1 }
            child.key = key + "/" + name
            child.assignKeys()
        }
        if let content = popup?.content {
            content.key = key + "/@surface"
            content.assignKeys()
        }
    }

    /// This node and what is under it, parents first, with the content of
    /// the surfaces `open` says are showing.
    func walk(open: (ModNode) -> Bool, _ visit: (ModNode) -> Void) {
        visit(self)
        for child in children { child.walk(open: open, visit) }
        if let content = popup?.content, open(self) { content.walk(open: open, visit) }
    }

    /// Every node, parents first.
    func walk(_ visit: (ModNode) -> Void) {
        visit(self)
        for child in children { child.walk(visit) }
    }

    var count: Int { children.reduce(1) { $0 + $1.count } }
}
