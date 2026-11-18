import AppKit
import HerdrKit
import ModKit
import SwiftUI

/// One copy of a mod, drawn by ModKit.
struct ModBlock: NSViewRepresentable {
    let name: String
    var props: [String: Any] = [:]
    /// Where it lives: its own saved state.
    let slot: String
    var takesKeyboard = false
    var onHeight: ((CGFloat) -> Void)?
    /// False while a layout keeps it out of sight.
    var shown = true
    /// In the mods' sidebar: on its surface, without a box of its own.
    var flush = false
    /// Changes when the mod's files do: the view starts over.
    let revision: Int

    final class Holder: NSView {
        var view: ModView?
        var revision = -1
        /// Why the mod didn't load: shown in its place, so a mistake in a
        /// mod's file isn't a blank panel.
        var problem: String? {
            didSet {
                guard problem != oldValue else { return }
                note?.removeFromSuperview()
                note = nil
                guard let problem else { return }
                let label = NSTextField(wrappingLabelWithString: "This mod didn't load.\n\n" + problem)
                label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                label.textColor = .secondaryLabelColor
                label.isSelectable = true
                addSubview(label)
                note = label
                needsLayout = true
            }
        }
        private var note: NSTextField?

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            view?.frame = bounds
            note?.frame = bounds.insetBy(dx: 12, dy: 12)
        }

        func close() {
            view?.copy.close()
            view?.removeFromSuperview()
            view = nil
        }

        isolated deinit { view?.copy.close() }
    }

    func makeNSView(context: Context) -> Holder { Holder() }

    func updateNSView(_ holder: Holder, context: Context) {
        if holder.revision != revision || holder.view == nil {
            holder.revision = revision
            holder.close()
            do {
                let copy = try Mods.shared.runtime(for: name).makeCopy(props: props, slot: slot)
                let view = ModView(copy: copy)
                view.baseSize = 13
                view.takesKeyboard = takesKeyboard
                view.onNaturalHeight = onHeight
                view.isShown = shown
                view.isFlush = flush
                view.frame = holder.bounds
                holder.addSubview(view)
                holder.view = view
                holder.problem = nil
            } catch {
                holder.problem = "\(error)"
            }
        } else if let view = holder.view {
            if !NSDictionary(dictionary: view.copy.props).isEqual(to: props) { view.copy.setProps(props) }
            if view.isShown != shown { view.isShown = shown }
            view.isFlush = flush
        }
    }

    static func dismantleNSView(_ holder: Holder, coordinator: ()) { holder.close() }
}

/// A mod where a layout or an overlay puts it: the mod itself once the
/// person allowed it, else what it asks for.
struct ModPanel: View {
    let name: String
    var props: [String: Any] = [:]
    let slot: String
    var takesKeyboard = false
    var onHeight: ((CGFloat) -> Void)?
    var shown = true
    var flush = false

    var body: some View {
        let mods = Mods.shared
        if name == "changes" {
            // Swiftr's own, in the place herdr-app's panel of that name has.
            ChangesPanel(shown: shown)
        } else if let entry = mods.entry(name) {
            if entry.allowed {
                ModBlock(name: name, props: props, slot: slot, takesKeyboard: takesKeyboard, onHeight: onHeight, shown: shown, flush: flush, revision: mods.reloads(of: name))
            } else {
                ModConsent(entry: entry)
            }
        } else if WindowLayout.missing.contains(name) {
            ModNote(title: name.prefix(1).uppercased() + name.dropFirst(), text: "This herdr-app panel isn't in Swiftr yet.")
        } else {
            ModNote(title: name, text: "This layout's mod isn't added yet: Settings › Mods.")
        }
    }
}

private struct ModNote: View {
    let title: String
    let text: String

