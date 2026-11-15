import HerdrKit
import SwiftUI

/// What every pane of the shown tab needs to know.
struct PaneContext: Equatable {
    let space: SpaceItem
    let tab: LayoutTab
    let focused: String?
    /// More than one pane on screen: mark the focused one.
    let multiple: Bool
}

/// A tab's layout: rows, columns and stacks down to its panes.
struct PaneTree: View {
    let node: LayoutNode
    let context: PaneContext

    var body: some View {
        switch node {
        case .block(let id, let content, _, _):
            PaneView(paneID: id, content: content, context: context)
        case .split(let id, let axis, let children, _, _):
            let shown = children.filter { !$0.hidden }
            if shown.count == 1 {
                PaneTree(node: shown[0], context: context)
            } else if !shown.isEmpty {
                SplitContainer(id: id, axis: axis, children: shown, context: context)
            }
        case .stack(_, let children, let active, _, _):
            if let shown = children.first(where: { $0.id == active }) ?? children.first {
                PaneTree(node: shown, context: context)
            }
        }
    }
}

/// A row or column, with dividers to drag between its children.
struct SplitContainer: View {
    @Environment(AppModel.self) private var model
    let id: String
    let axis: SplitAxis
    let children: [LayoutNode]
    let context: PaneContext

    /// Weights while a divider is dragged, until the document comes back.
    @State private var dragging: [Double]?
    @State private var dragStart: [Double] = []

    static let gap: CGFloat = 5

    private var horizontal: Bool { axis == .row }

    private var weights: [Double] {
        if let dragging, dragging.count == children.count { return dragging }
        return children.map { child in
            if case .weight(let w) = child.size { return max(w, 0.0001) }
            return 1
        }
    }

    private func fixed(_ i: Int) -> CGFloat? {
        if case .px(let p) = children[i].size { return CGFloat(p) }
        return nil
    }

    /// Points for each child: fixed ones first, the rest shared by weight.
    private func lengths(_ total: CGFloat) -> [CGFloat] {
        let w = weights
        let fixedTotal = children.indices.compactMap(fixed).reduce(0, +)
        let flex = max(0, total - fixedTotal)
        let flexWeight = children.indices.filter { fixed($0) == nil }.map { w[$0] }.reduce(0, +)
        return children.indices.map { i in fixed(i) ?? (flexWeight > 0 ? flex * CGFloat(w[i] / flexWeight) : 0) }
    }

    var body: some View {
        GeometryReader { geo in
            let length = (horizontal ? geo.size.width : geo.size.height) - CGFloat(children.count - 1) * Self.gap
            let sizes = lengths(length)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(children.enumerated()), id: \.element.id) { i, child in
                    PaneTree(node: child, context: context)
                        .frame(width: horizontal ? max(0, sizes[i]) : nil, height: horizontal ? nil : max(0, sizes[i]))
                    if i < children.count - 1 {
                        divider(after: i, flexLength: length)
                    }
                }
            }
        }
        .onChange(of: children.map(\.size)) { dragging = nil }
    }

    private func divider(after i: Int, flexLength: CGFloat) -> some View {
        ZStack {
            Color(nsColor: model.prefs.theme.backgroundColor)
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
        }
        .frame(width: horizontal ? Self.gap : nil, height: horizontal ? nil : Self.gap)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in drag(i, by: horizontal ? g.translation.width : g.translation.height, flexLength: flexLength) }
                .onEnded { _ in commit() }
        )
    }

    private func drag(_ i: Int, by delta: CGFloat, flexLength: CGFloat) {
        guard fixed(i) == nil, fixed(i + 1) == nil else { return }
        if dragging == nil {
            dragStart = weights
            dragging = dragStart
        }
        let fixedTotal = children.indices.compactMap(fixed).reduce(0, +)
        let flexWeight = children.indices.filter { fixed($0) == nil }.map { dragStart[$0] }.reduce(0, +)
        let pointsPerWeight = (flexLength - fixedTotal) / CGFloat(flexWeight)
        guard pointsPerWeight > 0 else { return }
        let pair = dragStart[i] + dragStart[i + 1]
        let least = Double(80 / pointsPerWeight)
        let a = min(max(dragStart[i] + Double(delta / pointsPerWeight), least), pair - least)
        guard a > 0, pair - a > 0 else { return }
        var w = dragStart
        w[i] = a
        w[i + 1] = pair - a
        dragging = w
    }

    private func commit() {
        guard let w = dragging else { return }
        var shares: [String: Double] = [:]
        for (i, child) in children.enumerated() where fixed(i) == nil {
            shares[child.id] = (w[i] * 10_000).rounded() / 10_000
        }
        model.setWeights(shares, container: id, on: context.space.machine)
    }
}

