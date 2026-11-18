import AppKit
import Foundation

/// One element of a mod's panel as VoiceOver meets it: a part, an element
/// the mod gave a role or a name, something to press, or a run of text.
/// It holds no node: the panel is described anew at each change, so it
/// looks its node up by key each time it is asked.
///
/// AppKit declares these calls free of any actor and makes them on the main
/// thread; each answers from there.
nonisolated final class ModAccessElement: NSAccessibilityElement, @unchecked Sendable {
    private struct Carried<T>: @unchecked Sendable { var value: T }

    nonisolated(unsafe) weak var view: ModView?
    let key: String

    init(view: ModView, key: String) {
        self.view = view
        self.key = key
        super.init()
    }

    /// Answers on the main actor, with the element's node when it still shows.
    private func answer<T>(_ fallback: T, _ work: @MainActor (ModView, ModNode) -> T) -> T {
        let fallback = Carried(value: fallback), me = Carried(value: self)
        return withoutActuallyEscaping(work) { work in
            let work = Carried(value: work)
            return MainActor.assumeIsolated {
                guard let view = me.value.view, let node = view.accessNodes[me.value.key] else { return fallback }
                return Carried(value: work.value(view, node))
            }.value
        }
    }

    override func accessibilityParent() -> Any? {
        // A surface's elements belong to its own layer.
        answer(view as Any?) { view, node in view.accessHost(of: node) }
    }

    override func isAccessibilityElement() -> Bool { answer(false) { _, _ in true } }
    override func accessibilityIdentifier() -> String { answer("") { _, node in node.id ?? "" } }

    override func accessibilityRole() -> NSAccessibility.Role? { answer(.unknown) { _, node in ModAccess.role(node) } }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { answer(nil) { _, node in ModAccess.subrole(node) } }
    override func accessibilityLabel() -> String? { answer(nil) { _, node in ModAccess.label(node) } }
    override func accessibilityValue() -> Any? { answer(nil) { view, node in ModAccess.value(of: node, in: view) } }

    override func accessibilityFrame() -> NSRect {
        answer(.zero) { view, node in
            guard let window = view.window, let rect = view.rect(of: node) else { return .zero }
            return window.convertToScreen(view.convert(rect, to: nil))
        }
    }

    override func isAccessibilityEnabled() -> Bool { answer(false) { _, node in !node.isDisabled } }

    override func isAccessibilityFocused() -> Bool {
        answer(false) { view, node in view.focusedNode() === node && view.holdsKeyboard }
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        guard focused else { return }
        answer(()) { view, node in view.focus(node: node, byKey: true) }
    }

    override func isAccessibilitySelected() -> Bool { answer(false) { _, node in node.access["selected"] as? Bool == true } }
    override func isAccessibilityExpanded() -> Bool { answer(false) { view, node in ModAccess.expanded(node, in: view) == true } }

    override func accessibilityPerformPress() -> Bool {
        answer(false) { view, node in !node.isDisabled && view.accessPress(node) }
    }

    override func accessibilityPerformIncrement() -> Bool {
        answer(false) { view, node in node.part == "slider-thumb" && view.sliderKey("right", on: node) }
    }

    override func accessibilityPerformDecrement() -> Bool {
        answer(false) { view, node in node.part == "slider-thumb" && view.sliderKey("left", on: node) }
    }
}

/// How a node reads: its role, its name, its value.
enum ModAccess {
    /// The roles a mod names (`role("button")`), as the Mac calls them.
    private static let roles: [String: NSAccessibility.Role] = [
        "button": .button, "checkbox": .checkBox, "switch": .checkBox, "radio": .radioButton, "radio_button": .radioButton,
        "link": .link, "slider": .slider, "tab": .radioButton, "tablist": .tabGroup, "tab_list": .tabGroup, "tabpanel": .group,
        "list": .list, "listbox": .list, "list_box": .list, "listitem": .group, "list_item": .group, "option": .staticText,
        "group": .group, "region": .group, "toolbar": .toolbar, "menu": .menu, "menuitem": .menuItem, "menu_item": .menuItem,
        "dialog": .group, "heading": .staticText, "image": .image, "img": .image, "label": .staticText, "text": .staticText,
        "status": .staticText, "alert": .staticText, "progressbar": .progressIndicator, "progress_indicator": .progressIndicator,
        "meter": .levelIndicator, "combobox": .comboBox, "combo_box": .comboBox, "textbox": .textField, "text_input": .textField,
        "table": .table, "row": .row, "cell": .cell, "columnheader": .cell, "tree": .outline, "treeitem": .row,
        "separator": .splitter, "scrollbar": .scrollBar, "tooltip": .helpTag, "disclosure": .disclosureTriangle,
    ]