    var body: some View {
        GeometryReader { box in
            if box.size.height < 90 {
                // A bar: one line.
                HStack(spacing: 8) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    Text(text).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .help(text)
            } else {
                VStack(spacing: 6) {
                    Text(title).font(.headline)
                    Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// What a mod's files say it does, and the button that lets it run.
struct ModConsent: View {
    let entry: Mods.Entry

    @State private var showsDetails = false

    var body: some View {
        GeometryReader { box in
            if box.size.height < 150 {
                // A bar or a small block: one line, the rest in a popover.
                HStack(spacing: 8) {
                    Text(entry.manifest.title).fontWeight(.medium).lineLimit(1)
                    Text("needs your OK to run").foregroundStyle(.secondary).lineLimit(1)
                    Button("Review…") { showsDetails = true }
                        .controlSize(.small)
                        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                            details.frame(width: 340).fixedSize(horizontal: false, vertical: true)
                        }
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ScrollView { details }
            }
        }
        .accessibilityIdentifier("mod-consent-\(entry.name)")
    }

    private var details: some View {
        let needs = entry.report.needs.sentences
        return VStack(alignment: .leading, spacing: 10) {
                Text(entry.manifest.title).font(.headline)
                Text("A mod is a program. Allow it only if you trust who wrote it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if needs.isEmpty {
                    Label("Only draws its panel", systemImage: "checkmark.circle")
                } else {
                    ForEach(needs, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.circle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !entry.report.programs.isEmpty {
                    Text("Programs: " + entry.report.programs.joined(separator: ", "))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !entry.report.sites.isEmpty {
                    Text("Sites: " + entry.report.sites.joined(separator: ", "))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Allow") { Mods.shared.allow(entry.name) }
                        .buttonStyle(.borderedProminent)
                    Button("Show Files") { NSWorkspace.shared.open(Mods.shared.center.modsFolder.appending(path: entry.name)) }
                }
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: A layout in the window

/// How wide or tall a part of a layout is: so many points, or a share of
/// what the fixed parts leave.
private nonisolated struct TrackSize: LayoutValueKey {
    static let defaultValue = Track(px: nil, weight: 1, hidden: false)
}

private nonisolated struct Track: Equatable, Sendable {
    var px: CGFloat?
    var weight: CGFloat
    var hidden: Bool
}

/// A layout's row or column.
private struct Tracks: Layout {
    let horizontal: Bool
    let gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 600, height: 400))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let tracks = subviews.map { $0[TrackSize.self] }
        let shown = tracks.filter { !$0.hidden }
        let length = horizontal ? bounds.width : bounds.height
        let room = length - gap * CGFloat(max(0, shown.count - 1))
        let fixed = shown.compactMap(\.px).reduce(0, +)
        let weights = shown.filter { $0.px == nil }.map(\.weight).reduce(0, +)
        // Fixed parts give way when the window is too small for them.
        let squeeze = weights == 0 || fixed > room ? (fixed > 0 ? room / fixed : 1) : 1
        let rest = max(0, room - fixed * squeeze)
        var at = horizontal ? bounds.minX : bounds.minY
        for (index, subview) in subviews.enumerated() {
            let track = tracks[index]
            if track.hidden {
                // Kept, so a hidden panel's mod keeps what it holds.
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(width: 0, height: 0))
                continue
            }
            let size = track.px.map { $0 * squeeze } ?? (weights > 0 ? rest * track.weight / weights : 0)
            let proposed = horizontal ? ProposedViewSize(width: size, height: bounds.height) : ProposedViewSize(width: bounds.width, height: size)
            subview.place(at: horizontal ? CGPoint(x: at, y: bounds.minY) : CGPoint(x: bounds.minX, y: at), proposal: proposed)
            at += size + gap
        }
    }
}

/// The shown tab with the layout's mods around it. Without a layout, or
/// with one that holds none of the person's mods, the tab alone.
struct ModLayoutHost: View {
    @Environment(AppModel.self) private var model
    let space: SpaceItem
    let tab: LayoutTab

    var body: some View {
        let mods = Mods.shared
        // Swiftr's own layout keeps the card for the tab: its mods are in
        // the window's right sidebar (`ModSidebar`), or in a panel at the
        // card's right, which the tab gives its room (`FloatingModSidebar`).
        if let layout = mods.layout, !layout.isOwn, !layout.mods.isEmpty {
            LayoutPart(item: layout.root, layout: layout, space: space, tab: tab, revision: mods.revision)
        } else {
            TabContent(space: space, tab: tab)
                .modifier(FloatingModSidebar())
        }
    }
}

private struct LayoutPart: View {
    @Environment(AppModel.self) private var model
    let item: WindowLayout.Item
    let layout: WindowLayout
    let space: SpaceItem
    let tab: LayoutTab
    /// The tree's items change in place: this tells each part to read its
    /// item again.
    let revision: Int
    /// False under a hidden part or a stack's other child.
    var shown = true

    var body: some View {
        switch item.kind {
        case .block:
            switch item.content {
            case .tab: TabContent(space: space, tab: tab)
            case .mod(let name):
                ModPanel(name: name, props: item.props, slot: item.id, shown: shown)
                    .background(Color(nsColor: model.prefs.theme.backgroundColor))
            default: Color.clear
            }
        case .row, .column:
            let horizontal = item.kind == .row
            let parts = item.children.filter(WindowLayout.shows)
            let line = Color(nsColor: model.prefs.theme.foregroundColor).opacity(0.14)
            Tracks(horizontal: horizontal, gap: parts.count > 1 ? 1 : 0) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { index, child in
                    LayoutPart(item: child, layout: layout, space: space, tab: tab, revision: revision, shown: shown && !child.hidden)
                        .clipped()
                        .overlay(alignment: handleEdge(index, in: parts, horizontal: horizontal)) {
                            if child.px != nil, child.resizable, !child.hidden {
                                ResizeHandle(item: child, layout: layout, horizontal: horizontal, leading: index > 0)
                            }
                        }
                        .opacity(child.hidden ? 0 : 1)
                        .allowsHitTesting(!child.hidden)
                        .layoutValue(key: TrackSize.self, value: Track(px: child.px.map { CGFloat($0) }, weight: CGFloat(child.weight), hidden: child.hidden))
                }
            }
            // The line between two parts.
            .background(line)
        case .stack:
            let shown = item.shownChild?.id
            let stack = ZStack {
                ForEach(item.children) { child in
                    // The others stay, out of sight, with what they hold.
                    LayoutPart(item: child, layout: layout, space: space, tab: tab, revision: revision, shown: self.shown && child.id == shown)
                        .opacity(child.id == shown ? 1 : 0)
                        .allowsHitTesting(child.id == shown)
                }
            }
            if needsSwitcher {
                // No mod draws the stack's switch, so Swiftr does.
                VStack(spacing: 0) {
                    ModSwitcher(stack: item, layout: layout, revision: revision)
                        .frame(height: 38)
                        // On the terminals' color: as light or dark as it.
                        .environment(\.colorScheme, model.prefs.theme.isDark ? .dark : .light)
                    stack
                }
                .background(Color(nsColor: model.prefs.theme.backgroundColor))
            } else {
                stack
            }
        }
    }

    /// A layout file's stack, while the layout lacks a bar that may be the
    /// one switching it. (Swiftr's own stack is in `ModSidebar`.)
    private var needsSwitcher: Bool {
        let mods = Mods.shared
        return ModSwitcher.choices(of: item).count > 1 && layout.lacksLooseMod { mods.has($0) }
    }

    private func handleEdge(_ index: Int, in parts: [WindowLayout.Item], horizontal: Bool) -> Alignment {
        if horizontal { return index > 0 ? .leading : .trailing }
        return index > 0 ? .top : .bottom
    }
}

/// How Swiftr's own layout shows the mods' sidebar.
enum ModSidebarStyle: String, CaseIterable, Identifiable {
    /// A panel on the terminals' card, which keeps its width: the tab
    /// gives the panel its room.
    case floating
    /// A column of the window, its mods on a card like the terminals'
    /// beside it.
    case card

    var id: String { rawValue }

    var title: String {
        switch self {
        case .floating: "Floating"
        case .card: "Card"
        }
    }
}

/// The mods of Swiftr's own layout, one shown at a time; the others stay,
/// out of sight, with what they hold.
private struct ModSidebarMods: View {
    let stack: WindowLayout.Item
    let inSight: Bool
    /// The tree changes in place: this tells the view to read it again.
    let revision: Int

    var body: some View {
        let shown = stack.shownChild?.id
        ZStack {
            ForEach(stack.children) { child in
                if case .mod(let name) = child.content {
                    ModPanel(name: name, props: child.props, slot: child.id, shown: inSight && child.id == shown, flush: true)
                        .opacity(child.id == shown ? 1 : 0)
                        .allowsHitTesting(child.id == shown)
                }
            }
        }
    }
}

/// The mods' sidebar in its card style, on the window's right: a column of
/// the window on the sidebar's own surface, its mods on a card. Its button
/// and its mods' names sit in the band the toolbar keeps, as the left
/// sidebar's buttons do.
struct ModSidebar: View {
    @Environment(AppModel.self) private var model

    static let minWidth: CGFloat = 240
    static let maxWidth: CGFloat = 640

    var body: some View {
        let mods = Mods.shared
        let revision = mods.revision
        VStack(spacing: 0) {
            if let layout = mods.layout, layout.isOwn, let stack = layout.find(WindowLayout.panelStackID) {
                // In sight only as the column: the window keeps this
                // content once shown, the floating panel's mods beside it.
                ModSidebarMods(stack: stack, inSight: mods.sidebarShown, revision: revision)
                    .modifier(ModCard())
                    .contextMenu { ModSidebarStyleMenu() }
                    // As far from the window's edge as the card is; the card's
                    // own margin is between the two.
                    .padding([.trailing, .bottom], Card.margin)
                    .overlay(alignment: .top) {
                        GeometryReader { box in
                            // The band from the window's top, as `TopRow` reads it.
                            let band = max(box.frame(in: .global).minY, 34)
                            ModSidebarHeader(stack: stack, layout: layout, revision: revision)
                                .padding(.trailing, Card.margin)
                                .frame(height: band)
                                .offset(y: -band)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // One surface with the sidebar and the card's frame.
        .background { SidebarMaterial().ignoresSafeArea() }
        .background { ModColumnWidth(width: mods.sidebarPin) }
        // The width its edge was dragged to comes back at the next launch.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { mods.noteSidebar(width: $0) }
        .accessibilityIdentifier("mod-sidebar")
    }
}

/// Puts the window's column this sits in at a width, while one is asked:
/// SwiftUI gives the column's least, best and most widths, not its width
/// now.
private struct ModColumnWidth: NSViewRepresentable {
    let width: CGFloat?

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.asked = width
        // Once the window has laid the column out, and never from inside
        // a layout: the split view raises an exception there.
        if width != nil { DispatchQueue.main.async { view.apply() } }
    }

    final class Probe: NSView {
        var asked: CGFloat?

        func apply() {
            guard let asked else { return }
            // The split view, and the column of it this view is in.
            var column: NSView = self
            while let up = column.superview, !(up is NSSplitView) { column = up }
            guard let split = column.superview as? NSSplitView, let at = split.arrangedSubviews.firstIndex(of: column), at > 0,
                  column.frame.width > 1, abs(column.frame.width - asked) > 0.5 else { return }
            // The line before the column takes no room of its own here: the
            // column starts where the line is put. Never where it would
            // squeeze the column before it: put too far, the line closed
            // this column, and the sidebar with it.
            let line = column.frame.maxX - asked
            guard line > split.arrangedSubviews[at - 1].frame.minX + 200 else { return }
            split.setPosition(line, ofDividerAt: at - 1)
        }
    }
}

/// The card style: the mods on a card of the terminals' color, shaped and
/// edged as the terminals' own.
private struct ModCard: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .environment(\.colorScheme, model.prefs.theme.isDark ? .dark : .light)
            .clipShape(Card.shape)
            .background {
                Card.shape
                    .fill(Color(nsColor: model.prefs.theme.backgroundColor))
                    .shadow(color: .black.opacity(dark ? 0.3 : 0.08), radius: 2)
                    .overlay { Card.shape.stroke(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.12), lineWidth: 1).padding(-0.5) }
            }
    }
}

/// The floating style: the mods' sidebar as a lifted panel on the
/// terminals' card, at its right. The tab gives the panel its room, so
/// nothing lies under it, and the panel's left edge drags to size it.
/// Its button stays in the top row, over it (`TabStrip`).
struct FloatingModSidebar: ViewModifier {
    @Environment(AppModel.self) private var model
    /// While the panel's edge is dragged: its width when pressed, and now.
    @State private var dragFrom: CGFloat?
    @State private var draggedTo: CGFloat?

    /// Between the panel and the card's edges.
    static let inset: CGFloat = Card.margin
    /// Between the tab and the panel.
    static let gap: CGFloat = 4
    /// The least the tab keeps, in a narrow window.
    static let tabFloor: CGFloat = 320

    /// The panel's width in a card this wide: the one asked, as far as
    /// the tab keeps its floor.
    static func width(_ asked: CGFloat, in total: CGFloat) -> CGFloat {
        let most = min(ModSidebar.maxWidth, total - tabFloor - inset - gap)
        return max(min(max(asked, ModSidebar.minWidth), most), 160)
    }

    func body(content: Content) -> some View {
        let mods = Mods.shared
        let revision = mods.revision
        let shown = mods.floatingShown
        GeometryReader { box in
            let total = box.size.width
            // A change of style: how much of the column is in, 0 to 1,
            // read from this card's own width. The window moves the column
            // by its own clock, and this follows it frame by frame.
            let cross = Self.cross(mods, total: total)
            let full = cross == nil ? total : mods.cardFull
            let width = Self.width(draggedTo ?? mods.sidebarWidth, in: full)
            let room = width + Self.inset + Self.gap
            ZStack(alignment: .topTrailing) {
                content
                    // The tab's room goes to the column as it comes: the
                    // tab stays as wide as it was.
                    .frame(width: max(0, total - (cross.map { room * (1 - $0) } ?? (shown ? room : 0))), height: box.size.height)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Kept while hidden, past the card's edge, as a column of
                // the window keeps its content: built anew at each open,
                // its header joined the slide late, the glass under the
                // shown name last of all.
                if mods.sidebarStyle == .floating || cross != nil, let layout = mods.layout, layout.isOwn, let stack = layout.find(WindowLayout.panelStackID) {
                    panel(stack, layout, revision: revision, width: width, total: full, shown: shown)
                        // One body for the slide. Without this each part
                        // inside goes to its new place by its own
                        // animation, or by none: the piece under the shown
                        // name jumped to the end and came back late.
                        .geometryGroup()
                        // In a change of style it holds its place in the
                        // window while the card's edge moves, and fades as
                        // the column covers it.
                        .offset(x: cross == nil ? (shown ? 0 : width + Self.inset + Self.away) : full - total)
                        .opacity(cross.map { 1 - $0 } ?? 1)
                        .allowsHitTesting(shown && cross == nil)
                        .accessibilityHidden(!shown)
                }
            }
            // The tab gives way as the panel slides in, and takes its room
            // back as it slides out: one move, as a column of the window
            // makes. Only when it opens or closes: a drag of the panel's
            // edge follows the hand, and a change of style follows the
            // window's column (`Mods.pick(style:)`).
            .animation(.smooth(duration: 0.3), value: mods.panelShown)
            // What is left when the column came in at another width than
            // the one counted on.
            .animation(.smooth(duration: 0.2), value: mods.crossing)
        }
    }

    /// How far past the card's edge the hidden panel waits: clear of its
    /// shadow.
    private static let away: CGFloat = 24

    /// In a change of style, the share of the column that is in. It notes
    /// the card's width, which the next change of style counts from.
    private static func cross(_ mods: Mods, total: CGFloat) -> CGFloat? {
        mods.cardWidth = total
        guard mods.crossing, mods.cardFull > 0 else { return nil }
        return min(max((mods.cardFull - total) / max(mods.crossColumn, 1), 0), 1)
    }

    private func panel(_ stack: WindowLayout.Item, _ layout: WindowLayout, revision: Int, width: CGFloat, total: CGFloat, shown: Bool) -> some View {
        let dark = model.prefs.theme.isDark
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(spacing: 0) {
            // One mod alone heads itself.
            if ModSwitcher.choices(of: stack).count > 1 {
                ModSwitcher(stack: stack, layout: layout, revision: revision)
                    .padding(.horizontal, 8)
                    .frame(height: 44)
            }
            ModSidebarMods(stack: stack, inSight: shown, revision: revision)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipShape(shape)
        // The bare parts of the header too.
        .contentShape(shape)
        .contextMenu { ModSidebarStyleMenu() }
        // Solid, lifted off the card: no glass beside text that repaints.
        .background {
            shape
                .fill(Color(nsColor: model.prefs.theme.backgroundColor))
                .overlay { shape.fill(Color.white.opacity(dark ? 0.09 : 0)) }
                .shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 10, y: 3)
                .overlay { shape.strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.14), lineWidth: 1) }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        // Its left edge, to drag.
        .overlay(alignment: .leading) {
            ModGrip(sideways: true, name: "sidebar") { right in
                let from = dragFrom ?? width
                dragFrom = from
                draggedTo = Self.width(from - right, in: total)
            } ended: {
                if let to = draggedTo { Mods.shared.setSidebar(width: to) }
                dragFrom = nil
                draggedTo = nil
            }
            .frame(width: 10)
            .offset(x: -5)
        }
        .padding(Self.inset)
        .accessibilityIdentifier("mod-sidebar-floating")
    }
}

/// A grip on an edge that sizes a part: the resize pointer, and drags
/// through its own mouse events, in a background window too
/// (`acceptsFirstMouse`), as the left sidebar's `SplitHandle`.
struct ModGrip: View {
    /// Dragged left and right; else up and down.
    let sideways: Bool
    /// For tests, which find it by this.
    let name: String
    /// How far the pointer went right (or down) since it was pressed.
    let moved: (CGFloat) -> Void
    let ended: () -> Void

    var body: some View {
        ModGripArea(sideways: sideways, name: name, moved: moved, ended: ended)
            // The resize pointer, asked three ways: SwiftUI's own here, and
            // in the view a cursor rectangle and a tracking area. Between
            // two scrolling lists the rectangle alone did not show it.
            .pointerStyle(sideways ? .columnResize : .rowResize)
    }
}

private struct ModGripArea: NSViewRepresentable {
    let sideways: Bool
    let name: String
    let moved: (CGFloat) -> Void
    let ended: () -> Void

    func makeNSView(context: Context) -> ModGripView {
        let view = ModGripView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ModGripView, context: Context) {
        view.sideways = sideways
        view.name = name
        view.moved = moved
        view.ended = ended
    }
}

final class ModGripView: NSView {
    var sideways = false {
        didSet { if sideways != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    var name = ""
    var moved: (CGFloat) -> Void = { _ in }
    var ended: () -> Void = {}

    private var pointer: NSCursor { sideways ? .columnResize : .rowResize }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: pointer)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { pointer.set() }
    override func mouseEntered(with event: NSEvent) { pointer.set() }
    override func mouseMoved(with event: NSEvent) { pointer.set() }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    /// The whole drag, press to release, as AppKit's own dividers track
    /// one: its events come here alone. The pointer runs ahead of the edge
    /// and crosses other views; were they told, each would set its own
    /// pointer, and the resize pointer flickered.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        pointer.push()
        window.disableCursorRects()
        var release: NSEvent?
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                release = next
                break
            }
            // Window points go up.
            let at = next.locationInWindow
            moved(sideways ? at.x - start.x : start.y - at.y)
            pointer.set()
        }
        window.enableCursorRects()
        NSCursor.pop()
        ended()
        // The release goes on its usual way: the window saw the press, and
        // what watches its clicks waits for the release. Without it the
        // next click anywhere in the window was lost.
        if let release { NSApp.postEvent(release, atStart: true) }
        // What the crossed views were not told comes now: the pointer's
        // look is set again after it, by where it rests.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.invalidateCursorRects(for: self)
            if bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { pointer.set() }
        }
    }
}

/// The card style's top, in the band the toolbar keeps: the button that
/// hides the sidebar, where the left sidebar has its own, and the mods' names.
struct ModSidebarHeader: View {
    let stack: WindowLayout.Item
    let layout: WindowLayout
    let revision: Int

    var body: some View {
        ZStack {
            ModSwitcher(stack: stack, layout: layout, revision: revision)
                // Clear of the button, and as much on the other side.
                .padding(.horizontal, RoundGlassButton.side + 10)
            RoundGlassButton(symbol: "sidebar.right", title: "Hide Mods Sidebar", help: "Hide Mods Sidebar (⌥⌘B)") {
                Mods.shared.togglePanel()
            }
            .contextMenu { ModSidebarStyleMenu() }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A round glass button, as the toolbar draws the sidebar's own.
struct RoundGlassButton: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void

    /// The toolbar's round buttons are this wide.
    static let side: CGFloat = 36

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                // As the top row's icons: see `TabStrip.actionIcon`.
                .foregroundStyle(Color.primary)
                .frame(width: Self.side, height: Self.side)
                .contentShape(.circle)
        }
        .buttonStyle(.borderless)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
        .accessibilityLabel(title)
    }
}

/// The sidebar's two styles, in the menu a right click opens on its button
/// and in it: the choice Settings › Appearance shows with pictures.
extension Mods {
    /// The sidebar's style, changed in one move: the window slides the
    /// column in or out, and the floating panel holds its place under it
    /// (`crossing`). Left to themselves the column and the panel both
    /// slid, side by side for a moment, and the tab was squeezed twice.
    func pick(style: ModSidebarStyle) {
        // One change at a time: told to leave while it still comes in, the
        // window's column stays, and the style no longer says what shows.
        guard !crossing else {
            crossNext = style
            return
        }
        guard style != sidebarStyle else { return }
        // Hidden, nothing moves.
        guard layout?.isOwn == true, panelShown, cardWidth > 0 else {
            sidebarStyle = style
            return
        }
        let wanted = sidebarWidth
        // The column's width: the one it has, or the one it comes in at,
        // which is the panel's.
        crossColumn = sidebarShown && columnWidth > 0 ? columnWidth : wanted
        cardFull = cardWidth + (sidebarShown ? crossColumn : 0)
        crossing = true
        sidebarStyle = style
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.crossTime) { [weak self] in
            guard let self else { return }
            widthNote?.cancel()
            crossing = false
            if let next = crossNext {
                crossNext = nil
                if next != sidebarStyle { return pick(style: next) }
            }
            // The column, at the panel's width: see `sidebarPin`.
            guard sidebarStyle == .card, abs(columnWidth - wanted) > 0.5 else { return }
            sidebarPin = wanted
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.sidebarPin = nil }
        }
    }

