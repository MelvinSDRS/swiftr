import HerdrKit

/// Claude, Codex and OpenCode panes shown as a terminal or as a conversation.
extension AppModel {
    /// How this terminal's pane shows its agent: its own choice, else that
    /// agent's setting.
    func paneMode(of address: String) -> PaneMode {
        view.paneModes?[address] ?? prefs.panes(of: chatAgent(address))
    }

    /// The agent in front in this terminal; Claude's setting stands for any other program.
    func chatAgent(_ address: String) -> ChatAgent {
        store.model(address).flatMap(ChatAgent.init(record:)) ?? .claude
    }

    /// The pane shows a conversation: Messages chosen, and Claude, Codex or OpenCode runs there.
    func showsMessages(_ address: String) -> Bool {
        paneMode(of: address) == .messages && store.model(address)?.runsChatAgent == true
    }

    func setPaneMode(_ mode: PaneMode, for address: String) {
        let before = showsMessages(address)
        var modes = view.paneModes ?? [:]
        modes[address] = mode == prefs.panes(of: chatAgent(address)) ? nil : mode
        view.paneModes = modes.isEmpty ? nil : modes
        requestFocus()
        // The draft and the answers chosen follow to where the person writes now.
        let after = showsMessages(address)
        guard before != after, store.model(address)?.runsChatAgent == true else { return }
        let feed = feeds.feed(address)
        Task {
            if after { await feed.paneShown() } else { await feed.paneLeft() }
        }
    }

    /// ⇧⌘M: the focused Claude, Codex or OpenCode pane switches between terminal and conversation.
    func toggleMessages() {
        guard let address = focusedAddress, store.model(address)?.runsChatAgent == true else { return }
        setPaneMode(showsMessages(address) ? .terminal : .messages, for: address)
    }

    /// The focused pane runs Claude, Codex or OpenCode, so ⇧⌘M means something.
    var focusedRunsClaude: Bool {
        focusedAddress.flatMap { store.model($0) }?.runsChatAgent == true
    }
}
