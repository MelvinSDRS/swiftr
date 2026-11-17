import HerdrKit
import SwiftUI

/// The window's top row, in the title's place: the shown space's tabs, then
/// the pane buttons, the starred agents and the +; before the tabs, Back
/// and Forward once the sidebar is hidden. The shown tab sits
/// on glass, which slides to the next tab shown. Drag a tab along the strip
/// to move it.
struct TabStrip: View {
    @Environment(AppModel.self) private var model
    let space: SpaceItem
    /// On the card, in the terminals' light or dark; else on the window's
    /// frame, in the window's.
    let onCard: Bool
    @State private var drag: TabDrag?
    /// Where each tab's chip sits in the strip.
    @State private var frames: [String: CGRect] = [:]
    /// The chips' width, padding included: the strip takes no more, so the
    /// row past the last tab still drags the window.
    @State private var tabsWidth: CGFloat?
    /// The strip's ends past which more tabs wait: they fade out there
    /// rather than stop short.
    @State private var hidden = HiddenEnds()

    private static let spacing: CGFloat = 3
    /// How far in from an end the tabs fade out.
    private static let fade: CGFloat = 28
    /// A button of the row's glass groups, as big as the toolbar's were.
    static let button = CGSize(width: 32, height: 28)

    var body: some View {
        HStack(spacing: 4) {
            // Back and Forward, while the sidebar is hidden: shown, the
            // toolbar has them over it (`HistoryButton`), and its column
            // takes them along when it goes.
            if !model.sidebarVisible {
                HStack(spacing: 0) {
                    let (back, forward) = (model.canGoBack, model.canGoForward)
                    Button { model.goBack() } label: { actionIcon("chevron.left").opacity(back ? 1 : 0.35) }
                        .buttonStyle(.borderless)
                        .disabled(!back)
                        .help("Back (⌘[)")
                    Button { model.goForward() } label: { actionIcon("chevron.right").opacity(forward ? 1 : 0.35) }
                        .buttonStyle(.borderless)
                        .disabled(!forward)
                        .help("Forward (⌘])")
                }
                .padding(.horizontal, 2)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.leading, 8)
            }
            if model.prefs.showsTabBar {
                tabs
                    .frame(maxWidth: tabsWidth ?? .infinity)
                    // All the room the tabs need before the space after them.
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            // What the title's line said when herdr-core isn't there.
            if let note = linkNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            // The splits on a piece of glass of their own, then the starred
            // agents and the + on another, as the toolbar groups its buttons.
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Button { model.split(.row) } label: { actionIcon("rectangle.split.2x1") }
                        .buttonStyle(.borderless)
                        .help("Split Right (⌘D)")
                    Button { model.split(.column) } label: { actionIcon("rectangle.split.1x2") }
                        .buttonStyle(.borderless)
                        .help("Split Down (⇧⌘D)")
                }
                .padding(.horizontal, 2)
                .glassEffect(.regular.interactive(), in: .capsule)
                HStack(spacing: 0) {
                    FavoriteAgents(space: space)
                    NewTabButton(space: space)
                }
                .padding(.horizontal, 2)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding(.trailing, 8)
        }
        .frame(height: 34)
        .modifier(SchemeOf(theme: onCard ? model.prefs.theme.isDark : nil))
    }

    private var linkNote: String? {
        switch model.link {
        case .connected: nil
        case .connecting: "Connecting…"
        case .installing: "Installing herdr-core…"
        case .failed: "herdr-core isn't responding"
        case .missing, .installFailed: "herdr-core isn't installed"
        }
    }

    private func actionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(.secondary)
            .frame(width: Self.button.width, height: Self.button.height)
            .contentShape(Rectangle())
    }

    private var tabs: some View {
        let active = model.activeTab(in: space)?.id
        return ScrollView(.horizontal) {
            HStack(spacing: Self.spacing) {
                ForEach(Array(space.tabs.enumerated()), id: \.element.id) { index, tab in
                    let dragged = drag?.id == tab.id
                    TabChip(space: space, tab: tab, index: index, active: tab.id == active)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TabDrag.strip)) } action: { frames[tab.id] = $0 }
                        .simultaneousGesture(dragGesture(for: tab, at: index))
                        // Lifted while dragged; the shown tab has the strip's glass.
                        .glassEffect(dragged && tab.id != active ? .regular : .identity, in: .capsule)
                        .offset(x: drag?.offset(of: index, spacing: Self.spacing) ?? 0)
                        .zIndex(dragged ? 1 : 0)
                        // The others step aside; the dragged one stays under the pointer.
                        .animation(dragged ? nil : .easeOut(duration: 0.15), value: drag?.to)
                }
            }
            .background(alignment: .topLeading) { selection(under: active) }
            .coordinateSpace(.named(TabDrag.strip))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
            .background { WheelTurnsSideways() }
        }
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: HiddenEnds.self) { geometry in
            let shown = geometry.visibleRect
            return HiddenEnds(leading: shown.minX > 0.5, trailing: shown.maxX < geometry.contentSize.width - 0.5)
        } action: { _, ends in
            withAnimation(.easeOut(duration: 0.15)) { hidden = ends }
        }
        .mask { fadeMask }
    }

    /// Opaque, but for a fade at each end with tabs past it.
    private var fadeMask: some View {
        HStack(spacing: 0) {
            fadeEnd(from: .leading, faded: hidden.leading)
            Color.black
            fadeEnd(from: .trailing, faded: hidden.trailing)
        }
    }

    private func fadeEnd(from edge: UnitPoint, faded: Bool) -> some View {
        ZStack {
            LinearGradient(colors: [.clear, .black], startPoint: edge, endPoint: edge == .leading ? .trailing : .leading)
            // Covers the fade while no tab waits past this end.
            Color.black.opacity(faded ? 0 : 1)
        }
        .frame(width: Self.fade)
    }

    /// The glass under the shown tab: one piece for the whole strip, so that
    /// it slides from tab to tab rather than fading out on one and in on the
    /// other. It follows a dragged tab under the pointer.
    @ViewBuilder private func selection(under active: String?) -> some View {
        if let active, let index = space.tabs.firstIndex(where: { $0.id == active }), let frame = frames[active] {
            let place = frame.offsetBy(dx: drag?.offset(of: index, spacing: Self.spacing) ?? 0, dy: 0)
            Color.clear
                .frame(width: place.width, height: place.height)
                .glassEffect(.regular, in: .capsule)
                .offset(x: place.minX, y: place.minY)
                .animation(drag?.from == index ? nil : .smooth(duration: 0.3), value: place)
        }
    }

    private func dragGesture(for tab: LayoutTab, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(TabDrag.strip))
            .onChanged { value in
                let ids = space.tabs.map(\.id)
                if drag == nil {
                    let placed = ids.compactMap { frames[$0] }
                    guard placed.count == ids.count, ids.indices.contains(index) else { return }
                    drag = TabDrag(id: tab.id, from: index, frames: placed)
                }
                // The tabs changed meanwhile (another screen): let go.
                guard drag?.frames.count == ids.count else {
                    drag = nil
                    return
                }
                drag?.follow(value.translation.width)
            }
            .onEnded { _ in
                guard let d = drag else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    drag = nil
                    if d.to != d.from { model.moveTab(d.id, in: space, to: d.to) }
                }
                model.select(tab: tab, in: space)
            }
    }
}