    /// Longer than the window takes to slide a column.
    private static let crossTime = 0.6
}

struct ModSidebarStyleMenu: View {
    var body: some View {
        Picker("Sidebar Style", selection: Binding(get: { Mods.shared.sidebarStyle }, set: { Mods.shared.pick(style: $0) })) {
            Text("Floating").tag(ModSidebarStyle.floating)
            Text("Card").tag(ModSidebarStyle.card)
        }
        .pickerStyle(.inline)
    }
}

/// What picks the mod a stack shows, as the tab strip shows its tabs: the
/// names side by side, one piece of glass sliding under the shown one. A
/// menu when they are too many to sit side by side. One mod alone needs
/// none: it heads itself.
struct ModSwitcher: View {
    let stack: WindowLayout.Item
    let layout: WindowLayout
    /// The tree changes in place: this tells the control to read it again.
    let revision: Int

    /// Where each name sits in the row, by the mod's block. Anchors, read
    /// in the row itself: no state to fill after the first layout, so the
    /// glass is under its name from the first frame.
    private struct Places: PreferenceKey {
        static var defaultValue: [String: Anchor<CGRect>] { [:] }
        static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
            value.merge(nextValue()) { $1 }
        }
    }

    /// The stack's mods the person has.
    static func choices(of stack: WindowLayout.Item) -> [WindowLayout.Item] {
        stack.children.filter { child in
            if case .mod(let name) = child.content { return Mods.shared.has(name) }
            return false
        }
    }

    var body: some View {
        let children = Self.choices(of: stack)
        let active = stack.shownChild?.id
        Group {
            if children.count > 1 {
                ViewThatFits(in: .horizontal) {
                    names(children, active: active)
                    menu(children, active: active)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("mod-switcher")
    }

    private func names(_ children: [WindowLayout.Item], active: String?) -> some View {
        HStack(spacing: 3) {
            ForEach(children) { child in
                let shown = child.id == active
                Button {
                    layout.select(stack: stack.id, child: child.id)
                } label: {
                    Text(title(child))
                        .font(.callout)
                        .fontWeight(shown ? .semibold : .regular)
                        .foregroundStyle(shown ? .primary : .secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(shown ? .isSelected : [])
                .anchorPreference(key: Places.self, value: .bounds) { [child.id: $0] }
            }
        }
        // One piece of glass for all, so that it slides from name to name.
        .backgroundPreferenceValue(Places.self) { places in
            GeometryReader { row in
                if let active, let anchor = places[active] {
                    let place = row[anchor]
                    Color.clear
                        .frame(width: place.width, height: place.height)
                        .glassEffect(.regular, in: .capsule)
                        .offset(x: place.minX, y: place.minY)
                        .animation(.smooth(duration: 0.3), value: place)
                }
            }
        }
        .fixedSize()
    }

    private func menu(_ children: [WindowLayout.Item], active: String?) -> some View {
        Menu {
            ForEach(children) { child in
                Toggle(title(child), isOn: Binding(get: { child.id == active }, set: { _ in layout.select(stack: stack.id, child: child.id) }))
            }
        } label: {
            HStack(spacing: 4) {
                Text(children.first { $0.id == active }.map(title) ?? "Mods")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .capsule)
        .fixedSize()
    }

    private func title(_ item: WindowLayout.Item) -> String {
        guard case .mod(let name) = item.content else { return item.id }
        return Mods.shared.title(of: name)
    }
}

/// The edge of a part with a set size: drag it to resize the part.
private struct ResizeHandle: View {
    let item: WindowLayout.Item
    let layout: WindowLayout
    let horizontal: Bool
    /// On the part's leading (or top) edge: dragging toward it grows the part.
    let leading: Bool
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: horizontal ? 7 : nil, height: horizontal ? nil : 7)
            .contentShape(Rectangle())
            .offset(x: horizontal ? (leading ? -3 : 3) : 0, y: horizontal ? 0 : (leading ? -3 : 3))
            .pointerStyle(horizontal ? .columnResize : .rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = start ?? item.px ?? 0
                        if start == nil { start = from }
                        let moved = Double(horizontal ? drag.translation.width : drag.translation.height)
                        layout.resize(id: item.id, px: max(80, from + (leading ? -moved : moved)))
                    }
                    .onEnded { _ in start = nil }
            )
            .accessibilityIdentifier("mod-resize-\(item.id)")
    }
}

// MARK: Over the window

/// Mods opened over the window (`mod.open`, `openOverlay`), and what mods
/// tell the person.
struct ModOverlays: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mods = Mods.shared
        ZStack {
            ForEach(mods.overlays) { overlay in
                ModOverlayView(overlay: overlay)
            }
            if !mods.toasts.isEmpty {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(mods.toasts) { toast in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(toast.title).font(.callout.weight(.semibold))
                            if !toast.body.isEmpty { Text(toast.body).font(.callout).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: 320, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator) }
                        .onTapGesture { mods.dismiss(toast: toast.id) }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }
}

private struct ModOverlayView: View {
    @Environment(AppModel.self) private var model
    let overlay: Mods.Overlay
    @State private var natural: CGFloat = 0

    var body: some View {
        GeometryReader { box in
            let popup = overlay.kind == "popup"
            let limit = max(160, box.size.height - 80)
            let height = min(overlay.height ?? (natural > 0 ? natural : 320), limit)
            let width = min(overlay.width, box.size.width - 40)
            let shape = RoundedRectangle(cornerRadius: popup ? 10 : 14, style: .continuous)
            ZStack(alignment: .topLeading) {
                // A press outside closes it.
                Color.black.opacity(popup ? 0.001 : 0.28)
                    .onTapGesture { Mods.shared.modCloseOverlay(overlay.id) }
                ModPanel(name: overlay.mod, props: overlay.props, slot: "overlay-\(overlay.mod)", takesKeyboard: true,
                         onHeight: overlay.height == nil ? { tall in
                             DispatchQueue.main.async { if natural != tall { natural = tall } }
                         } : nil)
                    .frame(width: width, height: height)
                    .background(Color(nsColor: model.prefs.theme.backgroundColor))
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(Color(nsColor: model.prefs.theme.foregroundColor).opacity(0.16)) }
                    .shadow(color: .black.opacity(0.35), radius: popup ? 12 : 30, y: popup ? 4 : 12)
                    .offset(offset(popup: popup, size: CGSize(width: width, height: height), in: box.size))
            }
        }
        .onExitCommand { Mods.shared.modCloseOverlay(overlay.id) }
        .accessibilityIdentifier("mod-overlay-\(overlay.mod)")
    }

    /// A dialog in the middle, a little high; a popup at the pointer, kept
    /// inside the window.
    private func offset(popup: Bool, size: CGSize, in window: CGSize) -> CGSize {
        if popup, let at = overlay.at {
            return CGSize(width: min(max(8, at.x), window.width - size.width - 8), height: min(max(8, at.y), window.height - size.height - 8))
        }
        return CGSize(width: (window.width - size.width) / 2, height: max(40, (window.height - size.height) * 0.38))
    }
}