    private static let parts: [String: NSAccessibility.Role] = [
        "button": .button, "link": .link, "checkbox": .checkBox, "switch": .checkBox, "radio": .radioButton, "toggle": .checkBox,
        "accordion-trigger": .button, "slider-thumb": .slider, "progress": .progressIndicator, "select": .comboBox, "combobox": .comboBox,
    ]

    /// Whether VoiceOver stops on this node.
    static func isElement(_ node: ModNode) -> Bool {
        if node.kind == .text { return false }
        if node.kind == .input || node.kind == .textarea || node.kind == .editor { return false }
        if node.access["role"] != nil || node.access["label"] != nil { return true }
        if node.isControl { return true }
        if let part = node.part, parts[part] != nil { return true }
        // Something to press that the mod drew itself.
        return node.handlers["click"] != nil
    }

    private static let holders: Set<String> = [
        "group", "region", "list", "listbox", "list_box", "tablist", "tab_list", "tabpanel", "toolbar", "table", "tree", "menu", "dialog",
    ]

    /// Whether VoiceOver goes on into what the node holds.
    static func holdsOthers(_ node: ModNode) -> Bool {
        if let named = (node.access["role"] as? String)?.lowercased() { return holders.contains(named) }
        return role(node) == .group || node.part == "select" || node.part == "combobox"
    }

    static func role(_ node: ModNode) -> NSAccessibility.Role {
        if let named = node.access["role"] as? String, let role = roles[named.lowercased()] { return role }
        if let part = node.part, let role = parts[part] { return role }
        if node.popup?.kind == .popover { return .popUpButton }
        if node.kind == .text { return .staticText }
        if node.handlers["click"] != nil { return .button }
        if node.kind == .img || node.kind == .svg { return .image }
        return .group
    }

    static func subrole(_ node: ModNode) -> NSAccessibility.Subrole? {
        let named = (node.access["role"] as? String)?.lowercased()
        if named == "switch" || (named == nil && node.part == "switch") { return .switch }
        if named == nil, node.part == "toggle" { return .toggle }
        if named == "tab" { return .tabButtonSubrole }
        if named == "dialog" { return .dialog }
        return nil
    }

    /// The element at a point of the screen, in a panel or a surface's
    /// layer. AppKit asks from the main thread, free of any actor.
    nonisolated static func hit(_ point: NSPoint, in host: NSView) -> Any? {
        nonisolated(unsafe) var found: Any?
        MainActor.assumeIsolated {
            let owner = host as? ModView ?? (host as? ModSurfaceView)?.owner
            found = owner?.accessElement(at: point, in: host)
        }
        return found
    }

    /// Every text under a node, in order.
    static func text(under node: ModNode) -> String {
        var words: [String] = []
        node.walk { if $0.kind == .text, let text = $0.text, !text.isEmpty, $0.display != "none" { words.append(text) } }
        return words.joined(separator: " ")
    }

    static func label(_ node: ModNode) -> String? {
        if let given = node.access["label"] as? String, !given.isEmpty { return given }
        if node.kind == .text { return node.text }
        let read = text(under: node)
        if !read.isEmpty { return read }
        return node.tooltip
    }

    static func expanded(_ node: ModNode, in view: ModView) -> Bool? {
        if let told = node.access["expanded"] as? Bool { return told }
        if node.popup?.kind == .popover { return view.isOpen(node) }
        if node.part == "accordion-trigger" { return node.enclosing(part: "accordion-item")?.state["open"] ?? node.state["open"] }
        if node.part == "select" || node.part == "combobox" { return node.state["open"] }
        return nil
    }

    static func value(of node: ModNode, in view: ModView) -> Any? {
        if let checked = node.access["checked"] as? Bool { return NSNumber(value: checked ? 1 : 0) }
        switch node.part {
        case "checkbox", "switch", "radio": return NSNumber(value: node.state["checked"] == true ? 1 : 0)
        case "toggle": return NSNumber(value: node.state["pressed"] == true ? 1 : 0)
        case "slider-thumb":
            let values = view.sliderValues(of: node)
            return NSNumber(value: node.state["start"] == true ? values[0] : values[values.count - 1])
        default: break
        }
        if let value = node.access["value"] as? NSNumber { return value }
        if let position = node.access["position"] as? [NSNumber], position.count == 2 { return "\(position[0]) of \(position[1])" }
        return nil
    }
}

