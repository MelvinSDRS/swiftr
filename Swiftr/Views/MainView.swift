import HerdrKit
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    /// The toolbar has Back and Forward, over the sidebar; nil until the
    /// window knows whether the sidebar shows.
    @State private var historyOverSidebar: Bool?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView()
                // No narrower than its toolbar's buttons: under 224 points
                // the toolbar drops Forward.
                .navigationSplitViewColumnWidth(min: 224, ideal: 240, max: 380)
                // Back and Forward: the sidebar's own items go between the
                // window's buttons and the sidebar's. Only while it shows:
                // hidden, the toolbar would keep one of the two before the
                // sidebar's button, so the top row shows them (`TabStrip`).
                .toolbar {
                    if historyOverSidebar == true {
                        ToolbarItemGroup {
                            HistoryButton(model: model, forward: false)
                            HistoryButton(model: model, forward: true)
                        }
                    }
                }
        } detail: {
            DetailView()
                // The top row floats on the card, or over it on the sidebar's
                // material (`DetailView`).
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .alert(renameTitle, isPresented: renameShown) {
            TextField("Name", text: $draft)
            Button("Rename") {
                if let target = model.renaming { model.rename(target, to: draft) }
                model.renaming = nil
                model.requestFocus()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                model.renaming = nil
                model.requestFocus()
            }
        } message: {
            Text(renameMessage)
        }
        .alert("Swiftr", isPresented: problemShown) {
            Button("OK") { model.problem = nil }
        } message: {
            Text(model.problem ?? "")
        }
        // From the sidebar's + or File › Add Machine…, sidebar shown or not.
        .sheet(item: Binding(get: { model.addingMachine }, set: { model.addingMachine = $0 })) { adder in
            AddMachineSheet(adder: adder)
                .environment(model)
        }
        // The first launch's welcome, or Swiftr › Welcome to Swiftr….
        .sheet(item: Binding(get: { model.onboarding }, set: { if $0 == nil { model.endOnboarding() } })) { onboarding in
            OnboardingSheet(onboarding: onboarding)
                .environment(model)
        }
        .onChange(of: model.renaming) { _, target in
            switch target {
            case .space(_, let name), .tab(_, let name), .machine(_, let name): draft = name
            case nil: break
            }
        }
        .onChange(of: lookSignature) { model.pool.applyLook() }
        // Back and Forward leave the toolbar as the sidebar goes, and come
        // back once it has slid in: new items while it slides held the
        // slide back, the sidebar's button pushed over the top row.
        .task(id: model.sidebarVisible) {
            let shown = model.sidebarVisible
            if shown, historyOverSidebar != nil {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
            }
            historyOverSidebar = shown
        }
        .task { await model.start() }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.view.sidebarVisible = $0 != .detailOnly }
        )
    }

    private var renameTitle: String {
        switch model.renaming {
        case .space: "Rename Space"
        case .tab: "Rename Tab"
        case .machine: "Rename Machine"
        case nil: ""
        }
    }

    private var renameMessage: String {
        guard case .machine(let name, _) = model.renaming else { return "Leave empty to use the automatic name." }
        return "Only Swiftr shows this name. Leave empty to go back to “\(model.coreTitle(ofMachine: name))”."
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
    }

    /// Changes when anything the terminals draw with changes: Swiftr's theme
    /// also changes with the app's light or dark.
    private var lookSignature: String {
        let p = model.prefs
        let t = p.theme
        return "\(p.themeName)|\(p.fontName)|\(p.fontSize)|\(p.optionKey.rawValue)|\(t.background)|\(t.foreground)|\(t.cursor ?? "")|\(t.selection ?? "")|\(t.ansi.joined())"
    }
}