/// A mouse wheel turned up or down over the strip moves the tabs sideways:
/// the strip's scroll view only scrolls sideways and drops the rest. A
/// sideways wheel and a trackpad's swipes reach it as they are.
private struct WheelTurnsSideways: NSViewRepresentable {
    func makeNSView(context: Context) -> Catcher { Catcher() }

    func updateNSView(_ view: Catcher, context: Context) {}

    /// Inside the strip's scroll view, which it finds above it.
    final class Catcher: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return turn(event)
            }
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// nil once the strip has moved.
        private func turn(_ event: NSEvent) -> NSEvent? {
            // A trackpad's or a Magic Mouse's swipe comes in phases: left as it is.
            guard event.phase.isEmpty, event.momentumPhase.isEmpty,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  let window, event.window === window,
                  let scroll = enclosingScrollView, !scroll.isHiddenOrHasHiddenAncestor,
                  scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)),
                  let tabs = scroll.documentView
            else { return event }
            let clip = scroll.contentView
            guard tabs.frame.width > clip.bounds.width else { return event }
            // A wheel that turns in steps counts in lines; a smooth one, in points.
            let step = event.hasPreciseScrollingDeltas ? 1 : scroll.horizontalLineScroll
            // Down brings in the tabs on the right, as it brings in what is below.
            var shown = clip.bounds
            shown.origin.x -= event.scrollingDeltaY * step
            clip.scroll(to: clip.constrainBoundsRect(shown).origin)
            scroll.reflectScrolledClipView(clip)
            return nil
        }
    }
}

/// The terminals' light or dark, for the text and the glass on their color;
/// nil: the window's own, left as it is.
private struct SchemeOf: ViewModifier {
    let theme: Bool?

    func body(content: Content) -> some View {
        if let dark = theme {
            content.environment(\.colorScheme, dark ? .dark : .light)
        } else {
            content
        }
    }
}