extension ModView {
    /// Describes the panel for VoiceOver, once per change of it: the
    /// elements in reading order, and what holds each.
    private func describe() {
        guard accessOrder == nil else { return }
        var order: [String] = [], nodes: [String: ModNode] = [:]
        func visit(_ node: ModNode, named: Bool) {
            guard node.display != "none", node.visible else { return }
            var named = named
            if node.kind == .text {
                // Text inside something with a name is read with it.
                guard !named, let text = node.text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                order.append(node.key)
                nodes[node.key] = node
                return
            }
            if ModAccess.isElement(node) {
                order.append(node.key)
                nodes[node.key] = node
                // A list or a group still shows what it holds; a button or
                // a row reads as one, with its text for a name.
                if !ModAccess.holdsOthers(node) { named = true }
            }
            for child in node.children { visit(child, named: named) }
            if let content = node.popup?.content, isOpen(node) { visit(content, named: false) }
        }
        if let tree { visit(tree, named: false) }
        accessOrder = order
        accessNodes = nodes
        accessCache = accessCache.filter { nodes[$0.key] != nil }
    }

    /// The panel changed: what VoiceOver knows of it is out of date.
    func accessChanged() {
        guard accessOrder != nil else { return }
        accessOrder = nil
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// The layer that shows a node: a surface's own, or the panel.
    func accessHost(of node: ModNode) -> NSView {
        var at: ModNode? = node
        while let current = at {
            if current.isSurfaceRoot, let owner = current.parent, let layer = surfacePanels[owner.key]?.contentView { return layer }
            at = current.parent
        }
        return self
    }

    /// The elements one layer holds, in reading order.
    func accessElements(in host: NSView) -> [Any] {
        describe()
        var out: [Any] = []
        for key in accessOrder ?? [] {
            guard let node = accessNodes[key], accessHost(of: node) === host else { continue }
            let element = accessCache[key] ?? ModAccessElement(view: self, key: key)
            accessCache[key] = element
            out.append(element)
        }
        // The fields are real ones: they speak for themselves.
        out.append(contentsOf: host.subviews.filter { $0 is NSTextField && !$0.isHidden })
        return out
    }

    /// The element at a point of the screen.
    func accessElement(at point: NSPoint, in host: NSView) -> Any? {
        for case let element as ModAccessElement in accessElements(in: host).reversed() where element.accessibilityFrame().contains(point) {
            return element
        }
        return nil
    }

    /// VoiceOver's press: what a click there would do.
    func accessPress(_ node: ModNode) -> Bool {
        copy.runtime.lastGesture = Date()
        var did = false
        if let handler = node.handlers["click"] {
            copy.dispatch(handler, payload: ["click_count": 1, "modifiers": modifiers([]), "position": ["x": 0, "y": 0]], gesture: true)
            did = true
        }
        if node.actsOnPress { activate(node); did = true }
        if node.popup?.kind == .popover { toggle(node); did = true }
        return did
    }

    // MARK: The panel itself

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? { accessTitle ?? copy.runtime.name }
    public override func accessibilityChildren() -> [Any]? { accessElements(in: self) }

    nonisolated public override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        ModAccess.hit(point, in: self) ?? super.accessibilityHitTest(point)
    }

    /// For tests: each element as `role: name [value]`, in reading order.
    public func accessReport() -> [String] {
        var out: [String] = []
        var hosts: [NSView] = [self]
        hosts.append(contentsOf: surfacePanels.values.compactMap(\.contentView))
        for host in hosts {
            for case let element as ModAccessElement in accessElements(in: host) {
                var line = (element.accessibilityRole()?.rawValue ?? "?").replacingOccurrences(of: "AX", with: "") + ": " + (element.accessibilityLabel() ?? "")
                if let value = element.accessibilityValue() { line += " [\(value)]" }
                if !element.isAccessibilityEnabled() { line += " (off)" }
                out.append(line)
            }
        }
        return out
    }

    /// For tests: VoiceOver's press on the element with this name.
    @discardableResult
    public func accessPress(named name: String) -> Bool {
        describe()
        for key in accessOrder ?? [] {
            guard let node = accessNodes[key], node.kind != .text, ModAccess.label(node) == name else { continue }
            let element = accessCache[key] ?? ModAccessElement(view: self, key: key)
            return element.accessibilityPerformPress()
        }
        return false
    }
}

extension ModSurfaceView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? { owner?.accessElements(in: self) }
    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        ModAccess.hit(point, in: self) ?? super.accessibilityHitTest(point)
    }
}