/// The detail column's content sits on a card with round corners, set in
/// from the window's edges, on the sidebar's material.
enum Card {
    /// From the window's edges and the sidebar.
    static let margin: CGFloat = 8
    /// The window's own corners, less the margin, where it meets them;
    /// elsewhere this round.
    static let shape = ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: false)
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    /// The window's light or dark, which the toolbar follows.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shown = model.activeSpace != nil
        // The card runs up under the top row when the row's glass can sit
        // on it: the terminals' color as dark or as light as the window.
        // Else it starts under the row.
        let underToolbar = !shown || model.prefs.theme.isDark == (colorScheme == .dark)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The terminals' views too: their corners would stick out.
            .clipShape(Card.shape)
            .padding([.horizontal, .bottom], Card.margin)
            .background {
                let dark = colorScheme == .dark
                Card.shape
                    .fill(shown ? Color(nsColor: model.prefs.theme.backgroundColor) : Color(nsColor: .windowBackgroundColor))
                    // Lifted off the sidebar's surface: a soft shadow, and a
                    // hairline just outside its edge, where the content
                    // can't cover it.
                    .shadow(color: .black.opacity(dark ? 0.3 : 0.08), radius: 2)
                    .overlay { Card.shape.stroke(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.12), lineWidth: 1).padding(-0.5) }
                    .padding([.horizontal, .bottom], Card.margin)
                    .padding(.top, underToolbar ? Card.margin : 0)
                    .ignoresSafeArea(.container, edges: underToolbar ? .top : [])
            }
            .background { SidebarMaterial().ignoresSafeArea() }
            // The tabs and the buttons, in the title's place: the sidebar
            // already shows the space and its machine.
            .overlay(alignment: .top) {
                if let space = model.activeSpace {
                    TopRow(space: space, onCard: underToolbar)
                }
            }
            .toolbar(removing: .title)
            // Still the window's name, in the Window menu. Set here, not on
            // the split view: the window would read the shown space there,
            // and draw itself again, toolbar included, at each tab switch.
            .navigationTitle(model.activeSpace.map { model.title(of: $0) } ?? "Swiftr")
    }

    @ViewBuilder private var content: some View {
        if let space = model.activeSpace {
            if let tab = model.activeTab(in: space) {
                TabContent(space: space, tab: tab)
            } else {
                ContentUnavailableView("No Tabs", systemImage: "rectangle.dashed")
            }
        } else {
            switch model.link {
            case .connecting:
                ProgressView("Connecting to herdr-core…")
            case .missing:
                // The welcome sheet, over the window, says the rest.
                Color.clear
            case .installing:
                VStack(spacing: 10) {
                    ProgressView("Installing herdr-core…")
                    Text("It runs your terminals, and keeps them running when Swiftr quits.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .installFailed(let why):
                CoreInstallFailed(why: why)
            case .failed(let why):
                ContentUnavailableView("herdr-core isn't responding", systemImage: "bolt.horizontal.circle", description: Text(why))
            case .connected:
                if let key = model.view.activeSpace, model.machineLoading(splitAddress(key).machine) {
                    ProgressView()
                } else if model.slots[""]?.isReady == true {
                    ContentUnavailableView {
                        Label("No Spaces", systemImage: "square.dashed")
                    } description: {
                        Text("A space holds tabs of terminals.")
                    } actions: {
                        Button("New Space") { model.newSpace(on: "") }
                            .buttonStyle(.glassProminent)
                    }
                } else {
                    ProgressView()
                }
            }
        }
    }
}

/// What the window shows when herdr-core couldn't be installed: why, and
/// how to install it by hand meanwhile.
private struct CoreInstallFailed: View {
    let why: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let command = CoreInstall.command(environment: model.endpoint.environment)
        ContentUnavailableView {
            Label("herdr-core isn't installed", systemImage: "arrow.down.circle")
        } description: {
            Text("Swiftr couldn't install it: \(why.hasSuffix(".") ? why : why + ".") It tries again every 30 seconds. To install it yourself, run this in Terminal:")
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize()
        } actions: {
            Button("Try Again") { model.retryNow() }
                .buttonStyle(.glassProminent)
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }
}

/// The tabs and the buttons, in the band the toolbar keeps over the card,
/// after the window's own buttons.
private struct TopRow: View {
    let space: SpaceItem
    let onCard: Bool
    /// Where the window's own buttons end, from its left edge. Kept here,
    /// not in `DetailView`, so that a change redraws the row alone.
    @State private var buttonsEnd: CGFloat = 0

    var body: some View {
        GeometryReader { box in
            let frame = box.frame(in: .global)
            // The band from the window's top: the row sits in its middle.
            let band = max(frame.minY, 34)
            TabStrip(space: space, onCard: onCard)
                // Clear of the traffic lights and the sidebar button, over
                // the row once the sidebar is hidden: 8 past them, then the
                // tabs' own 8, about as far as the sidebar button sits from
                // the traffic lights. Worked out here, in the same pass that
                // moves the row as the sidebar slides.
                .padding(.leading, max(0, buttonsEnd + 8 - frame.minX))
                .frame(height: band)
                .offset(y: -band)
        }
        .background(alignment: .top) {
            WindowButtonsEnd(end: $buttonsEnd)
                .frame(height: 0)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, Card.margin)
    }
}

/// Where the window's own buttons end: the traffic lights, and the sidebar
/// button, which the toolbar puts after them once the sidebar is hidden.
/// The toolbar places them itself, so this reads where they are.
private struct WindowButtonsEnd: NSViewRepresentable {
    @Binding var end: CGFloat

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.report = { [end = $end] value in
            if end.wrappedValue != value { end.wrappedValue = value }
        }
    }

    final class Probe: NSView {
        var report: (CGFloat) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            guard let window else { return }
            // Full screen moves the buttons; a resize, the column. A window
            // that starts out of sight (the app launched hidden) has none
            // to read until it shows.
            let names = [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.measureSoon() }
                }
            }
            measureSoon()
        }

        override func layout() {
            super.layout()
            // The column grows or shrinks as the sidebar goes or comes back,
            // and the sidebar button moves with the sidebar's edge.
            measureSoon()
        }

        isolated deinit {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }

        /// Once the toolbar has placed its buttons, and outside SwiftUI's
        /// update, which the report changes.
        private func measureSoon() {
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        private func measure() {
            guard let window else { return }
            let toggle = window.toolbar?.items.first {
                $0.itemIdentifier == .toggleSidebar || $0.itemIdentifier.rawValue.hasSuffix("toggleSidebar")
            }?.view
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0) } + [toggle]
            // Through the screen: in full screen, the toolbar has a window
            // of its own.
            let end = buttons.compactMap { button -> CGFloat? in
                guard let button, let home = button.window, home.isVisible, !button.isHiddenOrHasHiddenAncestor else { return nil }
                let onScreen = home.convertToScreen(button.convert(button.bounds, to: nil))
                return window.convertPoint(fromScreen: NSPoint(x: onScreen.maxX, y: onScreen.minY)).x
            }.max()
            report(end ?? 0)
        }
    }
}