/// One pane: a terminal, or a note for what Swiftr does not show.
struct PaneView: View {
    let paneID: String
    let content: BlockContent
    let context: PaneContext

    var body: some View {
        switch content {
        case .terminal(let t):
            TerminalPane(address: qualify(t, on: context.space.machine), paneID: paneID, context: context)
        case .mod(let name):
            UnsupportedPane(text: "The “\(name)” mod shows in herdr-app.")
        case .tab, .agent, .other:
            UnsupportedPane(text: "This pane shows in herdr-app.")
        }
    }
}

struct UnsupportedPane: View {
    let text: String

    var body: some View {
        ContentUnavailableView(text, systemImage: "puzzlepiece.extension")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TerminalPane: View {
    @Environment(AppModel.self) private var model
    let address: String
    let paneID: String
    let context: PaneContext
    @State private var hovering = false

    /// In the background, the view keeps the size the core has (another
    /// app may be showing this terminal); in front, it fills the pane.
    private var followGrid: GridSize? {
        guard !model.appActive, let m = model.store.model(address), m.cols > 0, m.rows > 0 else { return nil }
        return GridSize(cols: m.cols, rows: m.rows)
    }

    var body: some View {
        let focused = context.focused == paneID
        let messages = model.showsMessages(address)
        Group {
            if messages {
                ConversationHost(address: address, paneID: paneID, pane: context)
            } else {
                let session = model.pool.session(address)
                TerminalHost(session: session, background: model.prefs.theme.backgroundColor, followGrid: followGrid, focused: focused, focusTick: model.focusTick)
                    .overlay { PhaseNote(session: session, record: model.store.model(address)) }
            }
        }
        .overlay {
            if context.multiple {
                // Round as the card (`Card.shape`): as the window's corners
                // where it meets them, else its least.
                Card.shape
                    .stroke(Color.accentColor.opacity(focused ? 0.8 : 0), lineWidth: 1.5)
                    .padding(0.75)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Terminal or conversation: shown over a Claude, Codex or OpenCode pane while the pointer is on it.
            if model.store.model(address)?.runsChatAgent == true, hovering || messages {
                PaneModeToggle(address: address)
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
    }
}

/// Says why a pane shows nothing live.
struct PhaseNote: View {
    let session: TerminalSession
    let record: TerminalModel?

    var body: some View {
        Group {
            switch session.phase {
            case .attached, .waiting:
                EmptyView()
            case .attaching:
                EmptyView()
            case .lost:
                note("Terminal lost, coming back with a new shell…", systemImage: "arrow.triangle.2.circlepath")
            case .ended(let why):
                note(why == "killed" ? "The program was stopped." : "The program ended.", systemImage: "stop.circle")
            case .failed(let why):
                note(why, systemImage: "exclamationmark.triangle")
            }
        }
        .allowsHitTesting(false)
    }

    private func note(_ text: String, systemImage: String) -> some View {
        VStack {
            Spacer()
            Label(text, systemImage: systemImage)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 14)
        }
    }
}
