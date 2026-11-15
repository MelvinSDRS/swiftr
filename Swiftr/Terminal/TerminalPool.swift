import AppKit
import HerdrKit

/// Keeps one session per terminal Swiftr shows. Every terminal of the shown
/// space stays attached, so switching tabs is instant; a few recently shown
/// ones stay too, and the rest are detached and dropped.
final class TerminalPool {
    private(set) var sessions: [String: TerminalSession] = [:]
    private unowned let model: AppModel
    /// How many terminals outside the shown space stay attached.
    var recentLimit = 12

    init(model: AppModel) {
        self.model = model
    }

    /// The session for `address`, made (not yet attached) if needed.
    func session(_ address: String) -> TerminalSession {
        if let s = sessions[address] { return s }
        let record = model.store.model(address)
        let cols = record?.cols ?? 0
        let rows = record?.rows ?? 0
        let s = TerminalSession(address: address, cols: cols > 0 ? cols : 120, rows: rows > 0 ? rows : 40, model: model)
        sessions[address] = s
        return s
    }

    func existing(_ address: String) -> TerminalSession? { sessions[address] }

    /// Attaches `background` (shown space, other tabs) at once; `onScreen`
    /// ones attach when their view is laid out. Drops what is neither and
    /// was not shown recently, or whose program is over: a view drawn once
    /// more with the old layout can make a session for a pane just closed.
    func keep(onScreen: Set<String>, background: Set<String>) {
        for address in background where !onScreen.contains(address) {
            let s = session(address)
            if s.phase == .waiting || s.phase == .lost { s.attach() }
        }
        let wanted = onScreen.union(background)
        let others = sessions.values
            .filter { !wanted.contains($0.address) }
            .sorted { $0.lastShown > $1.lastShown }
        for (i, s) in others.enumerated() where i >= recentLimit || model.store.model(s.address)?.isLive != true {
            drop(s.address)
        }
    }

    func drop(_ address: String) {
        guard let s = sessions.removeValue(forKey: address) else { return }
        s.detach()
        if s.view.superview != nil { s.view.removeFromSuperview() }
    }

    func connectionLost() {
        for s in sessions.values { s.connectionLost() }
    }

    /// A new connection: every kept session attaches again.
    func reconnected() {
        for s in sessions.values { s.reattach() }
    }

    func applyLook() {
        for s in sessions.values { s.applyLook() }
    }
}

/// A weak reference that can cross threads.
final class WeakBox<T: AnyObject & Sendable>: Sendable {
    weak let value: T?

    init(_ value: T) {
        self.value = value
    }
}

/// Runs `body` on the main thread, after what was queued before it.
nonisolated func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { body() }
    }
}