/// Which ends of the strip have tabs past them, out of view.
private struct HiddenEnds: Equatable {
    var leading = false
    var trailing = false
}

/// A tab being dragged along the strip.
private struct TabDrag: Equatable {
    nonisolated static let strip = "tab strip"

    let id: String
    let from: Int
    /// Where the chips sat when the drag began, in tab order.
    let frames: [CGRect]
    var dx: CGFloat = 0
    /// Where the tab lands if dropped now.
    var to: Int

    init(id: String, from: Int, frames: [CGRect]) {
        self.id = id
        self.from = from
        self.frames = frames
        to = from
    }

    /// Follows the pointer, inside the strip; the tab lands past each tab
    /// whose middle its leading edge passed.
    mutating func follow(_ x: CGFloat) {
        guard let first = frames.first, let last = frames.last else { return }
        let me = frames[from]
        dx = min(max(x, first.minX - me.minX), last.maxX - me.maxX)
        let passedRight = frames.indices.filter { $0 > from && frames[$0].midX < me.maxX + dx }.count
        let passedLeft = frames.indices.filter { $0 < from && frames[$0].midX > me.minX + dx }.count
        to = from + passedRight - passedLeft
    }

    /// How far the chip at `index` moves: the dragged one follows the
    /// pointer, the ones it passed step aside.
    func offset(of index: Int, spacing: CGFloat) -> CGFloat {
        if index == from { return dx }
        let room = frames[from].width + spacing
        if from < to, index > from, index <= to { return -room }
        if to < from, index >= to, index < from { return room }
        return 0
    }
}

/// Back or Forward through the tabs shown before, of any space, as a button
/// of the toolbar: over the sidebar, between the window's buttons and the
/// sidebar's. It reads the history itself: a tab switch draws it alone
/// again, not the toolbar.
struct HistoryButton: View {
    let model: AppModel
    let forward: Bool

    var body: some View {
        Button {
            if forward { model.goForward() } else { model.goBack() }
        } label: {
            Label(forward ? "Forward" : "Back", systemImage: forward ? "chevron.right" : "chevron.left")
        }
        .disabled(!(forward ? model.canGoForward : model.canGoBack))
        .help(forward ? "Forward (⌘])" : "Back (⌘[)")
    }
}

struct TabChip: View {
    @Environment(AppModel.self) private var model
    let space: SpaceItem
    let tab: LayoutTab
    let index: Int
    let active: Bool
    @State private var hovering = false

    var body: some View {
        let attention = model.attention(of: model.addresses(of: tab, in: space))
        let subtitle = model.subtitle(of: tab, in: space)
        HStack(spacing: 6) {
            // As herdr-app: the program's icon first, the state after the name.
            if let program = model.programKey(of: tab, in: space) {
                ProgramIcon(key: program, size: 14)
                    .foregroundStyle(.secondary)
            }
            Text(model.title(of: tab, index: index))
                .fontWeight(active ? .semibold : .regular)
                .lineLimit(1)
            if tab.name.isEmpty, !subtitle.isEmpty {
                Text(cleanTitle(subtitle, fallback: subtitle))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            StateMark(attention: attention, asleep: model.sleepers.anyAsleep(model.addresses(of: tab, in: space)))
            Button {
                model.select(tab: tab, in: space)
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .font(.callout)
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        // The shown tab sits on the strip's glass; another lights up under the pointer.
        .background(Color.primary.opacity(!active && hovering ? 0.07 : 0), in: .capsule)
        .contentShape(.capsule)
        .onHover { hovering = $0 }
        // Shown at the first click; the second of a double click renames it.
        // A double-tap gesture would hold each click back for the
        // double-click time, half a second, to rule out a second one.
        .onTapGesture {
            model.select(tab: tab, in: space)
            if NSApp.currentEvent?.clickCount == 2 {
                model.renaming = .tab(Place(space.machine, tab.id), tab.name)
            }
        }
        .contextMenu {
            Button("Rename…") {
                model.select(tab: tab, in: space)
                model.renaming = .tab(Place(space.machine, tab.id), tab.name)
            }
            if index > 0 {
                Button("Move Left") { model.moveTab(tab.id, in: space, to: index - 1) }
            }
            if index < space.tabs.count - 1 {
                Button("Move Right") { model.moveTab(tab.id, in: space, to: index + 1) }
            }
            SleepMenuItems(addresses: model.addresses(of: tab, in: space))
            Divider()
            Button("Close Tab", role: .destructive) {
                model.select(tab: tab, in: space)
                model.closeTab(tab.id)
            }
        }
        .help(subtitle)
    }
}
