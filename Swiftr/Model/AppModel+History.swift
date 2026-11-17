import AppKit
import HerdrKit

/// Back and Forward: through the tabs shown before, in any space, as a
/// browser goes through its pages.
extension AppModel {
    /// Where a tab of the history shows now; nil once closed, or while its
    /// machine hasn't answered.
    private func place(ofTab key: String) -> (space: SpaceItem, tab: LayoutTab)? {
        let (machine, id) = splitAddress(key)
        for space in spaces(on: machine) {
            if let tab = space.tabs.first(where: { $0.id == id }) { return (space, tab) }
        }
        return nil
    }

    var canGoBack: Bool { tabHistory.target(-1) { place(ofTab: $0) != nil } != nil }

    var canGoForward: Bool { tabHistory.target(1) { place(ofTab: $0) != nil } != nil }

    func goBack() { go(-1) }

    func goForward() { go(1) }

    private func go(_ step: Int) {
        var history = tabHistory
        guard let key = history.go(step, where: { place(ofTab: $0) != nil }), let (space, tab) = place(ofTab: key) else {
            NSSound.beep()
            return
        }
        // The stop first: the tab it shows is then no new one.
        tabHistory = history
        select(tab: tab, in: space)
    }

    /// After any change of layout or selection: the tab shown, when it is
    /// another one, is the history's next stop, whatever showed it (a click,
    /// a key, a new tab, the tab before it closing).
    func noteShownTab() {
        var history = tabHistory
        // Closed tabs, on machines that answered or that are gone.
        history.forget { key in
            let machine = splitAddress(key).machine
            return place(ofTab: key) == nil && (machineReady(machine) || (machinesKnown && slots[machine] == nil))
        }
        if let space = activeSpace, let tab = activeTab(in: space) { history.visit(tabKey(tab, in: space)) }
        // Only when it changed: the top row reads it.
        if history != tabHistory { tabHistory = history }
    }
}