struct TabContent: View {
    @Environment(AppModel.self) private var model
    let space: SpaceItem
    let tab: LayoutTab

    var body: some View {
        let zoomed = model.zoomedPane(in: tab, of: space)
        let root = zoomed.flatMap { tab.root.find($0) } ?? tab.root
        let context = PaneContext(
            space: space, tab: tab,
            focused: model.focusedPane(in: tab, of: space),
            multiple: zoomed == nil && tab.root.visibleBlocks.count > 1
        )
        PaneTree(node: root, context: context)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The sidebar's own material, around the card and over the sidebar's
/// glass: one surface from the window's edges to the card's, as the
/// sidebar's glass over it would come out a shade off.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> MaterialView {
        let view = MaterialView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: MaterialView, context: Context) {}

    final class MaterialView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            clearSidebarEdge()
        }

        override func layout() {
            super.layout()
            clearSidebarEdge()
        }

        /// What the split view draws over both columns at the sidebar's
        /// edge, its line and the sidebar's shadow: the card's edge is the
        /// only one. Clear, not hidden: the pointer still drags the line.
        private func clearSidebarEdge() {
            var view = superview
            while let v = view, !(v is NSSplitView) { view = v.superview }
            for edge in view?.subviews ?? [] where edge.alphaValue != 0 {
                let name = String(describing: type(of: edge))
                if name.contains("Divider") || name.contains("Shadow") { edge.alphaValue = 0 }
            }
        }
    }
}
