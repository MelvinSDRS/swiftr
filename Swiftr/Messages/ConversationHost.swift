import AppKit
import SwiftUI

/// A Claude pane shown as a conversation. Its view stays with its feed
/// while the pane is out of sight (`MessageFeeds`), as a terminal's view
/// stays with its session: back on the tab, the conversation shows sooner,
/// scrolled where it was left. Made again, it would lay out every message
/// first, a few hundred milliseconds for a long conversation.
struct ConversationHost: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let address: String
    let paneID: String
    let pane: PaneContext

    func makeNSView(context: Context) -> ConversationContainer {
        ConversationContainer()
    }

    func updateNSView(_ container: ConversationContainer, context: Context) {
        container.show(ConversationRoot(model: model, address: address, paneID: paneID, pane: pane), feeds: model.feeds)
    }

    static func dismantleNSView(_ container: ConversationContainer, coordinator: ()) {
        container.release()
    }
}

/// A kept conversation view's content: the pane, and the model, which the
/// window's own views get from their surroundings.
struct ConversationRoot: View {
    let model: AppModel
    let address: String
    let paneID: String
    let pane: PaneContext

    var body: some View {
        MessagesPane(address: address, paneID: paneID, context: pane, feed: model.feeds.feed(address))
            .environment(model)
    }
}

/// Lends a conversation's kept view a place on screen, and counts its feed
/// as shown meanwhile. From one tab's conversation to another's, SwiftUI
/// keeps this container: the conversation left stays in it, hidden, still
/// in the window. Back in a window, a view takes about as long to show as
/// one made anew.
final class ConversationContainer: NSView {
    private var shown: (address: String, feed: TranscriptFeed, feeds: MessageFeeds)?

    func show(_ next: ConversationRoot, feeds: MessageFeeds) {
        if shown?.address != next.address {
            hideShown()
            let feed = feeds.feed(next.address)
            shown = (next.address, feed, feeds)
            feed.show()
        }
        let host: NSHostingView<ConversationRoot>
        if let kept = feeds.keptView(next.address) as? NSHostingView<ConversationRoot> {
            host = kept
            // Only when the pane changed: a new root updates the whole view.
            if kept.rootView.paneID != next.paneID || kept.rootView.pane != next.pane { kept.rootView = next }
        } else {
            host = NSHostingView(rootView: next)
            // Sized by the pane: an ideal size would measure every message.
            host.sizingOptions = []
            host.autoresizingMask = []
            feeds.keep(host, for: next.address)
        }
        if host.superview !== self { addSubview(host) }
        // A new container has no size yet: the view keeps the one it had,
        // likely the same, rather than laying out every message for none.
        if !bounds.isEmpty, host.frame != bounds { host.frame = bounds }
        host.isHidden = false
    }

    override func layout() {
        super.layout()
        // The hidden ones take the size when shown again.
        for view in subviews where !view.isHidden && view.frame != bounds { view.frame = bounds }
    }

    /// SwiftUI takes the container away: its views leave the window, and
    /// the feeds keep them a while.
    func release() {
        hideShown()
        for view in subviews { view.removeFromSuperview() }
    }

    private func hideShown() {
        guard let (address, feed, feeds) = shown else { return }
        shown = nil
        if let host = feeds.keptView(address), host.superview === self { host.isHidden = true }
        feed.hide()
    }
}
